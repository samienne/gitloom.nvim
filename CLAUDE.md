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
- `tests/minimal_init.lua` sets up the runtime path (plugin + plenary from
  the lazy.nvim install dir) and disables swap/shada.

Coverage:

- `tests/refs_spec.lua` — `parse_refs`
- `tests/commit_spec.lua` — `parse_commit_line`
- `tests/gitloom_spec.lua` — public surface (setup, command registration)
- `tests/graph_layout_spec.lua` + `tests/graph_helpers.lua` — the lane-layout
  algorithm, tested by **invariants** rather than golden snapshots (so the
  tests survive visualization changes; see below).

`graph._internal` (`require("gitloom.graph")._internal`) exposes, **for tests
only** (not the public API): `parse_refs`, `parse_commit_line`, `build_graph`,
`get_track_chars`, `reset_ids`.

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

Invariants must be **sound** (never flag correct output) before being strict.
Glyph-level color/continuity is subtle because junction glyphs (`├ ┤ ┬ ┴`,
turns) are lane *boundaries* where color legitimately changes — only enforce
continuity where it unambiguously holds (straight `│↔│` runs, and across
crossings). A `checker self-test` block feeds deliberately broken grids to
prove the checker still has teeth; keep it passing.

Still uncovered: the listview widget (needs snacks in the test runtime).

## Key concepts (quick reference)

- **Commit** — a node in the DAG (hash, parents, children, refs, metadata).
  Identity-stable across the stream.
- **Track / lane** — one vertical line of history on a row, with connectivity
  and an id that drives its color.
- **OrderItem** — a rendered row (`commit`, `merge`, or `split` type) with its
  lane set, plus optional `above`/`below` virtual-line lane sets.
- **GraphOptions / MergeStyle** — configuration; see specification.md §8.
- **listview** — the generic virtualized list widget the graph renders into.

See specification.md §4–§5 for full definitions.

## Implementation notes

Details not covered by the spec or architecture:

- **init.lua is a thin facade**; graph.lua holds git I/O + layout + render;
  listview.lua is a git-agnostic reusable widget.
- **`graph._internal`** exists solely for tests (pure parsers + the
  `build_graph`/`get_track_chars`/`reset_ids` layout seam). Do not route
  production code through it.
- **Vendored duplication is intentional** — `compose` lives in both graph.lua
  and listview.lua, and `make_future` is gitloom's own minimal promise. See
  "Relationship to loomworks" before deduplicating.
- **setup() config is not yet wired** to `:GitloomGraph` (specification.md
  §8 "Known gap"). The command uses built-in defaults.
- **graph.lua contains commented-out experiment scaffolding** (`--override`
  lines, alternate-style blocks). These are dev aids; treat with care when
  cleaning up and prefer removing dead scaffolding over leaving it.
- **git runs in Neovim's cwd** — `jobstart` is called without an explicit
  `cwd`, so the graph reflects the current working directory's repo.
- **Neovim >= 0.10** — relies on the 4-arg `vim.str_byteindex` and the
  decoration-provider API.
