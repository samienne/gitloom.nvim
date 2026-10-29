# Window glue notes

Scope: the window controller (`window.lua`): module layout and `GraphCtx`, z-order, the context panes and their seams, collapse, the command palette and `GRAPH_KEYS`, checkout / branch sync / examine, reflow, persistence, progress and config wiring. [specification.md](../../specification.md) and [ARCHITECTURE.md](../../ARCHITECTURE.md) remain authoritative; this file is implementation detail for working on the code. Index: [CLAUDE.md](../../CLAUDE.md).

## Implementation notes

- **Module layout (post-split)**: the code is layered into a **git data
  library** (`gitloom.git`), a pure **graph engine** (`gitloom.graph`), a
  **window controller** (`gitloom.window`), and helpers — dependencies point
  downward (`window → graph → git`). `init.lua` is a thin facade binding
  `:GitloomGraph` to `gitloom.window.open`. **gitloom.git** (`git/`): `model`
  (Commit/Ref types), `parse` (log/show/diff/status parsers), `format`
  (commit-detail/diff/diffstat/range/worktree formatters), `refs`, `range`
  (DiffRange), `order` (`order_commits`, §3.1), `date`, and `fetch` (the async
  `vim.system` I/O — its only Neovim coupling), behind a `git/init.lua` aggregator.
  **gitloom.graph** (`graph/`): `view` (the pre-Phase-1 projection §10),
  `sigset` (the interned persistent owner sets the §10.2 signatures are computed
  in), `rank` (§5 identity pairing + rank order), `columns` (Phase 1 lane layout), `render` (Phase 2 glyphs/colour/dimming +
  `display_item`), `reach` (§12 reachability), `select` (selection/branch-mode
  helpers §2/§10/§13), `pane` (context-pane core), `color`; `graph/init.lua` is
  the engine entry (data-model types + the layout glue `build_graph`/
  `refresh_columns`/`pack_markers`/`owners_from_refs` + the `_internal` test
  seam). **gitloom.window** (`window.lua`) holds the window/keymap glue, the
  streaming/resync, the reachability debounce, the context panes, the commit
  view, and the external-diff glue (`M.open`). **gitloom.util** vendors
  `make_future`/`compose`/`highlight_text`/`trim_ws`. (Still pending: a finer
  window→commitview→panes split.) **window.lua internal structure:** a graph
  session is a **`GraphCtx`** (`ctx`) table bundling the per-session state (repo,
  opts, view_state, sel, sig_cache, the live `ctx:win()` host-window accessor,
  etc.); `open_graph` assembles it, and the graph **helpers**, **keymap
  handlers**, and **autocmd bodies** are *module-level* functions taking `ctx`
  (collected in the `GRAPH_HELPERS` table → attached as `ctx:method()`, and the
  `GRAPH_KEYS` table → bound buffer-local), so the formerly-giant `open_graph`
  closure stays well under LuaJIT's 60-upvalue ceiling (it references the two
  tables, not each helper). Sibling calls go through `ctx:` (resolved at call
  time, so definition order is free). The pane-machinery cluster
  (`update_panes` + its coroutine helpers) and the one-time stream/`on_show`
  setup remain nested inside `open_graph` (cohesive, already encapsulated via
  `ctx`). The float **z-order** is the single-window bounded model (§14):
  `host_zindex`/`overlay_zindex`/`float_zindex`, fixed deltas (+1 overlays, +2
  gitloom's transient floats) above the host's live zindex — no stacking ladder.
  The host is created at `opts.zindex` (default 41, so 41/42/43: above ordinary
  windows' decorations, below other plugins' floats such as fidget at 45);
  floats gitloom does not own keep their own zindex. pane.lua is the context-pane
  layout core (boundary-line extraction; `continue`/`condense`/`footer` = the
  footer's down-rebuild; `continue_up` = the header's **minimal connecting subgraph**
  (only how the pinned anchors relate to each other + the lanes crossing the cutoff —
  the "seeds"): a **meaningful-head induce** over the **display** DAG, up-only (lanes
  matched by `lane_of(n).id`, the main-graph lane identity threaded in — the projected
  first-parent is unreliable). From each seed walk up via `children`, following a child
  edge iff it is **not a loop-back** AND the branch **reaches a meaningful head** — a
  pinned anchor tip, or a **seam-to-seam confluence** (the first meeting of two distinct
  crossing lanes, the anchor/trunk lane excluded). The loop-back test carries a **per-path
  `visited` set of every lane id each commit touches** (`lanes_at`): re-entering a burned
  lane — or `merged_reentry`, stepping onto a **non-first (merged-in) parent's** lane the
  node already touched from below — is a loop-back, so the split-then-merge-back diamond
  is pruned. Two cleanup passes follow: a **redundant-arm reduction** drops a fork arm
  whose reachable meaningful heads are all already claimed by a higher-priority sibling (a
  feature that forks off the trunk and merges back into a pinned head the trunk already
  reaches), GC-ing the orphaned interior; and a **parallel-merge declutter** resolves a
  2×2 diamond — two crossing lanes both forking to the SAME two children — by keeping each
  child's first-parent edge and dropping the redundant cross-arm when the other parent
  stays connected (spec §6.2). This drops the merge/fork plumbing of every feature branch
  that touched the trunk off-screen, caps an isolated crossing lane at the seam (a bare ◍)
  instead of drawing it to its own feature tip, and renders a parallel-merge as clean
  parallel lanes; merges fall out where two followed lanes meet one node (a node-less
  junction). It also fixes the merge-at-cutoff anchor-severing bug (HEAD jumping to a
  fresh id): the anchor's lane id follows its spine unbroken up to the anchor — a
  collapsed continuation's `lane_of` is its `parent_lanes[1]` (the trunk lane), keyed by
  the tip hash, so a recycled tip-own lane never severs it; a **divergent** anchor
  connects via the meaningful split reaching its pinned tip (no separate spine
  down-connect). So an unpinned branch forking off the trunk that reconnects to nothing is
  **pruned** (no stray feature heads); a branch that only merges back is the single
  node-less junction; ≥2 kept children → junction, 1 → collapse, 0 → head. Real-repo
  headers shrank from ~11 nodes to 2–6. Invariant: every
  above-seam boundary `begin` is in the node set (inducted or a seam head) so no seam
  lane drops; `condense(up)`; the **direct seam-up
  grid** `header` — a bottom-up sweep seeded from the boundary so the seam is the
  bottom row, columns never reused, each lane drawn in **its own colour**
  (`lane_of(child, parent)`, the main-view colour of the EDGE drawn — `via` names the
  first hop across a spliced run; the pivot is the arriving lane the main view
  continues and keeps its colour, an extra fork child takes its own) and unpinned heads
  packed onto as few rows as possible (`pack_heads`/`overlay_rows` — pinned anchors and
  junctions keep their own line) BEFORE the de-collision, which recolours only lanes
  sharing a drawn row (the unit is a lane id IN one main-view colour, since a lane is
  recoloured at an outranking ref; two units of one identity sharing its colour are
  no clash; a negative, muted-level colour — `rank.drawn` level 2 or 3 — is never moved), never onto a pinned slot, and within the
  palette without truecolor (`ncolors`); `cap`; §6.2). **Both panes are wired** via
  graph.lua `update_panes` (gated by `opts.panes`, toggled by `F`): borderless
  overlays (footer at the bottom, header at the top). Both seams are computed by
  **pure, virtual-line-aware** seam functions that round to **whole commit blocks** so
  a commit is never split across the seam — exact mirrors, both in **screen-row space** on
  the shared `pane.screen_lines(display)` model (the flat real-columns + virtual split/merge
  screen sequence). The footer derives `bs` = the bottom visible **screen row** (cursor-
  anchored via `pane.footer_bs`, reached through `pane.footer_bottom`, which declines
  `"at bottom"` when the unclamped window bottom reaches the model's last row — nothing
  below the window, the mirror of the header's `"at top"`), then `pane.footer_seam(sm, bs, cover)` walks up to the
  first block boundary, reading the seam item's **bottom** edge (its merge fan when present).
  The header derives `ts` = the top visible **screen row** (cursor-anchored via
  `pane.header_ts` = `cols[cursor] − (winline() − 1)`), then `pane.header_seam(sm, ts, cover)`
  walks **down** to the first block **start**, reading the seam item's **top** edge (its
  split fan when present). No `screenpos`; both need only window-relative measures (`winline`
  + window height). This screen-row model is the fix for the pane virtual-line drift — a
  split at the window **bottom** once pushed the footer a row too low, and a split at the
  window **top** (which `line('w0')`, a real line, can't address) once drifted the header's
  seam off the main view's first visible line. The footer
  continues the seam lanes down to the roots (pinned refs below the cutoff
  included); the header rebuilds the focused up-sub-DAG (`dnode`/`order_of` resolve
  the projected nodes; `lane_edge["<child>><parent>"]` from each item's
  `parent_lanes`, falling back to `lane_main[hash]` (its `parent_lanes[1]`), gives
  `lane_of(n, p)` the main-view colour of each drawn edge so the header matches the
  graph) and lays it out
  seam-up with distinct colours and packed unpinned heads — `converge_header`
  min-fit-sizes from the `(#pinned tips above)+1` guess up to `HEADER_MAX` (8),
  capping over-tall headers with `+N above`, and **hides the header at the top** (and `build_footer` hides the footer at the bottom, `"at bottom"`)
  (`w0` display index ≤ 1). HEAD plus `master`/`main`/`dev` are pinned by default
  (`effective_pinned`, so they get their own labelled lines); `P` toggles others.
  The rebuild is **async and cancellable**: `update_panes` runs `build_panes` as a
  coroutine driven across event-loop ticks (`drive_panes`); `pane.continue`/
  `pane.continue_up`/`pane.condense` take an optional `yield` hook they call every
  `YIELD_EVERY` steps, so the deep first-parent walks (and the O(N) index passes,
  via `py`) are chunked and never block a keypress. A scroll (or a newer build)
  bumps `pane_gen` to abandon the in-flight coroutine; both panes are computed
  before any overlay mutation (a no-yield tail), so a cancelled build leaves the
  previous panes intact. The rebuild is also **scroll-gated**: the cursor/scroll
  debounce calls `maybe_update_panes`, which rebuilds only when the **scroll key**
  changed (`pane_scroll_key` = `winsaveview().topline .. ":" .. topfill`; the panes are
  independent of the cursor row). The `topfill` is essential: a **sub-scroll through a
  line's `virt_lines_above` rows** moves the visible region by one screen row while
  `line("w0")` stays constant — gating on `line("w0")` alone left the footer stale
  (a direction-dependent discontinuity `F`-`F`/refocus "fixed"; see
  `tests/pane_scroll_gate_spec`). Forced callers (reflow / `M`/`B`/`F`/… toggles) call
  `update_panes` directly.
  **The gate is `pane.gate()`** — a state machine in pane.lua, not a bare key
  comparison, so its rule is testable without a window: **it remembers what was
  BUILT, not what was attempted.** `update_panes` calls `started(key)` (an in-flight
  target, enough that the debounce does not tear down and restart an identical build
  every tick); `drive_panes` calls `built()` only when the coroutine finished and was
  not superseded, and `dropped()` on a build error or a vanished window; the
  `WinScrolled` handler calls `dropped()` when it bumps `pane_gen`. Crediting the key
  at *start* (the old single-field `pane_topline`) let an abandoned build leave the
  gate claiming panes that were never produced, so every later `maybe_update_panes`
  took the cheap repaint path — panes stale, or GONE if that build had already
  declined and closed them — until an unrelated scroll moved the key. The exposure is
  the **programmatic reposition** shape: `jump_to_ref` (`<leader>b`, the §10.6.1
  dialog `<CR>`), the §16 filter `<CR>`/`<Esc>` and the §15 commit-search confirm all
  move the view and then call `update_panes` synchronously, so the `WinScrolled`
  their own `center_view` emits arrives *after* the gate has been told this scroll is
  current. Reachability is narrow — nvim drains scheduled callbacks (hence the whole
  chunked build) before `may_trigger_win_scrolled_resized` runs, measured identically
  on 0.11.6 and 0.12.5 — but the invariant is unconditional, so the gate enforces it
  rather than relying on that ordering.
  **`vim.g.gitloom_open_trace`** (README → Diagnostics, §10.8) is the armable
  diagnostic for the OPEN path: one line per phase — open / refs / batch (per
  streamed batch; the first is the first paint) / stream / sort / owners (with the
  merge-owner count) / signatures (and whether the cache was reused) / project (its
  row count, so the rows the collapse removed are read off against the owners line)
  / layout / pack / apply / done. `util.open_trace` shares one `append` writer with
  the pane trace, each keeping its own sequence counter; `open` restarts the clock,
  so several opens read as separate timelines. Inert unset.
  **`vim.g.gitloom_pane_trace`** (README → Diagnostics) is the armable diagnostic for
  the whole lifecycle: one appended line per `maybe` (key, built key,
  rebuild-vs-repaint, each overlay up/down), `update` (target key + call site),
  `geom` (the viewport the seams were measured from — `winline`/height/`topline`/
  `topfill`/`w0`), `yield`/`abandon`, `built` (the per-pane decline reason) and
  `hide_all`/`close` (with a stack). Inert unset: one `vim.g` read, no traceback
  walk, no file handle (`util.pane_trace` / `util.pane_tracing`).
  The repo.order hash→index
  map is cached (`order_idx`), rebuilt only when the order length changes. Full
  cross-level head packing (all unpinned heads on ONE row, vs. today's consecutive
  packing) is pending. listview.lua is a git-agnostic reusable widget.
- **Collapse interaction** (spec §10.4): acts on the row's **own owners**
  (§10.2), not a selected ref — `branch_under_cursor(line)` runs
  `select.toggle_target` over the commit's signature (a head / packed marker: its
  tip) into `{state, owners, keepers, anchors, selected, hide_owners, follow,
  commit}`; `selected` (the h/l ref's owners) feeds only the per-ref actions
  (palette hide, `P`). `<Space>` is the 2-state collapse⇄expand toggle:
  `GRAPH_HELPERS.toggle_branch` calls `set_branch` (flips the owners, reflows,
  then `goto_hash` repositions the cursor on the result so it is repeatable) and
  gives the `still open via …` / mainline notices (`select.owner_label`); the
  palette's collapse / expand go through it too. The expand side everywhere
  (filter jump `ensure_expanded`, the §11.7.6 reveal, the selection toggle, a
  packed marker's expand) is `select.open_owners`. `reflow_owners` writes
  `view_state.owner_tip` (the rule's input) and `view_state.expanded` (the §6
  `▾` set `pin_marks` hands the renderers). `<CR>` is **examine, never a menu** (`h_cr`): the commit view of
  the row's commit — `select.menu_target` maps a collapsed head to its `tip`, a
  packed-marker line uses the selected marker's tip (the **first** marker's when
  none is selected), and while a §13 selection is active it is the range view.
  Every other row action moved to the `<C-Space>` palette (below), which is now the
  single action menu: `ctx:palette()` classifies the row as `<CR>` used to — a
  normal commit row with **no ref selected** (cursor on the message) is `plain`
  (the commit context: diff, checkout, checkout & examine); a ref selected with
  `h`/`l` or a **collapsed head** is `branch` (checkout of the branch, collapse /
  expand, hide — no commit diff, no checkout & examine); a **packed-marker row** is
  `markers` (with a marker selected — `row.selected` — ONLY that marker's checkout /
  expand / hide, which is the branch context; with none, expand/hide per marker by
  name) — keyed off `selection_state.index` (the h/l ref selection), and the pure
  `palette.row_entries(row, has_diff)` returns those entries, each with an `op`
  the palette helper maps to its glue. **Checkout** (§10.4.1) is
  `select.checkout_spec(commit, select.selected_ref(commit, index))` → `git switch
  <local>` / `git switch <short>` for a remote (git's DWIM) / `git checkout
  --detach <hash>`; never forced, none for a §4.2 virtual commit, and a collapsed
  head resolves to its `tip` (its own hash is a synthetic `collapsed:` id —
  `<CR>` and the diff entry resolve it the same way). It runs through
  `git.run_checkout(argv, repo.root)` (`git_code` with an explicit cwd, so a
  submodule graph checks out in the submodule); a non-zero exit is one
  `format_git_error` line at ERROR, success runs `ctx:resync(false, {})` — the `R`
  path in its **follow-HEAD** form (checkout & examine and Return pass a `note`):
  the cursor lands on HEAD's row and the notice is `git.head_summary`
  (`HEAD → x (abc1234)` / `HEAD detached at abc1234`). Every resync also clears
  `sig_cache.sig`, whose count-only key cannot see a ref tip that moved.
- **Command palette = the action menu** (spec §17, `<C-Space>` + `<C-@>`, which
  many terminals send for it — `<C-@>` and `<Nul>` are one key code):
  `palette_entries(info)` is the pure builder over ONE snapshot (`row`,
  `selection`, `remotes`, `examine`, `has_diff`, `keys`; `commands` a test seam)
  and returns one ordered list — the **context** first (`row_entries(row)`, or the
  registry's `selection` entries instead while a §13 selection is active), then the
  registry's `global` entries, then the context's **keys** (`key_entries`). The
  command registry (`COMMANDS`: `{ id, label (string or
  fun(state)), key?, scope, per_remote?, when?(state), action(ctx, remote?) }`) is
  filtered by scope and `when`, gets the `  (key)` suffix, and expands a
  `per_remote` entry per cached remote as `fetch:<remote>`. Registry entries carry
  an `action`; row entries an `op` the window runs against the row it resolved.
  There is no Refresh command: the resync is the `R` key's entry.
  **The key registry is `GRAPH_KEYS`** (window.lua, an ordered `GraphKey[]`:
  `{ key (lhs or alias list), run?(ctx), desc, help?, group?, contexts?, when? }`)
  — the ONE table the buffer-local maps are bound from (`desc = "Gitloom: " ..`),
  `h_help` renders (`palette.help_lines`) and the palette lists
  (`palette.key_entries(keys, context, state, taken)`: grouped keys offered in the
  context — `row_context(row)` = `commit` / `branch` / `markers`, or `selection` —
  groups `refs → view → select → other`, registry order within, `<desc>  (<key>)`,
  a key an earlier entry already carries skipped). No `group` = bound + in help,
  never in the palette (motions, `q`, `<Esc>`, the palette key, `<leader>wD`); no
  `run` = bound elsewhere (`<C-o>`/`<C-i>`, `nav.install_nav_keys`), help only. A
  new graph key goes in this table — nowhere else — with a `desc`. Helpers defined
  above it reach it through `ctx:key_registry()` (a `GRAPH_HELPERS` field; the
  local ceiling again); tests through `window._internal.keys`.
  The glue is `GRAPH_HELPERS` fields (window.lua's local ceiling): `palette` (row
  classification + a `vim.ui.select` built from cached state only — never waits)
  and `run_remote` (`git.remote_command` → `git.run_remote(argv, repo.root, env)`,
  the `run_checkout` shape with an env: `GIT_TERMINAL_PROMPT=0`;
  `ctx.remote_busy` refuses a second run; success → INFO + resync, failure →
  `format_git_error` over `remote.failure_text` (git's `fatal:`/`error:` line
  first, stdout when stderr is empty) + resync for a pull only). §17.4: it
  streams (`git.run_remote(..., on_chunk)`) into `ctx.remote_log` (the pure
  `remote.log_feed`), reports `remote.status_text` as the op's message from a 1 s
  uv timer + output (≤ 4/s), and sends its start / outcome notices through one
  `progress.notice()` (the notify provider replaces it with the live status when
  the notifier returned a handle). Success notice = `remote.summary_text` over
  `remote.ref_summary(res.err)`. `show_remote_log` / `refresh_remote_log` (the
  palette's *Show fetch log*, `ctx.remote_log_buf`) — no footer segment, no key.
  `ctx.remotes` comes from `load_remotes` (`git remote`, async) at session
  assembly and at the top of every `resync`. Pull's argv is exactly `git pull
  --ff-only`, which overrides any `pull.rebase` / `pull.ff` config, so it never
  merges or rebases; a failed pull still resyncs (its fetch half may have moved
  remote-tracking refs).
- **Branch sync** (spec §17.2, ARCHITECTURE "Command palette"): the branch
  context's fast-forward / reset-to-upstream entries. Visibility is decided from
  the CACHED tracking counts (`SelectedRef.upstream`, carried from
  `group_refs`'s `track`; `Upstream.ref` is the full refname from
  `for-each-ref %(upstream)`, so a local-branch upstream works too) — no spawn
  while building the palette. But the current-vs-other form is decided from the
  fresh `fetch.sync_probe`, never the decoration: a stale "current" would aim
  `reset --hard` at whatever branch HEAD is on now. Untracked files are not
  counted as "discarded" (`parse_status`'s `paths - untracked`, not its per-state sum) since
  `reset --hard` never touches them. `ctx:branch_sync` is a `GRAPH_HELPERS` field
  (the 200-local ceiling) and shares `ctx.remote_busy`.
- **Checkout & examine** (spec §10.4.2): check a commit (or a §13 selection's
  newest end) out detached and open diffview on ONE rev — the older end's first
  parent, the empty tree for a root (`range.examine_range`) — so the right side is
  `RevType.LOCAL`, the files on disk, and LSP attaches; a working-tree newer end
  checks nothing out and opens its existing single-rev range, and so does a newer
  end that already IS HEAD's commit — the palette then labels it **Examine**
  (`Examine <short>` / `Examine selection`), decided by `examine.needs_checkout`
  over the CACHED `HEAD` ref (`select.head_target`, passed to `palette_entries`
  as `head` + the selection's `newest`): no probe, checkout, stash or state, a
  dirty tree examined as is. Three layers: the
  pure plans in `git/examine.lua` (`examine_plan` → `open` / `refuse` /
  `checkout`; `examine_stash_message`; `return_plan`; `stash_index`), the git side
  in `fetch.lua` (`examine_probe`, `examine_run`, `examine_return`, `drop_stash` —
  all `git_code` in `repo.root`), and the window glue `GRAPH_HELPERS.examine` /
  `examine_selection` / `examine_return` (dirty prompt, notices, provider, resync;
  `ctx.remote_busy` shared with fetch / pull). **The state lives in
  `nav.examine[root]`**, the module-level table already holding the host
  registry, so it survives closing and reopening the graph — a field rather than
  a new local because window.lua is at the 200-local ceiling. **The stash is
  shared with every worktree and session**, so it is never addressed by position:
  `examine_run` reads `stash@{0}` before AND after the push (unchanged ⇒ nothing
  was stashed, e.g. only a dirty submodule, rather than adopting someone else's
  stash), Return applies by SHA, and `drop_stash` re-derives `stash@{n}` from
  `git stash list --format=%H` right before dropping. No stash chain: a second
  examine while one is active keeps `orig` + the stash and only moves `examined`,
  and on a dirty tree is refused ("Return first"). Return clears the state only
  after a successful switch + apply; a failed switch keeps it (retry), a failed
  apply clears it but keeps the stash and names it. The stash is applied with
  `--index`, so staged changes come back staged. When git refuses that
  ("conflicts in index" — `examine.index_refused`; git checks the staged patch
  with an atomic `git apply --cached` BEFORE touching the index, tree or
  untracked files, verified on 2.49) Return falls back to a plain apply and WARNs
  that the changes are back unstaged; any other `--index` failure is a failed
  apply. The `--index` apply runs under `LC_ALL=C` so the message is matchable.
- **Sticky columns** (listview, anti-bounce; spec §6): the shared column widths
  recompute from the visible range each scroll, so a varying column bounces. A
  column can *only grow* (never shrink): `col_max` (a per-column cap, implies
  sticky — the author column at 25) and `col_sticky` (no-cap sticky columns, a
  list or a function — the graph column when `opts.mirror` is on, whose
  right-aligned content would otherwise shift as the lane width changes).
- **The reflow splits into compute and apply** (§10.5): `reflow_build` produces
  the display and touches no window, `reflow_apply` swaps it in; `reflow` is both,
  `reflow_async` drives the compute half as a coroutine across event-loop turns
  (the pane build's shape) for the one reflow that scales with the repository —
  the opening projection. Both bump `ctx.reflow_gen`, so a keypress supersedes an
  in-flight build, which then drops itself having changed nothing on screen. The
  swap stays atomic: a half-collapsed projection is not a cheaper intermediate
  (signatures are computed against the whole owner set) and rows would move under
  the cursor at every step. The §11.7.6 focus-reveal rides inside the single
  projection via the `on_signatures` hook — it needs only the signatures and the
  resolved modes, and a mode never enters a signature — instead of triggering a
  second whole reflow as it used to.
- **Persisted view state** (§18, `persist.lua`; see ARCHITECTURE "Persisted view
  state"): one JSON file, `stdpath("state")/gitloom.json`. The toggles
  `m C M B d H S c p F i` save `{ value, base }` via `ctx:save_pref(<field>)`
  (`base` = the configuration-resolved value, computed in `open_graph` from the
  caller's options BEFORE the defaults merge, kept as `ctx.persist_config`); a
  changed config beats a stale entry. Per-repo pins save via `save_pins` from `P`
  and the `L` dialog — root graph + base view only (§14.8). Reset (palette /
  `:GitloomResetView`) clears the toggles + THIS repository's pins only. All glue
  uses inline `require("gitloom.persist")` — no new window.lua locals. Tests must
  never hit the real file: `persist.set_path` (minimal_init does it).
- **Progress reporting** (§19, `progress.lua`; see ARCHITECTURE "Progress
  reporting"): `ctx.progress` is the session's tracker; each reported operation is
  `ctx.progress:start(title, { message?, own_notices? })` → an Op ended on EVERY
  path (`op:finish(outcome)`, idempotent), and the graph buffer's `BufWipeout`
  sweeps the rest `cancelled`. fidget is only ever `pcall(require)`d, per Op; an
  Op shorter than `progress.delay` reaches no provider. A new long-running async
  operation gets an Op the same way; keystroke-paced or synchronous work does not
  (§19.1). Glue uses inline `require("gitloom.progress")` — no window.lua locals.
- **setup() config is wired** to `:GitloomGraph`: `init.lua`'s command callback
  forwards `M.config` (the stored `setup()` opts) to `window.open`, which merges
  it over the built-in defaults (read at invocation time). The per-pane
  `header_max`/`footer_max` caps remain hardcoded (specification.md §6/§8).
