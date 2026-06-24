# gitloom.nvim — Project Context for Claude

## Authoritative Documents

- **[specification.md](specification.md)** — Behavioral contract. *What*
  gitloom does: entry point, data source, data model, graph layout
  invariants, rendering behavior, configuration. Authoritative for behavior.
- **[ARCHITECTURE.md](ARCHITECTURE.md)** — Implementation architecture.
  *How* it is built: layers, data flow, the lane-layout algorithm, the
  listview widget, file layout.
- **[README.md](README.md)** — User-facing docs. Install, usage,
  configuration, testing.

Do NOT duplicate content from these files here. Refer to them instead.

## What this is

A read-only git commit-graph viewer for Neovim. `:GitloomGraph` opens a
floating window showing the commit DAG as a colored, lane-based graph for the
repo at Neovim's cwd. Part of the loomworks suite, but **standalone** — its
only third-party dependency is snacks.nvim.

**Focus and direction.** The product is the graph viewer; other git
functionality is out of scope except where it falls naturally out of the
graph or is delegated to another plugin (diffview, etc.). gitloom builds the
graph itself rather than wrapping `git log --graph` (model ownership), because
the planned interactive views — collapse / pin / toggle branch visibility,
with reflow — require owning ordering and layout. The graph algorithm is the
most developed part of the codebase; the rest of the current surface exists
mainly to exercise it. The central unsolved problem is commit attribution in
a shared DAG. See specification.md §1, §10 and ARCHITECTURE.md
("Model ownership and the view pipeline").

The plugin lives at `C:/src/nvim-plugins/gitloom.nvim` and is loaded via the
owner's Neovim config (`C:/Users/samie/AppData/Local/nvim`, branch
`loomworks`) as a lazy.nvim dev plugin: the config's `dev.path` resolver uses
the local checkout when present, otherwise clones the `unstable` branch from
`https://gitcode.com/samienne/gitloom.nvim`.

## Relationship to loomworks

gitloom ships in the loomworks suite but **must not depend on
`loomworks.nvim`**. This is a deliberate, standing decision.

- gitloom currently *vendors* small utilities loomworks also has — a
  promise/future (`make_future` in graph.lua) and a highlight-composition
  helper (`compose`, duplicated in graph.lua and listview.lua). Keep these
  vendored.
- It is fine to **copy** an implementation from loomworks wholesale (e.g.
  adopting loomworks' more complete `future.lua` by vendoring it) — but copy,
  do not add a runtime dependency.
- The intended long-term path for shared code is a separate small `utils`
  library that gitloom can copy from or depend on independently — not a
  dependency edge to loomworks. Do not introduce that edge.

## Spec-First Development Workflow

**Before implementing any change that contradicts specification.md or
ARCHITECTURE.md, STOP.** Propose the doc change first, explain the reasoning,
and wait for approval. Then update the doc, then the code.

The cycle:

1. Identify what needs to change (spec vs current behavior)
2. Propose a spec amendment (show the diff or describe it)
3. Wait for approval
4. Update specification.md (and ARCHITECTURE.md if architecture changes)
5. Implement the code change
6. Update or add tests

For changes clearly *within* the existing spec (bug fixes, adding tests,
refactors without behavior change), skip steps 1–4 and implement directly.

## Branch Workflow

All changes go through branches — never commit directly to `master` or
`unstable`.

- **Feature branches**: `feature/<short-name>`
- **Bugfix branches**: `fix/<short-name>`
- Branch from `master`. Multiple commits per branch are fine.
- Do **not** create commits automatically — only when the user explicitly
  asks. It is fine to suggest "should we commit this?" at a stopping point.
- Merge with `git merge --no-ff` and a summary message describing *what* and
  *why*.

The shipped/default branch is `unstable` (what the Neovim config follows);
`master` is the integration branch.

## Pre-merge checklist (mandatory)

Before merging ANY branch, verify:

1. **specification.md** — all behavioral changes reflected
2. **ARCHITECTURE.md** — any structural changes documented
3. **README.md** — user-facing changes covered
4. **No discrepancies** — the docs agree with each other and the code
5. **Type annotations** — LuaCATS `@class`/`@field` annotations affected by
   the change are current (no stale or missing fields)
6. **Comments** — comments near changed lines are still accurate
7. **Tests pass** — `make test`
8. **Diagnostics clean** — `make lint` (lua-language-server, see Testing)
   reports no problems

**Do not merge if documentation is out of sync.** Fix docs first. If the
user does not ask for this check, remind them before merging.

## Bugfix workflow

Reproduce a bug with a failing test first, then fix it:

1. Write a failing spec that reproduces the bug
2. Verify it fails for the right reason
3. Fix the bug
4. Verify the spec passes

## Testing

Tests use plenary.busted.

- `make test` — run every spec in `tests/`
- `make test-file FILE=tests/<name>_spec.lua` — run one spec
- `make lint` — type-check with lua-language-server (`--check`, using
  `.luarc.json`). Resolves the Neovim runtime from `nvim` so `vim.*` is known;
  `tests/types/luassert.lua` is a `---@meta` stub for the busted `assert`
  matchers. Override the binary with `LUALS=...`. Part of the pre-merge
  checklist — keep it at zero problems.
- `tests/minimal_init.lua` sets up the runtime path (plugin + plenary from
  the lazy.nvim install dir) and disables swap/shada.

Coverage:

- `tests/refs_spec.lua` — `classify_ref`, `group_refs` (compact ref display),
  `owners_from_refs` (view-builder owners per ref, HEAD skipped; §10), and the
  branch-mode toggle helpers `next_mode` / `selected_owner_ids` / `collapse_owners`
  (§10/§10.4)
- `tests/ref_picker_spec.lua` — the ref-picker pure pieces (spec §2, `<leader>b`):
  `bump_recent` (the session MRU list — newest first, deduped, input not mutated),
  `ref_picker_items` (name → Ref registry → ordered picker entries: session-
  recent first in MRU order then grouped HEAD / local / remote / tag by name,
  commitless refs skipped, fields the picker shows incl. the match `text`), and
  `ref_decoration_index` (picked ref → its decoration index for pre-selection:
  local/remote → branch group by short name, tag → after the branches, HEAD/absent
  → nil)
- `tests/view_spec.lua` — the view builder `view.project` (spec §10): monotone
  signatures, the all-normal identity, hidden removal (shared ancestors kept),
  collapsed contraction to one head with junctions kept, **branch-topology
  preservation** (a fork/merge — a commit with ≥2 visible children/parents — is
  never collapsed away; no floating head; asserted on targeted cases and the
  whole fuzz sweep), distinct-signature regions staying separate heads, the
  display-mode join truth-table, the
  collapsed `◍` glyph render, the precomputed-sig caching equivalence, the
  first-parent-only signature (`fp_only`) and the `view.owners` first-parent
  default (§10.7: trunk normal+fp, others collapsed, merge owners; mainline-full /
  merged-collapsed projection), `pack_markers` (§10.4: packing concurrent
  collapsed heads onto one line with the packed grid passing the wires-connect
  checker; no-op when there are no markers), **node-less junction markers**
  (§10.4: a kept junction renders no node glyph — node count drops — vs. a node
  when `junction_markers` is off), and a fuzz sweep feeding projections through
  the real layout's wires-connect checks
- `tests/selection_spec.lua` — `move_selection`, `decoration_texts`,
  `ref_byte_col` (h/l ref selection + cursor parking), `pack_right`
  (the right-pinned ref width budget), `window_right` (the selection-windowed
  overflow, §6: a contiguous window around the selected ref with separate
  left/right `+N` markers; greedy right-then-left growth; the selected item always
  shown even when it alone overflows; sel clamping; empty), and `refresh_columns`
  width aggregation from `below` and from every stacked `above`/`below` row (§6.1)
- `tests/ref_window_spec.lua` — the windowed right-ref overflow **end to end** (§6):
  gitloom's `display_item` (setting `line_right` + `line_right_sel`) feeding the
  listview's `build_line` windowing, rendered into a stubbed window — default shows
  whole labels + a trailing `+N` (overflow hidden), selecting the overflowed ref
  scrolls it fully into view with the cursor target (`ref_byte_col`) resolving to
  it, and a single over-long selected ref truncates cleanly with `…` within the
  window (never spilling past the edge); plus the **packed marker row** (§10.4):
  its labels left-align after the graph (`line_right_align = "left"`) but window the
  same way around the selected marker (`+N` overflow, selected scrolled into view)
- `tests/label_mode_spec.lua` — the dual label mode's continuation graph
  (spec §6.1): `passthrough_columns` in both directions (`up` keeps lanes
  entering from above, `down` keeps lanes leaving below — the message row;
  a crossing keeps only its through-vertical; edge objects shared so §12 dimming
  still applies) and its rendering via `get_column_chars` (only `│`/blanks — no
  node or junctions — each vertical coloured by its lane slot)
- `tests/listview_spec.lua` — the multi-real-line bookkeeping (spec §6.1 dual):
  the buffer-line ↔ item offset map (`rebuild_starts`/`item_index_at`: mixed line
  counts, clamping, the incremental append path) and a windowed smoke test (snacks
  stubbed with a real window) that an item renders the right number of real buffer
  lines and that `relayout` grows the buffer when a mode switch makes a commit two
  rows, and that `set_items` swaps the whole list and re-lays the buffer (the
  reflow-swap primitive; §10.5)
- `tests/commit_spec.lua` — `parse_commit_line`, `parse_timestamp`, the
  date formatters (`format_absolute`, `format_relative`), and `make_line_buffer`
  (the unbuffered-stdout de-chunker: whole lines vs. the held trailing partial,
  cross-chunk stitching, byte-by-byte reassembly, blank lines; spec §3 streaming)
- `tests/commit_view_spec.lua` — the commit view's pure pieces (spec §11):
  `parse_show` (git-show field splitting, multi-line body, empty parents),
  `format_commit_detail` (committer-differs branch, refs line, body indent),
  `format_diff` (add/delete vs `+++`/`---`, hunk + file headers, context),
  `diffstat_files` (per-file counts, `start` offsets, rename, binary),
  `format_diffstat` (summary totals, per-file rows), and `commit_range`
  (single-commit `DiffRange`: `^!`, empty-tree for roots, `from` = first parent)
- `tests/commit_selection_spec.lua` — the commit-selection (range) pure helpers
  (spec §13): `range_endpoints` (single-commit `^!`, span `<older>^..<newer>`,
  empty-tree when the older end is a root), `sel_ascend_children` (first-parent
  children first), `sel_step` (extend/contract along the branch, flip at the
  anchor, clamp at tip/root) and `sel_switch` (rotate the parent at a merge /
  child at a split, no-op on a linear path; §13.2/§13.3), and `format_range_detail`
  (the range view's metadata: `N commits  (oldest..newest)` then newest-first
  hash + subject rows; §13.5)
- `tests/worktree_spec.lua` — the working-tree virtual-commit pure helpers
  (spec §3.3/§4.2/§11.8): `parse_status` (the `git status --porcelain` staged/
  unstaged/untracked counter — X vs Y, `??`, renames/adds, mixed, clean),
  `commit_range` for a virtual commit (staged → `--cached`/`to=index`, unstaged →
  `HEAD`/`to=worktree`, real commits unchanged; §11.5), `worktree_label` (the
  graph-row subject + pluralized counts + untracked) and `format_worktree_detail`
  (the commit-view state header + the untracked-additions note)
- `tests/reachability_spec.lua` — `reachable_cone` (spec §12.1: pivot/ancestors/
  descendants, no cousins, viewport clipping); the **lane model** (`build_graph`
  attaches `parent_lanes`/`child_lanes`, sharing one Lane object per edge); and
  `mark_reachable` (the Lane walk): cone markers light, an edge is highlighted iff
  it's in the cone, a sibling sharing a fan stays fully dim (exact, no bus
  over-lighting), and the shared descent/ascent at a separate split/merge line
  keeps a non-trunk cone lane connected through the hub
- `tests/columns_spec.lua` — Phase 1 (`columns.layout`) directly: per-cell
  well-formedness (≤1 vertical, the turn cap), vertical continuity, and a fuzz
  sweep across all five styles; plus track-id reuse (a straight chain is one id;
  a new id only at a branch head or an extra merge parent); plus free-list
  colouring (spec §5.5): each lane keeps one colour for life, concurrent lanes
  get distinct colours, a first-parent chain is one colour, and an ended lane's
  slot is recycled so a later fan stays distinct under a small palette, and a
  slot shared during a brief exhaustion is not returned (and handed to a live
  lane) until its last holder ends (the recycling-leak regression); plus root
  column break (spec §5.1): a branch head is not stacked under a root, and a run
  of stacked roots alternates columns; plus colour generation (spec §5.5): all
  curated slots are used before any generated one, a released colour is not
  reused within `buffer` allocations (breathing room), and surplus generated
  slots are retired so a calmed graph returns to curated colours; plus the
  **boundary seed** (spec §6.2): a seeded lane enters from above in its column
  and stays continuous (the seam row runs no compaction), and the seed colour is
  reserved so a pane-born lane never reuses it
- `tests/pane_spec.lua` — the context-pane layout core (`gitloom.pane`, spec
  §6.2): `boundary_below`/`boundary_above` (the lanes crossing a row's edge, by
  column), `split_boundary` (continue vs terminate via `node_of`), `footer`
  (the continuing lane seeds the layout so the footer's top seam matches the main
  view exactly, with the seam parent translated through `node_of` into a
  collapsed lane), `continue_up` + `header` (the **minimal-connecting-subgraph**
  header: only how the pinned anchors relate to each other + the lanes crossing the
  cutoff — an isolated crossing lane terminates at a **seam head**, two crossing lanes
  meeting at a **confluence** render a junction (incl. a confluence dead-end head and
  nested confluences), an unpinned branch forking off the trunk/an anchor that
  reconnects to nothing is **pruned** (the stray-fork regression), a bubble on a pinned spine
  → node-less junction but an unrelated bubble is pruned, a pinned anchor a labelled
  `◍` even when isolated, isolated seam heads packed onto a shared row — laid out by the
  direct seam-up grid with the seam as the bottom row matching the main view's top
  edge. Each lane keeps its own colour (`lane_of`, the main-view colour so the
  header matches the graph and forks are distinct — the pivot continuation keeps the
  pivot's colour, only an extra fork child takes a new one). Asserted vertically
  id-continuous, **distinct-coloured** (concurrent lanes never share a colour),
  through the wires-connect checker, with `assert_seam_match` (every crossing lane
  present at the seam) and a **minimal-subgraph oracle** (`confluences_of` +
  `assert_no_irrelevant_heads`: every ◍ is a pinned anchor, a crossing-lane begin, or a
  confluence — never an unrelated head) over a **fuzz sweep** of LARGE random DAGs ×
  cutoffs (8–20 commits, uncapped so tall headers are stressed), and replayed against
  a large real-world topology (every cutoff, 0 problems) during verification, the
  header `cap`
  (`keep_first`: keep the tip + seam-nearest rows, report the elided `+N above`
  count), `condense` (the topological condensed graph, both down and `up` modes:
  fork/merge junctions, roots/tips and anchor-ref heads kept, linear pass-throughs
  spliced into edges, edges re-pointed across them, spliced hashes mapped to the
  next kept node toward the root/tip, the anchor-ref filter, false junctions
  spliced, root rendered as a real node), and `continue` (follow the active seam
  lanes' first-parent chains to a root: both lanes converge at their meeting
  junction and reach the root, every node's chain terminates at a root — never cut
  off — and no non-active branch is introduced)
- `tests/header_replay_spec.lua` + `tests/large_topo.lua` — the header replayed end
  to end over a **large real-world repository's full (`--all`) topology** (anonymised to
  synthetic ids — topology only, no hashes/names/messages), driven through the **full
  projection** (`view.owners` → `view.project` → `columns.layout`, first-parent focus,
  HEAD + dev pinned) and `continue_up`/`header` at **every** display cutoff: asserts the
  pinned anchors HEAD and dev keep their **graph lane id** throughout — they never sever
  onto a fresh synthetic id when a merge sits at the cutoff (the merge-at-cutoff
  anchor-severing regression)
- `tests/color_spec.lua` — `gitloom.color`: sRGB↔OKLab/OKLCH round-trips, known
  conversions, and `generate` (golden-angle hues distinct and in-gamut)
- `tests/gitloom_spec.lua` — public surface (setup, command registration)
- `tests/graph_layout_spec.lua` + `tests/graph_helpers.lua` — the lane-layout
  algorithm, tested by **invariants** rather than golden snapshots (so the
  tests survive visualization changes; see below).
- `tests/graph_mirror_spec.lua` — the `mirror` render transform (spec §5.4):
  the same invariant suite must pass on mirrored output, the mirrored grid must
  equal the horizontal flip of the normal grid (reverse + glyph swap), and the
  per-cell color multiset must be preserved (connectors included — guards the
  connector-color scan that flips direction under mirror).

`graph._internal` (`require("gitloom.graph")._internal`) exposes, **for tests
only** (not the public API): `classify_ref`, `group_refs`, `bump_recent` /
`ref_picker_items` (the `<leader>b` ref-picker MRU + ordered entries; §2),
`ref_decoration_index` (picked ref → decoration index for pre-selection; §2),
`display_item` (the per-row renderer — exposed for the §6 ref-window integration
test), `decoration_texts`,
`move_selection`, `ref_byte_col`, `parse_commit_line`, `make_line_buffer`
(the streaming-stdout line de-chunker; §3), `parse_timestamp`,
`format_absolute`, `format_relative`, `parse_show`, `format_commit_detail`,
`format_diff`, `diffstat_files`, `format_diffstat`, `commit_range`,
`range_endpoints` / `sel_ascend_children` / `sel_step` / `sel_switch` /
`format_range_detail` (the commit-selection range + path-walking + range-view
metadata pure helpers; §13),
`parse_status` / `worktree_label` / `format_worktree_detail` (the working-tree
virtual-commit pure helpers; §3.3/§4.2/§11.8),
`reachable_cone`, `mark_reachable`, `build_graph` (Phase 1, delegates to
`columns.layout`), `get_column_chars` (Phase 2, the renderer),
`passthrough_columns` (the dual label mode's vertical-only branch line; §6.1),
`owners_from_refs` (refs → view-builder owners; §10), the branch-mode toggle
helpers `next_mode` / `selected_owner_ids` (§10), `pack_markers` (the
marker-packing pass; §10.4), and `collapse_owners` (the region's collapsible
owners under the cursor; §10.4). `columns.layout` is reached via
`require("gitloom.columns")`; the view builder `view.project` / `view.signatures`
/ `view.owners` via `require("gitloom.view")` (§10).
`listview._internal` exposes `pack_right` (the right-pin budget packer),
`window_right` (the selection-windowed overflow packer — window + left/right `+N`
counts; §6), `refresh_columns` (the column-width packer), and
`rebuild_starts`/`item_index_at` (the buffer-line ↔ item offset map for
multi-real-line items; §6.1).

### Layout testing approach

The lane algorithm is tested by feeding artificial commit DAGs through
`build_graph` and asserting properties, not by comparing to fixed rendered
output. The deliberate choice (see chat history / specification.md §10): the
plugin will support multiple visualizations, so golden snapshots would be a
maintenance treadmill. Two layers, both in `graph_helpers.lua`:

- **Model** — every input commit is laid out exactly once (faithfulness vs.
  the input DAG, which is the oracle — not a re-derivation of the layout).
- **Rendered grid** — a "wires must connect" check on the actual glyph grid:
  no unknown glyphs, no dangling left/right or up/down stubs, crossings pass
  the horizontal wire through a vertical bar, and lane color stays continuous
  (including across crossings).

Color/id-continuity is the **id-continuity** invariant: a lane's id must not
silently change along a straight `│` run (a "lane handoff"). Tests use
`big_opts` (a 64-entry palette) so color is a 1:1 proxy for the *concurrent*
lane id — the colour free list (spec §5.5) only recycles a slot once a lane
ends, so two lanes alive at the same time always differ in colour as long as the
palette outnumbers the live lanes; `big_opts` guarantees that for the test DAGs,
so a handoff can't be masked. The four stable styles pass this exactly across
fuzzing; only `allow_merge_on_split` fails it (column reuse at a merge — see
known gaps), which is why that style asserts structural-only invariants plus the
characterization snapshot.

Invariants must be **sound** (never flag correct output) before being strict.
Glyph-level color/continuity is subtle because junction glyphs (`├ ┤ ┬ ┴`,
turns) are lane *boundaries* where color legitimately changes — only enforce
continuity where it unambiguously holds (straight `│↔│` runs, and across
crossings). A `checker self-test` block feeds deliberately broken grids to
prove the checker still has teeth; keep it passing.

Still uncovered: the listview widget's rendering (needs snacks in the test
runtime). Its pure helpers are testable — `snacks.win` loads lazily (only
`create_win` errors without it), so `listview._internal.pack_right` is covered.

## Key concepts (quick reference)

- **Commit** — a node in the DAG (hash, parents, children, refs, metadata).
  Identity-stable across the stream.
- **Lane** — one drawn edge child→parent
  (`{id, color, begin, parent, highlighted}`), a persistent object living from
  the child's row to the parent's row; `id` is its stable identity and `color`
  (a palette slot from the recycling free list, spec §5.5) drives the colour.
- **GraphColumn** — one cell of a rendered line: its connectivity plus the
  **Segment**s (per-edge wires) it draws. (Was `Track`; renamed.)
- **OrderItem** — a rendered row (`commit`, `merge`, or `split` type) holding
  its commit line `columns` plus optional `split`/`merge` virtual lines and the
  `parent_lanes`/`child_lanes` for reachability.
- **GraphOptions / MergeStyle** — configuration; see specification.md §8.
- **listview** — the generic virtualized list widget the graph renders into.

See specification.md §4–§5 for full definitions.

## Implementation notes

Details not covered by the spec or architecture:

- **Two-phase pipeline** (see ARCHITECTURE.md): **Phase 1** `columns.lua`
  (`columns.layout`) owns lane placement — it assigns lanes to columns and emits
  one Segment per drawn edge with its own connectivity, validated for
  continuity. **Phase 2** `get_column_chars` (in graph.lua) renders glyphs and
  colour from those Segments. `build_graph`/`refresh_columns` are Phase 1 entry
  points (both go through `columns.layout`).
- **Branch modes — the view builder** (`view.lua`, spec §10): a pure
  pre-Phase-1 stage projecting the immutable commit DAG + a view state (per-ref
  `normal`/`collapsed`/`hidden`) into an **OrderItem graph** of DisplayNodes that
  `columns.layout` lays out unchanged. `view.project` computes each commit's
  reachability **signature**, partitions into equal-signature regions, joins to a
  display mode, contracts each **linear** collapsed run to one `◍` head while
  keeping junctions (a fork/merge — ≥2 visible children/parents — stays a real
  node so branch topology survives, §10.3), drops hidden commits, and re-points
  edges. graph.lua keeps
  `repo.order` (raw, 1:1 with commits) as the projection input and `repo.display`
  (the projection) as what the listview renders and `order_at`/`mark_reachable`
  index; `reflow()` rebuilds it and swaps via `controller.set_items`. With
  all-normal modes the projection is the identity, so `repo.display == repo.order`
  and streaming keeps its fast incremental path. `<CR>` cycles a selected ref's
  mode / expands a head; signatures are cached across mode toggles (§10.5).
- **First-parent focus** (`opts.collapse_merged`, default on; spec §10.7, toggled
  by `c`): `view.owners(items, ref_owners, pinned, modes, cm)` builds the owner
  set so **every** owner is **first-parent-only** (`fp_only`) — each covers only
  its tip's first-parent line. The **pinned anchors** (`pinned`, a set of ref
  ids; §10.6) default normal; every other ref and every non-first merge parent
  (an anonymous `merge:<hash>:<i>` owner) defaults collapsed — so the graph opens
  with the anchors' mainline in full and every other branch a `◍` head.
  `view.signatures` honours `fp_only` (propagate only through `parents[1]`).
  **All owners** being fp-only (not just the anchors) is what makes a branch
  attributed to *its own* commits, so collapsing/expanding one branch doesn't
  drag in the earlier branches its history merged through (spec §10.2). It is a
  recomputed default, not a seed: `view_state.modes` holds only explicit user
  mode overrides, `view_state.effective` the resolved mode per owner (drives the
  `<CR>` cycle's starting point and the footer `focus` indicator). The
  stream-completion handler calls `reflow()` so the default applies on open.
- **Pin axis** (spec §10.6, toggled by `P`): pin is the **anchor** set the focus
  default folds toward — it *generalises the trunk* (one anchor → a set). HEAD is
  pinned by default; `view_state.pinned` holds explicit per-ref pin/unpin
  overrides and `effective_pinned()` resolves the live set ({HEAD} ∪ overrides),
  passed to `view.owners`/`collapse_owners` in place of the old single `trunk_id`.
  Pinning changes only the default *mode* (anchors normal, rest collapsed), not
  `fp_only` or the owner tips, so it does **not** invalidate the signature cache
  (like a mode toggle). `P` uses `branch_under_cursor`, pins only real refs (drops
  anonymous merge owners), reflows, and repositions the cursor. Anchors are the
  foundation for the planned context panes (spec §6.2).
- **Marker packing** (`opts.pack_markers`, default on; spec §10.4, toggled by
  `p`): a **marker** is a messageless node (today a collapsed head — `◍` + ref
  labels + count, no subject). `pack_markers` is a post-Phase-1 pass run in
  `reflow` after layout: it merges adjacent overlay-compatible marker rows into
  one **marker-group** OrderItem (`type == "markers"`, holding the marker
  DisplayNodes + merged columns) — multiple `◍` on one line, the one exception to
  "one commit per line" (§5.1). Overlay-compatible = each column has ≤1 node and
  ≤1 lane id and no horizontal overlap; compaction makes only safe merges
  compatible. On a packed line `h`/`l` selects a marker (`marker_units`); the
  listview stays 1-item-per-line (a group is one item). The marker labels render
  via `line_right` with `line_right_align = "left"` (left-aligned after the graph)
  so they get the windowed `+N` overflow (§6) around the selected marker instead of
  truncating the row with `…`. Selecting a marker drives the §12 reachability
  cone (not a flat `palette.selected` repaint): `update_cone` seeds it from the
  selected head via `mark_node_cone` (walking the DisplayNode `.parents`/
  `.children` and lighting each lane via its shared edge object by `node_loc`, like
  `mark_path`), so the selected branch (its `◍` node, label, and lane) stays its
  normal colour and the sibling heads/branches on the row dim — exactly like
  moving onto a normal head (§12). `h`/`l` calls `update_cone` before the redraw so
  the dimming follows the selection; no selection ⇒ the line is neutral (all lit).
- **Collapse interaction** (spec §10.4): acts on the *region under the cursor*,
  not a ref — `branch_under_cursor(line)` resolves the selection (ref/marker) or
  the commit's signature (`collapse_owners`) into `{state, owners, follow,
  commit}`. `<Tab>` is the 2-state collapse⇄expand toggle (`set_branch` flips the
  owners, reflows, then `goto_hash` repositions the cursor on the result so it is
  repeatable). `<CR>` opens an action menu (`vim.ui.select`) — examine / diff /
  collapse / expand / hide, listing every marker by name on a packed line.
- **Sticky columns** (listview, anti-bounce; spec §6): the shared column widths
  recompute from the visible range each scroll, so a varying column bounces. A
  column can *only grow* (never shrink): `col_max` (a per-column cap, implies
  sticky — the author column at 25) and `col_sticky` (no-cap sticky columns, a
  list or a function — the graph column when `opts.mirror` is on, whose
  right-aligned content would otherwise shift as the lane width changes).
- **Node-less junctions render inline** (spec §10.4): `columns.layout` skips the
  separate split/merge line for a node-less junction (it carries no message), so
  a join is one row, not a fan line plus an empty lane row.
- **Junction markers** (`opts.junction_markers`, default on; spec §10.4): a kept
  fork/merge inside collapsed branches (a junction, flagged `junction=true` in
  `view.project`, `collapsed=false`) renders **node-less** — `get_column_chars`
  draws its cell as box-drawing lanes (`├ ┬ ┼ …`, the new `is_node` gate) instead
  of a commit node, and `display_item` blanks date/author/message (keeps refs +
  the split/merge fan lines). So the split topology shows without the commit's
  weight. Topology model/invariants are unchanged (it stays a real node).
- **init.lua is a thin facade**; graph.lua holds git I/O + the window/keymap
  glue + Phase 2 render + reachability + the commit view; columns.lua is Phase 1;
  view.lua is the pre-Phase-1 projection (§10); pane.lua is the context-pane
  layout core (boundary-line extraction; `continue`/`condense`/`footer` = the
  footer's down-rebuild; `continue_up` = the header's **minimal connecting subgraph**
  (only how the pinned anchors relate to each other + the lanes crossing the cutoff —
  the "seeds"): a three-pass reachability over the **display** DAG, up-only —
  **Pass 1** `seed_reach` (each boundary column + each pinned tip is a seed; walk up via
  `children`; a node reached by ≥2 distinct seeds is a **confluence**), **Pass 2**
  `useful` (walk down from confluences + pinned tips, marking ancestors that lead up to
  one), **Pass 3** induce (walk up from useful seeds keeping only useful children; a
  non-useful seed → a **seam head** that terminates at the seam; then each pinned anchor
  is connected **down** its own first-parent spine to the seeded part — induct for
  *edges only*, NOT re-walked up, or the up-walk pulls in every collapsed fork off the
  trunk and balloons the header. That down-connect fixes the merge-at-cutoff anchor-severing bug:
  when both boundary lanes begin at one merge at the cutoff, the up-walk's single
  first-parent chain dead-ends at a collapsed node before reaching an anchor on a folded
  branch, leaving it inducted-but-disconnected and rendered as a lone head on a fresh
  lane id (HEAD jumped to id 39); the spine nodes are all `useful` so `condense` splices
  them and the header stays minimal. So an unpinned branch
  forking off the trunk that reconnects to nothing is **pruned** (no stray feature
  heads — the stray-fork regression); a branch that only merges back condenses to a node-less
  junction; ≥2 useful children → junction, 1 → collapse, 0 → head (a dead-ending
  confluence caps). Invariant: every above-seam boundary `begin` is in the node set
  (useful node or seam head) so no seam lane drops; `condense(up)`; the **direct seam-up
  grid** `header` — a bottom-up sweep seeded from the boundary so the seam is the
  bottom row, columns never reused, each lane drawn in **its own colour**
  (`lane_of`, the main-view colour; the pivot continuation keeps the pivot's colour,
  an extra fork child takes its own) and unpinned heads packed onto as few rows as
  possible (`pack_heads`/`overlay_rows` — pinned anchors and junctions keep their own
  line); `cap`; §6.2). `boundary_at(.., up=true)` reads a
  fork seam item's **split** (virtual) line so the fork's divergence is captured. **Both panes are wired** via
  graph.lua `update_panes` (gated by `opts.panes`, toggled by `F`): borderless
  overlays (footer at the bottom, header at the top) whose seam is read from the
  rendered line at a screen row (`boundary_at`/`seam_for` via `screenpos`, so
  split/merge virtual lines work; `up=true` selects the header's edge). The footer
  continues the seam lanes down to the roots (pinned refs below the cutoff
  included); the header rebuilds the focused up-sub-DAG (`dnode`/`order_of` resolve
  the projected nodes; `lane_main[hash]` from each item's `parent_lanes[1]` gives
  `lane_of` the main-view colour so the header matches the graph) and lays it out
  seam-up with distinct colours and packed unpinned heads — `converge_header`
  min-fit-sizes from the `(#pinned tips above)+1` guess up to `HEADER_MAX` (8),
  capping over-tall headers with `+N above`, and **hides the header at the top**
  (`w0` display index ≤ 1). HEAD plus `master`/`main`/`dev` are pinned by default
  (`effective_pinned`, so they get their own labelled lines); `P` toggles others.
  Full cross-level head packing (all unpinned heads on ONE row, vs. today's
  consecutive packing) and moving the rebuild off the cone-debounce are pending.
  listview.lua is a git-agnostic reusable widget.
- **`graph._internal`** exists solely for tests (pure parsers + the
  `build_graph`/`get_column_chars` seam). Do not route production code through it.
- **Vendored duplication is intentional** — `compose` lives in both graph.lua
  and listview.lua, and `make_future` is gitloom's own minimal promise. See
  "Relationship to loomworks" before deduplicating.
- **setup() config is not yet wired** to `:GitloomGraph` (specification.md
  §8 "Known gap"). The command uses built-in defaults.
- **Ref label modes** (`opts.label_mode`, cycled by `B`; spec §6.1) are a
  placement choice in `display_item`: `right` puts refs in `line_right`
  (right-pinned, default), `inline` composes them into the flex column before the
  message, `dual` draws a labelled commit on **two real buffer lines** — row 1 is
  the graph (node) + labels, row 2 is the message with the graph continued
  downward via `passthrough_columns(item.columns, "down")` (no node). A `dual`
  commit with no labels stays one line. `dual_two_line(opts, commit)` is the
  single predicate shared by the listview's `line_count` (buffer allocation) and
  `display_item` (rendered rows) so they never disagree.
- **Multi-real-line items**: `repo.order` stays 1:1 with commits; the listview
  maps a *buffer line* to its order index via a prefix-sum offset
  (`rebuild_starts`/`item_index_at`, exposed as `controller.item_at`/`item_start`).
  graph.lua's `order_at(line)` is the only boundary translation (used by the
  keymaps, cursor parking, and the cone viewport, which converts `w0`/`w$` to
  order indices). `DisplayElement.lines` (a list of real rows) generalises `line`;
  `above`/`below` are stacked virtual rows attached to the first/last real line.
  `B` calls `controller.relayout()` (resize the buffer + rebuild the map) because
  it changes per-item line counts; `m`/`M`/`d`/`H`/`i` stay on `refresh()`.
  This is the deferred "real branch line" alternative, now built; the cursor sits
  physically on the labels, and `CursorMoved` pre-selects the first label when it
  lands on a labelled commit's first row.
- **`allow_merge_on_split` — the lane handoff**: with that flag on, an extra
  parent reuses a column the merge just freed, so one cell legitimately holds an
  ending child edge and a starting parent edge — two turns, two different lanes.
  Phase 1 still emits them as distinct per-edge Segments (each continuous), so
  the model is faithful; but the rendered cell shows a single colour, so its
  vertical colour changes mid-column. Grid colour-continuity is therefore not
  asserted for this style (structural invariants only) and a characterization
  test (`random_dag(7, 108)`) locks the current look. The other four styles pass
  the full suite incl. grid colour. This is the one place a cell may have two
  turns (the per-column cap is 1 otherwise).
- **git runs in Neovim's cwd** — `jobstart` is called without an explicit
  `cwd`, so the graph reflects the current working directory's repo.
- **External diff is a pluggable provider** (specification.md §11.5): the
  `diff.open` callback takes a **`DiffRange`** (`{ rev, from, to }`), not a
  commit, so graph range-selection reuses it. `commit_range(commit)` builds a
  single-commit range (`<hash>^!`, empty-tree for roots); `range_endpoints(newer,
  older)` builds a commit-selection span (`<older>^..<newer>`; §13.5).
  The default `open` runs diffview guarded; diffview is the only optional
  dependency beyond snacks. Provider/label/`D` are window glue (not unit-tested);
  `commit_range` is.
- **Commit selection (range)** (specification.md §13; toggled by `V`): a modal
  selection that is a **path along one branch** over the visible projection
  (`repo.display`), not a contiguous row block. State lives in `sel` (in `M.open`):
  `path` (DisplayNodes newest-first), `anchor`/`cursor` (the two ends — always
  endpoints, so the path is exactly `anchor..cursor`), and `dparent`/`dchild` (the
  branch chosen at each junction for `h`/`l`). The walk is pure
  (`sel_step`/`sel_switch`/`sel_ascend_children`) over the DisplayNode graph
  (`.parents` first = trunk, `.children`); the window glue resolves rows
  (`goto_hash`), lane/marker emphasis (`mark_path`, reusing the §12 dimming via
  `view_state.cone`), the cursor-on-lane parking, and the range (`selection_range`
  → `range_endpoints` → the **literal** `<older>^..<newer>` `DiffRange`). `j`/`k`
  and `<C-d>`/`<C-u>` are bound to walk while active and **fall through to the
  builtin motions** (fed without remap) when inactive; `h`/`l` switch branch while
  active (else the §2 ref selection). `<CR>` opens the **range commit view**
  (§13.5): `open_commit_view(opts, nil, { range, commits, title })` — the same
  view generalised with a `range` arg, listing the selected commits
  (`selection_commits` → `format_range_detail`) and rendering the combined range
  diff (`fetch_range_diff` = `git diff <base> <to>`) through the existing
  diffstat/diff/context-header pipeline; its action label and `D` open the range
  in the external provider. A `reflow()` recreates DisplayNodes, so it drops any live selection
  (stale references). Navigation walks the DisplayNode edges directly, so it
  passes *through* collapsed heads (including packed ones); a `node_loc` index
  (hash → {item, col}, built with `display_index`) lets `mark_path` light a head's
  lane (the Lane object is shared with the child's row via `seg.edges`) and marker
  even when packed, and `display_item` draws the selected head with
  `palette.selected` and dims the other heads on the shared line (§13.4).
  `selection_toggle` (`<Tab>` while selecting) folds/unfolds the cursor's head in
  place: it captures the path **by member hash** (a head expands to its whole
  region so the unfolded branch stays selected/lit — the diff range is unchanged),
  applies the mode + reflow, re-resolves against a fresh hash→node map (region
  members → their head, dedup consecutive), keeps the anchor on its end and the
  cursor on the toggled end, and restores the saved scroll (`winsaveview`/
  `winrestview` topline) so the view holds.
  Selection isn't started *on* a packed-marker line. The pure helpers are tested;
  the window glue is not (like the other window glue).
- **Reachability dimming = Lane model + walk** (specification.md §5, §12):
  Phase 1 (`columns.layout`) makes one **Lane** (edge `{id, begin, parent,
  highlighted}`) per parent/child edge, wires `OrderItem.parent_lanes`/
  `child_lanes`, and binds each Segment to the Lane it draws. A separate split/
  merge line's shared descent-into-the-commit / ascent-out-of-the-commit is one
  multi-edge Segment (so a non-trunk cone lane stays connected through the hub).
  `mark_reachable` walks the Lanes from the pivot (parent_lanes = ancestors,
  child_lanes = descendants), setting `highlighted`, and first resets every Lane
  *drawn* in the window (via each Segment's edges) so persistent lanes don't keep
  stale highlights. This is **exact** — a sibling sharing a fan is a distinct
  Lane, so it stays dim. `get_column_chars(opts, columns, emphasis)` renders by
  unioning the highlighted Segments' connectivity (or all when none is lit) and
  dims out-of-cone wires via `dim_hl` (the cached, `ColorScheme`-rebuilt
  hue-preserving blend, factor `palette.dim`; flat `NonText` without truecolor).
  Out-of-cone row fields (date/author/message/refs) dim via the `rh` helper.
  Recompute is **debounced** (~60ms) on cursor move / scroll (only the last,
  after the cursor settles, walks); `m` reflow / `H` toggle / stream completion
  recompute immediately. `emphasis` is false (all lit) on `H` off or no pivot.
  `reachable_cone` stays a pure, tested helper; production uses `mark_reachable`.
- **Neovim >= 0.10** — relies on the 4-arg `vim.str_byteindex` and the
  decoration-provider API.
