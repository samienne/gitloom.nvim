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
- Layout (Phase 1) is `columns.layout(opts, items)` — a pure, deterministic
  pass that lays out an ordered item list from scratch. Two entry points wrap it:
  - `build_graph(opts, items)` — the from-scratch reflow primitive and the test
    entry point (just calls `columns.layout`).
  - `refresh_columns(opts, order)` — the production path: re-runs
    `columns.layout` over the live order and copies the fresh lines/lanes back
    onto each `OrderItem` in place (the view holds references). The lane layout
    with compaction is global, so it is a full rebuild rather than incremental.
- There is no view state yet. The view is a single fixed projection.

What remains for the target is **ordering ownership** (move ordering out of
`git log` into the builder) and a **view state** input (per-branch
visibility, pinned heads) that `columns.layout` reflows against. Phase 1 is
reused as-is; what changes is *what feeds it* — a filtered, possibly reordered
commit set instead of the raw git stream.

Commit attribution — deciding which commits "belong to" a branch being
collapsed or hidden when commits are shared across the DAG — is resolved by the
**reachability-signature** model (specification.md §10.2): per-commit signature
→ regions of equal signature → a display-mode join over each region's owners.
Owners are refs, plus anonymous non-first merge-parents, plus a *first-parent-
only* trunk owner (HEAD) whose coverage stops at every merge — which is what lets
the **first-parent focus** default (§10.7) show HEAD's mainline in full while
collapsing every branch merged into or diverging from it.

### OrderItem graphs as derived projections

`repo.commits` is the immutable commit graph (the source of truth). An
**OrderItem graph** — an ordered list of **DisplayNodes** plus their re-pointed
parent/child edges — is a *projection* of it, produced by `view.lua` (the
model→rows transform that feeds Phase 1) from `(commit graph, view state)`. Several OrderItem graphs may coexist over one commit graph (the
live projection, a recomputed one mid-reflow, future alternate views). A
**DisplayNode** is either a commit-backed item or a synthetic **collapsed
head** (`{tip, refs, count, region_hashes}`); `columns.layout` (Phase 1) is
unchanged — it lays out whatever DisplayNode DAG it is handed.

Consequences for the build:

- **Reflow swaps the graph** rather than mutating in place. The listview points
  at an OrderItem-graph value; a view-state change builds a fresh one and
  re-points. This supersedes `refresh_columns`' current copy-back-onto-existing-
  items path.
- **Caching split** to bound work (specification.md §10.5): `sig()` is cached
  against (DAG + owner set) and invalidated only by new commits or owner
  changes — *not* by mode toggles; the per-region join is recomputed cheaply on
  every toggle; contraction + `columns.layout` rebuild only when the display
  set actually changes.
- Row order is derived from the existing `git log --topo-order` by dropping
  hidden rows and contracting collapsed regions to their tip's position, so
  **ordering ownership is not a prerequisite** for branch modes.

What remains for the broader target is **ordering ownership** (move ordering
out of `git log` into the builder), still future.

## Layers

```
lua/gitloom/
  init.lua       Thin facade: setup() + :GitloomGraph command registration
  graph.lua      Git I/O, DAG construction, Phase 2 render, reachability, commit view
  view.lua       View builder: commit DAG + view state → OrderItem graph (spec §10)
  columns.lua    Phase 1: lane layout (lanes → columns + per-segment connectivity)
  color.lua      OKLCH↔sRGB conversion + golden-angle colour generation (§5.5)
  listview.lua   Reusable virtualized list widget (snacks.win)
```

- **init.lua** — registers the `:GitloomGraph` user command (bound directly
  to `graph.open`) and exposes `setup(opts)`, which merges options into
  `M.config`. It is intentionally minimal.
- **graph.lua** — the bulk of the plugin: git I/O, DAG construction, the
  window/keymap glue, Phase 2 rendering (`get_column_chars`), reachability, and
  the commit view.
- **columns.lua** — Phase 1, the lane-layout algorithm (`columns.layout`). Pure
  and git-agnostic; takes the ordered, DAG-wired commits and returns the rendered
  lines with per-segment connectivity.
- **color.lua** — pure colour maths: sRGB↔OKLab/OKLCH conversion and
  golden-angle colour generation for overflow lane colours (§5.5). No Neovim
  dependency; graph.lua realises its output into highlight groups.
- **listview.lua** — a generic, incrementally-rendered list view. It knows
  nothing about git; it renders rows produced by a `display` callback and
  only materializes the visible range.

graph.lua is the only consumer of columns.lua and listview.lua; both are
written to be reusable in isolation.

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
          │    refresh_columns(order)          ← Phase 1 relayout (columns.layout)
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
  `%x1f`-delimited pretty-format (`%H %P %an %at %ai %s`). `%at` (epoch) + `%ai`
  (offset) feed the parsed timestamp. No `--decorate`; refs are a separate query
  (specification.md §3).
- `fetch_commit_detail(hash)` — `git show -s --date=iso` with a `%x1f`-delimited
  format (`%H %an %ae %ad %cn %ce %cd %P %B`), buffered and resolved as one raw
  string. The on-demand source for the **commit view** (specification.md §11);
  it does not feed the graph model. The body `%B` is last so its embedded
  newlines stay in the final field.
- `fetch_commit_diff(hash)` — `git show --format= -p <hash>`, buffered and
  resolved as the raw patch string. The commit view's diff source (§11.3),
  fetched on demand and chained after `fetch_commit_detail`.

`git log` is porcelain, but an explicit `--pretty=format:` is a stable,
documented placeholder contract — the de-facto way to script this. The
plumbing-pure alternative (`git rev-list --no-commit-header`, same format) is a
one-line swap with no real gain today; revisit only if §10 takes over ordering.

All run via `vim.fn.jobstart` (no explicit `cwd`, so they observe Neovim's
working directory) and resolve a `Future` on `on_exit`. The controller chains
them refs → head → commits.

### Parsing / ref resolution

- `parse_commit_line(line)` — splits the `%x1f` fields into a `Commit`
  (hash, parent hashes, author, date, message; an empty `refs` list), with the
  date built by `parse_timestamp`.
- `parse_timestamp(epoch, iso)` — `%at` + `%ai` → `Timestamp { epoch, offset,
  raw }`. `format_absolute(ts, fmt)` renders author-local wall-clock (os.date in
  UTC mode over `epoch + offset`); `format_relative(ts, now)` renders an age.
  `format_date(ts, opts)` dispatches on `opts.date_mode`.
- `classify_ref(refname)` — maps a full refname to a `(kind, name)`:
  `refs/heads/*` → `local`, `refs/remotes/*` → `remote` (skipping the remote's
  `HEAD` symref), `refs/tags/*` → `tag`; nil for anything else.
- `add_ref` / `get_or_create_commit` — resolve a ref's target hash to a
  `Commit` (placeholder if unseen) and link them by reference.
- `group_refs(refs)` — for display: collapses branch refs (local + remote) that
  share a short name into one `RefGroup { name, has_local, remotes }`, keeping
  HEAD and tags separate. Drives the compact `(name ↑remotes)` rendering (§6).
- `parse_show(output)` — splits the `fetch_commit_detail` output (`%x1f` fields,
  body last) into a `CommitDetail { hash, author_name, author_email,
  author_date, committer_name, committer_email, committer_date, parents[], body
  }` for the commit view (specification.md §11).
- `format_commit_detail(detail, opts)` — renders a `CommitDetail` into the
  commit view's display lines (compose-style `{text, highlight}` rows). The
  committer block is emitted only when it differs from the author; `opts`
  carries the row's `decorations` (refs, reused from the model) and the
  `palette`. Pure; the window glue (`open_commit_view`) just writes its output.
- `format_diff(patch, palette)` — classifies each patch line by role (added,
  removed, hunk header `@@`, file header `diff --git`/`index`/`---`/`+++`/mode/
  rename/new-file; context uncolored) and returns one compose-style row per
  line, the whole line carrying the role's `palette.diff` group (§11.3). Pure.
- `diffstat_files(patch)` — parses the patch into a per-file list
  `{ path, added, removed, binary, start }` where `start` is the 1-based index
  (into the patch's split lines) of that file's `diff --git` line — the jump
  target. Counts `+`/`-` lines (skipping `+++`/`---`), shows renames as
  `old => new`, flags binary files (§11.4). Pure.
- `format_diffstat(files, palette)` — renders the diffstat: a summary row
  (`N files changed, …`) then one row per file (path, counts, colored `+`/`-`
  bar). Returns compose-style rows, summary first, files in `files` order, so
  the caller can map each file row back to its `diffstat_files` entry. Pure.
- `commit_range(commit)` — builds the `DiffRange` for a single commit's own
  changes: `{ rev = "<hash>^!"` (or `<empty-tree>..<hash>` for a root, no
  parents)`, from = parents[1], to = commit }`. The first range constructor for
  the external-diff provider (specification.md §11.5); graph range-selection will
  add more. Pure.

- `reachable_cone(order, pivot_index, top, bottom)` — the pivot's causal cone
  (specification.md §12.1): two monotonic sweeps from `order[pivot_index].commit`
  — one following `parents` (ancestors), one following `children` (descendants) —
  bounded to commits in the visible rows `top..bottom`. Returns a
  `table<Commit, true>` set (pivot included). Pure (no view/IO); the window
  bound and the parent-always-below-child topological order make it exact for
  relationships between on-screen commits.

`parse_commit_line`, `parse_timestamp`, `format_absolute`, `format_relative`,
`classify_ref`, `group_refs`, `parse_show`, `format_commit_detail`,
`format_diff`, `diffstat_files`, `format_diffstat`, `commit_range`, and
`reachable_cone` are pure and exposed via `graph._internal` for testing.

### DAG construction

Commits are merged into `repo.commits` keyed by hash via
`get_or_create_commit`, so a commit first seen as a parent or ref target is a
placeholder later filled in by its log line (identity preserved; its refs are
kept). Parent hash strings resolve to `Commit` references; unseen parents get
a placeholder so the graph stays connected. Child links are populated on the
parent side. Refs are resolved the same way (a `Ref` holds a direct `Commit`
reference, and `Commit.refs` is the inverse).

### Lane layout — Phase 1 (`columns.lua`)

The graph is built as a **two-phase pipeline**:

- **Phase 1** (`columns.lua`, `columns.layout`) owns lane placement. It assigns
  lanes to columns and emits, per rendered line, the connectivity of every
  **Segment** in every **GraphColumn** — one Segment per drawn edge, each with
  its own connectivity. It does *not* pick glyphs or colours.
- **Phase 2** (`get_column_chars`, in graph.lua) renders glyphs and colour from
  those Segments (below).

The model:

```
Lane        = { id, begin (child Commit), parent (Commit), highlighted }
Segment     = { connectivity = {up,down,left,right}, edges = Lane[], id, begin, parent }
GraphColumn = { connectivity, lanes = Segment[], has_commit, commit?, id, … }
```

A **Lane** is one edge child→parent — a *persistent object* that lives from the
child's row down to the parent's row. Reusing the same object across rows is
what makes vertical continuity hold by construction (same id up and down). A
Segment usually draws one Lane; the shared trunk wire at a fan hub draws several
(see descent/ascent below).

`columns.layout(opts, items)` sweeps the order **top-to-bottom**, carrying one
piece of state: `active`, a map `column → Lane` of the lanes flowing *down* into
the current row. For each commit `C`:

1. **Classify** `active`: lanes whose `parent == C` are **incoming** (its child
   edges, terminating here); the rest are **survivors** (pass-throughs).
2. **Commit column `cc`** = the leftmost incoming column, or the leftmost free
   column for a tip. A column a **root** (no-parent commit) occupied on the
   previous row is **blocked** for this row — tip placement, compaction targets,
   and fresh fan-out columns all skip it — so an independent history does not
   stack directly under a root (the "root column break" invariant). The block
   lasts one row, so consecutive stacked roots simply alternate columns.
3. **Outgoing** = one Lane per parent. The first parent **reuses the trunk
   child's id and colour** (so a straight chain keeps one colour); a fresh id and
   a free-list colour slot are taken only where a lane is born — a branch head (a
   tip's first parent) and every extra parent of a merge. Colours come from a
   recycling **free list** seeded with `palette.tracks`: a born lane takes a slot
   from the front, an ended lane returns its slot to the back (FIFO). New lanes
   allocate *before* the line's ended lanes return their slots, so concurrent
   lanes always differ in colour while slots last. A returned slot is recycled
   with a **cooldown** (`palette.buffer` allocations) for breathing room; if the
   front of the list hasn't cooled when a lane is born, a **generated** slot (id
   `> #tracks`) is minted instead. Curated slots are used first; a *generated*
   slot is **retired** (dropped) once the list is comfortably full again, so a
   calmed graph drifts back to the curated palette.
   Without generation (no truecolor), exhaustion instead **shares** a curated
   slot, reference-counted so it returns only when its last holder ends.
4. **Compaction**: each survivor shifts left into the leftmost *row-start* gap
   (drawn as a horizontal turn), never a column another lane vacates this same
   row — that is what keeps two turns out of one cell, so freed columns are
   reclaimed over a ripple.
5. **Emit Segments** for the split line (children converge, when
   `split_on_separate_line`), the commit line (the marker + first-parent handoff
   + inline fans), and the merge line (parents fan out, when
   `merge_on_separate_line`). On a separate split/merge line the single
   descent-into / ascent-out of the commit is one **multi-edge Segment** carrying
   every converging/diverging edge, so a non-trunk cone lane stays connected
   through the hub.
6. **Advance** `active` to the out-columns for the next row, and attach the
   `parent_lanes`/`child_lanes` to the `OrderItem` for reachability.

Per-column well-formedness (validated by the tests): at most one vertical
(`up+down`) Segment and at most one *turning* Segment; the exception is
`allow_merge_on_split`, which permits the two-turn cell where an extra parent
reuses a freed merge column. Empty columns are allowed.

`build_graph(opts, items)` lays out a whole ordered list from scratch (the test
entry point and the reflow primitive); `refresh_columns(opts, order)` re-runs
`columns.layout` over the live order and copies the fresh lines/lanes back into
the existing `OrderItem`s (the view holds references). Both go through
`columns.layout` — there is no separate incremental algorithm.

### Future direction: layout policies and lookahead (not yet built)

This is a recorded design intent, **not** implemented. Today there is one
layout algorithm. The note exists so that *if* we add alternative layout modes
(below), we already agree on the shape; until then the current single-pass code
stays as-is. Do not refactor toward this speculatively — revisit it when a
second algorithm is actually wanted.

**What varies by mode, and what never does.** Reading `columns.layout`'s
per-commit loop, the steps sort cleanly into two buckets:

- *Mode-invariant machinery* — lane lifecycle (id/trunk reuse,
  `parent_lanes`/`child_lanes`), the colour free list, DAG classification
  (incoming / survivors / outgoing), and Segment emission
  (`new_line`/`draw`/`assemble` + the continuity validation). All driven by the
  *DAG*, never by where a lane is drawn.
- *Mode-specific policy* — **only** the column-placement decisions: the commit
  column `cc`, the survivor compaction, the outgoing fan-out assignment (incl.
  the `allow_merge_on_split` freed-column reuse), and the occupancy/blocking
  model.

So alternative layouts are not separate algorithms reusing shared pieces; they
are **one driver with a replaceable placement policy**. The seam is a pure
function:

```
place(ctx) -> { cc, survivor_cols, outgoing_cols, blocked_next }
   ctx = { active (col -> lane), incoming, survivors, outgoing, blocked,
           opts, hints? }
```

The driver does lifecycle + colour + emission and calls `place`; today's
behaviour becomes the default `compact` policy. This is **functional core,
imperative shell**: purify the part that varies (placement), and leave the
inherently-stateful lifecycle (persistent Lane objects threaded row-to-row, the
colour FIFO) as the shell — threading those through pure functions buys nothing.
Decoupling lane id/colour from column placement (they are already DAG-driven,
not column-driven) is what makes a placement policy expressible in isolation,
and is the prerequisite for the lookahead work below.

**Candidate modes.**

- *Spread* — keep empty columns between occupied ones, with a restoring
  "pressure" pulling lanes back toward the boundary. Static slack: a free
  neighbour is usually nearby, so crossings are cheap to avoid locally. A local
  policy; needs no lookahead.
- *Lookahead crossing-minimization* — anticipate an incoming fan (e.g. an
  octopus merge several rows below) and **make space early**, spreading the
  horizontal travel over many rows (gentle diagonals) instead of one sharp cut
  at the fan row. The current algorithm cannot do this: every decision sees only
  the current `active` lanes and the current commit's parents — it is online,
  greedy, single-pass.

  Lookahead still fits the seam **without** breaking single-pass control flow:
  add a mode-independent **annotation pass** that runs once and precomputes
  forward-looking hints (lane lifespans = the row each lane's parent lands on;
  upcoming fan widths; near-term column demand), fed into `ctx.hints`. A greedy
  policy ignores `hints`; a lookahead policy consumes them. So lookahead is
  "what is in `ctx`", not new control structure.

Spread and lookahead are the same spectrum — spread is *static* slack, lookahead
is *dynamic* anticipation — and may combine (spread + a small lookahead window).

**Hard constraints that bound the ambition.**

- *Streaming* — commits arrive incrementally from `jobstart`; you cannot look
  past the stream frontier (those commits are not loaded). Lookahead must be
  **bounded to a window** of already-known rows, not global.
- *Reflow stability* — the planned interactive views (§10: collapse / pin /
  toggle *with reflow*) rerun layout and must stay predictable: a small input
  change must not reshuffle the whole graph. Global crossing-minimization
  (iterative barycenter/median, Sugiyama-style) is both expensive and jumpy.
  Prefer **bounded, local heuristics**.
- *Determinism* — layout must be deterministic for stable rendering and testing
  (no randomness).

**Testing.** The invariant harness (`graph_helpers.lua`) tests *correctness*
(wires connect, continuity). Crossing minimization is *quality*, so it needs a
new kind of test: a **crossing counter** over the rendered grid, asserting a
smart policy yields ≤ the greedy policy's count on the same DAGs (a comparative
quality test) **while** the existing invariants still hold (a smart layout must
still be a *valid* layout). The grid-building fuzz harness already exists, so the
counter is a natural addition and doubles as a quality regression guard.

**Sequencing, when we do this.** (1) Extract the placement-policy seam with
current behaviour as `compact`, proven behaviour-preserving by the fuzz suite.
(2) Add `spread` — a local policy, no lookahead — as the second real consumer
that validates the seam's shape. (3) Add the `annotate` pass + a bounded
lookahead policy last, against a seam already proven by a real second consumer.
Steps 1–2 are behaviour-preserving refactors (within spec); step 3 introduces
new layout behaviour and needs a specification.md §5 amendment first.

### Rendering to glyphs — Phase 2

- `get_column_chars(opts, columns, emphasis)` — maps each `GraphColumn` to a
  box-drawing glyph (`│ ├ ┤ ┬ ┴ ╭ ╮ ╯ ╰ ─ ○ ◉ ◎` …) plus inter-lane horizontal
  connectors. The glyph's connectivity is the **union of the highlighted
  Segments'** connectivity (or of *all* Segments when none is highlighted), so an
  out-of-cone arm of a junction drops to a small gap while the cone arm stays; a
  vertical crossing is kept whole. Colour comes from a highlighted Segment's
  Lane when present (the cone colour wins), else the Segment's own colour slot
  (assigned in Phase 1's free list, not `id mod #tracks`). A slot `≤ #tracks`
  indexes `palette.tracks`; a slot beyond that is a **generated** colour, an
  OKLCH hue realised lazily by `gitloom.color` into a cached `GitloomGen_*`
  highlight group (same pattern as `dim_hl`, rebuilt on `ColorScheme`; §5.5). The
  generated colours' lightness/chroma anchor is derived once from the curated
  `tracks` (or `Normal`).
- `mirror_columns(columns)` — when `opts.mirror` is set, `get_column_chars` runs
  the cells through this first: it reverses the column order and swaps each
  cell's `left`/`right` connectivity. Because the glyph is a pure function of
  connectivity, the mirrored glyphs (`╭`↔`╮`, `┤`↔`├`, `╴`↔`╶`) and connectors
  fall out with no glyph-swap table, and colour (lane colour slot) is unchanged. A
  horizontal connector is colored by the lane its run terminates at (found by
  scanning past pass-through crossings/jumps); that destination is to the right
  normally but to the **left** once the cells are reversed, so the scan flips
  direction under mirror — otherwise the connector is miscolored. It also tags
  the column `align = "right"` so the listview right-aligns it (padding on the
  left) — keeping vertical wires column-aligned across rows of differing lane
  counts. Render-only; the model rows are untouched (specification.md §5.4).
- `display_item(opts, item)` — assembles a `DisplayElement`: the commit's real
  line(s) plus optional `above`/`below` virtual rows for separate split/merge
  lines. How the ref decorations are placed depends on `opts.label_mode`
  (spec §6.1): in `right` (default) they go in `line_right`, which the listview
  pins to the right edge; in `inline` they are composed into the flex column
  before the message; in `dual` a **labelled** commit emits **two real rows**
  (`DisplayElement.lines`): the first is the normal graph line (node) with the
  labels left-aligned in the flex column, the second is a **message row** whose
  graph column is `passthrough_columns(item.columns, "down")` — a vertical-only
  projection of the commit's lanes that continues every down-going lane as a `│`
  (no node), carrying the same edges so §12 dimming still applies. A `dual` commit
  with no labels stays a single row. `B` cycles the mode.
- `passthrough_columns(columns, dir)` — builds a vertical-only `GraphColumn` per
  input column (`dir = "up"` keeps lanes entering from above, `"down"` lanes
  leaving below; the rest blank), reused through `get_column_chars` for
  glyphs/colour/dimming and mirroring. `down` is the dual-mode message row.

### Selection and navigation

The graph window uses `cursorline` as the current-row indicator and **parks the
cursor** at the commit message — or on the selected ref — rather than hiding it
(specification.md §2/§7). Parking is robust across terminals where cursor-hiding
(`guicursor` blend) is unreliable.

A `SelectionState { commit, index }` (held by commit *identity*, so it survives
reflow) tracks the selection. `index` is `nil` for the **message** (the default)
or `1..N` for a ref decoration. Refs are pinned to the right edge, so `l`
(dir +1) moves right onto the refs starting at the first and `h` (dir -1) moves
left back to the message; `move_selection(pos, count, dir)` is the pure
clamp-step (no wrap). In the `dual` label mode a labelled commit occupies two
real buffer lines: the label row (node + refs) and the message row. The graph
keeps `repo.order` 1:1 with commits, so it translates a buffer line to its order
index through the listview (`controller.item_at`) and remembers which sub-row the
cursor is on; `place_cursor` parks on the selected ref on the label row (now a
real line, so the cursor sits physically on it) and on the message on the message
row. The `CursorMoved` handler pre-selects index `1` when it lands on a labelled
commit's label row.

`decoration_texts(commit)` is the single source for the decoration strings
(branch groups then tags), so `display_item` (rendering + the `palette.selected`
highlight) and the cursor target use byte-identical text. `place_cursor` parks
the cursor: for a selected ref it finds the decoration in the rendered line via
`ref_byte_col` (refs are pinned to the right edge, so their column is not
fixed); otherwise it parks at the message via `controller.col_offset(line,
"line", FLEX_COL)`. A `CursorMoved` autocmd resets the selection to the message
and re-parks on row change; the `m`/`M`/`d`/`i` toggles re-park after their
refresh since column widths shift. Selection counts all decorations, so one
hidden in the `+N` overflow can be selected but parks at the message until
visible. This is the selection substrate for the §10 per-branch actions;
nothing acts on it yet.

### Commit view

`<CR>` opens the commit view (specification.md §11) for the commit on the
current row. `open_commit_view(opts, commit)` is the runtime glue: it opens a
`snacks.win` float (same geometry as the graph window), chains
`fetch_commit_detail(commit.hash)` then `fetch_commit_diff(commit.hash)`, and on
resolution renders the diff **action label** (when a provider is configured;
§11.5), then the metadata (`format_commit_detail`), then the diffstat
(`format_diffstat`), then the diff (`format_diff`) into the buffer (real lines +
namespaced extmark highlights, then made read-only). The cursor is parked on the
action label after render. `q` closes it. The pure
pieces — `parse_show`, `format_commit_detail`, `format_diff`, `diffstat_files`,
and `format_diffstat` — are unit-tested; only the window/IO glue is not. The
refs in the view come from the row's commit (`decoration_texts`), not a
re-query. The diff highlights are applied as extmarks rather than
`filetype=diff`, so the metadata header stays unaffected (§11.3).

While assembling the rows it records, for each changed file, the buffer line of
its diffstat row and the buffer line where its diff section begins
(`diff_start + start - 1`, from `diffstat_files`). A buffer-local `<CR>` mapping
looks up the cursor's line in that map and jumps to the file's diff section,
scrolling it to the top (§11.4). The jump is performed with the `G` motion (a
jump command) rather than `nvim_win_set_cursor`, so the diffstat position is
pushed onto the jumplist and the built-in `<C-o>` / `<C-i>` move between the
diffstat and the diff. The map is keyed by buffer line, so it is robust to the
diffstat's variable height.

`<C-o>` is itself remapped in the view: it inspects `getjumplist()` and, when the
entry it would visit (`list[curidx]`, or none) is not in the view's buffer,
closes the float instead of jumping into the graph buffer — otherwise it replays
a real `<C-o>`. So `<C-o>` walks back through the view's own jumps and then backs
out of the view entirely (§11.4).

The action label's buffer line maps (like the diffstat file rows) to an action;
`<CR>` on it calls the diff provider. So the commit view's `<CR>` dispatches by
cursor line: action label → open diff, diffstat file row → jump, else nothing.

### External diff

gitloom delegates rich diffs to an external plugin via a pluggable provider
(specification.md §11.5), so it carries no diff renderer of its own.
`open_diff(opts, commit)` builds a `DiffRange` with the pure `commit_range`
constructor and calls `opts.diff.open(range)`. The default `open`
`require`s diffview first (so a lazy-loaded diffview registers its command),
then runs `:DiffviewOpen <range.rev>` guarded by `vim.fn.exists(":DiffviewOpen")`
(it notifies when diffview is absent rather than erroring), so diffview is optional;
overriding `diff.open`/`diff.label` swaps in another plugin. Two call sites use
it: the graph's `D` key (commit under the cursor) and the commit view's action
label. Because the provider takes a *range*, future graph-side multi-commit
selection adds new range constructors (e.g. `range_between(a, b)`) without
touching the provider or the call sites.

### Reachability emphasis

The pivot's cone (specification.md §12) drives a dimming pass over the visible
rows, walking the **Lane graph** (no flood, no id heuristics):

- `mark_reachable(order, pivot_index, top, bottom)` walks the Lanes from the
  pivot: follow `parent_lanes` (ancestors), then `child_lanes` (descendants),
  setting `highlighted` on each Lane reached and `active` on each cone commit's
  marker (others dim). It first **resets** every Lane *drawn* in the window (via
  each Segment's edges, so a pass-through whose endpoints are off-window is
  cleared too) since Lanes persist across frames. It returns the cone commit set,
  which also drives the **row-field** dimming (date/author/message/refs) in
  `display_item`. Each Lane is one edge, so the walk is **exact**: a sibling
  sharing a fan is a distinct Lane and never lights. Bounded to the visible rows.
  Lanes are attached by Phase 1 (`columns.layout`), so no separate build step is
  needed.
- `get_column_chars(opts, columns, emphasis)` renders the cone by unioning the
  highlighted Segments' connectivity (above) and dims everything out-of-cone:
  a glyph whose top Segment draws no highlighted edge, the commit marker by the
  column's own `active`, and a connector whose run carries no highlighted edge.
  `emphasis` is false when the toggle is off or there is no pivot, so everything
  renders lit.
- `reachable_cone` (above) remains a pure helper (commit-set only) with its own
  property tests; the production path uses `mark_reachable` (which subsumes it).
  `update_cone` just calls `mark_reachable` over the visible window.
- `dim_hl(opts, group)` returns a dimmed derivative of a highlight group:
  it resolves the group's `fg`, blends it toward `Normal`'s `bg` by
  `palette.dim` (default `0.45`), and defines a cached `GitloomDim_<group>`
  group with that colour. Cached per `(group, factor)`; a `ColorScheme` autocmd
  clears the cache (the derived groups are wiped by `hi clear`) and refreshes.
  Without `termguicolors` it returns a flat `NonText` fallback.

`display_item` dims the row's non-lane fields (date, author, message, refs)
through the `rh` helper (which dims a field's group, or a group-less field's
default `Normal` foreground) when the row's commit is outside the cone, and
passes `emphasis` to `get_column_chars` for the lanes. With no pivot (or the
toggle off) `emphasis` is false, so streaming and the pre-pivot state render lit.
The cone is recomputed (`mark_reachable` over the window, then a listview
refresh) on row change (`CursorMoved`) and on scroll (`WinScrolled`), both
**debounced** (~60ms — only the last, once the cursor settles, does the walk, so
held `j`/`k` stays responsive); the `m` reflow, the `H` toggle, and stream
completion recompute immediately.

### Vendored helpers

- `make_future()` — a minimal promise used to chain the two git jobs.
- `compose(list)` / `highlight_text(text, hl)` — build styled text segments
  with offset-adjusted highlight ranges.

`compose` also exists in listview.lua; this duplication is intentional for
now (see "Self-contained by design").

## listview.lua internals

A reusable virtualized list widget over `snacks.win`.

- `M.open(opts)` — creates the float, a `model` (`items`, `columns`,
  `display`), and a `controller` (`insert`, `remove`, `move`, `refresh`,
  `relayout`, `item_at`). Installs a decoration provider that calls `on_redraw`
  for the visible range. Returns `{ win, controller }`.
- **Multi-line items** — an item may render more than one **real** buffer line
  (the dual label mode's labelled commits are two: label row + message row). A
  cheap `line_count(data)` callback (no `DisplayElement` build — it reads only the
  data and current mode) gives each item its real-line count, and the model keeps
  a prefix-sum `starts` map (item → first buffer line) plus the inverse
  `item_at(buffer_line)`. `repo.order` stays 1:1 with items; only this map turns a
  buffer line into an order index. `DisplayElement.lines` (a list of real rows)
  generalises `line` (one row); a `DisplayElement` with both is read as `lines`.
  `relayout()` recomputes the counts, resizes the buffer to the new total, rebuilds
  `starts`, and redraws — used when a mode toggle changes line counts (`B`); the
  count is known at `insert` time because refs resolve before the commit stream,
  so streaming allocates the right number of blank lines up front.
- **In-place view updates** — `controller.refresh()` drops cached columns and
  re-renders the visible range. Two reflow patterns sit on top of it: a
  *display-only* change (e.g. the `i` lane-id toggle) just calls `refresh()`;
  a *layout* change (e.g. the `m` style cycle) first re-lays-out `repo.order`
  via `refresh_columns` (Phase 1, mutating each item's columns in place) then
  calls `refresh()`; a *count* change (the `B` label-mode cycle, which turns a
  labelled commit into two real lines or back) calls `relayout()` to resize the
  buffer. The `m`/`M`/`d`/`H`/`i` toggles never change line counts, so they stay
  on `refresh()`. This is the reflow-without-reopen path the §10 interactive views
  (collapse / pin / toggle) will build on.
- **Lazy column computation** — `refresh_columns` computes an item's display
  columns (via `model.display`) only when first needed, and recomputes the
  shared per-column max widths used to align `above`/`line(s)`/`below` fields. The
  `flex` column is excluded from that max (it sizes per row, not by alignment) —
  in every field, since the dual-mode message row carries its message in the flex
  column and the labels share it on the label row.
- **Stacked virtual rows** — `above`/`below` are each a **list of rows** (every
  row a column array), so a single buffer line can carry several stacked virtual
  lines (e.g. split + the `down` continuation are separate concerns; split/merge
  fan lines remain here). A row whose only content is a single column array is
  just a one-row list.
- **Flex column + right-pinned items** — `build_line` lays out the `line` field:
  columns before `model.flex` are fixed (aligned); the flex column fills the
  remaining window width (truncated with `…`); and the row's `line_right` items
  (e.g. refs) are packed against the **right edge** by `pack_right`. The refs
  may use the free width, reserving only what the flex column needs — its
  natural width, capped at `message_min` — so refs fill empty space yet a long
  message keeps its floor; the leftover collapses into a `+N` marker. This is
  per-row, not an aligned column, so navigation stays line-by-line (spec §6).
- **Rendering** — `display(win, …)` writes each item's real line(s) at its mapped
  buffer offset (`starts`) and attaches the `above`/`below` rows as virtual lines
  (above the item's first real line, below its last) within one extmark per real
  line (`virt_lines` holding the stacked rows). It takes the window (not just the
  buffer) because the flex/right layout needs its width.
- **Width fitting** — `fix_width` pads/truncates a `DisplayItem` (or a plain
  string, normalised to one — the `above`/`below` lines mix string spacers with
  items) to a target display width (UTF-8 and display-width aware), clamping
  highlight ranges; with `ellipsis` it appends `…` when truncating. A
  `DisplayItem` with `align = "right"` is padded on the left instead (highlight
  ranges shifted by the pad), used for the mirrored graph column. The per-column
  max widths it aligns against are driven by the `above`/`below`/`line` fields
  (`refresh_columns`).
- **Cursor offset** — `controller.col_offset(buffer_line, field, j)` returns the
  byte offset where column `j` starts on that buffer line (resolving the line to
  its item and sub-row, then summing the fixed columns before `j`), used by graph
  to park the cursor at the message or a label.
- **virt_text chunks** — `build_virt_text_chunks` converts a `DisplayItem`
  into extmark `virt_text` chunks.
- **Lazy snacks** — `snacks.win` is required lazily; only `create_win` errors if
  it is missing, so the pure helpers (e.g. `pack_right`) load under test without
  it. `pack_right` is exposed via `listview._internal` for testing.

The buffer holds each item's blank-then-filled real line(s); graph content for
the real rows lives in the real buffer text, while the split/merge fan lines stay
virtual lines anchored to the item. An item is one real line everywhere except a
labelled commit in `dual` mode (two real lines). `repo.order` stays 1:1 with
*items* (commits); the listview's `starts`/`item_at` map turns a buffer line into
that order index, so the navigation/cone math keeps working in order-index space.

## File layout

```
gitloom.nvim/
├── lua/gitloom/
│   ├── init.lua
│   ├── graph.lua
│   ├── view.lua           View builder: projection under view state (§10)
│   ├── columns.lua        Phase 1 lane layout
│   ├── color.lua          OKLCH colour generation (§5.5)
│   └── listview.lua
├── tests/
│   ├── minimal_init.lua
│   ├── refs_spec.lua / selection_spec.lua / commit_spec.lua / commit_view_spec.lua
│   ├── reachability_spec.lua / view_spec.lua
│   ├── columns_spec.lua / graph_layout_spec.lua / graph_mirror_spec.lua
│   ├── graph_helpers.lua  Invariant checker for the layout tests
│   ├── gitloom_spec.lua
│   └── types/luassert.lua ---@meta stub for lua-language-server
├── .luarc.json            lua-language-server config (see `make lint`)
├── Makefile
├── README.md
├── ARCHITECTURE.md
├── specification.md
└── CLAUDE.md
```
