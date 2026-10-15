# Layout engine notes

Scope: the Phase 1/Phase 2 layout engine: the pipeline, the resumable sweep, layout policies (incl. `gutter`), lane identity and colours, junction rendering, and reachability dimming. [specification.md](../../specification.md) and [ARCHITECTURE.md](../../ARCHITECTURE.md) remain authoritative; this file is implementation detail for working on the code. Index: [CLAUDE.md](../../CLAUDE.md).

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
  its commit line `columns` plus an `above` **list** of virtual lines (the §5.2
  split fan, and under the `gutter` policy its two handover rows — so one commit can
  render three lines above its own), an optional `merge` virtual line below, and the
  `parent_lanes`/`child_lanes` for reachability. `pane.seam_line` is the single
  decoder of a seam's `virt` against that list (`-1` = nearest the columns line).
- **GraphOptions / MergeStyle** — configuration; see specification.md §8.
- **listview** — the generic virtualized list widget the graph renders into.

See specification.md §4–§5 for full definitions.

## Implementation notes

- **Two-phase pipeline** (see ARCHITECTURE.md): **Phase 1** `columns.lua`
  (`columns.layout`) owns lane placement — it assigns lanes to columns and emits
  one Segment per drawn edge with its own connectivity, validated for
  continuity. **Phase 2** `get_column_chars` (in graph.lua) renders glyphs and
  colour from those Segments. `build_graph`/`refresh_columns`/`extend_columns` are
  the Phase 1 entry points, and all three run the same sweep.
- **The sweep is resumable** (§3.1): `columns.session(opts, seed)` holds the
  per-row state open and `session.extend(items, from, yield)` sweeps more rows
  onto the end; `columns.layout` IS a session extended once, so the one-shot path
  is unchanged by construction. `graph.extend_columns(opts, order, start_pos,
  stream)` is the streaming caller — `on_batch` continues the sweep instead of
  re-laying the whole accumulated order, which is what the ignored `start_pos`
  argument used to cost (N²/2B commit-layouts per stream; 355 s of layout for
  12,000 commits of a 293-ref repository, vs 4.3 s resumed).
  **Why resuming is exact, and where it stops being exact.** The sweep is a strict
  top-down fold — a row's output is a function of (state after the previous row,
  this row's commit) — and `git log --topo-order` emits a parent only after every
  one of its children, so a streamed row's `.parents`/`.children` are final the
  moment it is appended and nothing below can change it. Hence a prefix layout is
  exactly the first rows of the whole layout. Verified, not assumed: 0 differing
  rows for `compact` / `survivors` / `linear` / `straight` over two real
  repositories x 5 merge styles, and **106–128 differing rows for `gutter`**,
  whose `gutter_prepass` reads the NEXT subject row. A policy with a `prepass`
  therefore reports `lookahead` and `extend_columns` rebuilds in full there.
  It also falls back on a changed layout fingerprint or a non-append `order`, so
  the fast path is an optimisation and never a correctness cliff.
- **Layout policy** (`opts.layout_policy`, default `"compact"`, cycled by `C`;
  spec §5.6): lane placement is a named enum — `compact` (linear-commit slide +
  survivor compaction, today's behaviour), `survivors` (no slide), `linear` (no
  survivor compaction), `straight` (neither; every lane holds its column for
  life), and `gutter` (`straight` plus a column constraint: the **lane** owning the
  current subject row is held in a fixed column beside the message, so a run of
  commits on one lane draws a straight vertical with nodes on it and no horizontal
  at all). The first four are **chains of the existing stages** in `columns.lua` —
  no new stage code — dispatched through a `POLICY` record `{ body, seam, prepass }`.
  `straight` reuses `layout_seam` verbatim, so "straight is the no-move chain" holds
  by construction. `gutter` adds THREE stages (`evict_gutter`, `claim_gutter`,
  `place_gutter`) plus a `prepass` (`gutter_prepass`) and two pure decisions — the
  merge-side `gutter_swap` inside `place_gutter` (gated by the extracted predicate
  `merge_swap_index`) and the split-side `split_swap` inside `evict_gutter` — and
  touches the shared ones only through four
  `state` fields — `state.gutter`, `state.cont` (the index of the outgoing entry that
  continues at the node column; every reader spells `state.cont or 1`, so `1` is the
  un-swapped path by construction), `state.own_lane_up` and `state.reserve` (the
  handover column, below). (`state.split_swap` /
  `state.up_foreign` are two more, read only by the gutter's own stages.) All are nil,
  and therefore inert, under every other policy — verified cell-for-cell against the
  baseline over glyphs, highlight groups AND every Segment's
  `id.colour.connectivity`: **0 differing over 191,364 signature Lines** (4 policies ×
  4 merge styles × 3 corpora × 2 projections), and **0 over 190,384** re-verified the
  same way for the split swap. `gutter` is the policy the `prepass`
  hook exists for (it is also kept for the reserved `interval` placement); it is
  also the one policy whose `seam` is NOT `layout_seam` — that chain does not apply
  the column constraint. **The gutter changes hands on
  two virtual rows of its own, one lane each** (`evict_gutter` moves the occupant
  out, `claim_gutter` turns the arriving lane in), never by a same-row swap and
  never on a commit Line: two lanes transposing must both bend in the gutter cell,
  which renders `├─┤` — the same glyph a fan bus draws — with one colour for two
  wires. So there is no swap glyph. **The occupant to evict is whoever is in the
  column** — a survivor *or* one of the commit's own converging children; reading it
  as "a survivor only" (equivalently, reading the claim's skip test as "any incoming
  lane already in the gutter" instead of "the claimer") is what drew a fork's split
  hub in the *ending* branch's colour while the spine below it was the trunk's, since
  §3.1's ordering routinely parks an ending lineage in the gutter right above a fork
  (85 of 986 nodes on a 1040-commit repo expanded; `compact` showed 0–1, hence it
  read as gutter-specific).
  **The handovers that are avoided rather than paid for** are TWO swaps, one per fan
  (§5.6), and they are gated separately.
  **`gutter_swap`** — at a merge, hand the gutter to a **non-first** parent so the
  branch owning the next subject row is already in it. Gated on THREE clauses, all
  required — (1) that
  parent's next commit is earlier in row order than the first parent's, (2) it OWNS
  the next subject row, (3) this merge is its only in-set child so it can KEEP the
  gutter. Clause 2 is the gate: with clause 1 alone it fires at 100% of merges in the
  shipping FOCUSED view and buys nothing (a `◍` head sits after the merge by §3.1
  lineage grouping, and a head owns no subject row), measured at crossings 116 → 209,
  rows +29.5%, node-in-gutter 1.000 → 0.943. Clause 3 makes the saving *provable*:
  without it a sibling lane may win §5 identity at that parent (a better rank or a
  first-parent edge), ours is evicted
  anyway, and the break buys nothing — it declines exactly the unearned fires
  (15 of 100 on a 1040-commit repo expanded, 0 of 11 on `large_topo`). Cost on that
  repo expanded: crossings 598 → 512, rendered Lines 1593 → 1423, ink −12.3%,
  handover Lines 445 → 275, width and node-in-gutter unchanged, lane stability
  0.912 → 0.922, and 85 spine breaks each removing one handover.
  **`split_swap`** — the mirror at a fork, needing NO lookahead (the sweep is
  top-to-bottom, so the gutter's occupant is already decided): where the occupant is
  one of this commit's own converging children and is not the lane it continues, the
  node takes the gutter WHERE THE CHILD ALREADY IS instead of evicting it and claiming
  the column back. Decided in `evict_gutter` (it just returns); `claim_gutter` declines
  on `state.split_swap` and `place_gutter` needs no change, because `seed_bars` marks
  `occ0` for SURVIVORS only, so an incoming occupant never reads as "held" and the node
  column is already the gutter — which is why **node-in-gutter cannot regress**. Three
  clauses: (1) the occupant is a converging child, NOT a pass-through survivor (a
  survivor's through-vertical cannot hold the node, and declining to evict it would push
  the node off the gutter — the hard floor); (2) it is not the continuing lane; (3) no
  parent swap is also available unless the fan-in has a Line of its own (see the
  precedence below). With a separate split Line it breaks **no spine at all** — `fan_in`
  labels the hub from `commit_incoming`, i.e. the commit's own lane wherever the node
  landed, so the descent/node/continuation are one id and the trunk simply converges as
  a fan arm; only a fully INLINE fan-in leaves a break, priced 1:1 in the two rows it
  removed, and there the node needs no `own_lane_up` because its `down` wire IS its own
  lane. **Precedence**: the two compose with a separate split Line (opposite sides of a
  cell whose up wire is still the commit's own lane), but on an inline fan-in they would
  leave the commit's own lane on NEITHER side, so `split_swap` consults
  `merge_swap_index` (the merge gate extracted as a pure predicate) and yields — the
  parent swap saves the same two rows and keeps the node's colour. Backwards costs real
  rows: 69 of the 85 parent swaps on that repo expanded sit on such a row. Cost of the
  split swap on that repo expanded, on top of the parent swap: crossings 512 → **285**,
  rendered Lines 1423 → **1251**, ink −16.6%, handover Lines 275 → **103**, max width
  11 → 10 (mean 3.93 → 4.25 — the removed Lines were narrow, total drawn cells −5%),
  node-in-gutter unchanged at 0.990, stability 0.922 → **0.950**, 0 new breaks on that
  style (16 inline).
  Both swaps leave the FOCUSED view BYTE-IDENTICAL (0 differing over ~20,600 signature
  Lines): §3.1 keeps consecutive subject rows on one lane and a `◍` head claims no
  gutter, so the gutter at a kept fork is already the trunk's.
  **The handover column** (§5.6) decides where an eviction lands: on a row where the
  lane holding the gutter afterwards has a parent that is not `state.next_subject`,
  `place_gutter` sets `state.reserve = GUTTER + 1` + `state.reserve_end` (that lane's
  end row, the prepass's `pre.row`), and `free_lane_col` / `fan_out` keep the column
  from any lane ending no earlier (a lane ending sooner nests inside and may take it),
  so the eviction lands beside the gutter instead of past every collapsed head born
  meanwhile. Measured: reactive mixed crossings 262 → 242, fuzz mixed 35389 → 34792,
  `large_topo` mixed 60 → 58; Lines, handover Lines, width, node-in-gutter and
  stability unchanged; the default focused view byte-identical; other policies
  untouched (`next_subject` is nil without the prepass). `columns._internal.
  handover_column = false` is the tests' with/without switch, not configuration.
  `tests/graph_helpers.check_spine` is the invariant —
  at a node cell, the wire above and the wire below carry one lane id — and it now
  **prices** each swap instead of exempting it, with ONE LICENCE PER SWAP. Merge: the
  break is in the gutter column, is between the row's first and a non-first parent lane,
  AND the next subject row's node is in the gutter entered by the swapped lane. Split:
  the break is in the gutter column, the wire BELOW is the first parent and the wire
  ABOVE a converging child the first parent does not continue (exact by §5 — the first
  parent inherits the id of the lane it continues), AND **this** row emitted no handover
  Line. A cell matching both at once (foreign child above, non-first parent below) is
  reported — that is the composition the layout forbids. All read off the rendered rows,
  so a swap that saved nothing still fails; it returns the licensed count and a per-kind
  breakdown so a test can prove each gate fires. The split licence's shape coincides
  with the four policies' leftmost-lane residue and only the policy knows a column is a
  gutter, so the check stays asserted for `gutter` alone. `gutter`
  holds it exactly; the four lane-column policies place the node on the LEFTMOST
  incoming lane (a positional stand-in for its own lane) and carry a 1–2 rows/repo
  residue, unfixed because the node column is what compaction ripples off (see
  `place_commit`). **A swapped node's colour comes from its `up` wire**, not the
  usual `down`: `render.top_lane` takes an `own_lane_up` flag (set by `finalize` from
  the layout, nil everywhere else) and inverts its vertical preference for that cell
  alone, so a trunk merge keeps the trunk's colour and the topic lane merely *begins*
  below it instead of the merge reading as the branch it merged.
  An unknown/absent value falls back to `compact`. §5.1's invariants
  are classified accordingly: **universal** (hold under every policy),
  **conditional guards** (constrain any jog a policy makes — written as violation
  counts, so they go vacuous rather than false), **policy-specific** (only the
  linear-commit slide), and **fan-out placement** (a separate axis in `fan_out`,
  which every chain runs). Unlike `merge_style_index`/`sort_mode_index`/
  `label_mode_index`, the cycle index is derived from `ctx.opts.layout_policy`
  per keypress — deliberately per-window, since the point is comparing two
  windows at two policies. `ctx.pane_opts` (the panes' shallow copy of `opts`,
  frozen at window creation) is kept in step by the handler. The **footer** pane
  follows the policy, except that `gutter` lays it out `straight`
  (`pane.footer_policy`, applied inside `pane.footer`: the pane draws no
  messages, so the gutter column would only add handover rows; the seam still
  matches since `straight` moves no seeded lane); the **header** does not (it is
  the direct seam-up grid, never `columns.layout`).
- **Lane identity is independent of placement** (spec §5, `spawn_lanes`): a
  commit's first parent continues the identity of the incoming lane that
  represents the same line of history, in tiers: **0** the best **pin rank**
  (`opts.pin_rank`, ref id → rank, 1 best; each Lane carries the `rank` of the
  pinned ref at its birth; unranked is worst), **1** a lane whose child has this
  commit as its FIRST parent, else any incoming lane (a merge's second-parent edge
  is still that branch continuing; minting fresh there would recolour every
  merged-in branch tip), **2** the **newest**, the largest id (the chain that
  started nearest the commit; it was the most senior until the user chose this —
  a trunk keeps its colour through such a junction by being pinned, tier 0; the
  ended lanes' colours are still freed in id ORDER, which is only the FIFO's
  determinism, not a continuation choice). Since the four lane-column policies
  still put the node on the LEFTMOST incoming lane, the newest lane usually
  arrives from the right, so an unpinned fork shows a colour change at the node
  under them (`check_spine` errors ~3.5x the senior rule's over fuzz; `gutter` 0).
  Fixtures that need a trunk to continue through a fork PIN it (`pin_rank`), as
  production does (the split-swap block, the fork-hub fixture, `header_replay_spec`,
  two `pane_spec` header cases, the focused spine sweep's `t1`). A commit whose
  best rank (`columns.commit_rank`) strictly beats every incoming lane's is a
  **pinned birth**: every incoming lane ends — an arriving merge extra-parent edge
  included (the old "adopt" case is gone: a lane's colour is fixed for life) — and a
  fresh ranked lane is born (`state.pin_birth`; under `gutter` it skips the claim
  row when a fan has its own Line and declines the parent swap). **Pinned colours**
  (§5.5): rank `k <= #palette.tracks` owns curated slot `k` (`columns.pinned_slots`);
  `M.session` withholds those slots from the FIFO up front (`pin_wait` / `held`,
  `in_use` 1), a lane born with rank `r` takes slot `r` (`take_pin`), and the slot
  returns through the ordinary `free_color` when that lane ends — or through
  `release_pin` at the tip when no lane of its own is born there (outranked, a
  better ref on the commit, a root). The no-truecolor share path skips held slots,
  and generated-slot retirement counts only non-held ones. A footer seed carrying a
  withheld slot takes the reservation over (counted once). nil/empty `pin_rank` is
  byte-identical to the unranked layout (0 of 233,025 rows vs the pre-rank code); a
  non-matching rank inside the palette withholds its slot for the whole layout. The
  map is in the layout fingerprint, and footer seeds carry `rank` via
  `pane.boundary_of`.
  Under the four lane-column policies ranks change colour only (0 glyphs); under
  `gutter` they move geometry (spec §5's measured exception). The ended lanes' colours are returned in
  **id order**, because `free_color` appends to a FIFO and the return order decides
  which colour a later lane gets. Nothing here reads a column, which buys the
  cross-policy guarantee: **all five policies produce identical lane ids and
  colours**, differing only in position, so `C` moves the graph and never recolours
  it (asserted in `graph_layout_spec`). This replaced "reuse the **leftmost**
  incoming lane" — a positional proxy for "the trunk" that failed wherever a topic
  lane landed left of it, drawing the merge and the whole spine below as the topic.
  It was found under `gutter` (which constrains columns, so it hit reliably) but was
  never gutter-specific: `compact` mis-picked on ~2.8% of commits. The fix changes
  **colour only — geometry is untouched** (0 glyph changes across every corpus).
- **Node-less junctions render inline** (spec §10.4): `columns.layout` skips the
  separate split/merge line for a node-less junction with a **single** fan (it
  carries no message), so a join is one row, not a fan line plus an empty lane
  row. The exception is a junction that is **both** a fork and a merge: collapsing
  both funnels onto one line would lay two independent fans across it (§5.1
  forbids two separated lanes sharing a horizontal except at a single fan), so it
  follows `merge_style` like a normal commit — `inline_junction` is gated on `not
  (#incoming > 1 and #outgoing > 1)`, sending its fan-in to a split line.
- **Junction markers** (`opts.junction_markers`, default on; spec §10.4): a kept
  fork/merge inside collapsed branches (a junction, flagged `junction=true` in
  `view.project`, `collapsed=false`) renders **node-less** — `get_column_chars`
  draws its cell as box-drawing lanes (`├ ┬ ┼ …`, the `is_node` gate) instead
  of a commit node, and `display_item` blanks date/author/message (keeps refs +
  the split/merge fan lines). So the split topology shows without the commit's
  weight. Topology model/invariants are unchanged (it stays a real node).
  **Exception — a ref must be anchored to a node:** a junction that carries refs
  is *not* node-less. The `is_node` gate only suppresses the node when
  `#commit.refs == 0`; a labelled junction renders the `◍` collapsed marker (the
  glyph gates ◍ on `collapsed or (junction and junction_markers)`), keeping the
  blank message and fan lanes, so the ref sits on a node instead of floating. The
  layout is unchanged (still inline / split-line per the funnel rule) — only the
  glyph swaps, so there is no compactness cost.
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
  The **context panes dim with the cone too** (§6.2), without walking the
  off-screen graph: cone-membership inside a pane is fixed by which seam-crossing
  lanes are in-cone, propagated over the pane's *own* condensed graph by
  `pane.mark_pane_cone(seeds, dir)` — `.parents` down (footer = pivot-ancestors),
  `.children` up (header = pivot-descendants), `O(pane)`. The build stashes a
  repaint state on `footer.state`/`header.state` (rows, `node_of_hash`, the seam
  crossing-lanes whose `edges` are **live** refs into the main view's segments, the
  dir + offsets); `paint_pane` reads the live seam highlights, seeds, walks, writes
  `highlighted` onto the stored rows (footer via per-edge `Lane`, header via each
  segment's `cone` node tag — `seg_hl` now also honours a segment-level
  `highlighted`), and re-renders. A cursor move that doesn't scroll takes the cheap
  `repaint_panes` path (no rebuild); `maybe_update_panes` rebuilds only on a real
  scroll. `H` re-dims via the same path.
