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

The model and rendering layers exist; the view-state and view-builder layers
do not yet:

- The repository model exists as `repo.commits` (an identity-stable DAG), but
  **ordering is currently seeded from `git log --topo-order`**, and layout is
  computed *incrementally* as commits stream in (`refresh_tracks` appends to
  `repo.order`).
- There is no view state and no from-scratch reflow. The view is a single
  fixed projection.

The refactor toward the target moves ordering ownership out of `git log` and
into a view builder that recomputes the full ordered row set (and its lane
layout) from the model plus a view state. The existing lane algorithm
(`handle_commit_line` / `handle_merge_line` / `handle_split_line`) is the core
of that builder and is reused as-is; what changes is *what feeds it* — a
recomputed, filtered, possibly reordered commit set instead of the raw git
stream.

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
   ├─ fetch_branches()           git for-each-ref refs/heads  → repo.branches/heads
   │      │ (Future)
   │      ▼
   └─ fetch_commits()            git log --all --topo-order --parents --decorate=full
          │  per commit line:
          │    parse_commit_line → Commit
          │    merge into repo.commits (identity-preserving)
          │    resolve parent hashes → Commit refs (+ child links, dummy parents)
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

- `fetch_branches(opts)` — `git for-each-ref --format="%(refname:short) %(objectname)" refs/heads`.
- `fetch_commits(opts)` — `git log --remotes --topo-order --decorate=full --parents`
  with a `%x1f`-delimited pretty-format (`%H %P %an %ai %s %D`).

Both run via `vim.fn.jobstart` (no explicit `cwd`, so they observe Neovim's
working directory) and resolve a `Future` on `on_exit`. Output is parsed
line-by-line in `on_stdout`.

### Parsing

- `parse_commit_line(line)` — splits the `%x1f` fields into a `Commit`
  (hash, parent hashes, author, date, message, parsed refs).
- `parse_refs(str)` — parses the `%D` decorate field into `branches`, `tags`,
  `symbols` (`HEAD -> ...`), and `raw` (unrecognized).

Both are pure and exposed via `graph._internal` for testing.

### DAG construction

In the `fetch_commits` `on_item` callback, commits are merged into
`repo.commits` keyed by hash (so a commit seen first as a parent placeholder
is later filled in — identity is preserved). Parent hash strings are resolved
to `Commit` references; unseen parents get a dummy `Commit` so the graph is
always connected. Child links are populated on the parent side.

### Lane layout (the core algorithm)

Each commit becomes an `OrderItem` with a `tracks` array describing the lanes
on that row. A `Track` is one vertical lane:

```
Track = { id, connectivity = {up,down,left,right}, has_commit, commit?, parent? }
```

`refresh_tracks` walks the order from a start index, and for each item
`handle_commit_item` produces the new lane set from the previous row's lanes:

- `handle_split_line` (optional) — when a commit has multiple children and
  `split_on_separate_line` is set, lanes fan in on a virtual line *above*.
- `handle_commit_line` — the commit row itself: continues passing-through
  lanes, places the commit glyph, and fans out new lanes for extra parents.
- `handle_merge_line` (optional) — when a commit has multiple parents and
  `merge_on_separate_line` is set, lanes fan out on a virtual line *below*.

These share a `TrackState` (`space_available`, `merge`/`split` bookkeeping,
`merge_id`). Lane identity (`id`) is allocated by a module-global
`get_next_id()` counter and drives lane color.

### Rendering to glyphs

- `get_track_chars(opts, tracks)` — maps each track's connectivity to a
  box-drawing glyph (`│ ├ ┤ ┬ ┴ ╭ ╮ ╯ ╰ ─ ○ ◉ ◎` …) plus inter-lane
  horizontal connectors, coloring each by lane id against `palette.tracks`.
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
  `display`), and a `controller` (`insert`, `remove`, `move`). Installs a
  decoration provider that calls `on_redraw` for the visible range.
- **Lazy column computation** — `refresh_columns` computes an item's display
  columns (via `model.display`) only when first needed, and recomputes the
  shared per-column max widths used to align `above`/`line`/`below` fields.
- **Rendering** — `display` writes real buffer lines for the `line` field and
  attaches `above`/`below` as virtual lines (extmarks). Highlights are applied
  as extmarks. The buffer is briefly made modifiable around writes.
- **Width fitting** — `fix_width` pads/truncates a `DisplayItem` to a target
  display width (UTF-8 and display-width aware), clamping highlight ranges.
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
