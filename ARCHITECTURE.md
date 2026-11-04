# gitloom.nvim — Architecture

A high-level map of how gitloom is built, for a first-time reader. It names
the layers, how data moves between them, and where to look next. The details
live in the code; each module starts with a header comment that explains its
part.

- *What* gitloom does (the behavioural contract): [specification.md](specification.md).
- Using it: [README.md](README.md).
- Working notes for changing a subsystem: `docs/claude/` (indexed from
  [CLAUDE.md](CLAUDE.md)).

## What gitloom is

A read-only git commit-graph viewer for Neovim. `:GitloomGraph` opens a
floating window that shows the commit DAG of the repository at Neovim's cwd
as a coloured, lane-based graph, one commit per row, with refs, author, date
and message beside it. From there you can collapse and pin branches, open a
commit, search, diff, and run a handful of explicit actions (checkout, fetch,
pull, branch sync) from a command palette.

gitloom **owns its model**. It reads raw commits and refs from git and does
the ordering and lane layout itself, rather than wrapping `git log --graph`.
That is what makes collapse, pin and reflow possible: the graph is a function
of *(commits, view state)* that can be recomputed whenever the view state
changes.

gitloom is **self-contained**. Its only third-party dependency is snacks.nvim
(diffview is an optional diff provider), and it does not depend on
`loomworks.nvim` even though it ships in the same suite. The small helpers it
shares with loomworks (a promise, highlight composition) are vendored in
`util.lua` and `listview.lua` on purpose.

## Layers

Dependencies point one way: **window → graph → git**. Only the window layer
and `fetch.lua` touch Neovim; everything else is pure Lua and is tested
without a UI.

| Layer | Where | Role |
|---|---|---|
| Git data library | `lua/gitloom/git/` | Runs git, parses its output, holds the commit/ref model, owns the topological sort. |
| Graph engine | `lua/gitloom/graph/` | Pure: (commits, view state, options) → laid-out, renderable rows. |
| Window controller | `lua/gitloom/window.lua` | The floating window, keymaps, streaming, panes, commit view, actions. Drives the other two. |
| List widget | `lua/gitloom/listview.lua` | Generic virtualized list over `snacks.win`; knows nothing about git. |
| Support | `navstack.lua`, `persist.lua`, `progress.lua`, `submodule.lua`, `util.lua` | Navigation stack, saved view state, progress reporting, submodule changes, vendored helpers. |

### Git data library (`gitloom.git`)

- **Model** (`model.lua`): `Commit`, `Ref` and `Upstream`. `repo.commits` is
  an identity-stable DAG keyed by hash; commits and refs link to each other,
  and a placeholder stands in for a hash that has not streamed in yet.
- **Parsing and formatting** (`parse.lua`, `format.lua`, `refs.lua`,
  `date.lua`): turn `git log` / `for-each-ref` / `show` / `status` /
  `worktree list` output into structured data, and structured data into
  display text. Pure.
- **Ordering** (`order.lua`): `order_commits`, gitloom's own topological sort
  (spec §3.1), run once the stream completes.
- **Action plans** (`range.lua`, `examine.lua`, `remote.lua`, `sync.lua`):
  pure builders for diff ranges, checkout & examine, fetch / pull and branch
  sync. They return argv and prompts; the window runs them.
- **I/O** (`fetch.lua`): every git command, as an async `Future`. See
  [Async fetching](#async-fetching).

### Graph engine (`gitloom.graph`)

The engine turns the model into rows in three steps:

1. **View projection** (`view.lua`, with `sigset.lua`): commit DAG + view
   state → an **OrderItem graph**, the ordered list of nodes that will be
   drawn. Collapsed regions become a single synthetic *collapsed head*. Which
   commits belong to which branch is decided by **reachability signatures**:
   each commit's signature is the set of owners (refs, worktrees, the HEAD
   trunk and a few anonymous owners) that reach it. Regions with the same
   signature collapse and expand together (spec §10).
2. **Lane layout, Phase 1** (`columns.lua`, with `rank.lua`): assigns lanes to
   columns and emits, per line, which way each wire connects. No glyphs and no
   highlight groups, just structure and colour *slots*.
3. **Rendering, Phase 2** (`render.lua`, with `color.lua` and `reach.lua`):
   turns connectivity into box-drawing glyphs and highlights, and dims
   everything outside the cursor's reachability cone (spec §12).

`graph/init.lua` holds the shared types and the layout entry points
(`build_graph`, `refresh_columns`, `extend_columns`). Smaller pure helpers
for the window also live here: `select.lua` (selection and navigation walks),
`pane.lua` (header / footer context panes), `palette.lua` (the action menu).

### Window controller and list widget

`window.lua` assembles a graph session, a **`GraphCtx`**: the window, buffer,
repository model, view state and listview controller. It wires keymaps and
autocmds to engine calls. Each repository gets one host window, and inside it
a navigation stack (`navstack.lua`) of **frames**: the graph, an opened
commit, a drilled-in submodule. `<C-o>` / `<C-i>` move through the stack by
swapping buffers (spec §14).

`listview.lua` renders rows **on demand**. A decoration provider asks for the
visible range on each redraw, and only those rows are laid out and written to
the buffer. Real buffer lines carry the commits; the fan-out lines of merges
and splits are virtual lines attached to them.

> **Gotcha:** `window.lua` is at LuaJIT's 200-local chunk limit, and
> `open_graph` must stay under the 60-upvalue limit. New helpers go into the
> `GRAPH_HELPERS` table and new keys into `GRAPH_KEYS`. See CLAUDE.md and
> [docs/claude/window.md](docs/claude/window.md).

## Data flow

```
:GitloomGraph
  └─ window.open ── listview.open (float + decoration provider)
       ├─ fetch refs, HEAD, worktrees        → repo.refs (Ref ↔ Commit links)
       └─ stream git log --topo-order         → batches of commits
            per batch: parse → merge into repo.commits
                       → extend_columns (resume the layout sweep)
                       → listview inserts blank rows
            on completion: order_commits (owned sort)
                       → view projection + full layout, in slices
                       → swapped in atomically (one reflow)

redraw (visible top..bottom)
  └─ listview asks window for those rows → Phase 2 glyphs + highlights
```

A view-state change (collapse, pin, a layout toggle) builds a fresh OrderItem
graph and layout, then points the listview at it: a **reflow**, not an
in-place edit. Signatures are cached against the DAG and owner set, so a mode
toggle only recomputes the cheap per-region join and the layout (spec §10.5).

## Async fetching

All git I/O is asynchronous and must never block a keypress.

- **One spawn path.** Every git command goes through `fetch.lua`'s `spawn`,
  which uses `vim.system` (never `jobstart`, whose output can be lost under a
  busy main loop), pins `cwd` to the active repository root, and is the
  `vim.g.gitloom_git_debug` hook. Each call returns a `Future`
  (`util.make_future`).
- **Streaming.** The commit log is read unbuffered. The stdout callback only
  stitches lines and queues them. A worker drains a batch per turn, parses it,
  extends the layout and inserts rows, so the graph fills in progressively.
- **Chunked workers yield to the screen.** Long work (the stream worker,
  sliced reflows, pane rebuilds as coroutines) reschedules itself through
  `next_tick` (a 0 ms `uv` timer), **not** `vim.schedule`. A chain of
  `vim.schedule` callbacks never lets the screen redraw.
- **Argument limits.** Revision lists that grow with the number of refs go on
  stdin, because Windows caps a command line at 32766 characters.
- **Stale results are dropped.** Rebuilds carry a generation counter, so a
  newer request abandons an older one in flight.

Details: [docs/claude/git-io.md](docs/claude/git-io.md).

## The lane-layout algorithm

Phase 1 is a single **top-to-bottom sweep** over the ordered rows. It carries
one piece of state: the set of lanes currently flowing down, each in a column.

- A **Lane** is one edge, child → parent. It is a persistent object that
  lives from the child's row down to the parent's row, so a wire's identity
  and colour stay continuous by construction.
- At each commit the sweep classifies the incoming lanes (edges ending here)
  and the pass-throughs, places the commit in a column, then starts one new
  lane per parent. The first parent continues an incoming lane's identity;
  other parents fan out.
- Each lane **carries a ref** (spec §5), the best-ranked ref by `rank.lua`,
  and that ref decides its colour. A branch keeps its colour down its history.
- The per-commit step is a **pipeline of grid stages** (seed bars → place
  commit → slide → fan in → compact → fan out → finalize). Each stage writes
  wires into a live column grid and reads occupancy back. One rule keeps the
  graph legible: lanes of the same fan may share a horizontal, nothing else
  may cross one. A **layout policy** (spec §5.6) is just a different chain of
  stages.
- Because the sweep never reads below the current row, it can be
  **resumed**. Streaming appends rows by continuing the sweep
  (`extend_columns`) instead of starting over.
- The output is validated by structural checkers (`complete_check` in code,
  invariant tests on every layout).

Phase 2 is a pure function from a cell's connectivity to a glyph, which is why
mirroring (§5.4) and cone dimming need no special glyph tables.

More: [docs/claude/layout.md](docs/claude/layout.md) (pipeline, policies,
colours), [docs/claude/view.md](docs/claude/view.md) (projection, signatures,
pins), [docs/claude/layout-research.md](docs/claude/layout-research.md)
(measured results and closed questions).

## File map

```
lua/gitloom/
  init.lua          setup() and the :GitloomGraph command
  window.lua        window controller (GraphCtx, keymaps, panes, commit view, actions)
  listview.lua      virtualized list widget over snacks.win
  navstack.lua      per-window navigation stack (§14)
  persist.lua       saved toggles and pins (§18)
  progress.lua      progress reporting, fidget / notify (§19)
  submodule.lua     submodule change view (§11.7)
  util.lua          vendored helpers: make_future, compose, highlight_text
  git/              data library
    init.lua          re-exports the submodules
    model.lua         Commit / Ref / Upstream
    parse.lua         git output parsers (incl. the stream de-chunker)
    format.lua        commit detail / diff / range formatters
    refs.lua          ref classification, worktree refs, ref picker, resync diff
    order.lua         owned topological sort (§3.1)
    date.lua          timestamps and date formats
    range.lua         diff ranges (§11.5, §13.5)
    examine.lua       checkout & examine plans (§10.4.2)
    remote.lua        fetch / pull (§17)
    sync.lua          branch sync (§17.2)
    fetch.lua         async git I/O (vim.system), the one Neovim-coupled file
  graph/            layout engine
    init.lua          types, layout entry points, `_internal` test seam
    view.lua          view projection (§10)
    sigset.lua        interned owner sets for signatures (§10.2)
    rank.lua          ranked refs (§5)
    columns.lua       Phase 1 lane layout
    render.lua        Phase 2 glyphs, colour, dimming
    reach.lua         reachability cone (§12)
    select.lua        selection and navigation helpers
    pane.lua          header / footer context panes (§6.2)
    palette.lua       command palette (§17)
    color.lua         OKLCH colour generation (§5.5)
tests/              plenary.busted specs (see docs/claude/testing.md)
```
