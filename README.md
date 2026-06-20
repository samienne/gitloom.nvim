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
| `<CR>` | Selected ref: cycle its branch mode (normal → collapsed → hidden); collapsed head: expand it; otherwise open the commit view |
| `D` | Open the commit's diff in an external diff viewer (diffview by default) |
| `d` | Toggle the date column between absolute and relative ("3 days ago") |
| `h` / `l` | Select the previous / next ref decoration on the current row |
| `H` | Toggle reachability highlighting (dimming) off / on |
| `c` | Toggle first-parent focus — collapse every non-mainline branch, or show the full graph |
| `p` | Toggle marker packing — merge concurrent collapsed heads onto shared lines, or one per line |
| `K` | Float with the full lane breakdown for the commit under the cursor (debug) |
| `i` | Toggle the per-lane id column before the message (debug; hidden by default) |
| `?` | Float listing all keybindings |

**Branch modes.** Select a ref with `h`/`l`, then `<CR>` cycles it through
**normal → collapsed → hidden**. A *collapsed* branch contracts its commits to a
single `◍` head row (showing a commit count, the tip's subject, and the ref);
*hidden* removes them. A branch's local ref and its tracking remotes cycle
together. `<CR>` on a collapsed head expands it again. See the design in
[specification.md §10](specification.md).

**First-parent focus (default).** By default the graph opens focused on the
current branch: HEAD's first-parent mainline is shown in full and every other
branch — merged-in *and* divergent — is collapsed to a `◍` head. Press `c` to
toggle this off (the full graph) and on again; your explicit per-branch toggles
are kept across the switch. Disable the default with `collapse_merged = false`
(§10.7).

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
`<C-o>` closes the view once it would step back out). `q` closes it.

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
  git rev-range like `<hash>^!`) and defaults to opening diffview; `label` is the
  action-label text. Override `open` to use a different diff plugin, or set it to
  `nil` to disable the integration. See [specification.md](specification.md)
  §11.5.

> **Note:** `require("gitloom").setup(opts)` currently stores config but does
> not yet forward it to `:GitloomGraph` — the command uses the defaults above.
> Wiring `setup()` config through to the graph is a known gap (see
> [specification.md](specification.md) §Configuration).

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
