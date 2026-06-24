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
  **gitloom owns the row ordering**: commits are read without an ordering flag
  and `order_commits` runs its own topological sort (spec §3.1).
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
collapsing every branch merged into or diverging from it. The trunk is the
single-anchor case of the **pin** axis (spec §10.6): pinning generalises it to a
*set* of anchor owners — each defaults normal, everything else collapsed — which
the planned context panes also fold off-screen topology onto.

### OrderItem graphs as derived projections

`repo.commits` is the immutable commit graph (the source of truth). An
**OrderItem graph** — an ordered list of **DisplayNodes** plus their re-pointed
parent/child edges — is a *projection* of it, produced by `view.lua` (the
model→rows transform that feeds Phase 1) from `(commit graph, view state)`. Several OrderItem graphs may coexist over one commit graph (the
live projection, a recomputed one mid-reflow, future alternate views). A
**DisplayNode** is either a commit-backed item or a synthetic **collapsed
head** (`{tip, refs, count, region_hashes}`); `columns.layout` (Phase 1) is
unchanged — it lays out whatever DisplayNode DAG it is handed.

**Marker packing** (spec §10.4) is a post-Phase-1 pass over the laid-out rows:
adjacent *marker* rows (collapsed heads — messageless nodes) that are
overlay-compatible (no column has two nodes or two different lanes; lanes stay
continuous) merge into one **marker-group** OrderItem carrying several markers'
nodes on one line. Compaction makes only the safe merges compatible (a turn
between two rows breaks continuity, so they won't merge). `columns.layout` and
the listview's one-item-per-line model are unchanged — the group is one item; the
packed grid is validated by the same wires-connect checker the layout uses.

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
- Row order is derived from gitloom's owned topological sort (`order_commits`,
  §3.1) by dropping hidden rows and contracting collapsed regions to their tip's
  position.

**Ordering ownership** is now in place: commits are read without an ordering
flag and `order_commits` (graph.lua) runs the topological sort that produces
`repo.order` (spec §3.1). This also underpins **resync** (§3.4): an in-place
history refresh appends new commits, prunes unreachable ones, and re-sorts.

### Context panes (header / footer)

The header/footer context panes (spec §6.2) summarise off-screen topology folded
onto the pinned anchors. **Both are built**, and both are **focused rebuilds** —
each reconstructs a small sub-DAG of *only* the lanes crossing the cutoff (plus the
pinned anchors), never the whole off-screen graph. The **footer** continues the
seam lanes **down** their first-parent chains to the roots and lays them out with
`columns.layout`; the **header** mirrors it **up** and lays the result out with a
bespoke seam-up grid. `pane.lua` is the pure, window-agnostic core; `update_panes`
in graph.lua does the windowing.

**The footer pipeline** (`update_panes`, gated by `opts.panes`), per scroll:

1. **Seam by screen rows.** The footer is a **borderless overlay** over the
   bottom rows of the main window (relative="win") — the sticky-scroll pattern,
   so its lanes butt directly against the seam with no border between. The seam
   is the screen row just above the overlay (`seam_for` = window position +
   height − overlay height). `boundary_at(target)` then reads the **down-lanes of
   whichever *rendered line*** sits at that screen row — a commit's columns line,
   or its split/merge **virtual** line (found via `screenpos`, since a fan has no
   buffer line of its own). This is what makes the cutoff correct across all
   merge styles.
2. **Continue only the active lanes.** `pane.continue(boundary, anchors, extra)`
   walks each boundary lane's **first-parent chain** down to a root, plus any
   pinned-ref tips below the cutoff (`extra`) so a divergent pinned branch still
   shows. Lanes converge at the commits where they actually meet; every lane
   reaches a root (never dangling); a merge's second parent is never followed, so
   **no non-active branch is introduced**.
3. **Condense + render.** `pane.condense` contracts each linear stretch to an
   edge, keeping only ref heads (`◍` markers — anchor refs only), fork/merge
   **junctions** (node-less join glyphs), and roots/tips (real nodes); `node_of`
   maps every member hash to its node. `columns.layout` lays it out in compact
   mode (`pane_opts`: inline joins), the lanes seeded from the boundary; it's
   rendered topology-only, **dashed** (┊ / ╌, junctions solid), aligned under the
   main graph, with a `┊` separator marking the seam. Height grows to a fixed
   point and is capped (always keeping the root, `pane.cap`).

`pane.continue` errors are contained (`update_panes` pcalls the build and hides
both panes on failure); `scrolloff` is forced to 0 so `<C-e>`/`<C-y>` and the
scroll-driven refresh work.

**The header pipeline** — the **minimal connecting subgraph** (a focused rebuild,
*not* a reduction of the whole off-screen graph): only how the pinned anchors relate
to each other and to the lanes crossing the cutoff:

1. **Seam.** `boundary_at(target, up=true)` reads the **up-lanes** of the rendered
   line at the seam screen row and its *display* index. **Virtual lines matter:**
   when the seam item is a fork its children diverge on its **split** (virtual) line,
   so for the header the boundary is read from `item.split` (the divergence), not the
   single mainline lane on the columns line — otherwise a fork sitting right below
   the viewport hides every branch that forks from it.
2. **Rebuild the focused sub-DAG** — `pane.continue_up(boundary, tips, anchors,
   order_of, seam)` runs a three-pass reachability over the **display** DAG (the
   projected nodes, so `order_of` is always defined), up-only, bounded above the seam:
   - **Pass 1 — `seed_reach`.** Each boundary column is a distinct **seed** (a fork
     seam yields ≥2 columns on one commit — different lanes, so seed identity is the
     *column*, not the begin hash); each pinned tip is a seed too. From every seed walk
     **up** via `children`, recording the **set** of seed-ids reaching each node. A node
     reached by **≥2 distinct seeds** is a **confluence**.
   - **Pass 2 — `useful`.** From every confluence and every pinned tip walk **down** via
     `parents`, marking the above-seam ancestors that lead up to one of them. (Seeding
     pinned tips keeps a lone anchor's full spine; over-marking is harmless because the
     induction is seed-driven.)
   - **Pass 3 — induce.** Walk up from each *useful* seed keeping only *useful*
     children (first-parent child first, for colour-pivot continuity). A seed that is
     **not** useful becomes a **seam head** (a childless node → it terminates at the
     seam). The induced node's restricted `children`/`parents` then drive `condense`'s
     role: ≥2 kept children → junction, 1 → collapse, 0 → head (so a confluence whose
     merged output dead-ends caps with a head). Each pinned anchor is then connected
     **down** its own first-parent spine to the already-seeded part (induct for *edges
     only* — the spine nodes are not re-walked up, or the up-walk would pull in every
     collapsed fork off the trunk and balloon the header). When both boundary lanes begin
     at one merge sitting at the cutoff, the up-walk's single first-parent chain can
     dead-end at a collapsed node before it reaches an anchor on a folded branch; without
     this step the anchor is inducted but **disconnected**, and `M.header` renders it as a
     lone head on a fresh lane id, severed from its crossing lane (the merge-at-cutoff
     bug — HEAD jumped to id 39). Every spliced spine node is `useful`, so `condense`
     collapses the linear run back to one edge and the header does not grow.

   So an unpinned branch that forks off the trunk and reconnects to nothing is
   **pruned** (the stray-fork regression — no stray feature heads); a branch that only merges
   back condenses to a node-less junction. **Invariant:** every above-seam boundary
   `begin` ends up in the node set handed to `condense` (a useful node or a seam head),
   so no seam lane is dropped and the header's bottom row matches the main view's top
   edge. `condense(up=true)` then splices linear runs.
3. **Direct seam-up grid.** `pane.header(items, boundary, node_of, lane_of)` lays
   the condensed sub-DAG out by a bespoke **bottom-up sweep** — no `columns.layout`,
   no transpose. `active` (col → lane → the node it ascends toward) is seeded from the
   boundary, so the bottom row *is* the seam. Processing nodes nearest-seam first,
   each emits one line: still-active lanes carry up as bars, a head places a `◍`
   (labelled for an anchor, bare otherwise), a junction draws a node-less crossing.
   **Colour** comes from `lane_of(node)` — the node's main-view lane colour (graph.lua
   builds `lane_main[hash]` from each display item's `parent_lanes[1]`), so the pane
   matches the graph and forks are distinct. The **pivot continuation keeps the
   pivot's colour**; each *extra* fork child takes its own, and fork children take
   fresh columns (**columns are never reused**) so colour continuity is exact. Lines
   are collected bottom-up then reversed (tip on top), and `pack_heads` merges
   consecutive **unpinned-head** rows (`overlay_rows`, the §10.4 marker rule) so bare
   `◍` heads share rows — pinned-anchor and junction rows break a run and keep their
   own line.
4. **Size + render.** `converge_header` does a **min-fit search**: start at
   `H = (#pinned tips above) + 1`, grow until the rows + the seam separator fit; cap
   at `HEADER_MAX` (8), then clip with a `+N above` indicator (`pane.cap(...,
   keep_first=true)`). The header **vanishes** when the viewport is already at the
   top (`w0` display index ≤ 1). Rendered topology-only, dashed, tip on top, the
   seam separator at the **bottom** (padded so the seam butts the main view).

Full cross-level head packing (lifting *all* unpinned heads onto a single row, vs.
today's consecutive packing) and moving the rebuild off the cone-debounce path are
the remaining refinements.

## Layers

```
lua/gitloom/
  init.lua       Thin facade: setup() + :GitloomGraph command registration
  graph.lua      Git I/O, DAG construction, Phase 2 render, reachability, commit view
  view.lua       View builder: commit DAG + view state → OrderItem graph (spec §10)
  columns.lua    Phase 1: lane layout (lanes → columns + per-segment connectivity)
  pane.lua       Context-pane layout core: boundary extraction + focused-rebuild footer (continue/condense/footer) and header (continue_up/condense/seam-up grid) builders (spec §6.2)
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
   └─ fetch_commits()            git log --all --parents   (no ordering flag)
          │  stdout handler (light): stitch partial lines, enqueue raw text,
          │    schedule a drain — no per-commit work here (see Git I/O).
          │  scheduled worker, COMMIT_BATCH at a time (yields between batches):
          │    parse_commit_line → Commit
          │    merge into repo.commits (fills ref placeholders, keeps their refs)
          │    resolve parent hashes → Commit refs (+ child links, placeholders)
          │    append OrderItem to repo.order   ← provisional arrival order
          │  then once per batch:
          │    refresh_columns(order)          ← Phase 1 relayout (columns.layout)
          │    controller.insert(new_items)    ← inserts the batch's blank lines
          │  on stream completion:
          │    order_commits(repo.commits)     ← owned topological sort (§3.1):
          │      rebuilds repo.order in the authoritative row order, then reflow()
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
- `fetch_commits(opts)` — `git log --parents` (no ordering flag — gitloom owns
  the row order, §3.1) with a
  `%x1f`-delimited pretty-format (`%H %P %an %at %ai %s`). `%at` (epoch) + `%ai`
  (offset) feed the parsed timestamp. No `--decorate`; refs are a separate query
  (specification.md §3). **Streamed unbuffered** so the view fills progressively
  (spec §3, §10.5): the `on_stdout` handler is kept light — `make_line_buffer`
  stitches the partial line at each chunk seam, the complete lines are enqueued,
  and the heavy per-commit work (`parse_commit_line` + `on_batch`) runs in a
  `vim.schedule`d worker that drains `COMMIT_BATCH` lines per turn and reschedules
  until the queue is empty, so a large log never blocks the event loop in one
  callback. `on_batch` does one `refresh_columns` + one `controller.insert` for
  the whole batch. The returned future resolves only once the stream has closed
  *and* the queue is fully drained.
- `fetch_commit_detail(hash)` — `git show -s --date=iso` with a `%x1f`-delimited
  format (`%H %an %ae %ad %cn %ce %cd %P %B`), buffered and resolved as one raw
  string. The on-demand source for the **commit view** (specification.md §11);
  it does not feed the graph model. The body `%B` is last so its embedded
  newlines stay in the final field.
- `fetch_commit_diff(hash)` — `git show --format= -p <hash>`, buffered and
  resolved as the raw patch string. The commit view's diff source (§11.3),
  fetched on demand and chained after `fetch_commit_detail`.
- **Working-tree state** (specification.md §3.3) — small porcelain queries that
  run *after* the commit stream (so HEAD is in the model). `fetch_worktree_state`
  resolves `{ head_hash (rev-parse HEAD), status (parse_status of git status
  --porcelain) }`; `parse_status` counts the staged (index, `X`) / unstaged
  (working tree, `Y`) / untracked (`??`) files. The diffs are on demand, like the
  commit view: `fetch_worktree_diff("staged")` is `git diff --cached`;
  `fetch_worktree_diff("unstaged")` is `git diff` concatenated with the untracked
  additions (`fetch_untracked_diff`: each `git ls-files --others
  --exclude-standard` file rendered via `git diff --no-index -- /dev/null <f>`,
  capped at `UNTRACKED_DIFF_CAP`). `git_lines` / `git_output` are the thin
  jobstart helpers these share.

`git log` is porcelain, but an explicit `--pretty=format:` is a stable,
documented placeholder contract — the de-facto way to script this. The
plumbing-pure alternative (`git rev-list --no-commit-header`, same format) is a
one-line swap with no real gain today. gitloom owns row ordering (`order_commits`,
§3.1), so no ordering flag is passed to `git log` — git's emission is only the
arrival order for progressive streaming.

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
- `diff_contexts(patch)` — for each 1-based patch line, the governing file and
  hunk (the nearest `diff --git` / `@@` at or above it) with the patch-line
  index where each begins, so the context-header glue can tell when a header has
  scrolled off (specification.md §11.6). Renames show as `old => new`. Pure.
- `commit_range(commit)` — builds the `DiffRange` for a single commit's own
  changes: `{ rev = "<hash>^!"` (or `<empty-tree>..<hash>` for a root, no
  parents)`, from = parents[1], to = commit }`. A range constructor for the
  external-diff provider (specification.md §11.5). Pure.
- `range_endpoints(newer, older)` — the `DiffRange` for a **commit selection**
  span (specification.md §13.5): `<older>^..<newer>` (empty-tree base for a root,
  and exactly `commit_range` when the ends coincide). The graph range-selection
  constructor that feeds the same provider and the commit view's range mode. Pure.
- `format_range_detail(commits, palette)` — the range commit view's metadata rows
  (specification.md §13.5): an `N commits (oldest..newest)` summary then one
  newest-first `<abbrev> <subject>` row per selected commit. Pure.
- `sel_ascend_children` / `sel_step` / `sel_switch` — the commit-selection path
  walking over the DisplayNode graph (specification.md §13.2/§13.3): the children
  to ascend into, a one-commit step along the branch (extend/contract), and the
  branch switch at the nearest junction. Pure.

- `reachable_cone(order, pivot_index, top, bottom)` — the pivot's causal cone
  (specification.md §12.1): two monotonic sweeps from `order[pivot_index].commit`
  — one following `parents` (ancestors), one following `children` (descendants) —
  bounded to commits in the visible rows `top..bottom`. Returns a
  `table<Commit, true>` set (pivot included). Pure (no view/IO); the window
  bound and the parent-always-below-child topological order make it exact for
  relationships between on-screen commits.

`parse_commit_line`, `parse_timestamp`, `format_absolute`, `format_relative`,
`classify_ref`, `group_refs`, `parse_show`, `format_commit_detail`,
`format_diff`, `diffstat_files`, `diff_contexts`, `format_diffstat`,
`commit_range`, `range_endpoints`, `format_range_detail`, `sel_ascend_children`,
`sel_step`, `sel_switch`, and `reachable_cone` are pure and exposed via
`graph._internal` for testing.

### DAG construction

Commits are merged into `repo.commits` keyed by hash via
`get_or_create_commit`, so a commit first seen as a parent or ref target is a
placeholder later filled in by its log line (identity preserved; its refs are
kept). Parent hash strings resolve to `Commit` references; unseen parents get
a placeholder so the graph stays connected. Child links are populated on the
parent side. Refs are resolved the same way (a `Ref` holds a direct `Commit`
reference, and `Commit.refs` is the inverse).

### Working-tree virtual commits (§3.3 / §4.2)

When the working tree is dirty, up to two **virtual commits** (`Commit.virtual =
"staged" | "unstaged"`, with reserved sentinel hashes) are spliced into
`repo.order` just above the HEAD commit — `unstaged → staged → HEAD`, each present
only when it has content. `apply_worktree(state)` builds them (wiring
`parents`/`children` like real commits) from the fetched dirty-state counts and
`clear_worktree_nodes()` removes them; both leave the real DAG untouched. Because
they sit *above* HEAD, no owner's first-parent reach (§10.2) touches them, so they
project (`view.lua`) as **empty-signature → normal** nodes that are never
collapsible — the §4.2 "always shown" behaviour with no new owner kind. They
render via the `Commit.virtual` branches in `get_column_chars` (the `◌` glyph) and
`display_item` (a synthesized `worktree_label`, blank date/author), and the commit
view branches on `virtual` to use `fetch_worktree_diff` + `format_worktree_detail`
instead of `git show`.

**Refresh seam (§3.4).** Two refreshes share this seam, at different radii:

- `refresh_worktree(silent)` re-reads only the dirty state and rebuilds the
  virtual commits on the *current* HEAD anchor (re-resolving HEAD first, so it
  returns `"moved"` when real history advanced past the model). Triggered by a
  debounced `BufWritePost`/`FocusGained` autocmd and once at stream completion;
  skipped while a commit selection is active.
- `resync()` (the `R` key) is the **general history refresh**: re-read refs
  (`fetch_refs`), diff against the model for added / removed / moved tips
  (`diff_ref_tips`), pull the newly-reachable commits (`git rev-list --parents
  <new tips> --not <old tips>`, via `fetch_new_commits`) and link them into the
  identity-stable DAG by hash, re-point moved ref bindings, prune commits no
  longer reachable from any ref (`prune_unreachable`), re-run `order_commits`,
  then fold in `refresh_worktree` and `reflow()` — restoring the hash-keyed
  cursor / scroll / selection across the rebuild. The working-tree refresh is the
  same seam at a smaller radius.

`parse_status`, `worktree_label`, and `format_worktree_detail` are pure and
exposed via `graph._internal`; `order_commits`, `diff_ref_tips`, and
`prune_unreachable` (the resync pure pieces, §3.1/§3.4) are exposed there too.

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
   column for a tip. A **linear** commit (a single incoming child-lane) then
   **compacts** `cc` left through the run of columns free since row start, its
   incoming lane turning in — so a branch born one column out (an inline
   merge-on-split that had to fan past a freed cell) ends up next to the trunk
   after a single jog rather than stranded beside an empty column (`cc` is reserved
   before step 4, so a survivor keeps any nearer gap). The slide **stops at the
   first occupied column** — it never reaches past one into a farther gap, which
   would lay the lane's horizontal across the occupant (the no-cross rule below). A
   column a **root** (no-parent commit) occupied on the previous row is **blocked**
   for this row — tip placement, compaction targets, and fresh fan-out columns all
   skip it — so an independent history does not stack directly under a root (the
   "root column break" invariant). The block lasts one row, so consecutive stacked
   roots simply alternate columns.
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
4. **Compaction**: each survivor shifts left through the run of *row-start* gaps
   to its left (drawn as a horizontal turn), **stopping at the first occupied
   column** so the jog never crosses another lane — once two lanes have separated
   they re-share a horizontal only at a commit's own fan. It never moves into a
   column another lane vacates this same row either (two turns out of one cell), so
   freed columns are reclaimed over a ripple. Each placed lane's jog span is
   reserved (`used`) so a later one neither lands on nor crosses it. With both fans
   on their own lines, a commit line then has no crossings at all. An extra
   (non-first) parent likewise takes the
   leftmost column free since before this row — an interior gap, not a fresh
   rightmost one — so a staircase of sequential merges stays a bounded width. A
   column a *terminating child* frees is reusable by a parent only when that does
   not stack two turns in a cell: on a **separate merge line** (the child ended on
   the commit line above) or under `allow_merge_on_split` (the sanctioned inline
   two-turn cell); inline otherwise, the freed column waits for the next row.
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
visible. This is the selection substrate the §10 per-branch actions and the §13
commit selection build on.

**Commit selection (range)** (specification.md §13) is a separate modal layer
over the same window. A `sel` state (active flag, `path` of DisplayNodes
newest-first, `anchor`/`cursor` endpoints, per-junction `dparent`/`dchild`
choices) drives it; `V` toggles it. The path walk is pure (`sel_step` /
`sel_switch` / `sel_ascend_children`) over the DisplayNode edges, so it passes
through collapsed heads; a `node_loc` index (hash → {item, col}, built with
`display_index`) lets `mark_path` light a head's lane/marker even when packed.
While active, `j`/`k`/`<C-d>`/`<C-u>` walk the branch (else they fall through to
the builtin motions), `h`/`l` switch branch (else the ref selection above, flipped
under mirroring), `<Tab>` folds/unfolds the cursor's head in place (re-resolving
the selection by hash), `<CR>` opens the range commit view and `D` the range in
the external provider. Emphasis reuses the §12 dimming via a path-derived cone.

**Initial focus and position retention** (specification.md §2). When the stream
completes, after the final `reflow` the window focuses a target commit via
`goto_hash` (which resolves a folded commit to its collapsed head and returns
whether it landed), then centers on it with `center_view` (a window-local
`normal! zz`, so it clamps at the graph edges) and re-parks with `place_cursor`.
The cone is then recomputed for the new pivot/viewport. The target is the
**remembered position** for the repo if there is one, else **HEAD**
(`repo.refs["HEAD"]`; absent on a detached HEAD, which falls back to the top).
The remembered position is a module-level `saved_positions` table keyed by
Neovim's cwd (the repo git runs in); the `CursorMoved` handler records the hash
under the cursor (`cursor_hash`) on every row change, so it is always current
without a close hook. It is in-memory for the Neovim session — not persisted to
disk.

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

`open_commit_view` takes an optional `range` argument (the commit-selection
**range mode**, §13.5): when present `commit` is nil, the metadata is the
selected-commit list (`format_range_detail`) instead of `format_commit_detail`,
and the diff is the combined range patch from `fetch_range_diff` (`git diff
<base> <to>`, base = the range's first parent or the empty tree) rather than
`git show`. Everything below the metadata — the diffstat, the diff, the file
jumps, the §11.6 context header — is the shared pipeline, so range mode reuses it
unchanged.

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

The **context header** (§11.6) is a borderless overlay pinned to the top of the
view (`relative="win"`, `zindex` above the content, `focusable=false`), modeled
on the graph's footer glue rather than `pane.lua`. `render` builds `diff_contexts`
over the same patch and records `diff_start`; a `WinScrolled`/`WinResized`
autocmd calls `update_ctx`, which reads the viewport top (`line("w0")`, not the
cursor), advances it past the overlay's own height with a short fixpoint (the
height is 0–2), looks up the governing file/hunk, and shows each line only once
its real header has scrolled above that effective top — closing the overlay when
nothing sticks. It is decoration only; a `WinClosed` autocmd tears it down with
the view.

### Submodule change view

A commit that bumps a submodule pointer renders in the diff as an opaque
`160000`-mode hunk — an old/new `Subproject commit <hash>` pair. When the
submodule is checked out and both commits are present locally, the commit view
replaces that pair with a small change graph of the submodule's own history
(specification.md §11.7). The split mirrors the rest of the commit view: a pure,
unit-tested core in **`submodule.lua`** plus async git I/O and the render splice
in graph.lua.

`submodule.lua` (git-agnostic, no I/O):

- `parse_changes(patch)` scans the rendered patch for submodule bumps — a
  `diff --git` file whose body is a `-Subproject commit` / `+Subproject commit`
  pair — and returns one entry per changed submodule with its `path`, `old`/`new`
  hashes, and the 1-based patch-line indices of the two `Subproject` lines (the
  splice target) and the file's `diff --git` line. One-sided changes (a newly
  added or removed submodule) are skipped — there is no relationship to draw.
- `classify(old, new, base)` maps the merge-base `base` to the relationship:
  `base == old` → `ff` (forward bump), `base == new` → `rewind`, a `base` but
  neither → `diverged`, no `base` → `unrelated`.
- `link(commits)` resolves a flat, newest-first commit list (parents as hash
  strings) into layout-ready `{ type = "commit", commit }` OrderItems: it
  resolves in-list parent hashes to their Commit objects, sets child back-links,
  and drops out-of-list parents so the cone's boundary commits read as roots.
  The result feeds `columns.layout` unchanged (the same Phase 1 the main graph
  uses), so the mini-graph is the real lane layout, not a bespoke renderer.

graph.lua glue (gated, async — never fetches; §11.7.1/§11.7.4):

- `git_output(args, cwd?)` is a thin future over `jobstart` (used for the
  submodule queries; the submodule is addressed with `git -C <path>` so a missing
  checkout fails the query rather than throwing on an invalid `cwd`).
- `fetch_submodule_graph(opts, change)` chains the gated queries — presence
  (`cat-file -e <hash>^{commit}` for both), `merge-base`, `rev-list --count` for
  ahead/behind, and a `log --first-parent base..tip` (ff/rewind) or one-line
  `log` of each endpoint (diverged) — and resolves a structured result
  (`available`/`reason`, `class`, `ahead`/`behind`, the linked `items` or the
  endpoint commits). For ff/rewind the fork-point commit is fetched and appended
  as the bottom anchor, so the old/new pointer there is shown. The log format
  matches `parse_commit_line` with a trailing `%d` decoration field; `--first-
  parent` keeps a mainline merge a single node and avoids dragging a merged-in
  side branch in (no lane dangling at the range boundary — the §10.7 focus).
- The render builds the change block: a header line (`+N` / `−N` /
  `diverged +X / −Y`), then for ff/rewind the first-parent commits laid out by
  `columns.layout` and drawn by `get_column_chars` (the same glyph gutter as the
  footer pane), with the **old/new pointer rows tagged** (`◀ new` / `◀ old`) and
  the list capped via `pane.cap` (newest rows plus the always-kept fork-point
  anchor) with a "+K more" note for the commits elided between (shown in full,
  not condensed — see specification.md §11.7.3); for diverged a glanceable
  endpoint summary (the two tips and the merge-base, no paths drawn); for
  unavailable the raw two hashes plus a dim reason. The commit view fetches the
  submodule graphs after the patch renders and re-renders in place once they
  resolve (progressive enhancement — the diff never blocks on a slow submodule).

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
  `update_cone` calls `mark_reachable` over the visible window — except on a
  **packed marker line** (§10.4), where the `h`/`l`-selected head has no row of its
  own (so `mark_reachable`'s index pivot can't reach it): there it calls
  `mark_node_cone`, which seeds the same emphasis from the selected head's
  DisplayNode (walking `.parents`/`.children`, lighting each lane via its shared
  edge object by `node_loc`, as `mark_path` does). So selecting a packed head dims
  the sibling heads/branches and keeps the selected one lit, exactly like moving
  onto a normal head. With no marker selected the line is neutral (all lit).
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
│   ├── pane.lua           Context-pane layout core (§6.2)
│   ├── columns.lua        Phase 1 lane layout
│   ├── color.lua          OKLCH colour generation (§5.5)
│   ├── submodule.lua      Submodule change view: pure core (§11.7)
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
