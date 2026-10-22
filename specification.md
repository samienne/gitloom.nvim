# gitloom.nvim — Specification

This is the behavioral contract: *what* gitloom does, independent of *how*
it is implemented. Implementation details live in
[ARCHITECTURE.md](ARCHITECTURE.md).

This document is authoritative. When behavior changes, update this file
first (see [CLAUDE.md](CLAUDE.md) → Spec-First Development).

## 1. Purpose and scope

gitloom's primary goal is to be an excellent **git graph viewer**. The graph
is the product. Other git functionality is deliberately out of scope, except
where it falls naturally *out of* the graph (e.g. acting on the commit under
the cursor) or is delegated to an existing plugin (e.g. opening a diff in
diffview).

### 1.1 Own the model

gitloom does **not** wrap `git log --graph`. It reads commit and ref data
from git and builds the commit DAG, the row ordering, and the lane layout
itself, in memory. Owning the model is a hard requirement, not an
implementation detail: the planned view features — collapsing, pinning,
toggling branch visibility, and reflowing (§10) — are only possible if
gitloom controls ordering and layout rather than delegating them to git.

gitloom never stages, commits or rewrites history by itself. The exceptions to
an otherwise read-only view are actions the user explicitly picks: **checkout**
(§10.4.1), which only moves HEAD and the working tree; **checkout & examine**
(§10.4.2), which may also **stash** the uncommitted changes (after asking) and
re-apply them on Return; **fetch** / **pull** from the command palette (§17);
the palette's **branch sync** (§17.2): **fast-forward** a branch to its upstream,
or **reset** it to its upstream; and the palette's **set / unset upstream**
(§17.2), which only rewrites a branch's tracking configuration
(`branch.<b>.remote` / `merge`) — no ref, commit or file. Reset is the one action gitloom offers that can
**discard work** (local commits, uncommitted changes to tracked files), so it
always asks first and says what would be lost.
The view-transformation features in §10 are the direction this is built
toward; the current non-graph surface (window, streaming fetch, rendering)
exists primarily to exercise and validate the graph algorithm.

## 2. Entry point

- `:GitloomGraph` opens the graph for a **repository root**. With no argument
  it targets the repository at Neovim's current working directory (the
  default). It accepts an optional repository path so the graph can be opened
  on a **specific repository** — a submodule of the cwd repo, or the main
  module (§2.1).
- The window is a floating window — the per-repository **host window** (§14).
  `q` **hides** it (its navigation stack and view state are retained; `<C-w>q`
  destroys it, and `<C-o>` / `<C-i>` walk its navigation history — §14.1, §14.3);
  `m` cycles the merge/split rendering style (§5.2) so the styles can be compared
  at a glance; `C` cycles the **layout policy** (§5.6) so the lane-placement
  algorithms can be compared the same way; `M` toggles
  graph mirroring (§5.4); `B` cycles the **ref label mode** (§6.1) so the ref
  placements can be compared at a glance. `<Space>` is the quick **collapse ⇄
  expand toggle** for the row under the cursor (§10.4): it collapses the row's
  own branch(es) or expands a marker, in place, and the cursor follows so
  repeated `<Space>` flips it open/closed. (`<Tab>` is `<C-i>`, the navigation
  *forward* key — §14.3.) `<CR>` **examines**: it opens the **commit view**
  (§11) of the row's commit directly — never a menu (a collapsed head or a
  packed marker stands for its tip; §11). Every other action on the row — collapse
  / expand / hide the branch, open diff, **checkout** (§10.4.1), **checkout &
  examine** (§10.4.2) — is in the `<C-Space>` **command palette** (§17), listed
  ahead of its global commands.
  `D` opens that commit's diff in an external diff viewer via the configured
  provider (§11.5; a no-op on a collapsed head). Two debug
  aids: `K` opens a float with the full lane breakdown for the commit under
  the cursor, and `i` toggles the per-lane id column before the message (a
debug aid, hidden by default). `d` toggles the date column between absolute and
relative (§6). `H` toggles reachability highlighting (§12) off and on. `c`
toggles the first-parent focus (§10.7) — collapse every non-mainline branch, or
show the full graph. `p` toggles **marker packing** (§10.4) — merge concurrent
collapsed heads onto shared lines, or one per line. `R` **resyncs** the view with
the repository (§3.4) — re-reads refs, pulls newly-reachable commits, prunes
unreachable ones, re-sorts, and rebuilds the working-tree virtual commits (§4.2),
preserving cursor/scroll/selection. `<C-Space>` (also `<C-@>`, which many
terminals send for it) opens the **command palette** (§17) — a picker of the
graph's actions scoped to what the cursor is on: first the context's (a commit's
open diff / checkout / checkout & examine, a branch's checkout / collapse / expand
/ hide, a selected packed marker's, or, while a `V` selection is active, the
selection's; §10.4) — then the graph-wide commands: fetch (all remotes, or one),
pull, and **Return** while a checkout & examine (§10.4.2) is active — then the
graph's **keys** that apply there (§17.1), each with its key shown. `S` cycles the **row sort mode** (§3.1) —
gitloom's own topological order (reproducing git's `--topo-order`), or git's date
/ author-date order — reordering in place and keeping the cursor on its commit.
`L` opens the **pinned-branches dialog** (§10.6.1) — the pinned branches in
priority order, where they are reordered, given a dedicated lane, unpinned, or
added to. `V` enters **commit selection** (§13) — a modal range
selection along one branch, fed to the diff provider and the commit view's range
mode. `<leader>gl` opens a **commit search** (§15) — a fuzzy picker over commit
subjects and authors that jumps the cursor to the chosen commit. `/` enters the
**filter search** (§16) — a live, isolated overlay that contracts the graph to
matching commits (kept as normal commits, the rest collapsed); `<C-j>`/`<C-k>`
step the matches, `<CR>` jumps to one and dismisses, and `<C-s>` stamps it as a
persistent view.
  `<leader>b` opens a **ref picker** (snacks.picker) listing every branch,
  remote-tracking branch, and tag, plus **HEAD**; selecting one moves the cursor
  to that ref's commit and **centers** the view on it (like the initial HEAD
  focus below). Refs **recently jumped to in this session** are surfaced at the
  top of the list (per-repository, in-memory for the Neovim session — the same
  scope as the remembered cursor position). The jump resolves the ref's commit to
  its visible row, so a collapsed branch lands on its collapsed head (§10.3); a
  ref whose commit is currently hidden (§10.1) is a no-op with a notice. Landing
  also **pre-selects that ref's label** on the row (as if `h`/`l` had moved onto
  it; §6), so `<CR>` / the palette's row actions act on that branch with no further
  navigation. Picking HEAD — whose label is its branch's, or the unselectable detached `HEAD` — just centers, cursor at the
  message.
  `%` **cycles a branch between its local and remote counterparts**. The source
  is the ref selected with `h`/`l`, else the row's first branch label (HEAD's
  branch first on the HEAD row; on a packed-marker line, the selected — else the
  first — marker's). For the branch's short name `x` the cycle is the local `x`,
  then `<remote>/x` for each remote in `git remote` order (any other remote
  holding an `x` after them, by name), then back to `x` — matched by **name**,
  never by upstream configuration, and only refs that exist; a remote-only branch
  cycles among its remotes. A member whose commit cannot be jumped to — not in
  the current projection (a `hidden` branch, §10; filtered out, §16) — is
  **stepped past**, decided up front so the cycle never sticks on it; when no
  other member is visible, `%` stays put with one notice `no other visible ref
  for x`. Each step is a `<leader>b` jump to the next member
  (same row resolution, collapsed-region landing, label pre-selection and
  `<C-o>`/`<C-i>` history). Members on the **same commit are not skipped**: since
  a local branch and its same-named remotes on one commit share one label
  (`dev ↑origin`, §6.3) and one selection, gitloom remembers which member `%` last
  landed on for as long as that selection stands (any `h`/`l`, row move or reflow
  ends it), so repeated `%` steps through the grouped members; whenever the
  cursor stays on its row a short notice names the ref now current with its
  position (`origin/dev (2/3)`). A row with no branch label (tag-, worktree- or
  detached-HEAD-only, or ref-less), or a selected tag / worktree, does nothing
  but say so; a branch with no counterpart anywhere notices `no other ref for x`.
  `?` opens a float listing **every** graph key, grouped, generated from the same
  **key registry** the palette reads (§17.1), so it cannot drift from what is
  bound; every graph key is also bound with a `desc` (`Gitloom: …`), so
  `:map` and which-key-style plugins name it. The window **title** identifies the
  repository the graph is for (§2.1): its name, plus the current branch once HEAD
  is known — or `detached @<short>` (HEAD's 7-character hash) on a detached HEAD,
  so the title always says what is checked out (a caller-supplied `win.title` is left untouched). The graph's buffer
  is additionally **named** after the repository root (`<root path> (gitloom)`), so
  an external GUI window title — e.g. Neovide's OS titlebar, which Neovim derives
  from the active buffer — identifies the repo by path instead of showing an
  unnamed scratch buffer. A commit view's buffer (§11) is named the same way,
  `<root path> (gitloom) <view title>`, the view title keeping buffer names
  unique. The footer shows
  live status (the active merge mode and ref label mode, a `N collapsed, M hidden`
  summary when any branch modes are set, and `(mirrored)` when mirroring is on).
- **Navigation.** Navigation is line-by-line (`j`/`k`, arrows, etc. move whole
  rows), with `cursorline` marking the current row (§7). The cursor is parked at
  the **commit message** rather than left at column 0. `h`/`l` move a selection
  across the current row's ref decorations — the branch groups then tags (§6);
  the selected decoration is highlighted (`palette.selected`) **and the cursor
  moves onto it**. The message is the default position (the cursor parks there);
  since refs are pinned to the right edge, `l` moves **right** onto the refs
  (starting at the first) and `h` moves **left** back toward the message.
  Selection clamps at the last ref and resets to the message when the cursor
  moves to another row. In the **dual** label mode (§6.1) the refs sit on the
  commit's first row (with the node) and the message on its second row, both real
  lines the cursor occupies normally: landing on a labelled commit's first row
  **pre-selects the first** ref (so `h`/`l` refine an already-active selection),
  and the cursor sits physically on the selected ref. This selection scopes the
  per-ref actions — the palette's checkout, branch sync and hide, and `P` (§10,
  §17); it does not narrow `<Space>`, which acts on the row's own owners (§10.4). The
  row under the cursor also defines a **pivot** whose reachable history
  (ancestors and descendants) is emphasised while everything else dims (§12).
- The view opens immediately and is populated asynchronously as git output
  arrives; the window must not block on git completing.
- **Initial focus and position retention.** When the graph finishes loading it
  moves the cursor to **HEAD** (the current branch's commit, or the checked-out
  commit itself on a detached HEAD, §3.2) — HEAD's own row, never the §4.2
  working-tree row always drawn above it — and **centers** the view on that row
  when possible — clamped at the top/bottom of the graph (like `zz`). HEAD is
  always an anchor (§10.6), so attached and detached focus alike; only a
  repository with no HEAD commit (empty) leaves the cursor at the top. The cursor's row is then **remembered per
  repository** (keyed by repository root, §2.1) for the duration of the
  Neovim session: closing and reopening the graph restores the cursor to the same
  commit (re-centered) instead of re-focusing HEAD. The remembered target is the
  **commit under the cursor by hash**, so it survives reflow (§10.5) and resolves
  to the commit's collapsed head (§10.3) when its branch is folded; if that commit
  is no longer present, focus falls back to HEAD.

### 2.1 Repository selection

The graph is bound to a **repository root** — an absolute path resolved once
when the graph opens (from the given path, or Neovim's cwd, via git's
top-level). All of gitloom's git queries run against that root, so the graph
need not be the repository at the editor's cwd.

- A **picker** entry point lists the **main module** (the cwd repo's top
  level) and its **direct submodules**; choosing one opens the graph for that
  repository. Nested submodules are out of scope for the first cut (cf.
  §11.7.5). A submodule that is **not initialized / checked out** is shown but
  disabled — there is no local repository to open. Like the graph itself, the
  picker **opens immediately** with the entries whose paths are known up front
  and **fills each entry's branch / commit summary asynchronously** as git
  resolves it, so a slow or large submodule never blocks the list. `setup()`
  binds the picker to **`<leader>wG`** by default (a normal-mode mapping;
  configurable via the `pick_key` option, `false` to disable).
- gitloom retains view state — the remembered cursor position (§2) and the
  ref-picker session MRU (§2 `<leader>b`) — **per repository** for the Neovim
  session, keyed by repository root. Reopening a repository restores where you
  were in it.
- **Each repository has one host window; opening a repository shows that window
  rather than stacking a new one** (§14.1). `<leader>wG` opens the picker to
  switch to another (sub)repository (creating its window on first entry); `q`
  hides the current window and `<leader>wg` returns to it (the most-recently-open
  stack), restoring where you were, keyed by the per-repository remembered
  position (above). The **active repository follows the visible host window**, so
  git queries always target the repository whose window is shown. (This
  supersedes the earlier model in which each open stacked an independent floating
  window — §14.)
- A repository may be opened **focused on a specific commit** rather than HEAD —
  used by the commit-view submodule link (§11.7.6), which opens a submodule's
  repository on the commit under the cursor as a navigation-stack entry with the
  update's commits pinned (§14.7).

## 3. Data source

Two independent queries, joined by commit hash.

### 3.1 Commits

Commits are read via `git log` with:

- `--topo-order` — git's topological order: a valid topological base (children
  before parents) for progressive painting, the verbatim order of the `git` sort
  mode, and the input the `gitloom` sort mode re-clusters on top of.
- `--parents` — full parent hash list per commit.
- a refspec, default `--all`.

Each commit carries: hash, parent hashes, author, author date, subject. The
author date is read as a Unix epoch (`%at`) plus its tz offset (from `%ai`) and
parsed into a structured `Timestamp` (§4), not kept as text. Refs are **not**
taken from `--decorate`; they come from §3.2.

**Row ordering — sort modes.** gitloom **owns the row-order pipeline** (§1.1): it
records the commit set, decides *when* to (re)order, and reflows — but a given
**sort mode** sources its *sequence* either from git or from its own algorithm.
`S` cycles the mode; the active mode determines `repo.order`. All modes keep the
hard invariant that a parent is never at an earlier row than a child (the layout
and reachability invariant of §5/§12). The modes:

- **`topo`** (default) — gitloom's own **topological sort**, computed in Lua to
  **reproduce git's `--topo-order`**: a depth-first walk over a LIFO stack
  (mirroring git's `sort_in_topological_order`) that groups history by lineage —
  it descends a commit's parents the instant they become ready, so a merge's
  merged-in lineage is emitted right after the merge instead of scattered by date,
  which is what keeps the graph's lanes tight. The independent tips seed the stack
  **newest committer-date first** (`%ct`, git's own ordering; hash breaks ties);
  once a lineage starts it is followed by topology, not recency. This matches
  `git rev-list --topo-order` commit-for-commit (verified against a real and a
  synthetic repo during development), so gitloom owns this order outright rather
  than delegating to git.
- **`date`** / **`author`** — git's `--date-order` / `--author-date-order`
  (`git rev-list`): topological, otherwise newest-first by committer / author
  date, so branches interleave by date.

The `topo` mode computes its sequence in Lua; the `date` / `author` modes obtain
theirs from `git rev-list <flag>`. Cycling re-orders `repo.order` **in place** (no
re-stream) and reflows, keeping the cursor on its commit. The default mode is
configurable (`sort_mode`, §8).

**Streaming.** While commits stream in they are appended in git's `--topo-order`
arrival order so the view paints progressively. When the stream completes the
active sort mode is applied once to produce the authoritative `repo.order`, after
which the §10 projection / reflow proceeds.

Two properties make "progressively" mean what it says, and both are obligations
on the implementation rather than free consequences of batching:

- **The loop must go idle between batches.** A batch is laid out and inserted,
  and then control returns to the event loop far enough that Neovim redraws and
  a keypress is seen, before the next batch starts. Handing off in a way that
  merely re-enters the same drain (a self-rescheduling callback on the event
  queue) satisfies neither: the queue never empties, so nothing reaches the
  screen until the last commit has been processed.
- **A batch costs its own rows, not the whole history.** The lane layout
  (§5) of a streamed batch **continues** the sweep that laid out the rows above
  it; it does not re-lay the accumulated order. This is exact rather than an
  approximation: the sweep is a strict top-down fold whose per-row output depends
  only on the state after the previous row, and `--topo-order` emits a parent
  only after every one of its children, so a row's parents and children are final
  the moment it is appended and nothing below it can change it. Laying out a
  prefix therefore yields exactly the first rows of laying out the whole list.
  A lane-placement policy that reads *ahead* of the current row (§5.6 `gutter`,
  whose parent-swap gate needs the next subject row) is the stated exception and
  is re-laid in full.

### 3.2 Refs

Refs are read via `git for-each-ref` over `refs/heads`, `refs/remotes`, and
`refs/tags`, yielding for each ref its refname, target hash, and — for
annotated tags — the dereferenced commit hash. The current branch is read via
`git symbolic-ref` (HEAD). Each ref is resolved to the `Commit` it points at
by hash (§4.1).

Using a dedicated, structured query rather than parsing `git log --decorate`
makes ref discovery robust and makes remote branches and annotated tags
first-class (the decorate field conflated them and dropped remotes).

**Linked worktrees.** A third query, `git worktree list --porcelain`, reads the
repository's **linked worktrees** — their path, checked-out `HEAD`, and whether
that HEAD is on a branch or **detached**. This is not a convenience: the commit
refspec (§3.1, `--all`) walks **every worktree's HEAD**, so without it the model
would hold real commits that no ref covers. A detached worktree HEAD is
genuinely alive — a worktree HEAD is a **gc root**, so those commits are exactly
as permanent as any branch tip, and they are usually work in progress the user
has deliberately checked out. They are given a ref (kind `worktree`, §4.1) so
they are attributed like any other branch (§10.2) and survive the resync prune
(§3.4).

Two rules keep the labels from being noise:

- **Skip the main worktree's HEAD** — it is already the `head` ref (§4.1).
- **Skip a worktree whose HEAD commit any other ref already points at.** This
  covers the common case (a worktree checked out on a branch — the branch ref
  already labels that commit) and the incidental one (a detached HEAD parked
  exactly on a branch tip or tag). Only a worktree HEAD that *nothing else names*
  gets a label.

A worktree's own `git log --all` may of course see commits this repository's
worktrees do not; that is the general case §10.2's total owner coverage handles.

### 3.3 Working-tree state

gitloom always shows the **working tree** as a row directly on top of HEAD — the
live state the user is building, and the place a selection or an examine can
start from to land on the real files (§10.4.2, §13.5). When the tree is dirty the
uncommitted changes appear as up to three **virtual commits** (§4.2) stacked on
top of HEAD; when it is **clean** a single **clean** virtual commit stands there
instead, so the row never disappears and HEAD always has the working tree drawn
above it. gitloom **displays** the index and working tree; it never stages,
unstages, or commits by itself (§9). The operations that change them are the
ones the user explicitly picks: **checkout** (§10.4.1), which only moves HEAD and
the working tree; **checkout & examine** (§10.4.2), which on a dirty tree stashes
the changes (`git stash push -u`, after a prompt) and re-applies them on Return;
and **pull** from the command palette (§17), which only fast-forwards the current
branch to its upstream (it never creates a commit). The stash is git's own and
the only one gitloom creates; it never stages or commits.

The state is read with porcelain queries that run **after** the commit stream
(§3.1) has its HEAD anchor:

- the **staged** node — the index versus HEAD — from `git diff --cached`;
- the **unstaged** node — the **tracked** working tree versus the index — from
  `git diff`;
- the **untracked** node — the **untracked** files
  (`git ls-files --others --exclude-standard`, respecting `.gitignore`), each
  rendered as a whole-file addition (via `git diff --no-index` against the empty
  device) so untracked content appears as added lines.

A node is materialised **only when it has content**: a clean index produces no
staged node, no tracked working-tree changes produce no unstaged node, and no
untracked files produce no untracked node, so the count of change nodes is 0,
1, 2, or 3. The untracked files are their own node — separate from the tracked
unstaged changes — stacked newest-first as untracked → unstaged → staged → HEAD.
When the count is **0** (all three queries came back empty: the tree is clean)
the **clean** node is materialised in their place, so the working-tree stack
always has 1, 2 or 3 nodes. The clean node is never shown together with a change
node. Dirtiness is decided by the same `git status --porcelain` read that already
counts the three kinds (§3.4), spawned like every git call through
`fetch.lua`'s `spawn`; a clean tree costs that one read and no diff.

The reads are gated by the `working_tree` option (§8, default `true`) and are
skipped entirely when it is off or when HEAD is unborn (no commits yet — there is
no HEAD to stand on, so no clean node either). With `working_tree = "dirty"` the
clean node is not materialised (the stack may be empty, as before this row was
always shown). They never block
the graph: the main view streams and renders first; the virtual commits are added
when their queries resolve.

### 3.4 Liveness and refresh

The graph re-reads the repository as it changes underneath. Two refresh concerns
are distinguished, and they are independent:

- **Working-tree refresh** — re-reading only the dirty state (§3.3) when the
  index or working tree changes (the user edits, stages, or unstages). The set of
  real commits is unchanged. This **is** supported: a debounced refresh re-runs
  the §3.3 queries and rebuilds the virtual commits on the current HEAD anchor.
  It is triggered on buffer writes, on focus regained, after a `:!` shell
  command (`ShellCmdPost`) and on leaving a terminal's insert mode (`TermLeave`)
  — the last two catch `git add` / `git stash` / edits made from inside Neovim
  without a write, which would otherwise leave the always-visible row (a clean
  label especially) stale. It first re-reads
  HEAD's hash so it can detect when history has moved out from under it. A
  refresh that turns a clean tree dirty (or back) **replaces** the clean node by
  the change nodes (or the reverse); a cursor that was on any working-tree node
  stays on the **topmost** working-tree node, since the sentinel hash it was
  remembered by may no longer exist (§4.2).
- **History refresh** — re-reading the commit DAG and refs because real history
  changed (`commit`, `fetch`, `rebase`, a `checkout` that moves HEAD). This is
  **supported** in place via *resync* (the `R` key, §2): gitloom re-reads the
  refs (§3.2), diffs them against the model to find added / removed / moved tips,
  fetches only the newly-reachable commits (`git rev-list --parents --stdin`, fed
  the new tips plus `^<previous tip>` per previous tip — the revision list scales
  with the repository's ref count, so it goes on **stdin** rather than the command
  line, which has a hard OS-level size cap) and links them into the
  identity-stable model (§4) by
  hash, re-points moved ref bindings, prunes commits no longer reachable from any
  ref (history rewrites / force-pushes), re-runs the owned sort (§3.1), and
  `reflow()`s — preserving hash-keyed view state (selection, folds, cursor,
  scroll) across the rebuild. The working-tree refresh is folded in (resync ends
  by rebuilding the virtual commits on the new HEAD anchor). A full teardown
  re-stream remains available by reopening the view.

The working-tree refresh was the first case of this general refresh, so the
history refresh extends it rather than replacing it: both re-resolve HEAD,
reconcile against the identity-stable model (§4), and end in `reflow()`.

**The prune and the open path must agree.** The orphan prune keeps only what is
reachable from a ref, so anything the open path renders that no ref reaches would
be silently deleted by the first `R`. The `worktree` refs of §3.2 are re-read and
reconciled on every resync exactly like branch tips, which is what keeps a linked
worktree's checked-out work — reachable from `--all` and from nothing else — from
disappearing on refresh.

## 4. Data model

```
Commit    = { hash, parents: Commit[], children: Commit[], refs: Ref[],
              author, date: Timestamp, message }
Ref       = { name, kind, commit: Commit }
Timestamp = { epoch, offset, raw }
```

- `Commit.date` is a parsed `Timestamp`, not a string: `epoch` is the author
  date as Unix time (UTC), `offset` is the author's tz offset in seconds (so
  the author's local wall-clock is `epoch + offset`), and `raw` keeps the
  original `%ai` text. Formatting happens at render time (§6).
- `Ref.kind` is one of `local`, `remote`, `tag`, `head`, `worktree`.
- `Ref.commit` is the `Commit` the ref points at — a **direct reference, not a
  hash**. `Commit.refs` lists the refs pointing at it (the inverse). A
  name → `Ref` registry is kept on the repository.
- Commits are identity-stable: a commit referenced as a parent (or by a ref)
  before it is seen in the log is the *same* object once its own log line
  arrives.
- Every hash reference resolves to a `Commit`: parent hashes and ref targets
  become `Commit` references once resolved. A target not in the fetched range
  still exists as a (sparse) `Commit` placeholder so the graph and refs stay
  connected, filled in when (if) its log line arrives.
- Child links are the inverse of parent links.

### 4.1 Ref resolution

Each ref is classified by its refname and resolved to its target commit:

| refname                          | kind     | name shown            |
|----------------------------------|----------|-----------------------|
| `refs/heads/<name>`              | `local`  | `<name>`              |
| `refs/remotes/<remote>/<name>`   | `remote` | `<remote>/<name>`     |
| `refs/tags/<name>`               | `tag`    | `<name>` (annotated tags resolved to their commit via the dereferenced hash) |
| HEAD (symbolic)                  | `head`   | marks the current branch's commit (drawn as that branch's label, `(HEAD → <name>)` in the HEAD colour, §6) and records which branch it is on; a detached HEAD marks the checked-out commit directly (a bare `HEAD` label) and is an owner of its own (§10.6) |
| a linked worktree's HEAD (§3.2)  | `worktree` | `wt:<dir>` — `<dir>` is the worktree directory's **basename** |

`refs/remotes/<remote>/HEAD` (the remote's default-branch symref) is skipped.
The target hash is looked up in the commit table; a missing target yields a
sparse `Commit` placeholder (as above).

A `worktree` ref is the one kind with **no refname**: it comes from
`git worktree list --porcelain`, not from `for-each-ref`, so it is *constructed*
rather than classified. Its name is prefixed `wt:` — a `:` cannot appear in a git
refname, so a worktree label can never be confused with, or collide in the
name → `Ref` registry with, a real branch or tag. Beyond the name it is an
ordinary ref: it is an owner (§10.2), it is pinnable (§10.6), it appears in the
ref picker (§2) and the context panes (§6.2), and the resync reconciles it like
any other tip (§3.4).

### 4.2 Virtual commits (working tree)

The working-tree state (§3.3) enters the model as **virtual commits** — synthetic
`Commit` nodes that are not part of the real DAG:

```
Commit.virtual = "staged" | "unstaged" | "untracked" | "clean" | nil   -- nil for a real commit
```

The **clean** node stands for a working tree with no changes (§3.3). It is a
virtual commit like the other three in every rule below — sentinel hash, one
parent (always the HEAD commit, since it is never stacked with a change node), no
children, no refs, placed directly above HEAD — and it carries no diff: its
content is by definition HEAD's.

A virtual commit:

- carries a reserved **sentinel hash** (a value git never produces for a real
  object), so every hash-keyed path (the commit table, cursor memory, navigation)
  keeps working unchanged. The staged, unstaged, untracked and clean nodes use
  distinct sentinels;
- has **one parent** and **no children**, so it is a tip (§5.3). Each node's
  parent is the next existing node down the stack: the untracked node's parent is
  the unstaged node, else the staged node, else the HEAD commit; the unstaged
  node's parent is the staged node when one exists, otherwise the HEAD commit; the
  staged node's parent is the HEAD commit. So the stack reads, newest first,
  untracked → unstaged → staged → HEAD;
- carries **no refs** and is **placed directly above** the HEAD commit in the row
  order;
- carries **no `author`/`date`/`message` from the model** — its detail is read on
  demand in the commit view (§11.8), not from the graph stream;
- **is** a selectable commit-selection endpoint (§13.2), but only ever the
  **newer** one — having no children, it can never be the older end of a path.
  Because its hash is a sentinel rather than a git object, a range ending at it
  names a **tree state** (`"index"` / `"worktree"`) instead of a commit, so the
  sentinel never reaches a git rev (§13.5).

Because a virtual commit sits *above* HEAD, no owner's first-parent reach (§10.2,
which descends toward ancestors) touches it: its reachability signature is
**empty**, so by the §10.2 join it is always **normal** and, having no owner, is
**never collapsible or hideable**. This is exactly the desired "the live state is
always shown" behaviour, and it falls out of the existing view model with no new
owner kind.

Virtual commits are **not** real commits for commit search (§15) or the filter
search (§16): neither matches, lists nor previews them.

**Layout identity follows HEAD.** The empty signature governs *attribution* only
(display mode, §10.2). For *layout* the working-tree stack is drawn as HEAD's own
continuation: a working-tree node's **pin rank** (§5 "Lane identity") is the rank
of the HEAD commit it stands on (the current branch's rank, or the `HEAD` owner's
when detached), and for a **reserved column** (§10.6.2) it counts as attributed to
HEAD commit's highest-priority reserved owner. So the lane born at the topmost
working-tree node carries HEAD's rank and colour into HEAD's row — it **ties**
there, so the "birth at a pinned tip" overrule (§5) does not fire and the lane
simply continues — and it is born in HEAD's reserved column when there is one.
Without this rule the stack would sit on an unranked lane that ends at HEAD
(HEAD's branch is pinned by default, §10.6), in an unrelated free-list colour and,
under a reservation, bending in from another column. The rule changes no
invariant: it only feeds the existing rank and reservation inputs.

The stack is present whenever the `working_tree` option is on and HEAD is born:
the change nodes while the tree is dirty, the clean node while it is clean
(§3.3; `working_tree = "dirty"` drops the clean node). The working-tree refresh
(§3.4) adds, updates, swaps and removes them as the index and working tree change.

## 5. Graph layout

The layout is the visual projection of the commit graph. Its vocabulary, from
the model outward:

- **Commit** — a node in the DAG (§4).
- **Lane** — one drawn **edge, child → parent**:

  ```
  Lane = { id, color, begin: Commit, end: Commit, highlighted: bool }
  ```

  `begin` is the child (above), `end` the parent (below); `id` is the lane's
  stable identity (born once, never reused); `color` is its palette slot, which
  drives the rendered colour (kept continuous along a first-parent chain, so a
  line of history reads as one colour); `highlighted` marks it for the
  reachability emphasis (§12). There is one Lane per parent/child edge. Colours
  are drawn from a recycling **free list** (§5.5), so concurrent lanes get
  distinct colours. *(A future **Route** — a contiguous run of Lanes forming a
  path — is not modelled yet.)*
- **OrderItem** — the visual unit for one Commit: its order position, the Commit
  it shows, the Lanes incident to it (`parent_lanes` out to its parents,
  `child_lanes` in from its children), and its rendered **Lines**. This is the
  commit ↔ visual bridge.
- **Line** — one rendered row: a sequence of **Columns**. An OrderItem has a
  *commit line*, **any number of virtual lines above** it, and, per the merge
  style (§5.2), an optional *merge line* (below). The above-lines are a **list**,
  not one optional slot: the merge style contributes at most one (the *split
  line*, §5.2), and the `gutter` policy (§5.6) contributes its handover rows, so
  a commit may render two or three lines above its own. Exactly one Commit's node
  sits on the commit line; every virtual line carries only wires. A virtual line
  takes a **screen** row but no real buffer line (§6.2), so adding one never
  changes what `line('w0')`/`line('w$')` address.
- **Column** — one cell of a Line: the **Segments** through it, plus the Commit
  node when one sits here. (`GraphColumn` in the code.)
- **Gutter column** — a Column that holds the **Lane owning the current subject
  row**, so that lane's commits' nodes all sit in one fixed column. It exists only
  under the `gutter` layout policy (§5.6), where it is model column 1 — so under
  the default mirror (§5.4) it renders as the **rightmost** cell, immediately
  beside the commit message. Only the Lane leading to the next subject-owning
  commit may enter it; every other Lane keeps out, so it never fills with an
  unrelated branch and is always either the current subject Lane or empty. (A Lane
  already in it may be left there for the next subject row's node to land on, rather
  than moved out and replaced — §5.6's *split swap*. Nothing new enters either way.)
  Every other policy has no gutter and places each node in its own Lane's column
  wherever that falls.
- **Segment** — a single wire within a Column: its `connectivity`
  {up, down, left, right} and the **Lane(s)** it carries. Each drawn edge gets
  its own Segment — one per Column normally, two where wires cross. The one
  exception is the single descent into a merge (or ascent out of a split) on a
  separate split/merge line: that wire is shared by every converging/diverging
  edge, so it is one **multi-edge** Segment, highlighted when *any* of them is —
  which keeps a non-trunk cone lane connected through the hub (§12).

The graph is walked top to bottom (newest heads on top, roots at the bottom), so
a Lane's `begin` (child) is always already placed when its `end` (parent) is
reached. A Column's rendered **glyph** is a function of the union of its
Segments' connectivity; its **colour** is one carried Lane's `color`, chosen by
a "top" strategy that prefers a highlighted Lane (§12).

#### Lane identity — which chain continues

A lane's identity is its `id`, its `color` and its **pin rank**. The rank is the
position, in the resolved pin list (§10.6), of the best-ranked pinned ref at the
commit where the lane was **born** — 1 is the highest priority. Only the list's
**entries** are ranked: a pinned local branch's implicit remote counterparts
(§10.6) carry no rank. A lane born where no ranked ref points is **unranked**,
which is worse than every rank. An unranked lane may instead be a **counterpart
lane** of rank `k` (§5.5 — born at a counterpart tip, below; its colour is slot `k`'s
counterpart variant): its **counterpart rank** `k` orders it among the unranked
lanes only, never against a ranked one. A continuation carries its lane's rank (and
counterpart rank) unchanged, exactly as it carries the `id` and the `color`. Which lane continues is decided
**semantically**, from the DAG, the row order and the pin ranks alone. A §4.2
working-tree node has no refs but **ranks as the HEAD commit it stands on** (§4.2
"Layout identity follows HEAD"), so the working-tree lane continues into HEAD in
HEAD's branch colour rather than ending there.

**Which lane a commit's first parent continues.** Among the incoming Lanes, in
tiers — each tier decides only between the lanes the previous one left tied:

0. **Pin rank.** The best-ranked incoming lane wins. Between unranked lanes, a
   counterpart lane beats a plain one, the better (smaller) counterpart rank first.
1. **First parent.** A lane whose child **has this commit as its FIRST parent** —
   the child that genuinely continues *into* it — beats one arriving as a merge's
   second-or-later parent edge.
2. **Newest.** The **newest** lane wins — the largest `id`. Ids are minted in row
   order and carried along a whole first-parent chain, so the largest id is the
   chain that started **lowest** — nearest this commit. Where nothing pinned and no
   first-parent edge decides, the branch the reader has just followed down into the
   junction carries on, and the older chain ends there. The trunk keeps its colour
   through such a junction by being **pinned** (tier 0) — `master` / `main` / `dev`
   and HEAD are pinned by default (§10.6) — not by having started first.

So a first-parent chain reads as one `id` and one `color` end to end, and a lane
arriving only as a merge's extra-parent edge still continues when nothing better
arrives — that edge *is* the merged-in branch, and minting afresh there would
recolour every merged-in branch tip. Every incoming lane that does not continue
**ends** at this commit, and its colour returns to the free list (§5.5).

**Birth at a pinned tip.** The tiers are overruled at a commit a pinned ref points
at, when that ref's rank (the best one at the commit) **strictly beats** every
incoming lane's rank — which includes every incoming lane being unranked. Then
**every** incoming lane **ends** here and the pinned branch's own lane is **born**:
a fresh `id`, the branch's **pinned colour** (§5.5; a free-list colour past the
palette), and the pinned rank. That includes a merge's extra-parent edge arriving
at the tip: a pinned branch that has been merged (`master` merged `dev`, and `dev`
still points at the merged commit) ends the merge's wire at its tip and starts its
own lane there, in its own colour — a lane's colour is fixed for life, so the wire
cannot be recoloured into the pinned one.

So a lower-priority or unpinned branch's colour never runs down a higher-priority
branch's history. With `dev` pinned and `feature1` branched off `dev`'s newest
commit, `feature1`'s lane ends at `dev`'s tip and the history below it is drawn in
`dev`'s own colour — where `feature1`'s colour used to continue down it. A remote
counterpart is no exception: `origin/x` ahead of a pinned `x` reaches `x`'s tip as
an unranked lane, so `x`'s pinned lane is born there and `origin/x`'s commits above
it are drawn in `x`'s **counterpart colour** (§5.5: the same slot, lightly dimmed),
which brightens to the full pinned colour at `x`'s tip. A pinned lane in turn **ends** where it
converges into a better-ranked lane (tier 0), as any lane does.

**Birth at a counterpart tip.** The same overrule one step down, for an implicit
remote counterpart (§10.6) of a pin of rank `k`. At a commit such a counterpart
points at, when **no ranked ref** points there (a ranked ref wins: the pinned rule
above applies instead), slot `k` is still **held** (§5.5 — so there is a counterpart
colour to give), and `k` strictly beats every incoming lane — **none** of them is
ranked `≤ k` and none is a counterpart lane of rank `≤ k` — **every** incoming lane
**ends** here and a **counterpart lane** is born: a fresh `id`, unranked, counterpart
rank `k`, colour `-k` (§5.5). The comparison is by rank, exactly as for a pinned
birth: an incoming lane of a pin ranked **worse** than `k` (rank `> k`) is beaten and
ends here — its own commits above keep its colour — while a lane of a pin ranked as
well or better (rank `≤ k`) still continues through (the counterpart loses to it),
and so does a counterpart lane of rank `≤ k`. So with `dev` pinned and `origin/dev`
one commit ahead, the remote's commit reads in `dev`'s counterpart colour even when
another branch is built on top of it — unpinned, or pinned below `dev` (HEAD's
branch, a default pin ranked after the trunks, §10.6): that branch's lane ends at
`origin/dev`'s commit instead of running through it down to `dev`'s tip. Under the four lane-column policies this changes lane
ids and colours only (0 glyph changes over the fuzz corpus and the large real-world
topology); under `gutter` it moves geometry like a pinned birth (55 of 2,064 fuzz rows,
0 of 3,804 on the real topology, every invariant holding), with the same rules: the
birth claims no gutter when a fan has a Line of its own, declines the parent swap,
and its spine break is licensed.

A fresh `id` and `color` are therefore taken where a lane is born: a branch head (a
commit nothing arrives at), a merge's second-and-later parents (born unranked), a
pinned tip that outranks everything arriving at it, and a counterpart tip that
outranks everything arriving at it. A lane born at a pinned tip —
by outranking, or as a head nothing arrives at — takes its branch's pinned colour
(§5.5) instead of the front of the free list.

**Identity never depends on placement.** No column, and no ordering by column, may
influence an `id`, a `color`, a rank, or the order in which colours are returned to
the free list. This is what makes lane identity **invariant across layout policies**
(§5.6): the same commits in the same row order under the same pin ranks produce the
same lane ids and colours under every policy, which differ only in *where* the lanes
are drawn. Switching policy with `C` moves the graph; it never recolours it.

**The pin ranks are a layout input.** They are part of the layout fingerprint — the
resumable sweep of §3.1 and the reflow of §10.5 — so a pin, an unpin or a reorder in
the dialog (§10.6.1) re-lays the layout instead of continuing one laid out under
other ranks. They are not part of any signature (§10.2), so the signature cache stays
valid across pin changes. The footer's seeded sweep (§6.2) uses the same ranks, each
seeded lane carrying its main-view rank, so a lane born inside the pane obeys the
same rule as one born in the main view. The pinned colours are fixed by the ranks
alone (§5.5), so they are known before the first row and the resumable sweep's
prefix property is unaffected.

> **The `gutter` exception (measured).** Under the four lane-column policies the
> ranks change colour only: 0 glyph changes over 17,852 fuzz rows and the large
> real-world topology, with 944 births. Under `gutter` (§5.6) stages *read* the
> continuing lane, so a birth or a rank-won convergence moves geometry there: 11.5% of
> fuzz rows change glyphs (Lines 31,394 → 31,149), and on the real topology 65 of
> 638 rows under the inline-fan-in styles (two Lines fewer) and none under the
> split-line ones — with every invariant holding, the birth's spine break licensed.
> A birth claims no gutter when a fan has a Line of its own and declines the parent
> swap (which would leave the node in neither its own lane's colour above nor below).
> The parent swap's clause 3 is unchanged: a merge's sole-child edge arriving at a
> pinned tip ends there, which is a licensed birth like any other.

> The rule was previously "reuse the **leftmost** incoming lane's id and colour" — a
> positional proxy for "the trunk", sound only while the trunk happened to sit
> leftmost. It failed wherever a topic lane landed left of the trunk: the merge and
> the whole spine below it were drawn as the topic. Any layout that constrains
> columns (§5.6 `gutter`) turns that from an edge case into the common one, which is
> how it was found — but it was never gutter-specific.

### 5.1 Invariants

Lane placement is a **switchable policy** (§5.6), so the guarantees here are of
three kinds and the distinction is load-bearing. A **universal** invariant holds
under every policy. A **conditional** one constrains a sideways move a policy may
or may not make — it is vacuously true under a policy that makes none. And one
rule below is a **placement** rule on an axis of its own, unrelated to compaction.
The single genuine claim that compaction *happens* is policy-specific and lives in
§5.6, not here.

**Universal.** These hold under every layout policy.

- **One commit per Line.** Exactly one Commit's node is placed on a commit line;
  the virtual split/merge lines carry none. *Exception:* a **packed marker line**
  (§10.4) carries several markers' nodes — messageless collapsed heads merged
  onto one line — each in its own lane column.
- **Two-sided Segments.** Each Segment touches exactly two of its Column's sides
  (a wire enters and exits) — one side only at an endpoint (a Lane's `begin` or
  `end`). This forces crossings (`─│─`) and tees to be modelled as *separate*
  Segments, not one over-connected wire.
- **Every Lane is an edge.** A Lane has both a `begin` (child) and an `end`
  (parent), both placed Commits (or the fetched-range boundary). Its Segments run
  from `begin`'s line down to `end`'s line; no Lane fizzles into nothing.
- **Edge attribution.** Each Segment carries the actual Lane(s) it draws — the
  edge `(begin, end)` — so two wires that share a Column or cross stay distinct
  by edge identity. The shared descent/ascent Segment at a separate split/merge
  hub carries the set of edges converging/diverging there.
- **Per-Lane continuity.** A Segment of Lane L with `down` on one Line meets a
  Segment of the *same* Lane L with `up` in the same Column on the next Line.
- **The spine through a node.** A commit's node sits in **its own Lane's** column —
  the Lane its first parent continues (§5) — so the wire arriving at the node cell
  from above and the wire leaving below carry one `id` and one colour, and a line of
  history reads as one colour straight through its commits. *Exactly two exceptions
  are licensed, one per fan, and both belong to the `gutter` policy's handover
  avoidance (§5.6):*
  - the **parent swap**, at a **merge**, which may hand the gutter to a non-first
    parent — so the wire below the node is a non-first parent's and the wire above is
    still the node's own Lane. The node then takes its colour from the wire **above**,
    so the break shows as a new lane beginning rather than as the trunk changing
    colour.
  - the **split swap**, at a **fork**, which may leave the gutter with a converging
    child that is not the continuation and put the node on it — so the wire above the
    node is that child's and the wire below is still the first parent's. The node's
    colour needs no adjustment here: it comes from the wire below, which is its own
    Lane. This one breaks the spine **only where the fan-in shares the commit Line**;
    given a split Line of its own the child terminates up there, the hub descent
    carries the node's own Lane, and nothing is broken at all.

  Both are licensed **only where they demonstrably remove a handover** — a break is
  1:1 with two rows saved, never a free allowance — and a cell with the node's own
  Lane on *neither* side is a defect under both. The four lane-column policies place a
  node on the leftmost *arriving* Lane, a positional stand-in for its own that is right
  on real histories but not always, so they carry a small unlicensed residue (1–2 rows
  per repository); fixing it moves the node column, which compaction ripples off, so it
  is a deliberate visual decision of its own rather than a quiet correction. That
  residue has the same *shape* as the split swap's licensed break, and only the policy
  knows that a given column is a gutter, so the check is asserted for `gutter` alone.
- **Root column break.** A root (a commit with no parents) ends its lane with
  nothing below it. The column it occupies is **not reused** by any vertical wire
  or commit node on the immediately following Line, so an independent history
  beneath a root is offset into another column instead of stacking under it (which
  would read as one continuous lane). A horizontal wire may still cross that
  column on the next Line (a crossing, not a continuation). This is enforced by
  the sweep's own column bookkeeping — tip placement and fan-out both skip a
  blocked column — never by a compaction move, so it survives a policy that moves
  nothing.
- **Reserved columns are occupied.** A column held for a **reserved** pinned
  branch (§10.6.2) counts as occupied for every placement decision, on every
  Line — exactly the root-column-break mechanism above, with a longer lifetime.
  Only that branch's own lane may be born into it; tip placement, fan-out and
  every compaction move skip it. Occupancy is bookkeeping rather than a move, so
  this holds under every policy. Its one extra requirement over the root break:
  a compacting lane that meets a reserved column **stops at it and never lays a
  horizontal across it** (the conditional guard below already says exactly that,
  and a reserved column is simply one more thing it stops at). A horizontal
  crossing a *held* column is not a horizontal crossing a *vertical*, so nothing
  in the crossings check would catch it — which is why it is stated rather than
  left implicit.
- **Colour comes from a carried Lane.** A Column's colour is the `color` slot of
  one Lane on one of its Segments (§5.5). Colour is a property of the lane
  *lifecycle* (born / continued / ended), which no policy varies.
- **Connectivity consistency.** The glyph's wired sides equal the union of the
  Column's Segments' connectivity (every wired side has a Segment providing it).
- Merges (commit with >1 parent) fan out `parent_lanes`; splits (>1 child) fan in
  `child_lanes`.
- **A commit Line's horizontals are its own fans.** The only horizontal wires on a
  commit Line are the wires of that commit's own fan — its converging children and
  its diverging parents. Everything else is a compaction jog, and no jog may cross
  a lane (the guard below). *Corollary, for every policy that lets a commit's node
  fall wherever its own Lane already is* — `compact`, `survivors`, `linear`,
  `straight`: on the both-lines style (§5.2) both fans are elsewhere and a linear
  commit's degenerate fan spans no columns, so such a commit Line carries no
  horizontal at all and therefore has **no crossings**. This is *provable* from the
  guards rather than merely observed. Under `straight` it is strictly stronger
  still — no Line carries a jog, so no commit Line ever carries a horizontal that
  is not a fan. It holds under `gutter` (§5.6) too, and for the same reason:
  constraining *which column* a Lane occupies does mean a lane has to travel on
  the rows where the gutter changes hands, but that handover is given **virtual
  rows of its own** and never rides a commit Line — so a commit Line still carries
  only that commit's own fans. Measured over the §5.6 fixtures, `gutter` and
  `straight` produce **identical** counts of commit Lines carrying a horizontal;
  the residue in both is the node-less junction whose single fan renders inline
  (§10.4), which is a fan. This was false while the handover's swap-in rode on the
  arriving commit's own Line: a linear commit's "fan" then spanned from its Lane's
  column to the gutter and crossed whatever lay between. The separate claim row is
  what removed it.
- **A repositioning move gets a Line of its own.** A policy may move a lane for
  reasons that are not a commit's fan — today only the `gutter` handover (§5.6).
  Such a move is drawn on a **virtual Line** carrying that move and nothing else:
  exactly one lane turns on it, so it has one horizontal run, in one direction,
  and it cannot be confused with a fan or with another move. It may not share a
  commit Line, whose horizontals are reserved for that commit's own fans by the
  rule above.

**Conditional — the compaction guards.** Stated as constraints on any jog a policy
chooses to make, not as claims that one is made, so they hold unchanged under
every policy (vacuously where none is made).

- **A compaction jog never crosses a lane.** Once two lanes have separated they
  share a horizontal Line only at a commit's own fan (the split/merge funnel).
  *Where a policy makes a jog* — the linear-commit slide (§5.6), or a survivor
  shifting into a gap — it moves left only through a run of columns *free since
  row start*, **stopping at the first occupied column** rather than reaching past
  it into a farther gap (which would lay the lane's horizontal across the
  occupant). A gap behind an occupied lane is reclaimed on a later row, once that
  lane itself moves (a ripple). "Occupied" is occupancy in the universal sense
  above — a live lane, a root-blocked column, or a column **reserved** for a
  pinned branch (§10.6.2) — so the guard covers all three without restatement.
- **A fan Line carries no compaction.** *Where compaction runs*, it is suppressed
  entirely on a Line whose fan is drawn **inline** (the split or merge shares the
  commit Line rather than getting its own Line): a pass-through lane crosses the
  fan **vertically**, never compacting horizontally along it, and the
  linear-commit slide does not run. Only the fan's own lanes — the converging
  children, the diverging parents — draw the horizontal; a lane joins it only if
  it belongs to that fan. Where compaction runs at all, it still applies on
  non-fan Lines and on a Line whose fan sits on its own split/merge Line.

Both guards are specified — and tested — by **counting violations** ("no jog does
X"), never by asserting an existence ("a jog happens"). That is what lets them
stay sound, and stay *unchanged*, across every policy; it is a deliberate property,
not an accident of phrasing, and it should be preserved when policies are added.

**Fan-out placement.** A separate axis from compaction: it governs where a *newly
diverging* lane is put, not whether an existing one moves, so it applies under
every policy — including one that never compacts. There is exactly one placement
rule today; replacing it is a future policy of its own (§5.6). Its name is
historical — it is about *reusing* a freed column, not about the compaction moves
— so do not read it as part of the compaction axis.

- **Compact column reuse.** A fanned-out parent lane (a merge's extra parent)
  takes the **leftmost column that has been free since before its Line** — an
  interior gap an earlier branch vacated — rather than always opening a new
  rightmost column. A column **reserved** for a pinned branch (§10.6.2) is never
  free, so a fan-out steps over it; only that branch's own lane is born there.
  So a staircase of sequential feature-branch merges stays a
  bounded width instead of growing one column wider per merge. A column a
  *terminating* child frees is reusable by an outgoing parent only when that does
  not place two turns in one cell: when the fan-out is on a **separate merge Line**
  below (the child already ended on the commit Line above, so the column is simply
  free) or under `allow_merge_on_split` (the sanctioned inline two-turn cell, §5.2).
  Otherwise — an inline fan-out sharing the commit Line with the fan-in — the
  freed column is left for the next Line to reclaim, so two adjacent merges may
  alternate columns by one. That alternation applies **only** to a fan-in that
  shares the commit Line: with a **separate split Line** the converging children
  end on that Line, above the commit Line, so on the commit Line their columns are
  simply free (only the node's column is held) under every policy, and a run of
  merges each absorbing the next topic's lane keeps every topic in the same
  column. Reusing the column on a separate merge Line is what
  keeps that style from leaving an empty-column gap that bounces a right-aligned
  (mirrored, §5.4) graph.

  **How it is enforced, and why that matters to a new policy.** The default is
  *not* reuse: a terminating child's column is marked **occupied for its own Line**
  when the commit is placed, so every later placement on that Line steps over it,
  and only the two sanctioned cases above lift it deliberately. The one exemption
  is a commit's **first parent** re-taking its own trunk child's column — it
  inherits that lane's `id` and `colour` (§5), so the cell holds one lane, not two.
  A policy that places commits itself and forgets to reserve those columns
  reintroduces the §5.2 lane handoff *unsanctioned*: an ending child's turn and an
  unrelated lane's turn land in one cell, whose single rendered colour then breaks
  mid-column. This is stated because it has actually happened during development,
  and because the reservation looks like bookkeeping rather than the invariant it
  is.

  The **mirror image** has also happened, and binds just as hard: a reuse is a
  *preference among columns that are free*, never a licence to take one **this
  Line has already claimed**. The node's own column is always claimed — the first
  parent continues there (§5) — so it is never a reuse candidate, however the
  policy chose it. Deciding that by POSITION ("every converging child but the
  leftmost") is only correct while the node sits on the leftmost arriving lane;
  a policy that puts it on the commit's own lane instead (§5, which is what §5.6's
  `gutter` does) then offers the node's own column to an extra parent, and the two
  parents collide in one column with one silently dropped. Test the claim, not the
  ordinal.

Edge attribution (`begin`/`end` per Lane, and a Segment's edge set) is the model
contract that makes the §12 reachability emphasis exact and the planned §10 view
work and lane navigation possible. The handoff split (an incoming child-lane and
an outgoing parent-lane sharing a column) remains two distinct Lanes.

### 5.2 Merge style

`merge_style` selects where merges and splits are drawn:

- `split_on_separate_line` — when set and a commit has >1 child, the fan-in
  is drawn on a virtual line **above** the commit row.
- `merge_on_separate_line` — when set and a commit has >1 parent, the fan-out
  is drawn on a virtual line **below** the commit row.
- `allow_merge_on_split` — permits placing a merge onto a split lane when
  merges are folded onto the commit line. In this mode an incoming child-lane
  and an outgoing parent-lane can share a column (a "lane handoff"): the cell's
  `up` segment and `down` segment belong to *different* lanes. The **model**
  represents these faithfully as two separate lanes (so per-lane continuity
  holds); the **rendered** glyph is a single cell that can only show one
  color, so its color is best-effort and may read as continuous across the
  handoff. The model is the contract here, not the coloring.

When a separate line is not used, the merge/split is folded onto the commit
row itself.

### 5.3 Glyphs

Lanes render as box-drawing characters derived from connectivity
(`│ ├ ┤ ┬ ┴ ┼ ╭ ╮ ╯ ╰ ─` and the terminal half-segments; `┼` only as a
node-less junction, §10.4). Commit markers:

| Marker | Meaning |
|--------|---------|
| `◎`    | root commit (no parents) |
| `◉`    | tip commit (no children) |
| `○`    | ordinary commit |
| `◌`    | working-tree commit (a virtual staged/unstaged/untracked/clean node, §4.2), in the HEAD colour |
| `◍`    | collapsed head (a contracted region, §10.3) |
| merge icon | merge commit when merges are folded onto the line and `icons.merge` is set |
| `●`    | the commit **HEAD** points at, attached or detached (`icons.head`), in the HEAD colour |

**HEAD's node** is drawn `●` (`icons.head`, §8) in the **HEAD colour**
(`palette.head`, the colour of HEAD's label marker, §6) instead of the marker its shape
would pick (`○`, `◉`, `◎` or the merge icon) — "you are here" in the graph
itself, not only in the labels. The renderer recognises HEAD's commit by the
`head` ref it carries (§3.2), so a resync or checkout (§3.4, §10.4.1) moves the
marker with no extra state. Precedence: a working-tree node (§4.2) keeps `◌`;
when HEAD's commit is folded into a collapsed `◍` head (§10.3) or a packed marker
(§10.4), that node keeps `◍` but takes the HEAD colour. Only the glyph and its
colour change — the cell stays one column wide, so the layout is untouched — and
out-of-cone dimming (§12) applies to it as to any node. The mirror transform
(§5.4), the context panes (§6.2) and the commit-search snippet (§15.3) mark it
the same way. Setting `icons.head = ""` turns the marker off (the ordinary glyph
and lane colour).

**The working-tree node** (§4.2) is drawn `◌` in the **HEAD colour** too — only
the glyph cell, its lane keeps HEAD's branch colour (§4.2 "Layout identity follows
HEAD"). Since the stack is always present (§3.3), every graph shows a HEAD-coloured
`◌` directly above the HEAD-coloured `●` and joined to it, which is what makes
HEAD stand out at a glance even on a clean tree. Its row label is synthesized (the
model carries no message): `Staged changes · N files`, `Unstaged changes · N
files`, `Untracked files · N files`, and for the clean node `Working tree ·
clean`, drawn in the date colour (dimmer than a subject) so a clean row reads as
state, not as a commit. Date and author cells are blank. With `icons.head = ""`
the `◌` takes its lane colour.

### 5.4 Mirroring

By default the graph is **mirrored**: the cell sequence of each row is reversed
and each cell's `left`/`right` connectivity is swapped before glyphs are
derived, so the graph reads right-to-left with lane 1 at the **right** edge of
the graph column, nearest the commit message. The graph column is right-aligned
(padded on the left) so vertical wires stay column-aligned across rows of
differing lane counts. Setting `mirror = false` (§8) renders it the
conventional way, left-to-right with lane 1 at the left.

Mirroring is purely a rendering transform: the commit ordering, the lane
layout, and the lane model (ids, `child`/`parent`, per-lane continuity) are
unchanged — only the projection to glyphs is flipped. Because the glyph is a
pure function of connectivity (§5), the mirrored glyphs (`╭`↔`╮`, `┤`↔`├`,
`╴`↔`╶`) and the inter-lane connectors fall out of the model with no separate
glyph-swap table, and color (lane color slot) is preserved. All §5.1 invariants
hold on the mirrored output.

**Mirroring does not flip the ref labels.** Only the graph column is mirrored;
the ref labels of a row (§6) keep their **logical order** in every mode,
mirrored or not: HEAD's label (the current branch) first, then the local
branches, the remote-only branches, the tags and the worktree labels — in every
label mode (§6.1), on collapsed heads and labelled junctions and packed marker
rows (§10.4), and in the context panes (§6.2). Everything that follows from that
order is the unmirrored behaviour too: the default selection is the first label
(and a packed line's first marker), `h`/`l` step through the labels left to
right, the `+N` overflow (§6) is a trailing one, and the palette lists a packed
line's per-marker entries first to last. The reason is that the reading order
carries the labels' **priority**: drawn reversed, the remotes and tags would be
read before the local branches, and the overflow would no longer hide the least
important labels. A strict mirror image of the label strip is therefore
deliberately given up — the labels are not beside the flipped graph anyway (it
stays in its column, left of the message and the labels).

### 5.5 Lane colouring (the free list)

A lane's colour is a **palette slot** drawn from a recycling **free list**,
seeded with the curated `palette.tracks` colours (§8). A born lane takes a slot
from the front; an ended lane returns its slot to the back (FIFO), so a colour is
not reused immediately. Allocation happens **before** the same line's ended lanes
return their slots, so concurrent lanes always have distinct colours.

**Breathing room.** A returned colour is held out of reuse for the next
`palette.buffer` allocations (§8); if no colour is free *and* cooled down when a
lane is born, a colour is **generated** instead. This guarantees at least
`buffer` other colours are drawn before any colour repeats — a history that ends
is never immediately followed by a new one in the same colour. Curated colours
are used first (they start available), so generation only begins once branching
outpaces the cooled-down curated colours.

**Generation.** Overflow colours are generated in **OKLCH**, rotating hue by the
golden angle (~137.5°) at a lightness/chroma **anchored to the theme** (derived
from `palette.tracks`/`Normal`, or set explicitly, §8), so they stay in the
theme's key while staying perceptually separated at any count. Generated colours
recycle like curated ones but are **retired** (dropped, not returned) once the
list is comfortably full again — so a graph that quiets down drifts back to the
curated palette, and only sustained branching shows generated colours. **Curated
colours are never retired.**

Generation requires truecolor. Without `termguicolors`, nothing is generated: the
curated palette is **shared** on exhaustion (a slot reused, reference-counted so
it returns only when its last holder ends; a lane is never recoloured, since that
would break its colour continuity).

A first-parent continuation keeps the continued chain's slot (one colour per
first-parent chain, §5). Allocation happens at the three places a lane is born (§5
lane identity): a branch head, a merge's extra parent, and a **pinned tip that
outranks every lane arriving at it** — the last of these returns every incoming
colour, so a lower-priority branch's colour never runs down a higher-priority
branch's history.

**Pinned colours.** A pin-list entry (§10.6) of rank `k` **owns slot `k`** of the
curated palette — the `k`-th of `palette.tracks`, the same list every lane draws
from — as its **pinned colour**. From the start of the layout the slot is
**withheld**: dropped from the free list, never handed to another lane, and never
shared on exhaustion. The pinned branch's lane is born with it (at its tip, §5), and
keeps it for life like any colour. Once the branch's start is found the slot is
**released** into the free list and recycled like any returned colour:

- when the pinned lane **ends** — it converges into a better-ranked lane, or stops
  at a root; or
- at the pinned tip itself, when no lane of the branch's own is born there — a
  better-ranked lane arrives and continues, or a better-ranked ref on the same
  commit names the lane.

A pinned ref whose commit is never laid out (hidden, not yet streamed) keeps its
slot withheld for that layout. A released slot goes to the back of the free list
with the usual cooldown, after the same commit's ended lanes, in slot order.
Only explicit entries own a colour; a remote counterpart has no rank (§10.6) and
owns no slot, but **shares its local's** (below).

**Counterpart colours.** A lane **born** at the tip of an implicit remote
counterpart (§10.6) of a pin of rank `k` — where no ranked ref points: nothing
arrives at the counterpart's commit, or only lanes it outranks (§5 "Birth at a
counterpart tip") — takes slot `k` too, marked as a **counterpart lane**. It
is drawn in the **counterpart variant** of that colour: the same hue, blended
lightly toward the background by `palette.counterpart_dim` (§8, default `0.25`,
much lighter than the §12 cone dim), so the local and where each remote thinks it
is read as one branch while staying distinguishable. Without truecolor the variant
is the plain slot colour. When several counterparts of different pins point at the
commit, the best rank's slot is taken. Sharing slot `k` with the pinned lane is
allowed — they are told apart by the light dim — and slot `k` is handed to
counterpart lanes **in addition to** the pinned lane and to nothing else: a
counterpart lane takes it only while it is **held** (still withheld, or held by the
pinned lane or by another counterpart lane), counted as one more holder; a slot
already released, or a rank past the palette, gives the counterpart lane an
ordinary free-list colour with no counterpart mark. The slot returns to the free
list only when its **last** holder ends — the reservation or pinned lane and every
counterpart lane holding it. Counterparts still carry no rank, so a pinned lane
always beats a counterpart lane in tier 0; the birth at a counterpart tip (§5) —
which ends an arriving pinned lane only when its pin ranks worse than `k` — changes lane
identity, and glyphs only under `gutter`. A counterpart lane that reaches its
local's tip ends there and the pinned lane is born (§5), so the colour visibly
brightens at the local's tip; a counterpart at or behind its local sits on the
pinned lane itself, in full colour. With `pin_upstream` off there are no
counterparts and no counterpart colours. The counterpart map (ref id → its local's
rank) is a layout input beside the pin ranks — part of the layout fingerprint,
known before the first row (so the §3.1 prefix property holds), carried by the
footer's seeded lanes (§6.2) inside their colour.

**The cap is the curated palette.** Only ranks `1 … #palette.tracks` own a slot. A
pin ranked below that keeps its rank (§5 identity is unchanged) but takes a
free-list colour where its lane is born. The withheld slots shrink the free list,
so heavy pinning reaches generated colours (or, without truecolor, sharing among
the slots not withheld) sooner; "comfortably full" for retiring a generated colour
is measured against the slots not withheld. With every curated slot withheld and no
truecolor, sharing falls back to all curated slots rather than failing.

The pinned colours depend on the pin ranks alone — never on a column or a row — so
they are identical under every layout policy (§5.6), known before the first row is
laid out (the resumable sweep of §3.1 keeps its prefix property), and a pin added
**below** an existing one leaves that one's colour unchanged.

**The free list is order-sensitive, so the return order is fixed by identity too.**
A returned slot goes to the back of the FIFO, so *which* colour a later lane receives
depends on the order the ended lanes were returned in. That order is therefore taken
from the lanes' `id`s — row order — never from their columns; otherwise colour would
depend on placement through the back door, and two layout policies (§5.6) would
diverge on colour even with identical identity rules.

**Reserved slots.** A slot may be **held out of the free list entirely** for as
long as something owns it: it is dropped from the FIFO, counted in use, and
neither recycled nor retired. Three things reserve a slot — a context pane's
**seeded** boundary lane, so a lane born inside the pane never reuses a colour
live at the seam (§6.2); a **pinned colour** until its branch's start is found
(above); and a pinned branch with a **dedicated column** (§10.6.2), which keeps its
pinned colour for the whole layout. Reserving is the same mechanism in every case.
A seeded lane that carries a slot still withheld as a pinned colour **is** that
pinned branch's lane continuing across the seam: it takes the reservation over
(the slot is counted once), and the slot is released when that lane ends inside the
pane — never assigned a second time.

### 5.6 Layout policy

Lane placement is a **named policy**, selected by `layout_policy` (§8) and cycled
live with `C` — so the placement algorithms can be compared in the real
application, on a real repository, at a glance (the same "compare at a glance"
motive as `m` for the merge style, §5.2). Every §5.1 universal invariant holds
under every policy and both §5.1 guards constrain every policy. A policy chooses
**which lanes may move sideways to close a gap**, and — one policy only —
**where a commit's node is put**.

Two independent moves exist:

- the **linear-commit slide** — a *linear* commit (reached by a single child-lane)
  slides left through the run of columns free since row start, its incoming lane
  turning into the new column. So a branch born one column out — an inline
  merge-on-split that had to fan past a freed cell — compacts next to the trunk
  after a single jog rather than running stranded beside an empty column. The
  slide reserves its column before survivor compaction, so a survivor keeps any
  nearer gap; the lone jog is a turn, not a straight run, so id-continuity holds.
  *This is the one §5.1 claim that is genuinely policy-specific: it asserts that a
  jog happens.*
- **survivor compaction** — a pass-through lane shifts left into the run of free
  columns to its left, redrawn as a turn.

| Policy | Linear slide | Survivor compaction | Column constraint |
|--------|--------------|---------------------|-------------------|
| `compact` (**default**) | yes | yes | none |
| `survivors` | no | yes | none |
| `linear` | yes | no | none |
| `straight` | no | no | none |
| `gutter` | no | no | the current subject lane holds a **fixed column** |

Under `straight` every lane holds its column for its whole life: nothing but a
commit's own fan draws a horizontal, so on the both-lines style a commit Line
carries no horizontal wire at all — strictly stronger than the no-crossings
corollary §5.1 states for the lane-column policies.

The policy is a **flat enum**, not a pair of booleans. The first four happen to
be a 2×2, but the axis is "how are lanes placed": `gutter` shares `straight`'s
row of that square and is still a different policy — it adds a *placement
constraint* on top of the no-move rule rather than another kind of move — and a
future policy (below) is not a point in that square at all.

#### `gutter` — a fixed column for the current lane

The **lane** that owns the current subject row occupies the gutter (§5 *gutter
column*; model column 1, so the rightmost cell under the default mirror), which
puts that lane's commits' nodes in one fixed column immediately beside their
messages. Lanes otherwise **never move** — the `straight` no-move rule — so a run
of consecutive commits on one lane draws a straight vertical with nodes on it and
**no horizontal wire at all**.

The gutter changes hands only when the **next subject-owning commit is on a
different lane**. Because the ordering emits a merged-in lineage contiguously right
after its merge (§3.1 lineage grouping), consecutive subject rows overwhelmingly
share a lane, so this is rare — measured below.

**It keys on subject-owning rows.** A **marker** row — a collapsed head, or a kept
junction drawn as a marker (§10.4) — carries ref labels but no subject, and several
markers may share one packed Line (§10.4), so a marker never claims the gutter and
never displaces it: a marker between two commits of one lane disturbs nothing. Its
own node sits on its own lane like any other node. A working-tree virtual commit
(§4.2) carries a synthesized subject, so it is an ordinary subject row.

**The handover is two virtual rows, one move each — never a swap, and never
shared with a fan.** This is the design's load-bearing choice. Two lanes
exchanging columns over ONE row must both bend in the gutter cell, which renders
`├─┤` — the same glyph a two-arm fan bus draws, so a transposition is not
distinguishable from a fan; and a cell holding two different lanes' bends renders
a single colour for two wires, which is exactly the §5.2 lane handoff. Nor may
either move ride on the commit Line: a wire travelling *into* the gutter and the
arms of that commit's own fan travelling *out* of it occupy the same cells in
opposite directions, and a reader following a run cannot tell which wire it is
on. So the handover decomposes onto **two separate virtual rows above the
commit**, in this order:

1. a **virtual eviction row** — the occupant leaves the gutter for the nearest
   free column to its right;
2. a **virtual claim row** — the arriving lane turns in from its own column to
   the gutter, directly above the commit that will sit on it.

Each row moves **exactly one lane**, so it carries exactly one horizontal run, in
one direction, and nothing else on it turns at all. The commit Line below them
then carries only that commit's own fan (usually nothing, since the trunk is
already in place). The lane that claims is the one whose **chain the commit
continues** (§5 lane identity), so the gutter cell's wire above the node and its
wire below it are one Lane, one id, one colour.

**The handover column.** While the gutter's lane will be evicted before it next
owns a subject row (its parent is not the next subject row, known from the
prepass), the column beside the gutter is kept free for it: a lane placed on such
a row skips that column if it ends no earlier than the occupant. A lane that ends
sooner may still take it, since it nests inside the occupant and neither crosses
the other. So the eviction lands beside the gutter instead of beyond every lane
born in the meantime, typically collapsed heads (§10.4). It costs no Lines and
moves no existing lane.

**The occupant is whoever is in the column** — a pass-through survivor, or one of
this commit's *own* converging children. The second case is the frequent one and
the easy one to miss: a run of commits on lane L holds the gutter, and where that
run's last commit forks off a trunk, L's final edge terminates at the fork —
still in the gutter, and still not the lane the fork continues on. Ignoring that
case is what once left the gutter cell's wire above the node on the ending lane
and its wire below on the continuing one, so the fork's split hub rendered in the
ending branch's colour while the spine below it rendered in the trunk's — the
very defect the rule above forbids, and the one the ordering makes routine (§3.1
emits a merged-in lineage right after its merge, so the lane adjacent to a fork
is very often one that ends there). A **pass-through** occupant is evicted like
any other; a **converging child** is now handled by the *split swap* below, which
leaves it where it is and brings the node to it — the fix for the colour defect
being that the hub carries the commit's own Lane wherever the node landed, not
that the child had to move.

Either row is emitted only when it has work: a gutter already free needs no
eviction, and **the claiming lane** already in the gutter needs no claim — which,
given the lineage grouping (§3.1), is the overwhelmingly common case. *Any* other
lane in the gutter is a reason to evict **or to swap** (below), not a reason to skip
the claim. Only a subject row may claim the gutter, so it is free by the time the
claim row runs.

**Avoiding the handover instead of paying for it.** A handover costs two rows, and
both fans give the layout one chance to avoid one — at a **merge** by choosing *which
parent* continues in the gutter, and at a **fork** by choosing *not to take the gutter
back*. The two are mirror images, they cost different things, and they are gated
separately.

**The parent swap (at a merge).** A handover
costs two rows, and one class of it is avoidable at the source. At a **merge**, the
gutter is about to be wanted by whichever branch the next subject row is on, and the
merge is the one place the layout still has a free choice: *which of its parents*
continues in the gutter. Where that next row belongs to a **non-first** parent, that
parent takes the gutter and the first parent fans out sideways as an ordinary arm of
the merge's own fan-out — so the branch that needs the gutter is already in it, and
the two handover rows are never emitted at all.

This is deliberately hard to trigger. **All three** of the following must hold:

1. **That parent comes first.** Its next commit is earlier in row order than the
   first parent's — the merged-in lineage is what continues immediately below the
   merge, and the first parent's own line resumes further down.
2. **That parent owns the next subject row.** Not merely the next *row*: the next
   row that carries a message (this policy keys the gutter on subject rows).
3. **That parent can keep the gutter it is handed** — the merge is its only in-set
   child, so the Lane born at the merge is the only Lane arriving at it and is
   therefore the Lane it continues (§5 identity).

Clause 2 is not a refinement; it is the gate. With clause 1 alone the swap fires at
**every** merge in the shipping focused view and buys **nothing**: §3.1's lineage
grouping parks the merged-in branch's `◍` collapsed head immediately after its merge,
so clause 1 passes — but a collapsed head owns no subject row (above), so it never
wanted the gutter and no handover exists to save. Measured on a 1040-commit
repository focused: 62 of 62 merges fired, and the result was **worse** on every
axis — crossings 116 → 209, rendered rows +29.5%, and node-in-gutter fell from 1.000
to 0.943, because a merge that gives its gutter away is a subject row whose own node
is no longer in it. With clause 2 all 62 decline and the focused view is byte-
identical to not having the rule at all.

Clause 3 makes the saving **provable** rather than likely. Clause 2 says the next
subject row is that parent; it does not say that row will *continue* on the Lane it
was handed. If another Lane also arrives there — another child of that parent — and
wins §5 identity over the handed one (a better rank, a first-parent edge, or a
larger `id`), that Lane is the one continued,
the handed Lane is evicted after all, and the row pays its handover anyway *on top
of* a spine break that bought nothing. "Its only in-set child is this merge" removes
the contest: one candidate, so it wins by construction. Measured, clause 3 declines
**exactly** the fires that save nothing and no others (15 of 100 on that repository
expanded, 0 of 11 on `tests/large_topo`); in a real history the merged-in tip
normally has just the one child, which is why the cost is small.

**The price is a licensed spine break, and the licence must be earned.** §5.1's
per-Lane continuity still holds — the wire above the node and the wire below it are
distinct Segments of distinct Lanes, each continuous — but the *node's column* is no
longer one `id` from top to bottom, which is the one thing the gutter otherwise
guarantees (above). That is a real cost, so it is bounded rather than waived:

> A commit's node cell may carry a different Lane above it than below it **only** at
> a merge where this swap fired, and **only** if the swap saved a handover — meaning
> the next subject-owning row does put its node in the gutter, entered by the very
> Lane the swap sent there. A break anywhere else, or a swap that saved nothing, is a
> defect.

So the break is **1:1 with a handover removed** — never a free allowance. It is
checkable from the rendered output alone, without reference to the layout's internal
decisions, which is how it is tested (`tests/graph_helpers.check_spine`).

**The split swap (at a fork) — declining to take the gutter back.** The mirror case,
and the more common one. The gutter is held by a lane that is one of this commit's own
**converging children** but is not the one it continues (§5 identity) — the shape §3.1
makes routine, since a merged-in lineage is emitted right after its merge, so the lane
adjacent to a fork is very often one that *ends at* the fork. The handover above exists
only to put the node over the continuation's wire: the child is evicted, the
continuation claims the column, two rows. Instead the node simply takes the gutter
**where the child already is**, and the continuation converges into it as an ordinary
arm of the fork's own fan-in. Neither handover row is emitted.

**No lookahead is involved.** The sweep runs top to bottom, so when a fork is reached
the gutter's occupant is already decided; unlike the parent swap, the whole condition
is a fact about the current row. **Three clauses:**

1. **The occupant is one of this commit's own converging children**, not an unrelated
   **pass-through** lane. A pass-through draws a through-vertical in the gutter, so a
   node placed over it would put two Lanes' verticals in one cell and read as the
   commit sitting *on* an unrelated branch — and the placement would in fact fall back
   off the gutter, spending a node-in-gutter row (this policy's whole purpose) to save
   two Lines. A pass-through is evicted, as before.
2. **It is not the lane the commit continues.** If it is, no handover was going to be
   paid and there is nothing to swap.
3. **No parent swap is also available on this row, unless the fan-in has a Line of its
   own** — see the composition rule below.

**What it costs depends on where the fan-in is drawn, and only one case costs a break.**
With a **separate split Line** (§5.2) the child terminates up there as a bare stub and
the descent into the node carries the commit's **own** Lane, so the wire above the node
and the wire below it are one Lane: the spine is intact and **nothing is licensed
because nothing is broken**. The trunk's travel to the gutter is an ordinary fan arm on
a fan Line, which §5.1 permits. With a **fully inline fan-in** the fan shares the commit
Line, so the child's stub *is* the node's wire from above: the node's column carries a
different Lane above than below — a licensed break, priced 1:1 in the two rows it
removed. There the node needs no colour adjustment (unlike the parent swap): a Column's
colour comes from its downward wire (§5), which here is the first parent — its own Lane.

The licence is bounded exactly as the parent swap's is, and earned on **its own** row
rather than the next one:

> A commit's node cell may carry a converging child's Lane above it and its **first
> parent's** Lane below it **only** at a fork where this swap fired, and **only** if
> the row emitted **no handover Line** — no eviction and no claim. A break on a row
> that paid its handover anyway saved nothing and is a defect.

**Composing the two swaps.** A commit that both forks and merges (§10.4's both-fans
case) can satisfy both gates. With a separate split Line they **compose**: they touch
opposite sides of a node cell whose wire from above is still the commit's own Lane, so
this row pays no handover *and* the next subject row pays none either, and it is the
parent swap's licence that applies, unchanged. With an inline fan-in they **cannot**:
the cell would hold a foreign child above and a non-first parent below — the commit's
own Lane on neither side — which no licence prices and which could not even be coloured
from its own Lane. The **parent swap wins** there; it saves the same two rows (on the
next subject row instead of this one) and keeps the node's colour, so the split swap
declines. Getting that precedence backwards is not free: on a 1040-commit repository
expanded, 69 of the 85 parent swaps sit on exactly such a row, so blocking them costs
about as many rows as the split swap saves.

**What it buys, measured** over the same 1040-commit repository fully expanded, at
split-on-its-own-line (against the parent swap alone):

| | parent swap only | + the split swap |
|---|---|---|
| crossings | 512 | **285** (−44.3%) |
| rendered Lines | 1423 | **1251** (−12.1%) |
| ink (glyph cells) | 6339 | **5286** (−16.6%) |
| handover Lines | 275 | **103** (−62.5%) |
| mean / max width | 3.93 / 11 | 4.25 / **10** |
| node-in-gutter (subject rows) | 0.990 | 0.990 |
| within-sweep lane stability | 0.922 | **0.950** |
| licensed spine breaks | 85 | 85 (**no new break** on this style) |

`tests/large_topo` expanded: crossings 172 → 100, handover Lines 74 → 32, max width
11 → 10. The mean width **rises** while the max width falls and the total number of
drawn cells falls 5%: the Lines removed were narrower than average, so this is the mean
moving rather than the graph widening. On a **fully inline** fan-in the same repository
gives crossings 512 → 399, handover Lines 275 → 241 and 16 new licensed breaks — 1
break per two rows saved, the same price as the parent swap's.

In the **focused** (default) view: **nothing changes at all**, on either fixture and at
every merge style. The reason is structural rather than a further clause: §3.1's lineage
grouping keeps consecutive subject rows on one lane, and every branch that is not an
anchor contracts to a `◍` head, which claims no gutter (above) — so the gutter at a kept
fork is already the trunk's own and clause 2 declines. Measured: 0 fires over the whole
focused corpus, and 0 differing over 20,651 cell-for-cell signature Lines.

**The node keeps its own lane's colour.** A Column's colour normally comes from its
downward wire (§5), which is a stand-in for "the node's own Lane" — exact wherever
the spine is continuous. At a swapped merge it would name the *arriving branch*, so a
merge on the trunk would render in the colour of the topic it merged: mechanically
the same misreading as the fork-hub defect above. So a swapped node's cell is marked
to take its colour from the wire **above** — the Lane its first parent continues, its
own. The trunk keeps its colour through the merge and the topic lane simply *begins*
below it, which reads as "a new lane starts here" rather than "the trunk was
renamed". The mark is set only on a swapped node, so no other cell's colour changes
under any policy.

**What it buys, measured** over a 1040-commit repository fully expanded, at
split-on-its-own-line (against the same policy without the rule):

| | baseline | with the swap |
|---|---|---|
| crossings | 598 | **512** (−14.4%) |
| rendered Lines | 1593 | **1423** (−10.7%) |
| ink (glyph cells) | 7229 | **6339** (−12.3%) |
| handover Lines | 445 | **275** (−38.2%) |
| mean / max width | 4.04 / 11 | **3.93** / 11 |
| node-in-gutter (subject rows) | 0.990 | 0.990 |
| within-sweep lane stability | 0.912 | **0.922** |
| licensed spine breaks | 0 | 85 (each saving one handover) |

`tests/large_topo` expanded: crossings 197 → 172, 11 breaks for 11 handovers. In the
**focused** (default) view: nothing changes at all, on either fixture.

**The general rule this is an instance of.** Two horizontal runs may share cells
on a Line only when both are arms of the **same fan of the commit on that Line** —
both converging children, or both diverging parents. A run belonging to one fan
sharing with a run of the other, or with any lane that is not incident to that
commit, is a defect regardless of policy. Repositioning moves — the gutter
handover above, and anything like it a future policy adds — therefore get rows of
their own rather than borrowing a commit's.

**Colour and identity are the same under this policy as under every other.** Lane
identity is chosen from the DAG and the row order alone (§5), so constraining columns
cannot change it: the same history renders the same lane ids and colours under
`compact` and under `gutter`, differing only in where each lane is drawn. That is a
guarantee, asserted across policies, not an accident — and it is what makes `C` a
comparison tool rather than a repaint.

Three consequences worth stating:

- **The gutter belongs to the row being read, and nothing may take it
  opportunistically.** A commit's first parent continues in the gutter, and the only
  parent that may take it instead is one the **parent swap** hands it to (above) —
  which is not opportunism but an exchange: the swap fires only where the next
  subject row is that parent, so it replaces a handover rather than borrowing a
  column, and the node still shows its own Lane's colour. The unconditional version
  *was* once the rule, and was a bug: at a merge the parent starting the merged-in
  lineage was placed straight into the gutter as part of the merge's own fan-out,
  which looked free (a lane is born there, no wire moves) and was documented as a
  bonus. Because a node's colour is read from its cell's downward wire, the merge
  rendered in the **lineage's** colour and a merge on the trunk read as the topic
  branch it merged. The difference is the gate and the colour rule, not the geometry:
  an ungated swap is still that bug, measured at 62 of 62 merges in the default view
  for no saving at all.
- The gutter may be **briefly empty**, between a run ending and the next lane
  turning in. It renders blank; nothing else may take it.
- The **root column break** (§5.1) applies unchanged. A root sitting in the gutter
  ends its lane with a bare vertical stub, so the gutter is blocked for the
  following Line and the next subject row's node falls on its own lane instead.
  That is the only case where a subject row's node is not in the gutter, and it is
  the invariant working, not an exception to it.

**Where the crossings and the extra rows are.** The §5.1 no-crossings corollary
holds on commit Lines (above) — the cost moved onto the handover rows rather than
vanishing. Each handover row carries **exactly one** horizontal wire, in one
direction, with nothing else turning on it, and that wire crosses whatever lanes
lie between the gutter and the lane's own column. So this policy converts
*distance* into *crossings* and *rows*, and concentrates both on the rare handover
rows instead of spreading them over every row.

**The costs, measured** over gitloom's own projected history (`tests/large_topo`)
and a 1028-commit real repository, against `compact` (the default):

| | large_topo focused | large_topo expanded | real repo focused | real repo expanded |
|---|---|---|---|---|
| subject rows with the node **adjacent** | 98.9% → **100%** | 40.4% → **99.8%** | 88.6% → **100%** | 8.2% → **99.0%** |
| mean node-to-message distance | 0.51 → **0.00** ch | 15.73 → **0.03** ch | 0.23 → **0.00** ch | 21.37 → **0.05** ch |
| rows carrying a horizontal | 14.6% → **10.4%** | 7.6% → **12.3%** | 68.1% → **56.0%** | 26.5% → **34.6%** |
| crossings | 160 → **202** | 160 → **888** | 1179 → **1109** | 1323 → **3438** |
| ink (glyph cells) | 2068 → **2102** | 8751 → **10319** | 8319 → **8396** | 22578 → **29802** |
| rendered rows | 335 → **336** | 661 → **715** | 392 → **393** | 1135 → **1400** |
| max graph width | 54 → **54** | 54 → **54** | 60 → **64** | 60 → **62** |

The table predates two later changes, both of which move only the **expanded**
figures and neither of which touches a focused view:

- evicting a *converging child* that holds the gutter, not only a survivor, which
  buys the spine guarantee at the price of the handover rows those forks were
  previously skipping: **+5.9%** (`large_topo`) / **+12.1%** (a 1040-commit
  repository) rows fully expanded, on top of the figures above;
- the **parent swap** (above), which then takes most of that back — on the same
  repository expanded, rendered Lines −10.7%, crossings −14.4%, ink −12.3%,
  handover Lines −38.2%, and `large_topo` crossings 197 → 172;
- the **split swap** (above), which takes the rest — on top of that, rendered Lines
  −12.1%, crossings −44.3%, ink −16.6%, handover Lines −62.5%, max width 11 → 10, and
  `large_topo` crossings 172 → 100. Together the two swaps put the expanded figures
  back below the pre-eviction ones: crossings 598 → 285 and handover Lines 445 → 103.

Adjacency is unchanged throughout (100% focused, 99.0–99.8% expanded, the residue
being the root column break) — a swapped merge gives away its gutter only to a
parent, never leaving its own node out of it.

**Handover frequency** — the number that governs the design. Counted as subject
rows whose owning lane differs from the previous subject row's: **0.6 per 100
rendered rows** (large_topo focused), 8.0 (expanded), **0.3** (real repo focused),
17.6 (expanded). It is a property of the DAG and the row order, not of the layout,
so no placement change moves how often the gutter changes **hands**. What a
placement *can* change is how many of those changes cost rows: the **parent swap**
(above) absorbs the change into the merge that caused it and the **split swap**
absorbs it into the fork, which is why the two together remove **62%** of the handover
Lines while the handover frequency stays exactly what the DAG says. In the shipping
default view the gutter effectively never changes hands; fully
expanded it changes roughly every fifth subject row, which is where the extra rows
and crossings come from — each handover that is *not* absorbed costs up to two
virtual rows.

So: adjacency goes from 8–99% to 99–100% and the graph is no wider on a narrow
history (up to +4 columns on a wide one). The costs are rows and ink — **+0.3%**
rows / **+1.6%** ink in a focused view, up to **+23%** rows / **+32%** ink fully
expanded — and crossings, which are up 26% (large_topo focused) and 4.5× fully
expanded on that fixture, but **down** 6% on the real repository focused. Two
caveats remain:

- The **`dual` label mode (§6.1) partially defeats it**: row 1 carries the node and
  the labels, row 2 carries the message, so the message row has no adjacent node.
- The **header pane does not follow it** (see below) — and where that is a cosmetic
  difference for the other policies, here the two halves of the screen disagree
  about *where nodes live*, which is far more visible.

It is offered as a policy rather than a default because the comparison is worth
making in the application, on a real history.

`linear` names *what* slides — a linear commit — rather than the move; it is
deliberately not called `slide`.

**Why `compact` is the default, and what it costs.** The default is today's
behaviour, kept so the change is inert until a policy is chosen. Its cost is
measured and should stay visible, because "compaction saves width" is the obvious
intuition and it is **not** what the numbers say: the linear-commit slide never
bought width on any fixture (max |Δ mean width| **0.03 columns**), while on the
default inline style over gitloom's own projected history, dropping it took
within-sweep lane stability from **43.2% to 93.2%**, crossings **−14%** and ink
**−23%**. The visible artifact it produces is the **trunk stepping sideways at
every collapsed feature head**. So a non-sliding policy is a legitimate candidate
for the default, not a degradation; the reason to keep it selectable rather than
delete the slide is that the comparison should be made in the application, on real
histories, rather than settled by fixtures.

**The pane seam is not on this axis.** A context pane's boundary row (§6.2) must
satisfy a stronger requirement — **every seeded lane keeps its seeded column** — so
the pane meets the main view without a jog. That requirement is violated by exactly
the two moves above, so the seam row is laid out by the **no-move** placement
whatever policy the body rows use. Policy × seam is two-dimensional in principle,
and `gutter` is the case that shows why: it must use its **own** chain for the seam
too, because the shared no-move chain does not apply the gutter's column
constraint, so the pane's first row would place its node differently from its body.
Its body chain already satisfies the seam requirement — it moves no lane — so it is
its own seam. For the other four the seam behaviour is shared.

**The footer follows the policy; the header does not.** The footer is a seeded
lane sweep, so its body rows obey the active policy like the main view — with
one exception: under `gutter` the footer is laid out **`straight`**. The gutter's
column constraint exists to line nodes up beside the commit messages, and the
pane draws no messages, so there it would only add handover rows (a turn whose
sole purpose is moving a lane into the gutter column, e.g. the trunk above its
root). `straight` is the gutter's own no-move base, so every seeded lane still
keeps its seam column and the seam still reproduces the main view's. The
**header** is built by the *direct seam-up grid* (§6.2) — a different layout
routine that never runs the stage chain — so its rows are unaffected by the
policy, and a `straight` graph keeps a `compact`-style header. This is correct
per §6.2 (the header is a rebuild of a focused sub-DAG, not a continuation of the
sweep), but it is visible when comparing policies and is called out here so it
does not read as an inconsistency. Bringing the header onto the policy axis would
mean expressing the seam-up grid as a stage chain — not planned. **Under `gutter`
this caveat is much louder** than for the other policies: the header's nodes sit
wherever their lane falls, while the main view keeps the current lane pinned to
the gutter — so the seam is not a subtle difference in compaction but a visible
disagreement about where the graph's spine is.
It is a known limitation of offering `gutter` as a policy, not a defect in either
routine.

**Reserved columns cut across the axis.** A **dedicated column** held for a
pinned branch (§10.6.2) is not a policy: it is occupancy (§5.1), so every policy
respects it and none of the four is exempt. What varies with the policy is only
how much work it does. Under `straight` no lane ever moves sideways, so a
reservation is a **birth-placement constraint alone** — the reserved column is
simply never chosen for anyone else's new lane. Under the three policies that
move lanes it is additionally a **barrier the moves stop at** (§5.1's guard).
The reservation itself is enforced at birth and by "not compacted away", never
by jogging an already-placed lane rightward into its column — compaction's
redraw is leftward-only, and a rightward jog has no redraw to produce.

**The pre-pass.** A policy may declare a once-per-sweep `prepass` computing hints
the top-to-bottom sweep cannot see, since it would have to look forward. It is a
pure function of `(opts, items)` whose result is threaded onto each row, so
nothing is written back onto the caller's items. **`gutter` uses it**: the parent
swap's three clauses are all forward-looking — which commit owns the *next* subject
row, each parent's row index, and how many in-set children a parent has — and none
of them is knowable from the current row alone. Reading them does not let a fan-out
claim the gutter *early*, the move the identity rule forbids: the swap only chooses
which of **this** commit's parents continues in the column this commit's node
already occupies. The hook is also what the reserved `interval` placement (below)
will use, for lane lifespans.

**Reserved: `interval`.** The name is reserved for a future "straight branches"
placement that assigns columns from forbidden intervals over precomputed lane
lifespans (an `O(N)` pre-pass, the same hook), replacing the §5.1 **fan-out
placement** rule rather than the compaction moves — which is why the enum is flat
and why that rule is filed on its own axis. It is not specified here.

## 6. Row content

A commit row displays, left to right:

1. author date — formatted from the `Timestamp` (§4) either as an **absolute**
   author-local time (via the configurable `date_format`, default
   `%Y-%m-%d %H:%M`) or as a **relative** age (e.g. `3 days ago`). The
   `date_mode` selects which; `d` toggles it live.
2. author name
3. graph lanes (glyphs)
4. commit subject (the message)
5. ref decorations — placed by the **label mode** (§6.1); by default pinned to
   the **right edge** of the row

The date, author, and graph are width-aligned across visible rows. To avoid the
aligned widths **bouncing** as different-length values scroll past, a column can
be *sticky* — it only grows, never shrinks: the **author** column is sticky with
a cap (max 25, longer names truncate), and under mirroring (§5.4) the **graph**
column is sticky too (its right-aligned content would otherwise shift as the lane
width changes). The message and refs share the remaining width **per row** (not as
a fixed aligned column, so navigation stays line-by-line): in the default mode the
refs are right-aligned at the window edge and the message fills the gap, truncated
with `…` when it does not fit.

**Ref decorations** — branch groups, then tags as `[name]`, then worktree
labels as `{wt:<dir>}` (§4.1). The bracket carries the kind, as it already does
for branches and tags; the `wt:` prefix keeps the label self-describing without
colour. **HEAD always reads as `HEAD`, and its label comes first.** On a
branch, the **current branch's** group is drawn as one label
`(HEAD → name …)` — the `HEAD → ` prefix in the **HEAD colour**
(`palette.head`), the rest in the label colour (below) — and it is moved to the
**front** of the row's labels; on a
**detached HEAD** (no current branch, §3.2) the checked-out commit carries a bare
`HEAD` label, also first. Being first, HEAD is the label the `+N` overflow
(below) never hides while no ref is selected — "you are here" is always on
screen. The attached label is still the branch: selecting it selects the current
branch (its owners, §10.4; its checkout, §10.4.1). The detached `HEAD` label is
not selectable (there is no ref behind it to act on). Branch refs (local +
remote) that share a **short name** collapse into one group: the name is shown
once, followed by the remotes that also point at this commit, as
`(name ↑remote1,remote2)`. A local branch with no matching remotes is just `(name)`. This
keeps the common case (a branch plus its remote-tracking copies all at one
commit) from repeating the name per remote. A label whose ref is a **pinned
anchor** (§10.6 — the effective pin set, so the default anchors `master` / `main`
/ `dev` and a pinned local branch's implicit remote counterparts count too) opens
with the **pin icon**
(`icons.pin`, default `⚲`, §8) inside its bracket: `(⚲dev)`,
`(⚲release/2.1 ↑origin)`, `[⚲v1.0]`, `{⚲wt:review}`. A branch group is marked
when any ref in it is pinned (its local branch, or one of the listed
`remote/name` refs — so a remote-only group is marked when its refs are the
implicit counterparts of a pinned local branch at another commit). **HEAD's
label never carries it** — neither
`(HEAD → name …)` nor a detached `HEAD` — although HEAD (or its branch) is always
an anchor: HEAD is already marked by its first place and colour. The icon is part
of the label's text, so the width budget, the `+N` windowing, the `h`/`l`
selection and the cursor parking (§2) all measure the label as drawn; packed
marker labels (§10.4) and the context panes' labels (§6.2) carry it too. It
follows the pin set live (`P`, the dialog §10.6.1, a resync), and
`icons.pin = ""` turns it off. A local branch that **tracks an
upstream** also carries a terse divergence indicator (`⇡N⇣M` / `gone`), and —
when that upstream is not the same-named branch on its remote — the upstream
spelled out before it (`→origin/dev ⇡4⇣6`) — see §6.3. Note the `↑remote,…` list
is *which same-named remotes sit at this commit*, not *what the branch tracks*.

**Expanded marker.** A label whose ref is **expanded** opens with the
**expanded icon** (`icons.expanded`, default `▾`, §8) inside its bracket, after
the pin icon when both apply: `(▾feature/x)`, `(▾fix/y ↑origin)`, `[▾v2.0]`,
`{▾wt:review}`. A ref is *expanded* when its owner's **effective** mode is
**normal** (§10.1) while its **default** mode (§10.7) is **collapsed** — that is,
the user opened it (`<Space>` on its `◍` head, the palette's expand, a filter
jump §16.4, a §11.7.6 reveal). It marks exactly the refs that keep their rows
open *by the user's choice*, so on a row carrying several heads the one that
holds the branch open reads at a glance. `<Space>` (§10.4) on a row collapses
the row's own refs, so their `▾` go even when the row stays open. What still
holds the row open is then a branch built on top, which keeps its `▾` on its own
tip row (and `<Space>` names it). The rule is about
**deviation from the default**, so:

- an **anchor** (§10.6) — pinned, a default trunk, an implicit counterpart, HEAD's
  branch — is never marked: its default is normal, and the pin icon / the HEAD
  label already say why it is open (and that `<Space>` will not fold it);
- with the first-parent focus **off** (`collapse_merged = false`, `c`) every
  default is normal, so nothing is marked;
- a ref that is collapsed or hidden is not marked; a `◍` head's labels
  (§10.4), whose owners are all collapsed by definition, never are.

A **branch group** is marked when any ref in it is expanded (as for the pin
icon). **HEAD's label never carries it** — an attached HEAD's branch is an anchor,
and a detached `HEAD` label is not a ref label. Like the pin icon it is part of
the label's text — the width budget, the `+N` windowing, the `h`/`l` selection
and the cursor parking all measure it — it is drawn in the label's own colour (no
separate highlight, so lane ownership, dimming and `palette.selected` apply
unchanged), it appears in every label mode (§6.1), on packed marker lines and in
the context panes (§6.2), and it follows the view state live (every reflow).
`icons.expanded = ""` turns it off.

Anonymous owners (§10.2 — merge parents, uncovered tips) carry no label, so an
expanded one cannot be marked on its row; the palette's collapse entry (§10.4)
names it instead.

**Label colour.** A node's **lane colour** — exactly the colour its node glyph gets
(§5, §12.2): the cell's top Segment's palette slot, including a `gutter`
parent-swapped node that takes its colour from the wire arriving from above (§5.6),
and a collapsed `◍` head's or a labelled junction's `◍` colour — goes to **one**
label on the node: the label of the ref that **owns** the lane. Every other label on
the node is drawn in its **per-kind** colour (`palette.branch` / `remote` / `tags` /
`worktree`, the current branch's whole label in `palette.head` — what
`lane_label_colors = false` gives), so a label only reads as belonging to a lane
when the lane is its own.

The **owner** is decided per node, in two steps:

1. **The ref the lane was born for.** If the node's lane colour is the **pinned
   colour** (§5.5) of a pinned ref pointing at this node — rank `k`, slot `k` — or
   the **counterpart colour** `-k` of an implicit remote counterpart pointing at it,
   that ref's label owns the lane. A pinned colour is withheld until its ref's tip
   (§5.5), and only a counterpart lane carries `-k`, so this is exactly "the lane
   was born here for that ref" (a birth at a pinned or a counterpart tip, §5, or a
   pinned branch's own tip lane) — read off the colour, so the panes, which carry
   the main view's colours (§6.2), agree without any layout data. A pin past the
   curated palette has no pinned colour, and falls to step 2.
2. **Otherwise the first label** in logical order: the current branch's group (the
   `(HEAD → x …)` label), then the other branch groups, then tags, then worktree
   labels. A detached HEAD's bare `HEAD` marker is never an owner candidate (it is
   always `palette.head`) — and that holds when the lane was born for a pinned
   detached `HEAD` (step 1) too: since the `HEAD` label can never show the lane
   colour, ownership passes to the **first other label** on the node (this step), so
   a branch sitting on a detached HEAD reads in its lane's colour. With no other
   label, no label carries it.

A **branch group** (a local and its `↑remote,…` list) is **one** label: it owns when
any of its refs does, and then the whole label takes the lane colour — brackets, the
pin icon, the name and the remote list. A remote's default-branch symref
(`origin/HEAD`) is never a label (§3.2), so it can never take ownership from the
branch it points at. So on a commit carrying `origin/dev` (the counterpart of a
pinned `dev`, whose counterpart lane is born there), `origin/HEAD` and
`origin/feature`, only `(dev ↑origin)` shows `dev`'s dimmed counterpart colour;
`(feature ↑origin)` is in the remote colour. A counterpart in sync with its local
sits on the pinned lane, in its local's group, in full colour.

Three things keep their own highlight on every label: the **HEAD marker** (a
detached `HEAD` label, and the `HEAD → ` prefix of the current branch's label) stays
in `palette.head`, even though HEAD's node glyph is itself drawn in `palette.head`
(§5.3) — the branch name after the arrow takes the lane colour when it owns; the
upstream tracking tokens — the spelled-out upstream and the divergence — keep
`palette.track` (§6.3); and a ref carrying its own
colour (a submodule pointer mark, §11.7.6) keeps it. The `h`/`l`-**selected** label
(§2) still draws in `palette.selected`. On a **packed marker row** (§10.4) each
marker is its own node, with its own owner among its labels and *that marker's* node
colour (a non-owner marker label is `palette.branch`); in the **context panes**
(§6.2) a pane row's node colour goes to its owner the same way. The ref **kind** is
carried by the bracket — `( )` branch, `[ ]` tag, `{ }` worktree — and `↑` for
remotes. `lane_label_colors = false` (§8) gives every label its per-kind colour.
Out-of-cone labels dim like their lane (§12.2), owner or not.

**Ref width budget.** The refs use the row's free width: they may take
everything the message does not need — its natural width, but never reserving
more than `message_min` (§8). So refs fill empty space when the message is
short, while a long message still keeps at least `message_min` columns
(truncated with `…`). Each field is colored by its `palette` highlight group;
lanes are colored by a palette slot allocated from a recycling free list (§5.5).

**Overflow is windowed around the selection.** With **no ref selected**, labels
are shown in order (leftmost first) until the budget is reached and the rest
collapse into a trailing `+N` overflow marker. When a ref **is** selected (via
`h`/`l`, §2, or the picker, §2), the visible labels form a **window around the
selection** sized to the budget, so the selected label is **always visible** and
highlighted; labels hidden before and after the window collapse into **separate
`+N` markers on the left and right** (e.g. `+2 (feat) (master) +3`). Moving the
selection scrolls this window to keep the selected label in view. Labels are
always shown **whole** — a label that does not fit is hidden into a `+N` marker,
never partially drawn. The one exception is the **selected** label when it alone
is wider than the line: it is brought into view and **truncated with `…`** (since
it must stay visible), the only case a ref is truncated. This windowing applies to
the right-pinned (`right`) mode and to **packed marker rows** (§10.4), where the
labels are left-aligned after the graph but window the same way around the selected
marker; `inline` and `dual` (§6.1) keep their flex-column `…` truncation.

### 6.1 Ref label modes

How a row's ref decorations are *placed* is selected by `label_mode` (§8) and
cycled live with `B` (the footer shows the active mode). The grouping and the
selectable order (branch groups then tags; the current branch coloured as HEAD,
§6) are identical in every mode — only the placement differs:

- **`right`** *(default)* — refs are pinned to the **right edge** of the commit
  line and the message fills the gap, with the width budget and `+N` overflow
  above. This is the layout the rest of §6 describes.
- **`inline`** — refs are rendered **left-aligned immediately after the graph,
  before the message**, on the commit line (branch first, then the subject).
- **`dual`** — a labelled commit is drawn on **two real rows**: the **first row**
  carries the graph (with the commit's node) and the **ref labels** left-aligned
  after it; the **second row**, directly below, carries the commit **message**,
  with the graph's lanes continued downward as vertical wires (the same lane
  layout, with **no node placed** on that row). The two rows are tied by a
  **pair bracket** in a prefix of the flex column: `┬` directly before the labels
  on the first row (marking it as the commit's main row), `└` directly before the
  message on the second — no gap, so `┬(main)` / `└fix the thing` — in
  `palette.pair` (default `NonText`; `false` leaves the prefix blank — same
  width, so the alignment is identical). The prefix is exactly the configured
  `dual_bracket` strings (§8), so a trailing space there restores a gap. The
  labels and the message are therefore both indented by the bracket's width from
  the graph edge, so the pair reads as one unit rather than the message as a
  commit of its own. The prefix sits inside the flex
  column, so the date / author / graph columns of every other row keep their
  widths and alignment. Like the other row fields it dims with the row outside
  the reachability cone (§12). The prefix is on the graph side in both
  orientations — under mirroring (§5.4) the labels and message are still drawn
  after the right-aligned graph, so the bracket still opens toward the graph just
  as in the unmirrored layout. Only commits that actually have
  ref decorations get the second row; a commit without labels stays a single row
  (node + message, as in `right` without the right-pin). Both rows are real buffer
  lines and belong to the same commit: navigation (§2) treats them as two rows of
  one commit — `<CR>`/`D` act on that commit from either row, and reachability
  (§12) dims both together. The cursor parks on the **labels** on the first row
  (landing on a labelled commit pre-selects the first label, so `h`/`l` refine it)
  and on the **message** on the second row. The two rows stack with the virtual
  lines (§5 *Line*) as: every above-line in order (the §5.2 split fan-in, and any
  handover rows the layout policy added), label row, message row, merge line
  (fan-out).

In every mode an out-of-cone row dims its refs with the rest of the row (§12),
and a selected ref is drawn with `palette.selected`. The **context panes** (§6.2)
render every row topology-only, the same render style as markers (§10.4).

### 6.2 Context panes (header / footer)

The graph window may carry two **context panes** — a **header** above the main
viewport and a **footer** below it — that summarise the topology *off-screen* in
each direction so the main branches stay in view while scrolling. They are
**read-only**: no cursor, no selection, no navigation; they are a map, not a
surface to act on.

**One projection, three viewports.** The header, main view, and footer are three
windows onto a **single** laid-out projection (§10), not three independent
layouts. The header renders the rows *above* the main viewport's top line, the
footer the rows *below* its bottom line (down to and including the **root
commit(s)**). Because it is one lane sweep, lanes are continuous across both
boundaries by construction — the main view's top row *is* the header's bottom
row.

A pane has **height 0** (is hidden) whenever there is no off-screen topology in
its direction: the header vanishes when scrolled to the top of the graph, the
footer when scrolled to the bottom (the roots are then already on-screen). "At
the bottom" is measured in **screen rows**, virtual split/merge lines included:
the footer is hidden whenever the graph's last rendered row is visible — the last
commit at the window's bottom row (after `G`), or a graph shorter than the window
with empty filler rows below it. This falls out of the sizing rule below (`G = 0`
at the extreme). Both are also hidden
when the repository has **no HEAD commit** (empty) — but a **detached** HEAD is an
anchor like any pinned branch (§10.6), so the panes show on it exactly as on a
branch, folding toward the checked-out commit.

**What they show.** Panes render **topology-only** (§10.4): graph glyphs and ref
labels only — no date, author, or message. The labels read as in the main view
(§6): HEAD's label — `(HEAD → <branch>)` or the detached `HEAD` — first, its
HEAD marker in the HEAD colour, and the label owning its pane row's node lane in
that lane's colour, the others per-kind (§6 "Label colour"). Off-screen topology is folded onto
the **pinned anchors** (§10.6): an anchor's line is drawn; everything else is
contracted.

**Boundary lane-continuity (invariant).** Every lane crossing a viewport
boundary **must** connect to something in the pane — no lane dangles at the edge.
A region that *touches* the boundary is therefore never folded away; its crossing
lane is preserved and terminated explicitly. This is the "wires must connect"
grid invariant (§5.1) lifted to the window edge. It is also stronger than anything
§5.1 asks of a body row — **every seeded lane must keep its seeded column**, or the
seam jogs — so the seam row is laid out by the **no-move** placement regardless of
the layout policy (§5.6) the body rows use. The footer's body follows the main
view's policy, except that under `gutter` it is laid out `straight` (§5.6): with
no messages beside it, the gutter column would only add handover rows.

**Panes do not honour dedicated columns.** A column **reserved** for a pinned
branch (§10.6.2) is a main-view placement rule; neither pane applies it. The
footer is a seeded sweep whose seam must reproduce the main view's boundary
columns *exactly*, so holding an extra column there would jog the seam — the
very thing the invariant above forbids. The header never runs the column sweep
at all (it is the direct seam-up grid below), so a reservation would have
nothing to constrain. The exemption is deliberate: the boundary invariants in
this section are unaffected by reservation, and a pane whose columns differ from
the main view's for this reason is not a seam violation.

**The minimal connecting subgraph.** A pane is a **focused rebuild**, not a
reduction of the whole off-screen graph. The header shows **only how the pinned
anchors relate to each other and to the lanes crossing the cutoff** (the "seeds") —
the smallest graph that connects those endpoints. The build is a reachability over
the **display** DAG (the projected nodes the main view shows), **up-only** (toward
children/newer):

- **Seeds** are the lanes crossing the cutoff (each boundary column is its own seed,
  carrying its **lane id**) plus the pinned anchor tips.
- Each crossing lane is **followed up by its lane id** — the stable rendered-lane
  identity from the main graph, *not* a first-child guess (in the projected DAG the
  first child is unreliable) — to where it ends: its own tip (a **head**) or a point
  where it **merges** into another lane. Two lanes that converge merge into one,
  drawn as a node-less junction. **Merges are always kept** — lanes connecting is the
  useful, legible case.
- A **split** — a fork where a *new* lane diverges off the one being followed — is
  drawn **only if that diverging lane is a *tracked* lane** (matched by **lane id**):
  a lane crossing the seam, or a pinned anchor's lane. Equivalently, the header keeps a
  junction only where **≥2 tracked lanes meet** — two seam lanes converging, a seam
  lane merging into an anchor, or two anchors diverging / rejoining. A fork onto any
  *untracked* lane — an unpinned feature branch's own lane — is **dropped**: the
  followed lane simply continues past it as if the fork were not there. ("Leads up to
  an anchor" is too weak — followed upward, *every* branch eventually reaches the trunk,
  so it would prune nothing; the test is "*is* a tracked lane".) So the header never
  fans out into the merge/fork plumbing of every feature branch that touched the trunk
  off-screen — the back-and-forth crossings that make a busy header unreadable.
- A **parallel-merge declutter** resolves the remaining redundant case: when two
  crossing lanes both fork up to the **same two children** — e.g. a trunk-merge and a
  collapsed head each merging the same two lanes (a 2×2 "parallel merge") — drawing all
  four edges crisscrosses the header with rake arms. The header resolves it to a
  **matching**: each child keeps its **first-parent** edge and drops the redundant
  cross-arm *when the other parent stays connected through its own child*, so the two
  crossing lanes render as clean **parallel lanes**. A genuine confluence — where the
  dropped parent has no other child and would be orphaned — is preserved.

So the header is the anchors' spines, the **merges** where crossing lanes join them
(or each other), and the splits that lead to another anchor — plus every other
crossing lane drawn straight up to its bare head. An unpinned branch that forks off
the trunk and reconnects to nothing — a stray feature head — **never appears**; a
feature branch that merges back into the trunk is shown as that single merge, not as
its whole sub-tree. (When anchors genuinely interconnect off-screen the header can
still grow; it is capped with a `+N above` overflow.)

**Virtual commits never appear in a pane.** The working-tree virtual commits
(§4.2) are the live state, not topology; the header's up-walk stops before
reaching them, so the topmost **real** commit (typically HEAD) is the highest
head the header draws. When the only off-screen-newer content is virtual, the
header is hidden. (The footer walks *down* toward the roots, so virtual commits —
always above HEAD — never reach it.)

**Lane termination.** Every crossing lane is *continued* until it ends at real
topology — never arrow-capped:

- it ends at a **head** — drawn as a `◍` collapsed marker — either at its own tip (an
  isolated crossing lane, drawn continuously up from the seam to where it terminates)
  or where a dead-ending confluence caps;
- or at a **junction** — the merge/fork where it joins another lane, drawn as a
  **node-less 3-way crossing** (box-drawing only, no commit glyph).

Pinned **anchors** keep a labelled row (the anchor's spine, tip → seam); every
other head is a **bare `◍`** (no label). A **divergent** anchor — one whose tip is
ahead of the trunk so its lane never crosses the seam and the up-walk never reaches it —
is **connected down its own first-parent spine** to the trunk (the already-built part),
so it relates to the trunk visibly instead of floating as a stray labelled head. (A
truly disconnected anchor — a separate root nothing reaches — still shows as a lone
labelled head.) A **linear run** (a
lane stretch with no head, junction, or anchor on it) costs **zero** rows — it is pure
vertical continuation. This is the same "wires must connect" grid invariant (§5.1)
lifted to the window edge: no lane dangles, none stops in mid-air.

**Colour.** Each lane is drawn in **its own colour — the same colour the main view
gives that lane** (§5.5), so a branch reads identically in the pane and the graph
and forking branches are visually distinct. A fork's mainline continuation keeps the
incoming lane's colour; each *extra* fork child takes its own. (A pane that drew
every branch one colour would read as a single discontinuous tangle.) Where two lanes
alive together arrive sharing a main-view colour (the main view recycles colours),
the header gives one of them a different colour, and that replacement is never a
**pinned colour** (§5.5) — a pinned branch's colour stays its own in the pane too.
A counterpart lane (§5.5) keeps its main-view counterpart colour in the header, light
dim included. The footer's seeded sweep obeys §5.5 directly: a seed holding a pinned
colour takes its reservation over, a seed holding a counterpart colour is one more
holder of that slot, and a pinned tip or a counterpart tip born inside the footer
takes its pinned or counterpart colour.

**Reachability emphasis (§12).** When reachability emphasis is on, the panes dim
out-of-cone topology exactly like the main view: a pane lane (and its labels)
keeps full colour when it is in the pivot's cone and is blended toward the
background (`palette.dim`) when it is not. A pane reads as one continuous picture
with the graph — a branch lit in the main view stays lit where it continues into
the pane, and a dimmed one stays dimmed.

This costs **`O(pane)`**, not a walk of the off-screen graph. Cone membership
inside a pane is fully determined by **which seam-crossing lanes are in-cone**,
then propagated by a directed reachability over the pane's *own* (already-built,
condensed) graph: **down** (toward parents/roots) for the footer, **up** (toward
children/tips) for the header. This is sound because the cone is monotone — every
parent of an in-cone commit is in-cone and every child of an in-cone commit is
in-cone (§12.1) — so everything the footer draws below an in-cone crossing lane is
a pivot-ancestor, and everything the header draws above one is a pivot-descendant.
A confluence where an out-of-cone lane joins an in-cone one is in-cone from the
join onward (the meeting node is a parent/child of an in-cone node), which the
propagation captures for free.

This obeys the same **boundary-as-source-of-truth** invariant as layout: a
crossing lane's lit/dim state in the pane **equals** its state at the main view's
edge — the seam agrees in colour *and* emphasis. The emphasis tracks the cursor
(the seam crossing-lanes' cone state is the main view's own, recomputed as the
cursor settles, §12.2); because it is a per-pane repaint of the existing rows, not
a rebuild, it does not depend on a scroll. When emphasis is off (`H`), panes
render at full colour like the rest of the view.

**Packing.** Bare-`◍` heads (the unpinned tips) are **packed** onto as few rows as
possible — multiple `◍` share a row wherever their columns don't collide (the §10.4
marker-overlay rule), so a busy common-ancestor fork is a handful of marker rows, not
one row per head. **Pinned anchors and junction rows are never packed** — each keeps
its own line so the anchors stay legible.

**Sizing.** Panes are **content-driven within a cap**, computed so the size is
stable (no scroll-induced bounce, §6 sticky principle):

- **Header.** From the seeds the header rebuilds the **minimal connecting subgraph**
  (above) by the two reachability passes, then condenses linear runs and lays the
  result out by a **direct seam-up grid**: the bottom row is seeded *from* the
  boundary (so its lanes line up with the main view's top row *by construction*), and
  rows are built upward from there. Height is found by a **min-fit search**: guess
  `H = (#pinned tips above the cutoff) + 1`, build, and grow `H` by one — re-deriving
  the cutoff at the new height each round — until the rows fit. To avoid the main
  view's height twitching, `H` **grows immediately but shrinks only on settle**
  (debounced), the same anti-bounce rule as sticky columns; the tip is pinned at the
  top so growth happens at the bottom. When the fold
  exceeds `header_max`, the surplus collapses into a trailing **`+N above`**
  indicator (the tip + the seam-nearest rows are kept). The header **vanishes**
  entirely when the view is already scrolled to the top (nothing off-screen above).
- **Footer.** The footer anchors to the main view's *bottom* line, which floats
  with the main height, so its size is a mild fixed point; it is resolved by
  reserving a **fixed** footer height (the footer is small — roots plus a few
  anchor tails) or, if made dynamic, by monotone iteration to `footer_max`.

**Asynchronous update.** Pane content is recomputed **off the main render path**:
a scroll or view-state change schedules a debounced pane rebuild that must
**never block or slow the main view**. The main view scrolls and renders
immediately; the panes catch up (a brief stale pane is acceptable, a stalled main
view is not). The boundary lanes the main view already drew are the source of
truth a pane rebuild must match.

Panes are configurable (on/off, `header_max`, `footer_max`); when off the graph
is the single viewport as today. (`setup()` config is now forwarded to the
command, §8, but the `header_max`/`footer_max` caps are still hardcoded — not
yet read from the options.)

### 6.3 Upstream tracking

A local branch may **track an upstream** — a remote-tracking ref configured as
its `@{upstream}` (`branch.<name>.remote` / `merge`). gitloom reads this
relationship from git directly (`for-each-ref %(upstream:short)`,
`%(upstream)` — the full refname, which the branch sync runs against, §17.2 —
`%(upstream:remotename)` / `%(upstream:remoteref)` — the configured remote and
the branch on it, `branch.<name>.remote` / `merge` — and `%(upstream:track)`); it
does **not** infer it from a shared short name (a branch
named `x` and a remote `r/x` are not assumed to track unless git says so), which
keeps it correct under mirrored/many-remote setups where short names collide.
git's configured upstream is the **source of truth** — gitloom never substitutes
a same-named remote branch for it — but a configured upstream that is *not* the
same-named branch is made **visible** (below), because that is the case where the
`↑remote` list (§6) and the divergence disagree about "the" remote branch.

**Divergence indicator.** A tracked local branch carries a terse indicator after
its name in the ref decoration:

- `⇡N` — **ahead** by N commits (commits the local branch has that the upstream
  does not).
- `⇣N` — **behind** by N (commits on the upstream the local branch lacks).
- `⇡N⇣M` — **diverged** (both).
- `gone` — the upstream ref no longer exists (it was deleted on the remote and a
  prune removed the local remote-tracking ref).
- **in sync** — no indicator (no news is good news).

So `master` two ahead and three behind renders `(master ⇡2⇣3)`; with other
remotes also at this commit, `(master ↑fork ⇡2⇣3)`. The `⇡`/`⇣`/`gone` tokens are
colored by `palette.track` (§8). The indicator is part of the branch decoration
(it is not separately selectable), so the rendered text and the selection/cursor
target stay byte-identical (§2).

**Non-matching upstream — spelled out.** The upstream **matches** when the branch
it names on its remote is the local branch's own name
(`%(upstream:remoteref)` = `refs/heads/<name>`); a local upstream
(`branch.<name>.remote = .`) never matches. A matching upstream renders exactly as
above — the bare `↑origin` already says it. A **non-matching** upstream is spelled
out as one more token, ` →<upstream>` (the glyph is `icons.upstream`, §8), placed **after** the `↑remote,…` list and
**directly before** the divergence indicator it qualifies:

- `(enne/standard-effect →origin/dev ⇡4⇣6)` — tracks `origin/dev`, 4 ahead, 6
  behind it;
- `(enne/standard-effect ↑origin →origin/dev ⇡4⇣6)` — the same, while
  `origin/enne/standard-effect` also sits at this commit (the `↑origin` list,
  §6);
- `(feature →origin/dev)` — in sync with a non-matching upstream (the token stays:
  the mismatch is the news, not the counts);
- `(feature →origin/dev gone)` — its non-matching upstream was deleted;
- `(feature →./dev ⇡2)` — tracks the **local** branch `dev`, written in git's own
  `remote = .` notation so a local upstream is told apart from a remote one at a
  glance.

`<upstream>` is `%(upstream:short)` (with `./` prefixed for a local upstream). The
glyph is deliberately not `↑`: `↑` lists same-named remotes *at this commit*, `→`
names *what the branch tracks*, so the two never read as one list.
`icons.upstream = ""` drops the glyph, leaving the bare name (the token itself is
not optional). The
token is part of the branch decoration exactly like the indicator — not separately
selectable, counted by the ref width budget and the `+N` overflow, identical in
every label mode (§6.1), on packed marker rows (§10.4), in the context panes
(§6.2) and in the `<leader>b` ref picker — and is coloured `palette.track.upstream`
(§8). It does not take the lane colour when the label owns (§6, like the divergence
tokens) and dims with the row (§12.2).

**Same-named remote branch — warning.** When the upstream does not match **and** a
remote-tracking branch of the local branch's own name exists on some remote
(`refs/remotes/<r>/<name>` for any remote `r` — `r` being the remote-tracking
ref's first name component, as for the `↑remote` list, §6 — read from the refs
already loaded, so it holds from the first frame, before the remote list arrives,
with no extra query; a remote's `HEAD` symref never counts), the spelled upstream token is drawn in `palette.track.mismatch` instead
(default the highlight group `GitloomTrackMismatch`, defined with `default = true`
linked to `DiagnosticWarn`, §8). That is the shape where a reader most likely
expects the branch to track `<r>/<name>` and the counts silently refer to another
branch; the palette then offers a one-step **Track `<r>/<name>`** (§17.2). The
text is unchanged — only the colour warns — so selection and cursor targets stay
byte-identical. Without true colour or with a colourscheme that clears the group,
the spelled-out name alone still carries the information.

**Computed against the last fetch.** The ahead/behind counts are git's own,
computed against the **local remote-tracking ref** — i.e. the remote's state *as
of your last `git fetch`*, not the live remote. gitloom never fetches on its own
(§9), so the indicator reflects what is already on disk; the palette's **Fetch**
(§17, which resyncs when it finishes), or a `git fetch` outside gitloom followed
by `R` (resync, §3.4), refreshes it.

The same tracking data drives a current-branch status in the window footer. (It
no longer alone decides which remote refs a pinned branch pins implicitly: those
are its **counterparts** — every remote branch of the same short name, plus the
tracked upstream when its short name differs — §10.6.)

## 7. Rendering behavior

- Rendering is **viewport-driven**: only rows within the visible range are
  laid out and drawn. Scrolling triggers layout of newly visible rows.
- The view updates incrementally as commits stream in.
- The buffer is non-modifiable to the user (`nofile`, read-only).
- The window uses `cursorline` as the current-row indicator and keeps the
  cursor parked at the commit message (or, when a ref is selected, on that ref);
  see §2.
- The pivot's reachability cone is emphasised by dimming everything outside it
  (§12); the cone is recomputed over the visible rows on row change and scroll
  (debounced — see §12).

## 8. Configuration

`GraphOptions` (see [README.md](README.md) for the full default table):

```
GraphOptions = { win, palette, merge_style, layout_policy, icons, branches,
                 sort_mode, mirror, highlight, date_format, date_mode,
                 message_min, label_mode, dual_bracket, diff, working_tree,
                 scrolloff, search, persist, progress, zindex, lane_label_colors }
MergeStyle   = { allow_merge_on_split, merge_on_separate_line, split_on_separate_line }
LayoutPolicy = "compact" | "survivors" | "linear" | "straight" | "gutter"
Diff         = { open: fun(range: DiffRange), label: string }
DiffRange    = { rev: string, from: Endpoint?, to: Endpoint, root: string? }
Endpoint     = Commit | "index" | "worktree"
```

- `win` — floating-window geometry (snacks.win).
- `palette` — highlight group per field, plus a `tracks` list whose entries are
  the curated lane colours, the seed of the recycling free list (§5.5). Lane
  colouring is tuned by `buffer`, the minimum free-list length — the number of
  other colours drawn before a released colour can repeat (default `3`);
  `generate`, whether overflow colours are generated in OKLCH when the curated
  ones run low (default `true`, automatically disabled without truecolor); and
  `anchor`, the lightness/chroma the generated colours are built on (default
  `nil` = derived from `tracks`/`Normal`; §5.5).
  Includes `selected`, the highlight for the `h`/`l`-selected ref decoration
  (§2; default `Visual`); `search`, the highlight for the matched substring in a
  filtered commit's subject (§16.7; default `Search`); `pair`, the `dual`-mode
  pair bracket (§6.1; default `NonText`, `false` leaves the prefix blank);
  `diff`, a sub-table of highlight groups for the
  commit view's diff: `add`, `delete`, `hunk`, `header` (defaults `DiffAdd`,
  `DiffDelete`, `Title`, `Comment`; §11.3); `submodule`, a sub-table of highlight
  groups for the submodule change view (§11.7): `new`, `old`, `base` — the added
  (green), removed (red), and common-ancestor **marker** colours (defaults a
  darker, muted green/red — `GitloomSubmoduleAdd` / `GitloomSubmoduleDel`, defined
  with `default = true` so a colorscheme can override — and the first lane colour
  `palette.tracks[1]`; foreground only, so only the graph markers/lanes are
  tinted, not the commit rows); `action`, the
  highlight for the commit view's diff action label (default `Special`; §11.5);
  `track`, a sub-table of highlight groups for the upstream divergence indicator
  (§6.3): `ahead`, `behind`, `gone` — the `⇡N` / `⇣N` / `gone` tokens (defaults
  `Added`, `WarningMsg`, `Comment`) — plus `upstream`, the spelled-out
  non-matching upstream `→<upstream>` (default `Comment`, the `palette.remote`
  default), and `mismatch`, that token when a same-named remote branch also
  exists (default `GitloomTrackMismatch`, defined with `default = true` linked to
  `DiagnosticWarn`); and `dim`, the
  blend factor (`0`–`1`) toward the window background used to de-emphasise
  out-of-cone rows and lanes (§12; default `0.45`; higher is more muted). On
  terminals without true colour, dimming falls back to a flat `NonText`
  highlight instead. `counterpart_dim` is the lighter blend factor of a remote
  counterpart lane's colour (§5.5; default `0.25`); without true colour a
  counterpart lane is drawn in the plain slot colour. `counterpart_dim_out` is a
  counterpart lane's blend **out of the cone** (§12.2; default `0.75 × dim`, so
  it stays brighter than every other dimmed lane).
- `lane_label_colors` — draw the label of the ref that owns a node's lane in the
  node's lane colour (§6 "Label colour"; the other labels stay per-kind). **Default
  true.** `false` restores the per-kind palette groups for every label. No toggle key.
- `highlight` — whether reachability dimming (§12) starts enabled. **Default
  true.** Toggle live with `H`.
- `branches` — ref argument(s) for `git log` (default `--all`).
- `icons` — glyph overrides: `merge` (the folded merge marker, §5.3; unset by
  default), `head` (HEAD's node, §5.3; default `●`), `pin` (the pinned-anchor
  label icon, §6; default `⚲`), `expanded` (the expanded-ref label icon, §6;
  default `▾`) and `upstream` (the glyph before a spelled-out non-matching
  upstream, §6.3; default `→`). `""` turns `head` / `pin` / `expanded` off;
  `upstream = ""` only drops the glyph — the upstream name stays.
- `sort_mode` — the initial **row sort mode** (§3.1): `"topo"` (default,
  gitloom's own order reproducing git's `--topo-order`), `"date"`, or `"author"`.
  Cycle live with `S`.
- `layout_policy` — the lane **layout policy** (§5.6): `"compact"` (**default**,
  linear slide + survivor compaction), `"survivors"`, `"linear"`, `"straight"`
  (no lane ever moves sideways), or `"gutter"` (`straight`, plus the lane owning
  the current subject row held in a fixed column beside the message). Cycle live
  with `C`. Like the other view toggles, the cycled value is persisted (§18) and
  restored on the next open unless the configured value has changed since.
- `mirror` — render the graph mirrored with lane 1 at the right edge of the
  graph column, nearest the message (§5.4). **Default true.** Set false for the
  conventional left-to-right layout. Purely a rendering transform; ordering and
  lane layout are unchanged. Toggle live with `M`.
- `date_format` — `os.date` format string for absolute dates (default
  `%Y-%m-%d %H:%M`), rendered in the author's local time.
- `date_mode` — `absolute` (default) or `relative`; selects the initial date
  rendering (§6). Toggle live with `d`.
- `message_min` — the minimum width always kept for the message (default `24`);
  the right-pinned refs use the rest of the free width, with overflow becoming
  `+N` (§6).
- `label_mode` — where ref decorations are placed: `"right"` (default), `"inline"`,
  or `"dual"` (§6.1). Cycle live with `B`.
- `dual_bracket` — the `dual`-mode pair bracket glyphs (§6.1): `{ label_row,
  message_row }`, each drawn exactly as given at the start of the flex column
  (no gap is added: a trailing space in a string, e.g. `{ "┬ ", "└ " }`, gives
  one). **Default `{ "┬", "└" }`.** Its colour is `palette.pair`.
- `diff` — the external diff provider (§11.5): `open` is a function called with a
  `DiffRange` to open the diff (default opens diffview in the range's `root`, the
  graph's repository — a custom `open` must honour `root` too), and `label` is the
  commit view's action-label text (default `▶ Open diff (diffview)`). Override
  `open`/`label` to use a different diff plugin; set `open` to `nil`/`false` to
  disable the integration (no action label, `D` is a no-op).
- `working_tree` — show the working tree as virtual commits on top of HEAD
  (§3.3, §4.2): `true` | `"dirty"` | `false`. **Default `true`.** With `true` the
  working-tree row is **always** shown: a dirty tree adds up to three `◌` nodes
  (staged / unstaged / untracked), a clean one a single `◌ Working tree · clean`
  node; they update on the working-tree refresh (§3.4). `"dirty"` shows only the
  change nodes (no clean node — the pre-always behaviour). `false` never reads the
  working tree and no virtual commits appear.
- `scrolloff` — window-local `'scrolloff'` applied to the graph and commit-view
  windows: the number of context rows kept above/below the cursor (**default
  `10`**). Set explicitly so the windows don't inherit the global value. Note: a
  non-zero value interacts with the context-pane overlays (§6.2); set `0` to
  restore the prior always-zero behaviour if the panes' scrolling misbehaves.
- `pin_upstream` — when a local branch is pinned, also pin its **remote
  counterparts** implicitly — every remote branch of the same short name, plus its
  tracked upstream (§6.3) — for the focus default and the pin icon; they take no
  rank, and a lane born at one shares its local's pinned colour, lightly dimmed
  (§5.5, §10.6). **Default true.** Set
  false to pin only the local branch. (The name predates the generalisation from
  "the tracked upstream" to "the counterparts"; it is kept so existing
  configurations keep working.)
- `persist` — remember the view toggles (`m C M B d H S c p F i`) and each
  repository's pin list across Neovim sessions in `stdpath("state")/gitloom.json`
  (§18). **Default true.** Set false to neither read nor write the file. A
  persisted toggle yields to a `setup()` value changed since it was saved (§18.3);
  **Reset view settings** (`<C-Space>`, `:GitloomResetView`) clears it.
- `progress` — how long-running operations are reported (§19): `provider` is
  `"auto"` (**default** — fidget.nvim when installed, else `vim.notify`),
  `"fidget"`, `"notify"`, `false`, or a custom provider table; `delay` is how long
  (ms) an operation must run before it is shown at all (**default `300`**).
  `progress = false` reports nothing, exactly as before §19. fidget is optional.
- `zindex` — the host window's **zindex** (§14.1, "Z-order"; **default `41`**).
  gitloom's own layers follow it: the overlays (context panes, the commit-view
  sticky header) at `zindex + 1`, its transient floats (`?` / `K`, its pickers
  and dialogs) at `zindex + 2`. The default places the full-screen graph above
  ordinary windows' float decorations (≤ 40) and below other plugins' floats
  (progress / notifications at 44–45, pickers and `vim.ui.select` at 50+).
- `search` — the commit-search picker (§15): `snippet` is the number of graph
  rows shown around the commit in the preview (**default `7`**, odd so the commit
  sits centered); `layout` is how the graph snippet and the commit detail are
  arranged in the preview — `"vertical"` (default, snippet above the detail). A
  side-by-side `"horizontal"` layout is deferred (it needs a second preview pane).

### setup() wiring

`require("gitloom").setup(opts)` stores `opts` in the module config, and the
`:GitloomGraph` command forwards that stored config to the graph open function,
where it is merged over the built-in defaults (read at invocation time, so a
later `setup()` still applies). Programmatic callers may also pass options
directly to the open function.

`setup()` also installs the **repository-picker mapping** (§2.1): a normal-mode
map of `pick_key` (default `<leader>wG`) to the picker. This is a setup-level
option (not a `GraphOptions` field) — installed by `setup()` rather than at
plugin load so `<leader>` resolves against the user's `mapleader`. Set
`pick_key = false` to install no mapping, or a string to choose the LHS.
`:GitloomPick` invokes the picker regardless.

## 9. Non-goals

gitloom is a **viewer**: it never stages, commits or rewrites history by itself.
The exceptions are actions the user explicitly picks — **checkout** (§10.4.1),
which only moves HEAD and the working tree; **checkout & examine** (§10.4.2),
which additionally stashes uncommitted changes when the user confirms the prompt
and re-applies them on Return; **fetch** / **pull** from the command palette
(§17); the palette's **branch sync** (§17.2) — fast-forward a branch to its
upstream, or reset it to its upstream, the latter the one action that can discard
work and therefore always confirmed with what would be lost; and the palette's
**set / unset upstream** (§17.2), which changes only which upstream a branch
tracks (its `branch.<b>.*` config). What is
permanently out of scope is **implicit index or history mutation as a side
effect of viewing** — gitloom never stages, unstages, commits, resets, or
rewrites history silently while you browse.

**Explicit, user-invoked graph operations** — fetch, rebase, cherry-pick, and
the like — are a planned future direction, not a non-goal. They build on the
refresh primitive (§3.4): the operation runs its git command, then the in-place
resync mirrors the result into the model. The line that does not move is the
*silent* one above; a deliberate, clearly-invoked operation is fair game.

Showing the **working-tree state** (§3.3, §4.2) is *not* the wedge for this:
gitloom *displays* the index and working tree as virtual commits, but **staging,
unstaging, and committing remain out of scope** — gitloom is a graph viewer, not
an index/staging UI. That is the obvious next step from a working-tree node and
the one deliberately not taken; the operations that fall naturally out of the
graph are history- and remote-level (above), not index editing. The diff is
read; the index is never written.

Acting on the commit under the cursor is reasonable where it arises naturally
from the graph, and the **commit view** (§11) is the first realization of it: a
read-only detail view of the selected commit, including its diff. Integration
with external diff plugins is realized through a pluggable provider (§11.5,
default diffview) rather than gitloom rendering its own rich diff. These are
secondary to the graph itself and must not compromise the model-ownership
principle (§1.1).

## 10. View model and transformations

> Status: **specified contract; implementation in progress.** The graph is a
> *projection* of the immutable commit model under a **view state**. Changing
> the view state reflows the projection.

### 10.1 Branch modes

Each **owner** has a mode. An owner is one of:

- a **ref** (its tip commit) — every ref except an *attached* HEAD, which only
  points at its branch's ref; a **detached** HEAD is an owner of its own, id
  `HEAD` (§10.6);
- an **anonymous merge-parent** — each *non-first* parent of a merge, identified
  by `(merge-hash, parent-index)`, so merged-in work that has no ref of its own
  can still be collapsed/expanded (and so the first-parent default, §10.7, has
  something to attach to);
Under the first-parent focus (§10.7) **every** owner is *first-parent-only*
(§10.2) — it covers only its tip's first-parent line. The **trunk owner** (the
current branch, or the `HEAD` owner when detached) is just the one that defaults to normal, so HEAD's mainline
stays in full.

Modes:

- **normal** — the owner's commits are shown in full.
- **collapsed** — the owner's commits are contracted to a single *collapsed
  head* row.
- **hidden** — the owner's commits are removed from the view.

Modes are independent: any owner may take any mode. The UI may restrict the
choices it offers; the model does not.

### 10.2 Attribution — the reachability signature

For each commit `c`, its **signature** `sig(c)` is the set of owners that can
reach `c`. Reachability is **first-parent-only** under the first-parent focus
(§10.7): an owner reaches `c` only along *first-parent* edges from its tip, so it
covers its tip's mainline but stops at every merge instead of descending the
merged-in side. This is what attributes a commit to the branch it is actually
*on*, not to every branch whose history merged through it — so collapsing or
expanding one branch never drags in the earlier branches it merged past. (With
focus off there is no trunk and every owner is full-reach — any parent edge — but
the projection is then the identity, so it does not matter.) Signatures are
monotone along the DAG: an ancestor's signature is a superset of its
descendants'. Commits therefore partition into **regions** — maximal connected
runs of equal signature — whose boundaries fall exactly at junctions where an
owner joins or leaves.

A first-parent line **does not stop where it rejoins another branch**: a merged-in
branch's own first parent leads back to the trunk commit it forked from, and the
owner continues down the trunk from there to the root. So a shared ancestor is
covered by an owner for every merge above it, and on a trunk where most commits
are merges each trunk commit sits in a region of its own. That is the intended
attribution — the branch *is* reachable from there — but it is also why the cost
of this pass tracks the repository's merge density rather than its size (§10.8).

**Owner coverage is total.** Every **real** commit in the model is reached by at
least one owner. This is not an accident of the ref set — it is guaranteed by
construction, because the owner set is closed under the two ways reachability can
leave a first-parent line:

- every non-first **merge parent** gets an anonymous owner (`merge:<hash>:<i>`),
  so a path that turns off a mainline at a merge is picked up on the other side;
- every **tip** — an in-model commit with no in-model child — that no ref covers
  gets an anonymous owner (`tip:<hash>`).

Any path from a ref to a commit decomposes into first-parent runs joined at
merges, so with both families present induction gives coverage of everything
reachable from a ref; the tip owners then cover whatever else the refspec drags
in. The `tip:` family exists precisely because §3.1's commit set is not
guaranteed to equal the ref-reachable set: `--all` walks namespaces the ref query
does not (a `refs/original/*` filter-branch backup, for instance). §3.2's
worktree refs give the *common* such case a real name; `tip:` is the backstop
that makes coverage hold regardless. Anonymous owners are never pinnable (§10.6)
and carry no label — a region owned only by them collapses to an unlabelled `◍`
head, which §10.4 already provides for.

**Working-tree virtual commits (§4.2) are excluded** from the tip family: they
sit above HEAD with no children by construction, and §4.2 requires them always
visible, so they are the one case that legitimately reaches the empty-signature
branch below.

A region's display mode is the **join** over the owners in its signature:

- empty signature (reached by **no** owner) → **normal**; only owners can hide,
  so an uncovered commit stays visible. With total coverage the only real
  commits that land here are the §4.2 virtual ones, which is exactly the rule's
  purpose
- some owner, but no non-hidden one (all hidden) → **hidden**
- any **normal** owner in the signature → **normal**
- otherwise (all collapsed) → **collapsed**

**A commit's own owners.** The owners in `sig(c)` whose **tip has the same
signature as `c`**: `own(c) = { o ∈ sig(c) : sig(tip(o)) = sig(c) }`. These are
the owners whose tip sits in `c`'s region (§10.2: a region is a connected run of
equal signature, so no owner joins between the tip and `c`). They are the owners
the row *belongs to*. An owner in `sig(c)` that is not own has its tip above
`c`'s region: it is a branch built on top of this one, and it reaches `c` only
through the part it shares. Examples:
- `c` carries refs `A` and `B` with branch `D` built on top: `own(c) = {A, B}`.
- a ref-less commit in the middle of `D`'s own commits: `own(c) = {D}`.
- a `◍` head: since every commit it contracts shares one signature, its own
  owners are those whose tip is the head's newest commit. That is the refs on
  its label, plus any anonymous merge-parent or tip owner (§10.2) starting there.

Several own owners always share their entire first-parent line, from the shared
tip down, so they can never be told apart on screen. §10.4's collapse and expand
act on them together.

`own(c)` is **empty** on a stretch that several branches share below the point
where they meet, for example the history under a fork whose sides are two
branches. No owner's tip lies in that region, so nothing there belongs to one
branch. Such a stretch is open while either branch is, by the join. For it:
- **expand** (its `◍` head) opens every collapsed owner in its signature, as
  before this amendment, because the stretch belongs to all of them;
- **collapse** has nothing of its own to collapse and only names the keepers
  (§10.4).

Intended consequences:

- A commit reachable from only one owner B follows B's mode.
- A commit shared by a hidden owner and a retained one stays visible — hidden
  owners never force removal of a commit a retained owner still reaches.
- A combined region below a junction is normal if *either* side is normal, and
  collapsed only if *all* its owners are collapsed; hidden owners don't vote.

### 10.3 Contraction — collapse preserves shape, hide removes

A **linear run** of collapsed commits contracts to a single collapsed-head
row. A collapsed commit that is a **junction** — a fork (two or more *visible*,
i.e. non-hidden, children) or a merge (two or more visible parents) — is **never
collapsed away**: it stays its own visible row, so the branching is intact —
with one exception, the **merge tip** (below). (A signature boundary, where
owners meet, is likewise a region boundary.) Hiding all-but-one of a junction's
branches demotes it to a linear commit that may then collapse.

A **merge tip** is the exception. A collapsed merge (two or more visible
parents) with **no visible child** is the end of its branch — the newest commit,
carrying the branch's ref, with nothing above it. A collapsed head is anchored
by its **tip** (its newest member), so a merge tip is a natural head: it
contracts into a `◍` **collapsed head**, like a linear run, rather than a
node-less junction. The head absorbs the adjacent collapsed commits of its
region (the rest of the folded branch below it), so it stands for the whole
folded branch with the right commit count, while the merged-in side stays a lane
off the head — so the merge still shows and the head never floats. (A fork
**root** — a collapsed fork with no visible parent — is *not* a tip; it stays a
node-less junction.)

The projection therefore preserves the commit graph's **branch topology**: every
fork, and every merge that still has a visible child, survives as its own node;
only linear runs and merge tips contract into heads (a merge tip's head keeps the
merged-in side as a lane). Edges crossing a collapsed region's boundary re-point
to its head, so a head is never left floating.

Hiding removes a region's rows outright and, unlike collapse, does **not**
preserve shape. An edge from a hidden region into a retained commit is dropped
(a phantom indicator is an open question, §10.8).

### 10.4 Markers and packing

A **marker** is a messageless node: it shows topology, not content. There are
two kinds:

- a **collapsed head** (§10.3) — the `◍` node, the region's ref label(s), and a
  compact collapsed indicator (a commit count). It carries **no message, date, or
  author**: a head stands for a whole region of commits, so any single value
  would misrepresent it. It exists only to show that the region exists and how it
  connects to the trunk — uncollapse for detail;
- a **kept junction** (§10.3) — a fork/merge inside collapsed branches whose
  commit is just a split point. It renders **node-less**: the cell draws the
  fork/merge as box-drawing lanes (`├ ┬ ┼ …`) instead of a node, with no
  message — so the split topology shows without the commit's visual weight.
  Controlled by the `junction_markers` option (default on); off renders those
  junctions as full commits. (A **merge tip** — a collapsed merge with no visible
  child — is *not* a kept junction; being the branch's tip it contracts into a
  `◍` head, §10.3.) A node-less junction with a **single** fan needs no separate
  fan line — it renders on one row (the fan inline). One that is **both** a fork
  and a merge keeps its fan-in and fan-out on **separate** lines per `merge_style`
  (the fan-in on its own split line), so two independent funnels never share a
  row (§5.1).

  **A ref must be anchored to a node.** A kept junction that carries refs is *not*
  drawn node-less — it shows the `◍` collapsed marker (it is a collapsed-mode
  commit), keeping its fan lanes and blank message, so the ref label sits on a
  node rather than floating beside bare box-drawing with no indication of which
  junction it tags. Only a **ref-less** junction renders truly node-less.

**Topology-only rendering.** A marker's row shows *topology, not content* —
graph glyphs and ref labels only, no date, author, or message. This is a
**render style**, not a mode: it is how collapsed heads and kept junctions
already draw, and the context panes (§6) render **every** row this way (branch
names only). Any row may be rendered topology-only without changing its place in
the model.

**Packing.** Because markers carry no message, several may share one physical
line. A maximal run of consecutive markers that are **mutually concurrent** (none
an ancestor of another) and whose lanes stay continuous is **packed** onto one
line: each marker keeps its own lane column and its edges, so branch topology is
unchanged, and the line lists the union of their ref labels. This is the one
exception to "one commit per line" (§5.1). Message-bearing commit rows never pack
(a Phase A limit; the general adaptive case is §10.8).

Packing is **on by default**, toggled live with `p` and via a config option;
with it off, every marker occupies its own line.

**Interaction.** Collapse/expand acts on the **owners the row belongs to**, its
**own owners** (§10.2), found through the commit's signature rather than a
selected ref. So it works for any region, including ref-less ones
(first-parent-merged, squashed). Each owner keeps its own collapsed / normal
state, and the §10.2 join does the rest: a row is open while **any** normal owner
reaches it. An owner reaches a commit along **first parents only** (§10.7): an
open branch opens its own first-parent line, never the branches merged into it.
So opening `dev` (or the trunk) does not open everything ever merged into it;
each merged-in side keeps its own state, behind its own `◍`. A commit the trunk
reaches (the mainline) is not collapsible.

A row's **keepers** are the normal owners in its signature, the ones holding it
open. A keeper that is not an own owner is a **branch built on top** (or an
anonymous merge-parent or tip owner above): it reaches this row through the
history it shares. Collapse never touches such a keeper, so a row it keeps open
stays open. The `▾` on that branch's label (§6) and the notice below say why.

- `<Space>` — the quick **collapse ⇄ expand toggle**. The **row** decides the
  direction, never a selected ref's own mode.
  - **On an open row** it sets every **normal, non-anchor own owner** collapsed.
    If a keeper remains (a branch built on top), the row stays open, and gitloom
    says so, naming the keepers' refs with anonymous ones as a count
    (`still open via feature/z +1 merged`). With nothing left to collapse (the own
    owners already are), it gives only that notice. The key never looks dead,
    and pressing it again never re-opens what it closed.
  - **On a `◍` head** it **expands** the head: it sets the head's **own owners**
    normal, the owners whose tip is the head's newest commit (§10.2). Owners that
    only reach the head through a branch built on top are left alone, so a
    collapsed branch above stays a `◍`. The newly normal owners also open the
    history they reach further down, by the join.

  The other ways of opening a commit follow the same rule: they set the commit's
  own owners normal, which is the least that makes it visible. These are the
  palette's expand, a filter jump (§16.4), the §11.7.6 reveal and the selection
  fold toggle (§13.4). A ref selected with `h`/`l` (or pre-selected by landing,
  §2) does **not** narrow the toggle. The refs on one row share their whole
  first-parent line, so collapsing only some of them can never fold the row, and
  a per-ref toggle would flip a ref's invisible mode back and forth while the row
  stays open. A row an **anchor** reaches (the mainline, §10.6) is not
  collapsible: `<Space>` there leaves the view unchanged and says why, naming the
  anchor(s) that reach it (e.g. `on dev's mainline — not collapsible`). Two-state —
  *hidden* is not in this cycle, so the toggled thing never vanishes from under
  the cursor. After the reflow the cursor is repositioned onto the resulting node
  (the new marker, or the expanded region's tip), so repeated `<Space>` flips it
  open/closed in place. (`<Tab>` / `<C-i>` is reserved for forward navigation,
  §14.3.)
- `<C-Space>` — the **command palette** (§17), gitloom's single action menu
  (`vim.ui.select`): the row's actions come first, then the global commands, then
  the keys (§17.1). The row entries are **scoped to what is selected** — a commit
  or a branch, never both:
  - **commit** — a **plain commit row** (cursor on a normal commit's message, no
    ref selected): **open diff** (`D`), **checkout commit** (detached),
    **checkout & examine** (**examine** when the row is HEAD's commit,
    §10.4.2). No branch actions.
  - **branch** — a ref selected with `h`/`l`, or a **collapsed head**:
    **checkout** of that branch (§10.4.1; a collapsed head detaches at its tip;
    a remote branch whose local counterpart sits elsewhere gets the explicit
    checkout-and-sync / detached entries of §10.4.1 instead),
    then the **branch sync** entries of a local branch tracking an upstream —
    **fast-forward to `<upstream>`** and **reset to `<upstream>`…** (§17.2) —
    then **collapse** (`<Space>`) + **hide** of an expanded branch or **expand**
    (`<Space>`) + **hide** of a collapsed one. **Collapse** and **expand** are
    `<Space>`'s: they act on the row's own owners. Each entry **names them**, with
    their ref names and the anonymous ones as a count
    (`Collapse feature/x, fix/y +1 merged`; `Collapse branch` when it has none).
    When a branch built on top will keep the row open, the collapse entry says so
    (`… (stays open via feature/z)`), and choosing it gives `<Space>`'s notices. On
    a mainline row there is neither a collapse nor a hide entry. **Hide** stays
    per-ref: it hides the selected branch's owners only (a `◍` with no ref
    selected: every collapsed owner in its signature; hidden owners do not vote,
    §10.2).
    No commit open diff and no
    detached checkout & examine — those are the commit's, reached from its message.
  - **packed-marker line, a marker selected** (`h`/`l`) — that marker's actions
    only: **checkout** of its tip, its **branch sync** entries (§17.2), **expand**
    (its own owners, as `<Space>` on a `◍`), **hide**. (The keys then follow the branch context.)
  - **packed-marker line, no marker selected** — **expand** / **hide** per marker,
    by name. The palette is the overflow-proof way to reach any marker on a packed
    line even when not all labels fit.

  The palette is where hidden and full mode control live. A §4.2 working-tree
  virtual commit gets no checkout entry; open diff and checkout & examine appear
  only when a diff provider is configured (§11.5). There is no examine entry: that
  is `<CR>`.
  - **working-tree row** (a §4.2 node, clean or not) — **Examine working tree**
    (§10.4.2) and **open diff** (§11.8), both only with a diff provider; on the
    clean node both open the same empty working-tree-vs-HEAD range. Nothing else: no checkout, checkout & examine, branch
    sync, expand, collapse, hide or pin — the row has no ref, no owner and no
    commit object. The globals (fetch, pull, Return, …, §17) are unaffected.
- `<CR>` — **examine**: the commit view (§11) of the row's commit, directly (§11).

On a packed line, `h`/`l` selects among the markers (all of them, regardless of
which labels fit); `<Space>`, `<CR>` and the palette act on the selected marker. Reachability
emphasis (§12) **follows the selection**: the selected head's branch — its `◍`
node, label, and lane — stays its normal colour while the sibling heads/branches
sharing the row dim, exactly as moving onto a normal head dims everything outside
its cone. With no marker selected the line is neutral (all lit).

#### 10.4.1 Checkout

The palette's **checkout** entry changes the repository (as do checkout & examine,
§10.4.2, and the palette's fetch and pull, §17): it moves HEAD and the working
tree, nothing else. What it runs depends on what the
row selects, and the entry's label says which:

| Selection | Command | Label |
|---|---|---|
| a local branch (`foo`) | `git switch foo` | `Checkout branch foo` |
| a remote branch only (`origin/foo`), no local `foo` anywhere | `git switch foo` | `Checkout branch foo (from origin/foo)` |
| a remote branch only (`origin/foo`), a local `foo` exists at another commit | see *A remote branch with a local counterpart* below | — |
| a tag, a worktree label, or no ref (a bare commit, a collapsed head's tip, a selected packed marker's tip) | `git checkout --detach <hash>` | `Checkout commit <short> (detached)` |

A branch group that has a local branch checks out the local one. The remote form
relies on git's DWIM: it creates a local tracking branch `foo` when none exists.
It is offered **only** then — when a local `foo` exists elsewhere, git's DWIM
would silently switch to that (possibly far-behind) local branch instead of the
commit the user selected, so gitloom makes the choice explicit (below). The attached HEAD label
`(HEAD → foo)` (§6) is the current branch's group, so it checks out `foo` (a
no-op switch); a detached HEAD's bare `HEAD` label is not selectable, so a row
whose only ref is a detached HEAD is a bare commit. A §4.2 working-tree
virtual commit has no checkout entry, and neither does a packed-marker line with
no marker selected.

Checkout **never forces**. The palette choice is the confirmation — there is no extra
prompt. git runs in the graph's repository root (§2.1), which may be a submodule,
not Neovim's cwd. If git exits non-zero (a dirty file the checkout would
overwrite, a branch checked out in another worktree, an ambiguous remote name…),
gitloom shows git's error as one line at ERROR level and changes nothing. On
success it runs the in-place resync (§3.4, the `R` key), so HEAD's marker and the
working-tree rows (§3.3) move to their new place — and then, unlike a plain `R`
(which keeps the cursor on the commit it was on), it **moves the cursor to HEAD's
row**: the commit just checked out, which is always a visible row because HEAD is
always an anchor (§10.6). The completion notice names the result instead of a
bare "resynced": `HEAD → <branch> (<short>)` on a branch, `HEAD detached at
<short>` otherwise (`<short>` = the 7-character hash).

**Behind notice.** When the checkout lands on a branch that is **behind** its
upstream, the notice says so, from the tracking counts of the ref read the resync
just made (§6.3) — never the counts cached before the checkout:

| The checked-out branch vs its upstream | Notice |
|---|---|
| strictly behind | `HEAD → foo (abc1234) — 12 behind origin/foo` |
| diverged | `HEAD → foo (abc1234) — 3 ahead, 12 behind origin/foo` |
| ahead only, in sync, `gone`, no upstream, detached | nothing appended |

Ahead-only is not mentioned: nothing is missing locally, and an unpushed branch
is the normal state of work in progress. This applies to every resync that
follows HEAD — checkout, the entries below, and Return (§10.4.2).

**A remote branch with a local counterpart.** When the selected ref is a remote
branch `origin/foo` and a local branch `foo` exists at a **different** commit
(were they on the same commit they would be one branch group, which checks out
the local branch), `Checkout branch foo (from origin/foo)` is not offered. What is
offered depends on whether the local `foo` **tracks** `origin/foo` — its upstream's
full refname (§6.3) is `refs/remotes/origin/foo` — and, if so, on its cached
tracking counts (§6.3; the palette spawns no git to decide):

| Local `foo` | Entry | Runs |
|---|---|---|
| tracks `origin/foo`, strictly **behind** (behind > 0, ahead = 0) | `Checkout foo and fast-forward to origin/foo` | `git fetch --no-recurse-submodules . refs/remotes/origin/foo:refs/heads/foo`, then `git switch foo` — no prompt (nothing is lost) |
| tracks `origin/foo`, **ahead** or **diverged** | `Checkout foo and reset to origin/foo…` | the §17.2 reset confirmation (Cancel first), then `git switch -C foo refs/remotes/origin/foo` |
| tracks `origin/foo`, and **is the current branch** | the plain branch sync entries, `Fast-forward foo to origin/foo` / `Reset foo to origin/foo…` (§17.2, current-branch forms) | as §17.2 |
| does not track `origin/foo` (another upstream, or none) | — (no branch entry) | — |
| in every case above | `Checkout commit <short> (detached)` | `git checkout --detach <hash>` of `origin/foo`'s commit |

The branch entry comes first, then the detached checkout. A tracking local branch
cannot be in sync with, or have a `gone`, upstream it is not on the commit of; if
the cached data says so anyway, only the detached checkout is offered.

Which form runs is decided from a **fresh read** of the repository
(`fetch.sync_probe`, as §17.2 does), never the cached decoration: if `foo` has
meanwhile become the current branch, the entry runs the current-branch form
(`git merge --ff-only` / `git reset --hard`, with §17.2's prompt) and switches
nothing. Otherwise:

- **Checkout and fast-forward** runs the two commands in order. git refuses a
  non-fast-forward (the refspec carries no `+`) and a branch checked out in
  another worktree; then nothing has changed. If the switch fails after the
  fast-forward succeeded (a dirty file the switch would overwrite), git's error
  is shown as one ERROR line and the graph resyncs without moving the cursor:
  `foo` stays fast-forwarded, nothing is lost.
- **Checkout and reset** asks first, exactly like §17.2's reset: the fresh read,
  a prompt whose first (default) choice is Cancel —
  `Check out foo and reset it to origin/foo (def5678)?` followed by what is lost
  (`discards 2 local commits`, the reflog line) — then the same state is read again
  right before running and the run is **aborted** with a WARN notice if the branch
  tip, the upstream tip or the current branch changed. `git switch -C` resets and
  switches in one atomic step. It never forces: uncommitted changes are carried
  over, and if git refuses because a dirty file would be overwritten (or the
  branch is checked out in another worktree), its error is shown and nothing
  changes.

Success runs the follow-HEAD resync like a checkout; the notice names HEAD and
what happened to the branch: `HEAD → foo (def5678) — fast-forwarded to
origin/foo` / `HEAD → foo (def5678) — reset to origin/foo, was abc1234`. These
entries share the one-at-a-time rule of the branch sync (§17.3).

#### 10.4.2 Checkout & examine

**Checkout & examine** checks a commit out (detached) and opens its changes in
the external diff provider (§11.5) **against the working tree**, so the
provider's right-hand side is the real files on disk and LSP clients and
diagnostics attach to them. This is the whole reason it exists: an ordinary
commit diff (`<hash>^!`) or a range diff (`<a>..<b>`, §13.5) makes the provider
build both sides from git blobs — read-only buffers with no path. Given a
**single** rev, diffview compares that rev to the working tree and the right side
is `RevType.LOCAL`, the file on disk. Checking the examined commit out first is
what makes "the working tree" equal "that commit".

**What it examines.** One commit, or a §13 range selection:

- `newer` — the selection's newest commit (for one commit, the commit itself);
  gitloom runs `git checkout --detach <newer>`;
- the diff is then opened as a `DiffRange` of **one** rev — `<older>`'s first
  parent, or the empty tree when `<older>` is a root commit — stamped with the
  graph's repository root (§2.1), so the provider runs `-C<root> <base>`. The
  base is the same one the range view uses (§13.5), so the diff shows the same
  combined changes, merged-in commits included.
- If the selection's newer end is a §4.2 **working-tree node**, there is nothing
  to check out — the working tree already is the newer end. gitloom opens that
  selection's existing working-tree range (§13.5, already single-rev) and changes
  nothing else.

**Examine (the newer end is HEAD).** When the newer end already **is** HEAD's
commit — HEAD attached or detached — there is nothing to check out either, so the
palette offers **Examine** (`Examine <short>` on a commit row, **Examine
selection** while selecting) in place of Checkout & examine. It opens the same
single-rev range — `<older>`'s first parent, the empty tree at a root — so the
provider's right side is the working tree, and does nothing else: no checkout, no
stash, no examine state recorded, so no Return. A **dirty** tree is examined as
it is, without a prompt: the right side shows the files on disk, uncommitted
changes included. (To see the uncommitted changes as their own range, extend the
selection onto the §4.2 working-tree nodes instead.) An examine already active is
left alone — its state and its Return entry stay. Whether the newer end is HEAD
is decided from the cached refs (the `HEAD` ref's commit) when the palette is
built, never by spawning git. A §13 selection whose newer end is a working-tree
node is likewise labelled **Examine selection**, since it checks nothing out
either. (Should HEAD have moved since the refs were read, a Checkout & examine
whose newer end turns out to be HEAD's commit behaves as Examine too.)

**Examine working tree (a working-tree row).** The cheapest case: the real files
are already on disk, so nothing is checked out, nothing is stashed, no examine
state is recorded and there is no Return. On any §4.2 row it opens one single-rev `DiffRange` — `rev` = HEAD's commit hash (from the cached
refs), `from` = HEAD, `to` = `"worktree"` — i.e. **every** uncommitted change
(staged and unstaged together; untracked as the provider lists them) against
HEAD, with the right side the files on disk so LSP attaches. It is the same
range whichever stack row the cursor is on: the entry examines *the working
tree*, not one node's slice of it (that per-node slice is **open diff**, §11.8).
On the **clean** node the entry is the same, and so is the range: the working
tree against HEAD, which is **empty** — the provider opens with no files. That is
the honest answer for "the working tree" when nothing is uncommitted, and it is
deliberately *not* rerouted to HEAD's Examine (that entry is on HEAD's own row). A
§13 selection whose newer end is any working-tree node — the clean one included —
is **Examine selection** as already described: `<older>`'s first parent against
the working tree.

**A dirty tree.** Before checking out, gitloom reads `git status --porcelain`.
If there are staged, unstaged or untracked changes it asks (`vim.ui.select`):
**Stash N changes and continue** / **Cancel**, where N is the number of changed
files, each path counted once (a file with both staged and unstaged edits is one
change, as is a rename or an untracked file). Continue runs
`git stash push -u -m "gitloom: examine <short> (from <branch or short hash>)"`
and records the new stash's SHA (`git rev-parse stash@{0}`). If the push fails,
git's error is shown and nothing is checked out. If the checkout then fails,
gitloom immediately re-applies the stash by SHA (`git stash apply <sha>`), drops
it only when that apply was clean, and shows the checkout error. A clean tree
needs no prompt.

**The examine state.** A successful examine records, per repository: `orig` —
the branch HEAD was on, or HEAD's hash when it was detached; the stash's SHA (or
none — a clean tree records state too, so Return knows where to go back to); and
the examined commit. It lives in the per-repository session state (like the
remembered cursor position, §2), so it **survives closing and reopening the
graph** within the Neovim session; it is not written to disk.

**No stash chains.** A second Checkout & examine while one is active is allowed:
`orig` and the stash are kept, only the examined commit moves. But if the tree is
dirty then (edits made since), gitloom refuses with a notice to Return first
rather than stashing a second time — there is never more than one gitloom stash
per examine.

**Return.** While an examine is active, the command palette (§17) lists
**Return to `<orig>`**. It runs `git switch <branch>` (or
`git checkout --detach <hash>` when `orig` was detached), then, if a stash was
recorded, `git stash apply --index <sha>`, which restores the index as well as
the working tree: staged changes come back staged, unstaged ones unstaged, and
untracked files are restored. A clean apply drops that stash (found by SHA in
`git stash list`, never by position). The rules on failure:

- the switch back fails (new local edits it would overwrite…): git's error is
  shown at ERROR level and the state is **kept**, so Return can be retried;
- git refuses to restore the index (`conflicts in index. Try without --index.`
  — e.g. `<branch>` moved meanwhile so the staged patch no longer applies
  exactly). git checks this before touching the index, the working tree or the
  untracked files, so nothing has changed; gitloom then runs a plain
  `git stash apply <sha>` and, when that applies cleanly, drops the stash as
  usual and warns (WARN) that the staged state could not be restored — the
  changes are back, but unstaged. Only that refusal falls back: any other
  failure of the `--index` apply is handled as below. (The `--index` apply runs
  with `LC_ALL=C`, so the refusal is recognised by git's untranslated message.)
  If the plain apply then conflicts or fails, it is handled as below;
- the apply conflicts or fails: the stash is **kept**, git's error is shown at
  ERROR level together with the kept stash's message, and the state is cleared
  (HEAD is back; the stash is the user's to resolve).

The state is cleared only after a successful switch plus a successful apply (or
none needed). Every outcome that changed HEAD or the working tree is followed by
the in-place resync (§3.4). After a successful examine and after a Return that
moved HEAD, the resync follows HEAD exactly as checkout does (§10.4.1): the
cursor lands on HEAD's row and the notice names it (`HEAD detached at <short>` /
`HEAD → <branch> (<short>)`), with what happened appended — `examining — Return
from the palette (<C-Space>)` after an examine, `changes restored` after a Return
that re-applied a stash (`changes restored (unstaged)` after the plain-apply
fallback). A failure's ERROR message is not overwritten. Like checkout, nothing here forces, everything runs
asynchronously in the graph's repository root, and one examine / Return runs at a
time per graph session (shared with the palette's fetch / pull, §17.3).

**Entry points.** Both are in the command palette (`<C-Space>`, §17). Among the
row entries (§10.4) **Checkout & examine** follows the checkout entry on a plain
commit row (the commit context) — **Examine** instead when that row is HEAD's
commit — never in the branch context (a selected ref or a collapsed head) or on
a packed-marker line. A §4.2 working-tree row gets **Examine working tree**
(above) and never Checkout & examine. While a §13 selection is active
the selection's entries replace the row's and lead with **Checkout & examine
selection** (**Examine selection** when its newer end is HEAD's commit or a
working-tree node; §17.1). Both appear only when a diff provider is configured
(§11.5).

### 10.5 Reflow

Any view-state change recomputes the projection from scratch (not appended) and
is **stable**: regions unaffected by the change keep their relative order and
do not visually churn. Row order is derived from the existing topological order
by dropping hidden rows and contracting each collapsed region to its tip's
position — so ordering ownership (§1.1) is *not* a prerequisite for this
feature.

**A reflow is applied atomically, and may be computed incrementally.** The new
projection is computed in full — owners, signatures, contraction, layout,
marker packing — before any of it is shown; the view never displays a partly
reprojected graph. A collapse is therefore a single transition, not a branch-by-
branch animation: signatures are computed against the whole owner set, so
"collapse one more branch" is not a cheaper intermediate but a re-run of the
entire pipeline, and a row the cursor or a keypress is addressing would move
under it at every step.

Computing it, however, need not block the editor. Where a reflow is not the
direct result of a keypress — today, the first projection after the commit
stream closes (§10.7), which is the one reflow whose cost scales with the whole
repository — it is computed in slices across event-loop turns, leaving the
window scrollable and the keymaps live while it lands, and the result is swapped
in when it is complete. Such a computation is **abandonable**: a reflow driven by
a keypress supersedes one in flight, and an abandoned one has changed nothing
that was on screen.

### 10.6 Pinned branches (anchors)

**Pin** is a per-owner flag, **orthogonal to mode** (§10.1): it marks an owner
as an *anchor* — a branch the view is organised around — without itself
deciding how much of that branch to draw. (This supersedes the earlier
"pinning forces normal" rule: an anchor still obeys its mode, so it may be
collapsed or hidden.)

The pinned set **generalises the trunk** of the first-parent focus (§10.7).
Today HEAD is the single distinguished owner the rest of the graph folds
toward; pinning lets the user name *several* anchors — e.g. `master`, `dev`, a
release branch, a few personal branches. **HEAD is pinned by default, along
with the common trunks `master` / `main` / `dev` when they exist**; the user may
pin or unpin any ref. HEAD is a default anchor **whether attached or detached**,
so the checked-out commit is always a normal, visible row — never folded into a
`◍` head:

- **on a branch** the anchor is the current branch's owner (its ref name), as
  for any branch;
- **detached**, the `HEAD` ref itself is the owner (owner id `HEAD`, §10.2) —
  there is no branch to name, and `HEAD` is the one id that keeps meaning "what
  is checked out": it is re-bound to the new commit by every resync (§3.4), so a
  pin, an unpin or a mode override on it follows HEAD from detached commit to
  detached commit instead of going stale with a hash-named id. Unpinning it
  (`P`, the dialog) suppresses the default like any other. While HEAD is on a
  branch the `HEAD` ref is not an owner (it duplicates the branch's), so an entry
  for it is not part of the resolved list then.

Every pinned ref's label — an implicit remote counterpart's (below) included —
shows the **pin icon** (`⚲`, `icons.pin`; §6), so the anchor set is visible on
the graph itself — except HEAD's label, which is already singled out.

**The pinned branches are an ordered list, not a set.** Each entry is a ref
owner id plus one flag, **reserved** (§10.6.2) — so the state is *one* list:

```
PinEntry = { id: string, reserved: boolean }
pins     = PinEntry[]        -- priority order, highest first
```

Two consequences are structural rather than remembered rules: `reserved` ⊆
`pinned` by construction (the flag has nowhere else to live), and **unpinning
implies unreserving** (the flag leaves with its entry). The order is the
**anchor priority**: first entry wins wherever one anchor has to be named. An
entry's **rank** is its 1-based position in the resolved list.

**Order matters for every entry.** The rank drives lane identity (§5): where two
lanes meet, the better-ranked one continues, and a pinned tip that outranks every
lane arriving at it starts its own lane — in its **pinned colour**, slot `k` of the
curated palette for rank `k` (§5.5). So moving any entry — reserved or not — can
change which lanes continue and how they are coloured. Among
**reserved** entries the order additionally decides the dedicated columns
(§10.6.2 — left to right in list order, skipping unreserved ones).

The list is **resolved**, not stored whole. The defaults are, in this order: the
common trunks `master`, `main`, `dev` and the seeded pointer marks (§11.7.6), then
HEAD's anchor (its branch, or the `HEAD` ref when detached) — HEAD comes **last**
among the defaults, as the most recently "pinned" one. The resolved list is the
defaults the user has not explicitly placed, in that order, **followed by** what
the user has explicitly ordered; an explicitly **unpinned** ref suppresses its
default, and an entry naming a ref that no longer exists is dropped. A **newly
pinned** ref (`P`, "Pin new branch…" in the dialog) always goes to the **bottom**
of the list, below every default and every earlier pin; the dialog (§10.6.1) is
how it is moved up. So the list is deterministic for a repository the user has
never touched, and stable once they have.

This order is **not** the order labels are drawn in. HEAD's label is drawn first
on its row, as `(HEAD → x …)` or a bare `HEAD` (§6), whatever HEAD's rank — that
is a rendering rule about "you are here", unchanged by pin priority.

**Implicit remote counterparts.** Pinning a local branch also pins its **remote
counterparts** implicitly (config `pin_upstream`, default on): every remote branch
with the same short name — the same members, in the same order, that the `%`
local ⇄ remote cycle steps through (§2: the remotes in `git remote` order, then any
remote not listed there, by name) — plus the branch's **tracked upstream** (§6.3)
when its short name differs. A logical branch is the local *and* where each remote
thinks it is, so anchoring them together keeps every one of those lanes in full
under focus — and where they have diverged the fork between them is drawn instead
of a remote collapsing to a `◍` head. The counterparts:

- are pinned for the **focus default** (§10.7) and the **pin icon** (§6): they
  have **no rank** (§5), so they never steer lane identity, and no slot of their
  own — a lane born at one **shares its local's pinned colour, lightly dimmed** (the
  counterpart colour, §5.5). A counterpart **diverged** from its local draws its own
  lane in that colour; one **ahead** of its local starts that lane at its own tip
  (even under another branch built on top of it, §5 "Birth at a counterpart tip")
  and reaches the local's tip as an unranked lane in that colour, so the local's pinned lane is born there and the
  colour brightens to full; one at or behind the local is on the local's own
  (pinned) lane, in full colour;
- are **not listed** in the pinned-branches dialog (§10.6.1) — they are not entries
  of their own, they follow their local's;
- carry the **pin icon** like any pinned ref (§6);
- are dropped when the local is unpinned (or `pin_upstream` is false).

An explicit choice on a counterpart still wins. `P` on a counterpart while it is
implicitly pinned records an explicit **unpinned** override for that one ref: it
loses its pin (icon, focus default) while its local and the other
counterparts keep theirs. Pinning a remote branch **explicitly** (`P` on an
unpinned one, or "Pin new branch…") gives it its own row in the dialog, at its own
priority, which is then its rank — with a pinned colour of its own.

Anchors drive three things — the focus default, the panes, and lane identity
with a **fixed colour** — and, deliberately, nothing more:

- **The focus default (§10.7).** Pinned owners default **normal**; every other
  owner defaults **collapsed**. So naming the anchors *is* choosing what stays
  in full. The trunk-only case is exactly one anchor. As in §10.7 this is a
  recomputed default, not a seed — explicit per-owner overrides win.
- **The context panes (§6).** The header/footer summarise off-screen topology
  *folded onto the anchors*: a non-anchor lane crossing the viewport boundary
  is drawn only until it merges into an anchor, and otherwise terminated
  minimally. The boundary lane-continuity invariant and pane sizing are
  specified in §6.
- **Lane identity and a fixed colour (§5, §5.5).** The pin ranks of the list's
  entries decide which lane continues where lanes meet, and where a pinned branch's
  own lane is born — so a pinned branch's history is drawn in its own colour rather
  than in the colour of whatever branched off its tip. That colour is **fixed**: the
  entry of rank `k` owns slot `k` of the curated palette (ranks past the palette
  take a free-list colour), withheld from every other lane until the branch's lane
  ends and then recycled. A pinned branch therefore reads as the same colour across
  reflows, policies and scrolling, and adding a pin below it never recolours it.
  Implicit remote counterparts take no part (above). (Under `gutter` the continuing
  lane also steers placement — see the implementation risk noted in §5.)
- **Nothing else.** In particular pin does **not** claim columns: a pinned branch
  is placed by exactly the same rules as any other. A **dedicated column** is a
  separate, explicitly-set flag (§10.6.2), never a consequence of pinning. This is
  deliberate and load-bearing — a typical repository pins up to four branches by
  default (the trunks and HEAD, plus their remote counterparts), so "pin ⇒ held
  column" would silently hold several columns open for a user who asked for none.

Pin is part of the view state; changing it — pinning, unpinning, or reordering —
reflows the projection and re-lays the layout (§10.5), since the ranks are a layout
input (§5). The signature cache stays valid: a pin changes only default modes and
ranks, neither of which enters a signature (§10.2).

#### 10.6.1 The pinned-branches dialog (`L`)

`L` opens a small modal float over the graph listing the resolved pin list
(§10.6) in priority order — the one place the order and the reserve flags are
edited:

```
Pinned branches                    ◆ = dedicated lane

  1  ◆  master              <C-j>/<C-k>  move
  2  ◆  topic1              <Space>      toggle lane
  3     origin/release      D            unpin
  4     dev                 <CR>         jump to branch
     + Pin new branch…      q            close
```

- Each row is one entry: its **priority number**, the **`◆` marker** when the
  entry is reserved (§10.6.2) and blank when it is not, and the ref name. The
  numbering runs over the whole list — it is every entry's rank, which drives
  lane identity (§5) — while the `◆` picks out the subsequence that also claims
  columns. A pinned local branch's implicit remote counterparts (§10.6) have **no**
  rows: they follow their local's row, and have no rank of their own (§10.6). An explicitly pinned remote branch
  has a row of its own.
- `<C-j>` / `<C-k>` move the entry under the cursor **down / up**, clamped at
  the ends; the cursor follows it so a move is repeatable.
- `<Space>` toggles the entry's reserve flag.
- `D` unpins the entry — it leaves the list, taking its reserve flag with it.
- The last row, **`+ Pin new branch…`**, opens the existing ref picker (§2,
  `<leader>b`); the chosen ref is appended to the **bottom** of the list, pinned
  and **not** reserved. Refs already on the list are omitted from that picker (an
  implicit counterpart is not on it, so it is offered — picking it pins it
  explicitly, with a row and rank of its own), and so is
  `HEAD` while it is on a branch (its branch is the owner); a **detached** `HEAD`
  is offered, so it can be pinned back after an unpin.
- `<CR>` on an entry closes the dialog and **jumps the graph to that branch**,
  exactly as picking it in the ref picker does (§2) — centered, with the ref's
  label pre-selected.
- `q` / `<Esc>` closes.

Every edit is applied immediately: the view state changes, the projection
reflows (§10.5), and the graph cursor is restored to the commit it was on. The
dialog's keys are buffer-local, so they do not collide with the graph's own
bindings. `P` (§10.6) remains the in-graph shortcut for pin/unpin of the branch
under the cursor; it appends to the bottom of the list, unreserved (on an
implicitly pinned counterpart it unpins that one ref instead, §10.6).

**Honesty about unimplemented effect.** The reserve flag is recorded and
displayed before the layout honours it (§10.6.2 is staged). While that is true,
the dialog says so on its own last line — a control whose effect is not yet
built must be visibly labelled as such rather than appear to work.

#### 10.6.2 Dedicated lanes (reserved columns)

A pin entry may be **reserved**: the branch is given a **dedicated column** in
the graph, held for it whether or not a lane of that branch is drawn on a given
row. Reserved branches take columns **left to right in pin-list order**,
skipping unreserved entries. Reserving is always explicit (§10.6.1); the default
for every entry, including the defaulted anchors, is **pinned but not
reserved**.

- **A reserved column is occupied for placement purposes.** It is exactly the
  existing **root column break** (§5.1) mechanism generalised: the sweep's own
  column bookkeeping marks the column taken, so tip placement, fan-out and any
  compaction move all skip it. Nothing new is asked of §5.1 — its "stopping at
  the first occupied column" stays literally true, with a reserved column being
  one of the things that counts as occupied.
- **Stop, never a skip.** A lane compacting leftward that meets a reserved
  column **halts there**. It must never lay a horizontal *across* the reserved
  column to reach a farther gap: that would be a wire crossing a held column,
  and — unlike a horizontal crossing a *vertical* — it is invisible to the
  crossing checker (§5.1 tests a horizontal against a vertical bar), so it would
  pass every existing test while looking wrong.
- **Birth, not re-jog.** The reservation is enforced where a lane is **born**
  (and by "not compacted away" thereafter), never by moving an already-placed
  lane rightward into its column. Compaction redraws leftward only; a rightward
  jog has no redraw and fails the layout's completeness check.
- **A reserved branch keeps its colour slot for the whole layout.** Every pinned
  entry already owns a pinned colour (§5.5) until its lane ends; a reserved one's
  slot is not released then — it stays dropped from the free list, counted in use,
  and never recycled or retired while the reservation stands. (A reserved entry
  ranked past the curated palette has a free-list colour, held the same way.) This
  generalises the context-pane **seed** carve-out (§6.2), which removes a live seam
  lane's colour from the free list for exactly the same reason.
- **Attribution tie-break.** A commit's signature is a *set* of owners (§10.2),
  so a commit may belong to several reserved branches at once. The column is
  chosen deterministically: the **highest-priority reserved owner in the
  signature** — the earliest such entry in the pin list. This is where pin-list
  order decides *placement*; lane identity (§5) is where it decides colour. A §4.2
  working-tree node, whose signature is empty, is placed as if attributed to the
  HEAD commit's highest-priority reserved owner (§4.2 "Layout identity follows
  HEAD"), so the stack is born in HEAD's reserved column instead of bending in.
- **The context panes are exempt.** Neither the footer nor the header honours
  reservations. The footer is a *seeded* sweep whose seam row must reproduce the
  main view's boundary columns exactly (§6.2), and the header is a direct
  seam-up grid that never runs the column sweep at all. Holding a column in
  either would break the seam or mean nothing. This is deliberate, not an
  oversight: the §6.2 seam invariants are unchanged by reservation.

Under the `straight` layout policy (§5.6) nothing compacts, so reservation
reduces to a birth-placement constraint alone; under the other three it is both
a birth constraint and a barrier the compaction moves stop at. No policy is
exempt — the reserved column is occupancy, and occupancy is universal (§5.1).

### 10.7 First-parent default

By default the graph opens **focused on the current branch**: HEAD's
first-parent mainline is shown in full and everything else — branches merged
into it *and* divergent branches — is collapsed. This is a per-owner **default
mode**, not a one-off seed: each reflow recomputes it, and `view state` holds
only the user's explicit overrides on top.

Under focus **every owner is first-parent-only** (§10.2) — each covers only its
own tip's first-parent line. The defaults are:

- the **pinned owners** (HEAD — attached or detached — pinned by default,
  §10.6) → **normal**; a pinned
  owner's first-parent line is the mainline (plus the history shared below
  merge-bases), so those stay visible;
- **every other owner** (unpinned refs — including the `worktree` refs of §3.2 —
  and the anonymous merge-parent and uncovered-tip owners of §10.2) →
  **collapsed**.

The trunk-only case (HEAD the sole anchor) is the default; "trunk" below reads
as "the pinned set" once more than one ref is pinned (§10.6).

Because the trunk is first-parent-only, it does not reach a merged-in branch, so
that branch's only owners are collapsed → it collapses, **even when a ref points
at it** (the ref defaults collapsed too). And because *every* owner is
first-parent-only, a branch is attributed to the commits on its own first-parent
line — so a feature ref does not reach the earlier features its history merged
through, and collapsing/expanding one branch (§10.4) affects only that branch
(branches genuinely built on top of one another are the exception — they share a
first-parent line and move together). A commit reachable only via collapsed
owners collapses; the shared mainline stays normal (the §10.2 join). The result
is "current branch in full, every other branch a `◍` head."

The user's explicit toggles (§10.4) override the default per owner, so any
collapsed branch can be expanded and any branch hidden.

This behavior is controlled by the **`collapse_merged`** option (default on) and
can be toggled live; with it off, every owner defaults **normal** (the plain
full graph) and no trunk/anonymous owners are introduced. A **detached** HEAD is
still the trunk — its owner is the `HEAD` ref (§10.6), so the checked-out
commit's first-parent line stays in full and the rest folds toward it. Only when
there is **no anchor at all** (no HEAD — e.g. an empty repository — no default
trunk branch and nothing pinned) does the graph fall back to all-normal.

### 10.8 Open / deferred

- **Adaptive layout** — Phase A packs only *consecutive* concurrent markers, so
  in a first-parent focus view (where each merged head sits between mainline
  commits, not next to other heads) packing rarely fires. Making it effective
  needs **reordering**: cluster concurrent markers into a band within their valid
  topological range (a merged head's range is its merge … its fork), then pack.
  Beyond that: *packing* junction markers (they already render node-less, §10.4,
  but don't yet share lines), and letting markers ride on message-bearing lines
  when they fit, toward a fully adaptive density (greedy row packing). Deferred.
- **Hidden connectivity** — phantom indicator vs. vanish.
- **Scale** — unbounded reads in large repositories; the loading strategy
  (limits, lazy/streamed loading, on-demand reachability) must keep reflow
  responsive. The open path no longer *blocks* on either half of this (§3.1
  streaming is incremental, §10.5's opening projection is sliced), but the total
  work is still linear in the whole history — a repository large enough still
  spends seconds projecting it, just without freezing. Bounding what is read and
  laid out at all remains open. The total is also a function of the repository's
  **shape**, not only its size: the per-commit signature is computed against the
  whole owner set (§10.2) and an owner is minted per non-first merge parent, so a
  trunk of merges costs several times what a linear history of the same length
  does. The phase breakdown of an open — the ref query, each streamed batch, then
  sort / owners / signatures / projection / layout / packing / apply, with the
  counts each scales with — is recorded by the armable `gitloom_open_trace`
  diagnostic (README → Diagnostics), so this is measured rather than estimated.
- **Auto-refresh** — history refresh (§3.4) is in place via the manual `R`
  resync; triggering it automatically when the repository changes underneath
  (watching `.git` refs / `HEAD` via an fs-event or autocmd, debounced) is a
  follow-up. Today a history change is mirrored only on `R` or reopen.
- **Toggle UX** — `<Space>` toggles collapse ⇄ expand and the `<C-Space>`
  palette's row entries set any mode (implemented); a picker for setting many at
  once is still future.
- **Context panes** — header/footer windows showing off-screen topology folded
  onto the pinned anchors (§10.6), with lanes continuous across the viewport
  boundary. To be specified in §6. Pane recomputation must be **asynchronous /
  debounced** and must never block or slow the main view's scroll and render.
- **Stronger-than-collapse fold** — contracting a non-anchor branch onto its
  boundary commit (the merge, or for squash-merged work the fork point) as a
  label + count with no head row or lane, a level between collapse and hide.
  Open refinement.

## 11. Commit view

`<CR>` on a commit row opens the **commit view** directly — no menu: a read-only
view pushed onto the host window's navigation stack (§14), showing the full
details of that one commit. The commit is the row's own (a §4.2 working-tree
row included, §11.8), the commit holding the ref selected with `h`/`l`, a
collapsed head's **tip** (the head's own hash is a synthetic id), or on a packed
line the selected marker's tip — the **first** marker's when none is selected.
While a §13 selection is active `<CR>` opens the range view instead (§13.5).
`<C-o>` returns to the graph; `q` hides the host window (§14.1). Like the
graph, it is a viewer — it never mutates the repository (§9; checkout, §10.4.1,
lives in the graph's command palette, not here).

The view's buffer is **named** `<root path> (gitloom) <view title>` — the graph
buffer's name (§2) plus the view's title without its `Commit ` prefix: the short
hash for one commit, the range title for a §13.5 range, the working-tree title
for §11.8 — so a GUI window title shows the repo path here too. Buffer names must
be unique: if the name is taken (the same view already open), the buffer is left
unnamed rather than failing to open.

### 11.1 Data source

The commit view's data is fetched **on demand** when it is opened — a single
`git show -s` for the selected commit's hash — *not* taken from the streaming
graph model. The graph model (§3, §4) deliberately carries only what the graph
needs (author, author date, subject); the richer per-commit detail (email,
committer, full message body) is read only when a commit is actually opened, so
the streaming path stays lean. The refs shown are the row's existing decorations
(§6), reused from the model rather than re-queried; so are each local branch's
upstream and ahead / behind counts (§6.3) in the **tracking** lines (§11.2). The
two tracking facts the ref read does not carry are fetched on demand alongside
the metadata, and only when the commit carries a local branch: per local branch,
its **push target** (`git rev-parse --symbolic-full-name <b>@{push}` — git's own
answer for `push.default` / `remote.pushDefault` / `branch.<b>.pushRemote`, which
gitloom does not re-implement; on failure git's `fatal:` line is kept as the
note), and — when the upstream does not match (§6.3) and a same-named remote
branch exists — that branch's counts
(`git rev-list --left-right --count refs/heads/<b>...refs/remotes/<r>/<b>`). A
failed count shows the line without counts; neither query ever blocks the view
from rendering the rest.

The diff is fetched the same way, on demand, by a second `git show --format= -p`
for the commit, chained after the metadata fetch; the view renders once both
arrive. The same on-demand fetch and formatter are reused by the commit-search
preview (§15.3), which leaves out the tracking lines (a preview follows the
cursor through the picker; it spawns no per-branch queries).

### 11.2 Content

The first line is the **diff action label** (§11.5) — when a diff provider is
configured — and the cursor is parked on it when the view opens, so `<CR>`
(open the commit view) then `<CR>` (on the focused label) opens the diff. Below
it the view shows, in order:

1. the full commit hash;
2. the ref decorations on the commit (the same compact groups as §6), when any,
   followed by the **tracking** lines of each **local branch** on the commit
   (below), when any;
3. the **author** — name, email, and date;
4. the **committer** — name, email, and date — shown **only when it differs**
   from the author (the common case where they match is omitted to reduce
   noise);
5. the parent commits (abbreviated hashes), when any;
6. the full commit message — subject and body — indented;
7. the **diffstat** — the list of changed files with per-file insertion /
   deletion counts (§11.4) — shown between the message and the diff;
8. the commit's diff (the patch), shown below the diffstat.

The author and committer dates are shown as `git show` renders them
(`--date=iso`); the structured `Timestamp` formatting of §6 applies to the graph
date column, not here.

**Tracking lines.** Each local branch on the commit (in its decoration order;
remote-only groups, tags and worktree labels get none) gets one `Tracking:` field,
at most three lines, spelling out what the compact §6.3 tokens abbreviate:

```
Refs:       (enne/standard-effect ↑origin →origin/dev ⇡4⇣6)
Tracking:   enne/standard-effect → origin/dev  4 ahead, 6 behind
              push: cannot resolve 'simple' push to a single destination
              same name: origin/enne/standard-effect  in sync
```

- **First line** — `<b> → <upstream>` and its state: `N ahead`, `M behind`,
  `N ahead, M behind`, `in sync`, or `gone`; `<b> → no upstream` when it tracks
  none. The upstream name takes the §6.3 colours: `palette.track.upstream` when it
  does not match, `palette.track.mismatch` when additionally a same-named remote
  branch exists.
- **`push:`** — the push target `@{push}` (short name), or git's reason when it
  cannot be resolved (as above: `push.default = simple` with a non-matching
  upstream); **omitted** when the push target is the upstream itself (the common
  case adds no line).
- **`same name:`** — only for a non-matching upstream, each existing
  `<r>/<b>` (remotes in `git remote` order) with its counts relative to the local
  branch (`3 ahead, 8 behind`, `in sync`).

So a plain `main` tracking `origin/main` that pushes there is the single line
`Tracking:   main → origin/main  in sync`. A §13.5 range view and the §11.8
working-tree view carry no tracking lines.

#### 11.2.1 Message wrapping

The commit message is **hard-wrapped** into real buffer lines — not soft-wrapped
with `'wrap'` — so every row below it (the diffstat, the diff, and the file-jump
and context-header bookkeeping of §11.4 / §11.6, which count buffer lines) stays
line-exact. Each message line, its 4-cell indent included, fits in the **wrap
width**: the view window's text width (the window width minus its sign / number /
fold columns), **capped at 100 display cells**, so a very wide window still gives
a readable measure. Widths are display cells (`strdisplaywidth`), so multibyte and
double-width text wraps correctly.

- The **subject** (the message's first line) wraps on its own at word boundaries,
  each continuation line at the subject's own column. It is never joined with the
  body.
- The **body** is **reflowed**: a paragraph — a run of consecutive non-blank
  lines — is joined with single spaces and re-wrapped at word boundaries.
- **List items** (`- `, `* `, `+ `, `1. `, `1) `, indented by fewer than four
  spaces) each start a new item. An item reflows like a paragraph, its
  continuation lines hanging-indented to the item's text; a following line
  indented no further than that text (a continuation, lazy or aligned) joins the
  item.
- **Kept verbatim** — never joined, never wrapped: blank lines; lines indented by
  two or more spaces or a tab (code, quoted output) that are not an item's
  continuation; a fenced block, from a ```` ``` ```` line through its closing
  fence; a line that is only a URL (or a `[n]: <url>` link reference); and git
  **trailer** lines (`Key: value`, `Key-Word: value` — `Signed-off-by:`,
  `Co-Authored-By:` …) in the final paragraph.
- A single word wider than the wrap width is **not broken**; it sits on its own
  line and overflows.

The wrap width is measured when the view renders, and the message is re-wrapped
in place when the window's width changes (`WinResized` / `VimResized` while the
view is shown) — the cursor and scroll are kept, shifted by the change in the
message's line count when they sit below it. The commit-search preview (§15.3)
wraps to its own window's width the same way. The range view (§13.5) shows no
message bodies — one subject per selected commit — and does not wrap.

### 11.3 Diff

The commit view shows the commit's diff below the diffstat (§11.4). Highlighting is
**line-level** (matching git's default and lazygit/tig): each patch line is
colored by its role — added, removed, hunk header (`@@ … @@`), and file header
(`diff --git`, `index`, `---`/`+++`, mode/rename/new-file lines); context lines
are uncolored. The highlight groups come from `palette.diff` (§8), using
always-defined UI groups by default, applied as extmarks — the view does **not**
switch the buffer to `filetype=diff`, so the custom metadata header above stays
unaffected. Language-aware (intra-line) syntax highlighting of the diff content
is a possible future enhancement. While the diff is scrolled, a **context
header** keeps the current file and hunk visible at the top of the view (§11.6).

A **submodule** bump (a `160000`-mode hunk whose body is two `Subproject commit`
lines) is intercepted and, when the conditions of §11.7 are met, augmented with a
small change graph in place of — or above — the two raw hashes.

### 11.4 Changed-files list (diffstat)

Between the message and the diff, the commit view shows a **diffstat**: a
summary line (`N files changed, X insertions(+), Y deletions(-)`) followed by one
line per changed file — the path, its insertion/deletion counts, and a colored
`+`/`-` bar (the `+` segment in `palette.diff.add`, the `-` in
`palette.diff.delete`; §8). Renames are shown as `old => new`; a binary file
shows `Bin` instead of counts.

The diffstat is **derived from the same patch** that §11.3 renders — not a
separate query — so the file list, the counts, and each file's location in the
diff all come from one source.

Pressing `<CR>` on a changed-file line **jumps** the cursor to that file's
section in the diff below (scrolling it to the top of the view). This makes the
diffstat a table of contents for the diff. The jump is recorded so `<C-o>` /
`<C-i>` move back to the diffstat and forward to the diff section as a
table-of-contents affordance **within** the view. When `<C-o>` would step back
*past* the view's own jumps, it pops the **navigation stack** (§14.3) —
returning to the graph (or whichever view pushed this one) rather than leaving a
dangling buffer. `<CR>` elsewhere in the view does nothing.

### 11.5 External diff

gitloom does not render a rich (side-by-side, syntax-highlighted) diff itself;
it **delegates** to an external diff plugin through a pluggable provider
(§8 `diff`). The provider operates on a **range**, not a single commit, so
richer commit selections on the graph can reuse it later (commit-vs-commit,
commit-vs-working-tree, a tag range, …); a single commit is just one way to
construct a range.

A `DiffRange` is `{ rev, from?, to, root? }`: `rev` is a git rev-range the diff tool
understands (e.g. `<hash>^!` for a commit's own changes, `<a>..<b>` for a span,
or an empty-tree range for a root commit), and `from`/`to` are the structured
endpoints. An endpoint is normally a `Commit` (`from` is `nil` for a root), but
for the working-tree virtual commits (§4.2) it may instead name a **tree state** —
`"index"` or `"worktree"` — so a range can run *to* the index or working tree
rather than to a commit (the staged node is `from = HEAD, to = "index"` with
`rev = "--cached"`; the unstaged node is `to = "worktree"` with `rev = "HEAD"`; the
untracked node reuses the unstaged node's range, having no range of its own).

A range also names the **repository** it belongs to: `root` is the graph's
repository root (§2.1). Every range gitloom hands the provider carries it — the
graph's `D`, the command palette, the commit view's action label, and the commit
selection (§13.5) alike — because that root need not be the repository at
Neovim's cwd: the graph may have been opened on a submodule, through the
repository picker, on an explicit path, or as a drilled-in submodule frame
(§11.7.6). A provider **must resolve `rev` in `root`**, not in the cwd; resolved
in the cwd, a commit is looked up in the wrong repository (it fails to parse, or —
for a working-tree range — silently diffs the cwd repository's working tree).
`root` is absent only for a range built outside a graph, where the cwd is the
only repository there is.

A `rev` naming **one** rev rather than an `<a>..<b>` span is the **working-tree**
form: the provider diffs that rev against the working tree (or, with `--cached`,
against the index). This is what preserves **LSP attachment** — the right-hand
side is the real file on disk, so it is editable and language servers attach to
it. A two-rev range has no working-tree side: both ends are built from git blobs,
which are read-only and have no path, so no LSP client attaches. The commit
selection (§13.5) relies on this: a range whose newer end is a working-tree node
emits a single rev for exactly this reason. The `--cached` form is the exception
that proves it — its head is the **index**, which likewise has no on-disk path, so
LSP does not attach there either; that is inherent to the index, not a defect.
**Checkout & examine** (§10.4.2) extends the same trick to any commit or range:
it checks the newer end out first, then opens a single-rev range on its base.

The provider's `open(range)` is
called to display it; the default opener runs diffview on `range.rev` **in
`range.root`** (diffview's `-C<root>`) and, when diffview is not installed,
reports that instead of erroring. Overriding `open`
(and `label`) switches to another diff plugin — diffview is therefore an
**optional dependency**, not required.

Two entry points construct a single-commit range (`<hash>^!`, or an empty-tree
range for a root) and call the provider:

- the graph's `D` key, on the commit under the cursor (§2);
- the commit view's **action label** — the first line, where the cursor parks on
  open (§11.2) — activated with `<CR>`.

The action label text is `diff.label` (default `▶ Open diff (diffview)`),
highlighted with `palette.action`. When no provider is configured (`diff.open`
is unset) the label is omitted and `D` is a no-op.

Graph-side range selection is realized by **commit selection** (§13): selecting a
range of commits along a branch constructs a `DiffRange` (`range_of`) and feeds it
to this same provider.

### 11.6 Diff context header

While scrolling the diff (§11.3), the commit view shows a **context header**: a
small borderless overlay pinned to the top of the view naming the location the
top of the **viewport** currently sits inside — independent of the cursor. It
carries up to **two lines**:

1. the **file** — the path from the governing `diff --git` / `+++` header;
2. the **hunk** — the governing `@@ … @@ <section>` line.

The **effective top** is the first diff row that remains visible *below* the
overlay — i.e. the window's top line advanced past the overlay's own height, so
the header never merely repeats a line it is covering. "Governing" means the
nearest file / hunk header at or above that effective top.

Each line appears **only when its real header has scrolled above** the effective
top; while a file's `diff --git` line or a hunk's `@@` line is still on screen
below the overlay, that line is omitted. So between a file header and its first
`@@`, only the file line shows; with neither scrolled off, the overlay is empty
(zero height) and invisible. The header is likewise absent while the viewport
top is still in the metadata / diffstat region (§11.2/§11.4) — it exists only
over the diff proper.

The two lines reuse the §11.3 diff highlight groups — the file line as a
`header`, the hunk line as a `hunk` (`palette.diff`, §8). The overlay never
takes focus and never mutates the buffer; like the graph context panes (§6.2)
it is pure decoration recomputed as the window scrolls.

### 11.7 Submodule change view

A commit that bumps a submodule pointer changes only an opaque value: the diff
(§11.3) carries the change as a `160000`-mode hunk whose body is the old and new
`Subproject commit <hash>` lines. Two hashes say *that* the submodule moved but
nothing about *how*. When the submodule's history is available locally, gitloom
replaces (or augments) that pair with a **small two-sided change graph** — drawn
from the submodule's own repository — visualizing the relationship between the
old commit `A` and the new commit `B`: the commits the bump **added** (green),
the commits it **removed** (red), and the **common ancestor** they descend to.

This is a graph-viewer feature, not general submodule support: gitloom reads the
already-checked-out submodule and **never fetches**. It is strictly read-only
(§9) and renders inline in the commit view's diff region.

#### 11.7.1 Availability — the gate

The change graph is shown **only when all** of the following hold; otherwise the
view falls back to the two raw `Subproject commit` hashes (§11.3), with a
one-line reason where useful:

- the hunk is a submodule change (`160000` mode, a `Subproject commit` pair);
- the submodule is **checked out** — its path (from the diff header) resolves to
  a working git repository;
- **both** `A` and `B` are **present** in that repository (resolve as commits).

No fetching is attempted to satisfy the last two. A missing checkout or a missing
commit is an expected, non-error state — the raw hashes remain, annotated
(e.g. "submodule not checked out", "commits not present locally").

#### 11.7.2 Classification — the relationship

When the gate passes, the old/new pair is classified by their relationship in the
submodule's DAG, computed from the **merge-base** of `A` (old) and `B` (new):

- **Fast-forward** (`A` is an ancestor of `B`, so `base == A`) — a forward bump.
- **Rewind** (`B` is an ancestor of `A`, so `base == B`) — the pointer moved
  backward.
- **Diverged** (a merge-base exists but neither reaches the other) — the two
  pointers sit on branches that forked at the merge-base.
- **Unrelated** (no merge-base — disjoint histories) — falls back to the raw
  hashes (§11.7.1), noting the histories are unrelated.

The first three (**fast-forward, rewind, diverged**) share **one renderer**
(§11.7.3): a two-sided change graph descending to the shared merge-base.
Fast-forward and rewind are its degenerate cases — one side is empty because the
merge-base *is* the old (resp. new) pointer. Only **unrelated** is special,
falling back to the raw hashes. Direction is intrinsic: `A` is always the old
pointer and `B` the new, so a fast-forward and a rewind are told apart by which
one is the ancestor, never by a heuristic.

#### 11.7.3 What is shown — both sides, marked, evenly truncated

When a merge-base exists the change graph draws **both first-parent lines** that
meet at it as a small two-lane graph (a Y) descending to the shared ancestor:

1. **The new side** — `git log --first-parent base..B`, the commits the bump
   **brings in**. Its markers/lane are the **added** colour
   (`palette.submodule.new`, green by default); its top row is the **new pointer
   `B`**, marked.
2. **The old side** — `git log --first-parent base..A`, the commits the bump
   **rolls back**. Its markers/lane are the **removed** colour
   (`palette.submodule.old`, red by default); its top row is the **old pointer
   `A`**, marked.
3. **The common ancestor** — the merge-base, a single shared node at the bottom
   where the two lines converge, in the **ancestor** colour
   (`palette.submodule.base`, the first lane colour — `palette.tracks[1]` — by
   default).

The **graph markers/lanes** and the commit **hash** carry these colours
(foreground only); the commit **subject** stays in the view's neutral colour, so
the message reads normally rather than tinted like a diff.

Each side is **first-parent**, so it is a linear line: a merge on it stays one
node and its merged-in side branch is not pulled in (the same first-parent focus
the main graph uses, §10.7 — no lane that "comes from nowhere" because the range
boundary cut a side branch off). The full-merge traversal (`base..tip` with every
parent) is a possible later option (§11.7.5).

The commits carry the submodule repository's **own ref decorations** (§6) where
refs actually point — gathered the stable way (refs *pointing at* a commit, via
git's own `%d` decoration), **never** by walking forward toward children. gitloom
does **not** guess a "current branch" for either side; a label appears only
because a ref genuinely lands on that commit.

**Mark the pointers.** `B` is the top of the new (green) side and `A` the top of
the old (red) side; both are labelled so it is clear which row the submodule moved
*from* and *to*. In the degenerate cases one side is empty and its pointer
coincides with the ancestor: a **fast-forward** marks the ancestor row as the
**old** pointer (the new side carries the bump's commits up to `B`); a **rewind**
marks it as the **new** pointer.

**Even truncation.** The graph is bounded by a fixed height (`SUBMODULE_MAX`).
One row is reserved for the shared ancestor; the remaining budget is split
**evenly** between the two sides. Each side is truncated **newest-first**, so its
pointer head is always kept, with a "+K more" marker for the commits elided
between the kept newest and the ancestor. When **one side is empty** (a
fast-forward or rewind) the other side takes the **whole** budget; likewise any
share a short side does not use **spills** to the other. The commits are shown in
full (not condensed): collapsing the linear stretches would hide the very commits
the bump moved through, which is the point.

The **detail level** of a kept commit — topology-only (graph + ref labels, like
the panes) versus showing the subject — is an open point expected to iterate
(§11.7.5); the structure above (gate, classification, both-sides / mark /
even-truncate) is the stable contract.

#### 11.7.4 Fetching and rendering

The submodule queries are **on demand and asynchronous**, like the rest of the
commit view (§11.1). The diff first renders with the raw `Subproject commit`
hashes; when the submodule data resolves, the change graph **replaces them in
place** (progressive enhancement), so a large or slow submodule never blocks the
diff. The queries fire **only** for an actual `160000` hunk that passes the gate
(§11.7.1); a commit that touches no submodule does no extra work. A commit
bumping several submodules gets one change graph per submodule.

#### 11.7.5 Open points

- **Detail level** (§11.7.3): the change graph currently shows both first-parent
  sides with per-commit subjects; a topology-only or condensed rendering
  (collapsing the linear stretches between junctions) is a likely configurable
  refinement, defaulting conservatively.
- **Full-merge traversal** (§11.7.3): an option to walk *all* parents
  (`base..tip` instead of `--first-parent`) so merged-in side branches show — at
  the cost of lanes that dangle where the range boundary cuts a side branch off.
  Deferred; first-parent is the cleaner default.
- **Named divergence**: when no ref points at `B`, a stable "B is on `X`, N
  behind its tip" line (from refs *containing* `B`, when exactly one) could name
  the new pointer's home — deferred, fragile when several branches contain it.
- **Nested submodules** are out of scope for the first cut.

#### 11.7.6 Opening the submodule's repository

Each **commit row** in the change graph (§11.7.3) is a **link into the
submodule's own repository**: pressing `<CR>` on a submodule commit line opens
the graph for that submodule (§2.1), **focused on the commit under the cursor**
— the new-pointer side, the old-pointer side, or the shared ancestor, whichever
row the cursor is on. The submodule repository is opened by its path (the change
graph's `path`, resolved to the submodule's git top level); the open **pushes a
navigation-stack entry** in the current host window (§14.7), so `<C-o>` returns
to the commit view. Because it crosses into another repository, the entry seeds
from the submodule's own view state with the pointers injected as anchors
(§14.4, and below) — it is not the submodule's own host window (§14.5).

**Bump context — the old and new pointers are virtual refs.** However the link
is entered, the opened submodule graph marks both pointers as **synthetic refs**:
a green **`new`** ref on the new pointer (`B`) and a red **`old`** ref on the old
pointer (`A`) (`palette.submodule.new` / `old`, the change view's colours). They
are ordinary ref decorations (§6) in every respect except origin — they are not
git refs — so they:

- render as labelled decorations on their commits in the main view **and in the
  context panes** (§6.2), in their colour;
- are **pinned as anchors** (§10.6) by default, which both **reveals** their
  branches (the first-parent default, §10.7, keeps a pinned anchor's line shown,
  so a pointer on an otherwise-collapsed branch appears as a real commit rather
  than folding into a `◍`) and keeps them **named in the header/footer panes** as
  you scroll away from them; and
- appear in the **ref picker** (§2 `<leader>b`), so you can jump between the two
  pointers.

The cursor focuses the **clicked** commit (also revealed, by hash, in case it is
an intermediate rather than a pointer). A pointer not present in the opened graph
(e.g. an orphaned old pointer unreachable from any ref) is simply not added; if
the *focused* commit is absent, focus falls back to HEAD (§2). Other lines (the
header, the "+K more" elision, a non-available block) are not links.

The synthetic refs are **transient** — a resync (§3.4) re-reads the real refs and
drops them; reopen the link to restore them. A `Ref` may carry an optional
highlight override (`hl`), which is what gives `new`/`old` their colours; this is
the first use of that mechanism.

### 11.8 Working-tree commit view

Opening the commit view (§11) on a **virtual commit** (§4.2) shows the
uncommitted change it stands for. It reuses the §11 machinery — the diffstat
(§11.4), the line-level diff (§11.3), the context header (§11.6), and the diff
action label (§11.5) — but the data sources differ, branched on `Commit.virtual`:

- the **metadata** region is not a `git show -s` (there is no commit object).
  Instead it is a short working-tree summary: a title naming the state (staged /
  unstaged / untracked) and the changed-file count (the untracked node counts the
  untracked files). There is no hash, author, committer, or parent list;
- the **diff** is the node's own patch from §3.3 — `git diff --cached` for the
  staged node, `git diff` (tracked only) for the unstaged node, the synthesized
  untracked additions for the untracked node — fed through the *same* diffstat and
  diff pipeline as a real commit, so the file list, counts, and per-file jumps all
  work unchanged;
- the **action label** and `D` open the node's working-tree `DiffRange` (§11.5)
  in the external provider — the index or the working tree, not a commit range.
  The untracked node reuses the unstaged node's working-tree range (the untracked
  files have no git-tracked counterpart, so there is no range of their own).

Like the rest of the commit view it is strictly read-only (§9): it shows the
staged/unstaged/untracked diff but offers no way to stage, unstage, or commit
from it.

**The clean node** has no diff to show. Its commit view is the metadata region
— the title `Working tree clean` and the line `matches HEAD <short>` (HEAD's
commit, from the cached refs) — followed by an empty diffstat (`no changes`). No
git is spawned for it: the clean state is the last working-tree refresh's
(§3.4), and opening the view does not re-check it. The diff **action label** and
`D` are kept and open the working tree against HEAD (single rev `<HEAD hash>`,
`to = "worktree"`) — the same, empty, range as **Examine working tree**
(§10.4.2) — so the row behaves like every other working-tree row. A **range**
whose newer end is the clean node (§13.5) is an ordinary working-tree range and
shows its combined diff as usual — the clean row only contributes its `working`
line to the range list.

## 12. Reachability emphasis

The row under the cursor defines a **pivot** commit. gitloom continuously
de-emphasises everything not causally related to the pivot, so the pivot's
history and what descends from it stand out.

### 12.1 The causal cone

The pivot's **cone** is computed by walking the **Lane graph** (§5) from the
pivot in two monotonic sweeps:

- **ancestors** — follow `parent_lanes` (each leads to a parent), recursing;
- **descendants** — follow `child_lanes` (each leads to a child), recursing.

Every Lane reached is set `highlighted`, and the commits it connects (`begin`,
`end`) form the cone. Because each Lane is one edge, the walk is exact: at a
shared fan, the pivot's edge is a distinct Lane from a sibling's, so only the
pivot's edges light. Each sweep never reverses direction, so the cone is exactly
the commits causally related to the pivot — not the whole connected component.

The walk stays within the **currently visible rows**. Because rows are in
topological order (a parent is always at a later row than its child), restricting
to the contiguous viewport loses nothing about relationships *between* on-screen
commits — it only clips the *recursion* at the viewport edges. A cone Lane whose
far endpoint is off-screen is still highlighted (its on-screen stub lights); the
walk simply does not recurse past it.

### 12.2 Dimming

Content **outside** the cone is rendered **dimmed**; the cone keeps full colour:

- a commit **row** — its date, author, message, refs, and commit marker — dims
  when that commit is not in the cone (not a `begin`/`end` of any highlighted
  Lane). Its ref labels, drawn in their node's lane colour (§6), dim as that
  lane does: the same hue-preserving blend of the lane colour (the flat
  fallback without true colour), not a generic dim group; a packed marker's
  labels dim with that marker, a pane label with its pane row;
- a **Segment** dims unless a Lane it carries is highlighted. Because a Segment
  carries the exact edge(s) it draws (§5.1), a cone wire stays lit through every
  split and merge it passes — including the shared descent/ascent Segment at a
  separate split/merge hub, lit when one of *its* converging edges is in the cone
  — while an unrelated bar it crosses stays dim.

A Column's glyph is the union of the connectivity of its **highlighted**
Segments (or of all of them when none is highlighted), so at a junction the arms
leading only to out-of-cone edges drop to a small gap while the cone arms stay
connected; a vertical crossing is left whole. The glyph takes the colour of a
highlighted Lane it carries when one is present (so the cone colour wins a shared
cell), else the §5 default.

Dimming preserves colour identity rather than flattening to one grey: each
field's / Lane's own highlight colour is blended toward the window background by
`palette.dim` (§8), so a dimmed Lane keeps its hue and stays individually
recognisable. On terminals without true colour, dimming falls back to a single
flat highlight group (`NonText`). A remote counterpart lane (§5.5) is already
lightly dimmed in the cone (`counterpart_dim`, default `0.25`). Out of the cone
the dims do **not** compose: its slot colour is blended by
`palette.counterpart_dim_out` (§8), **default `0.75 × palette.dim`** (`0.3375` at
the default `dim`), so an out-of-cone counterpart lane reads a shade **brighter**
than every other dimmed lane — its own pinned lane's included — while still dim.
In the cone: pinned lane full, counterpart `0.25`, others full; out of it: pinned
lane and others `dim`, counterpart `0.75 × dim`. Its label follows (§6 "Label
colour"). Without true colour every out-of-cone lane, a counterpart's included,
takes the flat fallback.

The emphasis is **on by default** and follows the cursor; it is recomputed when
the cursor moves to a new row and when the view scrolls (the window-bounded cone
tracks the visible rows). Those recomputes are **debounced** — only the last,
once the cursor settles, walks the cone — so fast `j`/`k` navigation stays
responsive. `H` toggles it off and on live (and `highlight`
configures the initial state, §8) — when off, the whole graph renders at full
colour, **identical regardless of the cursor row** (highlight state never affects
colour while it is off).

The **context panes (§6.2)** participate in the same emphasis: off-screen
topology dims with the cone too. The cone walk above is window-bounded, but it
still lights the *stub* of every cone Lane crossing the viewport edge, so the
panes recover in-cone membership from those seam-crossing lanes and propagate it
over their own small graph (§6.2 "Reachability emphasis") — the dimming reaches
into the header and footer without ever walking the off-screen history.

Lane-anchored navigation is realized as the single-commit case of **commit
selection** (§13): stepping along a branch's lanes commit-to-commit, with splits
and merges chosen explicitly, builds directly on this Lane model and the §2
selection substrate.

## 13. Commit selection (range)

A modal selection that picks a **range of commits along one branch** and feeds it
to the range-aware diff provider (§11.5) and a range mode of the commit view
(§11). It is read-only (§9) — it selects and inspects, never mutates. It builds on
the §2 ref-selection substrate (the cursor moves onto the thing selected), the
Lane model (§5), and the §12 reachability walk (reused for both traversal and
emphasis).

### 13.1 The selection model

`V` enters **selection mode** on the row under the cursor; `V` again or `<Esc>`
exits (the footer shows it is active). On entry the row's commit becomes both the
**anchor** (the fixed end, where `V` was pressed) and the **cursor** (the moving
end).

The selection is a **path along one branch**, not a contiguous range of buffer
rows: the commits on the first-parent chain between the anchor and the cursor,
walked over the **Lane graph** (§5). Rows between them that belong to *other*
branches are skipped — the selection covers only the followed branch's own
commits.

- It traverses the **visible projection** (`repo.display`, §10): a **collapsed
  head** (§10.3) is one selectable unit standing for its whole region — including
  it in the path includes all of that region's commits in the range.
- The path is always an ancestry chain (anchor and cursor are joined by
  first-parent edges), so it has a well-defined **older** end and **newer** end
  regardless of which is the anchor.

### 13.2 Movement

- `j` / `k` step the cursor to the next / previous commit **on the followed
  branch**, skipping intervening other-branch rows; the view scrolls to keep it
  visible. The cursor parks **on the graph lane column** of the followed branch
  (the §2 cursor-on-decoration behavior), so the lit lane shows which branch is
  selected — or, when the moving end is a collapsed head packed onto a shared
  line (§10.4), on that head's label (§13.4).
- `<C-d>` / `<C-u>` move by roughly a half-viewport's worth of **branch** commits
  (not buffer lines), so the jump stays on the branch even when its next commit is
  off the current page.
- `o` swaps the anchor and the cursor (as visual-mode `o`): the moving end becomes
  the other end; the path itself is unchanged.
- Movement clamps at the branch tip / root and at the fetched-range boundary.
- The **working-tree virtual commits** (§4.2) **are** selectable, but only as the
  **newer** end. A selection may start on one (`V` on a working-tree row) and may
  ascend into one (`k` from HEAD walks into the stack HEAD → staged → unstaged →
  untracked, or HEAD → clean on a clean tree). Because the stack is always
  present (§3.3), the working tree is always a reachable newer end — on a clean
  tree too, where `V` on the clean row and `j` down to a commit selects "that
  commit through the working tree". This is structural, not a rule the walk has to enforce: a virtual
  commit has no children (§4.2), so ascending into one ends there and it can only
  ever be the path's newest member. Everything below it on the path is a real
  commit.
- A virtual endpoint does **not** put its hash into a git rev. Its sentinel hash is
  not a git object, so a range ending at one denotes a **tree state** (`"index"` /
  `"worktree"`) rather than a commit — see §13.5. The range builder is where that
  mapping happens, so no caller can leak a sentinel into a `git diff`.

### 13.3 Branch switching at junctions

When the path is **not linear**, `h` / `l` rotate which branch it follows at the
**nearest junction between the cursor and the anchor**, on the side the path is
growing:

- anchor **above** the cursor (the selection grew **downward**, toward parents):
  walk **up** from the cursor to the nearest **merge** in the path; `h` / `l`
  rotate which **parent** the tail descends (in lane order — `l` the next, `h` the
  previous);
- cursor **above** the anchor (the selection grew **upward**, toward children):
  walk **down** from the cursor to the nearest **split**; `h` / `l` rotate which
  **child** the path ascends;
- a strictly linear path (no junction between the two ends) → `h` / `l` is a
  **no-op** (there is no branch to switch to).

The rotation follows the **rendered** lane order: under mirroring (§5.4, lane 1
at the right) it is reversed, so `l` always moves toward the branch drawn to the
right and `h` toward the left, matching how the graph reads.

After a switch the cursor **stays on its current row** when the newly-chosen
branch has a lane there, snapping to the nearest commit on the new branch
otherwise; `j` / `k` then walks the new branch. The path is re-derived from the
rotated junction onward; the portion between the anchor and the junction is
unchanged.

Outside selection mode `h` / `l` keep their §2 meaning (cycling the row's ref
decorations). The two never coexist: entering selection mode resets the ref
selection, and exiting restores the default message position.

### 13.4 Emphasis

While selection is active, the **selected path** is the emphasised set: its
commits and lanes stay full-colour and everything else dims, reusing the §12
machinery. This **replaces** the cursor-pivot cone for the duration; the pivot
cone returns when selection mode exits. `H` (§12) still toggles dimming off and
on.

A **collapsed head** (§10.3) on the path is emphasised like any other path
member — its marker and the lane joining it to the path light. On a **packed
marker line** (§10.4), which carries several concurrent heads, only the path's
head is lit and it is drawn with `palette.selected` (and the cursor parks on its
label); the other heads on that line dim. So the right head on a shared line is
unambiguous even though the line holds many.

`<Space>` while selecting **folds / unfolds the head under the cursor in place**
(the §10.4 collapse⇄expand toggle, scoped to the selection): it expands the
collapsed head the cursor sits on (or collapses the cursor's region) — acting on
the commit's own owners (§10.2), as `<Space>` does outside a selection —
**without changing what is selected**. An unfolded head expands into its **whole region**,
so the revealed branch stays selected and lit (not just its tip); a collapsed run
maps back to its head. The **diff range is therefore unchanged** by fold/unfold.
The anchor keeps its end and the cursor lands on the toggled (opposite) end, and
the saved scroll position is restored so the rows above the toggle stay put. It
is a no-op on a mainline commit (nothing there is collapsible).

### 13.5 Range and the commit view

The selection defines a **`DiffRange`** (§11.5): `to` is the **newer** end's
commit, `from` is the **parent of the older** end's commit (the empty tree when
the older end is a root), and `rev` is `<older>^..<newer>` (an empty-tree range
when rooted). This is the **literal** range — the combined patch between the two
ends, **including any side merged in** along the path when it crosses a merge
(restricting it to the followed branch's own first-parent changes is an open
refinement, §13.6). `range_endpoints(newer, older, root)` constructs it beside the
single-commit `commit_range` (§11.5), carrying the graph's repository `root`.

**A range ending at the working tree.** When the **newer** end is a working-tree
virtual commit (§4.2 — the only end it can be, §13.2) the range does not name two
commits: its head is a **tree state**, so `to` is `"index"` or `"worktree"` and
`rev` is a **single rev**, not an `<a>..<b>` span. `from` (and the base in `rev`)
is still the older end's first parent, exactly as for a commit span. Which node
the selection actually reached decides the form:

| newer end | `rev` | `from` | `to` | in-graph patch |
|---|---|---|---|---|
| `staged` | `--cached <base>` | `<base>` | `"index"` | `git diff --cached <base>` |
| `unstaged` | `<base>` | `<base>` | `"worktree"` | `git diff <base>` |
| `untracked` | `<base>` | `<base>` | `"worktree"` | `git diff <base>` + the synthesized untracked additions (§3.3) |
| `clean` | `<base>` | `<base>` | `"worktree"` | `git diff <base>` (the working tree equals HEAD, so this is `<base>..HEAD`'s content, on disk) |

The single-rev form is the point, not an implementation detail: a two-rev range
makes the diff provider build both sides from git blobs, which are read-only and
have no path on disk, whereas a single rev diffs against the **working tree** and
opens the real files — so LSP clients attach and the files are editable (§11.5).

`<base>` is the older end's first parent. It degenerates the same way a commit
span does, and the same way *up* the worktree stack:

- the older end is a **root** → `from` is `nil` and the base is the empty tree;
- the older end is itself a virtual commit (a selection that covers only
  working-tree rows) → its first parent is the next node **down the stack**, which
  is another tree state: the `staged` node is `"index"`, the `unstaged` /
  `untracked` nodes are `"worktree"`. `rev` is then the empty string — the
  provider's own default, working tree vs index. A sentinel hash is never read.
  When that next node down is HEAD's real commit (the bottom of the stack — e.g.
  the clean node selected alone) the base is HEAD's hash, as for any real parent;
  for the clean node the range is then empty.

The **staged** endpoint is the one case that does *not* get on-disk files: its
head is the index, whose content has no path in the working tree. That is
inherent to what the index is, not a gap — `--cached` is exactly the right
answer, and the files it shows are read-only for the same reason `git show` output
is.

The untracked endpoint reuses the §3.3 synthesized additions
(`git diff --no-index -- /dev/null <file>`, capped) for the **in-graph** view,
because `git diff <base>` never lists untracked files: without them an untracked
endpoint would render byte-identically to an unstaged one, and the selection the
user made would have no visible effect. The **external** provider needs nothing
extra — a working-tree view lists untracked files itself — so `rev` is unchanged.

`<CR>` in selection mode opens the **commit view** (§11) in **range mode**: the
metadata region lists the selected commits (newest first — abbreviated hash +
subject) in place of the single-commit fields, followed by the **diffstat** and
the **combined diff** (§11.3 / §11.4) for the range. Its diff **action label**
(§11.5) opens the same range in the external diff viewer; `D` likewise opens the
range while selection is active.

If the range diff **fails**, the view says so: git's exit code and its own error
message replace the diffstat/diff region (and are notified), instead of the
commit list appearing over an empty diff. The two are otherwise
indistinguishable — a range that genuinely changed nothing looks exactly like a
`git diff` that never ran — and this range's endpoints are *derived* (`from` is
the older end's first parent, `to` the newer end), so a failure is a real
possibility rather than a typo the user can see.

### 13.6 Open / deferred

- **First-parent-restricted range** — the literal `from..to` pulls in a merged-in
  side when the path crosses a merge; restricting the diff to the followed
  branch's own commits needs a synthesized range the provider understands (§13.5).
- **Selection across hidden regions** — a path that would cross a §10 *hidden*
  region (whose boundary edge is dropped, §10.3) follows the §10.8
  hidden-connectivity open question.
- **`<C-d>` / `<C-u>` step count** — the exact "half-viewport of branch commits"
  count is a tuning point, expected to need iteration.

## 14. Windows, views, and navigation

gitloom presents **one host window per repository**, and you navigate **within**
it rather than between stacked windows. This supersedes the earlier model (§2.1)
in which opening a repository pushed an independent floating window over the
previous one. The benefits: `<C-o>` / `<C-i>` history lives inside a single
window (no hopping between windows, no z-order juggling), and the context panes
(§6.2) attach to whichever view is shown rather than fighting modal windows for
stacking order.

Two tiers, with two different kinds of identity:

- **Host windows** (tier 1) are keyed by **repository root** (§2.1) — one per
  repository you have explicitly entered.
- **Views** (tier 2) are what you navigate to *inside* a host window — the
  graph, a commit view (§11), a filtered graph, a range view (§13.5). They are
  identified by their **position in the window's navigation stack**, never by
  content.

### 14.1 The host window (per repository)

- A host window is a single floating window bound to one repository root. The
  first time a repository is opened it is created; thereafter it is **hidden and
  re-shown**, never duplicated. Its navigation stack (§14.3) and per-repository
  view state (§2) persist while it is hidden.
- **`q`** **hides** the current host window: it leaves the screen but its
  navigation stack (§14.3) and view state are retained. **`<C-w>q`** instead
  **destroys** the window and **clears its stack** (wiping the views' buffers,
  §14.5) — the explicit teardown; hiding is the cheap default.
- **`<leader>wg`** **returns** to the most-recently-open host window, re-showing
  the stack you last left at exactly where you were. It is the counterpart to
  `q` — `q` closes, `<leader>wg` reopens. With no hidden window to return to it
  opens the repository at Neovim's cwd (the default entry point, §2).
- **`<leader>wG`** opens the **repository picker** to choose *another*
  (sub)repository (§2.1) — the main module and its submodules — and shows its
  host window, creating it on first entry (re-showing it if already open). This
  is the explicit cross-repository switcher (replacing the old
  picker-stacks-a-window behaviour, §2.1).
- **`<C-o>` / `<C-i>`** are **purely** for moving between breadcrumbs along the
  current window's stack (§14.3); they do not switch windows or repositories.
- Window count is bounded by the repositories you **explicitly enter**, not by
  the repositories you glance at: following a submodule link (§14.7) pushes a
  *view* in the current window (tier 2); it does **not** create that submodule's
  host window. A submodule gets its own host window only via `<leader>wG`.
- **Z-order.** The host is a full-screen *application* window, so it sits
  **below other plugins' floats** — progress / notification floats (e.g.
  fidget, oil, mason at 44–45), pickers, `vim.ui.select` and notifications
  (50+) draw over it — but **above the float decorations of ordinary windows**
  (sticky context, scrollbars: 20–40), which must not show through it. It is
  created at the `zindex` option (§8, default `41`), and gitloom's own layers are
  fixed offsets above it: the **overlays** (context panes §6.2, the commit-view
  sticky header §11) at host + 1 and gitloom's **transient floats** (`?` / `K`,
  the pin dialog, the filter prompt, its own pickers) at host + 2 — so `41` /
  `42` / `43` by default. The offsets are taken from the host's *live* zindex,
  since a hidden host re-shows as a new window. Floats gitloom merely invokes but
  does not own (a plain snacks picker such as the ref picker, `vim.ui.select`)
  keep their own zindex.

### 14.2 Views and modifiers

A **view** is a pure projection of the repository's immutable commit DAG (§3,
§4) together with:

- **Intrinsic modifiers** — what *defines* this view: its **scope** (the full
  graph; a commit, §11; a branch; a range, §13) and any **filters** (e.g. a file
  filter — only the commits touching a given path). Modifiers belong to the entry
  that introduced them.
- **View state** — the per-owner mode / pin overrides (§10) resolved against the
  defaults. View state is *not* part of a view's identity (§14.5); it is carried
  per entry and forked on push (§14.4).

A modifier that changes **which commits are laid out** (a filter, a different
scope) defines a **distinct view** — navigating to it pushes a new stack entry
(§14.3). A change that only **refocuses** the same content (centering on a
commit, moving the cursor) is navigation *within* the current view, not a new
entry.

The **file filter** is the canonical view-local modifier: it changes content for
one view only, may be applied from any context, and never leaks to any other
view — because it lives on the entry, not the repository.

### 14.3 The navigation stack

Each host window owns one **navigation stack** — an ordered trail of view
entries, the tier-2 unit.

- **Identity is positional.** Each entry is a distinct instance
  (`{ scope, modifiers, view-state, buffer }`); two entries with identical
  modifiers are still distinct. There is **no content-addressed dedup** at this
  tier (cf. §14.5).
- **Push.** Content-changing navigation (open a commit, apply / clear a filter,
  follow a submodule link, change scope) pushes a new entry on top of the
  current one.
- **`<C-o>` / `<C-i>`** are **hybrid**: they first walk the **in-buffer jumplist**
  — so they return to where you were before an in-graph jump (a filter `<CR>`
  §16.4, a ref-pick §2), the natural Vim feel — and only step back / forward along
  the **stack** once the jumplist would leave the current buffer. The stack itself
  is the drill-down-and-return tier (a commit view, a submodule); the jumplist is
  the within-view tier. (Ordinary `j`/`k` motion does not touch the jumplist, so it
  holds only real jumps; the commit view applies the same rule to its diffstat
  jumps, §11.4.)
- **Truncate on branch.** Going back and then navigating somewhere new
  **discards the forward tail** and wipes those entries' buffers (§14.5). The
  trail always reflects a single path from its root to the current entry.
- A **depth cap** bounds memory as a backstop; entries beyond it are wiped when
  nothing in the live stack references them.

### 14.4 Fork-on-push (state inheritance)

When an entry is pushed it inherits a **copy** of its parent entry's current view
state and then **diverges**:

- State present at fork time crosses to the child (pin a branch in the graph,
  *then* apply a filter → the filtered view starts with that pin).
- Nothing flows **back**: edits in the child never reach the parent.
- The fork is taken **at push time only**: the parent's *later* edits do not
  propagate to an already-open child (pure fork, not live sharing).

**Fork stops at the repository boundary.** When a push crosses into a different
repository (a submodule drill-in, §14.7), the parent's view state — keyed by the
parent repo's ref names — is meaningless in the child. The child instead seeds
from **its own repository's view state** (§2, and the durable state of §14.8 when
present) plus the **injected modifiers** the link supplies (e.g. the pinned
old / new submodule commits).

### 14.5 Identity, dedup, and lifetime

The two tiers dedup differently, and that difference is load-bearing:

- **Host windows dedup by repository root.** `<leader>wG` to an already-open
  repository re-shows its window; it does not create a second one.
- **Stack entries never dedup.** A view reached by *clearing* a filter is a
  **new** entry, distinct from a lower entry that merely happens to have no
  filter; a submodule drilled into from a commit (§14.7) is a **different
  instance** from the same submodule opened as its own host window. Positional
  identity is exactly what lets the same repository content appear both as a
  tier-2 entry (with injected context) and as a tier-1 window (without), with no
  special-casing.

Lifetime follows the stack:

- An entry's buffer lives as long as the entry is in a stack. It is wiped when
  the entry is truncated (§14.3) or its host window is destroyed (`<C-w>q`,
  §14.1).
- Hiding a host window (`q`) wipes nothing — the stack and its buffers are
  retained for re-show.

### 14.6 Breadcrumbs

Navigation here is **drill-down-and-return**, not the forward-dominant motion of
ordinary buffer editing. To keep the trail legible the host window shows a
**breadcrumb** of the current path — root → … → current entry (e.g.
`graph › commit a1b2c3d › graph · file:foo.lua`):

- The breadcrumb shows the **back-trail only**; forward history (`<C-i>`
  targets) is hidden, so the display stays minimal.
- Jumping to a crumb moves back to that entry and **truncates** the trail beyond
  it (§14.3), wiping the abandoned tail. This is the cheap way to collapse a deep
  excursion.
- For the graph view the breadcrumb shares the header with the context-pane seam
  (§6.2); the header is the view's "where am I" surface generally.

### 14.7 Submodule drill-in (worked example)

The commit-view submodule link (§11.7.6) is a tier-2 push that crosses a
repository boundary, and it exercises every part of this model:

1. In the **main** repository's host window: graph → open a commit carrying a
   submodule update → follow the submodule link.
2. This **pushes a stack entry** in the main window whose content is the
   **submodule's** graph, scoped / anchored by **injected modifiers** — the
   submodule's old and new commits pinned (§10.6) so the update is framed. It
   seeds from the submodule's own view state, not the main repo's (§14.4), and is
   **not** that submodule's host window.
3. `<C-o>` returns to the main repo's commit view; the drilled-in submodule entry
   stays in the main window's stack and is restored on return.
4. Opening the **same submodule** via `<leader>wG` creates its **own host
   window** with a fresh stack and **no injected context** — a deliberately
   distinct instance (§14.5).

A drilled-in submodule view requires the injected commits to be present locally;
if the submodule is not checked out / fetched, the view degrades gracefully (an
operational concern, not a model rule).

### 14.8 Durable state ownership

When per-repository view state is persisted (§18 — today the pin list), only a repository's **own host window** writes it, and only
from that window's **root (canonical) entry**. A drilled-in instance of a
repository (§14.7) **reads** the durable state as a seed but never writes back —
it is mid-stack in another repository's window, not canonical. So exploring a
submodule update can never quietly mutate the submodule's saved layout.

### 14.9 Open / deferred

- **Disk persistence** of the remaining durable view state — collapse / expand
  overrides — is deferred; the pin list and the view toggles are persisted (§18).
- **Cold rebuild.** Hiding (`q`) retains buffers, so re-show is instant.
  Rebuilding a destroyed entry from a serialized descriptor (scope + modifiers +
  state snapshot) — to survive a full teardown or a Neovim restart — would reuse
  the same descriptor used for breadcrumb labels (§14.6); not yet specified.
- **Live parent→child propagation.** Fork-on-push (§14.4) is deliberately a
  one-time copy; a model where a parent's later edits flow into already-open
  children (copy-on-write sharing) is materially more complex and is not adopted
  unless a concrete case demands it.
- **Modifier surface.** The concrete set of filters / scopes (file, path glob,
  author, …) and the keys that apply / clear them are enumerated as they are
  built; the machinery (§14.2–§14.5) is independent of which modifiers exist.

## 15. Commit search

`<leader>gl` opens a **commit search** picker (snacks.picker) over the
repository's commit set — a fuzzy finder across every commit in the model, with a
preview that shows the commit (§11) alongside a snippet of the graph locating it.
Selecting a result moves the cursor to that commit and centers the graph on it.
Like everything else, it is read-only (§9). `:GitloomSearch` is the command
equivalent. (Plain `/` is the in-graph **filter-search**, §16 — a different tool:
it narrows the graph to matching commits as a view modifier rather than jumping
to one.)

### 15.1 Entry point

`<leader>gl` (and `:GitloomSearch`) opens the picker immediately, populated from
the in-memory commit model (§3, §4) — the same `--all` set the graph laid out, in
`repo.order`. No git query is run: the searchable fields are already resident.
The picker lists one entry per commit; result rows follow snacks' native
`git_log` format (abbreviated hash, author date, author, subject) so the list
reads like the familiar git-log picker.

### 15.2 Matching

The fuzzy match is over each commit's **subject and author name** — the two
high-signal fields the model already carries (§3.1). It is snacks' client-side
fuzzy matcher over the resident list (not a git-side `--grep`), so it is
incremental and instant for any repository size, with no fetch and no cache.

Searching commit **message bodies** is deliberately out of scope here: bodies
are not in the model (§11.1), holding them resident does not scale, and body
matches dilute the result list. A future body-search mode is sketched in §15.5.

### 15.3 Preview

The preview shows the selected commit's **commit view** (§11) — fetched on
demand by the same `git show` queries (§11.1) and rendered by the same formatter
(metadata, message, diffstat, diff), cached per hash for the picker session —
**augmented with a graph snippet**: a fixed window of rows around the commit
drawn from the already-laid-out projection (`repo.display`, §10), with the
commit's own row marked, showing the real lanes in their graph colours so the
snippet matches the main view exactly.

The snippet is shown **above** the commit detail in the one preview buffer; a
side-by-side arrangement is a configurable enhancement (§8, deferred — it needs a
second preview pane). The preview is **centered on the match**: the matched text
is located in the rendered detail, scrolled to the center, and highlighted.

### 15.4 Confirm / navigation

Confirming a result moves the cursor to the commit and **centers** the graph on
it — navigation **within** the current view (§14.2), not a new stack entry
(§14.3). The jump resolves the commit to its visible row, so a collapsed branch
lands on its collapsed head (§10.3); a commit that is currently hidden (§10.1)
is a no-op with a notice — mirroring the ref picker (§2). Opening the full
commit view (§11) remains its own action, reached with `<CR>` on the row after
the jump.

### 15.5 Open / deferred

- **Body search** as a separate **live mode** — a toggle within the picker that
  switches from the resident fuzzy match to a git-side `git log --grep` / `-G`
  query, re-run per query (no resident corpus; regex, not fuzzy). This keeps body
  text searchable without caching it or cluttering the default subject/author
  list; not yet built.
- **Additional fields / filters** (committer, date range, path) would compose as
  further picker modes or as view modifiers (§14.2) as needed.

## 16. Filter search (in-graph)

`/` enters a **filter search**: a live query that contracts the graph to the
commits whose subject or author matches, keeping the matches as **normal commits**
and collapsing everything else (§10) so they stand out *in place*. It is by
default a **transient overlay** — a find-and-jump tool: type a query, step through
the matches, press `<CR>` to jump to one, and the filter evaporates, leaving you
in the normal graph on that commit. It can optionally be **stamped** into a
persistent view (§16.5). Read-only (§9). It also sidesteps native `/`'s blind
spot — the graph buffer is virtualized, so a plain `/` only searches the loaded
rows, whereas this filters the whole in-memory set.

Unlike the commit-search picker (§15), which shows a flat list, the filter shows
the matches *in graph context* and can be kept as a view.

### 16.1 The isolated filter view

Entering `/` works on an **isolated copy of the view state** (the per-owner
collapse / pin modes, §10). The copy starts from the current view, then collapses
everything (§16.3); the filter — and anything you do while filtered (pin, expand,
re-query) — acts only on the copy. The **commit data is shared** (no commits are
duplicated, §3); only the view state is copied. Closing the filter **discards the
copy** and returns to the base view exactly as it was — so the base's collapses
and pins are provably untouched, with no save/restore bookkeeping. (Implementation:
a single graph buffer whose projection follows the active view state, swapped to
the copy on entry and back on exit — ARCHITECTURE.md.)

### 16.2 Matching

The query matches a commit's **subject or author name**, **smartcase substring**:
case-insensitive unless the query contains an uppercase letter (like Neovim's
`smartcase`), a literal substring — not fuzzy, for a `/`-search feel. The match
set is computed over the in-memory model (§3, §4), the same resident
`subject`/`author` fields the picker uses (§15.2) — no git query. A **fuzzy** mode
and field scoping (subject-only / author-only) are open extensions (§16.8).

### 16.3 The filtered projection

The filter projects the graph through the §10 view builder with **every owner
collapsed** and the **match set kept**: a matching commit renders as a **normal
commit** (its subject, author, date, refs), while each maximal run of
non-matching commits between matches contracts to a single `◍` collapsed head
(§10.3). **Junctions** (forks/merges) are kept as before (§10.4), so the branch
topology that connects the matches survives — a match in the middle of a long
branch collapses the run above it and the run below it, leaving the match an
island joined through `◍` heads. The matched substring within each kept commit's
subject is **highlighted** (§16.7).

With **no matches** the graph is all heads and junctions and the footer reports
**0 matches**. The filter sets only the projection's contraction; it does **not**
change which commits are in `repo.order` (§3.1) — every commit is still present,
just contracted — so a match's history and the reachability cone (§12) are
unaffected.

### 16.4 The overlay input

`/` opens a single-line **filter input** (a small floating prompt), seeded empty
from the base graph or with the active query when re-opened over a stamped filter
(§16.5). As the query changes the graph re-filters **live, debounced** (§16.6).
An **empty (or blank) query is no filter**: opening `/` leaves the graph exactly
as it was, filtering takes effect with the first typed character, and erasing the
query back to empty restores the unfiltered graph.
The keys while the overlay is open:

- **`<C-j>` / `<C-k>`** move the **current match** down / up — the graph's cursor
  follows the selected match behind the input (`n`/`N` can't be used here: the
  input owns ordinary keys).
- **`<CR>`** — **select & dismiss**: discard the filter copy, return to the base
  view, and place the cursor on the selected match. If the match's branch is
  collapsed in the base view (§10.3), it is **opened** so the cursor lands on the
  commit itself, not its `◍` head (the branch stays expanded). The transient
  overlay leaves **no** stack entry; the pre-filter position is recorded in the
  jumplist, so `<C-o>` (§14.3) returns there.
- **`<Esc>`** — **cancel**: discard the copy and return to the base view at the
  **original** cursor (forget). An empty query behaves like cancel.
- **`<C-CR>` / `<C-s>`** — **stamp** the filtered view (§16.5). (`<C-CR>` needs a
  GUI / CSI-u-capable terminal; `<C-s>` is the portable alias.)

### 16.5 Stamping — a persistent filtered view

Stamping (`<C-CR>` / `<C-s>`) promotes the filtered view to a **persistent
navigation-stack entry** (a view-local filter modifier, §14.2) that **owns** the
isolated view-state copy. The input closes and you remain in the filtered graph;
the entry shows in the breadcrumb (§14.6). In a stamped view:

- **`n` / `N`** move to the next / previous match in row order, wrapping like
  Neovim's search.
- **`/`** re-opens the overlay seeded with the active query, to refine it in place
  (the same stamped entry, not a second one).
- **`<C-o>`** pops the entry, returning to the base view (the discarded copy means
  the base is unchanged, §16.1); navigating onward (a commit view, a submodule
  drill-in) pushes over it as usual.

So the stack carries a filter entry **only** when stamped; the default `/` flow is
transient and stackless.

### 16.6 Live rebuild (asynchronous)

Re-filtering reruns the projection + layout (`view.project` + `columns.layout`),
the same operation as a collapse toggle (§10.4) — so it is **debounced** (rebuild
only after typing settles, ~150 ms) and **cancellable**: a newer keystroke bumps a
generation counter and abandons the in-flight rebuild before it mutates the view,
so a burst of keystrokes costs one rebuild, not one per key, and a slow rebuild on
a large graph never blocks input. The heavy walks are chunked across event-loop
ticks where needed (reusing the context-pane coroutine drive, §6.2).

### 16.7 Match highlight

The matched substring within each kept commit's subject is emphasised with a
`Search`-like highlight group (`palette.search`, §8), so the matches stand out
beyond merely being the only normal commits among the `◍` heads.

### 16.8 Open / deferred

- **Fuzzy mode** and **field scoping** (subject-only / author-only) as toggles in
  the filter input (§16.2).
- Composing the filter with the body **live-grep** mode (§15.5) — filtering by
  message body via `git log --grep`, async — is a later extension.

## 17. Command palette

`<C-Space>` in the graph buffer opens the **command palette**: a
`vim.ui.select` picker that is gitloom's **single action menu**. It lists, in one
ordered list, three sections:

1. the **context** entries — the actions on what the cursor is on (§10.4: a
   commit, a branch, a selected packed marker, a packed line), or, while a §13
   selection is active, the selection's entries instead;
2. the **global** commands gitloom runs on the repository (Return, fetch, pull),
   **Show fetch log** (§17.4) and **Reset view settings** (§18.5);
3. the graph's **keys** that apply in this context (§17.1), grouped, each showing
   its key — so every keyed action is reachable (and discoverable) from here.

There is no examine entry: `<CR>` examines directly (§11). Many terminals send
`<C-Space>` as `<C-@>` (the same key as `<Nul>`), so that is mapped too.

### 17.1 The registries

**The context.** The palette first classifies the cursor into one context:

| Context | When | Row entries (§10.4) |
|---|---|---|
| `commit` | a plain commit row, cursor on its message, no ref selected | open diff, checkout (detached), checkout & examine (examine on HEAD's commit) |
| `branch` | a ref selected with `h`/`l`, or a collapsed head; also a packed line **with** a marker selected | checkout, branch sync (fast-forward / reset to upstream, §17.2), upstream (track same name / set / unset, §17.2), collapse / expand, hide — of that branch (or that one marker) |
| `markers` | a packed line with **no** marker selected | expand / hide per marker |
| `selection` | a §13 selection is active | the `selection` commands (below) |

A row entry that a key also runs carries that key (open diff `D`, collapse /
expand `<Space>`) and shows it after the label, e.g. `Open diff  (D)`.

**The commands.** The non-key commands come from **one registry**. Each entry has:

- `id` — a stable name (`fetch`, `pull`); a per-remote command's entries are
  `<id>:<remote>` (`fetch:origin`);
- `label` — what the picker shows;
- `key` — optional, the direct key that runs the same command; when present the
  picker shows it after the label, e.g. `Open diff  (D)`;
- `scope` — what the command acts on: `global` (the repository as a whole) or
  `selection` (the active §13 commit selection);
- optionally **per-remote** — the entry expands to one entry per remote;
- optionally a **condition** on the session state the palette is built from
  (an active examine, a configured diff provider) — the entry is listed only
  when it holds, and its label may be derived from that state;
- an **action** run on the graph session.

The palette lists the context entries — the row's, or while a §13 selection
is active the `selection` entries in registry order **instead** — then the
`global` entries, in registry order. The `selection` entries are **Open diff**
(`D`, the range in the diff provider, §13.5) and **Checkout & examine selection**
(§10.4.2; **Examine selection** when the newer end is HEAD's commit or a §4.2
working-tree node — nothing to check out), both only with a diff provider. Among the globals **Return** (§10.4.2)
comes first while an examine is active, since it is then the likeliest choice.

**The keys.** Every graph key is one entry of a single **key registry** — the
one table the buffer-local mappings are bound from, the `?` help is generated
from (§2) and the palette's third section is drawn from. Each entry has:

- the **key** (or keys, for an alias like `<C-Space>` / `<C-@>`; the first is the
  one shown);
- a one-line **description** — the mapping's `desc` (`Gitloom: …`), the palette
  label and the help text (help may carry a longer form);
- a **group**: `refs` (branches, refs and search), `view` (rendering toggles),
  `select` (commit, examine and selection), `other` — or **none**: motions and
  plumbing (`j k h l <C-d> <C-u> n N o`, `<Esc>`, `q`, `<C-w>q`, `<C-o>` / `<C-i>`,
  the palette key itself, the `<leader>wD` debug dump) are bound and listed in
  help but **never** in the palette;
- the **contexts** it applies to — none means everywhere (the view toggles,
  `<leader>b`, `L`, `/`, `<leader>gl`, `R`, `?`); `P` and `<Space>` only in the
  `branch` context; `D`, `<CR>` and `V` in `commit` and `selection`; `K` and `%` in
  `commit` and `branch`;
- optionally a **condition** on the same session state (`D` needs a diff
  provider; `<Space>` is not offered on a mainline row, where there is nothing to
  collapse or expand).

The palette lists the grouped keys of the current context, groups in the order
`refs` → `view` → `select` → `other`, each group in registry order, labelled
`<description>  (<key>)` — the hint always comes from the registry, never from a
label. A key already shown on an earlier entry (`D` on Open diff, `<Space>` on
collapse / expand) is not listed again. Choosing a key entry runs that key's
handler, exactly as pressing the key would.

**The remote list.** When the graph opens, gitloom runs `git remote` (local, no
network) asynchronously in the graph's repository root and caches the names, in
git's order, on the session; every resync (§3.4 — `R`, and the resync after a
palette fetch / pull) reloads it. The palette opens **instantly**, built only
from what is already cached: it never waits on the remote list, so until the
first read lands the per-remote entries are simply absent.

### 17.2 The commands

| Command | Key | Runs |
|---|---|---|
| **Return to `<orig>`** — only while a Checkout & examine (§10.4.2) is active | — | `git switch <orig>` (or `git checkout --detach <hash>`), then `git stash apply --index <sha>` of the examine's stash if any (a plain apply when git refuses `--index`) |
| **Fetch** | — | `git fetch --progress --all` |
| **Fetch `<remote>`** — one per remote, in `git remote` order | — | `git fetch --progress <remote>` |
| **Pull** | — | `git pull --ff-only --progress` |
| **Show fetch log** — only once a fetch or pull has run in this graph session | — | opens the running or last fetch / pull's log (§17.4) |
| **Reset view settings** | — | after a Reset / Cancel confirmation, clear the persisted view preferences and this repository's pin list and restore the configured values in the live graph (§18.5) |

The in-place resync (§3.4) is the `R` key's registry entry (`Refresh: resync with
the repository  (R)`, group `other`), listed with the keys — not a second command.

The `selection` entries (while selecting, with a diff provider):

| Command | Key | Runs |
|---|---|---|
| **Open diff** | `D` | the selection's range in the diff provider (§13.5) — exactly `D` |
| **Checkout & examine selection** | — | Checkout & examine (§10.4.2) of the selection; labelled **Examine selection** when its newer end is HEAD's commit or a working-tree node (no checkout, §10.4.2) |

Exiting the selection is the `V` key's entry (listed with the keys in the
`selection` context).

There is no per-remote pull: a pull follows the current branch's upstream.

A pull **only fast-forwards**: it moves the current branch to its upstream when
the branch is strictly behind, and never merges, rebases or creates a commit. If
the branch has diverged from its upstream — or there is no upstream, or HEAD is
detached — git refuses and its error is shown (§17.3); nothing is merged or
rebased, and integrating a diverged branch is left to the user. Neither command
ever forces.

**Branch sync.** In the `branch` context (§17.1), a **local branch that tracks
an upstream** gets up to two more entries, right after its checkout:

| Entry | Offered when | Runs — branch not checked out here | Runs — the current branch |
|---|---|---|---|
| **Fast-forward `<b>` to `<upstream>`** | strictly **behind** (behind > 0, ahead = 0) | `git fetch --no-recurse-submodules . <upstream ref>:refs/heads/<b>` | `git merge --ff-only <upstream ref>` |
| **Reset `<b>` to `<upstream>`…** | behind, ahead or diverged | `git branch -f <b> <upstream ref>` | `git reset --hard <upstream ref>` |

`<upstream ref>` is the upstream's full refname (`refs/remotes/origin/main`, read
from git with the tracking data, §6.3), so a branch name that happens to look like
a remote's never makes it ambiguous. An upstream that is itself a **local branch**
(`branch.<b>.remote = .`) works the same way, with `refs/heads/<upstream>`.

**Which branch.** The branch selected with `h`/`l` — a remote branch, a tag or a
worktree label gets no sync entry, with one exception: a remote branch
`origin/foo` whose local `foo` tracks it from another commit offers that local
branch's sync, folded into its checkout (`Checkout foo and fast-forward to
origin/foo` / `Checkout foo and reset to origin/foo…`), or as the plain entries
above when `foo` is the current branch (§10.4.1). On a collapsed head or a selected packed marker
with no ref selected, the head's **only** local branch, when it carries exactly
one; with several (or none) there is no sync entry — select one with `h`/`l`. The
**current branch** is the one HEAD is attached to in the graph's repository (§2.1):
its label is `(HEAD → <b> …)` (§6).

**Visibility comes from cached state only.** The entries are decided from the
tracking counts already read with the refs (§6.3) — the palette spawns no git to
build them. In sync, `gone` (the upstream was deleted) or no upstream ⇒ neither
entry. Since the counts are as of the last ref read, the commands re-check:

- **Fast-forward** needs no network and never merges. git itself refuses anything
  that is not a fast-forward (the `fetch .` refspec carries no `+`), refuses to
  update a branch checked out in **another worktree**, and — for the current
  branch — refuses when the move would overwrite uncommitted changes. There is no
  confirmation: like checkout (§10.4.1), it loses nothing. Success notice:
  `<b> → <upstream> (<short>)`.
- **Reset** can discard work, so it **always asks**: a `vim.ui.select` whose
  **first** (default) choice is **Cancel**, then **Reset**. Before asking gitloom
  reads the repository afresh (the branch tip, the upstream tip, the ahead/behind
  counts and, for the current branch only, `git status --porcelain`) and the prompt
  says what is lost:

  ```
  Reset main to origin/main (def5678)?
  discards 2 local commits
  discards uncommitted changes to 3 files
  the old tip abc1234 stays reachable in the reflog
  ```

  The commits line appears when the branch is ahead; the uncommitted line only for
  the current branch with a dirty tree (`N` = changed paths, each counted once;
  **untracked files are never touched** by `reset --hard` and do not count); the
  reflog line whenever something is lost. When nothing is lost (strictly behind,
  clean) the prompt is the first line alone (plus the mismatch line below, when
  it applies). Immediately before running, gitloom
  reads the same state again; if the branch tip, the upstream tip, which branch is
  current, or the dirty count changed since the prompt, it **aborts** with a WARN
  notice and runs nothing. git refuses `branch -f` for a branch checked out in
  another worktree (and for the current branch, which takes the `reset --hard`
  form instead). Success notice names the old tip:
  `<b> reset to <upstream> — was <short>`.

  When the upstream does **not match** (§6.3) the prompt adds, before the reflog
  line, `origin/dev is not enne/standard-effect's same-named branch` — and, when
  a same-named remote branch exists, `(origin/enne/standard-effect exists — see
  Track origin/enne/standard-effect)`, on the same line — since resetting to a
  differently named upstream is the likeliest case of resetting to the wrong
  branch. It is shown even when nothing is lost.

Neither entry touches the network, merges, rebases, commits or pushes; they run as
§17.3 says.

**Upstream.** In the same `branch` context, the same branch the sync entries act
on (**Which branch**, above — including the remote-branch exception: a selected
`origin/foo` whose local `foo` exists offers `foo`'s entries, labelled with `foo`)
gets the entries that change **what it tracks**, listed after the sync entries:

| Entry | Offered when | Runs |
|---|---|---|
| **Track `<r>/<b>`** | the upstream does not match, or there is none, **and** `refs/remotes/<r>/<b>` exists — one entry per such remote, in `git remote` order (in the remote-branch exception: just the selected one) | `git branch --set-upstream-to=refs/remotes/<r>/<b> <b>` |
| **Set upstream of `<b>`…** | any local branch | a `vim.ui.select` over the cached **remote-tracking** branches only (no remote `HEAD` symrefs; local branches are not offered as upstreams — a local upstream set outside gitloom is still shown, §6.3, and can be unset), same-named ones first then by name, the current upstream marked `(current)`; choosing one runs `git branch --set-upstream-to=<full refname> <b>` (choosing the current one runs nothing) |
| **Unset upstream of `<b>`** | the branch has an upstream (`gone` included) | `git branch --unset-upstream <b>` |

So for the case §6.3 warns about, **Track `origin/enne/standard-effect`** is one
step and comes *before* any Reset in the list (it is placed ahead of the sync
entries only in that case — the mismatch warning is the reason to show it first).
A matching upstream never gets a Track entry (it already tracks that branch).

- **Visibility from cached state only**, as for the sync: the mismatch, the
  existing same-named branches and the remote-tracking list come from the refs and
  remotes already read (§6.3, §17.1); the palette spawns nothing to build them.
- **No confirmation.** These rewrite only `branch.<b>.remote` / `merge` in the
  repository config — no ref, commit, index or file — and the previous upstream is
  named in the success notice, so the change is one palette step to undo:
  `<b> now tracks <r>/<b> (was origin/dev)` / `(had no upstream)`, and
  `<b> no longer tracks origin/dev`. Like the sync they need no network and never
  fetch: the new counts are against the last fetch (§6.3).
- **Run as §17.3 says** — asynchronously, in the repository root, one at a time
  with the other palette jobs, git's error at ERROR on failure (e.g. a ref that
  vanished since the last read: `the requested upstream branch … does not exist`),
  and the in-place resync on success, which re-reads the refs so the label, its
  colour and the counts (§6.3) follow the new upstream.

`push.default`, `remote.pushDefault` and `branch.<b>.pushRemote` are **not**
changed by any of these: the push target is shown (§11.2) but never configured —
gitloom does not push (§9).

### 17.3 How fetch, pull and the branch sync run

Everything below applies to the branch sync entries (fast-forward, reset) and the
upstream entries (track, set, unset, §17.2) too, except the `Fetching…` notice and
the environment, which only the network commands need.

- **Asynchronously** — the job runs in the background and the graph stays
  usable; a `Fetching…` / `Pulling…` notice shows when it starts — or, under the
  fidget progress provider, a fidget entry instead of that notice (§19.3). Each
  job is a reported operation (§19.1), ended on every path. A fetch or pull (not
  a branch sync) also reports a **live status** while it runs and keeps a log
  (§17.4).
- In the graph's **repository root** (§2.1), which may be a submodule — never
  implicitly Neovim's cwd.
- With `GIT_TERMINAL_PROMPT=0` in the job's environment, so a credential
  prompt **fails** instead of hanging an invisible job. Credential helpers still
  work.
- A per-remote fetch runs exactly like **Fetch** (everything in this list
  applies to it).
- **One at a time per graph session**: a second fetch, pull or branch sync while
  one is running (or a Checkout & examine, §10.4.2) is refused with a notice.
- **On success**: an INFO notice — for a fetch or pull, one that summarises the
  ref updates git reported (§17.4) — then the in-place resync (§3.4), so new
  remote branches, moved tips, a pull's fast-forward and a synced branch appear
  without a reopen. The cursor stays on the commit it was on (a plain `R`).
- **On failure**: git's error as one line at ERROR level — its `fatal:` /
  `error:` line when there is one, not the progress and hints ahead of it (the same formatting as
  a failed checkout, §10.4.1). A failed **pull** still resyncs, because its
  fetch half may already have moved the remote-tracking refs before the
  fast-forward was refused (a diverged branch), and the graph must show them. A failed fetch changes nothing worth
  re-reading.
- If the graph window has closed by the time the job finishes, the resync is
  skipped (the next open reads the repository afresh).

### 17.4 Live status, summary and the fetch log

A fetch or pull can spend a long time connecting, negotiating or downloading.
gitloom passes `--progress` (git prints no progress to a non-terminal otherwise)
and reads git's output **as it arrives**, on both stdout and stderr. This is
display only: it never changes what the command does.

**Live status.** While the job runs, the operation's progress message (§19.1) is

    0:42 · Receiving objects: 43% (1234/2870), 3.1 MiB | 1.2 MiB/s

- `<elapsed>` — the time since the job started, `m:ss`, refreshed **every
  second** even when git is silent;
- `· <latest line>` — the latest line git printed. A progress line that git
  rewrites in place (ended by `\r`) replaces the previous one; output split
  across reads at any point is reassembled first, and `\r\n` counts as one line
  end. Before git has printed anything: `· waiting for the remote` (connecting,
  authenticating and ref negotiation print nothing). When the latest output is
  more than 10 s old, ` (no output for N s)` is appended.

The message goes to the **progress provider only** (§19.3): fidget shows it as
the entry's message under the operation's title; the `notify` provider shows
`gitloom: <title> <message>` as **one replaceable notice**, updated at most once
per second, and only when the notifier can replace a notice (otherwise the
status is not notified — notices stay a log). The graph window itself shows
nothing extra. Output-driven updates are throttled to a few per second.

**Summary.** The success notice counts git's ref-update lines (`<flag> <what>
<from> -> <to>`, on stderr) by their one-character **flag column** — which,
unlike the bracketed words, git does not translate: `*` new, ` ` or `t`
updated, `+` forced, `-` deleted, `!` rejected (`=`, up to date, is not
counted). Ref counts only, never per-ref commit counts:

    gitloom: fetched origin — 2 new, 5 updated, 1 forced

Zero counts are left out. A fetch with no ref-update line ends `— up to date`; a
pull with none is a plain `gitloom: pulled` (its fast-forward, if any, shows
through the resync's HEAD notice). A pull's counts are its fetch half's.

**The fetch log.** Each graph session keeps the output of its **running or last**
fetch or pull, in memory only (never persisted; replaced by the next one; at
most 2000 lines, the oldest dropped): the command line and start time, then each
line git printed — in-place progress updates collapsed to their latest value —
prefixed with the time since the start (`+12.3s`), then `exit <code> (<s> s)`
(or `running <m:ss>` while it runs). The palette's **Show fetch log** (§17.2;
there is no key) opens it in a read-only scratch buffer in a float over the
graph (`q` closes it). Opened while the job runs, it **updates live** and
follows the end unless the cursor was moved off the last line.

## 18. Persisted view state

gitloom remembers how the user left the graph across Neovim sessions: the
**view toggles** (global) and each repository's **pin list** (per repository).
Nothing else is persisted — collapse / expand mode overrides (§10.1), the
cursor position (§2), a filter (§16), a selection (§13) and an examine (§10.4.2)
all stay in-memory.

### 18.1 The file

One JSON file, `stdpath("state") .. "/gitloom.json"`, shared by every Neovim
instance:

```json
{
  "version": 1,
  "view": {
    "mirror":        { "value": false,    "base": true },
    "layout_policy": { "value": "gutter", "base": "compact" }
  },
  "repos": {
    "C:/src/project": {
      "pins": [ { "id": "release/2.0", "reserved": true } ],
      "unpinned": [ "dev" ]
    }
  }
}
```

### 18.2 What is persisted

**Global view preferences** — written when the user changes one interactively,
read when a graph opens:

| Key | Option (§8) |
|---|---|
| `m` | `merge_style` |
| `C` | `layout_policy` |
| `M` | `mirror` |
| `B` | `label_mode` |
| `d` | `date_mode` |
| `H` | `highlight` |
| `S` | `sort_mode` |
| `c` | `collapse_merged` |
| `p` | `pack_markers` |
| `F` | `panes` |
| `i` | `show_lane_ids` |

**Per-repository state**, keyed by the repository root (§2.1): the pin list
(§10.6) — its entries `{ id, reserved }` in priority order — and the set of
explicitly **unpinned** ids. Written whenever the list changes (`P`, every
action of the `L` dialog, §10.6.1); read when a graph session for that root is
created. The saved list omits what the open-time resolution re-derives anyway:
an **unreserved** entry that is a **default anchor** at the time of saving
(`master` / `main` / `dev`, a seeded mark, HEAD's branch) **and still sits in its
default place** — in the leading run of defaults, above every explicitly placed
entry, where the resolution (§10.6) puts it back. Implicit remote counterparts
(§10.6) are never entries, so they are never saved. So pinning a branch while on
`feature/x` does not make `feature/x` an anchor forever after the user checks out
something else; an unpinned default stays unpinned, and a reserved entry keeps
its flag and place. Because the order of every entry now matters (it is the lane
identity rank, §5), a default the user has **moved** below an explicitly placed
entry is saved with its place rather than omitted — and so stays pinned, at that
place, even once it is no longer a default.

### 18.3 Precedence

Built-in defaults < `setup()` configuration < persisted. Each persisted view
preference is stored as `{ value, base }`, where `base` is the
**configuration-resolved** value (the user's `setup()` value, else the built-in
default) when it was saved. On open a stored `value` is applied only when the
current configuration-resolved value still equals its `base`; otherwise the user
has changed their configuration since, the **configuration wins**, and the stale
entry is ignored (and dropped on the next write). A stored value of the wrong
type is ignored too.

### 18.4 Writing

- The file is read lazily, once, when it is first needed; a missing file is an
  empty state.
- Every write **re-reads** the file, merges the one change into it and writes
  the result to a temporary file in the same directory, which is then renamed
  over the original — so concurrent Neovim instances writing different keys do
  not lose each other's changes, and a crash never leaves a half-written file.
- A corrupt or unreadable file is ignored with **one** warning; opening the
  graph never fails because of it. The next write replaces it.
- Only a repository's own canonical graph writes its pin list (§14.8): a
  drilled-in submodule frame (§14.7) and a stamped filter view (§16.5, whose pin
  list is a private copy) read it but never write it back.
- `persist = false` (§8) disables both reading and writing.

### 18.5 Reset

**Reset view settings** — a global entry of the `<C-Space>` palette (§17.2) and
the `:GitloomResetView` command — asks for confirmation (Reset / Cancel), then:

1. removes the **global view preferences** and **this repository's** pins /
   unpinned from the file (other repositories' pin lists are kept — they are
   per-repository state the user set up there, and are reset from their own
   graph);
2. restores the live session to the configuration-resolved values (the built-in
   defaults where `setup()` sets nothing) and to the default anchors (§10.6),
   re-sorting, re-laying out and re-rendering as the individual toggles do.

`:GitloomResetView` targets the graph in the current window, else the
repository at Neovim's cwd (its file entries are cleared even when no graph is
open for it). Reset works with `persist = false` too: it then only restores the
live session.

## 19. Progress reporting

Some of what gitloom does takes long enough that the user should be told it is
happening: opening a large repository, a fetch or pull, a checkout that rewrites
a big working tree. gitloom reports such an **operation** through a pluggable
**progress provider**. [fidget.nvim](https://github.com/j-hui/fidget.nvim) is the
default provider when it is installed; without it, operations are reported with
`vim.notify`. fidget is **optional** — like diffview (§11.5), it is never a
required dependency, and nothing else changes when it is absent. Progress is
**display only**: it never changes what an operation does, and reporting can never
fail an operation (a provider that errors is ignored for that operation).

### 19.1 Operations

An **operation** has a title, an optional message updated while it runs, and an
**outcome** when it ends: `done`, `failed` or `cancelled`. Every operation that is
started is **always ended** — on success, on every failure path, when it is
superseded, and when its graph session closes (§19.4).

Reported operations (titles are the user-visible strings):

| Operation | Title | Message while running | Own notices today |
|---|---|---|---|
| Open: refs → commit stream → sort → working tree → first projection (§3.1, §10.5) | `Loading <repo>` | `refs`, `N commits` (per streamed batch), `sorting`, `laying out` | none |
| Resync, `R` and every post-action resync (§3.4) | `Refreshing` | `refs`, `new commits`, `laying out` | `resynced` / the HEAD notice |
| Fetch / per-remote fetch / pull (§17.3) | `Fetching` / `Fetching <remote>` / `Pulling` | the live status `<m:ss> · <latest line>` (§17.4) | `Fetching…`, then the summary / error |
| Branch sync: fast-forward / reset (§17.2) — the git command only, not the probe or the prompt | `Fast-forwarding <branch>` / `Resetting <branch>` | — | success / error |
| Checkout (§10.4.1) | `Checking out <ref>` | — | the HEAD notice / error |
| Checkout and fast-forward / reset to `<remote>/<b>` (§10.4.1) — the git commands only, not the probe or the prompt | `Checking out <b>` | `fast-forwarding`, `switching` / `resetting` | the HEAD notice / error |
| Checkout & examine (§10.4.2) — from the confirmed stash / checkout, not the prompt | `Examining <short>` | `stashing`, `checking out` | the HEAD notice / error |
| Return (§10.4.2) | `Returning to <ref>` | `switching`, `restoring changes` | the HEAD notice / error |
| Sort by a `rev` mode, `S` (§3.1) | `Sorting by <mode>` | — | none |
| Commit / range / working-tree view diff load (§11.1, §13.5) | `Loading diff` | — | error only |

Not reported, deliberately:

- **Keystroke-paced rebuilds** — the context-pane rebuild (§6.2, every scroll),
  the reachability recompute (§12), the filter's live rebuild (§16.6). They run
  constantly and are superseded constantly; a progress entry would flicker.
- **Synchronous work** — a reflow driven by a toggle (`c`, `p`, `<Space>`, …;
  §10.5) runs on the main loop and blocks it, so no progress display could paint
  before it finished. Only work that yields to the event loop is reported.
- **The repository picker's discovery** (§2.1) — the picker's own rows are its
  progress, and it typically completes in well under the show delay.
- **Probes** (`git status`, `sync_probe`, the examine probe) — tens of
  milliseconds; they are folded into their operation, never reported alone.

No operation reports a **percentage**: the commit stream does not know its total
(`git log` reports none), and the other operations are single git commands. A
provider shows them as indeterminate (fidget: a spinner). Reporting the stream
against the previous open's commit count is deferred (§19.6).

### 19.2 The show delay

An operation is **shown only once it has run for `progress.delay` milliseconds**
(default `300`). One that ends sooner is never shown — nothing appears, neither a
start nor an end — so a fast checkout, a warm-cache open of a small repository or
a quick resync produce no noise. The delay applies to every provider, including a
custom one: a provider's `start` is called only once the delay has elapsed.

### 19.3 Providers

`progress.provider` selects how a shown operation is displayed:

- **`"auto"`** (default) — fidget when `require("fidget.progress")` loads, else
  `"notify"`. Checked once per operation, so installing or lazy-loading fidget
  later is picked up.
- **`"fidget"`** — a fidget progress entry. Every gitloom entry is grouped under
  the name **`gitloom`** (fidget groups progress by its client name), titled by
  the operation, with the message as the entry's message. The entry is created
  **non-cancellable**: gitloom does not cancel a running git job from the
  progress display (§19.4), and a fidget entry dismissed by the user only hides
  it. When fidget cannot be loaded, behaves as `"notify"`.
- **`"notify"`** — `vim.notify` notices (below).
- **a table** `{ start = fun(op: ProgressStart): ProgressSink }` — a custom
  provider. `start` receives `{ title, message? }` and returns a sink
  `{ report = fun(message?), finish = fun(outcome, message?) }`. gitloom calls
  `report` / `finish` only on a started sink and `finish` exactly once.
- **`false`** — nothing is reported; behaviour is exactly as before this section.
  `progress = false` is the same as `progress = { provider = false }`.

**The `notify` provider** never repeats what an operation already says:

- **Start** — after the delay, one INFO notice `gitloom: <title>…`, but **only
  for an operation with no notice of its own** (the open, `S`, a diff load).
  The other operations keep the notices they already emit and get no start
  notice of the provider's: fetch / pull keep their immediate `Fetching…` /
  `Pulling…` (§17.3), and a checkout, examine, Return, branch sync or resync is
  named by its own outcome notice.
- **End** — one INFO notice `gitloom: <title> — done (<seconds> s)`, only for
  outcome `done`, only when the start notice was shown, and only for an operation
  with no outcome notice of its own (so: a slow open, sort or diff load). A
  `failed` end adds nothing — every failure path already notifies at ERROR — and a
  `cancelled` end adds nothing either (a superseded or abandoned operation is not
  news).
- The running message (`N commits`, …) is not notified: notices are a log, not a
  live display. The one exception is fetch / pull's **live status** (§17.4), and
  only when `vim.notify` can **replace** a notice. gitloom takes a notifier that
  returns a handle for the `Fetching…` / `Pulling…` notice (snacks.notifier,
  nvim-notify) as one that can; Neovim's built-in returns nothing (it only
  echoes and logs to `:messages`), and so does any notifier that cannot. Then
  `Fetching…` / `Pulling…`, the live status (at most once per second, once the
  show delay has passed) and the outcome notice are **one** notice, each
  replacing the last: gitloom passes the same `id` (snacks.notifier) and the
  previous notice's handle as `replace` (nvim-notify), with `title = "gitloom"`.

**The `fidget` provider** owns the "running" display, so gitloom's own **start**
notice for fetch / pull (`Fetching…` / `Pulling…`) is **not** emitted under it —
the fidget entry replaces it (a fetch always outlives the delay, so it is shown).
Every **outcome** notice (success, the HEAD notice, every ERROR) is kept under
every provider: they carry content a progress entry does not (git's error line,
where HEAD landed), and a fidget entry is transient. A failed operation's entry
ends with the message `failed`; a cancelled one with `cancelled`.

### 19.4 Ending, cancellation and supersession

- **Every path ends the operation.** Each completion callback (success and every
  failure branch) ends it with `done` / `failed`; ending is idempotent, so a path
  that ends twice is harmless.
- **Supersession ends it `cancelled`.** The open's projection is a `reflow_async`
  (§10.5); a newer reflow supersedes it (`reflow_gen`), and the superseded
  projection's operation is ended `cancelled` at that point rather than left
  running. An operation is never kept alive by a newer one.
- **The session closing ends it `cancelled`.** Every operation belongs to its
  graph session; when the session is torn down (the graph buffer is wiped, §14.5)
  every operation it still has running is ended `cancelled`. This is the backstop
  for a path that never completes — the futures gitloom chains do not propagate
  errors, so an error thrown mid-chain would otherwise leave the entry running
  forever. The git job itself is not killed: a fetch finishing after the close
  still completes, its resync is skipped (§17.3).
- **gitloom never cancels work from the progress display.** No git job is
  interrupted, so no provider is offered a cancel action.

### 19.5 Configuration

```
Progress = false | {
  provider: "auto" | "fidget" | "notify" | false | ProgressProvider,  -- default "auto"
  delay:    integer,  -- ms before an operation is shown (default 300; 0 = at once)
}
ProgressProvider = { start: fun(op: { title: string, message: string? }): ProgressSink }
ProgressSink     = { report: fun(message: string?),
                     finish: fun(outcome: "done"|"failed"|"cancelled", message: string?) }
```

`progress` is a `GraphOptions` field (§8), merged over the defaults like the
others; it is not a view toggle and is not persisted (§18).

### 19.6 Open / deferred

- **A percentage for the open's stream**, estimated from the commit count of the
  previous open of the same repository (persisted, §18) — useful on very large
  repositories, wrong after a big fetch; deferred until it is wanted.
- **Cancel from the display** — interrupting a fetch from its fidget entry. It
  needs gitloom to own the job handle end to end and to define what a half-done
  fetch leaves behind; out of scope here.
- **Synchronous reflows** become reportable only once they are chunked like the
  open's projection (§10.5).
