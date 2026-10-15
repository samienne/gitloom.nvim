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

Do NOT duplicate content from these files here or in `docs/claude/`. Refer to
them instead.

## What this is

A read-only git commit-graph viewer for Neovim: `:GitloomGraph` opens a
floating window showing the commit DAG as a colored, lane-based graph for the
repo at Neovim's cwd. It never stages, commits or rewrites history by itself —
the only exceptions are actions the user explicitly picks from the `<C-Space>`
palette: checkout (spec §10.4.1), checkout & examine (§10.4.2, may `git stash
push -u` after a prompt and re-apply on Return), fetch / pull (§17) and branch
sync (§17.2: fast-forward / reset a local branch to its upstream — reset is the one action that can discard work, so it always
confirms). Part of the loomworks suite but **standalone**; its only third-party
dependency is snacks.nvim (diffview is an optional diff provider).

**Focus and direction.** The product is the graph viewer; other git
functionality is out of scope unless it falls out of the graph or is delegated
(diffview, etc.). gitloom builds the graph itself rather than wrapping `git log
--graph` (model ownership), because collapse / pin / toggle visibility with
reflow require owning ordering and layout. The graph algorithm is the most
developed part; the rest of the surface exists mainly to exercise it. The
central unsolved problem is
commit attribution in a shared DAG. See specification.md §1, §10 and
ARCHITECTURE.md ("Model ownership and the view pipeline").

The plugin lives at `C:/src/nvim-plugins/gitloom.nvim`, loaded via the owner's
Neovim config (`C:/Users/samie/AppData/Local/nvim`, branch `loomworks`) as a
lazy.nvim dev plugin: `dev.path` uses the local checkout when present, else
clones the `unstable` branch from `https://gitcode.com/samienne/gitloom.nvim`.

## Relationship to loomworks

gitloom **must not depend on `loomworks.nvim`** — a deliberate, standing decision.

- **Vendored duplication is intentional** — `compose` lives in both graph.lua
  and listview.lua, and `make_future` is gitloom's own minimal promise. Keep
  these vendored; do not deduplicate them against loomworks.
- Copying an implementation from loomworks wholesale (e.g. vendoring its more
  complete `future.lua`) is fine — copy, never add a runtime dependency.
- Long-term, shared code goes in a separate small `utils` library gitloom can
  copy from or depend on independently — never a dependency edge to loomworks.

## Spec-First Development Workflow

**Before implementing any change that contradicts specification.md or
ARCHITECTURE.md, STOP.** Propose the doc change first, explain the reasoning,
and wait for approval. Then update the doc, then the code.

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

- **Feature branches**: `feature/<short-name>`; **bugfix**: `fix/<short-name>`.
- Branch from `master`. Multiple commits per branch are fine.
- Do **not** create commits automatically — only when the user explicitly
  asks. It is fine to suggest "should we commit this?" at a stopping point.
- **Every commit on `master` makes one meaningful change.** How a branch lands:
  - **One commit** — fast-forward (rebase it onto `master` first if needed).
  - **Several commits that are not each a meaningful step** (work in progress,
    fixups, "address review") — squash them into one commit.
  - **A real merge** (`git merge --no-ff`, with a summary message describing
    *what* and *why*) — only when the branch's commits are carefully curated,
    each a self-contained meaningful step. Curate them before merging.
- Landing on `unstable` for test-driving is unaffected: it stays a
  `git merge --no-ff` merge of the branch.
- **A merged branch is finished.** Once merged (into `unstable` or `master`),
  never add commits to it or merge it again. Follow-up work — a cleanup, a fix
  to it, a review change — goes on a **new** branch from the current `master`.
  Continuing a merged branch makes the history graph messy.

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
8. **Diagnostics clean** — `make lint` reports no problems

**Do not merge if documentation is out of sync.** Fix docs first. If the
user does not ask for this check, remind them before merging.

## Bugfix workflow

Reproduce a bug with a failing test first, then fix it:

1. Write a failing spec that reproduces the bug
2. Verify it fails for the right reason
3. Fix the bug
4. Verify the spec passes

## Testing

Tests use plenary.busted (details: [docs/claude/testing.md](docs/claude/testing.md)).

- `make test` — run every spec in `tests/`
- `make test-file FILE=tests/<name>_spec.lua` — run one spec
- `make lint` — type-check with lua-language-server; keep it at zero problems
  (override the binary with `LUALS=...`)

## Hard gotchas (read before changing code)

- **window.lua is at LuaJIT's 200-local chunk limit** (and `open_graph` must
  stay under the 60-upvalue ceiling). A new module-level local breaks `require`
  outright: new helpers go into the `GRAPH_HELPERS` table (attached as
  `ctx:method()`), new keys into `GRAPH_KEYS` (the one key registry, with a
  `desc`), and other glue uses inline `require(...)`.
- **`graph._internal`** exists solely for tests (pure parsers + the
  `build_graph`/`get_column_chars` seam). Do not route production code through it.
- **`vim.schedule` does not yield the screen.** A self-rescheduling chunked
  worker must use `fetch.lua`'s `next_tick` (a 0 ms `uv` timer) or
  `vim.defer_fn(fn, 0)`; `vim.schedule` is only for a single hop out of a
  fast-event context. See [docs/claude/git-io.md](docs/claude/git-io.md).
- **Every git spawn goes through fetch.lua's `spawn`** (`vim.system`, never
  `jobstart` — a `jobstart` job drops output under a busy main loop). It pins
  `cwd` to the active repository root and is the `vim.g.gitloom_git_debug` seam.
  Revision lists that scale with ref count ride stdin (Windows 32766-char cap).
- **Tests must never touch the real persist file**
  (`stdpath("state")/gitloom.json`): `tests/minimal_init.lua` redirects it via
  `persist.set_path`; any new harness must do the same.
- **Layout invariants run on two corpora** (raw DAGs and the `h.focused`
  projection) — non-subject-row paths in `columns.lua` are unreachable on raw
  DAGs alone. See [docs/claude/testing.md](docs/claude/testing.md).

## Further reading

Topical notes under `docs/claude/` (spec and ARCHITECTURE stay authoritative):

- [testing.md](docs/claude/testing.md) — adding/changing a test: the testing approach and a spec → file map into `docs/claude/testing/` (layout, panes, refs, git-io, actions, commit-view, infra, seams).
- [layout.md](docs/claude/layout.md) — `columns.lua`/`render.lua`: pipeline, resumable sweep, policies + `gutter` swaps, lane identity/colours, junctions, dimming.
- [view.md](docs/claude/view.md) — `view.lua`/`sigset.lua`/`select.lua`: projection, focus, signatures, owner coverage, pins, packing, label modes, commit selection.
- [window.md](docs/claude/window.md) — `window.lua`: `GraphCtx`, z-order, panes + seams + gate, palette/`GRAPH_KEYS`, checkout/sync/examine, reflow, persist, progress.
- [git-io.md](docs/claude/git-io.md) — `gitloom.git`/`fetch.lua`: spawn + debug hook, `next_tick`, picker cost, sort modes, resync (32766 cap), diff provider.
