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
| `K` | Float with the full lane breakdown for the commit under the cursor (debug) |
| `i` | Toggle the per-lane id column shown before the message (debug) |

## Configuration

The graph view accepts an options table (`GraphOptions`). Defaults:

```lua
{
    win = {
        border = "rounded",
        width = 0.80,
        height = 0.80,
        title = "GraphView",
        footer = "Press 'q' to quit",
    },
    palette = {
        date = "Title",
        author = "Comment",
        branch = "WarningMsg",
        message = nil,
        tags = "Comment",
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
}
```

- **`win`** — floating window geometry (forwarded to snacks.win). Fractional
  `width`/`height` are a share of the editor.
- **`palette`** — highlight groups per field. `tracks` is a list cycled by
  lane id to color each lane.
- **`merge_style`** — controls whether merges/splits get their own virtual
  line above/below the commit, or are folded onto the commit line.
- **`branches`** — the ref arguments passed to `git log` (default `--all`).

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
