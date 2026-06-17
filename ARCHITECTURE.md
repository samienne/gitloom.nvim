# gitloom.nvim — Architecture

This document describes *how* gitloom is built. For *what* it does at the
contract level, see [specification.md](specification.md). For user-facing
docs, see [README.md](README.md).

## Self-contained by design

gitloom ships as part of the loomworks suite but **does not depend on
`loomworks.nvim`**. Today it vendors small utilities that loomworks also
has (a promise/future and a highlight-composition helper) rather than
importing them.

Rationale: gitloom should be installable and runnable on its own, with
snacks.nvim as its only third-party dependency. If shared utilities prove
worth deduplicating, the intended path is to extract a small standalone
`utils`-style library that both plugins copy or depend on — **not** to make
gitloom depend on loomworks. Until that exists, keep the vendored copies.

## Model ownership and the view pipeline

gitloom owns its model. It reads raw commit + ref data from git and builds
the DAG, ordering, and lane layout itself — it does not delegate graph
drawing or ordering to `git log --graph`. This is what makes the planned view
transformations (collapse / pin / toggle / reflow — see specification.md §10)
possible at all.

The intended pipeline separates four concerns:

1. **Repository model** — all fetched commits, refs, and the parent/child
   graph. The source of truth, independent of how it is displayed.
2. **View state** — per-branch visibility (visible/collapsed/hidden) and
   pinned heads.
3. **View builder** — a `(model, view state) → ordered rows → lane layout`
   computation. Must be recomputable from scratch so changing view state can
   *reflow* the graph, not merely append to it.
4. **Rendering** — the virtualized listview draws whatever rows the view
   builder produced.

### Current state vs. target

The model and rendering layers exist, and the **view-builder seam** is now in
place; **view state** does not yet exist:

- The repository model exists as `repo.commits` (an identity-stable DAG), and
  **ordering is still seeded from `git log --topo-order`**.
- Layout is exposed two ways over a shared pure core (`layout_item`):
  - `build_graph(opts, items)` — lays out an ordered item list **from
    scratch**, deterministically (fresh lane-id sequence each call). This is
    the reflow primitive and the test entry point.
  - `refresh_tracks(opts, order, start_pos)` — the production **incremental**
    path: a thin adapter that calls `layout_item` for newly streamed commits
    and assigns the result onto the `OrderItem` in place.
- There is no view state yet. The view is a single fixed projection, so
  `build_graph` is currently only driven by tests; production uses the
  incremental path.

What remains for the target is **ordering ownership** (move ordering out of
`git log` into the builder) and a **view state** input (per-branch
visibility, pinned heads) that `build_graph` reflows against. The lane
algorithm (`handle_commit_line` / `handle_merge_line` / `handle_split_line`,
behind `layout_item`) is reused as-is; what changes is *what feeds it* — a
filtered, possibly reordered commit set instead of the raw git stream.

The central unsolved problem is **commit attribution** (specification.md
§10.4): deciding which commits "belong to" a branch being collapsed or hidden
when commits are shared across the DAG.

## Layers

```
lua/gitloom/
  init.lua       Thin facade: setup() + :GitloomGraph command registration
  graph.lua      Git I/O, DAG construction, lane layout, glyph rendering
  listview.lua   Reusable virtualized list widget (snacks.win)
```

- **init.lua** — registers the `:GitloomGraph` user command (bound directly
  to `graph.open`) and exposes `setup(opts)`, which merges options into
  `M.config`. It is intentionally minimal.
- **graph.lua** — the bulk of the plugin. Owns everything from spawning git
  to producing styled display rows.
- **listview.lua** — a generic, incrementally-rendered list view. It knows
  nothing about git; it renders rows produced by a `display` callback and
  only materializes the visible range.

graph.lua is the only consumer of listview.lua. listview.lua is written to
be reusable in isolation.

## Data flow

```
:GitloomGraph
   │
   ▼
graph.open(opts)
   │  builds GraphOptions (defaults ⊕ opts)
   ▼
listview.open(listview_options)
   │  opens snacks float, installs decoration provider, calls on_controller
   ▼
on_controller(controller)
   │
   ├─ fetch_refs()               git for-each-ref heads/remotes/tags
   │      │  per ref: classify_ref → kind/name; resolve target hash to a
   │      │  Commit (placeholder if unseen); link Ref ↔ Commit; register
   │      ▼
   ├─ fetch_head()               git symbolic-ref → mark current branch (head Ref)
   │      │ (Future)
   │      ▼
   └─ fetch_commits()            git log --all --topo-order --parents
          │  per commit line:
          │    parse_commit_line → Commit
          │    merge into repo.commits (fills ref placeholders, keeps their refs)
          │    resolve parent hashes → Commit refs (+ child links, placeholders)
          │    append OrderItem to repo.order
          │    refresh_tracks(order, #order)   ← incremental lane layout
          │    controller.insert(order_item)   ← inserts a blank buffer line
          ▼
   (rendering is deferred)
```

Rendering is **pull-based**, driven by the decoration provider: when the
visible viewport changes, listview asks graph's `display` callback to lay out
just the rows on screen.

```
decoration provider (on_win, visible top..bottom)
   ▼
on_redraw(top, bottom)
   ├─ refresh_columns()   lazily compute each item's display columns,
   │                      track per-column max widths for alignment
   └─ display()           write real lines + extmark highlights + virt_lines
```

## graph.lua internals

### Git I/O

- `fetch_refs(repo)` — `git for-each-ref --format="%(objectname) %(refname)
  %(*objectname)" refs/heads refs/remotes refs/tags` (the deref hash resolves
  annotated tags).
- `fetch_head(repo)` — `git symbolic-ref --short --quiet HEAD` for the current
  branch.
- `fetch_commits(opts)` — `git log --topo-order --parents` with a
  `%x1f`-delimited pretty-format (`%H %P %an %ai %s`). No `--decorate`; refs
  are a separate query (specification.md §3).

All run via `vim.fn.jobstart` (no explicit `cwd`, so they observe Neovim's
working directory) and resolve a `Future` on `on_exit`. The controller chains
them refs → head → commits.

### Parsing / ref resolution

- `parse_commit_line(line)` — splits the `%x1f` fields into a `Commit`
  (hash, parent hashes, author, date, message; an empty `refs` list).
- `classify_ref(refname)` — maps a full refname to a `(kind, name)`:
  `refs/heads/*` → `local`, `refs/remotes/*` → `remote` (skipping the remote's
  `HEAD` symref), `refs/tags/*` → `tag`; nil for anything else.
- `add_ref` / `get_or_create_commit` — resolve a ref's target hash to a
  `Commit` (placeholder if unseen) and link them by reference.

`parse_commit_line` and `classify_ref` are pure and exposed via
`graph._internal` for testing.

### DAG construction

Commits are merged into `repo.commits` keyed by hash via
`get_or_create_commit`, so a commit first seen as a parent or ref target is a
placeholder later filled in by its log line (identity preserved; its refs are
kept). Parent hash strings resolve to `Commit` references; unseen parents get
a placeholder so the graph stays connected. Child links are populated on the
parent side. Refs are resolved the same way (a `Ref` holds a direct `Commit`
reference, and `Commit.refs` is the inverse).

### Lane layout (the core algorithm)

Each commit becomes an `OrderItem` with a `tracks` array describing the lanes
on that row. A `Track` is one vertical lane:

```
Track = { id, connectivity = {up,down,left,right}, has_commit, commit?, parent? }
```

`layout_item(opts, prev_tracks, item)` is the pure core: given the previous
row's carry-over lanes it returns `{ tracks, split?, merge?, carry }` without
mutating the item or touching the view. Both `build_graph` (from scratch) and
`refresh_tracks` (incremental) call it. Internally it produces the new lane
set from the previous row's lanes via:

- `handle_split_line` (optional) — when a commit has multiple children and
  `split_on_separate_line` is set, lanes fan in on a virtual line *above*.
- `handle_commit_line` — the commit row itself: continues passing-through
  lanes, places the commit glyph, and fans out new lanes for extra parents.
- `handle_merge_line` (optional) — when a commit has multiple parents and
  `merge_on_separate_line` is set, lanes fan out on a virtual line *below*.

These share a `TrackState` (`space_available`, `merge`/`split` bookkeeping,
`merge_id`). Lane identity (`id`) is allocated by a `get_next_id()` counter
and drives lane color; `reset_ids()` restarts the sequence so each
`build_graph` (and each opened graph window) is deterministic.

### Lane model (specification.md §5)

On top of the flat `Track` (one cell = one id + connectivity), `attach_lanes`
derives a `lanes: Lane[]` view per cell — the faithful model where each lane
is one wire (the edge child → parent) with its own connectivity. It runs per
rendered line against the line above it (column-aligned by track index):

- A cell's connectivity is decomposed into two-sided wires: a crossing →
  vertical + horizontal lanes; a tee → through lane + branch; a turn → one
  bent lane; straights/endpoints → one lane.
- **Handoff split:** if a cell's incoming (`up`) lane id — taken from the cell
  directly above — differs from its own (`down`) id, the up and down segments
  are *different* lanes (a child's split-in lane and a parent's merge-out lane
  sharing a column). They are modeled as two lanes rather than one conflated
  vertical, so per-lane continuity holds.

This is additive and behavior-neutral: the flat fields still drive the glyph
(its connectivity is the union of the cell's lanes' connectivity). Only the
*color* is sourced from the lanes, via `top_lane_id` (prefers the `down` lane
so a column reads continuously into the lane below) — a single cell shows one
color, so at a handoff the visual is best-effort while the model keeps both
lanes. The lane invariants (two-sided, connectivity-consistency,
leads-somewhere, per-lane continuity) are tested against this view.

### Rendering to glyphs

- `get_track_chars(opts, tracks)` — maps each track's connectivity to a
  box-drawing glyph (`│ ├ ┤ ┬ ┴ ╭ ╮ ╯ ╰ ─ ○ ◉ ◎` …) plus inter-lane
  horizontal connectors, coloring each by lane id against `palette.tracks`.
- `mirror_tracks(tracks)` — when `opts.mirror` is set, `get_track_chars` runs
  the cells through this first: it reverses the column order and swaps each
  cell's `left`/`right` connectivity. Because the glyph is a pure function of
  connectivity, the mirrored glyphs (`╭`↔`╮`, `┤`↔`├`, `╴`↔`╶`) and connectors
  fall out with no glyph-swap table, and color (lane id) is unchanged. It also
  tags the column `align = "right"` so the listview right-aligns it (padding on
  the left) — keeping vertical wires column-aligned across rows of differing
  lane counts. Render-only; the model rows are untouched (specification.md §5.4).
- `display_item(opts, item)` — assembles a `DisplayElement`: the commit line
  (date, author, graph glyphs, refs, message) plus optional `above`/`below`
  virtual lines for separate split/merge rows.

### Vendored helpers

- `make_future()` — a minimal promise used to chain the two git jobs.
- `compose(list)` / `highlight_text(text, hl)` — build styled text segments
  with offset-adjusted highlight ranges.

`compose` also exists in listview.lua; this duplication is intentional for
now (see "Self-contained by design").

## listview.lua internals

A reusable virtualized list widget over `snacks.win`.

- `M.open(opts)` — creates the float, a `model` (`items`, `columns`,
  `display`), and a `controller` (`insert`, `remove`, `move`, `refresh`).
  Installs a decoration provider that calls `on_redraw` for the visible range.
  Returns `{ win, controller }`.
- **In-place view updates** — `controller.refresh()` drops cached columns and
  re-renders the visible range. Two reflow patterns sit on top of it: a
  *display-only* change (e.g. the `i` lane-id toggle) just calls `refresh()`;
  a *layout* change (e.g. the `m` style cycle) first re-lays-out `repo.order`
  via `refresh_tracks` (mutating each item's tracks in place) then calls
  `refresh()`. Because there is one buffer line per commit (split/merge are
  virtual lines), neither adds or removes buffer lines — this is the
  reflow-without-reopen path the §10 interactive views (collapse / pin /
  toggle) will build on.
- **Lazy column computation** — `refresh_columns` computes an item's display
  columns (via `model.display`) only when first needed, and recomputes the
  shared per-column max widths used to align `above`/`line`/`below` fields.
- **Rendering** — `display` writes real buffer lines for the `line` field and
  attaches `above`/`below` as virtual lines (extmarks). Highlights are applied
  as extmarks. The buffer is briefly made modifiable around writes.
- **Width fitting** — `fix_width` pads/truncates a `DisplayItem` to a target
  display width (UTF-8 and display-width aware), clamping highlight ranges. A
  `DisplayItem` with `align = "right"` is padded on the left instead (highlight
  ranges shifted by the pad), used for the mirrored graph column.
- **virt_text chunks** — `build_virt_text_chunks` converts a `DisplayItem`
  into extmark `virt_text` chunks.

The buffer holds one (blank, then filled) line per item; all graph content
for `line` rows lives in the real buffer text, while split/merge rows are
virtual lines anchored to their commit.

## File layout

```
gitloom.nvim/
├── lua/gitloom/
│   ├── init.lua
│   ├── graph.lua
│   └── listview.lua
├── tests/
│   ├── minimal_init.lua
│   ├── refs_spec.lua
│   ├── commit_spec.lua
│   └── gitloom_spec.lua
├── Makefile
├── README.md
├── ARCHITECTURE.md
├── specification.md
└── CLAUDE.md
```
