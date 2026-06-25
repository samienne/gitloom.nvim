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
  them; the window opens immediately
- **Virtualized rendering** — only the visible range is laid out and drawn,
  so large histories stay responsive
- **Configurable merge style** — render merges/splits inline or on their
  own virtual lines
- **Reachability emphasis** — the row under the cursor dims everything not in
  its history (ancestors) or downstream of it (descendants), keeping each
  lane's colour (just muted) so the relevant graph stands out
- **Working-tree changes** — uncommitted work shows as up to three `◌` nodes
  (staged, unstaged, untracked) on top of HEAD; open any to inspect its
  diff in the commit view or the external viewer. Updates live as you edit or
  stage (and on `R`); strictly read-only — gitloom never stages or commits

### Planned

- **Collapse a branch** to a single line in the view
- **Pin branch-heads** so everything they reference stays visible
- **Toggle branch visibility** (visible / collapsed / hidden) with the graph
  reflowing to match
- **Graph-initiated actions** and integrations (e.g. diffview) where they
  arise naturally from the graph

## Requirements

- Neovim >= 0.10 (uses the 4-argument `vim.str_byteindex` and the
  decoration-provider API)
- [snacks.nvim](https://github.com/folke/snacks.nvim) (window management)
- *Optional:* [diffview.nvim](https://github.com/sindrets/diffview.nvim) (or any
  diff plugin) for the external diff (`D` / the commit view's action label); the
  provider is configurable, so diffview is not required

## Installation

gitloom follows the same dev/branch pattern as the rest of the loomworks
suite. With lazy.nvim:

```lua
{
    url = "https://gitcode.com/samienne/gitloom.nvim",
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
```

Opens the graph for the repository at Neovim's current working directory.

| Key | Action |
|-----|--------|
| `q` | Close the graph |
| `m` | Cycle the merge/split rendering style (split line → merge line → both → inline → inline w/ merge-on-split) |
| `M` | Toggle mirroring — render the graph with lane 1 on the right, nearest the message |
| `B` | Cycle the ref label placement (right edge → inline before the message → its own line) |
| `<Tab>` | Collapse ⇄ expand the branch under the cursor (toggle; the cursor follows so repeated `<Tab>` flips it in place) |
| `<CR>` | Action menu for the row — examine commit, open diff, collapse / expand / hide the branch |
| `D` | Open the commit's diff in an external diff viewer (diffview by default) |
| `d` | Toggle the date column between absolute and relative ("3 days ago") |
| `h` / `l` | Select the previous / next ref decoration on the current row — on a packed marker line, the previous / next collapsed head, with the reachability emphasis following it (switch the followed branch while selecting) |
| `V` | Start / end **commit selection** — pick a range of commits along one branch |
| `H` | Toggle reachability highlighting (dimming) off / on |
| `c` | Toggle first-parent focus — collapse every non-mainline branch, or show the full graph |
| `P` | Pin / unpin the branch under the cursor as an anchor — pinned branches stay shown in full under focus (HEAD is pinned by default) |
| `p` | Toggle marker packing — merge concurrent collapsed heads onto shared lines, or one per line |
| `R` | Resync with the repository — re-read refs, pull new commits, prune unreachable ones, re-sort, and rebuild the working-tree changes (`◌` nodes), keeping your cursor / scroll / selection |
| `S` | Cycle the row **sort mode** — gitloom's own topological order (reproduces git's `--topo-order`), or git's date / author-date order; reorders in place |
| `<leader>b` | Jump to a branch / ref — open a picker of all branches, remotes, tags, and HEAD; selecting one centers the view on its commit (recently jumped refs first) |
| `F` | Toggle the off-screen context panes (summary bands above and below the graph) |
| `K` | Float with the full lane breakdown for the commit under the cursor (debug) |
| `i` | Toggle the per-lane id column before the message (debug; hidden by default) |
| `?` | Float listing all keybindings |

**Branch modes.** A branch can be **normal**, **collapsed** (contracted to a
single `◍` marker row — a commit count and the ref), or **hidden**. The
collapse interactions act on the **branch under the cursor**, found from the
commit's history — no ref needed, so they work for ref-less regions too
(first-parent-merged, squashed):

- `<Tab>` toggles **collapse ⇄ expand** in place; the cursor follows the result,
  so holding `<Tab>` flips a branch open and closed.
- `<CR>` opens an **action menu** for the row — examine commit, open diff,
  collapse, expand, **hide** — most-relevant first. On a packed line it lists
  every marker by name, so any branch is reachable even when labels overflow.
- `h`/`l` selects a ref (or a marker on a packed line) for the toggle/menu to
  act on.

See the design in [specification.md §10](specification.md).

**First-parent focus (default).** By default the graph opens focused on the
current branch: HEAD's first-parent mainline is shown in full and every other
branch — merged-in *and* divergent — is collapsed to a `◍` head. Press `c` to
toggle this off (the full graph) and on again; your explicit per-branch toggles
are kept across the switch. Disable the default with `collapse_merged = false`
(§10.7).

**Anchors (pinning).** Focus folds everything toward the *anchors* — by default
the current branch (HEAD) plus the common trunks `master` / `main` / `dev` when
they exist. Press `P` on a branch to pin it as another anchor (or unpin it):
pinned branches stay shown in full under focus, so you can keep `master`, `dev`,
a release branch and a few of your own in view at once while everything else
collapses. The footer notes the anchor count when more than one is pinned
(§10.6). Pinning a local branch also pins its **tracked upstream** (so both lanes
stay in full and a divergence is drawn rather than the remote collapsing);
disable with `pin_upstream = false`.

**Upstream tracking.** A local branch that tracks a remote shows a terse
divergence indicator after its name: `⇡N` ahead, `⇣N` behind, `⇡N⇣M` diverged,
`gone` when the upstream was deleted (in sync shows nothing). So `(master ⇡2⇣3)`
means two commits ahead and three behind `origin/master`. The current branch's
status also shows in the footer, and `⇡⇣` appears in the `<leader>b` ref picker.
Counts are git's own, computed against the **last-fetched** remote state (gitloom
never fetches; `git fetch` then `R` refreshes them). The upstream is read from
git's tracking config, not a shared name, so it stays correct across mirrored or
many-remote setups. Colors are configurable via `palette.track`.

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
each other and to the lanes crossing the cutoff. Two crossing lanes that meet above
the view draw a node-less junction where they converge; an anchor gets its own
labelled row; a crossing lane that connects to nothing terminates at its own bare `◍`.
An unpinned branch that forks off the trunk and reconnects to nothing is **not shown**
— no stray feature heads. Every lane crossing the bottom edge always continues (so the
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
  first, the message on the second (only for commits that have labels). Both are
  real lines for the same commit; landing on the first row pre-selects the first
  label.

Pressing `<CR>` on a commit opens the **commit view** — a read-only float with
that commit's full details (hash, refs, author, committer when it differs,
parents, the full message, a diffstat, and the diff), fetched on demand. The
diff is colored line-by-line (added / removed / hunk / file headers). The
diffstat lists the changed files; pressing `<CR>` on a file line jumps to that
file's section in the diff below (`<C-o>` / `<C-i>` jump back and forth, and
`<C-o>` closes the view once it would step back out). `q` closes it. As you
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
returns to the same commit (re-centered) instead of jumping back to HEAD. On a
detached HEAD there is nothing to focus, so the view opens at the top.

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
        title = "GraphView",
        footer = "(status + key hints)",
    },
    palette = {
        date = "Title",
        author = "Comment",
        branch = "WarningMsg",   -- local branch name in (name ↑remotes)
        remote = "Comment",      -- the ↑remotes suffix (and remote-only names)
        head = "Special",        -- HEAD marker on the current branch
        message = nil,
        tags = "Comment",
        selected = "Visual",     -- the h/l-selected ref decoration
        action = "Special",      -- the commit-view diff action label (§11.5)
        dim = 0.45,              -- blend toward bg for out-of-cone rows/lanes (§12)
        -- commit-view diff colors (§11.3)
        diff = { add = "DiffAdd", delete = "DiffDelete", hunk = "Title", header = "Comment" },
        -- submodule change view (§11.7): added / removed / common-ancestor marker
        -- colours (foreground only; darker muted green/red by default). base = nil
        -- means "use lane 1's colour" (tracks[1]).
        submodule = { new = "GitloomSubmoduleAdd", old = "GitloomSubmoduleDel", base = nil },
        -- upstream divergence indicator (§6.3): the ⇡N / ⇣N / gone tokens.
        track = { ahead = "Added", behind = "WarningMsg", gone = "Comment" },

        tracks = { "Constant", "String", "Number", "Function", "DiagnosticInfo", "Identifier" },
    },
    merge_style = {
        allow_merge_on_split = false,
        merge_on_separate_line = false,
        split_on_separate_line = true,
    },
    icons = {
        -- merge = "M",
    },
    branches = { "--all" },  -- refspec(s) passed to `git log`
    mirror = true,           -- render mirrored (lane 1 on the right); toggle with M
    highlight = true,        -- reachability dimming (§12) on; toggle with H
    collapse_merged = true,  -- first-parent focus (§10.7) on; toggle with c
    pack_markers = true,     -- pack concurrent collapsed heads (§10.4) on; toggle with p
    junction_markers = true, -- draw kept fork/merge junctions node-less (§10.4)
    date_format = "%Y-%m-%d %H:%M",  -- os.date format for absolute dates
    date_mode = "absolute",  -- "absolute" or "relative"; toggle with d
    message_min = 24,        -- min width kept for the message; refs use the rest
    label_mode = "right",    -- ref placement: "right" / "inline" / "dual"; cycle with B
    working_tree = true,     -- show uncommitted changes as ◌ nodes (§3.3/§4.2); refresh with R
    scrolloff = 10,          -- context rows kept around the cursor (graph + commit view)
    pin_upstream = true,     -- pinning a local branch also pins its tracked upstream (§6.3/§10.6)
    diff = {
        -- External diff provider, operating on a git range (§11.5). Default opens
        -- diffview; override to use another plugin, or set open = nil to disable.
        -- open = function(range) vim.cmd("DiffviewOpen " .. range.rev) end,
        label = "▶ Open diff (diffview)",  -- commit-view action label text
    },
}
```

- **`win`** — floating window geometry (forwarded to snacks.win). Fractional
  `width`/`height` are a share of the editor.
- **`palette`** — highlight groups per field. `tracks` is a list cycled by
  lane id to color each lane. `dim` is a blend factor (`0`–`1`) toward the
  window background applied to everything outside the cursor row's reachability
  cone (§12); each field keeps its own colour, just muted (a higher factor is
  more muted). Falls back to a flat `NonText` on non-truecolor terminals.
- **`merge_style`** — controls whether merges/splits get their own virtual
  line above/below the commit, or are folded onto the commit line.
- **`branches`** — the ref arguments passed to `git log` (default `--all`).
- **`sort_mode`** — the initial row sort mode (default `"topo"`): `"topo"`
  (gitloom's own topological order, which reproduces git's `--topo-order`),
  `"date"`, or `"author"` (git's date / author-date order). Cycle live with `S`.
- **`mirror`** — render the graph mirrored, with lane 1 at the right edge of the
  graph column (nearest the message). On by default; set `false` for the
  conventional left-to-right layout. A render-only transform; toggle live with
  `M`. See [specification.md](specification.md) §5.4.
- **`highlight`** — whether reachability dimming (§12) starts enabled (default
  `true`). Toggle live with `H`.
- **`collapse_merged`** — whether the first-parent focus (§10.7) starts enabled
  (default `true`): the current branch's mainline in full, every other branch
  collapsed. Toggle live with `c`.
- **`pack_markers`** — whether concurrent collapsed heads pack onto shared lines
  (§10.4; default `true`). Toggle live with `p`.
- **`junction_markers`** — whether a fork/merge kept inside collapsed branches
  renders node-less (just the split lanes, no message; §10.4; default `true`).
  Off shows those junction commits in full.
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
- **`diff`** — the external diff provider (`D` and the commit view's action
  label). `open` is called with a `DiffRange` (`{ rev, from, to }` — `rev` is a
  git rev-range like `<hash>^!`; an endpoint may also be the tree state `"index"`
  or `"worktree"` for a working-tree node) and defaults to opening diffview;
  `label` is the action-label text. Override `open` to use a different diff
  plugin, or set it to `nil` to disable the integration. See
  [specification.md](specification.md) §11.5.
- **`working_tree`** — show uncommitted changes as virtual `◌` commits on top of
  HEAD (default `true`): a *staged* node (index vs HEAD), an *unstaged* node
  (tracked working tree vs index), and an *untracked* node (untracked files as
  additions), stacked newest-first untracked → unstaged → staged → HEAD and each
  shown only when it has content. They open in the commit view / external diff like
  any commit, and refresh live as you edit or stage (`BufWritePost` / focus), or as
  part of the full `R` resync. gitloom never stages or commits. See
  [specification.md](specification.md) §3.3 / §4.2.
- **`scrolloff`** — the window-local `'scrolloff'` for the graph and commit-view
  windows: how many context rows are kept above/below the cursor (default `10`).
  Set explicitly so the windows don't inherit your global value. A non-zero value
  interacts with the context-pane overlays (§6.2); set `0` to restore the prior
  always-zero behaviour if the panes' scrolling misbehaves.

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

## Documentation

- [specification.md](specification.md) — behavioral contract (what gitloom does)
- [ARCHITECTURE.md](ARCHITECTURE.md) — implementation architecture (how it's built)
- [CLAUDE.md](CLAUDE.md) — project context and development workflow

## License

TBD
