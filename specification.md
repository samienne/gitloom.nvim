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
  rendering style (§5.2) so the styles can be compared at a glance; `M` toggles
  graph mirroring (§5.4); `<CR>` opens the **commit view** for the commit on
  the current row (§11). Two debug
  aids: `K` opens a float with the full lane breakdown for the commit under
  the cursor, and `i` toggles the per-lane id column before the message (a
debug aid, hidden by default). `d` toggles the date column between absolute and
relative (§6).
  `?` opens a float listing all keybindings. The footer shows live status
  (the active mode, and `(mirrored)` when mirroring is on).
- **Navigation.** Navigation is line-by-line (`j`/`k`, arrows, etc. move whole
  rows), with `cursorline` marking the current row (§7). The cursor is parked at
  the **commit message** rather than left at column 0. `h`/`l` move a selection
  across the current row's ref decorations — the branch groups then tags (§6);
  the selected decoration is highlighted (`palette.selected`) **and the cursor
  moves onto it**. The message is the default position (the cursor parks there);
  since refs are pinned to the right edge, `l` moves **right** onto the refs
  (starting at the first) and `h` moves **left** back toward the message.
  Selection clamps at the last ref and resets to the message when the cursor
  moves to another row. This selection is the substrate for the planned
  per-branch actions (collapse / hide / pin, §10); it has no effect yet.
- The view opens immediately and is populated asynchronously as git output
  arrives; the window must not block on git completing.

## 3. Data source

Two independent queries, joined by commit hash.

### 3.1 Commits

Commits are read via `git log` with:

- `--topo-order` — topological ordering (children before parents).
- `--parents` — full parent hash list per commit.
- a refspec, default `--all`.

Each commit carries: hash, parent hashes, author, author date, subject. The
author date is read as a Unix epoch (`%at`) plus its tz offset (from `%ai`) and
parsed into a structured `Timestamp` (§4), not kept as text. Refs are **not**
taken from `--decorate`; they come from §3.2.

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
Commit    = { hash, parents: Commit[], children: Commit[], refs: Ref[],
              author, date: Timestamp, message }
Ref       = { name, kind, commit: Commit }
Timestamp = { epoch, offset, raw }
```

- `Commit.date` is a parsed `Timestamp`, not a string: `epoch` is the author
  date as Unix time (UTC), `offset` is the author's tz offset in seconds (so
  the author's local wall-clock is `epoch + offset`), and `raw` keeps the
  original `%ai` text. Formatting happens at render time (§6).
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

### 5.4 Mirroring

By default the graph is **mirrored**: the cell sequence of each row is reversed
and each cell's `left`/`right` connectivity is swapped before glyphs are
derived, so the graph reads right-to-left with lane 1 at the **right** edge of
the graph column, nearest the commit message. The graph column is right-aligned
(padded on the left) so vertical wires stay column-aligned across rows of
differing lane counts. Setting `mirror = false` (§8) renders it the
conventional way, left-to-right with lane 1 at the left.

Mirroring is purely a rendering transform: the commit ordering, the lane
layout, and the lane model (ids, `child`/`parent`, per-lane continuity) are
unchanged — only the projection to glyphs is flipped. Because the glyph is a
pure function of connectivity (§5), the mirrored glyphs (`╭`↔`╮`, `┤`↔`├`,
`╴`↔`╶`) and the inter-lane connectors fall out of the model with no separate
glyph-swap table, and color (lane id) is preserved. All §5.1 invariants hold on
the mirrored output.

## 6. Row content

A commit row displays, left to right:

1. author date — formatted from the `Timestamp` (§4) either as an **absolute**
   author-local time (via the configurable `date_format`, default
   `%Y-%m-%d %H:%M`) or as a **relative** age (e.g. `3 days ago`). The
   `date_mode` selects which; `d` toggles it live.
2. author name
3. graph lanes (glyphs)
4. commit subject (the message)
5. ref decorations, pinned to the **right edge** of the row

The date, author, and graph are width-aligned across visible rows. The message
and refs share the remaining width **per row** (not as a fixed aligned column,
so navigation stays line-by-line): the refs are right-aligned at the window
edge and the message fills the gap, truncated with `…` when it does not fit.

**Ref decorations** — a `HEAD` marker on the current branch, then branch
groups, then tags as `[name]`. Branch refs (local + remote) that share a
**short name** collapse into one group: the name is shown once, followed by the
remotes that also point at this commit, as `(name ↑remote1,remote2)`. The name
is highlighted when a local branch exists and dimmed when the group is
remote-only. A local branch with no matching remotes is just `(name)`. This
keeps the common case (a branch plus its remote-tracking copies all at one
commit) from repeating the name per remote.

**Ref width budget.** The refs use the row's free width: they may take
everything the message does not need — its natural width, but never reserving
more than `message_min` (§8). So refs fill empty space when the message is
short, while a long message still keeps at least `message_min` columns
(truncated with `…`). Ref labels are shown in order (leftmost first) until the
budget is reached; labels that do not fit collapse into a trailing `+N` overflow
marker. Each field is colored by its `palette` highlight group; lanes are
colored by lane id cycled through `palette.tracks`.

The `h`/`l` selection (§2) cycles all of a row's ref decorations. One collapsed
into the `+N` overflow can still be selected, but until it is visible it is not
highlighted and the cursor falls back to the message (revisited with the §10
actions).

## 7. Rendering behavior

- Rendering is **viewport-driven**: only rows within the visible range are
  laid out and drawn. Scrolling triggers layout of newly visible rows.
- The view updates incrementally as commits stream in.
- The buffer is non-modifiable to the user (`nofile`, read-only).
- The window uses `cursorline` as the current-row indicator and keeps the
  cursor parked at the commit message (or, when a ref is selected, on that ref);
  see §2.

## 8. Configuration

`GraphOptions` (see [README.md](README.md) for the full default table):

```
GraphOptions = { win, palette, merge_style, icons, branches, mirror,
                 date_format, date_mode, message_min }
MergeStyle   = { allow_merge_on_split, merge_on_separate_line, split_on_separate_line }
```

- `win` — floating-window geometry (snacks.win).
- `palette` — highlight group per field, plus a `tracks` list cycled by lane id.
  Includes `selected`, the highlight for the `h`/`l`-selected ref decoration
  (§2; default `Visual`), and `diff`, a sub-table of highlight groups for the
  commit view's diff: `add`, `delete`, `hunk`, `header` (defaults `DiffAdd`,
  `DiffDelete`, `Title`, `Comment`; §11.3).
- `branches` — ref argument(s) for `git log` (default `--all`).
- `mirror` — render the graph mirrored with lane 1 at the right edge of the
  graph column, nearest the message (§5.4). **Default true.** Set false for the
  conventional left-to-right layout. Purely a rendering transform; ordering and
  lane layout are unchanged. Toggle live with `M`.
- `date_format` — `os.date` format string for absolute dates (default
  `%Y-%m-%d %H:%M`), rendered in the author's local time.
- `date_mode` — `absolute` (default) or `relative`; selects the initial date
  rendering (§6). Toggle live with `d`.
- `message_min` — the minimum width always kept for the message (default `24`);
  the right-pinned refs use the rest of the free width, with overflow becoming
  `+N` (§6).

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

Acting on the commit under the cursor is reasonable where it arises naturally
from the graph, and the **commit view** (§11) is the first realization of it: a
read-only detail view of the selected commit. Showing the commit's diff in that
view is planned. Integration with external plugins (e.g. opening a diff via
diffview) remains reasonable later. These are secondary to the graph itself and
must not compromise the model-ownership principle (§1.1).

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

## 11. Commit view

Pressing `<CR>` on a commit row opens the **commit view**: a separate read-only
floating window showing the full details of that one commit. `q` closes it. Like
the graph, it is a viewer — it never mutates the repository (§9).

### 11.1 Data source

The commit view's data is fetched **on demand** when it is opened — a single
`git show -s` for the selected commit's hash — *not* taken from the streaming
graph model. The graph model (§3, §4) deliberately carries only what the graph
needs (author, author date, subject); the richer per-commit detail (email,
committer, full message body) is read only when a commit is actually opened, so
the streaming path stays lean. The refs shown are the row's existing decorations
(§6), reused from the model rather than re-queried.

The diff is fetched the same way, on demand, by a second `git show --format= -p`
for the commit, chained after the metadata fetch; the view renders once both
arrive.

### 11.2 Content

The view shows, in order:

1. the full commit hash;
2. the ref decorations on the commit (the same compact groups as §6), when any;
3. the **author** — name, email, and date;
4. the **committer** — name, email, and date — shown **only when it differs**
   from the author (the common case where they match is omitted to reduce
   noise);
5. the parent commits (abbreviated hashes), when any;
6. the full commit message — subject and body — indented;
7. the **diffstat** — the list of changed files with per-file insertion /
   deletion counts (§11.4) — shown between the message and the diff;
8. the commit's diff (the patch), shown below the diffstat.

The author and committer dates are shown as `git show` renders them
(`--date=iso`); the structured `Timestamp` formatting of §6 applies to the graph
date column, not here.

### 11.3 Diff

The commit view shows the commit's diff below the diffstat (§11.4). Highlighting is
**line-level** (matching git's default and lazygit/tig): each patch line is
colored by its role — added, removed, hunk header (`@@ … @@`), and file header
(`diff --git`, `index`, `---`/`+++`, mode/rename/new-file lines); context lines
are uncolored. The highlight groups come from `palette.diff` (§8), using
always-defined UI groups by default, applied as extmarks — the view does **not**
switch the buffer to `filetype=diff`, so the custom metadata header above stays
unaffected. Language-aware (intra-line) syntax highlighting of the diff content
is a possible future enhancement.

### 11.4 Changed-files list (diffstat)

Between the message and the diff, the commit view shows a **diffstat**: a
summary line (`N files changed, X insertions(+), Y deletions(-)`) followed by one
line per changed file — the path, its insertion/deletion counts, and a colored
`+`/`-` bar (the `+` segment in `palette.diff.add`, the `-` in
`palette.diff.delete`; §8). Renames are shown as `old => new`; a binary file
shows `Bin` instead of counts.

The diffstat is **derived from the same patch** that §11.3 renders — not a
separate query — so the file list, the counts, and each file's location in the
diff all come from one source.

Pressing `<CR>` on a changed-file line **jumps** the cursor to that file's
section in the diff below (scrolling it to the top of the view). This makes the
diffstat a table of contents for the diff. The jump is recorded in the
jumplist, so `<C-o>` / `<C-i>` move back to the diffstat and forward to the diff
section as usual. `<CR>` elsewhere in the view does nothing.
