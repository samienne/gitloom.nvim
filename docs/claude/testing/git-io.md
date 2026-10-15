# Git I/O tests

Scope: per-spec coverage of parsing, streaming, spawning, the repository picker, the argv bound, ordering, the working tree and the diff provider. [specification.md](../../../specification.md) and [ARCHITECTURE.md](../../../ARCHITECTURE.md) remain authoritative. Index: [../testing.md](../testing.md).

- `tests/commit_spec.lua` — `parse_commit_line`, `parse_timestamp`, the
  date formatters (`format_absolute`, `format_relative`), and `make_line_buffer`
  (the unbuffered-stdout de-chunker: whole lines vs. the held trailing partial,
  cross-chunk stitching, byte-by-byte reassembly, blank lines; spec §3 streaming)
- `tests/stream_complete_spec.lua` — the commit stream delivers the WHOLE log
  under a deliberately slow (20 ms) batch handler: every commit of a 1500-commit
  scratch repository arrives, none cut mid-record. Guards the `jobstart`
  truncated-tail regression (the subject-less 1970 "root" row at the bottom),
  fixed by streaming through `vim.system` (`fetch.lua`'s `spawn`). Plus the
  BUFFERED side: `fetch_rev_order` and `git_code` (via `run_checkout`) return
  all 1500 lines while a hog holds the main loop in 20 ms slices — a buffered
  `jobstart` delivered 0 of them there (exit 0), which is why every spawn moved
  to `vim.system`
- `tests/stream_tick_spec.lua` — the stream worker's hand-off (§3.1's "paints
  progressively"): `fetch._internal.next_tick` defers rather than running inline,
  a `next_tick` self-chain lets the **event loop iterate** between slices, and a
  `vim.schedule` self-chain does **not** — both sides pinned, since the second is
  the regression (a scheduled callback is drained inside the same pass of the
  event queue, so nothing reaches the screen until the whole log is processed).
  Observed through a libuv **idle handle** (one callback per loop iteration),
  which unlike `SafeState` still fires while `vim.wait` holds the loop
- `tests/git_debug_spec.lua` — the `vim.g.gitloom_git_debug` spawn-capture hook
  (fetch.lua's `spawn` helper): `quoted_len` / `cmdline_len` (libuv's
  `quote_cmd_arg` model — verbatim, empty, space-wrapped, backslash-doubling —
  pinned against the two bisected data points, `cmd` and a space-bearing `git`
  path, that both land on exactly 32766), `spawn_record` (every argv element on
  its own line, cwd, site, exe, argc, the `EXCEEDS` flag and the failure text),
  `debug_log` (inert unset, appends one record per spawn) and `spawn` end to end
  (a real spawn captured / nothing written when unset). Plus **the model against
  the real OS**: two spawns through fetch.lua's own `spawn` (`vim.system`), one
  command line of exactly `WIN_CMDLINE_MAX` characters and one of `+1`, asserting
  the first spawns and the second does not (re-raising `ENAMETOOLONG`) — the cap
  bisected against `jobstart` carried over unchanged
  — so the number the diagnostic reports can never drift from the OS
- `tests/repo_picker_spec.lua` — the repository picker's **discovery core**
  (§2.1), the pure pieces behind its 1 + N spawns: `submodule.parse_gitlinks`
  (`git ls-files --stage` → the index's `160000` gitlinks — non-gitlink modes
  skipped, index order kept, a path with spaces, a conflicted path's stages
  collapsed to one flagged entry taking the best object name whatever the line
  order, malformed lines ignored), `submodule.submodule_state` (the four states
  from the recorded sha + the on-disk head: no gitdir ⇒ `uninitialized` even when
  conflicted — "is there a repository to open" is the one distinction the picker
  acts on — conflict, moved-off ⇒ `modified`, and an unknown head degrading to
  `ok` rather than guessing), and the on-disk plumbing parsers
  `parse.parse_gitdir` (relative + absolute `gitdir:` pointers), `parse.parse_head`
  (attached branch / a symref outside `refs/heads` / a detached hash / a trailing
  CR / an unreadable HEAD), `parse.packed_ref` (a refname's hash, never a `^peel`
  line or the header) and `parse.parse_summary` (`%h%x1f%s%x1f%D` — the branch
  ONLY from `%D`'s `HEAD -> x` arrow, so a branch merely coinciding with a
  detached HEAD is not reported as current; empty repo ⇒ empty fields). The
  filesystem reads (`git_dir`/`head_info`) and the async picker orchestration are
  I/O and window glue, not unit-tested
- `tests/fetch_spec.lua` — the git I/O layer's **argv bound** (§3.4):
  `git.new_commits_query`, the resync query builder — the one command whose
  revision list scales with the repository's ref count. Asserts the argv stays
  constant-size at any tip count (no hash, no `--not`, on the command line), that
  the modelled Windows command line stays under the measured 32766-character cap
  for 0…5000 tips per side, the `^`-per-exclusion stdin encoding, and — against
  the real repository — that the `--stdin` form's output is **byte-identical** to
  the old command-line form. Guards the E903 `name too long` resync regression.
  Plus the **range diff to the working tree** (§4.2/§13.5), driven against a REAL
  dirty scratch repository (a staged edit, an unstaged edit, an untracked file):
  `fetch_range_diff` builds its argv from the endpoints' *shape*, so staged gives
  `--cached <base>` (the staged edit only), unstaged gives `<base>` (staged +
  unstaged, never untracked — `git diff` does not list those) and untracked gives
  the **same rev** plus the §3.3 synthesized additions, which is the only thing
  distinguishing the two and hence the reason for the `untracked` flag.
  Plus the **range diff's exit code** (§13.5): `fetch_range_diff` resolves
  `git_code`'s `{ code, out, err }`, so a real range gives `code == 0` + the patch
  while an unresolvable endpoint gives a non-zero code, empty `out` and git's own
  stderr — driven against the real repository, since the point is that the exit
  code survives the transport. Guards the swallowed-exit regression where a failing
  `git diff` reached the range view as an empty patch
- `tests/ordering_spec.lua` — gitloom's owned row order + the resync pure pieces
  (spec §3.1/§3.4): `order_commits` (the DFS topological sort reproducing git's
  `--topo-order` — child-before-parent validity is the hard invariant, plus
  **lineage grouping** (a merged-in lineage emitted contiguously right after its
  merge — the `m, f1, f2, p1, base` fixture), the newest-first tip tiebreak,
  determinism, identity-preservation, and ordering only the given set so
  out-of-set relationships are ignored), `diff_ref_tips` (the added/removed/moved
  ref classification) and `reachable_hashes` (the orphan-prune reachability walk;
  parents as Commit objects or raw hash strings)
- `tests/worktree_spec.lua` — the working-tree virtual-commit pure helpers, for
  the three nodes staged / unstaged / untracked (spec §3.3/§4.2/§11.8):
  `parse_status` (the `git status --porcelain` staged/unstaged/untracked counter —
  X vs Y, `??`, renames/adds, mixed, clean, plus the `paths` count — each changed
  path once, the §10.4.2 prompt's N), `commit_range` for a virtual commit
  (staged → `--cached`/`to=index`, unstaged → `HEAD`/`to=worktree`, untracked →
  the same worktree range as unstaged, real commits unchanged; §11.5),
  `worktree_label` (the graph-row subject + pluralized counts) and
  `format_worktree_detail` (the commit-view state header); plus the virtual row's
  **rendered lane continuity**: with HEAD mid-graph (in-set descendants above it)
  the unstaged node sits where lanes cross, and under `gutter` it owns a handover
  line above its node line — `display_item` must hand every row's `above`/`merge`
  lines to the listview (raw + focused × compact + gutter). Guards the regression
  where the virtual branch dropped them, cutting every crossing lane at the ◌
- `tests/diff_provider_spec.lua` — the external diff provider targets the graph's
  **repository root**, not Neovim's cwd (§2.1/§11.5): `commit_range` /
  `range_endpoints` stamp `root` on every range shape (real, root commit, span,
  empty-tree span, each working-tree form) and leave the range otherwise
  unchanged; `diffview_args` (`-C<root>` first, a root with spaces as ONE
  argument, `--cached <base>` split into flag + rev, an empty rev contributing
  nothing, no `-C` without a root). Plus **end to end against the real diffview**
  (loaded from the lazy install dir; `pending` when absent): cwd in one scratch
  repository, the graph in another whose path has a space, and the default
  provider (`window._internal.open_diffview`) must open a view whose adapter
  toplevel is the graph's repository with no error — for a single-commit range
  (the reported `Failed to parse rev '<hash>^!'`) AND a working-tree range (which
  without `-C` "succeeds" silently in the cwd repository). Views are closed only
  in the final cleanup: closing one between tests races diffview's async load
