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

- `tests/refs_spec.lua` — `classify_ref`, `group_refs` (compact ref display)
- `tests/selection_spec.lua` — `move_selection`, `decoration_texts`,
  `ref_byte_col` (h/l ref selection + cursor parking), and `pack_right`
  (the right-pinned ref width budget)
- `tests/commit_spec.lua` — `parse_commit_line`, `parse_timestamp`, and the
  date formatters (`format_absolute`, `format_relative`)
- `tests/commit_view_spec.lua` — the commit view's pure pieces (spec §11):
  `parse_show` (git-show field splitting, multi-line body, empty parents),
  `format_commit_detail` (committer-differs branch, refs line, body indent),
  `format_diff` (add/delete vs `+++`/`---`, hunk + file headers, context),
  `diffstat_files` (per-file counts, `start` offsets, rename, binary),
  `format_diffstat` (summary totals, per-file rows), and `commit_range`
  (single-commit `DiffRange`: `^!`, empty-tree for roots, `from` = first parent)
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
  slot is recycled so a later fan stays distinct under a small palette; plus root
  column break (spec §5.1): a branch head is not stacked under a root, and a run
  of stacked roots alternates columns
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
only** (not the public API): `classify_ref`, `group_refs`, `decoration_texts`,
`move_selection`, `ref_byte_col`, `parse_commit_line`, `parse_timestamp`,
`format_absolute`, `format_relative`, `parse_show`, `format_commit_detail`,
`format_diff`, `diffstat_files`, `format_diffstat`, `commit_range`,
`reachable_cone`, `mark_reachable`, `build_graph` (Phase 1, delegates to
`columns.layout`), and `get_column_chars` (Phase 2, the renderer).
`columns.layout` is reached via `require("gitloom.columns")`.
`listview._internal` exposes `pack_right` (the right-pin budget packer) and
`refresh_columns` (the column-width packer).

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
- **init.lua is a thin facade**; graph.lua holds git I/O + the window/keymap
  glue + Phase 2 render + reachability + the commit view; columns.lua is Phase 1;
  listview.lua is a git-agnostic reusable widget.
- **`graph._internal`** exists solely for tests (pure parsers + the
  `build_graph`/`get_column_chars` seam). Do not route production code through it.
- **Vendored duplication is intentional** — `compose` lives in both graph.lua
  and listview.lua, and `make_future` is gitloom's own minimal promise. See
  "Relationship to loomworks" before deduplicating.
- **setup() config is not yet wired** to `:GitloomGraph` (specification.md
  §8 "Known gap"). The command uses built-in defaults.
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
  commit, so future graph range-selection reuses it. `commit_range(commit)` is
  the only constructor today (single commit → `<hash>^!`, empty-tree for roots).
  The default `open` runs diffview guarded; diffview is the only optional
  dependency beyond snacks. Provider/label/`D` are window glue (not unit-tested);
  `commit_range` is.
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
