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
- The window is a floating window. `q` closes it.
- The view opens immediately and is populated asynchronously as git output
  arrives; the window must not block on git completing.

## 3. Data source

### 3.1 Branches

Branch heads are read via `git for-each-ref` over `refs/heads`, producing a
`name → object-hash` mapping. This populates the repository's branch list
ahead of the commit stream.

### 3.2 Commits

Commits are read via `git log` with:

- `--topo-order` — topological ordering (children before parents).
- `--parents` — full parent hash list per commit.
- `--decorate=full` — ref decorations (branches, tags, HEAD).
- a `branches` refspec, default `--all`.

Each commit carries: hash, parent hashes, author, author date, subject,
and parsed ref decorations.

## 4. Data model

```
Commit  = { hash, parents: Commit[], children: Commit[], refs: Refs,
            author, date, message }
Refs    = { branches: Ref[], tags: Ref[], symbols: {from,to}[], raw: string[] }
Ref     = { name }
```

- Commits are identity-stable: a commit referenced as a parent before it is
  seen in the log is the *same* object once its own log line arrives.
- Every parent hash resolves to a `Commit`. A parent not present in the
  fetched range still exists as a (sparse) `Commit` so the graph stays
  connected.
- Child links are the inverse of parent links.

### 4.1 Ref parsing (`%D` decorate field)

Given the comma-separated decorate string, each entry is classified:

| Entry form                  | Classified as | Notes |
|-----------------------------|---------------|-------|
| `HEAD -> <ref>`             | `symbols` + `branches` | `from`/`to`; target also recorded as a branch |
| `tag: <ref>`                | `tags`        | name is the text after `tag: ` |
| `refs/heads/<name>`         | `branches`    | name is `<name>` |
| anything else               | `raw`         | kept verbatim (e.g. remotes) |

An empty decorate string yields all-empty ref lists.

## 5. Graph layout

Each commit occupies one **row**. A row is a sequence of **lanes** (tracks).
A lane is a vertical line of history with:

- an **id** (stable identity, used to pick its color),
- **connectivity** (`up`, `down`, `left`, `right`),
- an optional **commit** marker when the commit sits on that lane.

### 5.1 Invariants

- The commit for a row sits on exactly one lane in that row.
- A lane that continues from the previous row preserves its id (and thus its
  color).
- Merges (a commit with >1 parent) fan out additional lanes; splits (a commit
  with >1 child) fan lanes in.
- Lane connectivity is internally consistent: a lane segment that claims a
  `down` connection is matched by an `up` on the lane below in the same
  column, and horizontal connectors join adjacent lanes that claim `left`/
  `right` toward each other.

### 5.2 Merge style

`merge_style` selects where merges and splits are drawn:

- `split_on_separate_line` — when set and a commit has >1 child, the fan-in
  is drawn on a virtual line **above** the commit row.
- `merge_on_separate_line` — when set and a commit has >1 parent, the fan-out
  is drawn on a virtual line **below** the commit row.
- `allow_merge_on_split` — permits placing a merge onto a split lane when
  merges are folded onto the commit line. **Experimental.** In this mode a
  merge commit's incoming lane terminates while a new parent lane reuses the
  same column, so a vertical lane's color may change mid-column at a merge
  (a "lane handoff"). The intended rendering for this case is not yet settled;
  the behavior is pinned by a characterization test rather than treated as a
  fixed contract.

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
4. ref decorations — branches as `(name)`, tags as `[name]`
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
