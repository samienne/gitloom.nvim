# Layout and view-builder tests

Scope: per-spec coverage of the lane layout, streaming sweep, pin ranks / colours, the view projection and signatures, reachability, mirroring. [specification.md](../../../specification.md) and [ARCHITECTURE.md](../../../ARCHITECTURE.md) remain authoritative. Index: [../testing.md](../testing.md).

- `tests/columns_spec.lua` — Phase 1 (`columns.layout`) directly: per-cell
  well-formedness (≤1 vertical, the turn cap), vertical continuity, and a
  fuzz sweep across all five styles **× all five layout policies** (§5.6) over
  **both** a raw DAG **and the §10.7 focused projection** (`h.focused` — the corpus
  that actually has `◍` heads and junction markers, hence **non-subject rows**;
  without it every such branch in `columns.lua` is unreachable, which is how
  `gutter` × `merge_on_separate_line` shipped a hard layout error with the matrix
  green); plus the
  policy reclassification — the linear-slide test ("compacts an expanded inline
  branch next to the trunk") is pinned to the **sliding** policies only, while root
  column break and compact column reuse run the whole matrix (a universal invariant
  and a fan-out-placement rule, not compaction), the one exception being the
  separate-merge-line staircase width, which is one wider and *stable* under
  `gutter` because the gutter may be entered only by the lane owning the next
  subject row (the claim — identical for 3 and 12 merges — is unchanged, so the
  constant is pinned per policy rather than loosened); plus a **gutter policy**
  block (§5.6): every subject row's node in the gutter (except where a root blocked
  it — the §5.1 break working, which on a 1028-commit repository is all 10 of the
  off-gutter rows), the gutter **held across marker rows** (a collapsed head between
  two trunk commits must cost no handover), and no pass-through lane ever drawing a
  horizontal (the no-move rule; stated on survivors, since with a separate merge
  Line the first parent legitimately spans two Lines through the hub);
  plus a **gutter handover column** block (§5.6): the reported shape (trunk in the
  gutter, three collapsed heads, an expanded branch, then `dev`) evicts into column 2
  instead of 5; a lane outliving the occupant skips the column while one ending sooner
  takes it; no reservation when the occupant's parent is the next subject row; and,
  cell for cell with vs without it (`columns._internal.handover_column`), the
  §10.7 focused projection under `gutter` and all four other policies (raw + focused)
  are byte-identical, while the raw corpus under `gutter` differs (the teeth);
  plus track-id reuse (a straight chain is one id;
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
- `tests/graph_layout_spec.lua` + `tests/graph_helpers.lua` — the lane-layout
  algorithm, tested by **invariants** rather than golden snapshots (so the
  tests survive visualization changes; see below). Includes two compaction
  invariants (spec §5): **no-cross compaction** — on the both-lines style (both
  fans on their own lines, so the commit line carries no fan) a fuzz sweep asserts
  a commit line has **zero** lane crossings (a jog never reaches past an occupied
  column into a farther gap); and **a fan line carries no compaction** — on an
  inline-fan commit line a pure survivor (begin ≠ C and parent ≠ C) draws no
  horizontal segment, i.e. it crosses the fan vertically instead of compacting
  along it (fuzzed over the inline / split-line / merge-line styles). The whole
  STYLES × FIXTURES sweep and **both** compaction guards run across all five
  layout policies (§5.6) — the guards are violation counts, so they hold unchanged
  (vacuously under `straight` and `gutter`, which move nothing). The both-lines **no-crossings corollary** now runs
  under **all five** policies — including `gutter`, once its handover swap-IN moved
  onto a virtual row of its own (it used to ride the arriving commit's Line: 1154
  offending commit Lines over 400 DAGs). `gutter` additionally satisfies the
  stronger one-run test on EVERY rendered line, handover rows included (every
  horizontal belongs to one contiguous run reaching that row's node), plus the
  **node spine** (`h.check_spine`, §5/§5.6): at a node cell the wire arriving from
  above and the wire leaving below carry ONE lane id — over the four stable styles ×
  200 fuzz DAGs **× both corpora** (raw and `h.focused`, since the §5.6 swaps
  fire only on the expanded one and the parent swap's clause 2 must be seen declining
  on the projected one), asserting 0 unlicensed breaks, a NON-ZERO licensed count on
  the raw corpus **per licence kind** (merge and split, so neither gate passes
  vacuously) and exactly 0 on the focused one (byte-identity in
  invariant form) — and on a named fixture — a fork three lines came out of, with a
  topic's last commit directly above it — asserting the split hub above the node is
  the trunk's lane and colour, not the ending topic's (the reported gutter split
  colour bug). Asserted for `gutter` only: the four lane-column policies put the
  node on the leftmost incoming lane and carry a small residue (see
  `place_commit`). Plus a **`the gutter parent swap (§5.6)`** block covering each gate
  clause on BOTH corpora from the same DAG — it fires expanded (the second parent
  continues in the gutter, the row it was handed pays no handover, the break is
  licensed), the node is coloured from its `own_lane_up` wire (with the un-flagged
  render asserted to be the topic's colour, so the fix cannot become a no-op), and it
  declines for each clause: clause 2 on the FOCUSED projection of that same DAG (the
  collapsed-head case — the whole reason clause 2 exists), clause 1 when the first
  parent already comes first, clause 3 when that parent has a second in-set child,
  and never at all under the other four policies × every merge style × both corpora
  (no `own_lane_up` anywhere). Plus a **`the gutter split swap (§5.6)`** block for the
  mirror at a fork, driven by a named fixture (a fork three lines came out of, with a
  topic's last commit directly above it, so the topic's lane holds the gutter): it fires
  with a split Line and **breaks no spine** (the hub is the commit's own lane and
  colour, 0 licensed), fires with an inline fan-in as a **licensed** break (kinds.split
  = 1, and the node still reads in its own lane's colour with NO `own_lane_up`),
  **declines for a pass-through occupant** (evicted instead, and the node still in the
  gutter — the hard floor), **composes** with the merge swap on a fork-and-merge fixture
  under a split Line (both handovers gone, the merge licence applying) while **yielding**
  to it on an inline fan-in (the row pays its handover, the wire above is the commit's
  own lane, kinds.split = 0), and **never fires in the focused projection** (every
  fixture plus 60 fuzz DAGs × both styles) nor under the other four policies. The
  "did it fire" predicate is read off the rendered row (node in the gutter, no handover
  Line, the first Line's gutter cell entered by a child lane that is not
  `parent_lanes[1]`'s), since with a split Line the swap leaves no spine break to see;
  a ROOT is excluded, as it continues nothing. Plus a
  `layout policy (§5.6)` block: the
  linear-commit slide changes the layout on only a small minority of DAGs while
  survivor compaction dominates (asserted as a wide-margin relation, not a count),
  under `straight` no lane ever changes column, and an unknown/absent policy falls
  back to `compact`. The whole STYLES × POLICIES matrix also runs its invariant
  sweep over the **§10.7 focused projection** (`h.focused`), and a
  `a freed fan-out column is never the node's own (§5.1/§5.6)` block pins the
  freed-column regression: a named fixture (a junction reached by a foreign
  second-parent edge *above* its own lane, so the node lands off the leftmost
  incoming column) laid out under `gutter` × merge-line / mergesplit, plus a
  matrix-wide projected sweep asserting **no two outgoing lanes ever turn down in
  one column**. Both are unreachable on a raw DAG — a projected view is what
  produces a row that owns no subject. A
  `a separate split Line frees its ended lanes under gutter (§5.1/§5.6)` block pins
  the split-occupancy regression: a run of first-parent merges, each also absorbing
  the next topic's lane on its split Line, laid out under `gutter` × split-line on
  both corpora (raw and focused, `◍` topics), asserts every merge fans its topic
  out into the column beside the node (it alternated one column out when
  `place_gutter` reserved the absorbed children's columns). The `inline+mergesplit` characterization snapshot is pinned
  to `compact` explicitly (a golden snapshot is a picture of one policy). The
  `invariant checker self-test` block also proves **`check_horizontals`** has teeth:
  a fan-in and a fan-out sharing a run is flagged MIXED-DIRECTION, two arms of the
  same fan are not. It proves **`check_spine`** has teeth too, on hand-built rows that
  isolate each licence clause of BOTH swap licences (a third, the §5 **pinned
  birth**, is exercised in `pin_rank_spec`). Merge: the licensed swap passes, while
  a break outside the
  gutter column, a break whose wire below is not a parent lane, a next subject row
  whose node is not in the gutter, a next subject row entered by a DIFFERENT lane
  (`SAVED NOTHING` — the case clause 3 prevents) and a break with no following subject
  row at all are each flagged with their own reason. Split: the licensed fork swap
  passes, while a break on a row that ALSO paid a handover Line (`SAVED NOTHING`), a
  break whose wire above is not a converging child, and a cell where BOTH swaps fired
  (a foreign child above AND a non-first parent below — the commit's own lane on
  neither side) are each flagged. So a checker that quietly became
  "gutter is exempt" fails there. That checker is wired into `M.check` (§5.1 horizontal sharing)
  for every merge style that gives at least one fan its own Line; it is NOT run on
  the two fully-inline styles, where a commit's fan-in and fan-out share its Line by
  construction and the rule fires under every policy alike (a deferred, pre-existing
  property of those styles, not of any policy).
- `tests/graph_mirror_spec.lua` — the `mirror` render transform (spec §5.4):
  the same invariant suite must pass on mirrored output, the mirrored grid must
  equal the horizontal flip of the normal grid (reverse + glyph swap), and the
  per-cell color multiset must be preserved (connectors included — guards the
  connector-color scan that flips direction under mirror). Plus a **`gutter`
  policy** block running all three checks over every merge style × mirrored and
  unmirrored fuzz: mirroring is orthogonal to *movement*, so the four compaction
  policies need no separate sweep, but `gutter` emits cell shapes the others never
  do (a node cell whose only wire is a horizontal; a `┤` where one lane both
  arrives and leaves) and mirrored is the orientation it exists for.
- `tests/pin_rank_spec.lua` — pin priority in lane identity (§5): `commit_rank`
  (best rank, `HEAD` keying), nil / empty / past-the-palette non-matching
  `pin_rank` byte-identical (fuzz + `large_topo`, every style × policy), the birth
  at a pinned tip (the `feature1`-off-`dev` case; a merged pinned tip ending the
  merge edge and starting its own pinned-colour lane; a counterpart ahead of its
  local reaching the tip unranked; equal rank one lane; a worse rank no birth),
  tier 0 beating the newest-lane tiebreak, ids /
  colours / ranks identical across policies, 0 glyph changes under the four
  lane-column policies and every invariant + `check_spine` (births licensed, seen
  > 0) under `gutter`, streaming == one-shot incl. a pin change forcing a re-lay
  (the fingerprint), and footer seeds carrying their main-view rank. Plus the
  **pinned colours** (§5.5): rank k's lane born with slot k and unchanged by a pin
  added below it; over a fuzz corpus with a 6-slot palette (generate on and off) no
  other lane holds slot k before rank k's branch start is found, and the slot IS
  recycled after; a diverged counterpart drawing an ordinary colour without a
  `pin_counterpart` map (with one, see `counterpart_color_spec`); pins past the
  palette falling back (generated, or shared without truecolor); a non-matching
  in-palette rank withholding its slot and moving nothing else; and the footer seed
  taking a withheld slot's reservation over (released once, reused as in the main
  view). `tests/pane_spec.lua` checks the header never de-collides a lane onto a
  pinned slot (`pane.header`'s `avoid`), and keeps a counterpart lane's `-k`
- `tests/counterpart_color_spec.lua` — **counterpart colours** (§5.5,
  `opts.pin_counterpart`): a counterpart ahead of its local draws `-k` above the
  local's tip (still unranked) and full `k` from it, the **birth at a counterpart
  tip** (an arriving unranked lane ends; a lane of a pin ranked as well or better
  continues; the **lumeeditor HEAD shape** — a lane of a pin ranked WORSE than k,
  HEAD's branch above `origin/dev`, ends there, its own commits keeping its colour,
  every style × policy, `check_spine` under `gutter`, and only `(dev ↑origin)` takes
  `-1` at Y), a diverged one shares slot k
  with the concurrent pinned lane while an unrelated lane never gets it, the slot
  returns only after the pinned lane AND every counterpart lane ended (a 2-slot
  fixture with teeth: without the map, x's end releases it), a fuzz sweep that no
  ordinary lane holds slot k while a holder does; the **birth at a counterpart
  tip** (§5) on the reported real-repo shape (pinned `x`, `origin/x` one ahead
  carrying two more remote refs AND a child branch on top: the child's lane ends,
  `-1` is born, every style × policy, a licensed `check_spine` birth with no claim
  Line under gutter), a ranked incoming lane continuing through, a ranked ref on the
  tip winning (pinned birth), a same-pin counterpart lane continuing vs a worse
  pin's ending, and no birth once the slot is released; 0 glyph changes vs no map
  under the four lane-column policies over fuzz + `large_topo` × 4 styles, gutter
  holding every `h.check` invariant + `check_spine` with births seen (measured
  rows changed with `GITLOOM_CP_MEASURE=1`; empty map byte-identical),
  streaming == one-shot incl. a map change re-laying, a footer seed carrying `-k`
  as one more holder, `select.pin_counterpart_rank` + `pin_upstream = false` →
  `{}` (`window._internal.pin_counterpart`), and rendering: `slot_hl(-k)` = the
  `counterpart_dim` blend (0.25; configurable; plain without truecolor), out of the
  cone `dim_hl` giving the slot colour's `counterpart_dim_out` blend (default
  `0.75 * dim`, configurable, following `dim`) — brighter than the dimmed pinned
  lane, dimmer than in-cone — and a counterpart's label in the light-dim colour
  in the cone and the same brighter dim out of it
- `tests/stream_layout_spec.lua` — the **streaming** Phase-1 sweep (§3.1,
  `graph.extend_columns`): the streamed layout is byte-identical to the one-shot
  one (every rendered Line's connectivity, lane id, colour, node flag,
  `own_lane_up` and per-segment endpoints, plus the row's parent/child lanes) over
  fixtures x batch sizes, a fuzz sweep, and the `large_topo` real-world topology,
  each x 5 merge styles x 5 layout policies. Plus what gives that teeth: the
  session is **carried** across batches (the same table, row counts growing in
  batch-sized steps, each row swept once) — without which "parity" passes
  trivially by rebuilding — and it is **dropped** when it cannot be continued (a
  non-append `start_pos`, changed layout options, and a `prepass` policy, which
  `columns.session` reports as `lookahead`). Deleting the lookahead guard fails
  the fuzz + `large_topo` blocks on `gutter`: the prefix property genuinely does
  not hold there
- `tests/view_spec.lua` — the view builder `view.project` (spec §10) — incl.
  **HEAD is always an anchor** (§10.6/§10.7: a detached HEAD's commit stays a
  normal row, never folded into a `◍`; an attached HEAD is no owner of its own); monotone
  signatures, the all-normal identity, hidden removal (shared ancestors kept),
  collapsed contraction to one head with junctions kept, **branch-topology
  preservation** (a kept junction — a fork, or a merge that still has a visible
  child — is never collapsed away, but a **merge tip** (a collapsed merge with no
  visible child) folds into its `◍` head; no floating head; asserted on targeted
  cases and the whole fuzz sweep), distinct-signature regions staying separate heads, the
  display-mode join truth-table, the
  collapsed `◍` glyph render, the precomputed-sig caching equivalence, the
  first-parent-only signature (`fp_only`) and the `view.owners` first-parent
  default (§10.7: trunk normal+fp, others collapsed, merge owners; mainline-full /
  merged-collapsed projection), `pack_markers` (§10.4: packing concurrent
  collapsed heads onto one line with the packed grid passing the wires-connect
  checker; no-op when there are no markers), **node-less junction markers**
  (§10.4: a kept junction renders no node glyph — node count drops — vs. a node
  when `junction_markers` is off), a fuzz sweep feeding projections through
  the real layout's wires-connect checks, and **total owner coverage** (§10.2):
  the `tip:<hash>` backstop (minted for an in-set commit with no in-set child that
  no ref owns — collapsed + fp_only, overridable by an explicit mode, none for a
  ref-owned tip or an interior commit, none at all with focus off) and its **§4.2
  exclusion** (a working-tree virtual commit is childless by construction and must
  stay visible, so it gets no `tip:` owner and still projects normal). Plus the
  regression the backstop fixes: a ref-less branch (a linked worktree's detached
  HEAD, a `refs/original/*` commit) must have a non-empty signature and collapse
  to one `◍`, not render as a run of expanded commits. Plus the **chunking hook**
  (§10.5, the async reflow): `signatures` / `project` fire an optional `yield` on a
  large set and give byte-identical output, including driven from inside a real
  coroutine that suspends and resumes (the driver's shape)
- `tests/view_sigset_spec.lua` — the **interned** signature sets
  (`gitloom.graph.sigset`, §10.2): the set algebra (singleton / union / intersect /
  members agreeing with plain sets, the memoised `summary`) and — the point —
  **one representation per set whatever order it was built in**, so region identity
  is pointer identity. Then parity against `h.reference_signatures`, the §10.2
  definition transcribed with no sharing and no memoisation (which is what shipped
  before): the same set for every commit, the same projection, and the same layout
  **cell for cell** over every merge style × every layout policy. `view.project`
  takes its pre-interning path for a plain table of sets, so this compares two real
  implementations rather than one with itself — and the corpus is sized to cross the
  trie's level boundaries (6 / 40 / 90 merges), so dropping a node's position from
  its intern key fails four of the five blocks. Plus the **sharing** claim, without
  which any correct representation passes: on a merge trunk the materialised form
  holds > N²/4 entries while the interned one must stay under 8N nodes, and indexing
  the map must NOT cache what it materialises (the cursor walking a merge-heavy
  trunk would re-accumulate exactly the footprint this removes)
- `tests/reachability_spec.lua` — `reachable_cone` (spec §12.1: pivot/ancestors/
  descendants, no cousins, viewport clipping); the **lane model** (`build_graph`
  attaches `parent_lanes`/`child_lanes`, sharing one Lane object per edge); and
  `mark_reachable` (the Lane walk): cone markers light, an edge is highlighted iff
  it's in the cone, a sibling sharing a fan stays fully dim (exact, no bus
  over-lighting), and the shared descent/ascent at a separate split/merge line
  keeps a non-trunk cone lane connected through the hub
