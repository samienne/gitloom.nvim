# Layout research: measured findings

Scope: measured results on lane-layout clarity (crossings, width, stability) and on
crossings under the `gutter` policy, from the 2026-07 spikes. They exist to stop
closed questions being re-opened and to give baselines for new layout work.
[specification.md](../../specification.md) (§5, §5.6) and
[ARCHITECTURE.md](../../ARCHITECTURE.md) remain authoritative; [layout.md](layout.md)
covers the code. Index: [CLAUDE.md](../../CLAUDE.md).

The measuring harness lived in untracked `spike/` directories and is not in the repo.
Numbers below are from those runs; re-measure before relying on them for a new decision.

**Settled priority:** stability > local crossing legibility > width.

## Fixtures

- `tests/large_topo.lua` — real, 638 commits, only 11 merges. 97.6% of lanes never
  move, 17 crossing cells, mean width 1.73, max 10. Thin: most policies are inert on it.
- reactive (`C:\src\reactive`) — real, ~1040 commits, 112 merges (~11%). The
  mid-density reference the owner can eyeball. Parent counts `{1:917, 2:112, 3+:0}`.
- `gitloom_topo` (396 commits / 65 merges) and `dense6k_topo` (6000 commits / 2518
  merges / 233 concurrent lanes) — spike-only, anonymised.
- `random_dag` is **not** a benchmark: parents are drawn uniformly from all later
  commits, so mean width is about 0.37·n. Keep it as an adversary, never tune to it.

## Crossings and width (compact-era layout)

- **Order-inversion crossings (two through-lanes swapping sides) are 0** on every
  fixture, size and style, up to 42% merges and 233 concurrent lanes. It follows from
  compaction stopping at the first occupied column. Crossing minimisation in the
  literature sense is already solved here.
- **Compaction jogs never cross anything.** Every visible `─│` crossing is a commit
  fan bus, so reducing crossings is a placement problem, not a compaction one.
- **Width is provably minimal.** With rows fixed, lanes are intervals, and greedy
  leftmost-free is interval-graph colouring (χ = max clique). Width is a budget, not
  a goal.
- **`slide`** caused ~75% of column churn on the default inline style (stability
  81% → 95% without it) for no width gain. This motivated the selectable policies
  (§5.6) rather than a deletion.
- **`compact` costs more than it buys.** Trunk+features synthetic: +40% crossings,
  +33% ink, −42 points of stability for 1.48 columns of mean width. On `dense6k` it
  is 5 columns *worse* than optimal (238 vs the χ bound 233, which no-compact hits
  exactly) for +45% crossings, +61% ink, −77 points stability; its real product is
  gap-freeness.
- **Residual cost in the default view is the collapsed-head cascade**: runs of `◍`
  heads each opening a column and landing on one commit (max width 10 on a graph of
  median width 1). `pack_markers` fixes the vertical half; the wide fan bus remains.

## Stability across reflows and streaming

- **Streaming is not a stability issue**: 0.0% column movement across batch
  boundaries; a prefix layout is a prefix of the full layout.
- **Cross-reflow instability is entirely compaction's doing.** On `dense6k`, `<Tab>`
  moves 2.7% and `P` 6.1% of commits (single nodes jump up to 238 columns); with no
  compaction both are exactly 0. Recolouring across reflows is 0.0–0.3% — the free
  list is deterministic, so a "fresh lane-id sequence" is **not** the cause.
- `c` (focus toggle) moves 73% / recolours 86% on dense — a whole-view change, not
  diagnosed against no-compact.
- The stream-completion re-sort (`apply_sort` → `order_commits`) is a true no-op
  (100% row-order agreement, 0 movement up to 6000 commits). Stripping `cepoch` moves
  88% of commits — that gotcha is guarded only by a comment; a regression test is cheap.
- Perf: `refresh_columns` ignores `start_pos` and re-lays the whole prefix every
  256-commit batch — O(N²/256), about 4 min on a 95k-commit repo. Layout itself is
  linear, ~15 µs/commit. Wasteful, not destabilising.

## Policies (§5.6)

- `layout_seam` was already the no-slide, no-compact chain, so every policy is a chain
  of the existing seven stages; no new stage code was needed. Policy × seam is a 2-D
  matrix.
- The §5.1 invariants split four ways: universal; universal-as-a-guard (the
  compaction rules as conditional violation counters); policy-specific (the linear
  slide); and fan-out placement ("compact column reuse" lives in `fan_out`, present in
  every chain).
- **The reserved `interval` placement already exists.** Under a no-move policy with
  half-open lane intervals, "leftmost column free for the whole lifespan" equals
  "leftmost column free on this row", and greedy in birth order is χ-optimal. Proven
  cell-for-cell (0 differing Lines). A closed-interval slip in the probe produced 266
  false divergences. §5.6 still describes `interval` as future work.

## Gutter policy: crossings

Closed axes, do not re-propose:

- **Fan arm order is inert.** 3+-parent merges occur 0 times in real topologies, and a
  fan's crossing cells depend only on the column multiset; reversing arm→column gave
  a byte-identical crossing set in 100% of cases.
- **Lifespan-aware birth placement is refuted**: 0.00% of crossing-causing lanes had a
  nearer column free for their whole life.
- **"Nearer column" variants are worse**: `nearest` +6% crossings, `freedsplit` +4%,
  a reserved gutter-adjacent pad +16% and +1 column. Merge-distance banding is a no-op
  on reactive and costs +22% width where it bites.

The two projections differ:

- **Focused** (default): X=116 on reactive, 93% inherent (every column between the
  arm's ends is occupied); 0 handover crossings, because second parents are collapsed
  heads. Irreducible: the price of node-adjacency.
- **Expanded**: X=598, of which 503 (84%) sit on the two gutter handover Lines
  (eviction 339, claim 164). §3.1 lineage grouping puts the second parent's lineage
  right after its merge, so the gutter changes hands at nearly every merge.

**The handover trilemma** — what the gutter cell below a merge node can carry:
(1) the first parent's lane: both handover rows needed (the old behaviour);
(2) another parent's lane: no handover, but a spine break, and the node colours from
its `down` Segment, so the merge renders in the topic's colour; (3) nothing:
`stepout`, only the claim row remains; (4) two lanes bending in one cell: `├─┤`,
banned by the owner and by `check_horizontals`. Moving the node off-gutter is
circular, and swapping lane identity instead of column breaks §5 (identity must be
policy-invariant). So removing both handover rows forces a colour break.

Variants measured on reactive expanded:

- **Ungated swap**: worse than baseline (X 606 vs 598).
- **`swapgated`** (swap when `row(p2) < row(p1)`): fires on every merge in the focused
  view and buys nothing there (a collapsed head owns no subject row): X 116 → 209,
  62 useless spine breaks. Unsafe as stated.
- **`swaptight`** (adds "and the next subject row is that parent"): focused view
  byte-identical; expanded X 598 → 552, Lines 1593 → 1423, 100 spine breaks for 100
  saved handovers. Claim-Line crossings −62%, eviction −2%, +64 on commit/split Lines.
- **`stepout`**: crossings rise 598 → 684, worst reflow stability (.9445), doubles the
  inline/mergesplit sharing count. Refuted.
- **`armfit`** (band on fan-arm weight): the only variant that improves reflow
  stability, but −4/116 crossings for +2.7% width is below the bar.

**Shipped (2026-08)**: `swaptight` as the merge parent swap plus its mirror at forks
(the split swap). Reactive expanded vs pre-swap: crossings 598 → 298, Lines
1593 → 1270, handover Lines 445 → 105, max width 11 → 10, stability .912 → .951,
85 licensed spine breaks (merge only; the split swap costs none at the
separate-split-line style). Focused view byte-identical. `check_spine` prices each
swap with one licence.

Other facts:

- git's `graph.c` "never move right" rule is incompatible with a gutter (a lane must
  vacate column 1 rightward first). gitloom satisfies its load-bearing half: each
  handover Line moves exactly one lane.
- Expanded views sit 1 column over the χ bound because the gutter is held empty — not
  in §5.6's cost table.

## Prior art

- git `graph.c`, tig, lazygit and GitX all use greedy leftmost-free plus leftward
  compaction.
- pvigier's forbidden-interval placement (straight branches) is the documented
  alternative; `gitgraph.nvim` ships it, magit makes the same trade.
- GitKraken ships "Pin to Left", validating column reservation as a feature.
- Crossing minimisation here is the fixed linear crossing number problem, NP-hard
  (Masuda et al. 1990). Storyline visualisation (crossings / wiggle / whitespace
  under fixed time order) is the closest literature.
- User complaints are about column instability (vscode-git-graph #207, SmartGit pin
  request); crossings are only reported as local glyph confusion (tig #1037, #631).
