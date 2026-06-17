# gitloom.nvim — Specification

This is the behavioral contract: *what* gitloom does, independent of *how*
it is implemented. Implementation details live in
[ARCHITECTURE.md](ARCHITECTURE.md).

This document is authoritative. When behavior changes, update this file
first (see [CLAUDE.md](CLAUDE.md) → Spec-First Development).

## 1. Purpose and scope

gitloom's primary goal is to be an excellent **git graph viewer**. The graph
is the product. Other git functionality is deliberately out of scope, except
where it falls naturally *out of* the graph (e.g. acting on the commit under
the cursor) or is delegated to an existing plugin (e.g. opening a diff in
diffview).

### 1.1 Own the model

gitloom does **not** wrap `git log --graph`. It reads commit and ref data
from git and builds the commit DAG, the row ordering, and the lane layout
itself, in memory. Owning the model is a hard requirement, not an
implementation detail: the planned view features — collapsing, pinning,
toggling branch visibility, and reflowing (§10) — are only possible if
gitloom controls ordering and layout rather than delegating them to git.

Today the view is read-only and shows a single fixed projection of the graph.
The view-transformation features in §10 are the direction this is built
toward; the current non-graph surface (window, streaming fetch, rendering)
exists primarily to exercise and validate the graph algorithm.

## 2. Entry point

- `:GitloomGraph` opens the graph for the repository at Neovim's current
  working directory.
- The window is a floating window. `q` closes it; `m` cycles the merge/split
  rendering style (§5.2) so the styles can be compared at a glance. Two debug
  aids: `K` opens a float with the full lane breakdown for the commit under
  the cursor, and `i` toggles the per-lane id column before the message (a
debug aid, hidden by default).
  `?` opens a float listing all keybindings. The footer shows live status
  (currently the active mode).
- The view opens immediately and is populated asynchronously as git output
  arrives; the window must not block on git completing.

## 3. Data source

Two independent queries, joined by commit hash.

### 3.1 Commits

Commits are read via `git log` with:

- `--topo-order` — topological ordering (children before parents).
- `--parents` — full parent hash list per commit.
- a refspec, default `--all`.

Each commit carries: hash, parent hashes, author, author date, subject. Refs
are **not** taken from `--decorate`; they come from §3.2.

### 3.2 Refs

Refs are read via `git for-each-ref` over `refs/heads`, `refs/remotes`, and
`refs/tags`, yielding for each ref its refname, target hash, and — for
annotated tags — the dereferenced commit hash. The current branch is read via
`git symbolic-ref` (HEAD). Each ref is resolved to the `Commit` it points at
by hash (§4.1).

Using a dedicated, structured query rather than parsing `git log --decorate`
makes ref discovery robust and makes remote branches and annotated tags
first-class (the decorate field conflated them and dropped remotes).

## 4. Data model

```
Commit = { hash, parents: Commit[], children: Commit[], refs: Ref[],
           author, date, message }
Ref    = { name, kind, commit: Commit }
```

- `Ref.kind` is one of `local`, `remote`, `tag`, `head`.
- `Ref.commit` is the `Commit` the ref points at — a **direct reference, not a
  hash**. `Commit.refs` lists the refs pointing at it (the inverse). A
  name → `Ref` registry is kept on the repository.
- Commits are identity-stable: a commit referenced as a parent (or by a ref)
  before it is seen in the log is the *same* object once its own log line
  arrives.
- Every hash reference resolves to a `Commit`: parent hashes and ref targets
  become `Commit` references once resolved. A target not in the fetched range
  still exists as a (sparse) `Commit` placeholder so the graph and refs stay
  connected, filled in when (if) its log line arrives.
- Child links are the inverse of parent links.

### 4.1 Ref resolution

Each ref is classified by its refname and resolved to its target commit:

| refname                          | kind     | name shown            |
|----------------------------------|----------|-----------------------|
| `refs/heads/<name>`              | `local`  | `<name>`              |
| `refs/remotes/<remote>/<name>`   | `remote` | `<remote>/<name>`     |
| `refs/tags/<name>`               | `tag`    | `<name>` (annotated tags resolved to their commit via the dereferenced hash) |
| HEAD (symbolic)                  | `head`   | marks the current branch's commit; a detached HEAD is not marked (current limitation) |

`refs/remotes/<remote>/HEAD` (the remote's default-branch symref) is skipped.
The target hash is looked up in the commit table; a missing target yields a
sparse `Commit` placeholder (as above).

## 5. Graph layout

Each commit occupies one **row** — it carries that commit's message, so there
is exactly one commit per row. A row is a sequence of **cells**, one per
column. A cell holds zero or more **lanes**, where a lane is one wire passing
through the cell:

```
Lane = { id, child: Commit, parent: Commit, connectivity: {up,down,left,right} }
```

- **id** — stable visual identity (drives color).
- **child** — the already-placed commit (above) the lane emanates from; its
  owner / attribution anchor.
- **parent** — the commit (below) the lane leads to and terminates at.
- **connectivity** — which of the cell's four sides this wire touches.

A lane represents the edge **child → parent**. The graph is walked top to
bottom (newest heads on top, roots at the bottom), so the child is always
already placed and the parent is the downward target; reaching a commit
matches it against its children's active lanes.

The cell's rendered **glyph** is the function of the **union** of its lanes'
connectivity. The cell's **color** is the id of one of its lanes, chosen by a
configurable "top" strategy.

### 5.1 Invariants

- **One commit per row.** Exactly one commit is placed per commit row; the
  virtual split/merge sub-lines carry none.
- **Two-sided lanes.** Each lane touches exactly two of the cell's sides (a
  wire enters and exits) — one side only where it is an endpoint (born at or
  terminating at a commit). This forces crossings (`─│─`) and tees to be
  modeled as *separate* lanes, not one over-connected wire.
- **Leads somewhere.** Every lane has a `parent`; its run terminates exactly
  at the row where that parent is placed (or the fetched-range boundary). No
  lane fizzles out into nothing.
- **No accidental crossing.** A lane keeps its `(id, child, parent)` along its
  run; two lanes that share a column or cross stay distinct because their
  edges differ.
- **Per-lane continuity.** A lane with `down` at one row meets a lane with the
  same id and `up` in the same column on the next row.
- **Color is active.** The color a cell shows is the id of one of its lanes.
- **Connectivity consistency.** The glyph's wired sides equal the union of the
  cell's lanes' connectivity (every wired side has a lane providing it).
- Merges (commit with >1 parent) fan out additional lanes; splits (>1 child)
  fan lanes in.

Current limitation: a cell's vertical lanes number at most one. A "bus" of
several bundled vertical lanes is reserved for future collapse/reflow work;
`Lane` arrays are kept symmetric (vertical and horizontal alike) to admit it.

Implementation status: lane `id`, `connectivity`, and the handoff split are
implemented and tested. Per-lane **`child`** and a *precise* per-lane
**`parent`** are not yet threaded — every lane currently carries its track's
parent, sufficient for `leads-somewhere`. Full edge attribution (the
`(id, child, parent)` identity behind `no accidental crossing`) is the next
step toward §10.

### 5.2 Merge style

`merge_style` selects where merges and splits are drawn:

- `split_on_separate_line` — when set and a commit has >1 child, the fan-in
  is drawn on a virtual line **above** the commit row.
- `merge_on_separate_line` — when set and a commit has >1 parent, the fan-out
  is drawn on a virtual line **below** the commit row.
- `allow_merge_on_split` — permits placing a merge onto a split lane when
  merges are folded onto the commit line. In this mode an incoming child-lane
  and an outgoing parent-lane can share a column (a "lane handoff"): the cell's
  `up` segment and `down` segment belong to *different* lanes. The **model**
  represents these faithfully as two separate lanes (so per-lane continuity
  holds); the **rendered** glyph is a single cell that can only show one
  color, so its color is best-effort and may read as continuous across the
  handoff. The model is the contract here, not the coloring.

When a separate line is not used, the merge/split is folded onto the commit
row itself.

### 5.3 Glyphs

Lanes render as box-drawing characters derived from connectivity
(`│ ├ ┤ ┬ ┴ ╭ ╮ ╯ ╰ ─` and the terminal half-segments). Commit markers:

| Marker | Meaning |
|--------|---------|
| `◎`    | root commit (no parents) |
| `◉`    | tip commit (no children) |
| `○`    | ordinary commit |
| merge icon | merge commit when merges are folded onto the line and `icons.merge` is set |

## 6. Row content

A commit row displays, left to right:

1. author date
2. author name
3. graph lanes (glyphs)
4. ref decorations, by kind — local branches as `(name)`, remote branches as
   `(remote/name)` (dimmed), tags as `[name]`, and a `HEAD` marker on the
   current branch
5. commit subject

Columns are width-aligned across visible rows. Each field is colored by its
`palette` highlight group; lanes are colored by lane id cycled through
`palette.tracks`.

## 7. Rendering behavior

- Rendering is **viewport-driven**: only rows within the visible range are
  laid out and drawn. Scrolling triggers layout of newly visible rows.
- The view updates incrementally as commits stream in.
- The buffer is non-modifiable to the user (`nofile`, read-only).

## 8. Configuration

`GraphOptions` (see [README.md](README.md) for the full default table):

```
GraphOptions = { win, palette, merge_style, icons, branches }
MergeStyle   = { allow_merge_on_split, merge_on_separate_line, split_on_separate_line }
```

- `win` — floating-window geometry (snacks.win).
- `palette` — highlight group per field, plus a `tracks` list cycled by lane id.
- `branches` — ref argument(s) for `git log` (default `--all`).

### Known gap: setup() wiring

`require("gitloom").setup(opts)` stores `opts` in the module config, but the
`:GitloomGraph` command currently invokes the graph with built-in defaults
and does **not** read that stored config. Forwarding `setup()` config to the
command is unimplemented. Until then, the documented defaults always apply to
`:GitloomGraph`. (Programmatic callers may pass options directly to the graph
open function.)

## 9. Non-goals

**Permanently** out of scope: repository mutation of any kind (no checkout,
commit, rebase, reset). gitloom is a viewer.

Out of scope **for now**, but reasonable later where they arise naturally
from the graph: acting on the commit/ref under the cursor, and integration
with external plugins (e.g. opening a diff via diffview). These are secondary
to the graph itself and must not compromise the model-ownership principle
(§1.1).

## 10. Planned: view model and transformations

> Status: **direction, not yet implemented.** This section records intended
> behavior so design and code can converge on it. It does not describe
> current behavior.

The graph is a *projection* of the full in-memory commit model under a
**view state**. Changing the view state reflows the graph.

### 10.1 Branch visibility

Each branch (identified by a ref / head) has a visibility mode:

- **visible** — its commits are shown in full.
- **collapsed** — its commits are represented compactly (conceptually a
  single row) while connectivity to visible lanes is preserved.
- **hidden** — its commits are removed from the view.

Toggling a branch's mode reflows the graph to match.

### 10.2 Pinned heads

A branch head may be **pinned**. Pinning guarantees that everything the
pinned head references (its reachable history, subject to the attribution
rule in §10.4) stays visible regardless of other visibility settings.

### 10.3 Reflow

Any change to view state produces a freshly computed ordering + lane layout
over the visible/collapsed commit set — recomputed from scratch, not
appended. Reflow must be deterministic and stable enough that unaffected
regions of the graph do not visually churn.

### 10.4 Open design questions

These must be specified before implementation:

- **Commit attribution (the central problem).** Commits are shared across
  branches in a DAG. Collapsing or hiding "a branch" requires a precise rule
  for which commits belong to that branch versus are shared with retained
  branches — e.g. first-parent ownership, or reachable-minus-other-retained-
  heads. Pinning and hiding both depend on this rule.
- **Collapsed rendering.** What a collapsed branch's single row shows
  (summary, commit count) and how merges into/out of it connect to visible
  lanes.
- **Hidden connectivity.** Whether a merge from a hidden branch into a
  visible one leaves a phantom indicator or vanishes entirely.
- **Scale.** Reading all commits is unbounded in large repositories; the
  loading strategy (limits, lazy/streamed loading, on-demand reachability)
  must keep reflow responsive.
