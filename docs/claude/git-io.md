# Git I/O notes

Scope: the git I/O layer (`gitloom.git`, `fetch.lua`): spawning, the debug hook, screen-yielding workers, the repository picker, sort modes and `order_commits`, resync, and the external diff provider. [specification.md](../../specification.md) and [ARCHITECTURE.md](../../ARCHITECTURE.md) remain authoritative; this file is implementation detail for working on the code. Index: [CLAUDE.md](../../CLAUDE.md).

## Implementation notes

- **git runs in the active repository root** (spec §2.1) — every git spawn
  goes through fetch.lua's `spawn` helper (`vim.system`, never `jobstart` — a
  buffered or streamed `jobstart` job drops output under a busy main loop; the
  buffered queries reach it through `run`, which resolves `{ code, out, err }`
  on the main loop), which pins `cwd` to a module-level
  active root set by `git.set_cwd`. `window.open` resolves it (the given
  `folder` or Neovim's cwd → `git rev-parse --show-toplevel`), stores it on
  `repo.root`, and keys the per-session view state by it. So the graph can
  target a **submodule** or the **main module**, not just the cwd repo. The
  repository picker (`:GitloomPick` / `window.pick`, default `<leader>wG`) lists
  the main module + direct submodules (`git.fetch_submodules`) and opens the
  graph on the chosen repo; its discovery queries take an explicit `cwd` so they
  don't disturb the active root. `nil` active root = Neovim's cwd (the original
  behaviour).
- **Streamed output (fetch / pull, spec §17.4)** — `fetch.run_remote(argv, root,
  env, on_chunk)` passes `stdout` / `stderr` FUNCTIONS to `spawn`; vim.system
  then leaves the completed result's `stdout` / `stderr` **nil**, so the runner
  collects the pieces itself and still resolves the whole `{ code, out, err }`
  (err trimmed only at its end, keeping a leading ref line's flag column). Each
  piece is handed to `on_chunk` through `vim.schedule` (FIFO, so every chunk
  lands before the resolve). Pieces split anywhere; git's progress is
  `\r`-separated and needs `--progress` (stderr is not a tty). The parsing is
  the pure `gitloom.git.remote` (`log_feed`, `status_text`, `ref_summary` — keyed
  on the untranslated flag column; `fetch --porcelain` exists but `pull`
  rejects it).
- **`vim.schedule` does not yield the screen.** A scheduled callback lands on the
  main loop's event queue, which nvim drains to empty before it iterates — so a
  worker that reschedules itself with `vim.schedule` starves the loop for its
  whole run and nothing is drawn. Measured on 0.12.5, 60 chained 8 ms slices:
  **0** `SafeState` events under `vim.schedule`, **59** under a 0 ms `uv` timer.
  `fetch.lua`'s `next_tick` is that timer, and it is why the commit stream now
  actually paints progressively. Use it (or `vim.defer_fn(fn, 0)`) for any
  self-rescheduling chunked worker; `vim.schedule` is still correct for a single
  hop out of a fast-event context.
- **The picker is spawn-bound** (spec §2.1): its whole cost is process creation
  (~30 ms per `git` spawn warm on the author's Windows box, ~225 ms on a slower
  one) — **nothing in it touches the network**. It costs **1 + N** spawns for N
  submodules. Discovery is ONE `git ls-files --stage` (the index's `160000`
  gitlinks → `submodule.parse_gitlinks`), with the checkout state read off the
  **filesystem**: `git_dir` resolves a submodule's `.git` *file*
  (`parse.parse_gitdir`), `head_info` reads `HEAD` (`parse.parse_head`) + the
  loose ref, falling back to `packed-refs` (`parse.packed_ref`), and
  `submodule.submodule_state` joins them into git's four states. This replaced
  `git submodule status`, which opens every submodule's repository in turn —
  measured 650 ms fixed **+ ~145 ms per submodule** (2.0 s at N=9, 2.8 s at
  N=16), gating the entire list. A row summary is now ONE spawn too: the branch
  comes from `head_info` (free) and `git log -1 --format=%h%x1f%s%x1f%D` carries
  the short hash, subject and — via `%D`'s `HEAD -> <branch>` — the fallback
  branch (`parse.parse_summary`), replacing a *sequential* `rev-parse` + `log -1`
  pair. Measured end to end (best of 3, same process): full population
  648 + 143·N ms → **52 + 7.1·N** ms — 2141 → 130 ms at N=9, 2994 → 181 ms at
  N=16, 5237 → 278 ms at N=32 — and every row is listed within ~40 ms instead of
  648 + 130·N. Verified identical to `git submodule status` (paths, states,
  recorded shas) and to the old two-spawn summary (branch/short/subject) over 12
  repositories incl. detached, modified, de-initialized, packed-ref and
  linked-worktree checkouts. The blocking `resolve_root` spawn ahead of it was
  measured at 21 ms and deliberately left alone (a `vim.fs` walk cannot promise
  the identical string `git rev-parse --show-toplevel` returns, and that string
  keys the per-repository session state).
  `spawn` is also the **spawn-diagnostics seam**: with `vim.g.gitloom_git_debug` set
  to a file path it appends one record per spawn — the full argv (one element per
  line, so nothing is lost to concatenation), the resolved cwd + executable, the
  call chain, the job id or the thrown error, and the command line's length
  against the 32766-char Windows ceiling (see the resync bullet for the
  measurement). Fully inert unset: one `type()` check, no traceback walk, no file
  handle. On failure the original error is re-raised with `error(msg, 0)`, so
  behaviour is identical whether or not the hook is armed. Pure pieces in
  `fetch._internal` (`quoted_len` / `cmdline_len` / `spawn_record` / `debug_log`),
  tested in `tests/git_debug_spec.lua`.
- **Sort modes** (specification.md §3.1, cycled by `S`): gitloom owns the
  row-order *pipeline* (records, decides when to order, reflows), but each
  **sort mode** sources its sequence differently. `SORT_MODES`: `topo`
  (default) = `order_commits` (a Lua **DFS over a LIFO stack** mirroring git's
  `sort_in_topological_order` — it reproduces `git rev-list --topo-order`
  commit-for-commit, so there is no separate raw-git mode; see below); `date` /
  `author` = `git rev-list --date-order` / `--author-date-order`. The `rev` modes
  fetch their hash sequence via `fetch_rev_order` and `reorder_by_hashes` reorders
  `repo.order` to match (in place, no re-stream); the `gitloom` mode runs
  `reorder_repo`. `apply_sort()` dispatches (returns a Future — the `rev` modes
  are async) and is the single seam used at stream completion, on `S`, and in
  `resync`. The stream itself fetches `git log --topo-order` (a valid topo base
  for progressive paint + the `git` mode's verbatim order). `opts.sort_mode`
  picks the initial mode (default `gitloom`).
- **`order_commits` reproduces git's `--topo-order`** (spec §3.1): a DFS over a
  LIFO stack, not a date-priority sort. Ready tips (all in-set children placed)
  seed the stack **oldest committer-date first** (`%ct`/`cepoch`, git's own
  ordering; author date is the fallback for synthetic commits) so the newest pops
  first (git seeds newest-first then reverses the LIFO); popping a commit emits it
  and pushes each parent the instant it becomes ready (in parent order, so the
  LAST parent is descended first — git's discipline), so a merge's merged-in
  lineage is emitted contiguously right after the merge instead of scattered by
  date (the spaghetti fix). Date only orders the independent tips. Verified 100%
  commit-for-commit vs `git rev-list --topo-order` on a real (257) and a synthetic
  (15) repo, which is why there is no separate raw-git sort mode. `ordering_spec`
  locks the lineage-grouping on a merge fixture and the committer-date seeding;
  `commit_spec` covers the `%ct` parse. **Gotcha:** `integrate_commit` MUST copy
  `cepoch` when filling a placeholder — `fetch_refs` pre-creates every ref *tip*
  as a placeholder, and the tips are exactly what `order_commits` seeds by, so
  dropping `cepoch` silently falls back to author-date seeding and scrambles the
  order on squash-merge repos (author ≠ committer date — a 39%-match regression on
  a 638-commit repo).
- **Owned ordering + resync** (specification.md §3.1/§3.4): `order_commits`
  produces the authoritative `repo.order` for the default `gitloom`
  sort mode (via `reorder_repo`, which reuses the existing OrderItem objects).
  `resync` (the `R` key) is the in-place
  history refresh: snapshot the old ref tips → `fetch_ref_entries` (non-mutating)
  → `reconcile_refs` (`diff_ref_tips`-driven add/move/remove) → `fetch_new_commits`
  (`git log --parents --stdin` fed `<new tips>` + `^<old tips>`, only the
  newly-reachable — the revision list rides **stdin** because it scales with the
  ref count and a command line does not: on Windows the whole line must fit
  32767 chars *including* the resolved exe path, and libuv rejects an overlong
  one with `UV_ENAMETOOLONG` → nvim's `E903 … name too long: <git.exe>`. Measured
  by bisecting `jobstart` on nvim 0.11.6 **and 0.12.5 — identical**: last
  spawnable line = 32766 chars, counting the *quoted resolved* argv[0] (nvim
  substitutes `exepath`) plus each quoted argument plus one separator each. It is
  the **only** input that produces the error — a deep/UNC/missing cwd, a 300 KB
  environment, 5000 variables and a 200 KB `$PATH` each moved the threshold by
  exactly 0 (libuv short-path-shortens a cwd past MAX_PATH itself), and the
  argument *count* is irrelevant (one 32 KB argument and 1600 small ones cross at
  the same total). In gitloom's pre-fix shape that is **398 ref tips per side**
  (399 fails) — i.e. roughly 400 distinct refs, since a resync passes nearly the
  same set as both positives and exclusions. `vim.g.gitloom_git_debug` (fetch.lua's
  `spawn` helper, README → Diagnostics) prices every spawn against that cap.
  The pure builder `git.new_commits_query` is the tested seam and
  `fetch_new_commits` hands the list to `run` as `stdin`, which `vim.system`
  writes and then closes — `--stdin` reads to EOF, so a missed close would wedge
  the resync silently) →
  `integrate_commit` (the shared stream/resync per-commit linker, extracted from
  `on_batch`) → `prune_to_reachable` (`reachable_hashes` orphan prune) →
  `apply_sort` (re-establish the active sort mode) → `refresh_worktree` +
  `reflow`, restoring the hash-keyed
  cursor/scroll. The pure pieces (`order_commits`, `diff_ref_tips`,
  `reachable_hashes`) are tested; the window glue is not (like the other glue).
  NB: the `order_commits` heap uses sequential `hpop` assignment — a multi-assign
  `heap[1], heap[n] = heap[n], nil` aliases when `n == 1` and spins forever.
- **External diff is a pluggable provider** (specification.md §11.5): the
  `diff.open` callback takes a **`DiffRange`** (`{ rev, from, to }`), not a
  commit, so graph range-selection reuses it. `commit_range(commit)` builds a
  single-commit range (`<hash>^!`, empty-tree for roots); `range_endpoints(newer,
  older)` builds a commit-selection span (`<older>^..<newer>`; §13.5) — or a
  **single-rev** working-tree range when the newer end is a §4.2 node (see below).
  Both take a trailing `root` and stamp it on the range: the graph's repository
  (`repo.root` / the commit view's `root`), which is NOT Neovim's cwd for a
  submodule, a picked repository or a drilled-in frame. The default `open`
  (`open_diffview`) calls `require("diffview").open(range.diffview_args(range))`
  — `-C<root>` + the rev as an argv list, never `vim.cmd("DiffviewOpen " ..)`,
  which both lost the root (diffview resolves from the current buffer / cwd:
  `Failed to parse rev '<hash>^!'`, or a working-tree range silently opening the
  cwd repo) and would need Ex escaping for a path with spaces. diffview is the
  only optional dependency beyond snacks. `open_diffview` is exposed as
  `window._internal.open_diffview` for `diff_provider_spec`'s real-diffview test.
- **Neovim >= 0.10** — relies on the 4-arg `vim.str_byteindex` and the
  decoration-provider API.
