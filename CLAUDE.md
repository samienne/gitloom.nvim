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

A read-only git commit-graph viewer for Neovim — it never stages, commits or
rewrites history by itself; the exceptions are actions the user explicitly picks
from the `<C-Space>` command palette: checkout (spec §10.4.1), checkout & examine
(§10.4.2 — which may also `git stash push -u` the uncommitted changes, after a
prompt, and re-apply them on Return), fetch / pull (§17) and the branch sync
(§17.2: fast-forward / reset a local branch to its upstream — reset is the one
action that can discard work, so it always confirms). `:GitloomGraph` opens a
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
- **Every commit on `master` makes one meaningful change.** How a branch lands
  there depends on its commits:
  - **One commit** — fast-forward (rebase it onto `master` first if needed).
  - **Several commits that are not each a meaningful step** (work in progress,
    fixups, "address review") — squash them into one commit.
  - **A real merge** (`git merge --no-ff`, with a summary message describing
    *what* and *why*) — only when the branch's commits are carefully curated,
    each a self-contained meaningful step. Curate them before merging.
- Landing on `unstable` for test-driving is unaffected: it stays a
  `git merge --no-ff` merge of the branch.
- **A merged branch is finished.** Once a branch has been merged (into
  `unstable` or `master`), never add commits to it or merge it again. Follow-up
  work — a cleanup, a fix to it, a review change — goes on a **new** branch from
  the current `master`. Continuing a merged branch makes the history graph messy.

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

- `tests/refs_spec.lua` — `classify_ref`, `group_refs` (compact ref display,
  incl. carrying a tracked local branch's upstream onto its group; §6.3, and
  moving the branch HEAD is on — the head ref's `branch`, else the fallback — to
  the FRONT flagged `current`; none when detached), `head_summary` (the
  post-checkout notice, incl. §10.4.1's behind suffix — strictly behind /
  diverged only, never ahead-only / gone / detached), `decoration_texts` / `pane_labels` drawing it first as
  `(HEAD → name …)` (§6),
  `track_segments` / `track_label` (the upstream divergence indicator's coloured
  segments + byte-identical plain label: ahead/behind/diverged/gone/in-sync),
  `decoration_texts` + `ref_picker_items` upstream threading (§6.3),
  `owners_from_refs` (view-builder owners per ref; an attached HEAD skipped, a
  detached HEAD an owner with id `HEAD`; §10/§10.6), the
  branch-mode toggle helpers `next_mode` / `selected_owner_ids` / `collapse_owners`
  (§10/§10.4), and the **linked-worktree refs** (§3.2/§4.1): `parse_worktrees`
  (the `git worktree list --porcelain` stanza parser — main-vs-linked, bare,
  detached *derived* from a HEAD with no branch, basename from either path
  separator), `worktree_refs` (the `wt:<dir>` labels + all three skips: the main
  worktree, bare/headless, and **any commit an existing ref already points at** —
  which subsumes "checked out on a branch"; two worktrees on one commit yield one
  label; the caller's `taken` set is not mutated), and the new kind flowing
  through `group_refs` (its own `worktrees` bucket) / `decoration_texts` +
  `pane_labels` (`{wt:<dir>}`, after the tags) / `ref_decoration_index` /
  `selected_owner_ids` / `owners_from_refs`; plus the **pin icon** (§6/§10.6):
  `decoration_texts` / `pane_labels` / `marker_units` given a `PinMarks` prefix a
  pinned ref's label inside its bracket (branch group via its local or any listed
  remote ref, tag, worktree), never HEAD's label (attached or detached), and
  `icon = ""` turns it off
- `tests/head_marker_spec.lua` — HEAD's node marker (§5.3) through the real
  `get_column_chars`: `●` in `palette.head` for the commit carrying the `head` ref
  (attached / detached), overriding tip / root / the merge icon; a §4.2 virtual
  node keeps `◌`; a collapsed head holding HEAD keeps `◍` in the HEAD colour; an
  out-of-cone HEAD node dims; `icons.head` honoured and `""` turns it off; and a
  laid-out graph marks exactly HEAD's row, mirrored or not
- `tests/label_color_spec.lua` — ref labels take their node's lane colour (§6
  "Label colour", §12.2) through the real `display_item`: a plain row's labels
  (branch group incl. `↑remote`, tag) equal the node glyph's `get_column_chars`
  colour; a `gutter` `own_lane_up` node colours them from the up wire (unflagged:
  the down wire); a collapsed `◍` head; each marker of a packed row its OWN node
  colour; the attached label's `HEAD → ` prefix and a detached `HEAD` keep
  `palette.head`, the h/l-selected label `palette.selected`, a pointer mark its
  `hl`; out of cone the label is `dim_hl` of the lane colour (a packed marker per
  marker), in cone / no pivot undimmed; `lane_label_colors = false` restores the
  per-kind groups. Panes: `pane_labels`'s `arrow` span and `node_lane_hl` on a
  header-style (segment-level `highlighted`) row matching the glyph. The pane
  window glue (`render_pane`) is untested
- `tests/ref_picker_spec.lua` — the ref-picker pure pieces (spec §2, `<leader>b`):
  `bump_recent` (the session MRU list — newest first, deduped, input not mutated),
  `ref_picker_items` (name → Ref registry → ordered picker entries: session-
  recent first in MRU order then grouped HEAD / local / remote / tag by name,
  commitless refs skipped, fields the picker shows incl. the match `text`), and
  `ref_decoration_index` (picked ref → its decoration index for pre-selection:
  local/remote → branch group by short name, tag → after the branches, HEAD/absent
  → nil)
- `tests/ref_cycle_spec.lua` — the `%` local ⇄ remote branch cycle (spec §2):
  `ref_cycle_members` (local first, then remotes in `git remote` order, then any
  unlisted remote by name — the fallback before `ctx.remotes` loads; only existing
  refs; same-commit members included), `ref_cycle_next` (the step + wrap-around,
  starting from a remote, a remote-only branch, `alone` with the short name for no
  counterpart, `none` for a tag / worktree / HEAD / unknown ref; stepping past a
  member whose commit is not in the `visible` set — wrapping round, `hidden` with
  the short name when no other member is visible), `visible_hashes` (the jumpable
  set: row commits, collapsed regions, packed markers + their regions — what
  `goto_hash` finds) and `cycle_source`
  (the h/l-selected decoration, else the first branch label with HEAD's first; nil
  on a tag- / worktree- / detached-HEAD-only or ref-less row). The window glue —
  the jump and the `ctx.ref_cycle_last` grouped-member memory — is untested.
  `tests/palette_spec.lua` asserts the real registry offers `%` in the commit and
  branch contexts (not markers / selection)
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
- `tests/open_trace_spec.lua` — the open-path phase trace
  (`vim.g.gitloom_open_trace`, §10.8): inert unset and inert for a non-string,
  one `NNNN +Mms event k=v …` record per call with the fields in sorted key order,
  every phase name the open path emits, the `open` record restarting the clock and
  the sequence, and — the regression the shared writer risks — that the pane trace
  keeps its own counter across an open trace's reset
- `tests/selection_spec.lua` — `move_selection`, `decoration_texts`,
  `ref_byte_col` (h/l ref selection + cursor parking), `pack_right`
  (the right-pinned ref width budget), `window_right` (the selection-windowed
  overflow, §6: a contiguous window around the selected ref with separate
  left/right `+N` markers; greedy right-then-left growth; the selected item always
  shown even when it alone overflows; sel clamping; empty), and `refresh_columns`
  width aggregation from `below` and from every stacked `above`/`below` row (§6.1)
- `tests/ref_window_spec.lua` — the windowed right-ref overflow **end to end** (§6),
  incl. HEAD's label staying visible ahead of the `+N` (attached `(HEAD → x)` and a
  detached bare `HEAD`):
  gitloom's `display_item` (setting `line_right` + `line_right_sel`) feeding the
  listview's `build_line` windowing, rendered into a stubbed window — default shows
  whole labels + a trailing `+N` (overflow hidden), selecting the overflowed ref
  scrolls it fully into view with the cursor target (`ref_byte_col`) resolving to
  it, and a single over-long selected ref truncates cleanly with `…` within the
  window (never spilling past the edge); the **pin icon** is part of the drawn label
  (windowed into view when selected, found by `ref_byte_col`, never on HEAD's
  label); plus the **packed marker row** (§10.4):
  its labels left-align after the graph (`line_right_align = "left"`) but window the
  same way around the selected marker (`+N` overflow, selected scrolled into view)
- `tests/label_mode_spec.lua` — the dual label mode's continuation graph
  (spec §6.1): `passthrough_columns` in both directions (`up` keeps lanes
  entering from above, `down` keeps lanes leaving below — the message row;
  a crossing keeps only its through-vertical; edge objects shared so §12 dimming
  still applies) and its rendering via `get_column_chars` (only `│`/blanks — no
  node or junctions — each vertical coloured by its lane slot)
- `tests/listview_spec.lua` — the multi-real-line bookkeeping (spec §6.1 dual):
  the buffer-line ↔ item offset map (`rebuild_starts`/`item_index_at`: mixed line
  counts, clamping, the incremental append path) and a windowed smoke test (snacks
  stubbed with a real window) that an item renders the right number of real buffer
  lines and that `relayout` grows the buffer when a mode switch makes a commit two
  rows, and that `set_items` swaps the whole list and re-lays the buffer (the
  reflow-swap primitive; §10.5)
- `tests/commit_spec.lua` — `parse_commit_line`, `parse_timestamp`, the
  date formatters (`format_absolute`, `format_relative`), and `make_line_buffer`
  (the unbuffered-stdout de-chunker: whole lines vs. the held trailing partial,
  cross-chunk stitching, byte-by-byte reassembly, blank lines; spec §3 streaming)
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
- `tests/future_spec.lua` — the vendored promise `make_future`: a `.next` callback
  runs whether attached before **or after** the future resolves, values chain, and
  a returned future flattens. Guards the regression where a synchronously-resolved
  future (the gitloom sort mode's `apply_sort`) dropped its chained callbacks, so
  the open-time worktree + reflow (the §10.7 default collapse) never ran
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
- `tests/commit_view_spec.lua` — the commit view's pure pieces (spec §11):
  `parse_show` (git-show field splitting, multi-line body, empty parents),
  `format_commit_detail` (committer-differs branch, refs line, body indent),
  `format_diff` (add/delete vs `+++`/`---`, hunk + file headers, context),
  `diffstat_files` (per-file counts, `start` offsets, rename, binary),
  `format_diffstat` (summary totals, per-file rows), and `commit_range`
  (single-commit `DiffRange`: `^!`, empty-tree for roots, `from` = first parent),
  plus the **message wrap** (§11.2.1): `message_width` (the 100-cell cap),
  `wrap_message` (paragraph join + re-wrap, blank lines kept, indented / tab /
  fenced lines untouched, final-paragraph trailers and URL-only lines verbatim
  while a `Key: value` line elsewhere reflows, list items with a hanging indent
  joining aligned and lazy continuations, an overlong word left whole, display-
  width (double-width) measuring, the subject wrapped on its own),
  `format_commit_detail`'s `width` (indent counted; nil = as is), and
  `window.build_commit_rows` with a wrapped body: `meta_end`, `diff_start`, the
  diffstat `file_jumps` and the diff_start-relative context-header mapping all
  shift by exactly the body's extra lines
- `tests/commit_selection_spec.lua` — the commit-selection (range) pure helpers
  (spec §13): `range_endpoints` (single-commit `^!`, span `<older>^..<newer>`,
  empty-tree when the older end is a root, plus the **working-tree newer end**
  (§4.2/§13.5): staged → `--cached <base>`/`to=index`, unstaged → `<base>`/
  `to=worktree`, untracked → the same plus the `untracked` flag, the base still
  the older end's first parent (empty tree at a root) and a *virtual* base
  resolved to its own tree state — asserted as an invariant too: never a sentinel
  hash in the rev, never a `..` span), `sel_ascend_children` (first-parent
  children first; a §4.2 working-tree virtual commit **is** ascended into, the
  whole stack HEAD → staged → unstaged → untracked walkable and clamping at its
  top on its own, with an
  ordinary child asserted unaffected), `sel_step` (extend/contract along the branch, flip at the
  anchor, clamp at tip/root) and `sel_switch` (rotate the parent at a merge /
  child at a split, no-op on a linear path; §13.2/§13.3), and `format_range_detail`
  (the range view's metadata: `N commits  (oldest..newest)` then newest-first
  hash + subject rows, plus the **synthesized working-tree row** — a `working` id
  cell instead of the sentinel, and `worktree_label`'s text for each of the three
  states; §13.5), and `format_git_error` (the one line the range view
  shows in place of the diff when `git diff` fails: label + exit code, git's stderr
  appended but only its first line, CR-trimmed, `exit -1` for an unspawnable job)
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
- `tests/checkout_spec.lua` — the palette's row entries + checkout (incl. the
  leading `(HEAD → x)` label resolving to branch `x`)
  (§10.4/§10.4.1): `palette.row_entries` order per row kind, scoped to the
  context (§17.1) (plain = commit → diff `(D)`, checkout, checkout & examine —
  **no examine**, `<CR>` is examine now; a selected branch / collapsed head →
  checkout of the branch / the tip, then collapse|expand `(<Space>)`, hide —
  **no** commit diff and **no** checkout & examine; a mainline branch → its
  checkout only; packed markers with none selected → per-marker expand/hide
  (`expand:<i>`/`hide:<i>`), no checkout; one selected → ONLY its checkout,
  `expand:<i>`, `hide:<i>`; diff and checkout & examine only with a provider; no
  checkout of either kind on a §4.2 virtual commit; no row → nothing), `selected_ref` (decoration index → local /
  remote-only / tag / worktree ref, a branch group preferring its local branch),
  `checkout_spec` (the argv per ref kind — `git switch <name>`, `git switch
  <short>` for a remote, `git checkout --detach <hash>` otherwise, a collapsed
  head detaching at its tip — and never a force flag), and `run_checkout` against
  a REAL scratch repository passed as the root (not the cwd): a branch switch and
  a detach land, and a switch over a conflicting dirty file is refused with a
  non-zero code + stderr, HEAD and the file untouched
- `tests/palette_spec.lua` — the command palette (§17): `palette.palette_entries`
  as ONE ordered list — the context first (the row's entries, or the `selection`
  entries **instead** while selecting: Open diff `(D)` + Checkout & examine
  selection, only with a provider), then the globals (Return first, only while an
  examine is active; Fetch / per-remote Fetch / Pull — no Refresh command, `R` is a
  key; remotes nil / {} / a list giving no / no / one `fetch:<remote>` entry
  each; **Reset view settings** last among the globals in every context, §18.5);
  no examine entry; a row entry carries an `op`, a registry entry an
  `action` (bound to ctx + remote); scope + `when` filtering and function labels
  on a custom registry; then the **key entries** over a FAKE registry (§17.1):
  `row_context` (commit / branch / markers, a packed line with a marker selected
  → branch), the per-context sets (commit: no `P`/`<Space>`; branch: no commit
  diff / examine; marker selected: only that marker's checkout / expand / hide;
  no marker: per-marker expand / hide + global keys; selection: `V`, `D` once),
  groups refs → view → select → other, hints derived from the registry key, a key
  already shown never repeated (so no duplicate `R`), ungrouped / handler-less
  keys never listed, a key entry running its handler; `help_lines` (grouped,
  ungrouped last, aliases joined, aligned, a newly added fake key picked up with
  its `help` text); and the REAL `GRAPH_KEYS` (`window._internal.keys`):
  well-formed (a desc each, known groups / contexts, no lhs bound twice), motions
  and plumbing ungrouped, `R` once, every key in the help, `<Space>` offered on a
  branch row only where it toggles (not on a `mainline` row; once on expanded /
  collapsed, as the row entry; on a selected packed marker); `remote.remote_command` (`git fetch --all`, `git fetch <remote>`,
  `git pull --ff-only`, `GIT_TERMINAL_PROMPT=0` in a fresh env table, pull's
  resync-on-failure, never forcing), `remote.parse_remotes` (blank lines, CR), `remote.failure_text`
  (the `fatal:`/`error:` line first, stderr as is, stdout fallback), and
  against REAL scratch repositories (a bare remote + two clones + a second bare
  remote): `fetch_remotes` order, fetch --all moving `origin/main`, a per-remote
  fetch moving only that remote's ref, pull fast-forwarding a strictly-behind
  branch, a diverged pull refused with HEAD unmoved, pull with
  no upstream failing with a code + stderr (HEAD unmoved), and the env reaching
  the job (a `!echo` alias prints `$GIT_TERMINAL_PROMPT`)
- `tests/sync_spec.lua` — the branch sync (§17.2). Pure (`gitloom.git.sync`):
  `sync_target` / `sync_offers` per tracking state (behind → ff + reset; ahead /
  diverged → reset; in sync / gone / no upstream / no refname / a remote ref / a
  tag / a worktree → none), the reset prompt's change count
  (`parse_status`'s `paths - untracked`: each changed TRACKED path once — `MM` and
  a rename count 1, `??` never), `ff_command` / `reset_command`
  for the current branch vs another (never a `+` refspec, `--force` or a remote
  name), `reset_prompt` / `prompt_text` per case (nothing lost → the question
  alone; commits / uncommitted lines; singular counts; another branch's dirty
  tree not mentioned), `sync_stale` (tip / upstream tip / current branch / dirty
  count / a failed read), the notices; and `palette.row_entries` reaching it (a
  selected local branch, a remote ref / tag / commit row getting none, a
  collapsed head's or selected marker's SOLE local branch, none when ambiguous).
  Plus a **remote ref with a local counterpart elsewhere** (§10.4.1):
  `select.local_counterpart` (none without a local namesake or on one commit) and
  the entries it yields — behind → `checkout_ff`, ahead / diverged →
  `checkout_reset`, a non-tracking / in-sync / gone local → detached only, a
  current local → the plain `fast_forward` / `reset_branch`, always followed by
  the detached checkout of the remote's commit — plus `checkout_commands` (never
  forcing), the `switching` reset prompt and `checkout_note`.
  Then against REAL scratch repositories (`origin/main` a locally created
  remote-tracking ref — no network): the ref read carrying `upstream.ref`,
  `fetch.sync_probe`, a non-current fast-forward leaving the files untouched, a
  current one, a diverged ff refused (both forms, branch unmoved), a ff over a
  conflicting dirty file refused, reset of the current branch (ahead + dirty — an
  untracked file survives; strictly ahead), of another branch, both refused for a
  branch checked out in a linked worktree, the stale-tip / dirty abort decision,
  and a LOCAL-branch upstream (`refs/heads/<x>`); and the §10.4.1 checkout +
  sync through `fetch.run_steps`: ff + switch lands HEAD on the branch at the
  upstream, a diverged ff refused at step 1 (nothing moved), a switch refused at
  step 2 leaving the branch fast-forwarded, `switch -C` resetting a diverged
  branch and checking it out (upstream kept, old tip in the reflog), and refusing
  over a conflicting dirty file. The window glue is untested
- `tests/examine_spec.lua` — Checkout & examine (§10.4.2). Pure:
  `range.examine_range` (ONE rev — the older end's first parent — `to =
  "worktree"`, `-C<root> <base>` as diffview args; a root older end → the empty
  tree; a raw-hash parent; a working-tree newer end → exactly `range_endpoints`),
  `examine_stash_message` (branch vs detached origin), `dirty_count` (the prompt's
  N = changed PATHS, each once: an `MM` file and a rename count 1, so N is not the
  per-state sum), `examine_plan` over clean /
  dirty × single / range × a working-tree newer end (`open`, no checkout, no
  stash) × a newer end AT HEAD — **Examine**, attached or detached (`open`
  `examine_range`, no checkout / stash / state, dirty or not, an active examine
  left untouched; `needs_checkout`) × an examine already active (clean: `orig` + stash kept, only `examined`
  moves, the active state not mutated; dirty: `refuse` "Return to … first" — no
  stash chain), unknown HEAD refused, never forcing; `return_plan` (branch → `git
  switch`, detached → `git checkout --detach`, apply `--index` by SHA + the plain
  fallback argv only with a stash, the label); `index_refused` (only git's
  "conflicts in index" refusal, either capitalisation, licenses the fallback — not
  a merge conflict, a local change in the way, a success or a spawn failure);
  `stash_index` (by SHA, CRLF-safe, nil when absent); the palette entries
  that reach it (HEAD's row → `Examine <short>` op `examine`, another row or an
  unknown head → Checkout & examine, none without a provider, Return still listed;
  the selection entry `Examine selection` for a HEAD / working-tree newer end).
  Then the git side against REAL scratch repositories
  (`fetch.examine_probe` / `examine_run` / `examine_return`): the probe's branch /
  detached / counts (a staged-only + an `MM` + an untracked file → N = 3); Examine
  of HEAD's commit on a dirty tree (attached and detached) → `open`, nothing
  stashed, HEAD and the edits untouched; dirty → stash (`stash@{0}`, the message) → detached checkout
  → clean tree, then Return → branch, edits AND untracked files restored, stash
  dropped; **the index round-trips** (a staged edit comes back staged, an unstaged
  one unstaged, an untracked file restored; one file with BOTH a staged and an
  unstaged edit keeps both); the **`--index` fallback** (a staged line-1 edit while
  `main` moved line 3: git refuses `--index`, the plain apply merges, the changes
  are back unstaged, `unstaged` flagged, stash dropped — and when the plain apply
  conflicts too the stash is KEPT); clean → no stash, Return switches back; a second examine keeps orig +
  stash and a dirty one is refused; a conflicting apply KEEPS the stash (HEAD back
  on the branch); a failed switch stops before the apply; a checkout failing after
  the stash re-applies it (clean → dropped); and drop-by-SHA leaves another
  session's stashes — one below AND one pushed on top meanwhile — alone. Plus,
  with diffview in the lazy dir (`pending` otherwise), the single-rev open's right
  side is `RevType.LOCAL` and the left `COMMIT`
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
- `tests/reachability_spec.lua` — `reachable_cone` (spec §12.1: pivot/ancestors/
  descendants, no cousins, viewport clipping); the **lane model** (`build_graph`
  attaches `parent_lanes`/`child_lanes`, sharing one Lane object per edge); and
  `mark_reachable` (the Lane walk): cone markers light, an edge is highlighted iff
  it's in the cone, a sibling sharing a fan stays fully dim (exact, no bus
  over-lighting), and the shared descent/ascent at a separate split/merge line
  keeps a non-trunk cone lane connected through the hub
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
- `tests/detached_head_spec.lua` — a detached HEAD is an anchor everywhere a pinned
  ref matters (§2/§6.2/§10.6.1): `select.head_target` (the open / return focus —
  HEAD's commit attached or detached, nil only without a HEAD commit),
  `pane.decline` (the panes' hide reason — off / no HEAD commit / no display, never
  for a detached HEAD) and `select.pin_candidate` (the dialog's "Pin new branch…"
  list — a detached `HEAD` offered, an attached one never, pinned refs skipped).
  The callers are window glue, not unit-tested
- `tests/pane_spec.lua` — the context-pane layout core (`gitloom.pane`, spec
  §6.2), **plus the multiple-above-rows contract** (§5 Line): a REAL `gutter` layout
  with two (and three) virtual lines above one commit, driven through
  `screen_lines` and BOTH seam functions at every window top/bottom × cover, with
  an oracle for "which line is rendered at screen row N" built independently of
  `screen_lines`. It pins the direction convention head-on — `virt = -1` is the row
  NEAREST the columns line, so the topmost of `n` is `virt = -n` = `above[1]` — and
  that `header_seam` always butts the TOPMOST above-row (a block start), while
  `footer_seam` never lands inside a block; `pane.seam_line` is the one decoder and
  inverting it fails three of these tests. Also covers:
  `boundary_below`/`boundary_above` (the lanes crossing a row's edge, by
  column), `split_boundary` (continue vs terminate via `node_of`), `mark_pane_cone`
  (the reachability-emphasis propagation: down `.parents` = ancestors, up
  `.children` = descendants, a confluence in-cone from the join, empty seeds → empty
  cone; §6.2), `footer`
  (the continuing lane seeds the layout so the footer's top seam matches the main
  view exactly, with the seam parent translated through `node_of` into a
  collapsed lane), `continue` (active lanes reach a root; **convergence junctions**
  kept when ≥2 crossing lanes land on the same parent — the seam-discontinuity
  fix — plus a fuzz sweep asserting no crossing lane strands at the seam across
  random DAGs × cutoffs), `continue_up` + `header` (the **minimal-connecting-subgraph**
  header: only how the pinned anchors relate to each other + the lanes crossing the
  cutoff — an isolated crossing lane terminates at a **seam head**, two crossing lanes
  meeting at a **confluence** render a junction (incl. a confluence dead-end head and
  nested confluences), an unpinned branch forking off the trunk/an anchor that
  reconnects to nothing is **pruned** (the stray-fork regression), a bubble on a pinned spine
  → node-less junction but an unrelated bubble is pruned, a **2×2 parallel-merge diamond**
  (two crossing lanes both forking to the same two children) declutters to clean parallel
  lanes — neither merge stays a junction, a genuine confluence preserved, a pinned anchor a labelled
  `◍` even when isolated, isolated seam heads packed onto a shared row — laid out by the
  direct seam-up grid with the seam as the bottom row matching the main view's top
  edge. Each lane keeps its own colour (`lane_of`, the main-view colour so the
  header matches the graph and forks are distinct — the pivot continuation keeps the
  pivot's colour, only an extra fork child takes a new one). Asserted vertically
  id-continuous, **distinct-coloured** (concurrent lanes never share a colour),
  through the wires-connect checker, with `assert_seam_match` (every crossing lane
  present at the seam) and a **minimal-subgraph oracle** (`confluences_of` +
  `assert_no_irrelevant_heads`: every ◍ is a pinned anchor, a crossing-lane begin, or a
  confluence — never an unrelated head) over a **fuzz sweep** of LARGE random DAGs ×
  cutoffs (8–20 commits, uncapped so tall headers are stressed), and replayed against
  a large real-world topology (every cutoff, 0 problems) during verification, the
  header `cap`
  (`keep_first`: keep the tip + seam-nearest rows, report the elided `+N above`
  count) and the footer `cap` (keep the root together with the `virtual` lines drawn
  directly above it), `drawn_lines` (a row's above / commit / merge lines flattened, one
  entry each), the pure **whole-commit seam** functions — both in **screen-row space** on the
  `screen_lines` model, exact mirrors: `header_seam(sm, ts, cover)` walks **down** from the
  top visible **screen row** `ts` to the first block **start** leaving ≥ cover rows above
  (seam = that item's **split** fan else columns; the header butts its top edge), and
  `footer_seam(sm, bs, cover)` walks **up** from the bottom visible **screen row** `bs` to
  the first block boundary leaving ≥ cover rows below (seam = that item's **merge** fan else
  columns). Both cover whole commit blocks so a virtual split/merge line is never split
  across the seam (the fix for the seam virtual-line drift — the header once used a
  display-index walk that assumed the top item's columns was the window top and drifted by
  a partial split fan above it), plus `header_ts`/`footer_bs` (the cursor-anchored
  top/bottom screen row) and `screen_lines` (flatten display → real columns + virtual
  split/merge rows, with display-index↔screen-row translation),
  `condense` (the topological condensed graph, both down and `up` modes:
  fork/merge junctions, roots/tips and anchor-ref heads kept, linear pass-throughs
  spliced into edges, edges re-pointed across them, spliced hashes mapped to the
  next kept node toward the root/tip, the anchor-ref filter, false junctions
  spliced, root rendered as a real node), `continue` (follow the active seam
  lanes' first-parent chains to a root: both lanes converge at their meeting
  junction and reach the root, every node's chain terminates at a root — never cut
  off — and no non-active branch is introduced), and the **chunking hook** (the
  async pane build, §6.2): a deep first-parent chain invokes `continue`/
  `continue_up`/`condense`'s optional `yield`, and the chunked output is identical
  to the synchronous (no-yield) path, and the **rebuild gate** `pane.gate` (§6.2):
  the three-call state machine `started`/`built`/`dropped` + `decide`, driven as
  SEQUENCES because the defect it pins is one of timing — an ABANDONED build must
  leave the gate uncredited (so the next debounce rebuilds), an in-flight one must
  not be restarted every tick, `built` must promote only a live `started`, and a
  later abandonment must not disturb the key already on screen. Reverting the
  credit to `started` fails four of them
- `tests/header_replay_spec.lua` + `tests/large_topo.lua` — the header replayed end
  to end over a **large real-world repository's full (`--all`) topology** (anonymised to
  synthetic ids — topology only, no hashes/names/messages), driven through the **full
  projection** (`view.owners` → `view.project` → `columns.layout`, first-parent focus,
  HEAD + dev pinned) and `continue_up`/`header` at **every** display cutoff: asserts the
  pinned anchors HEAD and dev keep their **graph lane id** throughout — they never sever
  onto a fresh synthetic id when a merge sits at the cutoff (the merge-at-cutoff
  anchor-severing regression)
- `tests/footer_replay_spec.lua` (+ `tests/large_topo.lua`) — the **footer** counterpart:
  the same real-world topology through the **full projection**, then the footer built at
  **every** cutoff and for **every rendered line the seam picker can land on** — a commit's
  `columns` line AND its virtual `split`/`merge` fan lines. Asserts the footer's **top row
  reproduces the seam line** (same column + id — no jog), no crossing lane **strands**
  (empty `terminate`), the pane's rows are in **topological order** (no row before
  an in-pane child), and lane **id-continuity** down every row; as drawn with the
  pane style, consecutive lines wire together and **nothing leaves the last line
  downward** (every lane lands on a node — the two-lane "loop" regression, where a
  collapsed root head the hash-keyed `order_of` could not rank sorted above its child). Guards the footer-layout
  stage against a mishandled virtual-line seam (the class the header's `header_seam` fixed).
  The seam-**picking** itself is the pure `pane.footer_seam` (below), unit-tested in
  `pane_spec` alongside `header_seam`. Plus the footer **as drawn**, under every layout
  policy with the pane's OWN inline merge style: `pane.footer`'s `rows` are drawn lines
  (one screen row each, `pane.drawn_lines`), so consecutive entries must wire together —
  same column, same lane id. Guards the `gutter` regression where the window drew only
  each row's commit line and dropped the policy's handover rows (§5.6), leaving a
  floating turn and an orphaned root
- `tests/screen_window_spec.lua` — the **FAITHFUL** screen-coordinate test: renders a buffer
  with `virt_lines` in a **real nvim window** EXACTLY as gitloom does (split →
  `virt_lines_above=true`, merge → below) and checks against nvim's ACTUAL rendering
  (`screenpos`/`winline`) across every cursor line × zt/zz/zb × several heights × bordered/
  unbordered: (1) `pane.screen_lines` reproduces nvim's layout (screenpos deltas == model
  `cols` deltas); (2) the **cursor-anchored** `footer_bs(sm, cursor, winline(), WH)` names the
  same `(line, virt)` nvim renders at the window bottom — cross-checked independently via
  `line('w$')`+`screenpos` (non-tautological), incl. split-at-bottom AND merge-at-bottom;
  (3) it **catches the bug** — the old `w0`+`win_screenpos` formula is wrong in real cases
  (`prod_wrong > 0`) while the cursor-anchored one is always right. The **header mirror**:
  the cursor-anchored `header_ts(sm, cursor, winline())` names the same `(line, virt)` nvim
  renders at the window **top** — cross-checked via `line('w0')`+`screenpos`, incl.
  split-**above**-columns AND merge-above tops — and catches the header bug (the old
  `ts = cols[w0]` assumption is wrong where the cursor-anchored one is right, `prod_wrong > 0`).
  Documents the nvim facts:
  `winline`/height are window-relative (border-robust), `win_screenpos` is the frame top,
  `line('w$')`/`line('w0')` are the last/first visible-**columns** line (a split at the top
  belongs to `w0`'s own fan above its columns)
- `tests/footer_bottom_spec.lua` — the footer **hides at the bottom** (§6.2), in a REAL
  nvim window with `virt_lines`: through the production `footer_bottom` → `footer_seam`
  path, no seam (`"at bottom"`) when the whole graph fits in the window (filler rows
  below) or after `G` (the last row at the window bottom), while one `<C-y>` up still
  builds a seam at the true bottom; plus the pure `footer_bottom` boundary (declines
  exactly when the unclamped bottom reaches the last row) and its agreement with
  `footer_bs` whenever it does not decline. Guards the clamped-`bs` regression
  (48fad8c) that drew a footer over the graph's own last commits
- `tests/footer_window_spec.lua` (+ `tests/large_topo.lua`) — the **count-based** screen model
  (§6.2): `pane.screen_lines` is exercised for the default single split/merge AND for
  **MULTIPLE** virtual rows above/below + dual-mode 2-row columns (count-based, signed `virt`
  offsets, not a boolean). Plus the sliding-window `footer_bs` bottom-derivation over the
  full-projection gitloom topology (pure synthetic frame) and a seam-visibility pipeline check
- `tests/header_window_spec.lua` (+ `tests/large_topo.lua`) — the **header** counterpart of
  the footer window sweep: the same full-projection gitloom topology, sliding the window
  **top** down every screen row (columns AND split-above-columns), asserting `header_ts`
  returns the true top (naive `cols[w0]` wrong where a split sits above, `naive_wrong > 0`)
  and the `header_seam` it implies rounds to a whole commit block that is fully visible
- `tests/color_spec.lua` — `gitloom.color`: sRGB↔OKLab/OKLCH round-trips, known
  conversions, and `generate` (golden-angle hues distinct and in-gamut)
- `tests/gitloom_spec.lua` — public surface (setup, command registration)
- `tests/persist_spec.lua` — the persisted view state (`gitloom.persist`, §18):
  `config_values` (setup() value else built-in, normalised; a partial merge style
  resolved over the built-in), `overlay` (a stored value wins only while its
  `base` equals today's configuration-resolved value; a wrong-typed / value-less
  entry is ignored), `set_pref` (stores `{ value, base }`, prunes other stale
  entries), `pins_for_save` (only the leading run of unreserved defaults still in
  default order dropped — a default moved below an explicit entry, or reserved,
  is kept with its place; order and reserve flags kept), `set_repo` / `repo_state` (per-root round trip, junk
  sanitised, an empty state removes the entry); and against a scratch file: round
  trip, rename-over-existing leaving no temp files, **two writers with different
  keys both surviving** (re-read before write), a corrupt / non-object file ignored
  with ONE warning and replaced by the next write, `persist = false` neither
  reading nor writing, and Reset clearing the global preferences + only the given
  repository. `tests/minimal_init.lua` redirects the module to a temp file for
  every test run, so no test touches the real `stdpath("state")/gitloom.json`; the
  smoke test (`make smoke`) checks the toggles' saves, `save_pins` and the live
  reset end to end
- `tests/progress_spec.lua` — progress reporting (`gitloom.progress`, §19): the
  tracker over a fake clock / timer and a recording provider — an Op ended before
  the show delay reaches no provider at all (default delay 300; `0` shows at once,
  no timer), one past it calls `start` once with the LATEST message then `report`,
  and `finish` exactly once however many ends (outcome defaulting to `done`);
  `close()` ends every live Op `cancelled`, none twice, a timer firing after it
  shows nothing and later starts are inert; a throwing `start` / sink leaves the
  caller unaffected; `provider = false` / `progress = false` arm no timer and
  notify nothing; `normalize`. Provider resolution: `"auto"` picks fidget iff
  `fidget.progress` loads, re-checked per Op (`op.fidget`, which drops fetch /
  pull's own start notice), `"fidget"` falling back to notify. The fidget adapter
  over a stubbed handle (client `gitloom`, `cancellable = false`, `finish()` on
  every outcome after naming `failed` / `cancelled`, never `cancel()`) and the REAL
  fidget from the lazy dir (`pending` when absent). The notify provider: a start
  notice + `done (N s)` only for an Op without notices of its own, nothing more for
  `failed` / `cancelled`, nothing at all when it ended before the delay, the running
  message never notified. Plus the glue paths reachable without a window
  (`window._internal.reflow_async` superseded → `cancelled`, erroring → `failed`,
  completing → left to the caller; `resync`'s closed-window exit → `cancelled`)
- `tests/snippet_spec.lua` — `graph_snippet` (the commit-search graph snippet,
  §15.3): the `[focus±radius]` window + reported focus row, top/bottom clamping,
  the focus-row gutter marker, the per-row subject, the shared graph-column width
  (subjects aligned), and a collapsed head labelled by its region count
- `tests/filter_spec.lua` — the in-graph filter-search pure core (§16):
  `smartcase_match` (case-insensitive unless the needle has an uppercase; literal
  substring, not a pattern), `filter_keep` (the keep-set from commits × query over
  subject **or** author; smartcase; blank query → empty), and `view.project`'s
  `keep` set (§16.3: a match stays a normal commit while the runs between matches
  collapse; junctions preserved; a kept match is never a node-less junction; nil
  keep = the plain collapse)
- `tests/pin_spec.lua` — the ordered pin list (§10.6) + the dialog (§10.6.1):
  `pin_resolve` (the unplaced defaults first — HEAD's anchor last among them —
  then the stored entries, a new pin at the bottom; unpinned suppressed,
  stale refs dropped, defaults never reserved), `pin_move` (clamped at both ends,
  reports the new index, carries the flag), `pin_toggle_reserved`, `pin_remove`
  (**unpin implies unreserve** — re-adding comes back unreserved), `pin_add`
  (idempotent), `pin_ids`, `reserved_order` (reserved-only, in list order — the
  order's meaning for *columns*; for lane identity every entry's place is its
  rank, `pin_rank`), and `pin_dialog_lines` (numbering, `◆` on reserved
  rows only, the key help, the add row, the row map, the aligned help column, the
  "not honoured yet" note). Plus a **windowed smoke** block driving the real
  dialog in a real float over a stub ctx (open/`<Space>`/`<C-j>`/`D`/`q`) — the
  keymaps, re-render and focus handoff, which the pure tests cannot reach.
  Plus the **implicit remote counterparts** (§10.6): `pin_counterparts` (same
  short name in `git remote` order, unlisted remotes by name, then a differently
  named upstream; none for a remote / tag) and `pin_rank` (with counterparts on
  — the anchor set: rank = place, a counterpart sharing its local's, an explicitly
  unpinned counterpart excluded, an explicitly pinned remote keeping its own; with
  them off — the layout's `opts.pin_rank`, entries only) and dialog lines without
  counterpart rows.
  `tests/window_internal_spec.lua` covers `effective_pins`/`effective_pinned`/
  `pin_rank`/`sync_pin_rank` (default order with HEAD's anchor last, nothing
  reserved by default, counterparts implicit anchors but NOT in the layout's rank
  map (§5.5: no rank, no pinned colour) and never rows,
  dropped with their local or by an explicit unpin, the ranks published on
  `opts` + `pane_opts`, and a detached HEAD pinning the `HEAD` ref last /
  unpinnable / dropped once attached), and `reconcile_refs` stamping
  the head ref's `branch` (nil when detached).
- `tests/pin_rank_spec.lua` — pin priority in lane identity (§5): `commit_rank`
  (best rank, `HEAD` keying), nil / empty / past-the-palette non-matching
  `pin_rank` byte-identical (fuzz + `large_topo`, every style × policy), the birth
  at a pinned tip (the `feature1`-off-`dev` case; a merged pinned tip ending the
  merge edge and starting its own pinned-colour lane; a counterpart ahead of its
  local reaching the tip unranked; equal rank one lane; a worse rank no birth),
  tier 0 beating seniority, ids /
  colours / ranks identical across policies, 0 glyph changes under the four
  lane-column policies and every invariant + `check_spine` (births licensed, seen
  > 0) under `gutter`, streaming == one-shot incl. a pin change forcing a re-lay
  (the fingerprint), and footer seeds carrying their main-view rank. Plus the
  **pinned colours** (§5.5): rank k's lane born with slot k and unchanged by a pin
  added below it; over a fuzz corpus with a 6-slot palette (generate on and off) no
  other lane holds slot k before rank k's branch start is found, and the slot IS
  recycled after; a diverged counterpart drawing an ordinary colour; pins past the
  palette falling back (generated, or shared without truecolor); a non-matching
  in-palette rank withholding its slot and moving nothing else; and the footer seed
  taking a withheld slot's reservation over (released once, reused as in the main
  view). `tests/pane_spec.lua` checks the header never de-collides a lane onto a
  pinned slot (`pane.header`'s `avoid`)
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
  produces a row that owns no subject. The `inline+mergesplit` characterization snapshot is pinned
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

`graph._internal` (`require("gitloom.graph")._internal`) exposes, **for tests
only** (not the public API): `classify_ref`, `group_refs`, `parse_worktrees` /
`worktree_refs` (the linked-worktree HEAD refs — porcelain parse + the
`wt:<dir>` labelling and skip rules; §3.2), `bump_recent` /
`ref_picker_items` (the `<leader>b` ref-picker MRU + ordered entries; §2),
`ref_decoration_index` (picked ref → decoration index for pre-selection; §2),
`marker_units` (a packed row's selectable marker labels; §10.4),
`display_item` (the per-row renderer — exposed for the §6 ref-window integration
test), `decoration_texts`,
`move_selection`, `ref_byte_col`, `parse_commit_line`, `make_line_buffer`
(the streaming-stdout line de-chunker; §3), `make_future` (the vendored promise;
exposed for `future_spec`), `order_commits` (the owned
topological row sort that replaced `git log --topo-order`; §3.1),
`diff_ref_tips` / `reachable_hashes` (the resync ref-diff + orphan-prune pure
helpers; §3.4), `parse_timestamp`,
`format_absolute`, `format_relative`, `parse_show`, `format_commit_detail`,
`wrap_message` / `message_width` (the §11.2.1 message wrap),
`format_diff`, `diffstat_files`, `format_diffstat`, `commit_range`,
`range_endpoints` / `sel_ascend_children` / `sel_step` / `sel_switch` /
`format_range_detail` (the commit-selection range + path-walking + range-view
metadata pure helpers; §13),
`parse_status` / `worktree_label` / `format_worktree_detail` (the working-tree
virtual-commit pure helpers; §3.3/§4.2/§11.8),
`reachable_cone`, `mark_reachable`, `build_graph` (Phase 1, delegates to
`columns.layout`), `get_column_chars` (Phase 2, the renderer),
`graph_snippet` (the commit-search graph snippet; §15.3),
`passthrough_columns` (the dual label mode's vertical-only branch line; §6.1),
`owners_from_refs` (refs → view-builder owners; §10), the branch-mode toggle
helpers `next_mode` / `selected_owner_ids` (§10), `pack_markers` (the
marker-packing pass; §10.4), `collapse_owners` (the region's collapsible
owners under the cursor; §10.4), the ordered-pin-list helpers `pin_resolve` /
`pin_move` / `pin_toggle_reserved` / `pin_remove` / `pin_add` / `pin_ids` /
`reserved_order` / `pin_dialog_lines` (§10.6/§10.6.1), `smartcase_match` /
`filter_keep` (the filter-search matcher + keep-set; §16.2), `ref_cycle_members` / `ref_cycle_next` / `cycle_source` / `visible_hashes` (the `%` local ⇄ remote
cycle; §2), and `selected_ref` /
`checkout_spec` (checkout; §10.4/§10.4.1 — the row entries themselves are
`require("gitloom.graph.palette").row_entries`).
`window._internal` additionally exposes `keys` (the `GRAPH_KEYS` key registry, §17.1),
`reflow_async` / `resync` (the §19.4 "always ended" glue paths, over a stub ctx),
`effective_pins` / `effective_pinned`,
`pin_dialog` (the §10.6.1 dialog, a windowed smoke-test seam) and `ctx` — the live
graph session, recorded by `open_graph`. The headless smoke test reads the
projected model through `ctx` because without a UI there is no rendered text to
inspect: the listview draws through a decoration provider, so the graph buffer's
lines are all empty.
`columns.layout` is reached via
`require("gitloom.graph.columns")`; the view builder `view.project` (which takes
the §16.3 `keep` set) / `view.signatures` / `view.owners` via
`require("gitloom.graph.view")` (§10).
`tests/graph_helpers.lua` additionally exposes `reference_signatures` (the §10.2
definition transcribed with no sharing — the oracle the interned representation is
compared against) and `line_sig` / `row_sig` (a rendered Line's / row's full cell
content as a comparable string, the cell-for-cell parity dump).
`listview._internal` exposes `pack_right` (the right-pin budget packer),
`window_right` (the selection-windowed overflow packer — window + left/right `+N`
counts; §6), `refresh_columns` (the column-width packer), and
`rebuild_starts`/`item_index_at` (the buffer-line ↔ item offset map for
multi-real-line items; §6.1).

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

Both layers run over **two corpora**: raw `dag()` items, and the same DAGs through
`h.focused` — the §10.7 first-parent projection an opened graph actually lays out.
The second is not redundant. `owns_subject` (§5.6) is false only for a collapsed
head or a junction marker, and a raw DAG has neither, so *every* non-subject-row
path in `columns.lua` is unreachable on raw fuzz however long it runs. Any new
layout invariant should be asserted on both.

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
  its commit line `columns` plus an `above` **list** of virtual lines (the §5.2
  split fan, and under the `gutter` policy its two handover rows — so one commit can
  render three lines above its own), an optional `merge` virtual line below, and the
  `parent_lanes`/`child_lanes` for reachability. `pane.seam_line` is the single
  decoder of a seam's `virt` against that list (`-1` = nearest the columns line).
- **GraphOptions / MergeStyle** — configuration; see specification.md §8.
- **listview** — the generic virtualized list widget the graph renders into.

See specification.md §4–§5 for full definitions.

## Implementation notes

Details not covered by the spec or architecture:

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
- **`vim.schedule` does not yield the screen.** A scheduled callback lands on the
  main loop's event queue, which nvim drains to empty before it iterates — so a
  worker that reschedules itself with `vim.schedule` starves the loop for its
  whole run and nothing is drawn. Measured on 0.12.5, 60 chained 8 ms slices:
  **0** `SafeState` events under `vim.schedule`, **59** under a 0 ms `uv` timer.
  `fetch.lua`'s `next_tick` is that timer, and it is why the commit stream now
  actually paints progressively. Use it (or `vim.defer_fn(fn, 0)`) for any
  self-rescheduling chunked worker; `vim.schedule` is still correct for a single
  hop out of a fast-event context.
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
  without it a senior sibling lane wins §5 identity at that parent, ours is evicted
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
  merged-in branch tip), **2** the most **senior**, the smallest id. A commit whose
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
- **Branch modes — the view builder** (`view.lua`, spec §10): a pure
  pre-Phase-1 stage projecting the immutable commit DAG + a view state (per-ref
  `normal`/`collapsed`/`hidden`) into an **OrderItem graph** of DisplayNodes that
  `columns.layout` lays out unchanged. `view.project` computes each commit's
  reachability **signature**, partitions into equal-signature regions, joins to a
  display mode, contracts each **linear** collapsed run to one `◍` head while
  keeping junctions (a fork, or a merge that still has a visible child, stays a
  real node so branch topology survives; a **merge tip** — a collapsed merge with
  no visible child — folds into a `◍` head since it is the branch's tip, §10.3),
  drops hidden commits, and re-points
  edges. graph.lua keeps
  `repo.order` (raw, 1:1 with commits) as the projection input and `repo.display`
  (the projection) as what the listview renders and `order_at`/`mark_reachable`
  index; `reflow()` rebuilds it and swaps via `controller.set_items`. With
  all-normal modes the projection is the identity, so `repo.display == repo.order`
  and streaming keeps its fast incremental path. `<Space>` and the palette's row
  entries set a branch's mode; signatures are cached across mode toggles (§10.5).
- **First-parent focus** (`opts.collapse_merged`, default on; spec §10.7, toggled
  by `c`): `view.owners(items, ref_owners, pinned, modes, cm)` builds the owner
  set so **every** owner is **first-parent-only** (`fp_only`) — each covers only
  its tip's first-parent line. The **pinned anchors** (`pinned`, a set of ref
  ids; §10.6) default normal; every other ref and every non-first merge parent
  (an anonymous `merge:<hash>:<i>` owner) defaults collapsed — so the graph opens
  with the anchors' mainline in full and every other branch a `◍` head.
  `view.signatures` honours `fp_only` (propagate only through `parents[1]`).
  **All owners** being fp-only (not just the anchors) is what makes a branch
  attributed to *its own* commits, so collapsing/expanding one branch doesn't
  drag in the earlier branches its history merged through (spec §10.2). It is a
  recomputed default, not a seed: `view_state.modes` holds only explicit user
  mode overrides, `view_state.effective` the resolved mode per owner (drives the
  `<Space>` toggle's starting point and the footer `focus` indicator). The
  stream-completion handler calls `reflow()` so the default applies on open.
- **Signatures are interned, not materialised** (`graph/sigset.lua`, §10.2): the
  cost of the projection tracks a repository's **merge density**, not its size. An
  `fp_only` owner flows down its tip's first-parent chain, and a merged-in branch's
  first-parent chain **rejoins the trunk** at its fork point — so on a trunk of
  merges every merge above a commit contributes an owner to it and one materialised
  `table<string,boolean>` per commit costs Θ(commits × owners). Measured on a
  12,999-commit / 6,499-merge repository (6,800 owners): **22.1M entries, 813 MB,
  847 ms** for `signatures` alone, against 13,000 entries for a linear history of
  the same length. `sigset` is a **hash-consed 32-way bitwise trie** over dense
  owner indices — adding an owner allocates O(depth) nodes and shares the rest —
  giving 40,579 nodes, 98 ms, and the whole completion pass 1219 → 374 ms
  (814 → 97 MB). Two consequences the projection consumes directly: a set has ONE
  representation (interned on level+base+contents), so "same region" is `a == b`
  instead of a sorted-and-concatenated `sig_key` per commit; and the mode join
  memoises **per node** (`summary`) instead of per commit. The pass ends by
  **sealing** the universe (releasing the hash-cons table + the memos — nothing
  builds sets after it), halving what the §10.5 cache retains, 18.3 → 9.7 MB; a
  sealed universe raises rather than minting a second node for an existing set.
  `view.signatures` still
  returns a `hash -> { [owner id] = true }` table — indexing it materialises that
  one commit's set — so `collapse_owners`, a head's stored `signature` and the
  §11.7.6 reveal are unchanged; it is deliberately NOT cached per hash (caching
  would let the cursor re-accumulate the footprint) and `pairs()` over the MAP
  enumerates nothing, so any test that iterated it must iterate the items instead
  or it passes vacuously. `view.project` still accepts a plain table of sets and
  takes an equivalent slower path — which is what the parity tests compare against.
- **Total owner coverage** (spec §3.2/§10.2): §3.1 streams `git log --all`, which
  in a repo with **linked worktrees** walks *every worktree's HEAD* — while §3.2's
  ref query reads only `refs/heads`/`refs/remotes`/`refs/tags`. The commit set was
  therefore a strict superset of the ref-reachable set, and those extra commits
  got an **empty signature** → `mode_of`'s "uncovered ⇒ normal" → a run of fully
  expanded rows in a focused view with no `◍` and nothing to pack. Worse, `R`'s
  `prune_to_reachable` deleted exactly those commits, so the open path and the
  resync disagreed. Two changes close it, and both are needed:
  1. **`worktree` refs** — `fetch_refs`/`fetch_ref_entries` chain
     `read_worktree_refs` (`git worktree list --porcelain` → the pure
     `parse.parse_worktrees` → the pure `refs.worktree_refs`), giving each linked
     worktree HEAD *nothing else names* a ref `wt:<basename>`. Skips: the main
     worktree (already the `head` ref), bare/headless, and **any commit an existing
     ref already points at** — the general form of "not if a branch matches", which
     also catches a detached HEAD parked on a tip. `:` is invalid in a refname, so
     `wt:` can never collide in `repo.refs`. A non-zero exit degrades to `{}`.
     Being in `repo.refs` is what makes them owners, pinnable, picker/pane
     entries, and — crucially — resync-reconciled instead of pruned.
  2. **`tip:<hash>` owners** — `view.owners` mints an anonymous fp-only, collapsed
     owner for every in-set commit with **no in-set child** that no ref owns, so
     coverage is total *by construction* whatever else `--all` drags in
     (`refs/original/*` is deliberately not filtered). **§4.2 virtual commits are
     excluded** (`c.virtual`): they are childless by construction and must stay
     visible — they are the case the empty-signature rule exists for.
  Anonymous owners are dropped from pinning structurally, not by a name test:
  `h_pin` filters on `repo.refs[oid]`, which `merge:`/`tip:` ids never satisfy.
- **Pin axis** (spec §10.6, toggled by `P`, managed by `L`): pin is the **anchor**
  set the focus default folds toward — it *generalises the trunk* (one anchor → a
  set). It is stored as **one ordered list**, `view_state.pins` (`PinEntry` =
  `{ id, reserved }`, priority order) plus `view_state.unpinned` (ids explicitly
  removed, which suppress the HEAD / `master` / `main` / `dev` / seeded-mark
  defaults; HEAD is its branch when attached, the `HEAD` ref itself when detached).
  `ctx:effective_pins()` resolves it (pure core `select.pin_resolve`: unplaced
  defaults — trunks, seeds, HEAD's anchor last — then the stored entries) into
  exactly the dialog's rows. **Implicit remote counterparts** (`pin_upstream`) are
  NOT entries, and take no rank and no pinned colour (§5.5/§10.6): `ctx:pin_rank()`
  is `select.pin_rank` with counterparts OFF — the entries' ranks (1 = highest), the
  layout map; `ctx:effective_pinned()` is the key set of `select.pin_rank` with
  counterparts ON (a local's `select.pin_counterparts`, unless explicitly unpinned)
  and is still what `view.owners`/`collapse_owners`/the pin icon consume. The header
  pane gets `columns.pinned_slots(pane_opts.pin_rank, #tracks)` as `pane.header`'s
  `avoid`, so its colour de-collision never hands out a pinned slot.
  `ctx:sync_pin_rank()` publishes the table as the layout input `opts.pin_rank`
  (on `ctx.opts` and `ctx.pane_opts`) at the top of every `reflow_build` and
  before the open stream — every pin change reflows, so that is the refresh.
  Pinning changes only the default *mode* and the ranks, not `fp_only` or the
  owner tips, so it does **not** invalidate the signature cache
  (like a mode toggle). `P` uses `branch_under_cursor`, pins only real refs (drops
  anonymous merge owners), appends to the list, reflows, and repositions the
  cursor. Anchors are the foundation for the context panes (spec §6.2).
- **Dedicated lanes + the pinned-branches dialog** (spec §10.6.1/§10.6.2, `L`):
  "holds a reserved graph column" is a **flag on the pin entry**, not a second
  list — so `reserved ⊆ pinned` and *unpin implies unreserve* are structural, and
  **pinning alone claims no column** (up to four are pinned by default). Every
  entry's place is its lane-identity rank (§5, `opts.pin_rank`); among reserved
  entries it also orders the columns (`select.reserved_order`). Implicit remote
  counterparts have no rows; `P` on one records an explicit unpin of just that
  ref. `L` opens a `float_zindex` float rendered
  by the pure `select.pin_dialog_lines` (lines + a line → entry-index row map);
  its buffer-local keys `<C-j>`/`<C-k>`/`<Space>`/`D`/`<CR>`/`q` each write
  `view_state.pins`, reflow, and restore the graph cursor by hash like `P`.
  `<CR>` and "Pin new branch…" reuse the `<leader>b` picker pieces extracted as
  `ctx:ref_picker_format` / `ctx:jump_to_ref`. **The layout does not honour the
  reserve flag yet** — the follow-up plugs it into `columns.lua`'s `grid_taken`
  (see ARCHITECTURE) — and the dialog's last line says so, since a control whose
  effect is unbuilt must not look like it works.
  **NB:** these helpers are `GRAPH_HELPERS` fields rather than module locals
  because window.lua is at LuaJIT's **200-local chunk limit** (a second ceiling
  beyond the 60-upvalue one); new window helpers must go into the tables.
- **Marker packing** (`opts.pack_markers`, default on; spec §10.4, toggled by
  `p`): a **marker** is a messageless node (today a collapsed head — `◍` + ref
  labels + count, no subject). `pack_markers` is a post-Phase-1 pass run in
  `reflow` after layout: it merges adjacent overlay-compatible marker rows into
  one **marker-group** OrderItem (`type == "markers"`, holding the marker
  DisplayNodes + merged columns) — multiple `◍` on one line, the one exception to
  "one commit per line" (§5.1). Overlay-compatible = each column has ≤1 node and
  ≤1 lane id and no horizontal overlap; compaction makes only safe merges
  compatible. On a packed line `h`/`l` selects a marker (`marker_units`); the
  listview stays 1-item-per-line (a group is one item). The marker labels render
  via `line_right` with `line_right_align = "left"` (left-aligned after the graph)
  so they get the windowed `+N` overflow (§6) around the selected marker instead of
  truncating the row with `…`. Selecting a marker drives the §12 reachability
  cone (not a flat `palette.selected` repaint): `update_cone` seeds it from the
  selected head via `mark_node_cone` (walking the DisplayNode `.parents`/
  `.children` and lighting each lane via its shared edge object by `node_loc`, like
  `mark_path`), so the selected branch (its `◍` node, label, and lane) stays its
  normal colour and the sibling heads/branches on the row dim — exactly like
  moving onto a normal head (§12). `h`/`l` calls `update_cone` before the redraw so
  the dimming follows the selection; no selection ⇒ the line is neutral (all lit).
- **Collapse interaction** (spec §10.4): acts on the *region under the cursor*,
  not a ref — `branch_under_cursor(line)` resolves the selection (ref/marker) or
  the commit's signature (`collapse_owners`) into `{state, owners, follow,
  commit}`. `<Tab>` is the 2-state collapse⇄expand toggle (`set_branch` flips the
  owners, reflows, then `goto_hash` repositions the cursor on the result so it is
  repeatable). `<CR>` is **examine, never a menu** (`h_cr`): the commit view of
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
- **HEAD is always an anchor, labelled first** (spec §6/§10.6): the `head` Ref
  carries `branch` (nil when detached). `owners_from_refs` makes a DETACHED HEAD
  an owner with id `HEAD` (re-bound, not renamed, by resync — so pins and mode
  overrides on it follow the checkout); `effective_pins` defaults it in and drops
  a `HEAD` entry while attached. `git.group_refs` moves the current branch's group
  to the front (`current = true`), so `decoration_texts` / `display_item` /
  `pane_labels` draw `(HEAD → x …)` first and `selected_ref` / `selected_owner_ids`
  / `ref_byte_col` agree on index 1 without any change of their own.
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
  first, stdout when stderr is empty) + resync for a pull only).
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
  in), `columns` (Phase 1 lane layout), `render` (Phase 2 glyphs/colour/dimming +
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
  (`lane_of`, the main-view colour; the pivot continuation keeps the pivot's colour,
  an extra fork child takes its own) and unpinned heads packed onto as few rows as
  possible (`pack_heads`/`overlay_rows` — pinned anchors and junctions keep their own
  line); `cap`; §6.2). **Both panes are wired** via
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
  the projected nodes; `lane_main[hash]` from each item's `parent_lanes[1]` gives
  `lane_of` the main-view colour so the header matches the graph) and lays it out
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
- **`graph._internal`** exists solely for tests (pure parsers + the
  `build_graph`/`get_column_chars` seam). Do not route production code through it.
- **Vendored duplication is intentional** — `compose` lives in both graph.lua
  and listview.lua, and `make_future` is gitloom's own minimal promise. See
  "Relationship to loomworks" before deduplicating.
- **setup() config is wired** to `:GitloomGraph`: `init.lua`'s command callback
  forwards `M.config` (the stored `setup()` opts) to `window.open`, which merges
  it over the built-in defaults (read at invocation time). The per-pane
  `header_max`/`footer_max` caps remain hardcoded (specification.md §6/§8).
- **Ref label modes** (`opts.label_mode`, cycled by `B`; spec §6.1) are a
  placement choice in `display_item`: `right` puts refs in `line_right`
  (right-pinned, default), `inline` composes them into the flex column before the
  message, `dual` draws a labelled commit on **two real buffer lines** — row 1 is
  the graph (node) + labels, row 2 is the message with the graph continued
  downward via `passthrough_columns(item.columns, "down")` (no node). A `dual`
  commit with no labels stays one line. `dual_two_line(opts, commit)` is the
  single predicate shared by the listview's `line_count` (buffer allocation) and
  `display_item` (rendered rows) so they never disagree.
- **Multi-real-line items**: `repo.order` stays 1:1 with commits; the listview
  maps a *buffer line* to its order index via a prefix-sum offset
  (`rebuild_starts`/`item_index_at`, exposed as `controller.item_at`/`item_start`).
  graph.lua's `order_at(line)` is the only boundary translation (used by the
  keymaps, cursor parking, and the cone viewport, which converts `w0`/`w$` to
  order indices). `DisplayElement.lines` (a list of real rows) generalises `line`;
  `above`/`below` are stacked virtual rows attached to the first/last real line.
  `B` calls `controller.relayout()` (resize the buffer + rebuild the map) because
  it changes per-item line counts; `m`/`M`/`d`/`H`/`i` stay on `refresh()`.
  This is the deferred "real branch line" alternative, now built; the cursor sits
  physically on the labels, and `CursorMoved` pre-selects the first label when it
  lands on a labelled commit's first row.
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
- **Commit selection (range)** (specification.md §13; toggled by `V`): a modal
  selection that is a **path along one branch** over the visible projection
  (`repo.display`), not a contiguous row block. State lives in `sel` (in `M.open`):
  `path` (DisplayNodes newest-first), `anchor`/`cursor` (the two ends — always
  endpoints, so the path is exactly `anchor..cursor`), and `dparent`/`dchild` (the
  branch chosen at each junction for `h`/`l`). The walk is pure
  (`sel_step`/`sel_switch`/`sel_ascend_children`) over the DisplayNode graph
  (`.parents` first = trunk, `.children`); the window glue resolves rows
  (`goto_hash`), lane/marker emphasis (`mark_path`, reusing the §12 dimming via
  `view_state.cone`), the cursor-on-lane parking, and the range (`selection_range`
  → `range_endpoints` → the **literal** `<older>^..<newer>` `DiffRange` — or, when
  the newer end is a §4.2 working-tree node, a **single-rev** `DiffRange` to a
  tree state, see below). `j`/`k`
  and `<C-d>`/`<C-u>` are bound to walk while active and **fall through to the
  builtin motions** (fed without remap) when inactive; `h`/`l` switch branch while
  active (else the §2 ref selection). `<CR>` opens the **range commit view**
  (§13.5): `open_commit_view(opts, nil, { range, commits, title })` — the same
  view generalised with a `range` arg, listing the selected commits
  (`selection_commits` → `format_range_detail`) and rendering the combined range
  diff (`fetch_range_diff`, shaped from the endpoints — `git diff <base> <to>`,
  `git diff <base>`, or `git diff --cached <base>`) through the existing
  diffstat/diff/context-header pipeline; its action label and `D` open the range
  in the external provider. A `reflow()` recreates DisplayNodes, so it drops any live selection
  (stale references). Navigation walks the DisplayNode edges directly, so it
  passes *through* collapsed heads (including packed ones); a `node_loc` index
  (hash → {item, col}, built with `display_index`) lets `mark_path` light a head's
  lane (the Lane object is shared with the child's row via `seg.edges`) and marker
  even when packed, and `display_item` draws the selected head with
  `palette.selected` and dims the other heads on the shared line (§13.4).
  `selection_toggle` (`<Tab>` while selecting) folds/unfolds the cursor's head in
  place: it captures the path **by member hash** (a head expands to its whole
  region so the unfolded branch stays selected/lit — the diff range is unchanged),
  applies the mode + reflow, re-resolves against a fresh hash→node map (region
  members → their head, dedup consecutive), keeps the anchor on its end and the
  cursor on the toggled end, and restores the saved scroll (`winsaveview`/
  `winrestview` topline) so the view holds.
  Selection isn't started *on* a packed-marker line. The pure helpers are tested;
  the window glue is not (like the other window glue).
- **A selection may end at the working tree** (spec §4.2/§13.2/§13.5): the three
  §4.2 virtual nodes are selectable endpoints, as the **newer** end only. That is
  structural, not a rule — they have no children, so ascending into one ends there
  and it can only ever be the path's newest member; `sel_ascend_children` and
  `enter_selection` therefore carry **no** virtual special case at all (both
  guards added 2026-09-08 were reworked away, not merely deleted). The invariant
  they existed for — *a sentinel hash must never reach a git rev* — is enforced in
  exactly two places instead: `range_endpoints` maps a virtual newer end to a
  **tree state** (`to = "index"|"worktree"`) and emits a **single** rev
  (`--cached <base>` / `<base>`), never an `<a>..<b>` span; and `fetch_range_diff`
  builds its argv from the endpoints' *shape*, asking only a **table** endpoint
  for its `.hash`. Single-rev is the whole point: verified against diffview's own
  `GitAdapter:parse_revs`, a lone rev resolves the right side to `RevType.LOCAL`
  — the real file on disk, so LSP attaches — while `<a>..<b>` gives `COMMIT` blobs
  and `--cached` gives `STAGE` (the index has no on-disk path either; inherent,
  not a defect). The base stays the older end's first parent, run through the same
  tree-state map when *that* parent is virtual (a worktree-only selection), so the
  degenerate `untracked..unstaged` span is `from = "index"`, `rev = ""` — the
  provider's own working-tree-vs-index default. The **untracked** endpoint carries
  `untracked = true` and gets the §3.3 synthesized additions appended to the
  *in-graph* patch only (`git diff <base>` never lists untracked files; without
  them the untracked endpoint would render byte-identically to the unstaged one,
  making the selection invisible) — the external provider needs nothing, since a
  working-tree view lists untracked files itself. `selection_range` /
  `real_newest` / `selection_commits` are unchanged: they still hand over the
  virtual `Commit` and let the range builder decide what it denotes.
  `format_range_detail` synthesizes its row (`working` in the id cell, never the
  sentinel; `worktree_label`'s text).
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
- **Neovim >= 0.10** — relies on the 4-arg `vim.str_byteindex` and the
  decoration-provider API.
