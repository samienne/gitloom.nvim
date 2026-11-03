# Context-pane tests

Scope: per-spec coverage of the header / footer panes, their seams and the screen-row model (§6.2). [specification.md](../../../specification.md) and [ARCHITECTURE.md](../../../ARCHITECTURE.md) remain authoritative. Index: [../testing.md](../testing.md).

- `tests/pane_spec.lua` — the context-pane layout core (`gitloom.pane`, spec
  §6.2), **plus the multiple-above-rows contract** (§5 Line): a REAL `gutter` layout
  with two (and three) virtual lines above one commit, driven through
  `screen_lines` and BOTH seam functions at every window top/bottom × cover, with
  an oracle for "which line is rendered at screen row N" built independently of
  `screen_lines`. It pins the direction convention head-on — `virt = -1` is the row
  NEAREST the columns line, so the topmost of `n` is `virt = -n` = `above[1]` — and
  that `header_seam` always butts the TOPMOST above-row (a block start), while
  `footer_seam` never lands inside a block; `pane.seam_line` is the one decoder and
  inverting it fails three of these tests. Also covers:
  `boundary_below`/`boundary_above` (the lanes crossing a row's edge, by
  column), `split_boundary` (continue vs terminate via `node_of`), `mark_pane_cone`
  (the reachability-emphasis propagation: down `.parents` = ancestors, up
  `.children` = descendants, a confluence in-cone from the join, empty seeds → empty
  cone; §6.2), `footer`
  (the continuing lane seeds the layout so the footer's top seam matches the main
  view exactly, with the seam parent translated through `node_of` into a
  collapsed lane), `continue` (active lanes reach a root; **convergence junctions**
  kept when ≥2 crossing lanes land on the same parent — the seam-discontinuity
  fix — plus a fuzz sweep asserting no crossing lane strands at the seam across
  random DAGs × cutoffs), `continue_up` + `header` (the **minimal-connecting-subgraph**
  header: only how the pinned anchors relate to each other + the lanes crossing the
  cutoff — an isolated crossing lane terminates at a **seam head**, two crossing lanes
  meeting at a **confluence** render a junction (incl. a confluence dead-end head and
  nested confluences), an unpinned branch forking off the trunk/an anchor that
  reconnects to nothing is **pruned** (the stray-fork regression), a bubble on a pinned spine
  → node-less junction but an unrelated bubble is pruned, a **2×2 parallel-merge diamond**
  (two crossing lanes both forking to the same two children) declutters to clean parallel
  lanes — neither merge stays a junction, a genuine confluence preserved, a pinned anchor a labelled
  `◍` even when isolated, isolated seam heads packed onto a shared row — laid out by the
  direct seam-up grid with the seam as the bottom row matching the main view's top
  edge. Each lane keeps its own colour (`lane_of`, the main-view colour so the
  header matches the graph and forks are distinct — the pivot continuation keeps the
  pivot's colour, only an extra fork child takes a new one). Plus a **colours follow
  the main view** block (§6.2 Colour): two heads never alive together keep their
  shared main-view colour (only lanes on one drawn row are de-collided), a lane
  recoloured at an outranking ref (§5 "Carried refs") is drawn above that node in the
  colour the main view gives that stretch, a fork child
  reached through a merge's SECOND parent is drawn in that edge's lane colour, and
  without generated colours (`ncolors`) a replacement stays in the palette and off the
  pinned slots; a slightly muted `-k` (a remote's colour, `rank.drawn` level 2) is
  kept and slot k never handed to another lane. Asserted vertically
  id-continuous, **distinct-coloured** (concurrent lanes never share a colour),
  through the wires-connect checker, with `assert_seam_match` (every crossing lane
  present at the seam) and a **minimal-subgraph oracle** (`confluences_of` +
  `assert_no_irrelevant_heads`: every ◍ is a pinned anchor, a crossing-lane begin, or a
  confluence — never an unrelated head) over a **fuzz sweep** of LARGE random DAGs ×
  cutoffs (8–20 commits, uncapped so tall headers are stressed), and replayed against
  a large real-world topology (every cutoff, 0 problems) during verification, the
  header `cap`
  (`keep_first`: keep the tip + seam-nearest rows, report the elided `+N above`
  count) and the footer `cap` (keep the root together with the `virtual` lines drawn
  directly above it), `drawn_lines` (a row's above / commit / merge lines flattened, one
  entry each), the pure **whole-commit seam** functions — both in **screen-row space** on the
  `screen_lines` model, exact mirrors: `header_seam(sm, ts, cover)` walks **down** from the
  top visible **screen row** `ts` to the first block **start** leaving ≥ cover rows above
  (seam = that item's **split** fan else columns; the header butts its top edge), and
  `footer_seam(sm, bs, cover)` walks **up** from the bottom visible **screen row** `bs` to
  the first block boundary leaving ≥ cover rows below (seam = that item's **merge** fan else
  columns). Both cover whole commit blocks so a virtual split/merge line is never split
  across the seam (the fix for the seam virtual-line drift — the header once used a
  display-index walk that assumed the top item's columns was the window top and drifted by
  a partial split fan above it), plus `header_ts`/`footer_bs` (the cursor-anchored
  top/bottom screen row) and `screen_lines` (flatten display → real columns + virtual
  split/merge rows, with display-index↔screen-row translation),
  `condense` (the topological condensed graph, both down and `up` modes:
  fork/merge junctions, roots/tips and anchor-ref heads kept, linear pass-throughs
  spliced into edges, edges re-pointed across them, spliced hashes mapped to the
  next kept node toward the root/tip, the anchor-ref filter, false junctions
  spliced, root rendered as a real node), `continue` (follow the active seam
  lanes' first-parent chains to a root: both lanes converge at their meeting
  junction and reach the root, a root two lanes fork from stays a `◎` node — not a
  node-less junction — every node's chain terminates at a root — never cut
  off — and no non-active branch is introduced), and the **chunking hook** (the
  async pane build, §6.2): a deep first-parent chain invokes `continue`/
  `continue_up`/`condense`'s optional `yield`, and the chunked output is identical
  to the synchronous (no-yield) path, and the **rebuild gate** `pane.gate` (§6.2):
  the three-call state machine `started`/`built`/`dropped` + `decide`, driven as
  SEQUENCES because the defect it pins is one of timing — an ABANDONED build must
  leave the gate uncredited (so the next debounce rebuilds), an in-flight one must
  not be restarted every tick, `built` must promote only a live `started`, and a
  later abandonment must not disturb the key already on screen. Reverting the
  credit to `started` fails four of them
- `tests/header_replay_spec.lua` + `tests/large_topo.lua` — the header replayed end
  to end over a **large real-world repository's full (`--all`) topology** (anonymised to
  synthetic ids — topology only, no hashes/names/messages), driven through the **full
  projection** (`view.owners` → `view.project` → `columns.layout`, first-parent focus,
  HEAD + dev pinned) and `continue_up`/`header` at **every** display cutoff: asserts the
  pinned anchors HEAD and dev keep their **graph lane id** throughout — they never sever
  onto a fresh synthetic id when a merge sits at the cutoff (the merge-at-cutoff
  anchor-severing regression). Plus **§6.2 Colour** at every cutoff, every policy
  (64-colour palette) and `compact` with 6 colours + generation: every header segment
  is in its lane id's main-view colour and every node in its main-view node colour —
  exactly 0 mismatches (nodes not asserted under `gutter`: a head reached only through
  a merge's second parent draws that edge, the main view colours its node by its
  first-parent lane — 3 nodes there). Fails on the pre-fix header (si=42 seg id=22).
  The ranking is built with `h.ranked` (pins `dev`, `enne`; `enne` current), as
  `ctx:sync_ref_rank` publishes it; one lane id may show several main-view colours
  (each on its own stretch) and a header segment must be in one of them. Three more
  configurations ("pinned pick recolour") add a local `pick` three first-parent commits
  below HEAD's tip, pinned first (pins `pick`, `dev`, `enne`): a better pin rank than
  `enne` (pin rank comes first, §5), so it outranks enne and recolours enne's lane from
  there (spec §5 "Rank", "Carried refs"). Each asserts that recolour happens — the lane
  id at pick's commit carries two main-view colours — so the case cannot pass
  vacuously (an unpinned ref, or one pinned below `enne`, would not outrank it). `tests/pane_spec.lua`'s "colours follow the main view"
  block pins the LumeScene shape on a minimal DAG under every policy, adapted so the
  outranking ref is pinned `dev` itself (recolouring enne's lane to slot 1)
- `tests/footer_replay_spec.lua` (+ `tests/large_topo.lua`) — the **footer** counterpart:
  the same real-world topology through the **full projection**, then the footer built at
  **every** cutoff and for **every rendered line the seam picker can land on** — a commit's
  `columns` line AND its virtual `split`/`merge` fan lines. Asserts the footer's **top row
  reproduces the seam line** (same column + id — no jog), no crossing lane **strands**
  (empty `terminate`), the pane's rows are in **topological order** (no row before
  an in-pane child), and lane **id-continuity** down every row; as drawn with the
  pane style, consecutive lines wire together and **nothing leaves the last line
  downward** (every lane lands on a node — the two-lane "loop" regression, where a
  collapsed root head the hash-keyed `order_of` could not rank sorted above its child). Guards the footer-layout
  stage against a mishandled virtual-line seam (the class the header's `header_seam` fixed).
  The seam-**picking** itself is the pure `pane.footer_seam` (below), unit-tested in
  `pane_spec` alongside `header_seam`. Plus the footer **as drawn**, under every layout
  policy with the pane's OWN inline merge style: `pane.footer`'s `rows` are drawn lines
  (one screen row each, `pane.drawn_lines`), so consecutive entries must wire together —
  same column, same lane id. Guards the `gutter` regression where the window drew only
  each row's commit line and dropped the policy's handover rows (§5.6), leaving a
  floating turn and an orphaned root
- `tests/screen_window_spec.lua` — the **FAITHFUL** screen-coordinate test: renders a buffer
  with `virt_lines` in a **real nvim window** EXACTLY as gitloom does (split →
  `virt_lines_above=true`, merge → below) and checks against nvim's ACTUAL rendering
  (`screenpos`/`winline`) across every cursor line × zt/zz/zb × several heights × bordered/
  unbordered: (1) `pane.screen_lines` reproduces nvim's layout (screenpos deltas == model
  `cols` deltas); (2) the **cursor-anchored** `footer_bs(sm, cursor, winline(), WH)` names the
  same `(line, virt)` nvim renders at the window bottom — cross-checked independently via
  `line('w$')`+`screenpos` (non-tautological), incl. split-at-bottom AND merge-at-bottom;
  (3) it **catches the bug** — the old `w0`+`win_screenpos` formula is wrong in real cases
  (`prod_wrong > 0`) while the cursor-anchored one is always right. The **header mirror**:
  the cursor-anchored `header_ts(sm, cursor, winline())` names the same `(line, virt)` nvim
  renders at the window **top** — cross-checked via `line('w0')`+`screenpos`, incl.
  split-**above**-columns AND merge-above tops — and catches the header bug (the old
  `ts = cols[w0]` assumption is wrong where the cursor-anchored one is right, `prod_wrong > 0`).
  Documents the nvim facts:
  `winline`/height are window-relative (border-robust), `win_screenpos` is the frame top,
  `line('w$')`/`line('w0')` are the last/first visible-**columns** line (a split at the top
  belongs to `w0`'s own fan above its columns)
- `tests/footer_bottom_spec.lua` — the footer **hides at the bottom** (§6.2), in a REAL
  nvim window with `virt_lines`: through the production `footer_bottom` → `footer_seam`
  path, no seam (`"at bottom"`) when the whole graph fits in the window (filler rows
  below) or after `G` (the last row at the window bottom), while one `<C-y>` up still
  builds a seam at the true bottom; plus the pure `footer_bottom` boundary (declines
  exactly when the unclamped bottom reaches the last row) and its agreement with
  `footer_bs` whenever it does not decline. Guards the clamped-`bs` regression
  (48fad8c) that drew a footer over the graph's own last commits
- `tests/footer_window_spec.lua` (+ `tests/large_topo.lua`) — the **count-based** screen model
  (§6.2): `pane.screen_lines` is exercised for the default single split/merge AND for
  **MULTIPLE** virtual rows above/below + dual-mode 2-row columns (count-based, signed `virt`
  offsets, not a boolean). Plus the sliding-window `footer_bs` bottom-derivation over the
  full-projection gitloom topology (pure synthetic frame) and a seam-visibility pipeline check
- `tests/header_window_spec.lua` (+ `tests/large_topo.lua`) — the **header** counterpart of
  the footer window sweep: the same full-projection gitloom topology, sliding the window
  **top** down every screen row (columns AND split-above-columns), asserting `header_ts`
  returns the true top (naive `cols[w0]` wrong where a split sits above, `naive_wrong > 0`)
  and the `header_seam` it implies rounds to a whole commit block that is fully visible
- `tests/footer_commit_view_spec.lua` — the panes vs the **commit view** (§6.2/§14.3),
  on the REAL graph of this repository (needs snacks in the lazy install dir): with the
  footer up, `<CR>` swaps the host to a commit view (BufWinLeave closes the panes); a
  pane rebuild then fired by an async path (`update_panes`/`maybe_update_panes`, as the
  stream / reflow / cone debounce / a resumed build chunk would) must NOT re-open the
  footer over it (`drive_panes` abandons while the host shows another buffer), and
  `<C-o>` back to the graph rebuilds it (on_show)
