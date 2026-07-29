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
flag and `order_commits` (`gitloom.git.order`) runs the topological sort that produces
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
in `gitloom.window` does the windowing.

The rebuild is **scroll-gated and async**. The cursor/scroll debounce calls
`maybe_update_panes`, which rebuilds only when the scroll key (`winsaveview().topline`
+ `topfill` — `topfill` catches a sub-scroll through a line's virtual rows that
`line("w0")` alone misses)
changed — the panes are a function of the scroll, not the cursor row, so a cursor
move within the window costs nothing. Forced callers (reflow, the `M`/`B`/`F`/…
toggles) call `update_panes` directly. `update_panes` runs `build_panes` as a
**coroutine** driven across event-loop ticks (`drive_panes`): the deep
first-parent walks in `pane.continue`/`pane.continue_up`/`pane.condense` call an
optional `yield` hook every `YIELD_EVERY` steps, and `build_panes`' own O(N) index
passes yield via `py`, so a deep history never blocks a keypress. A scroll (or a
newer build) bumps `pane_gen`, abandoning the in-flight coroutine; **both** panes
are computed before any overlay mutation (a no-yield tail), so a cancelled build
leaves the prior panes intact. The first chunk runs synchronously, so small panes
still land in the same tick. The repo.order index is cached (`order_idx`).

**The footer pipeline** (`build_panes`, gated by `opts.panes`), per rebuild:

1. **Seam by whole commit blocks.** The footer is a **borderless overlay** over the
   bottom rows of the main window (relative="win") — the sticky-scroll pattern,
   so its lanes butt directly against the seam with no border between. Its
   `zindex` sits just above the host window's content but below the transient
   `?`/`K` floats. With the single-window model (§14) there is only one host
   window on screen, so the z-order is bounded rather than a stacking ladder:
   `host_zindex` (the host's live zindex, snacks' default ~50) with fixed deltas
   above it — `overlay_zindex` (= host + 5: the panes and the commit-view sticky
   header) and `float_zindex` (= host + 10: the `?`/`K` floats and the pickers).
   Each reads the host's *live* zindex (it can hide and re-show with a new id),
   so the panes always layer correctly over whichever window the host currently
   is. The seam is computed in **screen-row space** on the flattened `screen_lines`
   model. **`pane.screen_lines(display, rows_of)`** flattens the display OrderItems
   into the actual sequence of rendered **screen rows** — real `columns` lines PLUS the
   **virtual** fan rows (`virt_lines`; each takes a screen row but *no* real buffer line,
   so `line('w0')`/`line('w$')` cannot address it). It is **count-based**:
   `rows_of(item)` returns `{ above, height, below }` (default reads the single
   `.split`/`.merge` fans), so any number of virtual rows above/below — and both on one
   commit — just work. Each screen row carries a signed `virt` (`0` columns, `-k` the
   k-th row above, `+k` below); `cols[di]` maps a display item to its first columns
   screen row. The live glue derives `bs`, the **bottom visible screen row (a model
   row)**, by anchoring on the **CURSOR** via **`pane.footer_bs(sm, cursor_disp,
   winline(), win_height)`** = `cols[cursor] + (win_height − winline())`. `winline()`
   (the cursor's screen row within the window, minus the dual-mode sub-row offset) and
   the window height are **both window-relative**, so this needs no `win_screenpos` and
   is border/winbar-robust. This is the fix for the whole class of footer virtual-line
   bugs: `line('w0')`/`line('w$')` are REAL lines that can't address a split fan rendered
   above an off-screen columns line, and `win_screenpos` is the **frame** top (drifts by
   the border). Verified against nvim's actual rendering — a real bordered window with
   `virt_lines` — in `tests/screen_window_spec`.
   **`pane.footer_seam(sm, bs, cover)`** then walks up from `bs` to the first
   **block boundary** (the last screen row of a commit's block) leaving ≥ `cover` rows
   below it, so the overlay covers **whole commit blocks** and its top butts the seam
   item's bottom line (a **below** fan row, else `columns`) exactly. Pure (no `screenpos`),
   unit-tested; the invariant is swept over every window position (`footer_window_spec`).
2. **Continue only the active lanes.** `pane.continue(boundary, anchors, extra)`
   walks each boundary lane's **first-parent chain** down to a root, plus any
   pinned-ref tips below the cutoff (`extra`) so a divergent pinned branch still
   shows. Lanes converge at the commits where they actually meet; every lane
   reaches a root (never dangling); a merge's second parent is never followed, so
   **no non-active branch is introduced**. A commit that ≥2 boundary lanes **land
   on** (a fork below the seam whose branches are both visible above) is where they
   converge, but the landing is not a first-parent edge — so `continue` counts
   those landings alongside the first-parent children and force-keeps such a commit
   as a convergence junction (passed to `condense` as `keep`). Without this the
   whole seam→root stretch condenses to the lone root and the extra lanes strand at
   the seam (the footer seam-discontinuity bug).
3. **Condense + render.** `pane.condense` contracts each linear stretch to an
   edge, keeping only ref heads (`◍` markers — anchor refs only), fork/merge
   **junctions** (node-less join glyphs), and roots/tips (real nodes); `node_of`
   maps every member hash to its node. `columns.layout` lays it out in compact
   mode (`pane_opts`: inline joins), the lanes seeded from the boundary; it's
   rendered topology-only, **dashed** (┊ / ╌, junctions solid), aligned under the
   main graph, with a `┊` separator marking the seam. Height grows to a fixed
   point and is capped (always keeping the root, `pane.cap`).

`pane.continue` errors are contained (`drive_panes` resumes the build coroutine,
so an error surfaces as a `false` return rather than an exception, and both panes
are hidden on failure). The graph window's `scrolloff` is set window-local from
`opts.scrolloff` (default 10, §8) rather than inherited; a non-zero value
interacts with the overlays (`<C-e>`/`<C-y>` and the scroll-driven refresh were
the reason it was historically forced to 0), so `opts.scrolloff = 0` restores
that behaviour if the panes' scrolling misbehaves.

**The header pipeline** — the **minimal connecting subgraph** (a focused rebuild,
*not* a reduction of the whole off-screen graph): only how the pinned anchors relate
to each other and to the lanes crossing the cutoff:

1. **Seam.** Computed in **screen-row space** on the same `screen_lines` model as the
   footer — the exact upward mirror. The live glue derives `ts`, the **top visible screen
   row (a model row)**, by anchoring on the **CURSOR** via **`pane.header_ts(sm,
   cursor_disp, winline())`** = `cols[cursor] − (winline() − 1)` (both window-relative, so
   border/winbar-robust — the mirror of `footer_bs`). This is the fix for the header's
   virtual-line drift: `line('w0')` is a REAL line that can't address a **split** fan
   rendered *above* an off-screen columns line, so the earlier display-index walk assumed
   the top item's columns line was the window top and the seam drifted by those partial
   split rows. **`pane.header_seam(sm, ts, cover)`** (pure, no `screenpos`) then walks down
   from `ts` to the first **block start** (the first screen row of a commit's block)
   leaving ≥ `cover` rows above it, so the overlay covers **whole commit blocks** and its
   bottom butts the seam item's top line exactly; `pane.boundary_of(line, up=true)` reads
   the **up-lanes** of that line. **Virtual lines matter:** when the seam item is a fork its
   children diverge on its **split** (virtual) line, so the boundary is read from
   `item.split` (`kind = "split"`) — not the single mainline lane on the columns line —
   otherwise a fork sitting right below the viewport hides every branch that forks from it.
   Verified against nvim's actual rendering in `tests/screen_window_spec` and swept over
   every window top position in `tests/header_window_spec`. (The footer is the exact
   mirror: `pane.footer_bs`/`pane.footer_seam` + the seam item's **merge** fan; see the
   footer pipeline.)
2. **Rebuild the focused sub-DAG** — `pane.continue_up(boundary, tips, anchors,
   order_of, seam, yield, lane_of)` runs a **tracked-lane induce** over the **display**
   DAG (the projected nodes, so `order_of` is always defined), up-only, bounded above the
   seam. **Working-tree virtual commits (§4.2) are excluded:** `above()` treats a virtual
   node as not-above, and a boundary lane that begins on one is not seeded — so the
   up-walk stops at the topmost **real** commit (the live state is never drawn in a
   pane; spec §6.2). A virtual-only off-screen region therefore yields an empty rebuild
   and the header is hidden.

   The **tracked** lanes are the lanes crossing the seam plus the pinned anchors' own
   lanes, by **lane id** (`lane_of(n).id`, the main-graph lane identity — the projected
   first-parent is unreliable). The header keeps a junction only where **≥2 tracked lanes
   meet**:
   - **Pass 1 — `seed_reach`.** Each boundary column is a distinct **seed** (different
     lanes, so seed identity is the *column*); each pinned tip too. Walk **up** via
     `children`, recording the seed-id set reaching each node; ≥2 distinct ⇒ a
     **confluence** (≥2 tracked lanes converge).
   - **Pass 2 — `useful`.** Walk **down** (via `parents`) from every confluence and pinned
     tip, marking above-seam ancestors that lead up to one — but only **through tracked
     nodes**, else a node useful via an *untracked* path the induce can't follow caps as a
     stray head.
   - **Pass 3 — induce.** Walk up from the seeds keeping a child iff it is **on a tracked
     lane AND useful**. Tracked drops the merge/fork plumbing of every feature branch that
     touched the trunk off-screen; useful caps an isolated crossing lane at the seam (a
     bare ◍) instead of drawing it up to its own feature tip. Merges fall out where two
     followed lanes meet one node; the per-edge seam sentinel keeps a merge whose parents
     cross the cutoff a junction. The restricted `children`/`parents` then drive
     `condense`'s role: ≥2 kept children → junction, 1 → collapse, 0 → head. This also
     fixes the merge-at-cutoff anchor-severing bug (HEAD jumping to a fresh id): the
     anchor's lane is **tracked**, so the crossing lane on it follows the spine by id
     unbroken to the anchor; a collapsed continuation's `lane_of` is its `parent_lanes[1]`
     (the trunk lane, keyed by the tip hash), so a recycled tip-own lane never severs it.
     Finally each pinned anchor is connected **down** its first-parent spine to the
     already-inducted trunk (edges only), so a **divergent** anchor whose tip is ahead of
     the trunk — its lane never crossing the seam, the up-walk never reaching it — relates
     to the trunk instead of floating as a stray labelled head.

   So an unpinned branch that forks off the trunk and reconnects to nothing is
   **pruned** (the stray-fork regression — no stray feature heads); a branch that only merges
   back is the single node-less junction (real-repo headers shrank from ~11 nodes to 2–6;
   a **shortest-path** dedup for redundant parallel routes to one anchor is deferred —
   none observed). **Invariant:** every above-seam boundary
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
today's consecutive packing) is the remaining refinement.

### Reachability emphasis in the panes (§6.2 / §12)

The panes dim with the cursor's cone like the main view, but **without** walking
the off-screen graph. The cone is monotone, so cone-membership inside a pane is
fully fixed by which seam-crossing lanes are in the cone, propagated over the
pane's *own* condensed graph: `pane.mark_pane_cone(seeds, dir)` walks `.parents`
(footer, `down`) or `.children` (header, `up`) from the in-cone entry nodes,
returning the in-cone node-hash set — `O(pane)`.

The build stashes each pane's repaint state on `footer.state`/`header.state` (the
laid-out rows, the condensed `node_of_hash`, the seam crossing-lanes — whose
`edges` are *live* refs into the main view's segments, so their `highlighted`
state is always current — plus the walk direction and render offsets).
`paint_pane(state)` reads the live seam highlights, seeds and runs
`mark_pane_cone`, writes the result onto the stored rows (the footer via its
per-edge `Lane.highlighted`, the header via each segment's `cone` tag — the
governing node, since header segments carry no per-edge `edges`), and re-renders
with emphasis on. `render_pane` dims out-of-cone labels/counts; the glyphs dim
per-cell in `get_column_chars` (`seg_hl` now also honours a segment-level
`highlighted`). Because it is a per-row repaint rather than a rebuild, a cursor
move that doesn't scroll takes the cheap path: `maybe_update_panes` rebuilds only
on a real scroll, otherwise calls `repaint_panes`. `H` (and the cone-changing
selection/marker paths via the cursor debounce) re-dim the same way.

## Layers

The code is layered: a **git data library**, a pure **graph engine**, a
**window controller** that drives them, and a couple of standalone helpers.
Dependencies point strictly downward — `window → graph → git`, and neither the
engine nor the library has any window/buffer coupling.

```
lua/gitloom/
  init.lua        Thin facade: setup() + :GitloomGraph command registration
  window.lua      The graph window CONTROLLER (gitloom.window): floating window,
                  keymaps, autocmds, streaming/resync, the reachability debounce,
                  context panes, the commit view, external-diff glue — M.open
  util.lua        Vendored helpers: make_future (promise), compose/highlight_text
                  (highlight builders), trim_ws
  git/            The git DATA LIBRARY (gitloom.git)
    init.lua        Public aggregator (re-exports the submodules)
    model.lua       Commit/Ref/Upstream types + sparse placeholder constructors
    parse.lua       git log/show/diff/status parsers (incl. the stream de-chunker)
    format.lua      Commit-detail / diff / diffstat / range / worktree formatters
    refs.lua        classify/group refs, ref-picker model, resync ref-diff (§2/§3.4)
    range.lua       DiffRange builders (§11.5/§13.5)
    order.lua       order_commits — gitloom's owned topo-sort (§3.1)
    date.lua        Timestamp parse + date formatters (§4/§6)
    fetch.lua       The async git I/O (jobstart) — the only Neovim-coupled corner
  graph/          The graph ENGINE (gitloom.graph): commits + view state → rows
    init.lua        Engine entry: data-model types (Lane/Segment/GraphColumn/
                    OrderItem/…) + layout orchestration (build_graph,
                    refresh_columns, pack_markers, owners_from_refs) + the
                    `_internal` test seam (re-exports the pure surface)
    view.lua        View builder: commit DAG + view state → OrderItem graph (§10)
    columns.lua     Phase 1: lane layout (lanes → columns + per-segment connectivity)
    render.lua      Phase 2: glyphs, colour, reachability dimming, row rendering
    reach.lua       Reachability cone + the Lane-graph emphasis walk (§12)
    select.lua      Selection / branch-mode pure helpers (§2/§10/§13)
    pane.lua        Context-pane layout core (§6.2)
    color.lua       OKLCH↔sRGB conversion + golden-angle colour generation (§5.5)
  listview.lua    Reusable virtualized list widget (snacks.win)
  submodule.lua   Submodule change classification + budget/truncate (§11.7)
```

- **init.lua** — registers the `:GitloomGraph` user command (bound directly to
  `window.open`) and exposes `setup(opts)`. Intentionally minimal.
- **gitloom.window (window.lua)** — the controller: the floating window, the
  keymaps and autocmds, the commit stream + resync, the reachability debounce,
  the context panes, the commit view, and the external-diff glue. It is the only
  Neovim-window-coupled layer; it drives the engine and the data library. A graph
  session is a **`GraphCtx`** (`ctx`) — `open_graph` assembles it and the helpers,
  keymap handlers, and autocmd bodies are *module-level* functions taking `ctx`
  (gathered in `GRAPH_HELPERS` → `ctx:method()` and `GRAPH_KEYS` → buffer-local
  binds), so the controller closure stays well under LuaJIT's 60-upvalue cap. The
  pane machinery and one-time stream/`on_show` setup stay nested.
- **gitloom.git** — the data library: the immutable commit model, the parsers
  and formatters that turn raw `git` output into structured data, the owned
  topo-sort, and the `jobstart` I/O (`fetch.lua`, its sole Neovim coupling).
  Pure everywhere else.
- **gitloom.graph** — the engine: a pure function of (commits, view state,
  options) → renderable rows. `view.lua` projects modes (§10), `columns.lua` is
  Phase 1 (lane layout), `render.lua` is Phase 2 (glyphs/colour), `reach.lua` the
  §12 emphasis, `select.lua` the selection walks. `graph/init.lua` owns the
  layout orchestration and the `_internal` test seam.
- **color.lua** — pure colour maths (no Neovim dependency); `render.lua` realises
  its output into highlight groups.
- **listview.lua** — a generic, incrementally-rendered list view. It knows
  nothing about git; it renders rows produced by a `display` callback and only
  materializes the visible range.

`gitloom.window` is the consumer of the engine and `listview`; both the engine
and `gitloom.git` are written to be reusable in isolation.

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
          │    apply_sort() → order_commits     ← owned topological sort (§3.1):
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

## Windows, views, and navigation

> **Target design** (specification.md §14), implemented across Phases A–E on
> `feature/view-stack`. Replaces the earlier "each open stacks an independent
> floating window" model. See **Current state** at the end of this section.

The controller layer gains two tiers of structure above the engine.

**Tier 1 — the session registry (per repository).** A module-level table keyed
by repository root: `sessions[root] = { host, stack, idx, mru }`. `host` is the
single floating window for that repo (one snacks `win`); `stack` is its
navigation stack (tier 2). Opening a repository **shows its session** (creating
it on first entry) rather than stacking a new window:

- `q` → `host:hide()` (snacks `close({buf=false})` — the window closes, the
  frames' buffers survive); the session is recorded as the MRU top.
- `<leader>wg` → show the MRU session (cold-start: open the cwd repo).
- `<leader>wG` → the repository picker; the chosen repo's session is shown.
- `<C-w>q` → destroy the session: wipe every frame buffer, drop the entry.

`host:hide()` / `:show()` is the toggle substrate; **`host:set_buf(frame.buf)`**
is the tier-2 navigation primitive (snacks sets `self.buf` before
`nvim_win_set_buf`, so its `fixbuf` autocmd no-ops — verified against
snacks.win).

**Tier 2 — the navigation stack (per session).** An ordered list of **Frame**s
with a current index; `<C-o>` / `<C-i>` move the index, and a content-changing
navigation pushes (truncating any forward tail and wiping its buffers). A
**Frame** externalises what `M.open` today traps in its closures:

```
Frame = {
  kind,        -- "graph" | "commit" | ...
  scope,       -- the full graph; a commit; a branch; a range (§14.2)
  modifiers,   -- filters / injected anchors intrinsic to this entry
  buf,         -- the frame's own buffer (shown via host:set_buf)
  view_state,  -- modes / pins / unpinned / effective / cone (forked on push, §14.4)
  controller,  -- the listview controller, for graph frames
  repo,        -- the repo data model (cross-repo frames carry their own, §14.7)
}
```

**Pure navigation logic** lives in a git-agnostic, unit-tested module (the
`select.lua` / `view.lua` pattern): stack push / pop / truncate, fork-on-push
state inheritance, the repo-boundary seeding rule (§14.4), breadcrumb-label
building (§14.6), and modifier resolution. Only the window glue (buffer swap,
keymaps, panes) stays untested.

**The decoration-provider seam.** listview's provider currently gates on the
**window id** (`state.winid == winid`). Two facts force a move to **buffer
keying**: `host:show()` yields a *new* window id (a winid-keyed provider goes
dark after a hide/return), and multiple graph frames share one window but hold
distinct buffers. The provider dispatches `bufnr → frame`, so each graph buffer
renders as its own graph and a commit-frame buffer is left alone.

**Panes and the breadcrumb attach to the active frame.** On a frame switch the
panes are rebuilt for the newly-shown frame; `pane_gen` is scoped per frame so
an abandoned async build cannot clobber a sibling. The breadcrumb is the graph
frame's header (sharing it with the pane seam, §6.2).

**Phasing.** A: tier-1 sessions + hide / return / switch / destroy + the
buffer-keyed provider. B: Frame externalisation + the stack scaffold (one graph
frame, no visible change). C: the commit view as a `commit` Frame (`<C-o>`
returns). E: the submodule deep-link as a cross-repo frame push (§14.7). D:
filters / modifiers + fork-on-push. F (deferred): durable persistence.

**Current state:** Phases A–E landed (`feature/view-stack`). One host window per
repo (`nav` session registry, keyed by repo root); the navigation stack
(`navstack.lua`) holds **frames** (a frame = a buffer the host swaps in). The
graph builds into a frame via `open_graph` — buffer-local keymaps and a listview
**attach mode** (`M.open{ attach = { winid, buf } }`) let it render into a shared
host window, so the commit view (C) and a drilled-in submodule (E,
`M.drill_submodule`) are frames in the one window, navigated by `<C-o>` / `<C-i>`.
`q` hides, `<leader>wg` returns, `<C-w>q` destroys. Remaining: D (filters /
modifiers + fork-on-push) and F (durable persistence, deferred).

## Internals

> Note: this section predates the library/engine/controller split. The pieces it
> describes now live in their split homes — Git I/O in `gitloom.git.fetch`, the
> parsers/formatters across `gitloom.git.*`, Phase 2 render in
> `gitloom.graph.render`, reachability in `gitloom.graph.reach`, and the window
> glue (streaming, panes, commit view, keymaps) in `gitloom.window`. The
> behaviour is unchanged; only the file boundaries moved.

### Git I/O

- `fetch_refs(repo)` — `git for-each-ref --format="%(objectname) %(refname)
  %(*objectname) %(upstream:short) %(upstream:track,nobracket)" refs/heads
  refs/remotes refs/tags` (the deref hash resolves annotated tags). Space-
  separated, **not** `%x1f` (for-each-ref does not interpret that hex escape); the
  first four atoms are space-free, so the one field with spaces —
  `%(upstream:track)`, "ahead N, behind M" — is **last** and parsed from field 5
  on. `parse_ref_line` turns the upstream atoms into a local branch's
  `Ref.upstream` (`{ short, ahead, behind, gone }`, §6.3) — only when git reports a
  tracked upstream, so divergence comes from real tracking config, never a shared
  short name. `fetch_ref_entries` (the resync read) carries the same upstream so
  `R` refreshes the indicator.
- `fetch_head(repo)` — `git symbolic-ref --short --quiet HEAD` for the current
  branch.
- `fetch_commits(opts)` — `git log --topo-order --parents` (a valid topo base for
  progressive paint; the active sort mode produces the final order at completion,
  §3.1) with a `%x1f`-delimited pretty-format (`%H %P %an %at %ai %ct %s`). `%at`
  (epoch) + `%ai` (offset) feed the parsed author timestamp; `%ct` (committer
  epoch) seeds `order_commits` (§3.1). No `--decorate`; refs are a separate query
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
  `fetch_worktree_diff("unstaged")` is `git diff` (tracked only);
  `fetch_worktree_diff("untracked")` is the synthesized untracked additions
  (`fetch_untracked_diff`: each `git ls-files --others --exclude-standard` file
  rendered via `git diff --no-index -- /dev/null <f>`, capped at
  `UNTRACKED_DIFF_CAP`). `git_lines` / `git_output` are the thin jobstart helpers
  these share.

`git log` is porcelain, but an explicit `--pretty=format:` is a stable,
documented placeholder contract — the de-facto way to script this. The
plumbing-pure alternative (`git rev-list --no-commit-header`, same format) is a
one-line swap with no real gain today. gitloom owns row ordering (`order_commits`,
§3.1); the stream's `--topo-order` is only a valid topo base for progressive
paint (it equals the `topo` sort mode's own output), and the active sort mode
produces the authoritative order at completion.

All run via `vim.fn.jobstart` and resolve a `Future` on `on_exit`. The
controller chains them refs → head → commits.

**Repository root (spec §2.1).** The git layer runs every query in an
**active repository root** rather than implicitly following Neovim's cwd. A
module-level `active_cwd` in `fetch.lua` (set via `M.set_cwd`, exposed as
`git.set_cwd`) is injected as each job's `cwd` by a single `js` wrapper around
`vim.fn.jobstart`; `nil` falls back to Neovim's cwd (the original behaviour
until a graph sets it). This mirrors the window's existing module-level state
(one active graph). The window resolves the root once when the graph opens
(`git -C <folder|cwd> rev-parse --show-toplevel`, defaulting to the cwd repo
when no folder is passed), stores it on `Repo.root`, and pushes it with
`git.set_cwd`. This is what lets the graph target a **submodule** or the
**main module** instead of the cwd repo; the window's per-session view state
(`saved_positions`, `recent_refs`) is keyed by `repo.root` accordingly.

**Repository picker (`:GitloomPick` → `window.pick`, §2.1).** `fetch_submodules(cwd)`
runs `git submodule status` in an **explicit** `cwd` (the picker queries the cwd
repo without disturbing any open graph's active root — `git_lines` now takes an
optional `cwd` that overrides `active_cwd`) and parses it with the pure
`submodule.parse_submodules` into `{ name, path, sha, state, checked_out }` per
direct submodule. `fetch_repo_summary(cwd)` returns `{ branch, short, subject }`
for a picker row. `window.pick` opens the snacks picker immediately with the
known entries (main module first, submodules appended as discovery resolves via
`picker:find{refresh}`) and fills each row's summary asynchronously
(`picker:update{force}` after mutating the item), so a slow submodule never
blocks the list; an uninitialized submodule is shown disabled, and confirming
opens `M.open` on that repo. `M.open` **re-shows** that repo's host window if one
already exists, or builds it on first entry — one window per repository, never
stacked (§14.1); the picker is the explicit cross-repository switcher (`q` hides
the current window, this opens/raises another). The pure `parse_submodules` is
unit-tested; the async picker orchestration is window glue (not unit-tested, like
the rest).

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
  share a short name into one `RefGroup { name, has_local, remotes, track }`,
  keeping HEAD and tags separate. Drives the compact `(name ↑remotes)` rendering
  (§6). A local branch's `Ref.upstream` rides along on `track`, so the decoration
  can append the divergence indicator.
- `track_segments(track)` / `track_label(track)` — the upstream divergence
  indicator (§6.3) as coloured `{ text, kind }` segments and, byte-identically,
  the plain concatenation `track_label` (so the rendered and selection/cursor
  forms agree). `⇡N` ahead, `⇣N` behind, `⇡N⇣M` diverged, `gone`; empty in sync.
  Shared by `decoration_texts`, `display_item`'s ref rendering, and the picker.
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
`classify_ref`, `group_refs`, `track_segments`, `track_label`, `parse_show`,
`format_commit_detail`,
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

When the working tree is dirty, up to three **virtual commits** (`Commit.virtual =
"staged" | "unstaged" | "untracked"`, with reserved sentinel hashes) are spliced
into `repo.order` just above the HEAD commit — `untracked → unstaged → staged →
HEAD`, each present only when it has content (the untracked node is the untracked
files; the unstaged node is tracked-only). `apply_worktree(state)` builds them (wiring
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
- **Phase 2** (`get_column_chars`, in `gitloom.graph.render`) renders glyphs and
  colour from those Segments (below).

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
   **compacts** `cc` left — under the `compact` / `linear` layout policies (§5.6);
   the others skip this slide — through the run of columns free since row start, its
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
4. **Compaction** (under the `compact` / `survivors` layout policies, §5.6; the
   others hold every survivor in its column): each survivor shifts left through
   the run of *row-start* gaps
   to its left (drawn as a horizontal turn), **stopping at the first occupied
   column** so the jog never crosses another lane — once two lanes have separated
   they re-share a horizontal only at a commit's own fan. It never moves into a
   column another lane vacates this same row either (two turns out of one cell), so
   freed columns are reclaimed over a ripple. Each placed lane's jog span is
   reserved (`used`) so a later one neither lands on nor crosses it. With both fans
   on their own lines, a commit line then has no crossings at all. **A `fan_line`
   — an *inline* split (≥2 incoming, no separate split line) or merge (≥2 outgoing,
   no separate merge line) — suppresses all compaction on that line** (both the
   survivor shift and step 2's linear slide): a pass-through lane crosses the fan
   vertically, and only the fan's own lanes draw the horizontal. On a separate
   axis — **fan-out placement**, which runs under every policy — an extra
   (non-first) parent takes the
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

### Layout as a staged pipeline

Status: **built** on `feature/layout-pipeline`. `columns.layout`'s per-commit loop
is a **pipeline of grid stages**, behaviour-preserving — byte-identical rendering
(verified over a large DAG × merge-style × mirror characterization matrix) and
every test green. This supersedes the earlier "one replaceable `place(ctx)` policy"
note: a layout **strategy** is a plain function that chains the stages, and
reordering / swapping / adding stages is the seam.

**The model.** Each stage **writes segments into a live column grid and reads
occupancy back from it** — the grid *is* the working state, not an abstract plan
rendered at the end. `columns.layout` sweeps the order top-to-bottom carrying the
imperative shell (`active` col → Lane flowing down, `blocked`, the
id/colour minters). For each commit it builds a per-item `state`:

```
state = {
  item, commit,
  incoming, survivors, outgoing,     -- the DAG split + the born parent lanes
  sep_split, sep_merge, fan_line,    -- merge-style flags
  g = { cells, draw, occ0, used },   -- the live main-line grid + occupancy
  above = {}, main, below = {},      -- the three line sections
  row,                               -- the finished OrderItem
}
```

**Lines and sections.** A **line** is a `GraphColumn[]` — the exact shape Phase 2
consumes — so the invariant validators apply to it directly. An item's lines form
**three sections**: zero-or-more `above` (virtual, fan-in rows), exactly one `main`
(real, carries the node), zero-or-more `below` (virtual, fan-out rows). Render
order is `above` top-to-bottom, then `main`, then `below`. Today's styles emit ≤1
above and ≤1 below; the sections are lists so a future strategy can spread one wide
fan over several rows.

**Grid occupancy.** The stages read occupancy from two reservations on `state.g`,
which together encode the one rule that keeps the graph legible — *a fan's
horizontal bus is shared by its lanes; nothing else may overlap a horizontal*:

- `occ0` — a **vertical** (a bar / node / down-going lane) occupies the column;
  frozen at row start, so a column a lane vacates mid-row is not silently reused.
- `used` — a **non-shareable horizontal** occupies the column: a survivor's
  compaction jog, or the trunk's jog into the node. A fan's own bus is **not**
  reserved — every lane of a fan emanates from the same commit's hub, so they
  overlap freely and only each lane's turn-down **endpoint** is claimed (as a
  vertical). `grid_taken(c)` = neither slot free.

Every stage tests occupancy through `grid_taken`. `place_commit` and `slide` run
before anything writes `used` (`seed_bars` creates it empty; only `fan_in` /
`compact` / `carry` / `fan_out` write it, all later in every chain), so for them
its `used` term is provably false — which is why they can share the predicate with
the later stages instead of spelling out `occ0 or blocked` inline.

(A first grid attempt reserved whole fan spans and pushed inline merges wider;
reserving only endpoints restores fan sharing and byte-identity — a good
confirmation the sharing rule is the right one.)

**Where dedicated lanes will plug in (§10.6.2, not yet built).** A column held
for a *reserved* pinned branch is occupancy, so `grid_taken` is the single seam:
one more term beside `blocked`, and tip placement, the slide, survivor compaction
and fan-out all skip the column for free — the spec's "stop, never a skip" then
follows from the guard the stages already obey, with nothing to add per stage.
The pin list supplies the order (`select.reserved_order`, above); the tie-break
for a commit whose signature names several reserved owners is the earliest of
them in that list. Enforcement is at lane **birth** plus "not compacted away" —
never a rightward re-jog, which `compact`'s leftward-only redraw cannot express
and `complete_check` would reject. The colour side reuses the pane **seed**
carve-out in `columns.layout` (drop the slot from the free FIFO, bump `in_use`).
Panes are exempt (§6.2): the footer's seam must reproduce the main view's
boundary columns exactly, and the header never runs this sweep.

**The stages.** Three **shell steps** run first (setup): `classify` (read `active`
into incoming/survivors), `spawn_lanes` (mint one outgoing Lane per parent — the
id/colour lifecycle), `decide_style` (the sep_split / sep_merge / inline_junction /
fan_line flags). Then the **layout strategy** chains the grid stages:

- `seed_bars` — open the main line; write every survivor's bar (a vertical).
- `place_commit` — the commit column `cc0` (leftmost incoming, or the leftmost free
  / non-blocked column for a tip), the incoming reservation, and the split reduction
  (only the trunk reaches the commit line under `sep_split`). `cc` starts at `cc0`.
- `slide` — compact a *linear* commit leftward through the free run (a no-op on a
  fan line). Its own stage so the seam strategy can drop it (below).
- `fan_in` — the split line above (when scheduled); reserve the commit jog; write
  the fan-in converging into the node (crossing survivors, sharing the bus) and the
  first parent's descent.
- `compact` — slide each survivor left into free columns, redrawn as a turn,
  reserving its jog in `used` (suppressed on a fan line, where a pass-through crosses
  the fan vertically).
- `fan_out` — the diverging parents' columns (endpoint-only reservation,
  freed-column reuse), drawn inline or on the merge line below; then advance
  `active` / `blocked`.
- `finalize` — assemble the main line, build the `OrderItem` (`split` / `columns` /
  `merge` + parent/child lanes).

The draw order — survivors, then fan-in, then the moved survivors, then fan-out —
is what keeps the grid byte-identical to the old algorithm.

**No generic runner.** A strategy is *just a function calling the stages in order*
— there is no loop, no ledger, no driver:

```
local function layout_compact(state)  -- the main view, and a pane's body rows
  seed_bars(state); place_commit(state); slide(state); fan_in(state)
  compact(state); fan_out(state); finalize(state)
end
```

An earlier version had a ledger-driven loop (run the stages until an obligation
ledger emptied, with a no-progress guard). It was **removed as speculative
generality** once it was clear the stage set always completes in one pass — the
loop, the ledger, the per-stage run-once guards, and the pass budget all only
served that generality. If a future strategy genuinely needs iteration (append a
line and re-run), it adds its *own* control flow. The obligation framing was not
wasted: it pinned down what "handled" means, which is now encoded in the oracle.

**A second strategy: the pane seam.** A context pane (§6.2) is laid out by the same
`M.layout`, seeded with the boundary lanes crossing in from above (the `seed`
param → pre-populated `active`). Its **first row is the seam** and must match the
seeded columns exactly, so the pane meets the main view without a jog. That is the
footer's *one* layout-level special rule, and it is now a distinct strategy rather
than a flag: `layout_seam` **drops `slide` and swaps `compact` for `carry`** (which
holds every survivor in its column). The sweep picks it for the seeded first row:

```
for i, item in ipairs(items) do
  run_item(item, (seed and i == 1) and layout_seam or layout_compact)
end
```

So the seam rule reads as *which stages run*, not a `first_row and seed` conditional
threaded through `place_commit` and `compact` (both now flag-free). Everything else
that makes the footer a footer lives outside `columns.layout`: building the
sub-DAG (`pane.continue` / `condense` — projection) and the dashed / dimmed drawing
(`render_pane` / `paint_pane` — render).

**Layout policies (spec §5.6).** The selectable layout policy needs **no new stage
code**: all four policies are chains of the stages already here, differing only in
whether `slide` runs and whether the compaction slot holds `compact` or `carry`.
`layout_seam` *is* the no-slide/no-compact chain already, byte-identical to what
`straight` needs.

| Policy | Body chain (after the shell steps) |
|--------|------------------------------------|
| `compact` | `seed_bars` `place_commit` `slide` `fan_in` `compact` `fan_out` `finalize` |
| `survivors` | `seed_bars` `place_commit` `fan_in` `compact` `fan_out` `finalize` |
| `linear` | `seed_bars` `place_commit` `slide` `fan_in` `carry` `fan_out` `finalize` |
| `straight` | `seed_bars` `place_commit` `fan_in` `carry` `fan_out` `finalize` |

A policy is therefore a **record carrying both chains**, not a single strategy —
`{ body, seam }` — because the seam row's requirement (every seeded lane keeps its
seeded column) is orthogonal to the body's placement and must hold under every
policy. `seam` is `layout_seam` for all four today; the record exists so a policy
that needed a different seam could say so, and so the sweep's
`(seed and i == 1) and policy.seam or policy.body` selection stays one expression.
`straight`'s **body** is that same `layout_seam` function object — reused, not
duplicated — so "`straight` is the no-move chain" is true by construction rather
than by two copies staying in sync. A reserved third field, `prepass`, is where a
future `interval` policy (§5.6) hangs its `O(N)` lane-lifespan annotation: a
`prepass(opts, items)` called once before the sweep, free to annotate `items` in
place so no hint-plumbing threads through `state`. No current policy declares one,
and the sweep simply skips it — exactly the annotation-pass shape the lookahead
sketch below needs.

`opts.layout_policy` selects the record; an unknown or absent value falls back to
`compact`, since it is read from user config and must never error.

**The live toggle (`C`).** `window.lua` cycles `ctx.opts.layout_policy` through
`LAYOUT_POLICIES` and reflows. Two deliberate departures from the neighbouring
cycles: the index is **derived from `ctx.opts` at each keypress** rather than held
in a module-level counter (`merge_style_index` and friends are shared by every
open graph — wrong for a feature whose purpose is holding two windows at two
policies), and the handler also writes `ctx.pane_opts.layout_policy`, because the
panes hold a **shallow copy of `opts` frozen at window creation** and would
otherwise keep the open-time policy while the main view changed. The toggle uses
`reflow()` (not `refresh()`) since a different placement can change which markers
pack, and re-anchors with `goto_hash` so the two renderings are comparable row for
row. The **footer** therefore follows the policy; the **header** does not, since
`pane.header` is the direct seam-up grid and never calls `columns.layout` (spec
§5.6, §6.2).

**`complete_check` is policy-free.** Every obligation it verifies — the node placed
once and on the main line, each incoming lane drawn and terminated, each survivor
drawn and carried, each outgoing lane drawn and carried, the outgoing count — is
owed by *any* strategy, whatever it does with columns. It asserts nothing about
where a lane sits. That is what makes adding a policy safe: the oracle keeps its
teeth without being parameterised, and a policy that drops a stage still gets
caught.

**Two contracts a stage in the compaction slot must honour.**

- **`s.out` is the interface between the compaction slot and `fan_out`.** Both
  `compact` and `carry` set `s.out` (the survivor's column *after* this row) on
  every survivor entry, and `fan_out` reads it to advance `active`. It is not
  defaulted anywhere. A replacement stage that leaves `s.out` nil for a survivor
  silently drops that lane from the next row's `active` — the failure is a lane
  vanishing a row later, not an error at the point of the bug. Set it for every
  survivor, always.
- **`fan_out` does double duty.** It both *draws* the diverging parents (and the
  merge line below) and performs the **advance** — rebuilding `active` and
  `blocked` for the next row. A future *placement* policy that replaces the
  fan-out rule (the §5.1 fan-out placement axis; `interval`) must keep the advance,
  which most likely means splitting `fan_out` into `fan_out` (draw) + `advance`
  (shell bookkeeping) first, so the placement half is the replaceable part.

**Completeness oracle.** `complete_check(state)` runs after the strategy and
verifies the emitted lines: the node appears exactly once and on the main line;
every incoming lane is drawn and has **terminated** (absent from the next
`active`); every survivor is drawn and **carried** forward; every outgoing lane is
drawn and carried, and the outgoing count equals the parent count. It reads the
output like the test invariants — stronger than `check_commits` — and it catches a
strategy that skips a stage (`state.main` would be nil). This is the safety net
that replaces the loop's guard, and it is what makes "the sequence ran" trustworthy
without a runtime driver.

**Output boundary.** `finalize` maps `above[]` / `main` / `below[]` back to the
existing `OrderItem` contract `row.split` / `row.columns` / `row.merge` (current
styles produce ≤1 of each), so Phase 2, the panes, `display_item`, and every test
are unaffected. Generalising the `OrderItem` to true `above[]` / `below[]` lists is
a later, spec-gated change — only when a strategy emits more than one — and it
touches `render.lua` / `display_item` and the panes.

**How it was built.** Peeled, then rebuilt, each step proven byte-identical over
the characterization matrix plus `make test` / `make lint`:

1. wrap the whole algorithm as a single stage behind a ledger-driven driver;
2. peel `spawn_lanes` and `decide_style` (the shell) out;
3. split into `place` (placement) + `emit` (drawing), then subdivide `place` into
   `place_commit` / `compact` / `fan_out`;
4. **rebuild onto the live grid** — replace compute-then-render with a routine
   whose steps write segments into `state.g` and read occupancy back (the fan-bus
   sharing fix keeps it byte-identical);
5. split that routine into the six composable grid stages
   (`seed_bars` … `finalize`);
6. **drop the runner** — replace the ledger + loop + guards with a plain strategy
   function plus the oracle.

The panes and `pack_markers` consume `columns.layout`'s output (including the
`seed` seam semantics, kept in the shell), so they are unaffected as long as its
output is preserved.

**Future strategies (not yet built).** With the pipeline in place, alternative
layouts become new strategies (a different chain of stages), not new algorithms —
and, once the policy enum exists, new **entries in it** (§5.6) rather than new
seams:

- *Spread* — a placement stage that keeps empty columns between occupied lanes
  with a restoring "pressure" toward the boundary. Local; no lookahead.
- *Lookahead crossing-minimization* — anticipate an incoming fan (an octopus
  merge several rows below) and make space early, spreading horizontal travel
  over gentle diagonals instead of one sharp cut at the fan row. This needs a
  mode-independent **annotation pass**, run once, precomputing forward hints (lane
  lifespans = the row each lane's parent lands on; upcoming fan widths; near-term
  column demand) into the state; a greedy stage set ignores them, a lookahead one
  consumes them.

The hard constraints still bound the ambition: **streaming** (you cannot look
past the stream frontier — lookahead is windowed, not global), **reflow
stability** (a small input change must not reshuffle the whole graph — prefer
bounded local heuristics over global barycenter/Sugiyama-style minimization), and
**determinism** (no randomness). Quality — crossing count — needs its own test
beyond the correctness invariants: a **crossing counter** over the rendered grid
asserting a smart stage set yields ≤ the greedy set's crossings on the same DAGs
while the invariants still hold. Introducing genuinely new layout *behaviour*
(spread/lookahead) needs a specification.md §5 amendment first; the decomposition
itself is a behaviour-preserving refactor within the current spec.

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
- `graph_snippet(opts, items, focus, radius)` — a compact "where is this commit"
  locator for the commit-search preview (spec §15.3): the rows of `items` in
  `[focus - radius, focus + radius]` (clamped) rendered as graph cells
  (`get_column_chars`) padded to a shared width plus a short subject, the focus
  row marked with a gutter. Pure over already-laid-out items; returns the compose
  rows and the focus's 1-based row index. Unit-tested (`snippet_spec`).

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

**Pinned branches — the ordered list and its dialog** (specification.md §10.6 /
§10.6.1). The anchor set is stored as **one ordered list** of `PinEntry`
(`{ id, reserved }`), not a set: `view_state.pins` holds the user's explicitly
ordered entries and `view_state.unpinned` the ids they removed (which suppress
the built-in defaults). `select.lua` owns the pure core — `pin_resolve` (stored
entries first, then the defaults HEAD / `master` / `main` / `dev` / seeded marks,
minus the unpinned and minus refs that no longer exist), `pin_move` /
`pin_toggle_reserved` / `pin_remove` / `pin_add`, and the two readers `pin_ids`
(the membership set) and `reserved_order` (the reserved ids in priority order —
the whole of what the ordering means to the layout). All are copy-in/copy-out, so
the glue assigns the result back.

Putting `reserved` **on** the entry rather than in a second list is what makes
`reserved ⊆ pinned` and "unpin implies unreserve" structural instead of
remembered: the flag has nowhere to survive its entry. Pinning alone still
changes **no geometry** — the flag is set only in the dialog.

`ctx:effective_pins()` resolves the live list and applies the **pin-the-pair**
upstream rule (§6.3), which needs the ref registry: an auto-pinned upstream
carries `auto = <local id>`, is re-derived on every resolve, and is inserted
directly after its source — so unpinning the local drops it, exactly as before,
while an explicit pin/unpin of the upstream still wins. `ctx:effective_pinned()`
is that list reduced to ids and remains what `view.owners` / `collapse_owners`
consume, so **every existing pin consumer is unchanged**.

`L` opens the dialog (`GRAPH_HELPERS.pin_dialog`): a `float_zindex` float over
the graph, with `select.pin_dialog_lines` producing the buffer lines and a
line → entry-index row map (pure, so the layout is testable without a window).
Its keys are buffer-local; each edit writes `view_state.pins`, reflows, and
restores the graph cursor by hash — the same sequence `P` uses. `<CR>` and the
"Pin new branch…" row both go through the pieces the `<leader>b` picker already
uses (`ctx:ref_picker_format`, `ctx:jump_to_ref`, `ref_picker_items`), extracted
so there is one ref picker, not two.

Note these four helpers are **`GRAPH_HELPERS` fields, not module locals**:
window.lua sits at LuaJIT's **200-local chunk limit** (a second ceiling beyond
the 60-upvalue one the tables were introduced for), and adding four locals
overflows it. New window helpers should go into the tables.

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
(`repo.refs["HEAD"]`, gated on `repo.head` so only a branch checkout focuses; a
detached HEAD still carries a marker (§3.2) but falls back to the top).
The remembered position is a module-level `saved_positions` table keyed by
the repository root (`repo.root`, §2.1); the `CursorMoved` handler records the hash
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
action label after render. `q` closes it. The row assembly — action label,
metadata, diffstat, diff, plus the submodule change blocks and the per-render
index maps (file jumps, the §11.6 context lookup) — is factored into
`build_commit_rows(opts, spec)`, a window-independent helper that emits the
compose `{text, highlight}` rows for any buffer. `open_commit_view` writes them
into its host-window frame; the **commit-search preview** (§15.3, below) writes
the same rows (with `action = false`) into the picker's preview buffer, so the
two renderings never drift. The pure
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

### Commit search

`<leader>gl` (and the buffer-local `:GitloomSearch`) opens a `snacks.picker` over
the in-memory commit set (specification.md §15). `h_commit_search(ctx)` — a
module-level `GRAPH_KEYS` handler — builds one item per real commit from
`repo.order` (via `ctx.repo`): `hash`, `short`, `subject`, `author`, a relative
date, and `text = subject .. author` (the fuzzy haystack, §15.2) — so the match is
client-side over resident data: no git query, no cache. Working-tree virtual
commits (§4.2) are skipped.

The **preview** is a custom `snacks` preview function. It renders, into the one
preview buffer: a **graph snippet** locating the commit
(`render.graph_snippet(opts, repo.display, focus, radius)`, §15.3) above the
**commit view** rows (`build_commit_rows` with `action = false`, fetched on
demand and cached per hash for the session). A full `hash → repo.display` row map
(built once when the picker opens, including collapsed region members → their
head's row, §10.3) resolves the snippet's focus row, so a folded commit locates
on its collapsed head. The detail fetch (`fetch_commit_detail` then
`fetch_commit_diff`) re-renders the preview when it resolves, guarded by a
`showing` token so a late fetch never clobbers a newer selection (snacks reuses
one preview buffer). After rendering, the preview is centered on the first line
containing a query token (else the subject) and that line highlighted (§15.3).
**Confirm** refocuses the graph float, `goto_hash`es the commit, and re-centers —
within-view navigation (§14.2), no stack push; a hidden commit is a no-op with a
notice, mirroring the ref picker.

The picker float sits above the graph via `layout = { preset = "default", layout =
{ zindex = float_zindex(ctx:win()) } }` — the single-window z-order model (§2.1):
the host keeps a fixed zindex and transient floats layer at `float_zindex` (host +
10). The preset is required (without it the layout drops the preview window).
`build_commit_rows` is exposed as `M.build_commit_rows` so the picker (and its
preview) share the commit-view renderer.

### Filter search (in-graph)

`/` (`h_filter(ctx)`) is the in-graph **filter** (specification.md §16) — a
transient, isolated overlay distinct from the §15 picker. The pure core lives in
the engine: `view.project` takes a **`keep` set** (§16.3) of commit hashes that
never contract (like junctions, §10.3), and `select.filter_keep` / `smartcase_match`
build that set from a query over subject+author (§16.2, smartcase substring).
Tested in `filter_spec`.

The window glue:

- **State** is `ctx.filter = { query, keep, current }`; `reflow` force-collapses
  every owner (a mode-only override, so the signature cache survives) and passes
  `keep` to `view.project`, so only matches and junctions stay visible (§16.3).
- **The overlay** is a one-line floating input (`b:completion = false` so a
  completion plugin can't grab its insert-mode keys). Typing re-filters live,
  debounced via a `filter_gen` counter (§16.4). `<C-j>`/`<C-k>` (and `<Up>`/`<Down>`)
  step the current match through `filter_goto`, which records `ctx.filter.current`
  (driving the §16.7 matched-substring highlight in `display_item`) and moves the
  graph cursor *behind* the focused input (`goto_hash`/`center_view` target
  `ctx:win()`, not the current window).
- **`<CR>`** (`select_dismiss`) discards the filter, opens the match's branch
  (`ensure_expanded` — sets the collapsed owners reaching it to normal), and jumps
  to the commit with a **recorded** motion (`goto_hash(hash, true)` → `{lnum}G`) so
  the pre-filter spot (tracked by hash, since expanding shifts lines) enters the
  jumplist and the hybrid `<C-o>` returns there (§14.3).
- **Isolation (§16.1)** is only needed for the **stamp**: the transient overlay
  can't change modes (the input owns the keys), so cancel/dismiss just clear
  `ctx.filter`. `<C-s>`/`<C-CR>` (`do_stamp`) deep-copies
  `view_state.modes` / `pins` / `unpinned`
  into the live view state and pushes a `filter` nav frame reusing the graph buffer
  (the `nav.push_frame` wipe-guard protects it); its `on_enter` re-installs the
  copy + filter; `on_show` restores `ctx.base_view` on `<C-o>`. So the base's
  collapse/pin are provably untouched, no bookkeeping. `/` over a stamped view
  refines it in place; `n`/`N` walk matches there.

> **Jumplist + the listview.** In-graph jumps (filter `<CR>`, ref-pick) record the
> jumplist so `<C-o>`/`<C-i>` work (§14.3, hybrid: in-buffer jumplist first, then
> the view stack — `list[idx]` = back, `list[idx+1]` = current, `list[idx+2]` =
> forward). The listview must therefore **not** corrupt the jumplist on a dimming
> refresh (§12), which re-renders some rows' glyphs: a multi-line block `set_lines`
> collapses jumplist entries within its range, so the renderer replaces only the
> changed lines, **one at a time** (a 1-for-1 single-line replace preserves the
> entry), falling back to a block write only when the row count changes.

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
- `split_budget(max, n_new, n_old)` distributes the bounded height (`max`, one row
  reserved for the shared ancestor) **evenly** between the two sides, **spilling**
  any unused share (a short or empty side) to the other — so a fast-forward/rewind
  (one empty side) hands the whole budget to the side that changed (§11.7.3).
- `truncate(commits, keep)` keeps the newest `keep` of a newest-first list and
  reports how many were dropped, so the pointer head is always shown with a
  "+K more" marker for the elided middle.

graph.lua glue (gated, async — never fetches; §11.7.1/§11.7.4):

- `git_code(args)` is a thin future over `jobstart` resolving `{ code, out }`
  (used for the submodule queries; runs in the active repository root like the
  rest, with the submodule addressed by `git -C <path>` relative to it, so a
  missing checkout fails the query rather than throwing on an invalid `cwd`).
- `fetch_submodule_graph(opts, change)` chains the gated queries — presence
  (`cat-file -e <hash>^{commit}` for both), `merge-base`, `rev-list --count` for
  ahead/behind, and **two** `log --first-parent base..tip` runs (one for
  `base..new`, one for `base..old`) plus the merge-base commit — and resolves a
  structured result (`available`/`reason`, `class`, `ahead`/`behind`, the
  `new_commits`/`old_commits` lists, and `base_commit`). The log format matches
  `parse_commit_line` with a trailing `%d` decoration field; `--first-parent`
  keeps a mainline merge a single node and avoids dragging a merged-in side branch
  in (no lane dangling at the range boundary — the §10.7 focus).
- The render (`submodule_block`) builds the change block: a header line (`+N` /
  `−N` / `diverged +X / −Y`), then a **hand-drawn two-lane Y** — because each
  side is a *linear* first-parent line, the topology is fixed, and the lanes carry
  *semantic* colour (added/removed/ancestor) rather than the free-list lane
  palette, so the dedicated renderer is simpler and more robust than the main
  `columns.layout` engine. The **new side** (green, `palette.submodule.new`)
  descends from the new pointer `B`; the **old side** (red,
  `palette.submodule.old`) from the old pointer `A`; both converge at the shared
  **ancestor** node (`palette.submodule.base`, the first lane colour). The pointer
  rows are tagged (`◀ new` / `◀ old`), each side is truncated via `split_budget` +
  `truncate` with a "+K more" note for the elided middle (shown in full, not
  condensed — §11.7.3), and a fast-forward/rewind degenerates to a single side
  with the ancestor marked as the coinciding pointer; an unavailable submodule
  shows the raw two hashes plus a dim reason. The commit view fetches the
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
│   ├── init.lua           Thin facade (setup + :GitloomGraph)
│   ├── window.lua         The window controller (gitloom.window): M.open
│   ├── util.lua           Vendored helpers (make_future/compose/highlight_text/trim_ws)
│   ├── git/               The git data library (gitloom.git)
│   │   ├── init.lua       Aggregator
│   │   ├── model.lua / parse.lua / format.lua / refs.lua
│   │   ├── range.lua / order.lua / date.lua
│   │   └── fetch.lua      Async git I/O (jobstart) — the only Neovim coupling
│   ├── graph/             The graph engine (gitloom.graph)
│   │   ├── init.lua       Engine entry: types + layout glue + _internal seam
│   │   ├── view.lua       View builder: projection under view state (§10)
│   │   ├── columns.lua    Phase 1 lane layout
│   │   ├── render.lua     Phase 2 render (glyphs/colour/dimming/rows)
│   │   ├── reach.lua      Reachability cone + emphasis walk (§12)
│   │   ├── select.lua     Selection/branch-mode pure helpers (§2/§10/§13)
│   │   ├── pane.lua       Context-pane layout core (§6.2)
│   │   └── color.lua      OKLCH colour generation (§5.5)
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
