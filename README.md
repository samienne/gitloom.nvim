# gitloom.nvim

A git commit-graph viewer for Neovim. Renders the commit DAG as a colored,
lane-based graph (lazygit/tig style) in a floating window. Part of the
**loomworks** suite.

## Goals

gitloom's purpose is to be an *excellent git graph viewer* — not a general
git client. It deliberately builds the graph itself rather than wrapping
`git log --graph`: it reads all commit and ref data and constructs the DAG,
ordering, and lane layout in memory. That ownership is what enables the
planned interactive views — collapsing branches to a single line, pinning
branch-heads so their history stays visible, and toggling branches between
fully visible / collapsed / hidden, with the graph reflowing to match.

Other git functionality is out of scope, except where it falls naturally out
of the graph (acting on the commit under the cursor) or is delegated to
existing plugins (e.g. opening a diff in diffview). See
[specification.md](specification.md) §1 and §10.

## Status

Early development. The graph renderer (async git fetch, DAG construction,
lane layout, and glyph rendering) works; the surrounding plugin surface
(configuration wiring, interactivity, docs) is still being built out.

gitloom is **self-contained** — it does not depend on `loomworks.nvim`
even though it ships as part of the same suite. See
[ARCHITECTURE.md](ARCHITECTURE.md) for the rationale.

## Features

- **Lane-based commit graph** — commits, merges, and splits rendered with
  box-drawing glyphs and per-lane color
- **Asynchronous** — commits stream into the view as `git log` produces
  them; the window opens immediately and fills in as rows arrive, and the
  first-branch-collapse pass that follows the stream is computed in the
  background, so the editor stays responsive on a large repository
- **Virtualized rendering** — only the visible range is laid out and drawn,
  so large histories stay responsive
- **Configurable merge style** — render merges/splits inline or on their
  own virtual lines
- **Reachability emphasis** — the row under the cursor dims everything not in
  its history (ancestors) or downstream of it (descendants), keeping each
  lane's colour (just muted) so the relevant graph stands out
- **Working tree** — a `◌` row always sits on top of HEAD (in the HEAD colour):
  uncommitted work shows as up to three nodes (staged, unstaged, untracked), a
  clean tree as one `Working tree · clean` row. Open any to inspect its diff in the
  commit view or the external viewer, or pick **Examine working tree** in the
  palette to see every uncommitted change against HEAD on the real files. Updates
  live as you edit or stage (and on `R`); strictly read-only — gitloom never
  stages or commits
- **Linked worktrees** — a worktree checked out on a **detached HEAD** would
  otherwise have no branch naming its commits, so they would show as a run of
  fully expanded rows in an otherwise focused graph (and vanish on the next `R`).
  gitloom reads `git worktree list` and labels such a HEAD `{wt:<dir>}`, so it
  collapses, pins and navigates like any other branch. A worktree that is on a
  branch — or parked on a tip something else already names — gets no extra label
- **Search & filter** — `<leader>gl` fuzzy-finds a commit by subject/author in a
  picker (preview shows the commit + a graph snippet); `/` is a live in-graph
  **filter** that folds the graph to matching commits in place (the rest
  collapse), with `<C-j>`/`<C-k>` to step matches, `<CR>` to jump (opening the
  branch), and `<C-s>` to keep it as a persistent view you return from with `<C-o>`

### Planned

- **Collapse a branch** to a single line in the view
- **Pin branch-heads** so everything they reference stays visible
- **Toggle branch visibility** (visible / collapsed / hidden) with the graph
  reflowing to match
- **Graph-initiated actions** and integrations (e.g. diffview) where they
  arise naturally from the graph
- **"Update available" marker** — flag when a tracked branch is behind its
  remote, queried with `git ls-remote` (no `fetch`, no objects downloaded,
  nothing written to the repo) so it stays true to the read-only viewer model

## Requirements

- Neovim >= 0.10 (uses the 4-argument `vim.str_byteindex` and the
  decoration-provider API)
- [snacks.nvim](https://github.com/folke/snacks.nvim) (window management)
- *Optional:* [diffview.nvim](https://github.com/sindrets/diffview.nvim) (or any
  diff plugin) for the external diff (`D` / the commit view's action label); the
  provider is configurable, so diffview is not required
- *Optional:* [fidget.nvim](https://github.com/j-hui/fidget.nvim) to show
  long-running operations (opening a large repository, fetch / pull, checkout)
  as progress entries; without it they are reported with `vim.notify` (§19)

## Installation

gitloom follows the same dev/branch pattern as the rest of the loomworks
suite. With lazy.nvim:

```lua
{
    url = "https://github.com/samienne/gitloom.nvim",
    branch = "unstable",
    cmd = "GitloomGraph",
    keys = {
        { "<leader>wg", "<cmd>GitloomGraph<cr>", desc = "Gitloom graph" },
    },
    config = function()
        require("gitloom").setup({})
    end,
}
```

## Usage

```vim
:GitloomGraph
:GitloomGraph path/to/submodule
:GitloomPick
:GitloomResetView
```

Opens the graph for the repository at Neovim's current working directory. With
an optional path argument it opens the graph for that repository instead — a
submodule of the current repo, or any other repo root (the path is resolved to
its git top level). View state (cursor position, ref-picker history) is
remembered per repository for the session. The view toggles and each repository's pin list are
remembered across sessions (see `persist` under Configuration);
`:GitloomResetView` forgets them (after a confirmation).

`:GitloomPick` opens a picker listing the **main module** and its **direct
submodules**; choosing one opens the graph for that repository. The picker
opens immediately and fills each entry's current branch and commit summary as
git resolves it; a submodule that is not checked out is shown disabled.

`setup()` binds the picker to **`<leader>wG`** by default. Remap or disable it
with the `pick_key` option:

```lua
require("gitloom").setup({
  pick_key = "<leader>gp", -- a string to remap, or false to disable
})
```

**One window per repository.** A repository's graph lives in a single **host
window**: opening the same repository again (via the picker or `:GitloomGraph`)
**re-shows** that window where you left it rather than stacking a second one.
`q` **hides** it (its place and history are kept), `<leader>wg` **returns** to
the most-recently-open one, and `<C-w>q` **destroys** it. Within a window,
`<C-o>` / `<C-i>` walk a **navigation history** of views — the graph, commit
views, and drilled-in submodules (below). Each repository's cursor position is
remembered for the session.

The graph buffer is named `<repo path> (gitloom)` (a commit view's
`<repo path> (gitloom) <short hash>` or `… <range>`), so a GUI window title — e.g.
Neovide's titlebar — identifies which repository is open by its path rather than
showing an unnamed scratch buffer. (Requires `:set title`.)

| Key | Action |
|-----|--------|
| `q` | Hide the graph window (`<leader>wg` returns to it, `<C-w>q` destroys it) |
| `<C-o>` / `<C-i>` | Navigate back / forward through the view history (graph ⇄ commit view ⇄ drilled-in submodule) |
| `m` | Cycle the merge/split rendering style (split line → merge line → both → inline → inline w/ merge-on-split) |
| `C` | Cycle the lane layout policy (compact → survivors → linear → straight → gutter) — which lanes may move sideways to close a gap, and (gutter) whether the current branch's lane is pinned to a fixed column beside the message |
| `M` | Toggle mirroring — render the graph with lane 1 on the right, nearest the message |
| `B` | Cycle the ref label placement (right edge → inline before the message → its own line) |
| `<Space>` | Collapse ⇄ expand the row's own branch(es) under the cursor (toggle; the cursor follows so repeated `<Space>` flips it in place) |
| `<CR>` | Examine — open the **commit view** of the row's commit (a collapsed head or a packed marker: its tip — the selected marker's, else the first; while selecting: the range view). Every other row action is in the `<C-Space>` palette |
| `D` | Open the commit's diff in an external diff viewer (diffview by default) |
| `d` | Toggle the date column between absolute and relative ("3 days ago") |
| `h` / `l` | Select the previous / next ref decoration on the current row — on a packed marker line, the previous / next collapsed head, with the reachability emphasis following it (switch the followed branch while selecting) |
| `V` | Start / end **commit selection** — pick a range of commits along one branch |
| `H` | Toggle reachability highlighting (dimming) off / on |
| `c` | Toggle first-parent focus — collapse every non-mainline branch, or show the full graph |
| `P` | Pin / unpin the branch under the cursor as an anchor — pinned branches stay shown in full under focus (HEAD is pinned by default) |
| `L` | **Pinned branches** — a dialog listing the pinned branches in priority order: `<C-j>`/`<C-k>` reorder, `D` unpins, `<CR>` jumps to a branch, the last row adds one via the ref picker, `q` closes |
| `p` | Toggle marker packing — merge concurrent collapsed heads onto shared lines, or one per line |
| `R` | Resync with the repository — re-read refs, pull new commits, prune unreachable ones, re-sort, and rebuild the working-tree changes (`◌` nodes), keeping your cursor / scroll / selection |
| `<C-Space>` | **Command palette** (also `<C-@>`, what many terminals send) — the single action menu, scoped to what the cursor is on: the commit's or the branch's actions first (the selection's while `V` is active), then return / fetch / pull, then the keys that apply there with their key shown; see below |
| `S` | Cycle the row **sort mode** — gitloom's own topological order (reproduces git's `--topo-order`), or git's date / author-date order; reorders in place |
| `<leader>b` | Jump to a branch / ref — open a picker of all branches, remotes, tags, linked-worktree HEADs (`wt:<dir>`) and HEAD; selecting one centers the view on its commit (recently jumped refs first) |
| `%` | Cycle the branch under the cursor (the `h`/`l`-selected one, else the row's first) between its local and remote counterparts — `dev` → `origin/dev` → `upstream/dev` (remotes in `git remote` order) → `dev`, jumping like `<leader>b`; when the next one is on the same row a notice names it (`origin/dev (2/3)`) |
| `<leader>gl` | Search commits — fuzzy picker over commit subjects and authors; the preview shows the commit (like the commit view) under a snippet of the graph locating it; selecting one jumps + centers the graph (also `:GitloomSearch`) |
| `/` | Filter the graph — a live, isolated overlay that folds it to commits whose subject/author match (the rest collapse); `<C-j>`/`<C-k>` (or `<Up>`/`<Down>`) step matches, `<CR>` jumps to one (opening its branch), `<C-s>` stamps it as a persistent view, `<Esc>` cancels |
| `F` | Toggle the off-screen context panes (summary bands above and below the graph) |
| `K` | Float with the full lane breakdown for the commit under the cursor (debug) |
| `i` | Toggle the per-lane id column before the message (debug; hidden by default) |
| `<leader>wD` | Write a context-pane debug dump — seam, boundary, condensed graph and rendered overlay — to `stdpath('data')/gitloom_pane_dump.txt` (debug) |
| `?` | Float listing every key, grouped — generated from the same key registry the palette reads, so it always matches what is bound (each mapping also carries a `Gitloom: …` description for `:map` / which-key) |

**Branch modes.** A branch can be **normal**, **collapsed** (contracted to a
single `◍` marker row — a commit count and the ref), or **hidden**. The
collapse interactions act on the **row's own branches** — the branches whose
tip is in the row's stretch of history — found from the commit's history, not a
selected ref, so they work for ref-less regions too (first-parent-merged,
squashed). A branch opens only its own first-parent line: opening `dev` (or the
trunk) never opens the branches merged into it.

- `<Space>` toggles **collapse ⇄ expand** in place; the cursor follows the
  result, so holding `<Space>` flips a branch open and closed. On an open row it
  collapses every ref of that row together (selecting one with `h`/`l` does not
  narrow it). A branch **built on top** is never collapsed with it: if one keeps
  the row open, gitloom says so (`still open via feature/z +1 merged`). On a `◍`
  it expands only that marker's own branches, so a collapsed branch above stays
  folded. A pinned branch's line is not collapsible (`on dev's mainline — not
  collapsible`).
- A branch you opened (one that is collapsed by default) carries an **expanded
  marker** in its label — `(▾feature/x)`, after the pin icon when both apply
  (`icons.expanded`; `""` turns it off). Pinned branches and HEAD never carry it,
  and nothing is marked with the first-parent focus off (`c`).
- `<C-Space>` opens the **command palette**, whose first entries are the
  actions on **what is selected** — a commit or a branch, never both. On the
  message (the commit): open diff, checkout (detached), checkout & examine
  (**examine** on HEAD's own commit). With
  a ref selected or on a collapsed head (the branch): checkout of that branch,
  the **branch sync** entries (below), collapse / expand, **hide**. On a packed
  marker line with a marker selected: that marker's checkout / sync / expand /
  hide only; with none selected it lists expand
  / hide for every marker by name, so any branch is reachable even when labels
  overflow. After a checkout the cursor
  lands on the commit now checked out and the notice says where HEAD is
  (`HEAD → main (1a2b3c4)` or `HEAD detached at 1a2b3c4`), adding how far the
  branch is behind its upstream when it is (`— 12 behind origin/main`); plain
  `R` keeps the cursor where it was. Selecting a remote branch `origin/foo`
  whose local `foo` sits at another commit never silently switches to that
  stale local branch: a tracking `foo` offers **Checkout foo and fast-forward to
  origin/foo** (behind) or **Checkout foo and reset to origin/foo…** (ahead /
  diverged, confirmed first), and every such case offers a detached checkout of
  the selected commit.
- **HEAD always reads as `HEAD`** and its label comes first on its row, so the
  `+N` overflow never hides it: `(HEAD → main …)` on a branch, a bare `HEAD` when
  detached. The window title shows the branch, or `detached @<short>`. In the
  graph itself HEAD's commit is drawn `●` in the HEAD colour (`icons.head`;
  a `◍` head that folded HEAD in keeps `◍` but takes the colour).
- `<CR>` examines: it opens the commit view directly (a head's tip on a
  collapsed head or packed marker).
- `h`/`l` selects a ref (or a marker on a packed line) for the toggle/palette to
  act on.

See the design in [specification.md §10](specification.md).

**First-parent focus (default).** By default the graph opens focused on the
current branch: HEAD's first-parent mainline is shown in full and every other
branch — merged-in *and* divergent — is collapsed to a `◍` head. Press `c` to
toggle this off (the full graph) and on again; your explicit per-branch toggles
are kept across the switch. Disable the default with `collapse_merged = false`
(§10.7).

**Anchors (pinning).** Focus folds everything toward the *anchors* — by default
HEAD (the current branch, or the checked-out commit itself when HEAD is detached,
so it is never folded into a `◍`) plus the common trunks `master` / `main` /
`dev` when they exist. Press `P` on a branch to pin it as another anchor (or unpin it):
pinned branches stay shown in full under focus, so you can keep `master`, `dev`,
a release branch and a few of your own in view at once while everything else
collapses. The footer notes the anchor count when more than one is pinned
(§10.6). A pin covers the branch's whole **identity** — a local branch, its
upstream and every remote branch of the same name — so their lanes stay in full
and a divergence is drawn rather than a remote collapsing. They are not separate
dialog rows; `P` on one remote unpins just that ref. Each pinned branch also keeps
a **fixed colour**: the pin at position `k` in the list draws in the `k`-th palette
colour, which no other branch ever takes (pins past the palette size draw an
ordinary colour).

**Colours follow branches.** A colour belongs to a branch, not to a lane: every
lane carries the best-ranked branch that reaches it (pinned branches first, by pin
order; among the rest, brighter beats dimmer; then by tip height), and a branch's label is drawn in that branch's colour. A local
branch and its remotes share one hue, drawn at one of **three brightness levels**:

| level | branches | drawn |
|---|---|---|
| full | local branches that are pinned or expanded; a pinned remote branch with no local branch | full strength |
| slightly muted | other remote branches that are pinned or expanded (a pinned local's remotes included) | `palette.remote_mute` (default `0.25`) |
| muted | any collapsed, unpinned branch, local or remote | `palette.collapsed_mute` (default `0.45`, replacing `remote_mute`) |

A pinned branch outranks every unpinned one where lanes meet, even a pinned remote
over a full-strength local; among unpinned branches a brighter one always outranks a
dimmer one. Out of the
reachability focus the dim is applied on top: a pinned or expanded remote takes
`palette.remote_mute_out` (default `0.75 × dim`, so it stays a shade brighter than
other dimmed lanes), and a collapsed one takes `palette.collapsed_mute_out` (default `0.45`, the same level as a dimmed local branch). Inside the
focus, while the reachability highlight is on, both muted levels are lifted to almost
full brightness by `palette.highlight_mute` (default `0.1`; `0` = full strength).
Collapsed branches (on a `◍` head, a packed marker or a kept junction) are coloured
like any other, in their own colour at the muted level. A tag takes the colour of
the node it sits on. An unpinned branch's colour is freed once it is outranked and
no member is still to come below, so colours are reused down a long graph
(specification.md §5, §5.5). Every pinned branch's label carries a pin icon —
`(⚲dev)`, `(⚲release/2.1 ↑origin)` — except HEAD's own label (`icons.pin`; `""`
turns it off). A remote branch with no local branch of its name anywhere carries
the remote icon, after the pin and expanded icons and directly before the name:
`(⇣origin/foo)`, `(⚲⇣origin/foo)`, `(▾⇣origin/foo)` (`icons.remote`; `""` turns
it off).

Press `L` for the **pinned-branches dialog** — the anchors in priority order,
where they are managed together. The defaults come first (the trunks, then
HEAD's branch), and a newly pinned branch goes to the bottom. Order matters for
every entry: where lanes meet, the higher-priority branch keeps its lane and
colour (§5), so reordering re-lays the graph.

```
Pinned branches

  1  master              <C-j>/<C-k>  move
  2  topic1              D            unpin
  3  origin/release      <CR>         jump to branch
  4  dev                 q            close
     + Pin new branch…
```

`<C-j>`/`<C-k>` reorder, `D` unpins, the last row adds a branch through the
ref picker, and `<CR>` jumps the graph to a branch. A pin covers the whole
branch: pinning `dev` also anchors `origin/dev` (kept expanded, shown in the
panes, drawn slightly muted, with no row of its own). Pinning a remote that has
a local branch — `origin/dev` while `dev` exists — pins `dev`, so the branch has
one row. A remote with no local branch (`origin/release` above) keeps its own
row and is drawn at full strength, its `⇣` icon still marking it remote. Pinning never claims a graph
column: a pinned branch is placed like any other (§10.6.1).

**Upstream tracking.** A local branch that tracks a remote shows a terse
divergence indicator after its name: `⇡N` ahead, `⇣N` behind, `⇡N⇣M` diverged,
`gone` when the upstream was deleted (in sync shows nothing). So `(master ⇡2⇣3)`
means two commits ahead and three behind `origin/master`. The current branch's
status also shows in the footer, and `⇡⇣` appears in the `<leader>b` ref picker.
Counts are git's own, computed against the **last-fetched** remote state (gitloom
never fetches on its own; **Fetch** from the `<C-Space>` palette, or `git fetch`
then `R`, refreshes them). The upstream is read from
git's tracking config, not a shared name, so it stays correct across mirrored or
many-remote setups. When a branch tracks something **other than its same-named
remote branch**, the label spells the upstream out before the counts —
`(enne/standard-effect →origin/dev ⇡4⇣6)` (a local upstream reads `→./dev`; the glyph is `icons.upstream`) —
and draws it in a warning colour when a same-named remote branch
(`origin/enne/standard-effect`) also exists, since the counts then are not
against the branch you probably expect. (The bare `↑origin` list means "the
same-named `origin` branch is at this commit", not "tracks origin".) The commit
view (`<CR>`) spells it all out per local branch: upstream and counts, the push
target (or why git cannot resolve one), and any same-named remote branch.
Colors are configurable via `palette.track`.

**Command palette.** `<C-Space>` (or `<C-@>`, which many terminals send for it)
opens gitloom's single action menu. Its first entries are the **context**: the
commit's or the branch's actions (above; never examine, which is `<CR>`), or while
a `V` selection is active the selection's — **Open diff  (D)** and **Checkout &
examine selection** — instead. Then the graph-wide commands:

- **Return to `<orig>`** — first, and only while a checkout & examine is active
  (below);
- **Fetch** — `git fetch --progress --all`;
- **Fetch `<remote>`** — `git fetch --progress <remote>`, one entry per remote in
  `git remote` order (the list is read when the graph opens and on every resync;
  the palette never waits for it, so the entries appear once it has arrived);
- **Pull** — `git pull --ff-only --progress` (fast-forward only: a branch that
  has diverged from its upstream is refused with git's error, never merged or
  rebased);
- **Show fetch log** — once a fetch or pull has run: its output (git's lines
  with the time since the start, then the exit code) in a float, updating live
  while it runs; `q` closes it.

  While a fetch or pull runs, its progress entry (fidget) — or, with a notifier
  that can replace notices such as snacks.notifier or nvim-notify, its one
  notice — shows the elapsed time and git's latest line
  (`0:42 · Receiving objects: 43% …`, `waiting for the remote`, `(no output for
  25 s)`). When it succeeds the notice counts the refs it moved:
  `gitloom: fetched origin — 2 new, 5 updated, 1 forced` (or `— up to date`);
- **Reset view settings…** — after a Reset / Cancel prompt, forget the remembered
  view toggles and this repository's pin list and go back to your configuration
  (below, and `:GitloomResetView`).

Then the graph's **keys** that apply where the cursor is, grouped (branches /
refs / search, then view toggles, then commit & selection, then other), each
labelled with its key — e.g. `Jump to branch / ref…  (<leader>b)`,
`Refresh: resync with the repository  (R)`. Branch-only keys (`P`, `<Space>`)
appear only on a branch, `V` / `D` / `<CR>` on a commit or a selection; a key
already shown on an earlier entry is not repeated. Motions and plumbing (`j`/`k`,
`h`/`l`, `q`, `<Esc>`, …) are never listed. Picking a key entry does exactly what
pressing the key does.

Fetch and pull run in the background in the graph's repository (a submodule's
graph fetches that submodule), with `GIT_TERMINAL_PROMPT=0` so a credential
prompt fails instead of hanging — credential helpers still work. A notice shows
while one runs; a second one is refused until it finishes. On success the graph
resyncs; on failure git's error is shown (a failed pull still resyncs, since its
fetch half may have moved the remote-tracking branches). Nothing is ever forced
(§17).

**Branch sync.** On a local branch that tracks an upstream (selected with `h`/`l`,
or a collapsed head / packed marker carrying exactly one local branch) the palette
offers, based on its `⇡⇣` counts:

- **Fast-forward `main` to `origin/main`** — only when strictly behind. Moves the
  branch, nothing else: a branch that is not checked out is updated without
  touching your files (`git fetch . origin/main:main`); the current branch runs
  `git merge --ff-only`, which git refuses if it would overwrite uncommitted
  changes. No network, no merge commit, no prompt.
- **Reset `main` to `origin/main`…** — when behind, ahead or diverged. This **can
  discard work**, so it always asks (**Cancel** is the first choice) and says what
  is lost: `Reset main to origin/main (def5678)? discards 2 local commits; discards
  uncommitted changes to 3 files; the old tip abc1234 stays reachable in the
  reflog`. The current branch runs `git reset --hard` (untracked files are left
  alone); another branch `git branch -f`. If the branch, its upstream or your
  working tree changes while the prompt is open, the reset is cancelled.

A branch checked out in another worktree is refused by git for both. They run like
fetch / pull below (one at a time, then a resync); the counts are against the last
fetch, so **Fetch** first to sync with the remote's current state.

**Upstream.** The same branch also gets entries that change what it tracks — only
its tracking config, no refs or files, so there is no prompt and the notice names
the previous upstream (`foo now tracks origin/foo (was origin/dev)`):

- **Track `origin/foo`** — when `foo` tracks a differently named branch (or
  nothing) and `origin/foo` exists; listed *before* the sync entries when the label
  warns about the mismatch. `git branch --set-upstream-to=origin/foo foo`.
- **Set upstream of `foo`…** — pick any remote-tracking branch (same-named first;
  local branches are not offered).
- **Unset upstream of `foo`** — `git branch --unset-upstream foo`.

gitloom never changes push settings (`push.default` etc.); the commit view only
shows where a push would go.

**Checkout & examine.** From the `<C-Space>` palette — a commit's entry (on its
message) or, with a `V` selection active, the selection's: gitloom checks the newest
commit out (`git checkout --detach`) and opens diffview on **one** rev — the
oldest commit's first parent (the empty tree for a root) — against the working
tree, so the right-hand side is the real files on disk and LSP / diagnostics
work. The diff is the same combined change the range view shows. A dirty tree
prompts **Stash N changes and continue** / **Cancel**; continuing runs
`git stash push -u -m "gitloom: examine <short> (from <branch>)"`. The palette
then offers **Return to `<orig>`**: it switches back (`git switch`, or a detached
checkout when you started detached) and re-applies the stash by SHA with
`--index`, so staged changes come back staged, dropping it when the apply is
clean. If git cannot restore the index (your branch moved so the staged patch no
longer applies), the changes are re-applied unstaged and a warning says so. A failed switch keeps the state so Return can be
retried; a conflicting apply keeps the stash and names it. The state survives
closing and reopening the graph. A second examine while one is active just moves
the examined commit — on a dirty tree it is refused ("Return first"), so there is
never a chain of stashes. A selection ending at a working-tree row opens its
working-tree range with no checkout. When the newest commit already **is** HEAD's
(attached or detached) the entry is **Examine** (`Examine <short>` / **Examine
selection**) instead: it just opens the same diffview — no checkout, no stash, no
Return — even on a dirty tree, whose uncommitted changes then show on the right
(select up onto the working-tree rows to see those as their own range). Requires
a diff provider (§10.4.2).

**Commit selection (range).** Press `V` to start a modal selection that picks a
range of commits **along one branch**. It is not a contiguous block of rows — it
follows the branch, skipping rows that belong to other branches:

- `j` / `k` extend or contract the selection along the followed branch (the
  cursor parks on the lit lane so you can see which branch you are on);
- `h` / `l` switch which branch the selection follows at the nearest fork / merge
  inside it;
- `<Tab>` folds / unfolds the head under the cursor in place — peek into a
  collapsed branch without losing the selection or moving the view;
- `<C-d>` / `<C-u>` jump roughly half a screen of branch commits;
- `o` swaps the fixed and moving ends;
- `<CR>` opens the **range view** — the selected commit list with the combined
  diff and diffstat — and `D` opens the range straight in the external diff
  viewer;
- `V` again or `<Esc>` ends selection.

A selection can end at the **working tree**: start on (or extend `k` into) one of
the `◌` working-tree rows (the clean row too) and the range runs from the older commit to your
live tree rather than to another commit — "what has changed since that branch
point, including everything I have not committed". Because the newer end is a tree
state and not a commit, gitloom hands the diff viewer a **single rev**, so it opens
the **real files on disk**: they are editable and your LSP attaches, which a
commit-to-commit range (read-only git blobs) cannot do. The *unstaged* and
*untracked* rows give you that; the *staged* row diffs against the index, whose
content has no file on disk, so LSP does not attach there.

The selected path is highlighted and everything else dims (reusing the
reachability emphasis). The footer shows a `SELECT N` indicator. See
[specification.md §13](specification.md).

**Context panes.** Two compact summary bands flank the graph so you keep sight of
how off-screen history connects without scrolling. Each shows **only** the lanes
crossing its edge plus the pinned anchors — a minimal rebuilt summary, not the
whole off-screen graph. The **footer** (below) continues the lanes active at the
bottom of the view down to where they merge into the main branch and reach the
root, with a marker for any pinned ref below the cutoff. The **header** (above)
shows the **minimal** off-screen-newer picture: only how the pinned anchors relate to
each other and to the lanes crossing the cutoff. It follows those lanes by id and keeps
a junction only where two of them meet — two crossing lanes, or a crossing lane merging
into an anchor, drawn as a node-less junction; an anchor gets its own labelled row; a
crossing lane that connects to nothing terminates at its own bare `◍`. The merge/fork
plumbing of every other feature branch that touched the trunk off-screen is **not
followed** — no stray feature heads, no back-and-forth crossings. Every lane crossing the bottom edge always continues (so the
bottom row lines up with the graph's top with no broken lanes), and the header
vanishes when you scroll to the top. Each lane keeps **the same colour it has in the
graph**, so branches stay distinct, and isolated `◍` tips pack onto as few rows as
possible (the pinned anchors keep their own labelled rows). Both are topology-only
(dashed lanes, solid junctions, no commit text). The panes also follow the
**reachability emphasis** (§12): the branch under the cursor stays lit where it
continues into the header/footer while unrelated off-screen lanes dim, so the cone
reads as one continuous picture across all three viewports. Toggle them with
`F` (§6.2).

The footer shows the active merge mode, the ref label mode, a `N collapsed,
M hidden` summary when any branch modes are set, and whether the graph is
mirrored (e.g. `Mode: inline | Refs: refs right | 1 collapsed, 0 hidden`).

Ref labels have three placements, cycled with `B` (`label_mode`):

- **right** (default) — pinned to the right edge of each row, with the message
  filling the gap (truncated with `…`); a `+N` marker stands in for labels that
  don't fit.
- **inline** — left-aligned right after the graph, before the message.
- **dual** — a labelled commit spans two rows: the graph + node + labels on the
  first, the message on the second (only for commits that have labels), tied by
  a muted pair bracket — `┬` right before the labels, `└` right before the
  message (`dual_bracket`, coloured by `palette.pair`). Both are
  real lines for the same commit; landing on the first row pre-selects the first
  label.

Pressing `<CR>` on a commit row opens the **commit view** — a read-only
view of that commit's full details (hash, refs, author, committer when it
differs, parents, the full message, a diffstat, and the diff), fetched on demand.
Long messages are wrapped to the window (at most 100 columns) and their
paragraphs reflowed; code blocks, indented lines, URLs and trailers are left as
written.
It opens **in the host window** as a navigation step, not a separate float: `q`
hides the window and `<C-o>` returns to the graph. The diff is colored
line-by-line (added / removed / hunk / file headers). The diffstat lists the
changed files; pressing `<CR>` on a file line jumps to that file's section in the
diff below (`<C-o>` / `<C-i>` jump back and forth between the diffstat and the
file, then step out to the graph once the jumplist is exhausted). As you
scroll the diff, a small **context header** sticks to the top of the view,
showing the current file and `@@ … @@` hunk once their real headers have
scrolled off — so you never lose track of where you are.

When a commit **bumps a submodule**, the diff would normally show just the old
and new `Subproject commit` hashes. If that submodule is checked out and both
commits are present locally, gitloom replaces the pair with a **small two-sided
change graph** of the submodule's own history: the commits the bump **added**
(green) above the new pointer, the commits it **removed** (red) above the old
pointer, both descending to their **common ancestor** at the bottom. The old and
new heads are marked, and the graph is truncated to a fixed height with the
budget split evenly between the two sides (`+K more` where commits are elided). A
fast-forward or rewind is just the degenerate case where one side is empty, so
the whole budget goes to the side that changed. gitloom never fetches for this:
if the submodule isn't checked out, the commits aren't present, or the two
histories are unrelated, it falls back to the plain hashes with a short reason.

Each **commit row** in that change graph is a **link into the submodule's own
repository**: pressing `<CR>` on it **drills into** the submodule's graph,
focused on the commit under the cursor. It opens as a **navigation step in the
current window** (not the submodule's own window — that's the picker), so `<C-o>`
returns to the commit view. The drilled-in graph marks both pointers as
**virtual refs** — a green **`new`** ref on the new commit and a red **`old`**
ref on the old one. Being refs, they render as labels in the graph **and the
context panes**, are **pinned** (so the new/old branches are revealed and stay
named in the header/footer as you scroll), and show in the `<leader>b` ref
picker. They're transient — a resync (`R`) drops them.

The first line of the commit view is an **action label** (`▶ Open diff
(diffview)`) and the cursor parks on it when the view opens, so `<CR>` then
`<CR>` opens the diff. The same diff opens from the graph with `D`. The diff
viewer is a configurable provider (`diff.open`/`diff.label`) operating on a
git range, defaulting to diffview — see Configuration.

Navigation is line-by-line, with `cursorline` marking the current row. The
cursor parks at the commit message; `l` moves the selection right onto the refs
and `h` moves it back left to the message, with the cursor following the
selected ref (the substrate for planned per-branch actions; it does nothing on
its own yet).

When the graph opens it focuses **HEAD** (the current branch's commit) and
centers the view on it. After that it **remembers where you were per repository**
for the rest of the Neovim session: close and reopen the graph and the cursor
returns to the same commit (re-centered) instead of jumping back to HEAD. A
detached HEAD is focused the same way — HEAD is always an anchor.

The row under the cursor is the **pivot**: gitloom dims everything outside its
reachability cone — its ancestors (following parents) and descendants
(following children) — so the relevant slice of history stands out. Dimming
keeps each lane's colour, only muted (`palette.dim`), so dimmed lanes stay
recognisable. It is on by default and follows the cursor; press `H` to toggle it
off and on. See [specification.md](specification.md) §12.

## Configuration

The graph view accepts an options table (`GraphOptions`). Defaults:

```lua
{
    win = {
        border = "rounded",
        -- Default: nearly full screen (~2-char margin each edge). A fraction
        -- (0–1) gives a proportional size; a number > 1 is absolute columns/rows.
        width = function() return math.max(vim.o.columns - 4, 1) end,
        height = function() return math.max(vim.o.lines - 4, 1) end,
        -- title defaults to the repository name + current branch, or
        -- `detached @<short>` (§2.1); set
        -- win.title here to pin your own.
        footer = "(status + key hints)",
    },
    palette = {
        date = "Title",
        author = "Comment",
        branch = "WarningMsg",   -- local branch name in (name ↑remotes)
        remote = "Comment",      -- the ↑remotes suffix (and remote-only names)
        head = "Special",        -- HEAD's label: (HEAD → branch), or a detached HEAD
        message = nil,
        tags = "Comment",
        worktree = "Comment",    -- a linked worktree's HEAD label, {wt:<dir>}
        selected = "Visual",     -- the h/l-selected ref decoration
        pair = "NonText",        -- the dual-mode pair bracket (§6.1); false = blank
        action = "Special",      -- the commit-view diff action label (§11.5)
        dim = 0.45,              -- blend toward bg for out-of-cone rows/lanes (§12)
        -- brightness levels (§5.5): 0–1 blends toward bg, 0 = off; anything else = default
        remote_mute = 0.25,      -- slightly muted: a pinned or expanded remote branch
        -- remote_mute_out = nil, -- its blend out of focus (§12.2); nil = 0.75 * dim
        -- (the former names counterpart_dim / counterpart_dim_out still work as aliases)
        collapsed_mute = 0.45,   -- muted: any collapsed, unpinned branch (replaces remote_mute)
        -- collapsed_mute_out = 0.45, -- its blend out of focus (§12.2)
        -- highlight_mute = 0.1,  -- both muted levels IN focus while highlighting (§12.2)
        -- commit-view diff colors (§11.3)
        diff = { add = "DiffAdd", delete = "DiffDelete", hunk = "Title", header = "Comment" },
        -- submodule change view (§11.7): added / removed / common-ancestor marker
        -- colours (foreground only; darker muted green/red by default). base = nil
        -- means "use lane 1's colour" (tracks[1]).
        submodule = { new = "GitloomSubmoduleAdd", old = "GitloomSubmoduleDel", base = nil },
        -- upstream tracking (§6.3): the ⇡N / ⇣N / gone tokens; `upstream` the
        -- spelled-out non-matching upstream (→origin/dev), `mismatch` that token
        -- when a same-named remote branch also exists.
        track = { ahead = "Added", behind = "WarningMsg", gone = "Comment",
                  upstream = "Comment", mismatch = "GitloomTrackMismatch" },

        tracks = { "Constant", "String", "Number", "Function", "DiagnosticInfo", "Identifier" },
    },
    merge_style = {
        allow_merge_on_split = false,
        merge_on_separate_line = false,
        split_on_separate_line = true,
    },
    icons = {
        -- merge = "M",
        head = "●",          -- HEAD's node marker (§5.3); "" = off
        pin = "⚲",           -- pinned-anchor label icon (§6/§10.6); "" = off
        expanded = "▾",      -- label icon of a branch you opened (§6); "" = off
        upstream = "→",      -- before a non-matching upstream, →origin/dev (§6.3)
        remote = "⇣",        -- label icon of a remote branch with no local (§6); "" = off
    },
    branches = { "--all" },  -- refspec(s) passed to `git log`
    layout_policy = "compact", -- lane placement (§5.6); cycle with C:
                             -- "compact" / "survivors" / "linear" /
                             -- "straight" / "gutter"
    mirror = true,           -- render mirrored (lane 1 on the right); toggle with M
    highlight = true,        -- reachability dimming (§12) on; toggle with H
    collapse_merged = true,  -- first-parent focus (§10.7) on; toggle with c
    pack_markers = true,     -- pack concurrent collapsed heads (§10.4) on; toggle with p
    junction_markers = true, -- draw kept fork/merge junctions node-less (§10.4)
    date_format = "%Y-%m-%d %H:%M",  -- os.date format for absolute dates
    date_mode = "absolute",  -- "absolute" or "relative"; toggle with d
    message_min = 24,        -- min width kept for the message; refs use the rest
    label_mode = "right",    -- ref placement: "right" / "inline" / "dual"; cycle with B
    dual_bracket = { "┬", "└" }, -- dual mode's pair bracket: label row, message row
    lane_label_colors = true, -- each branch label in its own ref's colour at its brightness level, tags in their node's (false: per-kind groups)
    working_tree = true,     -- the ◌ working-tree row above HEAD: true | "dirty" | false (§3.3/§4.2)
    scrolloff = 10,          -- context rows kept around the cursor (graph + commit view)
    persist = true,          -- remember the view toggles + pin lists across sessions (§18)
    progress = {             -- long-running operations (§19); progress = false for none
        provider = "auto",   -- "auto" (fidget if installed, else vim.notify) / "fidget" / "notify" / false / { start = fn }
        delay = 300,         -- ms an operation must run before it is shown at all
    },
    zindex = 41,             -- the graph window's zindex; its overlays +1, its own floats +2 (§14.1)
    search = {               -- commit search (§15; <leader>gl or :GitloomSearch)
        snippet = 7,         -- graph rows shown around the commit in the preview
        layout = "vertical", -- preview arrangement (snippet above the detail)
    },
    diff = {
        -- External diff provider, operating on a git range (§11.5). Default opens
        -- diffview; override to use another plugin, or set open = nil to disable.
        -- Run it in range.root (the graph's repository), not the cwd:
        -- open = function(range)
        --     require("diffview").open(require("gitloom.git.range").diffview_args(range))
        -- end,
        label = "▶ Open diff (diffview)",  -- commit-view action label text
    },
}
```

- **`win`** — floating window geometry (forwarded to snacks.win). Fractional
  `width`/`height` are a share of the editor.
- **`palette`** — highlight groups per field. `tracks` is the curated colour
  list the branches draw from (§5.5; generated colours extend it on truecolor
  terminals). `dim` is a blend factor (`0`–`1`) toward the
  window background applied to everything outside the cursor row's reachability
  cone (§12); each field keeps its own colour, just muted (a higher factor is
  more muted). Falls back to a flat `NonText` on non-truecolor terminals.
  `remote_mute` (default `0.25`) and `collapsed_mute` (default `0.45`) are the two
  muted **brightness levels** (§5.5): a pinned or expanded remote branch, and any
  collapsed, unpinned branch (which takes `collapsed_mute` instead of
  `remote_mute`). `remote_mute_out` is a pinned or expanded remote's blend out of
  the cone (default `0.75 × dim`); a collapsed branch out of the cone takes
  `collapsed_mute_out` (default `0.45`). While the reachability highlight is on,
  both muted levels take `highlight_mute` (default `0.1`, almost full brightness)
  inside the cone instead. `0` turns a level's muting off, and a value that is
  not a number in `0`–`1` falls back to its default. (`remote_mute` /
  `remote_mute_out` were formerly `counterpart_dim` / `counterpart_dim_out`, still
  accepted.)
- **`merge_style`** — controls whether merges/splits get their own virtual
  line above/below the commit, or are folded onto the commit line.
- **`layout_policy`** — the lane **layout policy** (default `"compact"`): which
  lanes may move sideways to close a gap. `"compact"` (linear-commit slide +
  survivor compaction, today's behaviour), `"survivors"` (compaction only),
  `"linear"` (slide only), or `"straight"` (neither — every lane holds its column
  for life, so the trunk never steps sideways, at the cost of leaving occasional
  empty columns). `"gutter"` additionally pins the lane of the commit you are
  reading to a **fixed column** beside the message, so it is always obvious which
  branch a message belongs to; a run of commits on one branch draws a straight
  vertical with the nodes on it, and the column changes hands only where the next
  commit belongs to a different branch. Each handover is drawn on rows of its own —
  one lane moves out, then one moves in — so no row ever carries two wires along the
  same run. It costs those extra rows (a few percent in the default focused view,
  more with every branch expanded) and the crossings they draw. Where the branch that
  needs the column next is one a **merge** on the current row is merging in, the
  column is handed straight to it at the merge and those rows are skipped entirely
  (~10% fewer rows and ~14% fewer crossings with every branch expanded, nothing at all
  in the default view); the merge's node keeps its own branch's colour and the
  merged-in branch's lane simply starts below it. Likewise at a **fork**: where the
  column is held by a branch that ends at that fork, the commit simply takes the
  column where that branch already is instead of moving both lanes, skipping another
  two rows (a further ~12% fewer rows and ~44% fewer crossings expanded — again
  nothing at all in the default view).
  Cycle live with `C` to compare them on a real repository; the
  cycled value is remembered for the next open (see `persist`). See
  [specification.md](specification.md) §5.6.
- **`branches`** — the ref arguments passed to `git log` (default `--all`).
- **`sort_mode`** — the initial row sort mode (default `"topo"`): `"topo"`
  (gitloom's own topological order, which reproduces git's `--topo-order`),
  `"date"`, or `"author"` (git's date / author-date order). Cycle live with `S`.
- **`mirror`** — render the graph mirrored, with lane 1 at the right edge of the
  graph column (nearest the message). On by default; set `false` for the
  conventional left-to-right layout. Only the graph flips: the ref labels keep
  their priority order (HEAD's branch first) either way. A render-only
  transform; toggle live with `M`. See [specification.md](specification.md) §5.4.
- **`highlight`** — whether reachability dimming (§12) starts enabled (default
  `true`). Toggle live with `H`.
- **`collapse_merged`** — whether the first-parent focus (§10.7) starts enabled
  (default `true`): the current branch's mainline in full, every other branch
  collapsed. Toggle live with `c`.
- **`pack_markers`** — whether concurrent collapsed heads pack onto shared lines
  (§10.4; default `true`). Toggle live with `p`.
- **`junction_markers`** — whether a fork/merge kept inside collapsed branches
  renders node-less (just the split lanes, no message; §10.4; default `true`). A
  junction that carries a ref still shows a `◍` marker so the label is anchored;
  only ref-less junctions are fully node-less. Off shows those junction commits in
  full.
- **`date_format`** / **`date_mode`** — the author date is parsed into a
  structured timestamp and rendered either as an absolute author-local time
  (`date_format`, an `os.date` string) or a relative age (`date_mode =
  "relative"`). Toggle live with `d`.
- **`message_min`** — in the default `right` label mode the ref labels are pinned
  to the right edge of the row and use the free width; the message keeps at least
  `message_min` columns (truncated with `…`), and refs that don't fit collapse
  into a `+N` marker.
- **`label_mode`** — where ref labels are placed: `"right"` (default, the
  right-edge layout above), `"inline"` (left-aligned before the message), or
  `"dual"` (on a separate line above the commit's message). Cycle live with `B`.
  See [specification.md](specification.md) §6.1.
- **`dual_bracket`** — the glyphs of the `dual` pair bracket that ties a
  labelled commit's two rows: `{ label_row, message_row }` (default
  `{ "┬", "└" }`), drawn exactly as given — add a trailing space
  (`{ "┬ ", "└ " }`) for a gap before the text. Its colour is `palette.pair`
  (default `NonText`; `false` leaves the prefix blank at the same width).
- **`lane_label_colors`** — draw every branch label in **its own ref's colour**
  (default `true`) — the colour of that branch's identity at its brightness level
  (collapsed branches on `◍` heads and packed markers included) — dimmed out of the
  cursor's reachability cone. A tag takes its node's colour; worktree labels keep
  their per-kind colour; the `HEAD` marker keeps `palette.head`, the
  `h`/`l`-selected label `palette.selected`. `false` restores the per-kind groups
  (`palette.branch` / `remote` / `tags` / `worktree`) for every label, tags
  included; lanes and nodes are coloured by ref either way. See
  [specification.md](specification.md) §6 "Label colour".
- **`pin_upstream`** — removed: a pin always covers the branch's identity
  (local + remotes); a set value is ignored (§10.6).
- **`diff`** — the external diff provider (`D` and the commit view's action
  label). `open` is called with a `DiffRange` (`{ rev, from, to, root }` — `rev`
  is a git rev-range like `<hash>^!`; an endpoint may also be the tree state
  `"index"` or `"worktree"` for a working-tree node; `root` is the graph's
  repository, which need not be Neovim's cwd — a submodule or a repository opened
  from the picker — so a custom `open` must resolve `rev` there, e.g. diffview's
  `-C<root>`) and defaults to opening diffview in `root`;
  `label` is the action-label text. Override `open` to use a different diff
  plugin, or set it to `nil` to disable the integration. See
  [specification.md](specification.md) §11.5.
- **`working_tree`** — show the working tree as virtual `◌` commits on top of
  HEAD: `true` (default) | `"dirty"` | `false`. A dirty tree shows a *staged* node
  (index vs HEAD), an *unstaged* node (tracked working tree vs index), and an
  *untracked* node (untracked files as additions), stacked newest-first untracked →
  unstaged → staged → HEAD and each shown only when it has content. With `true` a
  clean tree shows a single `◌ Working tree · clean` row instead, so HEAD always has
  the working tree drawn above it; `"dirty"` shows only the change nodes (nothing on
  a clean tree); `false` never reads the working tree. The `◌` takes the HEAD
  colour and continues HEAD's lane in its branch colour; opening the graph still
  puts the cursor on HEAD's own row. They open in the commit view / external diff
  like any commit (the clean row's diff is empty), the palette's **Examine working
  tree** shows every uncommitted change against HEAD on the real files, and they
  refresh live as you edit or stage (`BufWritePost`, focus, `:!` commands and
  leaving a terminal), or as part of the full `R` resync. gitloom never stages or
  commits. See [specification.md](specification.md) §3.3 / §4.2.
- **`scrolloff`** — the window-local `'scrolloff'` for the graph and commit-view
  windows: how many context rows are kept above/below the cursor (default `10`).
  Set explicitly so the windows don't inherit your global value. A non-zero value
  interacts with the context-pane overlays (§6.2); set `0` to restore the prior
  always-zero behaviour if the panes' scrolling misbehaves.
- **`search`** — the commit search (`<leader>gl` or `:GitloomSearch`, §15). `snippet` is
  how many graph rows are shown around the commit in the preview (default `7`,
  odd so the commit is centered); `layout` is the preview arrangement (currently
  only `"vertical"` — the snippet above the commit detail).
- **`persist`** — remember how you left the graph (§18), on by default. The view
  toggles `m C M B d H S c p F i` are saved when you press them, and each
  repository's pin list (`P`, the `L` dialog) when it changes, in one JSON file,
  `stdpath("state")/gitloom.json`, shared by every Neovim instance (each write
  re-reads and merges, so two instances do not clobber each other). They come back
  on the next open, taking precedence over your `setup()` values — **unless you
  change that option in your config afterwards**: each saved toggle records the
  configured value it overrode, and a changed configuration wins. Collapse /
  expand choices are not remembered. **Reset view settings…** in the `<C-Space>`
  palette, or `:GitloomResetView`, clears the toggles and the current repository's
  pin list (other repositories keep theirs) and restores your configuration live.
  A pin entry's `reserved` flag saved by an older version (the dropped dedicated
  lane) is ignored and no longer written.
  A corrupt file is ignored with one warning. `persist = false` neither reads nor
  writes the file.
- **`progress`** — how gitloom reports operations that take a while (§19):
  opening the graph, `R`, fetch / pull, checkout, checkout & examine / Return,
  the branch sync, a `rev` sort and a diff load. An operation is shown only once it
  has run for `delay` ms, so fast ones produce nothing. With
  [fidget.nvim](https://github.com/j-hui/fidget.nvim) installed (`provider =
  "auto"`, the default) each appears as a fidget entry under **gitloom** (and
  replaces the `Fetching…` / `Pulling…` notice); without it, an operation that has
  no notice of its own (the open, a sort, a diff load) gets a `gitloom: <title>…`
  notice and, when it succeeds, a `… — done (N s)` one — operations that already
  notify (fetch, checkout, …) are not announced twice. A fetch / pull's live
  status goes to the fidget entry, or — only with a notifier that can replace a
  notice — into its one notice, at most once a second. Success and error notices
  are kept under every provider. `provider = false` (or `progress = false`) turns
  reporting off; a table `{ start = function(op) … end }` plugs in your own.
- **`zindex`** — the graph window's float zindex (default `41`, §14.1). gitloom
  is a full-screen window, so it sits above ordinary windows' float decorations
  (treesitter-context, scrollbars: ≤ 40) and below other plugins' floats —
  fidget / oil / mason (44–45), pickers, `vim.ui.select` and notifications (50+)
  draw over it. Its own layers follow: the context panes and the commit-view
  sticky header at `zindex + 1`, the `?` / `K` floats, the pin dialog, the filter
  prompt and the commit search at `zindex + 2`. Floats gitloom does not own keep
  their own zindex. Raise it if another plugin's float should stay under the
  graph.
- **`pick_key`** — the normal-mode mapping `setup()` installs for the repository
  picker (`:GitloomPick`, §2.1; default `<leader>wG`). Set to a string to remap,
  or `false` to install no mapping. A setup-level option, not a graph option.

> **Note:** `require("gitloom").setup(opts)` stores config and `:GitloomGraph`
> now forwards it to the graph (merged over the defaults above, read at invocation
> time). See [specification.md](specification.md) §Configuration.

## Testing

Tests use [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)'s busted
harness.

```sh
make test                          # run all specs
make test-file FILE=tests/refs_spec.lua   # run a single spec
```

## Diagnostics

Four opt-in dump globals, all off by default and all harmless to leave unset.
Set any of them to a **file path** and gitloom writes a plain-text dump there.

```lua
-- Every git command gitloom spawns: the full argv (one element per line), the
-- resolved cwd and executable, the call site, the resulting process id — and, on a
-- failed spawn, the error plus the command-line length measured against the
-- 32766-character Windows ceiling. Appends; unset it to stop.
vim.g.gitloom_git_debug = vim.fn.stdpath("data") .. "/gitloom_git.log"

-- The live context-pane seam/boundary/header topology (also bound to <leader>wD
-- inside the graph). Overwrites on each pane rebuild.
vim.g.gitloom_pane_debug = vim.fn.stdpath("data") .. "/gitloom_pane_dump.txt"

-- The context panes' LIFECYCLE: one line per rebuild decision, build outcome and
-- close. Appends; unset it to stop.
vim.g.gitloom_pane_trace = vim.fn.stdpath("data") .. "/gitloom_pane_trace.log"

-- The OPEN path, phase by phase: the ref query, every streamed commit batch, then
-- the completion pass (sort / owners / signatures / projection / layout / marker
-- packing / apply) with the counts each phase scales with. Appends; unset it to
-- stop. Arm it, open the repository, and send the file.
vim.g.gitloom_open_trace = vim.fn.stdpath("data") .. "/gitloom_open.log"
```

`gitloom_pane_trace` is the one to reach for when the header/footer overlays are
missing, stale, or do not follow scrolling. It records, in order:

| record | meaning |
| --- | --- |
| `maybe` | the scroll-gated entry point: the current scroll key, the key the panes on screen were **built** for, and whether it chose `rebuild` or `repaint` — plus whether each overlay is currently `up`/`down` |
| `update` | a rebuild started, with the scroll key it targets and the call site |
| `geom` | the viewport the build measured its seams from — cursor line, display index, `winline`, window height, `topline`, `topfill`, `w0` |
| `yield` / `abandon` | the build spilled onto another tick / was dropped (a scroll landed mid-build, or a newer build superseded it) |
| `built` | the build finished, with the **decline reason** for each pane (`ok`, `at top`, `at bottom`, `no rows`, `past top@N`, `off`, `no HEAD`) |
| `hide_all` / `close` | both panes were hidden, with the reason or a stack trace |

The distinction that splits the search space fastest: a pane that is missing with
a `built … ftr=<reason>` line **declined** (the seam or the topology said no),
whereas one missing with a `close` line was torn down by the window layer. And a
`maybe … act=repaint` where the panes are `down` means the gate believes they are
current when they are not.

`gitloom_open_trace` is the one to reach for when a repository is slow to open.
Each line is one phase, with the elapsed time since the open began and that
phase's own cost:

| record | meaning |
| --- | --- |
| `open` | the open began (it restarts the clock, so several opens read as separate timelines) |
| `refs` | the ref query finished — `n` refs |
| `batch` | one streamed commit batch was linked in, laid out and inserted — `i` the batch number, `n` its commits, `rows` the running total. The **first** `batch` line is when something was first painted |
| `stream` | `git log` closed — total `rows` over `batches`, and the wall time of the whole stream |
| `sort` | the active sort mode was applied (§3.1) |
| `owners` | the owner set was resolved — `n` owners of which `merges` are the anonymous per-merge-parent family (§10.2), over `rows` commits |
| `signatures` | per-commit owner signatures (§10.2); `cached=true` means the cache was reused and nothing was computed |
| `project` | the projection (§10.3) — `rows` is what it produced, so `rows` here against the `owners` line's `rows` says how many rows the collapse actually removed |
| `layout` | Phase 1 lane layout over the projection |
| `pack` | marker packing (§10.4) |
| `apply` | the atomic swap into the view (§10.5) |
| `done` | the graph is on screen; `ms` is the whole open |

The two questions it settles: how much of the wait is `git log` (the `stream`
line) versus the completion pass (`sort` … `apply`), and — inside the completion
pass — whether the cost tracks the repository's *size* or its *shape*.
`signatures` is O(commits × owners) and an owner is minted per non-first merge
parent (§10.2), so a trunk of merges pays several times what a linear history of
the same length does.

`gitloom_git_debug` is the one to reach for when a git query fails to start —
notably Windows' `E903: Process failed to start: name too long`, which names the
(perfectly valid) `git.exe` and so reads as the wrong problem entirely. It is
really `UV_ENAMETOOLONG`: the command line exceeded 32766 characters. The dump
prices every spawn against that cap and says outright which one went over.

## Documentation

- [specification.md](specification.md) — behavioral contract (what gitloom does)
- [ARCHITECTURE.md](ARCHITECTURE.md) — implementation architecture (how it's built)
- [CLAUDE.md](CLAUDE.md) — project context and development workflow

## License

TBD
