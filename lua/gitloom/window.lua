--- gitloom.window — the graph window controller.
---
--- Owns everything Neovim-coupled: the floating window, keymaps, autocmds, the
--- streaming/resync, the reachability debounce, the context panes, the commit
--- view and the external-diff glue. It drives the pure engine (gitloom.graph)
--- and data library (gitloom.git); init.lua wires `:GitloomGraph` to M.open.
local M = {}

local submodule = require("gitloom.submodule")
local util = require("gitloom.util")
local git = require("gitloom.git")
local graph = require("gitloom.graph")
local selectm = require("gitloom.graph.select")
local reach = require("gitloom.graph.reach")
local render = require("gitloom.graph.render")

-- Layout orchestration lives in the engine (gitloom.graph); the controller drives it.
local build_graph = graph.build_graph
local refresh_columns = graph.refresh_columns
local pack_markers = graph.pack_markers
local owners_from_refs = graph.owners_from_refs

-- Max commits drawn in a submodule change graph before capping (spec §11.7.3);
-- the rest collapse into a "+K more" note.
local SUBMODULE_MAX = 12

-- merge_style presets the viewer cycles through with `m` (see M.open). Each
-- toggles whether merges/splits get their own virtual line, or are folded
-- onto the commit line (inline), plus the experimental allow_merge_on_split.
local MERGE_STYLES = {
    { name = "split on its own line",   style = { allow_merge_on_split = false, merge_on_separate_line = false, split_on_separate_line = true } },
    { name = "merge on its own line",   style = { allow_merge_on_split = false, merge_on_separate_line = true,  split_on_separate_line = false } },
    { name = "merge + split lines",     style = { allow_merge_on_split = false, merge_on_separate_line = true,  split_on_separate_line = true } },
    { name = "inline",                  style = { allow_merge_on_split = false, merge_on_separate_line = false, split_on_separate_line = false } },
    { name = "inline (merge on split)", style = { allow_merge_on_split = true,  merge_on_separate_line = false, split_on_separate_line = false } },
}
local merge_style_index = 1
-- Active row sort mode (index into SORT_MODES, defined below; spec §3.1), cycled
-- by `S`. 1 = topo (the default; order_commits, reproducing git's --topo-order).
local sort_mode_index = 1

-- Ref label placements the viewer cycles through with `B` (spec §6.1). `right`
-- pins refs to the right edge (default); `inline` draws them left-aligned before
-- the message on the commit line; `dual` moves them onto their own line above the
-- message. opts.label_mode is the source of truth; this index drives the cycle
-- and the footer label.
local LABEL_MODES = {
    { name = "refs right",        mode = "right" },
    { name = "refs inline",       mode = "inline" },
    { name = "refs on own line",  mode = "dual" },
}
local label_mode_index = 1


-- Remembered cursor position per repository, keyed by Neovim's cwd (which is the
-- repo the graph reflects — git runs in cwd). The value is the hash of the commit
-- under the cursor when the window last closed, so reopening the graph restores
-- the cursor to the same commit instead of re-focusing HEAD (spec §2). In-memory
-- for the Neovim session; not persisted to disk.
local saved_positions = {}

-- Per-repository session MRU for the ref picker (`<leader>b`, §2): the ref names
-- jumped to this session, newest first, keyed by Neovim's cwd (the repo, like
-- saved_positions). Surfaced at the top of the picker. In-memory for the session.
local recent_refs = {}

-- Index of the flex (message) column in a row's `line` field: date, author,
-- graph, message. The message fills the remaining width and refs are pinned to
-- the right edge of the row (specification.md §6; see listview's build_line).
local FLEX_COL = 4
-- The author column (index 2). It is given a sticky cap so it only grows up to
-- a max width and doesn't bounce as different-length names scroll past.
local AUTHOR_COL, AUTHOR_MAX = 2, 25
-- The graph column (index 3). Under mirroring it is sticky (only grows) so the
-- right-aligned graph + message don't shift as the lane width changes.
local GRAPH_COL = 3

-- Floating-window stacking order. Neovim's default float zindex is 50, which is
-- what the snacks graph window and the modal commit view get. The overlays must
-- layer above their own parent, and the modal commit view + the `?` help must
-- sit above the graph's context panes (otherwise the footer pokes through the
-- commit view and the help hides behind the panes). Larger = closer to the user.
--   graph window / commit view base ........ 50  (snacks default)
--   header/footer panes (overlay graph) .... 60
--   commit view (modal, over the graph) .... 100
--   commit view sticky overlay (over it) ... 110
--   `?` help float (topmost) ............... 300
local ZINDEX = {
    panes = 60,
    commit_view = 100,
    commit_ctx = 110,
    help = 300,
}

-- Graph window keybindings — the single source of truth for the `?` help
-- float. Handlers are registered in M.open.
local KEYBINDS = {
    { "q", "Close the graph" },
    { "m", "Cycle the merge/split rendering style" },
    { "M", "Toggle mirroring (lane 1 on the right)" },
    { "B", "Cycle ref label placement (right / inline / own line)" },
    { "<Tab>", "Collapse / expand the branch under the cursor (toggle)" },
    { "<CR>", "Action menu for the row (examine · diff · collapse/expand/hide)" },
    { "D", "Open the commit's diff (external viewer)" },
    { "d", "Toggle absolute / relative dates" },
    { "h/l", "Select previous / next ref (switch branch while selecting)" },
    { "V", "Commit selection: range along a branch (j/k walk · h/l switch · o swap · <CR>/D diff · Esc exit)" },
    { "H", "Toggle reachability highlighting (dimming)" },
    { "c", "Toggle first-parent focus (collapse non-mainline branches)" },
    { "P", "Pin / unpin the branch under the cursor as an anchor" },
    { "p", "Toggle marker packing (concurrent collapsed heads share a line)" },
    { "R", "Resync with the repository (refs + new commits + working tree)" },
    { "S", "Cycle the row sort mode (topo / date / author-date)" },
    { "<leader>b", "Jump to a branch / ref (picker; recent first)" },
    { "F", "Toggle the off-screen context panes (header + footer)" },
    { "K", "Lane breakdown for the commit under the cursor" },
    { "i", "Toggle lane-id debug + the cutoff/seam highlight" },
    { "?", "Show this help" },
}

-- The graph window footer: live status (the current mode, and whether the graph
-- is mirrored) plus a hint to the help float.
---@param mirror boolean?
---@param modes table<string, string>?  -- explicit branch-mode overrides (§10)
---@param focus boolean?  -- the first-parent focus default is on (§10.7)
---@param sort_label string?  -- the active sort mode's label (§3.1)
local function footer_text(mirror, modes, focus, nanchors, sort_label)
    local status = ("Mode: %s | Refs: %s"):format(
        MERGE_STYLES[merge_style_index].name, LABEL_MODES[label_mode_index].name)
    if sort_label then
        status = status .. " | Sort: " .. sort_label
    end
    if focus then
        status = status .. " | focus"
        -- More than the single default anchor (HEAD) ⇒ note the anchor count.
        if nanchors and nanchors > 1 then status = status .. (" (%d anchors)"):format(nanchors) end
    end
    local nc, nh = 0, 0
    for _, m in pairs(modes or {}) do
        if m == "collapsed" then nc = nc + 1 elseif m == "hidden" then nh = nh + 1 end
    end
    if nc > 0 or nh > 0 then
        status = status .. (" (%d collapsed, %d hidden)"):format(nc, nh)
    end
    if mirror then status = status .. "  (mirrored)" end
    return status .. "    ?: help"
end

-- Lines for the `?` help float.
local function help_lines()
    local lines = { "gitloom keys", "" }
    for _, kb in ipairs(KEYBINDS) do
        lines[#lines + 1] = ("  %-2s  %s"):format(kb[1], kb[2])
    end
    return lines
end

-- gitloom's own minimal promise (vendored in util.lua; see CLAUDE.md
-- "Relationship to loomworks"). Future type is declared there.
local make_future = util.make_future

-- Vendored single-fragment highlight builder (util.lua), sibling of compose.
local highlight_text = util.highlight_text

-- Phase 2 rendering (glyphs, colour, rows; §5, §6, §12) now lives in
-- gitloom.graph.render. graph.lua aliases the entry points the controller drives.
local reset_dim_cache = render.reset_dim_cache
local reset_gen_cache = render.reset_gen_cache
local DIM_FALLBACK = render.DIM_FALLBACK  -- the flat dim fallback group (submodule_block)


-- Ref classification / grouping / picker model + resync diff (§2, §3.4, §6)
-- now live in gitloom.git.refs.
local classify_ref = git.classify_ref

-- The commit-graph model (Commit/Ref types + the placeholder constructors) now
-- lives in gitloom.git.model.
local get_or_create_commit = git.get_or_create_commit
local add_ref = git.add_ref

-- git I/O (refs / stream / resync / worktree / commit-view / submodule) now
-- lives in gitloom.git.fetch. graph.lua aliases the functions it drives.
local fetch_refs = git.fetch_refs
local fetch_head = git.fetch_head
local fetch_ref_entries = git.fetch_ref_entries

-- Commit timestamp parse + formatting (§4, §6) now live in gitloom.git.date.
local parse_timestamp = git.parse_timestamp
local format_absolute = git.format_absolute
local format_relative = git.format_relative
local format_date = git.format_date

local group_refs = git.group_refs
local bump_recent = git.bump_recent
local ref_picker_items = git.ref_picker_items

-- Ref decoration rendering (§6, §10.4) lives in gitloom.graph.render.
local decoration_texts = render.decoration_texts
local pane_labels = render.pane_labels
local marker_units = render.marker_units

-- Selection & branch-mode interaction helpers (§2, §10.1, §13) now live in
-- gitloom.graph.select. graph.lua aliases them.
local next_mode = selectm.next_mode
local selected_owner_ids = selectm.selected_owner_ids
local move_selection = selectm.move_selection
local sel_ascend_children = selectm.sel_ascend_children
local sel_step = selectm.sel_step
local sel_switch = selectm.sel_switch
local ref_byte_col = selectm.ref_byte_col

local ref_decoration_index = git.ref_decoration_index

-- git output parsers now live in gitloom.git.parse (the commit-line + diff +
-- status parsers; §3, §11). graph.lua aliases them.
local parse_commit_line = git.parse_commit_line
local make_line_buffer = git.make_line_buffer

-- Row ordering (gitloom owning the order, §3.1) now lives in gitloom.git.order.
local order_commits = git.order_commits

local diff_ref_tips = git.diff_ref_tips
local reachable_hashes = git.reachable_hashes

local fetch_commits = git.fetch_commits

local fetch_new_commits = git.fetch_new_commits

--- The row sort modes (spec §3.1), cycled by `S`. The order gitloom renders is
--- owned, but each mode sources its *sequence* differently: a mode with `fn`
--- sorts the in-memory DAG in Lua; a mode with `rev` asks git for the exact
--- sequence (`git rev-list <rev>`). `topo` (the default) is `order_commits`,
--- which reproduces git's `--topo-order` itself; `date` / `author` are git's
--- date-interleaved orders.
local SORT_MODES = {
    { id = "topo", label = "topo", fn = true },
    { id = "date", label = "date", rev = "--date-order" },
    { id = "author", label = "author-date", rev = "--author-date-order" },
}

local fetch_rev_order = git.fetch_rev_order

-- Reachability emphasis (§12) and the OrderItem line accessor now live in
-- gitloom.graph.reach. graph.lua aliases them.
local item_lines = reach.item_lines


-- Engine data-model types (Connectivity / Lane / Segment / GraphColumn /
-- OrderItem / SelectionState) and the layout orchestration (build_graph,
-- refresh_columns, pack_markers, owners_from_refs) live in gitloom.graph.
local collapse_owners = selectm.collapse_owners

-- Vendored highlight-composition helper (util.lua). listview.lua keeps its own
-- private copy so it stays standalone — do not dedupe across that boundary.
local compose = util.compose

-- Segment colour + column glyph rendering (§5, §12) live in gitloom.graph.render.
local top_lane = render.top_lane
local passthrough_columns = render.passthrough_columns
local get_column_chars = render.get_column_chars


local reachable_cone = reach.reachable_cone
local mark_reachable = reach.mark_reachable


-- Row rendering (DisplayElement) lives in gitloom.graph.render.
local dual_two_line = render.dual_two_line
local display_item = render.display_item
local format_lane_info = render.format_lane_info

-- git data presentation formatters (commit detail / diff / diffstat / range /
-- worktree, §11, §13.5) now live in gitloom.git.format. graph.lua aliases them.
local worktree_label = git.worktree_label
-- CommitDetail / parse_show (the commit view's git-show parser, §11) now live
-- in gitloom.git.parse.
local parse_show = git.parse_show

local format_commit_detail = git.format_commit_detail

local format_range_detail = git.format_range_detail
local format_worktree_detail = git.format_worktree_detail

local format_diff = git.format_diff

local diffstat_files = git.diffstat_files

local diff_contexts = git.diff_contexts

local format_diffstat = git.format_diffstat

-- Reserved sentinel hashes for the working-tree virtual commits (§4.2): values
-- git never produces for a real object, so every hash-keyed path keeps working.
local WORKTREE_UNSTAGED_HASH = "0000000000000000000000000000000000000000"
local WORKTREE_STAGED_HASH = "0000000000000000000000000000000000000001"
local WORKTREE_UNTRACKED_HASH = "0000000000000000000000000000000000000002"

-- Working-tree I/O (state + diffs, §3.3) now lives in gitloom.git.fetch.
local fetch_worktree_state = git.fetch_worktree_state
local fetch_worktree_diff = git.fetch_worktree_diff

-- The `git status --porcelain` counter (§3.3) lives in gitloom.git.parse; kept
-- aliased for the graph._internal test seam.
local parse_status = git.parse_status

-- DiffRange builders (§11.5, §13.5) now live in gitloom.git.range.
local commit_range = git.commit_range
local range_endpoints = git.range_endpoints

--- Default diff provider: open diffview for the range (specification.md §11.5).
--- Guarded — reports rather than errors when diffview is not installed. Override
--- opts.diff.open to use another plugin.
---@param range DiffRange
local function open_diffview(range)
    -- diffview is usually lazy-loaded, so `:DiffviewOpen` does not exist until
    -- the plugin is loaded; require it first (a no-op if already loaded) to
    -- trigger the load, then run the command.
    pcall(require, "diffview")
    if vim.fn.exists(":DiffviewOpen") == 0 then
        vim.notify("diffview.nvim not found; set diff.open to use another diff plugin",
            vim.log.levels.ERROR)
        return
    end
    vim.cmd("DiffviewOpen " .. range.rev)
end

--- Open the configured external diff (§11.5) for a commit: build its DiffRange
--- and hand it to the provider. No-op when no provider is configured.
---@param opts GraphOptions
---@param commit Commit
local function open_diff(opts, commit)
    local open = opts.diff and opts.diff.open
    if open then
        open(commit_range(commit))
    end
end

-- On-demand commit-view I/O (detail / diff / range patch; §11, §13.5) now lives
-- in gitloom.git.fetch.
local fetch_commit_detail = git.fetch_commit_detail
local fetch_commit_diff = git.fetch_commit_diff
local fetch_range_diff = git.fetch_range_diff

-- Submodule change-graph I/O (§11.7) now lives in gitloom.git.fetch; the
-- submodule_block renderer below stays (it composes commit-view rows).
local fetch_submodule_graph = git.fetch_submodule_graph

--- Render one submodule change's fetched `result` (spec §11.7) into commit-view
--- rows (compose-style `{ text, highlight }`), replacing the raw `Subproject
--- commit` pair. `result` may be nil (not yet fetched) — then the raw hashes are
--- shown, upgraded in place once the fetch resolves (§11.7.4).
---@param opts GraphOptions
---@param change { path: string, old: string, new: string }
---@param result table?
---@return table[]
local function submodule_block(opts, change, result)
    local palette = opts.palette or {}
    local diffp = palette.diff or {}
    local rows = {}
    local function short(h) return (h or ""):sub(1, 8) end

    -- Gate failed or not yet fetched: the raw hashes, with a dim reason (§11.7.1).
    if not result or not result.available then
        rows[#rows + 1] = compose({
            highlight_text("  submodule ", palette.author),
            highlight_text(change.path, diffp.header),
            highlight_text(("  %s → %s"):format(short(change.old), short(change.new)), palette.date),
        })
        if result and result.reason then
            rows[#rows + 1] = highlight_text("  (" .. result.reason .. ")", DIM_FALLBACK)
        end
        return rows
    end

    -- Header: path, old → new, and the direction/counts.
    local dir
    if result.class == "ff" then
        dir = ("+%d"):format(result.ahead)
    elseif result.class == "rewind" then
        dir = ("−%d"):format(result.behind)
    else
        dir = ("diverged +%d / −%d"):format(result.ahead, result.behind)
    end
    rows[#rows + 1] = compose({
        highlight_text("  submodule ", palette.author),
        highlight_text(change.path, diffp.header),
        highlight_text(("  %s → %s  "):format(short(change.old), short(change.new)), palette.date),
        highlight_text("(" .. dir .. ")", palette.branch),
    })

    if result.class == "diverged" then
        local function endpoint(label, c, hl)
            rows[#rows + 1] = compose({
                highlight_text("    " .. label .. " ", hl),
                highlight_text(c and short(c.hash) or "", palette.date),
                highlight_text(c and c.message and ("  " .. c.message) or "", palette.message),
            })
        end
        endpoint("new ", result.new_commit, palette.branch)
        endpoint("base", result.base_commit, palette.author)
        endpoint("old ", result.old_commit, palette.remote)
        return rows
    end

    -- ff / rewind: lay the first-parent commits out (the same Phase 1 the main
    -- graph uses) and draw the glyph gutter. The commits are newest-first with the
    -- fork-point anchor last; when there are too many, keep the newest
    -- SUBMODULE_MAX-1 plus the anchor (pane.cap keeps the last row) and note the
    -- commits elided between (§11.7.3).
    local pane = require("gitloom.graph.pane")
    local laid = build_graph(opts, result.items or {})
    local shown = pane.cap(laid, SUBMODULE_MAX)
    local dropped = #laid - #shown
    -- The pointer tag for a row: "new"/"old" when it is the new/old pointer (§11.7.3).
    local function ptr_tag(hash)
        if hash == change.new then return "new" end
        if hash == change.old then return "old" end
        return nil
    end
    for i, item in ipairs(shown) do
        -- The elision falls between the newest kept rows and the anchor (last).
        if dropped > 0 and i == #shown then
            rows[#rows + 1] = highlight_text(("    … +%d more"):format(dropped), DIM_FALLBACK)
        end
        local c = item.commit
        if c then
            local segs = {
                highlight_text("    ", nil),
                get_column_chars(opts, item.columns, false),
                highlight_text("  " .. short(c.hash), palette.date),
            }
            local tag = ptr_tag(c.hash)
            if tag then segs[#segs + 1] = highlight_text(" ◀ " .. tag, palette.head) end
            if c.deco and c.deco ~= "" then segs[#segs + 1] = highlight_text(" " .. c.deco, palette.branch) end
            if c.message and c.message ~= "" then segs[#segs + 1] = highlight_text("  " .. c.message, palette.message) end
            rows[#rows + 1] = compose(segs)
        end
    end
    return rows
end

local commit_view_ns = vim.api.nvim_create_namespace("gitloom.commit_view")

--- Open the commit view (specification.md §11) for `commit`: a read-only snacks
--- float that fetches the commit's detail + diff on demand and renders the
--- metadata, the diffstat, and the diff. `q` closes it (snacks default); `<CR>`
--- on a diffstat file line jumps to that file's diff section (§11.4). The pure
--- pieces (parse_show / format_commit_detail / format_diff / diffstat_files /
--- format_diffstat) do the work; this is just window + IO glue.
--- When `range` is given (the commit-selection range mode, spec §13.5) the view
--- shows the selected commit list + the combined range diff instead of a single
--- commit's detail; `commit` is then nil. `range` is
--- `{ range = DiffRange, commits = Commit[], title = string }`.
---@param opts GraphOptions
---@param commit Commit?
---@param range? { range: DiffRange, commits: Commit[], title: string }
local function open_commit_view(opts, commit, range)
    local ok, snacks = pcall(require, "snacks.win")
    if not ok then
        vim.notify("snacks.win not found. Install snacks.nvim", vim.log.levels.ERROR)
        return
    end

    local title
    if range then
        title = range.title
    else
        ---@cast commit Commit
        title = "Commit " .. commit.hash:sub(1, 7)
    end

    -- Match the graph window's geometry so the commit view is the same size.
    local w = snacks.new({
        border = opts.win.border or "rounded",
        width = opts.win.width,
        height = opts.win.height,
        title = title,
        footer = "q: close",
        keys = { q = "close" },
        -- Above the graph window's header/footer panes so they don't poke
        -- through this modal view.
        zindex = ZINDEX.commit_view,
    })
    local buf = w.buf

    -- Window-local scrolloff (opts.scrolloff, default 10; §8): keep context rows
    -- around the cursor when paging through a long diff.
    if w.win and vim.api.nvim_win_is_valid(w.win) then
        pcall(vim.api.nvim_set_option_value, "scrolloff", opts.scrolloff or 0,
            { scope = "local", win = w.win })
    end

    -- Maps a diffstat file row's buffer line -> the buffer line where that
    -- file's diff section begins. Rebuilt on each render; <CR> jumps by it.
    local file_jumps = {}
    -- Buffer line of the diff action label (§11.5), or nil. <CR> there opens the
    -- external diff; the cursor parks here when the view opens.
    local action_line = nil

    -- Diff context-header state (§11.6), set by render(): the per-patch-line
    -- governing file/hunk (diff_contexts) and the buffer line where the patch
    -- begins, so a buffer line L maps to patch index L - diff_start + 1.
    local diff_ctx, diff_start = nil, nil
    -- Buffer line -> patch line index, set by render() only when a submodule
    -- block (§11.7) was spliced in (which breaks the 1:1 patch↔buffer mapping
    -- the line `L - diff_start + 1` assumes); nil otherwise, so the common
    -- no-submodule path is unchanged.
    local diff_buf_to_patch = nil
    -- Submodule change view (§11.7): the fetched result per submodule path,
    -- filled asynchronously after the first render and triggering an in-place
    -- re-render. Read by render() when it splices each change block.
    local sub_results = {}

    local function set_lines(lines)
        if not vim.api.nvim_buf_is_valid(buf) then return end
        vim.bo[buf].modifiable = true
        vim.bo[buf].readonly = false
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modifiable = false
        vim.bo[buf].readonly = true
    end

    -- <CR> dispatches by cursor line: on the action label it opens the external
    -- diff (§11.5); on a diffstat file line it jumps to that file's diff section
    -- (§11.4), scrolling it to the top; elsewhere it does nothing. The jump uses
    -- the `G` motion (a jump command) so the diffstat position lands in the
    -- jumplist — `<C-o>` / `<C-i>` then move back and forth between the diffstat
    -- and the file's diff.
    vim.keymap.set("n", "<CR>", function()
        if not vim.api.nvim_win_is_valid(w.win) then return end
        local line = vim.api.nvim_win_get_cursor(w.win)[1]
        if action_line and line == action_line then
            if range then
                if opts.diff and opts.diff.open then opts.diff.open(range.range) end
            else
                ---@cast commit Commit
                open_diff(opts, commit)
            end
            return
        end
        local target = file_jumps[line]
        if target then
            vim.api.nvim_win_call(w.win, function()
                vim.cmd("normal! " .. target .. "Gzt")
            end)
        end
    end, { buffer = buf, nowait = true, silent = true })

    -- <C-o> walks the jumplist back through the view's own jumps (diffstat <->
    -- diff). Once the next jump-back would leave the commit view — its target is
    -- another buffer (the graph), or there is none — close the view instead of
    -- jumping out of it (§11.4). getjumplist's curidx is the 1-based index of
    -- the entry <C-o> would visit (0 = nothing to go back to).
    vim.keymap.set("n", "<C-o>", function()
        local jl = vim.fn.getjumplist()
        local list, curidx = jl[1], jl[2]
        local target = (curidx >= 1) and list[curidx] or nil
        if target and target.bufnr == buf then
            vim.api.nvim_feedkeys(
                vim.api.nvim_replace_termcodes("<C-o>", true, false, true), "n", false)
        else
            w:close()
        end
    end, { buffer = buf, nowait = true, silent = true })

    -- Diff context header (§11.6): a borderless overlay pinned to the top of the
    -- view showing the governing file / hunk while the diff is scrolled past
    -- their real header lines. It tracks the viewport top, not the cursor, and
    -- materializes only when there is something to stick (else it is closed).
    local diff_pal = (opts.palette or {}).diff or {}
    local ctx_win, ctx_buf = nil, nil
    -- The commit-view window id, captured stably at open. snacks clears `w.win`
    -- to nil on close, and its own WinClosed cleanup can run before ours, so
    -- matching the close event against the live `w.win` may miss and orphan the
    -- overlay float. The captured id stays valid for the match (and goes invalid
    -- once the window is gone), so the teardown below always fires.
    local view_win = w.win

    local function close_ctx()
        if ctx_win and vim.api.nvim_win_is_valid(ctx_win) then
            pcall(vim.api.nvim_win_close, ctx_win, true)
        end
        ctx_win = nil
    end

    -- The context rows governing an effective viewport top (a buffer line): the
    -- file line when its `diff --git` has scrolled strictly above it, then the
    -- hunk line when its `@@` has — each omitted while its real header is still
    -- visible below the overlay (§11.6).
    local function ctx_rows_for(eff_top)
        if not diff_ctx then return {} end
        -- Buffer line -> patch index: the spliced map when a submodule block
        -- shifted lines (§11.7), else the plain 1:1 offset from diff_start.
        local pidx = diff_buf_to_patch and diff_buf_to_patch[eff_top]
            or (eff_top - diff_start + 1)
        local c = diff_ctx[pidx]
        if not c then return {} end
        local rows = {}
        if c.file and c.file_line < eff_top then
            rows[#rows + 1] = highlight_text(c.file, diff_pal.header)
        end
        if c.hunk and c.hunk_line < eff_top then
            rows[#rows + 1] = highlight_text(c.hunk, diff_pal.hunk)
        end
        return rows
    end

    local function update_ctx()
        if not (diff_ctx and vim.api.nvim_win_is_valid(w.win)) then
            close_ctx()
            return
        end
        -- The overlay covers the top `#rows` rows, so the first row the user
        -- actually reads is the window top advanced past it (§11.6). That offset
        -- depends on the count we are computing, so settle it with a short
        -- fixpoint (the height is 0–2; this converges in a step or two).
        local top = vim.fn.line("w0", w.win)
        local rows = ctx_rows_for(top)
        for _ = 1, 2 do
            local next_rows = ctx_rows_for(top + #rows)
            if #next_rows == #rows then
                rows = next_rows
                break
            end
            rows = next_rows
        end

        if #rows == 0 then
            close_ctx()
            return
        end

        if not (ctx_buf and vim.api.nvim_buf_is_valid(ctx_buf)) then
            ctx_buf = vim.api.nvim_create_buf(false, true)
        end
        local cfg = {
            relative = "win", win = w.win,
            row = 0, col = 0,
            width = vim.api.nvim_win_get_width(w.win),
            height = #rows,
            style = "minimal",
            focusable = false,
            -- Above the commit view itself (its sticky-scroll header).
            zindex = ZINDEX.commit_ctx,
        }
        if ctx_win and vim.api.nvim_win_is_valid(ctx_win) then
            pcall(vim.api.nvim_win_set_config, ctx_win, cfg)
        else
            ctx_win = vim.api.nvim_open_win(ctx_buf, false, cfg)
            pcall(vim.api.nvim_set_option_value, "winhl",
                "Normal:NormalFloat,NormalFloat:NormalFloat", { win = ctx_win })
        end

        vim.bo[ctx_buf].modifiable = true
        local lines = {}
        for _, r in ipairs(rows) do
            lines[#lines + 1] = r.text
        end
        vim.api.nvim_buf_set_lines(ctx_buf, 0, -1, false, lines)
        vim.bo[ctx_buf].modifiable = false
        vim.api.nvim_buf_clear_namespace(ctx_buf, commit_view_ns, 0, -1)
        for i, r in ipairs(rows) do
            for _, hl in ipairs(r.highlight or {}) do
                if hl.hl then
                    vim.api.nvim_buf_set_extmark(ctx_buf, commit_view_ns, i - 1, hl.start_pos, {
                        end_col = hl.end_pos,
                        hl_group = hl.hl,
                    })
                end
            end
        end
    end

    local ctx_group = vim.api.nvim_create_augroup("GitloomCommitCtx_" .. buf, { clear = true })
    vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized" }, {
        group = ctx_group,
        callback = function()
            -- This autocmd is global (it must catch scrolls in the commit view),
            -- so once that window has closed a later scroll in any other window
            -- would call nvim_win_is_valid(nil) and error. Guard on the captured
            -- id; when the window is gone, close the overlay (in case WinClosed
            -- missed it) and tear the group down.
            if view_win and vim.api.nvim_win_is_valid(view_win) then
                update_ctx()
            else
                close_ctx()
                pcall(vim.api.nvim_del_augroup_by_id, ctx_group)
            end
        end,
    })
    vim.api.nvim_create_autocmd("WinClosed", {
        group = ctx_group,
        callback = function(ev)
            -- Match the captured id, not the live `w.win` (which snacks may have
            -- already cleared), so closing the view always closes the overlay.
            if view_win and tonumber(ev.match) == view_win then
                close_ctx()
                pcall(vim.api.nvim_del_augroup_by_id, ctx_group)
            end
        end,
    })

    set_lines({ "Loading…" })

    -- Render the metadata (format_commit_detail), then the diffstat
    -- (format_diffstat), then the diff (format_diff) into one buffer: real lines
    -- + namespaced extmarks (the diff is highlighted this way, not via
    -- filetype=diff, so the metadata header stays clean §11.3). While laying out
    -- the rows, record each diffstat file row -> its diff section line (§11.4).
    local function render(meta_output, diff_output, keep_view)
        if not vim.api.nvim_buf_is_valid(buf) then return end
        -- On an in-place re-render (the submodule upgrade, §11.7.4) preserve the
        -- user's scroll/cursor; the first render parks on the action label.
        local saved_view = keep_view and vim.api.nvim_win_is_valid(w.win)
            and vim.api.nvim_win_call(w.win, vim.fn.winsaveview) or nil
        file_jumps = {}
        action_line = nil
        diff_ctx, diff_start = nil, nil
        diff_buf_to_patch = nil

        local rows = {}
        -- Diff action label as the first line (§11.5), when a provider is set.
        if opts.diff and opts.diff.open then
            rows[#rows + 1] = highlight_text(opts.diff.label or "▶ Open diff", opts.palette.action)
            action_line = #rows
            rows[#rows + 1] = highlight_text("")
        end
        -- Metadata: the selected-commit list in range mode (§13.5), else the
        -- single commit's detail.
        local meta_rows
        if range then
            meta_rows = format_range_detail(range.commits, opts.palette)
        elseif commit and commit.virtual then
            -- Working-tree commit view (§11.8): a short state header, not git show.
            meta_rows = format_worktree_detail(commit, opts.palette)
        else
            ---@cast commit Commit
            meta_rows = format_commit_detail(parse_show(meta_output), {
                decorations = decoration_texts(commit),
                palette = opts.palette,
            })
        end
        for _, r in ipairs(meta_rows) do
            rows[#rows + 1] = r
        end

        -- `git show --format=` prints a leading blank line; drop it.
        local patch = (diff_output or ""):gsub("^%s+", "")
        if patch ~= "" then
            local files = diffstat_files(patch)
            rows[#rows + 1] = highlight_text("")
            local stat_start = #rows + 1 -- buffer line of the diffstat summary row
            for _, r in ipairs(format_diffstat(files, opts.palette)) do
                rows[#rows + 1] = r
            end
            rows[#rows + 1] = highlight_text("")
            diff_start = #rows + 1 -- buffer line of the first patch line

            -- Submodule change blocks (§11.7): replace each `Subproject commit`
            -- pair with its change graph. Splicing shifts buffer lines, so build
            -- patch<->buffer maps for the file-jump and context-header lookups
            -- rather than the plain 1:1 offset (which holds only with no splice).
            local diff_rows = format_diff(patch, opts.palette)
            local repl = {} -- from_line -> { to_line, rows }
            for _, ch in ipairs(submodule.parse_changes(patch)) do
                repl[ch.from_line] = {
                    to_line = ch.to_line,
                    rows = submodule_block(opts, ch, sub_results[ch.path]),
                }
            end
            local patch_to_buf, buf_to_patch = {}, {}
            local pi = 1
            while pi <= #diff_rows do
                local r = repl[pi]
                if r then
                    local at = #rows + 1 -- buffer line of the block's first row
                    for _, br in ipairs(r.rows) do
                        rows[#rows + 1] = br
                        buf_to_patch[#rows] = pi -- block lines govern by the file's region
                    end
                    for k = pi, r.to_line do patch_to_buf[k] = at end
                    pi = r.to_line + 1
                else
                    rows[#rows + 1] = diff_rows[pi]
                    patch_to_buf[pi], buf_to_patch[#rows] = #rows, pi
                    pi = pi + 1
                end
            end

            -- Summary sits at stat_start; file j at stat_start + j. Its diff
            -- section starts where its `diff --git` line landed (identity when
            -- nothing was spliced).
            for j, f in ipairs(files) do
                file_jumps[stat_start + j] = patch_to_buf[f.start] or (diff_start + f.start - 1)
            end
            -- Context-header lookup over the same patch (§11.6); when a block was
            -- spliced the buffer is no longer 1:1 with the patch, so hand
            -- ctx_rows_for the inverse map.
            diff_ctx = diff_contexts(patch)
            if next(repl) then diff_buf_to_patch = buf_to_patch end
        end

        local lines = {}
        for _, r in ipairs(rows) do
            lines[#lines + 1] = r.text
        end
        set_lines(lines)
        vim.api.nvim_buf_clear_namespace(buf, commit_view_ns, 0, -1)
        for i, r in ipairs(rows) do
            for _, hl in ipairs(r.highlight or {}) do
                if hl.hl then
                    vim.api.nvim_buf_set_extmark(buf, commit_view_ns, i - 1, hl.start_pos, {
                        end_col = hl.end_pos,
                        hl_group = hl.hl,
                    })
                end
            end
        end

        if saved_view then
            -- In-place re-render: keep the user where they were (§11.7.4).
            pcall(vim.api.nvim_win_call, w.win, function() vim.fn.winrestview(saved_view) end)
        elseif action_line and vim.api.nvim_win_is_valid(w.win) then
            -- Park the cursor on the action label so <CR><CR> opens the diff (§11.2).
            pcall(vim.api.nvim_win_set_cursor, w.win, { action_line, 0 })
        end

        -- Seed the context header for the initial viewport (§11.6).
        update_ctx()
    end

    -- Fetch the diff (plus metadata in single-commit mode); render once it
    -- arrives (§11.1). Range mode (§13.5) needs no metadata fetch — the commit
    -- list is supplied — so it fetches only the combined range diff.
    local fetched
    if range then
        fetched = fetch_range_diff(range.range).next(function(diff_output)
            return { meta = nil, diff = diff_output }
        end)
    elseif commit and commit.virtual then
        -- Working-tree commit view (§11.8): the node's own diff (staged = index
        -- vs HEAD; unstaged = tracked working tree vs index; untracked = the
        -- synthesized untracked additions). No git-show metadata — the header is
        -- synthesized (format_worktree_detail).
        fetched = fetch_worktree_diff(commit.virtual).next(function(diff_output)
            return { meta = nil, diff = diff_output }
        end)
    else
        ---@cast commit Commit
        fetched = fetch_commit_detail(commit.hash).next(function(meta_output)
            return fetch_commit_diff(commit.hash).next(function(diff_output)
                return { meta = meta_output, diff = diff_output }
            end)
        end)
    end
    fetched.next(function(res)
        render(res.meta, res.diff)
        -- Submodule change graphs (§11.7): fetch each asynchronously (gated,
        -- never fetching) and re-render in place as they resolve, so a slow or
        -- large submodule never blocks the diff.
        local patch = (res.diff or ""):gsub("^%s+", "")
        for _, ch in ipairs(submodule.parse_changes(patch)) do
            fetch_submodule_graph(opts, ch).next(function(result)
                sub_results[ch.path] = result
                render(res.meta, res.diff, true)
            end)
        end
    end)
end

---@class GraphWinOptions
---@field border string
---@field width number|fun():number   fraction (0–1), absolute (>1), or a function
---@field height number|fun():number
---@field title string
---@field footer string
---@field keys? table  keymaps installed on the graph window (snacks.win keys)

---@class GraphPalette
---@field date? string
---@field author? string
---@field branch? string
---@field remote? string
---@field head? string
---@field message? string
---@field tags? string
---@field selected? string  the h/l-selected ref decoration (§2)
---@field action? string  the commit-view diff action label (§11.5)
---@field diff? { add?: string, delete?: string, hunk?: string, header?: string }  commit-view diff colors (§11.3)
---@field dim? number  blend factor toward bg for out-of-cone rows/lanes (§12)
---@field tracks? string[]  curated lane colours, the free-list seed (§5.5)
---@field buffer? integer  min free-list length: colours drawn before one repeats (§5.5)
---@field generate? boolean  generate overflow OKLCH colours when truecolor (§5.5)
---@field anchor? { L?: number, C?: number, base_hue?: number }  generated-colour anchor (§5.5)

---@class MergeStyle
---@field allow_merge_on_split boolean
---@field merge_on_separate_line boolean
---@field split_on_separate_line boolean

---@class Icons
---@field merge? string

---@class GraphOptions
---@field win GraphWinOptions
---@field palette GraphPalette
-----@field merge_style "compact"|"normal"|"merge"
---@field merge_style MergeStyle
---@field branches? string|string[]
---@field sort_mode? string  initial row sort mode id (§3.1): "topo" | "date" | "author"
---@field icons Icons
---@field mirror? boolean  render the graph mirrored (lane 1 on the right); §5.4
---@field highlight? boolean  reachability dimming on/off (default true); §12
---@field collapse_merged? boolean  first-parent focus on/off (default true); §10.7
---@field pack_markers? boolean  marker packing on/off (default true); §10.4
---@field panes? boolean  context panes (header/footer) on/off (default on); §6.2
---@field junction_markers? boolean  draw kept junctions node-less (default true); §10.4
---@field date_format? string  os.date format for absolute dates; §6
---@field date_mode? "absolute"|"relative"  initial date rendering; §6
---@field message_min? integer  min width kept for the message; refs use the rest; §6
---@field label_mode? "right"|"inline"|"dual"  ref label placement; §6.1
---@field diff? { open?: fun(range: DiffRange), label?: string }  external diff provider; §11.5
---@field working_tree? boolean  show uncommitted changes as virtual commits; §3.3/§4.2
---@field scrolloff? integer  'scrolloff' for the graph + commit-view windows (default 10); §8
---@field show_lane_ids? boolean  per-window lane-id debug overlay (toggled by `i`); window-owned, read by the renderer

---@param opts GraphOptions
function M.open(folder, opts)
    ---@type GraphOptions
    local defaults = {
        win = {
            border = "rounded",
            -- Nearly full screen: a ~2-char margin on each edge (snacks treats
            -- a returned size >= 1 as absolute and centers it). Re-evaluated on
            -- resize.
            width = function() return math.max(vim.o.columns - 4, 1) end,
            height = function() return math.max(vim.o.lines - 4, 1) end,
            title = "GraphView",
            footer = footer_text(),
        },
        palette = {
            date = "Title",
            author = "Comment",
            branch = "WarningMsg",
            remote = "Comment",
            head = "Special",
            message = nil,
            tags = "Comment",
            selected = "Visual", -- the h/l-selected ref decoration (§2)
            action = "Special",  -- the commit-view diff action label (§11.5)
            -- Reachability dimming (§12): blend factor toward the bg for the
            -- out-of-cone rows/lanes. Higher = more muted.
            dim = 0.45,
            -- Commit-view diff colors (§11.3): per-role highlight groups.
            diff = {
                add = "DiffAdd",
                delete = "DiffDelete",
                hunk = "Title",
                header = "Comment",
            },
            tracks = {
                --"DiagnosticWarn",
                "Constant",
                "String",
                "Number",
                --"Keyword",
                "Function",
                "DiagnosticInfo",
                "Identifier",
                --"DiagnosticHint",
                --"DiagnosticOk",
            },
            -- Lane colouring (§5.5): generate overflow colours in OKLCH when the
            -- curated `tracks` run low (auto-disabled without truecolor), keeping
            -- at least `buffer` colours in reserve so a released colour is not
            -- reused too soon. `anchor` (nil = derive L/C from the theme) sets the
            -- generated colours' lightness/chroma.
            generate = true,
            buffer = 3,
            anchor = nil,
        },
        --merge_style = "merge"
        merge_style = vim.deepcopy(MERGE_STYLES[merge_style_index].style),
        -- Render the graph mirrored (lane 1 at the right, nearest the message)
        -- by default. Toggle live with M.
        mirror = true,
        -- Reachability highlighting (§12) on by default; toggle live with H.
        highlight = true,
        -- First-parent focus (§10.7): on open, show HEAD's first-parent mainline
        -- in full and collapse every other branch (merged and divergent). Toggle
        -- live with `c`; set false to open the plain full graph.
        collapse_merged = true,
        -- Marker packing (§10.4): merge concurrent collapsed heads onto shared
        -- lines. Toggle live with `p`; set false for one marker per line.
        pack_markers = true,
        -- Junction markers (§10.4): draw a kept fork/merge inside collapsed
        -- branches node-less (just the split lanes, no message). Set false to
        -- show those junction commits in full.
        junction_markers = true,
        -- Date column: absolute (os.date format) or relative ("3 days ago").
        -- Toggle live with d.
        date_format = "%Y-%m-%d %H:%M",
        date_mode = "absolute",
        -- Refs are pinned to the right edge and use the free width; the message
        -- keeps at least message_min, and ref overflow becomes a "+N" marker.
        message_min = 24,
        -- Ref label placement (§6.1): "right" (default), "inline", or "dual".
        -- Cycle live with B.
        label_mode = "right",
        -- External diff provider (§11.5): open is called with a DiffRange; the
        -- default opens diffview. Override open/label to use another diff plugin,
        -- or set open = nil to disable (no action label, D is a no-op).
        diff = {
            open = open_diffview,
            label = "▶ Open diff (diffview)",
        },
        -- Working-tree state (§3.3/§4.2): show uncommitted changes as virtual
        -- commits (◌) on top of HEAD. On by default; refreshes live (R, writes,
        -- focus, §3.4). Set false to never read the working tree.
        working_tree = true,
        -- 'scrolloff' applied to the graph and commit-view windows: keep this many
        -- context rows above/below the cursor. The graph window otherwise inherits
        -- the global value, which interacts badly with the context-pane overlays
        -- (§6.2) — set 0 if the panes' scrolling misbehaves, or toggle panes with F.
        scrolloff = 10,
        icons = {
            --merge = "M",
        },
    }
    -- The default footer is computed before opts.mirror is resolved; unless the
    -- caller set its own footer, recompute it so the initial mirror state shows.
    local user_footer = opts and opts.win and opts.win.footer
    ---@type GraphOptions
    opts = vim.tbl_deep_extend("force", defaults, opts or {})
    if not user_footer then
        opts.win.footer = footer_text(opts.mirror)
    end
    -- Colour generation (§5.5) needs truecolor to realise RGB; without it Phase 1
    -- must not mint generated slots (they would have no colour), so degrade to
    -- the curated palette + sharing.
    opts.palette.generate = (opts.palette.generate ~= false) and vim.o.termguicolors and true or false

    -- Sync the cycle index to the configured label mode so B advances from it and
    -- the footer shows the right name.
    for i, m in ipairs(LABEL_MODES) do
        if m.mode == opts.label_mode then label_mode_index = i break end
    end

    local listview = require("gitloom.listview")

    ---@class Repo
    ---@field commits table<string, Commit>  hash → Commit (the resolution table)
    ---@field order OrderItem[]              raw commit items, 1:1 with commits (projection input)
    ---@field display? OrderItem[]           the projected OrderItem graph the view renders (§10; set at init)
    ---@field refs table<string, Ref>        name → Ref ("HEAD" for the head)
    ---@field head? string                   current branch name

    ---@type Repo
    local repo = {
        commits = {},
        order = {},
        refs = {},
    }
    -- The displayed graph is a projection of `order` under the view state. With
    -- no non-normal branch modes it is the identity, so it shares the same list
    -- (streaming appends to both) until a reflow swaps in a projected one (§10).
    repo.display = repo.order

    -- Resolve the initial sort mode (§3.1) from opts.sort_mode (an id string),
    -- defaulting to topo (order_commits). `S` cycles from here.
    if opts.sort_mode then
        for i, m in ipairs(SORT_MODES) do
            if m.id == opts.sort_mode then sort_mode_index = i; break end
        end
    end

    local palette = opts.palette

    ---@type SelectionState
    local selection_state = {
        commit = nil,
        index = nil,
    }

    -- The last buffer line the CursorMoved handler reacted to (it resets the ref
    -- selection on a row change). Lifted to this scope so a programmatic jump that
    -- sets its own selection (the ref picker, §2) can mark the landed row as
    -- already-visited and suppress the reset. Assigned in the window block below.
    local last_line = nil

    -- Commit selection (range) mode (§13). `active` gates the modal keymaps;
    -- `path`/`anchor`/`cursor` are the selected path over the visible projection
    -- (DisplayNodes, newest-first); `dparent`/`dchild` remember the branch chosen
    -- at each junction for h/l. `display_index` maps a node hash → its index in
    -- `repo.display`, rebuilt on reflow and on entering selection.
    ---@type { active: boolean, path?: table[], anchor?: table, cursor?: table, dparent: table<string,integer>, dchild: table<string,integer> }
    local sel = { active = false, path = nil, anchor = nil, cursor = nil, dparent = {}, dchild = {} }
    local display_index = {}
    -- node hash → { item, col }: the OrderItem holding the node and the index of
    -- the column carrying its marker. Covers both a node on its own row and a
    -- collapsed head packed into a marker group (§10.4) — which has no `.commit`,
    -- so display_index alone can't reach it. Lets the selection emphasis light a
    -- head's lane/marker even when packed (§13.4).
    local node_loc = {}
    local function build_display_index()
        display_index, node_loc = {}, {}
        local function locate(it, node)
            for c, cell in ipairs(it.columns or {}) do
                if cell.has_commit and cell.commit == node then
                    node_loc[node.hash] = { item = it, col = c }
                    return
                end
            end
        end
        for i, it in ipairs(repo.display or {}) do
            if it.commit then
                display_index[it.commit.hash] = i
                locate(it, it.commit)
            elseif it.type == "markers" then
                for _, m in ipairs(it.markers or {}) do locate(it, m) end
            end
        end
    end

    -- Reachability cone for the dimming pass (§12); nil until a pivot exists.
    -- `modes` is the branch-mode view state (ref name → mode); empty = all normal
    -- (the projection is then the identity). The reflow below reads it (§10).
    -- `modes` is explicit per-owner overrides; `effective` is the resolved mode
    -- per owner id after the first-parent default (§10.7), kept for the footer
    -- and the `<CR>` cycle. Both filled by reflow.
    -- `pinned` is the explicit per-ref pin overrides (ref id → boolean), on top
    -- of the HEAD-pinned-by-default rule (§10.6). The effective anchor set is
    -- computed by `effective_pinned()`; it generalises the single trunk of §10.7.
    local view_state = { cone = nil, modes = {}, effective = {}, pinned = {} }

    -- The effective anchor set (§10.6). Pinned by default: the current branch
    -- (HEAD) and the common trunks `master`/`main`/`dev` when present. The user's
    -- explicit pin/unpin overrides apply on top. Returns a set of ref-owner ids.
    local function effective_pinned()
        local p = {}
        if repo.head and repo.refs[repo.head] then p[repo.head] = true end
        for _, name in ipairs({ "master", "main", "dev" }) do
            if repo.refs[name] then p[name] = true end
        end
        for id, v in pairs(view_state.pinned) do
            if v then p[id] = true else p[id] = nil end
        end
        return p
    end
    -- Cached per-commit signatures for the projection (spec §10.5). They depend
    -- only on the commit set, the owner tips/fp-flags and the focus policy, not on
    -- modes, so a mode toggle reuses them; invalidated when those change. Keyed by
    -- the commit/owner counts and the collapse_merged flag.
    local sig_cache = { norder = -1, nowners = -1, cm = nil, sig = nil }

    -- Parks the cursor at the message (or the selected ref). Assigned after the
    -- listview opens; forward-declared so the key handlers can call it.
    local place_cursor = function() end
    -- Recomputes the pivot's cone + re-marks track activeness (§12). Assigned
    -- after the listview opens; forward-declared for the key handlers.
    local update_cone = function() end
    -- Rebuilds the context panes (§6.2) for the current viewport. Assigned after
    -- the listview opens; forward-declared so reflow/scroll can trigger it.
    local update_panes = function() end
    -- Pane debug state (the seam buffer line + height; or, when nothing showed,
    -- why), surfaced in the footer status when lane ids are on (`i`). Set by
    -- update_panes — one set per pane (footer below, header above).
    local footer_seam, footer_height, footer_dbg
    local header_seam, header_height, header_dbg
    -- Rebuilds the projected OrderItem graph under the current view state and
    -- swaps it into the listview (§10). Assigned after `order_at`/`lv` exist;
    -- forward-declared so the stream and key handlers can close over it.
    local reflow = function() end
    -- Moves the cursor onto the display row representing a commit hash (after a
    -- collapse/expand reflow, so the toggle stays under the cursor). Assigned in
    -- the window block; forward-declared for the key handlers.
    local goto_hash = function(_) end
    -- Centers the view vertically on the cursor's row (like `zz`, clamped at the
    -- graph edges). Assigned in the window block; forward-declared so the stream
    -- handler can focus HEAD on open (§2).
    local center_view = function() end
    -- The hash of the commit under the cursor at a buffer line, or nil on a row
    -- with no single commit. Used to remember the cursor position across
    -- close/reopen (§2). Assigned in the window block; forward-declared.
    local cursor_hash = function(_) return nil end

    -- Working-tree virtual commits (§3.3/§4.2): the staged/unstaged/untracked
    -- Commits currently spliced above HEAD (so a refresh can remove them), and the
    -- HEAD hash they were anchored on (so a refresh can tell when history moved).
    local worktree_commits = {}
    local worktree_head = nil
    -- Re-reads the dirty state and rebuilds the virtual commits (§3.4). Assigned
    -- in the window block; forward-declared for the autocmds.
    local refresh_worktree = function(_) end
    -- Full history resync (§3.4): re-read refs, pull new commits, prune, re-sort,
    -- refresh the worktree, reflow. Assigned in the window block; forward-declared
    -- for the `R` key.
    local resync = function(_) end

    -- The repository the graph reflects, identified by Neovim's cwd (git runs in
    -- cwd). Keys the remembered cursor position so reopening restores it (§2).
    local repo_key = vim.fn.getcwd()

    -- The listview instance. Forward-declared so the on_controller/stream
    -- callbacks below close over this local (not a stray global) and see it once
    -- it is assigned after the window opens.
    local lv

    -- Resolve a 1-based *buffer* line to its OrderItem, order index, and 0-based
    -- sub-row within the item. In dual mode a labelled commit spans two buffer
    -- lines (sub 0 = label row, sub 1 = message row); the buffer line is mapped
    -- via the listview. Without the map (or other modes) it is 1:1, sub 0.
    local function order_at(line)
        local idx, first = line, line
        if lv and lv.controller and lv.controller.item_at then
            idx = lv.controller.item_at(line)
            first = lv.controller.item_start and lv.controller.item_start(idx) or idx
        end
        return repo.display[idx], idx, line - first
    end

    -- Re-establish gitloom's owned row order (§3.1): run order_commits over the
    -- real (non-virtual) commit rows and rebuild repo.order in that order, reusing
    -- the existing OrderItem objects so identity is preserved. Called once at
    -- stream completion (the stream appended in provisional arrival order) and on
    -- every resync after new commits land. Worktree virtual commits are spliced
    -- separately (apply_worktree), so they are skipped and re-applied afterwards.
    local function reorder_repo()
        local item_of, commits = {}, {}
        for _, it in ipairs(repo.order) do
            if it.type == "commit" and it.commit and not it.commit.virtual then
                item_of[it.commit.hash] = it
                commits[#commits + 1] = it.commit
            end
        end
        local ordered = order_commits(commits)
        local new_order = {}
        for _, c in ipairs(ordered) do
            new_order[#new_order + 1] = item_of[c.hash]
        end
        repo.order = new_order
    end

    -- Reorder repo.order to match an external hash sequence (a `rev`-based sort
    -- mode's `git rev-list` output; §3.1). Rows git lists but we lack are skipped;
    -- in-memory rows git didn't list (refspec drift) are appended, so no row is
    -- dropped. Reuses the existing OrderItem objects. Virtual worktree commits are
    -- spliced separately, so they are excluded here.
    ---@param hashlist string[]
    local function reorder_by_hashes(hashlist)
        local item_of = {}
        for _, it in ipairs(repo.order) do
            if it.type == "commit" and it.commit and not it.commit.virtual then
                item_of[it.commit.hash] = it
            end
        end
        local new_order, placed = {}, {}
        for _, h in ipairs(hashlist) do
            local it = item_of[h]
            if it and not placed[h] then
                new_order[#new_order + 1] = it
                placed[h] = true
            end
        end
        for _, it in ipairs(repo.order) do
            if it.type == "commit" and it.commit and not it.commit.virtual
                and not placed[it.commit.hash] then
                new_order[#new_order + 1] = it
                placed[it.commit.hash] = true
            end
        end
        repo.order = new_order
    end

    -- Apply the active sort mode (§3.1) to repo.order, returning a Future (the
    -- `rev` modes query git asynchronously). The `gitloom` mode sorts the
    -- in-memory DAG (order_commits); the `rev` modes take git's exact sequence.
    -- The caller reflows.
    ---@return Future
    local function apply_sort()
        local mode = SORT_MODES[sort_mode_index]
        if mode.rev then
            local branch = opts.branches or { "--all" }
            if type(branch) ~= "table" then branch = { branch } end
            return fetch_rev_order(branch, mode.rev)
                .next(function(hashes) reorder_by_hashes(hashes) end)
        end
        reorder_repo()
        local future, promise = make_future()
        promise.resolve()
        return future
    end

    -- Merge a freshly-parsed Commit into the model (§3): fill its placeholder (or
    -- insert it), resolve its parent hashes to Commit references with child
    -- back-links, and append an OrderItem to repo.order (returned). Shared by the
    -- initial stream (on_batch) and the resync's new-commit pass. Identity-stable:
    -- a placeholder keeps its object and refs. Returns nil for an already-loaded
    -- commit (re-seen) so the caller doesn't double-link or double-list it.
    ---@param item Commit
    ---@return OrderItem?
    local function integrate_commit(item)
        local existing = repo.commits[item.hash]
        if existing then
            if existing.loaded then return nil end -- already a row; don't re-link
            -- Fill the placeholder; keep its resolved refs and children. cepoch
            -- (committer date) MUST be copied: ref tips are pre-created as
            -- placeholders by fetch_refs, and order_commits seeds tips by cepoch
            -- (§3.1) — dropping it falls back to author date and breaks the order
            -- on squash-merge repos (author ≠ committer date).
            existing.author = item.author
            existing.date = item.date
            existing.cepoch = item.cepoch
            existing.parents = item.parents
            existing.message = item.message
            existing.loaded = true
            item = existing
        else
            repo.commits[item.hash] = item
            item.children = item.children or {}
        end

        -- Resolve parent hashes (still strings from `git log`) to Commit refs.
        local resolved = {}
        for _, p in ipairs(item.parents) do
            local parent = get_or_create_commit(repo, p --[[@as string]])
            table.insert(parent.children, item)
            table.insert(resolved, parent)
        end
        item.parents = resolved

        ---@type OrderItem
        local order_item = { type = "commit", commit = item, columns = {} }
        table.insert(repo.order, order_item)
        return order_item
    end

    -- Remove a Ref from the model: unlink it from its commit's back-list and drop
    -- the registry entry. The resync uses it to retire a deleted or moved ref.
    ---@param key string
    local function unlink_ref(key)
        local ref = repo.refs[key]
        if not ref then return end
        local c = ref.commit
        if c and c.refs then
            for i = #c.refs, 1, -1 do
                if c.refs[i] == ref then table.remove(c.refs, i) end
            end
        end
        repo.refs[key] = nil
    end

    -- Reconcile the model's refs with a freshly-read ref set (§3.4): drop deleted
    -- refs, add new ones, and re-point moved ones (diff_ref_tips drives the three
    -- cases), then re-bind HEAD to the current branch. add_ref creates a
    -- placeholder Commit for a tip we haven't fetched yet; the new-commit pass
    -- fills it. Mutates repo.refs / repo.commits.
    ---@param entries { name: string, kind: string, hash: string }[]
    ---@param head string?
    local function reconcile_refs(entries, head)
        local newmap, by_key = {}, {}
        for _, e in ipairs(entries) do
            newmap[e.name] = e.hash
            by_key[e.name] = e
        end
        local oldmap = {}
        for k, ref in pairs(repo.refs) do
            if k ~= "HEAD" then oldmap[k] = ref.commit and ref.commit.hash end
        end

        local d = diff_ref_tips(oldmap, newmap)
        for _, k in ipairs(d.removed) do unlink_ref(k) end
        for _, k in ipairs(d.added) do
            local e = by_key[k]
            add_ref(repo, e.name, e.kind, e.hash)
        end
        for _, k in ipairs(d.moved) do
            local e = by_key[k]
            unlink_ref(k) -- detach the old binding before re-pointing
            add_ref(repo, e.name, e.kind, e.hash)
        end

        -- HEAD always re-points to the current branch's (possibly new) commit; a
        -- detached or vanished branch drops it.
        unlink_ref("HEAD")
        repo.head = head
        if head and repo.refs[head] and repo.refs[head].commit then
            add_ref(repo, "HEAD", "head", repo.refs[head].commit.hash)
        end
    end

    -- Prune commits no longer reachable from any ref (§3.4) — the orphans a
    -- force-push / rebase leaves behind. Walks parents from every ref tip, then
    -- drops unreachable real commits from repo.commits, prunes child back-links
    -- pointing at removed commits, and filters repo.order. Virtual worktree
    -- commits are not present here (cleared before a resync).
    local function prune_to_reachable()
        local tips = {}
        for _, ref in pairs(repo.refs) do
            if ref.commit then tips[#tips + 1] = ref.commit.hash end
        end
        local keep = reachable_hashes(repo.commits, tips)

        local removed = false
        for hash, c in pairs(repo.commits) do
            if not keep[hash] and not c.virtual then
                repo.commits[hash] = nil
                removed = true
            end
        end
        if not removed then return end

        for _, c in pairs(repo.commits) do
            if c.children then
                local kept = {}
                for _, ch in ipairs(c.children) do
                    if repo.commits[ch.hash] then kept[#kept + 1] = ch end
                end
                c.children = kept
            end
        end
        local kept_order = {}
        for _, it in ipairs(repo.order) do
            if it.commit and repo.commits[it.commit.hash] then
                kept_order[#kept_order + 1] = it
            end
        end
        repo.order = kept_order
    end

    -- Remove the working-tree virtual commits from the raw model (§4.2): unlink
    -- each from its parent's children, drop it from the commit table, and filter
    -- its OrderItem out of repo.order. Leaves the real DAG untouched. The caller
    -- reflows afterwards.
    local function clear_worktree_nodes()
        if #worktree_commits == 0 then return end
        for _, v in ipairs(worktree_commits) do
            local p = v.parents and v.parents[1]
            if p and p.children then
                for i = #p.children, 1, -1 do
                    if p.children[i] == v then table.remove(p.children, i) end
                end
            end
            repo.commits[v.hash] = nil
        end
        local kept = {}
        for _, it in ipairs(repo.order) do
            if not (it.commit and it.commit.virtual) then kept[#kept + 1] = it end
        end
        repo.order = kept
        worktree_commits = {}
    end

    -- Rebuild the working-tree virtual commits (§3.3/§4.2) from a fetched state
    -- ({ head_hash, status }). Removes any existing ones, then — when enabled,
    -- dirty, and the HEAD anchor is still in the model — splices up to three nodes
    -- (untracked → unstaged → staged → HEAD) into repo.order just above HEAD.
    -- Returns a status the caller surfaces: "ok" | "clean" | "off" | "moved"
    -- (HEAD advanced past the snapshot, §3.4). The caller reflows.
    local function apply_worktree(state)
        clear_worktree_nodes()
        if opts.working_tree == false then return "off" end
        worktree_head = state and state.head_hash
        local st = state and state.status
        if not (st and worktree_head) then return "clean" end
        local anchor = repo.commits[worktree_head]
        if not anchor then return "moved" end -- history advanced past the snapshot
        local want_staged = st.staged > 0
        local want_unstaged = st.unstaged > 0
        local want_untracked = st.untracked > 0
        if not (want_staged or want_unstaged or want_untracked) then return "clean" end

        -- The anchor's row index in the raw order; the nodes splice just above it.
        local ai
        for i, it in ipairs(repo.order) do
            if it.commit == anchor then ai = i; break end
        end
        if not ai then return "moved" end

        -- Build bottom-up (parent first): staged on HEAD, unstaged on the node
        -- below it, untracked on top — each parented to whichever exists below.
        -- `new_items` ends newest-first (untracked, unstaged, staged) for the
        -- splice above the anchor.
        local below = anchor
        local new_items = {}
        local function make(kind, wt, hash)
            ---@type Commit
            local v = { hash = hash, virtual = kind, parents = { below },
                children = {}, refs = {}, wt = wt }
            table.insert(below.children, v)
            below = v
            worktree_commits[#worktree_commits + 1] = v
            repo.commits[hash] = v
            table.insert(new_items, 1, { type = "commit", commit = v, columns = {} })
        end
        if want_staged then
            make("staged", { changed = st.staged }, WORKTREE_STAGED_HASH)
        end
        if want_unstaged then
            make("unstaged", { changed = st.unstaged }, WORKTREE_UNSTAGED_HASH)
        end
        if want_untracked then
            make("untracked", { changed = st.untracked }, WORKTREE_UNTRACKED_HASH)
        end
        for k = #new_items, 1, -1 do
            table.insert(repo.order, ai, new_items[k])
        end
        return "ok"
    end

    -- A full reflow (§10.5): project the raw commit order under the current
    -- branch modes into a fresh OrderItem graph, lay it out, and swap it into the
    -- listview. With all-normal modes the projection is the identity; this is the
    -- path every branch-mode change takes (and the stream takes once the
    -- projection is no longer the identity). Recomputes the cone over the new map.
    reflow = function()
        local viewbuilder = require("gitloom.graph.view")
        -- Owners under the first-parent default (§10.7): the pinned anchors
        -- (§10.6; HEAD by default) are first-parent-only + normal, every other ref
        -- and merge parent defaults collapsed; view_state.modes overrides. No
        -- anchor ⇒ all-normal.
        local cm = opts.collapse_merged ~= false
        local owners = viewbuilder.owners(
            repo.order, owners_from_refs(repo.refs, {}), effective_pinned(), view_state.modes, cm)
        view_state.effective = {}
        for _, o in ipairs(owners) do view_state.effective[o.id] = o.mode end
        -- Reuse cached signatures unless the commit/owner set or focus changed;
        -- only the join + contraction (mode-dependent) recompute on a toggle.
        if sig_cache.norder ~= #repo.order or sig_cache.nowners ~= #owners
            or sig_cache.cm ~= cm or not sig_cache.sig then
            sig_cache.sig = viewbuilder.signatures(repo.order, owners)
            sig_cache.norder, sig_cache.nowners, sig_cache.cm = #repo.order, #owners, cm
        end
        local proj = viewbuilder.project(repo.order, owners, sig_cache.sig)
        refresh_columns(opts, proj.items)
        -- Pack concurrent collapsed heads onto shared lines (spec §10.4) unless
        -- packing is off. The unpacked, laid-out list stays the projection input.
        repo.display = (opts.pack_markers ~= false) and pack_markers(proj.items) or proj.items
        -- A reflow recreates the DisplayNodes, so any in-flight commit selection
        -- (§13) holds stale node references — drop it. (Pure selection movement
        -- never reflows; this guards m/<Tab>/c/p/P etc. taken mid-selection.)
        sel.active, sel.path, sel.anchor, sel.cursor = false, nil, nil, nil
        if lv and lv.controller and lv.controller.set_items then
            lv.controller.set_items(repo.display)
        end
        build_display_index()
        update_cone()
        if lv and lv.controller then lv.controller.refresh() end
        update_panes()
    end

    -- The "branch" the collapse interactions (§10.4) act on at a buffer line:
    --   { state = "expanded"|"collapsed"|"mainline", owners = ids to flip,
    --     follow = hash to put the cursor on after the flip, commit = a real
    --     Commit for examine/diff }.
    -- Resolved from the selection (a ref or a packed marker) or, failing that,
    -- the region under the cursor via its signature — so it needs no ref.
    local function branch_under_cursor(line)
        local item = order_at(line)
        if not item then return nil end
        -- a selected marker on a packed line → expand that marker
        if item.type == "markers" then
            if selection_state.commit == item and selection_state.index then
                local u = marker_units(item)[selection_state.index]
                if u then
                    local owners = {}
                    for oid in pairs(u.marker.signature or {}) do owners[#owners + 1] = oid end
                    return { state = "collapsed", owners = owners,
                        follow = u.marker.tip and u.marker.tip.hash, commit = u.marker.tip }
                end
            end
            return { state = "collapsed" } -- packed line, no selection
        end
        local c = item.commit
        if not c then return nil end
        -- a selected ref → that branch (toggle by its effective mode)
        if selection_state.index and selection_state.commit == c then
            local ids = selected_owner_ids(c, selection_state.index)
            if ids then
                local cur = view_state.effective[ids[1]] or "normal"
                return { state = (cur == "collapsed") and "collapsed" or "expanded",
                    owners = ids, follow = c.hash, commit = c }
            end
        end
        -- a single collapsed marker (head) → expand its region
        if c.collapsed then
            local owners = {}
            for oid in pairs(c.signature or {}) do
                if (view_state.effective[oid] or "normal") == "collapsed" then owners[#owners + 1] = oid end
            end
            return { state = "collapsed", owners = owners,
                follow = c.tip and c.tip.hash, commit = c.tip }
        end
        -- a normal/junction commit → collapse the region containing it, if it is
        -- not mainline (no pinned anchor reaches it).
        local ids = collapse_owners(sig_cache.sig and sig_cache.sig[c.hash], effective_pinned(), view_state.effective)
        if ids then
            return { state = "expanded", owners = ids, follow = c.hash, commit = c }
        end
        return { state = "mainline", commit = c }
    end

    -- Recompute the footer (active modes + the branch-mode summary, §10) and
    -- apply it to the floating window. Centralised so every state change updates
    -- it the same way.
    local function update_footer()
        if lv and lv.win and lv.win.win then
            local nanchors = 0
            for _ in pairs(effective_pinned()) do nanchors = nanchors + 1 end
            local status = footer_text(opts.mirror, view_state.modes,
                opts.collapse_merged ~= false, nanchors, SORT_MODES[sort_mode_index].label)
            -- Commit selection (§13): show the mode + the selected row count.
            if sel.active then
                status = status .. (" | SELECT %d"):format(#(sel.path or {}))
            end
            -- Debug (lane ids on, `i`): the footer-pane cutoff (seam buffer line)
            -- and height when shown, or why it is hidden.
            if opts.show_lane_ids then
                if header_seam then
                    status = status .. (" | hdr@%s h=%d"):format(tostring(header_seam), header_height or 0)
                elseif header_dbg then
                    status = status .. " | hdr hidden: " .. header_dbg
                end
                if footer_seam then
                    status = status .. (" | ftr@%s h=%d"):format(tostring(footer_seam), footer_height or 0)
                elseif footer_dbg then
                    status = status .. " | ftr hidden: " .. footer_dbg
                end
            end
            lv.win.opts.footer = status
            pcall(vim.api.nvim_win_set_config, lv.win.win, {
                footer = lv.win.opts.footer,
                footer_pos = "center",
            })
        end
    end

    -- Apply a mode to a branch's owners, reflow, and keep the cursor on it (§10.4).
    local function set_branch(b, mode, follow)
        for _, oid in ipairs(b.owners or {}) do view_state.modes[oid] = mode end
        reflow()
        update_footer()
        if follow then goto_hash(follow) end
        place_cursor()
    end

    -- ── Commit selection (range) — window glue (spec §13) ───────────────────
    -- The OrderItem for a DisplayNode (by hash), or nil when it has no own row
    -- (a head packed into a marker group, §10.4 — selection clamps there in v1).
    local function node_item(node)
        if not node then return nil end
        local i = display_index[node.hash]
        return i and repo.display[i] or nil
    end
    -- Resolve a path endpoint DisplayNode to its real newest / oldest Commit: a
    -- collapsed head (§10.3) stands for its whole region, so its newest is the tip
    -- and its oldest is the last region member (§13.1).
    local function real_newest(node) return node.collapsed and node.tip or node.commit end
    local function real_oldest(node)
        if node.collapsed then
            local region = node.region or {}
            local h = region[#region]
            return (h and repo.commits[h]) or node.tip
        end
        return node.commit
    end
    -- The selection's DiffRange (§13.5): newest .. oldest real endpoints.
    local function selection_range()
        local p = sel.path
        if not (p and #p > 0) then return nil end
        local newer, older = real_newest(p[1]), real_oldest(p[#p])
        if not (newer and older) then return nil end
        return range_endpoints(newer, older)
    end
    -- Hand the selection range to the external diff provider (§13.5; the `D`
    -- key, and the range view's action label).
    local function open_selection_diff()
        local open = opts.diff and opts.diff.open
        if not open then
            vim.notify("gitloom: no diff provider configured (set diff.open)", vim.log.levels.WARN)
            return
        end
        local r = selection_range()
        if r then open(r) end
    end
    -- The selected commits, newest first (§13.5): each path node's real commit,
    -- a collapsed head expanded to its region members (resolved via repo.commits).
    local function selection_commits()
        local out, seen = {}, {}
        local function push(c)
            if c and not seen[c.hash] then seen[c.hash] = true; out[#out + 1] = c end
        end
        for _, node in ipairs(sel.path or {}) do
            if node.collapsed then
                for _, h in ipairs(node.region or {}) do push(repo.commits[h]) end
            else
                push(node.commit)
            end
        end
        return out
    end
    -- <CR> while selecting (§13.5): open the commit view in **range mode** — the
    -- selected-commit list + the combined range diff/diffstat, its action label
    -- opening the same range in the external viewer.
    local function open_selection_view()
        local r = selection_range()
        if not r then return end
        local commits = selection_commits()
        local n = #commits
        local title = (n == 1) and ("Commit " .. (commits[1] and commits[1].hash:sub(1, 7) or ""))
            or (("Selection: %d commits"):format(n))
        open_commit_view(opts, nil, { range = r, commits = commits, title = title })
    end

    -- Emphasis for the selected path (§13.4): light the path's commit markers and
    -- the lane between each consecutive pair, dim the rest. Mirrors mark_reachable
    -- — reset the highlight on every lane/marker drawn in the visible range, then
    -- light the path. Returns the cone set (keyed by DisplayNode) for row dimming.
    local function mark_path(top, bottom)
        for i = top, bottom do
            local it = repo.display[i]
            if it then
                for _, l in ipairs(it.parent_lanes or {}) do l.highlighted = false end
                for _, l in ipairs(it.child_lanes or {}) do l.highlighted = false end
                for _, line in ipairs(item_lines(it)) do
                    for _, t in ipairs(line) do
                        for _, s in ipairs(t.lanes or {}) do
                            for _, e in ipairs(s.edges or {}) do e.highlighted = false end
                        end
                        if t.has_commit then t.active = false end
                    end
                end
            end
        end
        local cone = {}
        local p = sel.path or {}
        for _, node in ipairs(p) do cone[node] = true end
        -- Light the lane each consecutive pair shares (newer p[i] = child → older
        -- p[i+1] = parent). For a node on its own row use its parent_lanes; for a
        -- packed head (no parent_lanes) match the shared Lane object by edge
        -- identity in its marker column — it is the same object the child's row
        -- draws, so lighting it lights both.
        for i = 1, #p - 1 do
            local a, b = p[i], p[i + 1]
            local it = node_item(a)
            if it then
                for _, lane in ipairs(it.parent_lanes or {}) do
                    if lane.parent == b then lane.highlighted = true end
                end
            else
                local loc = node_loc[a.hash] or node_loc[b.hash]
                if loc then
                    for _, s in ipairs(loc.item.columns[loc.col].lanes or {}) do
                        for _, e in ipairs(s.edges or {}) do
                            if e.begin == a and e.parent == b then e.highlighted = true end
                        end
                    end
                end
            end
        end
        -- Light each path node's marker cell (its own row, or its column in a
        -- packed marker group).
        for _, node in ipairs(p) do
            local it = node_item(node)
            if it then
                for _, line in ipairs(item_lines(it)) do
                    for _, t in ipairs(line) do
                        if t.has_commit and t.commit == node then t.active = true end
                    end
                end
            else
                local loc = node_loc[node.hash]
                if loc then loc.item.columns[loc.col].active = true end
            end
        end
        return cone
    end

    -- Reachability emphasis seeded from a packed marker head (spec §10.4 + §12).
    -- On a packed line `h`/`l` selects a head with no row of its own, so
    -- mark_reachable's index pivot can't reach it. Walk the DisplayNode graph from
    -- the selected head — `.parents` (ancestors) then `.children` (descendants) —
    -- bounded to the visible rows, lighting each traversed lane via its shared
    -- edge object (by node_loc for a packed head, as mark_path does) and each cone
    -- node's marker cell. Returns the cone set keyed by DisplayNode (row dimming).
    -- So selecting a packed head dims the sibling heads/branches and keeps the
    -- selected one lit, exactly like moving onto a normal head (§12).
    local function mark_node_cone(pivot, top, bottom)
        local visible, item_of = {}, {}
        for i = top, bottom do
            local it = repo.display[i]
            if it then
                if it.commit then
                    visible[it.commit] = true; item_of[it.commit] = it
                elseif it.type == "markers" then
                    for _, m in ipairs(it.markers or {}) do visible[m] = true; item_of[m] = it end
                end
            end
        end
        -- Reset every lane/marker drawn in the window (same sweep as mark_reachable)
        -- so a persistent lane keeps no stale highlight from the previous pivot.
        for i = top, bottom do
            local it = repo.display[i]
            if it then
                for _, l in ipairs(it.parent_lanes or {}) do l.highlighted = false end
                for _, l in ipairs(it.child_lanes or {}) do l.highlighted = false end
                for _, line in ipairs(item_lines(it)) do
                    for _, t in ipairs(line) do
                        for _, s in ipairs(t.lanes or {}) do
                            for _, e in ipairs(s.edges or {}) do e.highlighted = false end
                        end
                        if t.has_commit then t.active = false end
                    end
                end
            end
        end
        local cone = {}
        if not pivot or not visible[pivot] then return cone end
        cone[pivot] = true
        -- Light the lane the child→parent edge draws: on the child's own row via
        -- its parent_lanes, or in a packed head's marker column by edge identity
        -- (the same shared Lane the child row would draw).
        local function light_edge(child, parent)
            local it = node_item(child)
            if it then
                for _, lane in ipairs(it.parent_lanes or {}) do
                    if lane.parent == parent then lane.highlighted = true end
                end
            else
                local loc = node_loc[child.hash] or node_loc[parent.hash]
                if loc then
                    for _, s in ipairs(loc.item.columns[loc.col].lanes or {}) do
                        for _, e in ipairs(s.edges or {}) do
                            if e.begin == child and e.parent == parent then e.highlighted = true end
                        end
                    end
                end
            end
        end
        local stack = { pivot } -- ancestors via .parents
        while #stack > 0 do
            local n = table.remove(stack)
            for _, p in ipairs(n.parents or {}) do
                light_edge(n, p)
                if visible[p] and not cone[p] then cone[p] = true; stack[#stack + 1] = p end
            end
        end
        stack = { pivot } -- descendants via .children
        while #stack > 0 do
            local n = table.remove(stack)
            for _, ch in ipairs(n.children or {}) do
                light_edge(ch, n)
                if visible[ch] and not cone[ch] then cone[ch] = true; stack[#stack + 1] = ch end
            end
        end
        for n in pairs(cone) do -- light each cone node's marker cell
            local it = node_item(n)
            if it then
                for _, line in ipairs(item_lines(it)) do
                    for _, t in ipairs(line) do
                        if t.has_commit and t.commit == n then t.active = true end
                    end
                end
            else
                local loc = node_loc[n.hash]
                if loc then loc.item.columns[loc.col].active = true end
            end
        end
        return cone
    end

    -- Recompute the path emphasis, move the cursor onto the moving end, and
    -- redraw (§13). update_cone branches to mark_path while selection is active.
    local function selection_redraw()
        if sel.cursor then goto_hash(sel.cursor.hash) end
        update_cone()
        if lv and lv.controller then lv.controller.refresh() end
        place_cursor()
        update_footer()
        update_panes()
    end
    -- V: start selection on the row's commit (a normal commit or a collapsed head;
    -- a packed marker line is not a start point in v1). anchor = cursor = it.
    local function enter_selection(line)
        local item = order_at(line)
        if not item or not item.commit or item.type == "markers" then return end
        -- Commit selection (§13) is over real commits; a working-tree virtual
        -- commit (§4.2) is not a selectable range endpoint (v1).
        if item.commit.virtual then return end
        build_display_index()
        selection_state.index = nil -- drop the ref selection (§13.3)
        sel.active, sel.anchor, sel.cursor = true, item.commit, item.commit
        sel.path, sel.dparent, sel.dchild = { item.commit }, {}, {}
        selection_redraw()
    end
    local function exit_selection()
        sel.active, sel.path, sel.anchor, sel.cursor = false, nil, nil, nil
        update_cone() -- restore the cursor-pivot cone (§12)
        if lv and lv.controller then lv.controller.refresh() end
        place_cursor()
        update_footer()
        update_panes()
    end
    -- j/k along the branch (§13.2): step the moving end one commit; redraw.
    local function selection_move(dir)
        if not sel.active then return end
        sel_step(sel, dir)
        selection_redraw()
    end
    -- <C-d>/<C-u>: a half-viewport of branch commits, stopping at a tip/root
    -- (§13.2; the exact count is a tuning point, §13.6).
    local function selection_page(dir)
        if not (sel.active and lv and lv.win and lv.win.win) then return end
        local steps = math.max(1, math.floor(vim.api.nvim_win_get_height(lv.win.win) / 2))
        for _ = 1, steps do
            local before = sel.cursor
            sel_step(sel, dir)
            if sel.cursor == before then break end
        end
        selection_redraw()
        center_view()
    end
    -- h/l: switch branch at the nearest junction (§13.3). The rotation is in lane
    -- order, so under mirroring (§5.4, lane 1 at the right) the visual direction is
    -- reversed — negate `delta` so `l` always moves toward the visually-right
    -- branch and `h` the left, matching how the graph reads.
    local function selection_switch(delta)
        if not sel.active then return end
        if opts.mirror ~= false then delta = -delta end
        if sel_switch(sel, delta) then selection_redraw() end
    end
    -- o: swap the anchor and the moving end (§13.2).
    local function selection_swap()
        if not sel.active then return end
        sel.anchor, sel.cursor = sel.cursor, sel.anchor
        selection_redraw()
    end
    -- <Tab> while selecting (§13.4): fold/unfold the head under the cursor in
    -- place. Expand the cursor's collapsed head (or collapse its region), then
    -- re-resolve the selection against the new projection **by hash** so it covers
    -- the same commits: an unfolded head expands into its whole region (so the
    -- revealed branch stays selected/lit), a collapsed run maps back to its head.
    -- The diff range is therefore unchanged by fold/unfold; the anchor keeps its
    -- end and the cursor lands on the toggled (opposite) end. The saved scroll
    -- (topline) is restored so the view does not jump. A no-op on a mainline
    -- commit (nothing collapsible there).
    local function selection_toggle()
        local node = sel.active and sel.cursor
        if not node or not (lv and lv.win and lv.win.win) then return end
        local owners, mode = {}, nil
        if node.collapsed then -- a head: expand its still-collapsed owners
            for oid in pairs(node.signature or {}) do
                if (view_state.effective[oid] or "normal") == "collapsed" then owners[#owners + 1] = oid end
            end
            mode = "normal"
        else -- a normal/expanded commit: collapse its region, unless mainline
            owners = collapse_owners(sig_cache.sig and sig_cache.sig[node.hash],
                effective_pinned(), view_state.effective) or {}
            mode = "collapsed"
        end
        if #owners == 0 then return end

        -- Capture the selection by hash + the scroll position before reflow
        -- recreates the DisplayNodes. A collapsed head stands in for its whole
        -- region, so expand it to its region member hashes; a normal node is
        -- itself. Remember which end holds the anchor so we can restore both ends.
        local w = lv.win.win
        local view = vim.api.nvim_win_call(w, function() return vim.fn.winsaveview() end)
        local anchor_is_top = (sel.path or {})[1] == sel.anchor
        local function members(n) return n.collapsed and (n.region or {}) or { n.hash } end
        local path_h = {}
        for _, n in ipairs(sel.path or {}) do
            for _, h in ipairs(members(n)) do path_h[#path_h + 1] = h end
        end

        for _, oid in ipairs(owners) do view_state.modes[oid] = mode end
        reflow() -- rebuilds display + node_loc, drops sel

        -- Map every real-commit / head hash to its new node (members → the head),
        -- then rebuild the path: an expanded head's members resolve to their own
        -- nodes (all kept, so the branch stays selected); a still-collapsed run's
        -- members all resolve to one head (dedup), as does a newly-collapsed run.
        local by_hash = {}
        local function add(n)
            by_hash[n.hash] = n
            if n.collapsed then for _, h in ipairs(n.region or {}) do by_hash[h] = n end end
        end
        for _, it in ipairs(repo.display or {}) do
            if it.commit then
                add(it.commit)
            elseif it.type == "markers" then
                for _, m in ipairs(it.markers or {}) do add(m) end
            end
        end
        local newpath = {}
        for _, h in ipairs(path_h) do
            local nn = by_hash[h]
            if nn and nn ~= newpath[#newpath] then newpath[#newpath + 1] = nn end
        end
        if #newpath == 0 then return end -- selection lost (e.g. all hidden); stay dropped
        sel.path = newpath
        -- Keep the anchor on its end; the cursor takes the other (the toggled end).
        if anchor_is_top then
            sel.anchor, sel.cursor = newpath[1], newpath[#newpath]
        else
            sel.anchor, sel.cursor = newpath[#newpath], newpath[1]
        end
        sel.active = true

        -- Settle the viewport first (move to the cursor, restore the saved scroll
        -- so the rows above the toggle stay put), *then* recompute the emphasis
        -- over the settled range and redraw — otherwise mark_path runs over the
        -- old range and the unfolded rows render with a stale highlight.
        goto_hash(sel.cursor.hash)
        vim.api.nvim_win_call(w, function()
            local cur = vim.api.nvim_win_get_cursor(w)
            pcall(vim.fn.winrestview, { topline = view.topline, lnum = cur[1], col = cur[2], leftcol = 0 })
        end)
        update_cone()
        if lv.controller then lv.controller.refresh() end
        place_cursor()
        update_footer()
        update_panes()
    end

    ---@type ListViewOptions
    local listview_options = {
        win = opts.win,
        -- The message (FLEX_COL) fills the row; refs (line_right) pin to the
        -- right edge, using the free width down to message_min (§6).
        flex = FLEX_COL,
        message_min = opts.message_min,
        overflow_hl = opts.palette.remote,
        -- Sticky cap on the author column so it only grows (no scroll bounce).
        col_max = { [AUTHOR_COL] = AUTHOR_MAX },
        -- Under mirroring, make the graph column sticky too (only grow) so the
        -- right-aligned graph + message don't bounce as the lane width changes.
        col_sticky = function() return opts.mirror and { GRAPH_COL } or {} end,
        -- Real buffer lines per item: a dual-mode labelled commit is two rows
        -- (label row + message row), everything else one. Cheap — reads only the
        -- commit's refs + mode — so the listview's buffer-line map needs no layout.
        line_count = function(item)
            return dual_two_line(opts, item and item.commit) and 2 or 1
        end,
        display = function(item)
            return display_item(opts, item, selection_state, view_state.cone,
                sel.active and sel.cursor or nil)
        end,
        on_controller = function(controller)
            -- Refs first: they create sparse Commit placeholders with refs
            -- attached, which the commit stream then fills in (identity
            -- preserved), so rows render with their refs already present.
            fetch_refs(repo).next(function()
                return fetch_head(repo)
            end).next(function()
                return fetch_commits({
                    branch = opts.branches or { "--all" },
                    -- One batch of streamed commits (spec §3): link each into the
                    -- model, then lay out and insert the whole batch with a single
                    -- relayout + insert (cheaper than per-commit, and the work is
                    -- off the stdout handler — see fetch_commits).
                    ---@param commits Commit[]
                    on_batch = function(commits)
                        local new_items = {}
                        for _, item in ipairs(commits) do
                            local order_item = integrate_commit(item)
                            if order_item then
                                new_items[#new_items + 1] = order_item
                            end
                        end
                        if #new_items == 0 then return end

                        -- Fast path while the projection is the identity (the
                        -- common all-normal case): lay out and append the batch.
                        -- Once a branch mode makes the display a separate
                        -- projection, a streamed batch needs a full reflow (§10).
                        if repo.display == repo.order then
                            local from = #repo.order - #new_items + 1
                            refresh_columns(opts, repo.order, from)
                            controller.insert(new_items, from)
                        else
                            reflow()
                        end
                    end,
                })
            end).next(function()
                -- Stream closed: apply the active sort mode (§3.1) to establish the
                -- authoritative row order before anything is projected or anchored.
                -- (The stream appended git's --topo-order arrival order.)
                return apply_sort()
            end).next(function()
                -- Working-tree virtual commits (§3.3/§4.2): with HEAD now in the
                -- model, read the dirty state and splice the staged/unstaged/
                -- untracked nodes above HEAD before the projection. Gated by
                -- working_tree; a clean tree is a no-op. Chained so the reflow
                -- below projects them.
                if opts.working_tree == false then return nil end
                return fetch_worktree_state()
            end).next(function(state)
                if state then apply_worktree(state) end
                -- Stream done: apply the projection (the first-parent default
                -- collapse, §10.7) and compute the initial dimming (§12). reflow
                -- swaps in the projected graph, recomputes the cone, and refreshes.
                reflow()
                update_footer()
                -- Focus the remembered position for this repo if we have one,
                -- else HEAD; center the view on it (§2). goto_hash resolves a
                -- folded commit to its collapsed head; if the target is gone it
                -- leaves the cursor at the top. The HEAD ref (§3.2) is absent on a
                -- detached HEAD, so that case keeps the top of the graph.
                local target = saved_positions[repo_key]
                if not (target and goto_hash(target)) then
                    local headref = repo.refs["HEAD"]
                    if headref and headref.commit then goto_hash(headref.commit.hash) end
                end
                center_view()
                place_cursor()
                -- Focusing HEAD moved the pivot and scrolled the viewport, so the
                -- cone reflow ran for the wrong (top) range — recompute it for the
                -- new pivot/viewport and redraw (§12).
                update_cone()
                if lv and lv.controller then lv.controller.refresh() end
                update_panes()
            end)
        end,
    }

    opts.win.keys = opts.win.keys or {}
    -- m: cycle the merge/split style. A full reflow (re-layout from the raw order
    -- then re-pack) — the packed display can't be relaid in place (its marker
    -- groups aren't single commits).
    opts.win.keys.m = function()
        merge_style_index = (merge_style_index % #MERGE_STYLES) + 1
        opts.merge_style = vim.deepcopy(MERGE_STYLES[merge_style_index].style)
        reflow()
        update_footer() -- reflect the new mode live in the footer
        place_cursor() -- widths shifted; keep the cursor on message/ref
    end
    -- M: toggle graph mirroring (lane 1 on the right). A render-only change, so
    -- just refresh the display (no relayout/re-fetch) — like the `i` toggle.
    opts.win.keys.M = function()
        opts.mirror = not opts.mirror
        if lv and lv.controller then
            lv.controller.refresh()
        end
        update_footer()
        update_panes() -- re-align/re-render the footer for the new orientation
        place_cursor()
    end
    -- B: cycle the ref label placement (right / inline / dual; §6.1). The layout
    -- is unchanged, but dual turns labelled commits into two real rows, which
    -- changes per-item line counts — so relayout (resize the buffer + rebuild the
    -- line map), not just refresh. Reset the selection so it re-derives under the
    -- new mode (dual pre-selects the first label on the next cursor settle).
    opts.win.keys.B = function()
        label_mode_index = (label_mode_index % #LABEL_MODES) + 1
        opts.label_mode = LABEL_MODES[label_mode_index].mode
        selection_state.index = nil
        if lv and lv.controller then
            lv.controller.relayout()
        end
        update_footer()
        update_cone() -- buffer lines shifted; recompute the cone over the new map
        place_cursor()
    end
    -- <Tab>: the quick collapse ⇄ expand toggle for the branch under the cursor
    -- (§10.4). Collapse an expanded branch or expand a marker; the cursor follows
    -- the result (set_branch → goto_hash) so repeated <Tab> flips it in place.
    -- Two-state — hidden is the menu's job, so nothing vanishes under the cursor.
    opts.win.keys["<Tab>"] = function(self)
        -- While selecting (§13.4), <Tab> folds/unfolds the head under the cursor
        -- in place, keeping the selection and the screen position.
        if sel.active then selection_toggle(); return end
        local line = vim.api.nvim_win_get_cursor(self.win --[[@as integer]])[1]
        local b = branch_under_cursor(line)
        if not b or not b.owners or #b.owners == 0 then return end
        if b.state == "collapsed" then
            set_branch(b, "normal", b.follow)
        elseif b.state == "expanded" then
            set_branch(b, "collapsed", b.follow)
        end
    end
    -- <CR>: an action menu for the row (§10.4) — examine / diff / collapse /
    -- expand / hide, most-relevant first. On a packed line it lists every marker
    -- by name, so any branch is reachable even when not all labels fit.
    opts.win.keys["<CR>"] = function(self)
        -- In commit selection (§13.5) <CR> opens the commit view in range mode
        -- (the selected-commit list + combined range diff); D opens the range in
        -- the external viewer.
        if sel.active then open_selection_view(); return end
        local line = vim.api.nvim_win_get_cursor(self.win --[[@as integer]])[1]
        local item = order_at(line)
        if not item then return end
        local actions = {}
        local function add(label, run) actions[#actions + 1] = { label = label, run = run } end

        if item.type == "markers" then
            -- list every marker by name (overflow-proof access)
            for _, u in ipairs(marker_units(item)) do
                local owners = {}
                for oid in pairs(u.marker.signature or {}) do owners[#owners + 1] = oid end
                local tip = u.marker.tip and u.marker.tip.hash
                add("Expand " .. u.text, function() set_branch({ owners = owners }, "normal", tip) end)
                add("Hide " .. u.text, function() set_branch({ owners = owners }, "hidden", nil) end)
            end
        else
            local b = branch_under_cursor(line)
            if b then
                if b.state == "expanded" then
                    add("Collapse branch", function() set_branch(b, "collapsed", b.follow) end)
                    add("Hide branch", function() set_branch(b, "hidden", nil) end)
                elseif b.state == "collapsed" then
                    add("Expand branch", function() set_branch(b, "normal", b.follow) end)
                    add("Hide branch", function() set_branch(b, "hidden", nil) end)
                end
                if b.commit then
                    add(b.state == "collapsed" and "Examine tip commit" or "Examine commit",
                        function() open_commit_view(opts, b.commit) end)
                    if opts.diff and opts.diff.open then
                        add("Open diff", function() open_diff(opts, b.commit) end)
                    end
                end
            end
        end

        if #actions == 0 then return end
        vim.ui.select(actions, {
            prompt = "gitloom",
            format_item = function(a) return a.label end,
        }, function(choice)
            if choice then choice.run() end
        end)
    end
    -- D: open the commit's diff in the external diff viewer (§11.5), or — while
    -- selecting (§13.5) — the selected range.
    opts.win.keys.D = function(self)
        if sel.active then open_selection_diff(); return end
        local w = self and self.win
        if not w then return end
        local line = vim.api.nvim_win_get_cursor(w)[1]
        local item = order_at(line)
        if not item or not item.commit or item.commit.collapsed then
            return -- a collapsed head has no single commit to diff
        end
        open_diff(opts, item.commit)
    end
    -- K: float with the full lane breakdown for the commit under the cursor.
    opts.win.keys.K = function(self)
        local w = self and self.win
        if not w then return end
        local line = vim.api.nvim_win_get_cursor(w)[1]
        local item = order_at(line)
        if not item or not item.commit then
            return
        end
        vim.lsp.util.open_floating_preview(format_lane_info(item), "", {
            border = "rounded",
            focusable = true,
            -- Topmost, like the `?` help, so the panes don't hide it.
            zindex = ZINDEX.help,
        })
    end
    -- d: toggle the date column between absolute and relative. Render-only.
    opts.win.keys.d = function()
        opts.date_mode = (opts.date_mode == "relative") and "absolute" or "relative"
        if lv and lv.controller then
            lv.controller.refresh()
        end
        place_cursor()
    end
    -- H: toggle reachability highlighting (dimming) on/off (§12). Render-only.
    opts.win.keys.H = function()
        opts.highlight = opts.highlight == false
        update_cone() -- recompute for the current pivot so the toggle takes effect
        if lv and lv.controller then
            lv.controller.refresh()
        end
        place_cursor()
    end
    -- R: resync with the repository (§3.4) — re-read refs, pull newly-reachable
    -- commits, prune orphans, re-sort, and rebuild the working-tree virtuals,
    -- keeping the cursor/scroll/selection. The general history refresh; the
    -- working-tree refresh is folded into it.
    opts.win.keys.R = function()
        resync(false)
    end
    -- S: cycle the row sort mode (§3.1) — gitloom's clustered topo sort, git's
    -- exact --topo-order, or git's date / author-date order. Reorders repo.order
    -- in place (no re-stream) and reflows, keeping the cursor on its commit.
    opts.win.keys.S = function()
        local keep
        local ok, pos = pcall(vim.api.nvim_win_get_cursor, lv and lv.win and lv.win.win)
        if ok then keep = cursor_hash(pos[1]) end
        sort_mode_index = (sort_mode_index % #SORT_MODES) + 1
        apply_sort().next(function()
            reflow()
            update_footer() -- footer shows the active sort mode
            if keep then goto_hash(keep) end
            place_cursor()
            update_cone()
            if lv and lv.controller then lv.controller.refresh() end
            update_panes()
        end)
    end
    -- c: toggle the first-parent focus (§10.7) — collapse every non-mainline
    -- branch vs. show the full graph. Changes per-item line counts, so reflow.
    opts.win.keys.c = function()
        opts.collapse_merged = opts.collapse_merged == false
        reflow()
        update_footer()
        place_cursor()
    end
    -- p: toggle marker packing (§10.4) — merge concurrent collapsed heads onto
    -- shared lines vs. one per line. Changes line counts, so reflow.
    opts.win.keys.p = function()
        opts.pack_markers = opts.pack_markers == false
        reflow()
        update_footer()
        place_cursor()
    end
    -- <leader>b: jump to a branch / ref via a snacks.picker (§2). Lists every ref
    -- (HEAD included), recently jumped refs first (the session MRU); selecting one
    -- centers the view on its commit. The jump (goto_hash) resolves a folded
    -- commit to its collapsed head and re-runs the open-time focus steps (cone +
    -- panes) so dimming/footer follow the new pivot; a hidden ref is a no-op.
    opts.win.keys["<leader>b"] = function(self)
        local gwin = self and self.win -- the graph float to refocus / move
        local picker_ok, picker = pcall(require, "snacks.picker")
        if not picker_ok then
            vim.notify("gitloom: snacks.picker not available", vim.log.levels.WARN)
            return
        end
        local items = ref_picker_items(repo.refs, recent_refs[repo_key])
        if #items == 0 then
            vim.notify("gitloom: no refs to jump to", vim.log.levels.INFO)
            return
        end
        -- ref_picker_items sets each item's `text` (name + subject) for fuzzy
        -- matching; snacks keeps the original (MRU) order when the query is empty.
        local align = picker.util.align
        picker.pick({
            source = "gitloom_refs",
            title = "Gitloom refs",
            items = items,
            layout = { preset = "select" }, -- compact, no preview window
            ---@param item { name: string, kind: string, short: string, subject: string }
            format = function(item)
                local kind_hl = ({
                    head = "SnacksPickerGitBranchCurrent",
                    ["local"] = "SnacksPickerGitBranch",
                    remote = "SnacksPickerGitBranch",
                    tag = "SnacksPickerLabel",
                })[item.kind]
                local ret = {}
                ret[#ret + 1] = { align(item.name, 28, { truncate = true }), kind_hl }
                ret[#ret + 1] = { " " }
                ret[#ret + 1] = { align(item.short, 8), "SnacksPickerGitCommit" }
                ret[#ret + 1] = { " " }
                ret[#ret + 1] = { item.subject, "SnacksPickerComment" }
                return ret
            end,
            confirm = function(p, item)
                p:close()
                if not item then return end
                recent_refs[repo_key] = bump_recent(recent_refs[repo_key], item.name)
                -- Run after the picker tears down. snacks restores focus to the
                -- window behind the float, so refocus the graph float first — else
                -- the cursor we move lands in the wrong (background) window.
                vim.schedule(function()
                    if not (gwin and vim.api.nvim_win_is_valid(gwin)) then return end
                    pcall(vim.api.nvim_set_current_win, gwin)
                    if not goto_hash(item.hash) then
                        vim.notify(
                            ("gitloom: %s is not visible (hidden?)"):format(item.name),
                            vim.log.levels.INFO)
                        return
                    end
                    -- Pre-select the picked ref's label on the landed row (§2) so
                    -- <CR>/the menu act on it with no h/l. A packed marker row
                    -- selects the marker carrying the ref; a commit / collapsed
                    -- head selects its decoration. HEAD has no label → message.
                    local line = vim.api.nvim_win_get_cursor(gwin)[1]
                    local landed = order_at(line)
                    selection_state.commit, selection_state.index = nil, nil
                    if landed and landed.type == "markers" then
                        for i, u in ipairs(marker_units(landed)) do
                            for _, r in ipairs(u.marker.refs or {}) do
                                if r.name == item.name then
                                    selection_state.commit, selection_state.index = landed, i
                                    break
                                end
                            end
                            if selection_state.commit == landed and selection_state.index == i then break end
                        end
                    elseif landed and landed.commit then
                        local idx = ref_decoration_index(landed.commit, item.name, item.kind)
                        if idx then
                            selection_state.commit, selection_state.index = landed.commit, idx
                        end
                    end
                    center_view()
                    update_cone()
                    -- Refresh first so the windowed refs (§6) are in the buffer,
                    -- then park the cursor on the now-visible selected label.
                    if lv and lv.controller then lv.controller.refresh() end
                    place_cursor()
                    -- Mark the landed row visited so the CursorMoved reset (which
                    -- fires after this) keeps our pre-selection instead of clearing
                    -- it to the message; record the remembered position (§2) too,
                    -- since that handler — which normally does — now early-returns.
                    last_line = vim.api.nvim_win_get_cursor(gwin)[1]
                    local h = cursor_hash(last_line)
                    if h then saved_positions[repo_key] = h end
                    update_panes()
                end)
            end,
        })
    end
    -- P: pin / unpin the branch under the cursor as an **anchor** (§10.6).
    -- Anchors stay normal under focus; everything else collapses. HEAD is pinned
    -- by default. Acts on the selected ref (or the region under the cursor),
    -- restricted to real refs; changes the focus default, so reflow.
    opts.win.keys.P = function(self)
        local w = self and self.win
        if not w then return end
        local line = vim.api.nvim_win_get_cursor(w)[1]
        local b = branch_under_cursor(line)
        if not b or not b.owners then return end
        -- Only refs are pinnable (v1, §10.6) — drop anonymous merge-parent owners.
        local targets = {}
        for _, oid in ipairs(b.owners) do
            if repo.refs[oid] then targets[#targets + 1] = oid end
        end
        if #targets == 0 then return end
        local want = not effective_pinned()[targets[1]]
        for _, oid in ipairs(targets) do view_state.pinned[oid] = want end
        reflow()
        update_footer()
        if b.follow then goto_hash(b.follow) end
        place_cursor()
    end
    -- i: toggle the per-lane id column before the message (main view + footer).
    opts.win.keys.i = function()
        opts.show_lane_ids = not opts.show_lane_ids
        if lv and lv.controller then
            lv.controller.refresh()
        end
        update_panes() -- re-render the footer with/without its lane-id debug column
        place_cursor()
    end
    -- F: toggle the context panes (footer) on/off.
    opts.win.keys.F = function()
        opts.panes = opts.panes == false
        update_panes() -- builds it when on, closes it when off
        place_cursor()
    end
    -- ?: float listing all keybindings.
    opts.win.keys["?"] = function()
        vim.lsp.util.open_floating_preview(help_lines(), "", {
            border = "rounded",
            focusable = true,
            -- Topmost, so it isn't hidden behind the header/footer panes.
            zindex = ZINDEX.help,
        })
    end
    -- h / l: move the ref selection on the current row (§2). Positions are the
    -- branch groups then tags (decoration_texts) plus the message (rightmost,
    -- default). Selection is held by commit identity so it follows the commit
    -- across reflow; the cursor is moved onto the selected ref (or the message).
    local selection_visible = false -- a decoration (not the message) is selected
    local function move_ref(dir)
        return function(self)
            -- While selecting (§13.3) h/l switch the followed branch instead of
            -- cycling ref decorations.
            if sel.active then selection_switch(dir); return end
            local line = vim.api.nvim_win_get_cursor(self.win --[[@as integer]])[1]
            local item, _, sub = order_at(line)
            -- On a packed marker line, selection moves among the markers (§10.4).
            if item and item.type == "markers" then
                local count = #marker_units(item)
                local pos = (selection_state.commit == item) and selection_state.index or nil
                selection_state.commit = item
                selection_state.index = move_selection(pos, count, dir)
                selection_visible = selection_state.index ~= nil
                -- The reachability cone is seeded from the selected head (§12), so a
                -- different marker means a different cone — recompute before redraw
                -- so the dimming follows the selection. Synchronous: this is a
                -- deliberate keypress, not debounced cursor drift.
                update_cone()
                if lv and lv.controller then lv.controller.refresh() end
                place_cursor()
                return
            end
            local commit = item and item.commit or nil
            if not commit then
                return
            end
            -- In dual mode the labels live on the first row only; on the message
            -- row (sub 1) there is nothing to select.
            if opts.label_mode == "dual" and sub ~= 0 then
                return
            end
            local count = #decoration_texts(commit)
            local pos = (selection_state.commit == commit) and selection_state.index or nil
            selection_state.commit = commit
            selection_state.index = move_selection(pos, count, dir)
            selection_visible = selection_state.index ~= nil
            if lv and lv.controller then
                lv.controller.refresh()
            end
            place_cursor()
        end
    end
    opts.win.keys.h = move_ref(-1)
    opts.win.keys.l = move_ref(1)

    -- Commit selection (range) mode (§13). V enters/exits; while active, j/k walk
    -- the followed branch, h/l switch branch at a junction, <C-d>/<C-u> jump a
    -- half-viewport of branch commits, o swaps ends, <CR>/D open the range. When
    -- inactive, j/k and <C-d>/<C-u> fall through to the builtin motions (fed
    -- without remap so they don't re-trigger these maps); o is a no-op.
    local function feed(keys)
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "n", false)
    end
    opts.win.keys.V = function(self)
        local w = self and self.win
        if not w then return end
        if sel.active then exit_selection() else enter_selection(vim.api.nvim_win_get_cursor(w)[1]) end
    end
    opts.win.keys["<Esc>"] = function()
        if sel.active then exit_selection() end
    end
    opts.win.keys.j = function()
        if sel.active then selection_move("down") else feed(vim.v.count1 .. "j") end
    end
    opts.win.keys.k = function()
        if sel.active then selection_move("up") else feed(vim.v.count1 .. "k") end
    end
    opts.win.keys["<C-d>"] = function()
        if sel.active then selection_page("down") else feed("<C-d>") end
    end
    opts.win.keys["<C-u>"] = function()
        if sel.active then selection_page("up") else feed("<C-u>") end
    end
    opts.win.keys.o = function()
        if sel.active then selection_swap() end
    end

    lv = listview.open(listview_options)

    -- Cursor parking (§2/§7): cursorline marks the row; the cursor rests at the
    -- commit message, or on the selected ref. place_cursor reads the rendered
    -- buffer line and positions the cursor accordingly.
    if lv and lv.win and lv.win.win then
        local win, buf = lv.win.win, lv.win.buf
        pcall(vim.api.nvim_set_option_value, "cursorline", true, { win = win })

        -- Move the cursor onto the display row that now represents `hash` — a real
        -- commit row, the marker (head/packed) whose region contains it, or a
        -- junction. Used after a collapse/expand reflow so the toggle stays put,
        -- and to focus HEAD / the remembered position on open (§2). Returns true
        -- when a row was found and the cursor moved, false otherwise.
        goto_hash = function(hash)
            if not hash then return false end
            for i, it in ipairs(repo.display or {}) do
                local found = it.commit and it.commit.hash == hash
                if not found and it.commit and it.commit.collapsed and it.commit.region then
                    for _, h in ipairs(it.commit.region) do
                        if h == hash then found = true; break end
                    end
                end
                if not found and it.type == "markers" then
                    for _, m in ipairs(it.markers or {}) do
                        if m.hash == hash then found = true; break end
                        for _, h in ipairs(m.region or {}) do
                            if h == hash then found = true; break end
                        end
                        if found then break end
                    end
                end
                if found then
                    local lnum = (lv.controller.item_start and lv.controller.item_start(i)) or i
                    pcall(vim.api.nvim_win_set_cursor, win, { lnum, 0 })
                    return true
                end
            end
            return false
        end

        place_cursor = function()
            local line = vim.api.nvim_win_get_cursor(win)[1]
            -- Commit selection (§13.2): on a packed marker line park on the
            -- selected head's label so the right head is unmistakable; otherwise
            -- park on the graph lane column so the lit lane marks the branch (the
            -- cursor row is already set by selection_redraw).
            if sel.active then
                local item = order_at(line)
                if item and item.type == "markers" and sel.cursor then
                    for _, u in ipairs(marker_units(item)) do
                        if u.marker == sel.cursor then
                            local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
                            local mcol = ref_byte_col(text, u.text)
                            if mcol then
                                pcall(vim.api.nvim_win_set_cursor, win, { line, mcol })
                                return
                            end
                            break
                        end
                    end
                end
                local col = lv and lv.controller and lv.controller.col_offset
                    and lv.controller.col_offset(line, "line", GRAPH_COL) or 0
                pcall(vim.api.nvim_win_set_cursor, win, { line, col or 0 })
                return
            end
            local item = order_at(line)
            -- A packed marker line: park on the selected marker's label (§10.4).
            if item and item.type == "markers" then
                local col = nil
                if selection_state.commit == item and selection_state.index then
                    local u = marker_units(item)[selection_state.index]
                    if u then
                        local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
                        col = ref_byte_col(text, u.text)
                    end
                end
                if not col and lv and lv.controller and lv.controller.col_offset then
                    col = lv.controller.col_offset(line, "line", FLEX_COL)
                end
                pcall(vim.api.nvim_win_set_cursor, win, { line, col or 0 })
                return
            end
            if not item or not item.commit then return end
            local col = nil
            -- A selected ref: jump onto it. The label text lives on the rendered
            -- buffer line of the current row (the label row in dual; the commit
            -- line otherwise), so find it there; if it is not on this row (e.g.
            -- the message row, or a `+N`-collapsed ref) we fall back to the flex
            -- column below.
            if selection_state.commit == item.commit and selection_state.index then
                local texts = decoration_texts(item.commit)
                if selection_state.index <= #texts then
                    local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
                    col = ref_byte_col(text, texts[selection_state.index])
                end
            end
            -- Otherwise park at the start of the flex column (message / labels).
            if not col and lv and lv.controller and lv.controller.col_offset then
                col = lv.controller.col_offset(line, "line", FLEX_COL)
            end
            pcall(vim.api.nvim_win_set_cursor, win, { line, col or 0 })
        end

        -- Center the view vertically on the cursor's row when there is room,
        -- clamped at the top/bottom of the graph (exactly `zz`'s behaviour). Used
        -- to focus HEAD / the remembered position on open (§2).
        center_view = function()
            pcall(vim.api.nvim_win_call, win, function() vim.cmd("normal! zz") end)
        end

        -- The hash of the commit under the cursor at `line`: a real commit row
        -- yields its hash; a packed marker line (§10.4) yields the selected (or
        -- first) marker's tip; any other row yields nil. Drives the remembered
        -- position (§2).
        cursor_hash = function(line)
            local item = order_at(line)
            if not item then return nil end
            if item.commit then return item.commit.hash end
            if item.type == "markers" then
                local units = marker_units(item)
                local u = units[selection_state.index] or units[1]
                if u and u.marker and u.marker.tip then return u.marker.tip.hash end
            end
            return nil
        end

        -- Recompute the pivot's cone over the visible rows and re-mark track
        -- activeness (§12). Cheap (O(visible)); the caller then refreshes. The
        -- window gives *buffer* lines; map them to order indices (a dual labelled
        -- commit spans two buffer lines) so the cone walk stays in order space.
        update_cone = function()
            local topbuf = vim.api.nvim_win_call(win, function() return vim.fn.line("w0") end)
            local botbuf = vim.api.nvim_win_call(win, function() return vim.fn.line("w$") end)
            local curbuf = vim.api.nvim_win_get_cursor(win)[1]
            local item, cur = order_at(curbuf)
            local top = select(2, order_at(topbuf))
            local bottom = select(2, order_at(botbuf))
            -- Commit selection (§13.4): the selected path is the emphasised set,
            -- replacing the cursor-pivot cone for the duration.
            if sel.active then
                view_state.cone = mark_path(top, bottom)
                return
            end
            -- A packed marker line (§10.4): the selected head drives the cone
            -- (mark_node_cone) so its branch stays lit and the siblings dim, like a
            -- normal head. No selection ⇒ neutral (everything lit).
            if item and item.type == "markers" then
                local sel_node
                if selection_state.commit == item and selection_state.index then
                    local u = marker_units(item)[selection_state.index]
                    sel_node = u and u.marker
                end
                view_state.cone = sel_node and mark_node_cone(sel_node, top, bottom) or nil
                return
            end
            -- Lanes are attached by Phase 1 (columns.layout, via build_graph /
            -- refresh_columns); walk them from the pivot to mark highlights (§12).
            if not (item and item.commit) then
                view_state.cone = nil
                return
            end
            view_state.cone = mark_reachable(repo.display, cur, top, bottom)
        end

        -- Recomputing the cone and redrawing on *every* CursorMoved makes held
        -- j/k feel sluggish on large graphs, so debounce it: each move re-arms a
        -- short timer and only the last one — once the cursor settles — does the
        -- work. The walk stays synchronous (Lua is single-threaded and the editor
        -- API isn't usable off the main loop); we just run it far less often.
        -- `applying` suppresses the WinScrolled the deferred refresh may emit. A
        -- real scroll that lands during that window is remembered in `pending` and
        -- replayed, so the footer never goes stale on a dropped scroll.
        local CONE_DEBOUNCE_MS = 60
        local cone_gen, applying, pending = 0, false, false
        local function schedule_cone_update()
            cone_gen = cone_gen + 1
            local gen = cone_gen
            vim.defer_fn(function()
                if gen ~= cone_gen or not vim.api.nvim_win_is_valid(win) then return end
                update_cone()
                applying = true
                if lv and lv.controller then lv.controller.refresh() end
                applying = false
                update_panes()
                if pending then pending = false; schedule_cone_update() end
            end, CONE_DEBOUNCE_MS)
        end

        -- Working-tree refresh (§3.4): re-read the dirty state and rebuild the
        -- virtual commits on the current HEAD anchor. It first re-resolves HEAD, so
        -- it can tell when real history has moved out from under the model
        -- ("moved") — the seam the general history resync (below) extends. Keeps
        -- the cursor on its commit across the reflow. `silent` suppresses the
        -- "history moved" notice for the automatic (write/focus) triggers.
        refresh_worktree = function(silent)
            if opts.working_tree == false then return end
            fetch_worktree_state().next(function(state)
                if not (lv and lv.win and lv.win.win and vim.api.nvim_win_is_valid(lv.win.win)) then
                    return
                end
                local keep
                local ok, pos = pcall(vim.api.nvim_win_get_cursor, lv.win.win)
                if ok then keep = cursor_hash(pos[1]) end
                local res = apply_worktree(state)
                reflow()
                update_footer()
                if keep then goto_hash(keep) end
                place_cursor()
                update_cone()
                if lv and lv.controller then lv.controller.refresh() end
                update_panes()
                if res == "moved" and not silent then
                    vim.notify("gitloom: HEAD moved — reopen to refresh history (§3.4)",
                        vim.log.levels.WARN)
                end
            end)
        end

        -- History resync (§3.4): re-read refs and reconcile the model in place so a
        -- `commit` / `fetch` / `rebase` / HEAD-moving `checkout` shows without a
        -- reopen. Snapshot the current ref tips (the rev-list exclude set) and the
        -- focused commit, then: re-read refs (non-mutating) → reconcile bindings
        -- (add/move/remove) → pull only the newly-reachable commits → link them →
        -- prune orphans → re-establish the owned order → refresh the worktree →
        -- reflow, restoring the cursor by hash and the scroll. Worktree virtuals
        -- are dropped up front and re-applied at the end. `silent` suppresses the
        -- completion notice (reserved for future automatic triggers).
        resync = function(silent)
            if not (lv and lv.win and lv.win.win and vim.api.nvim_win_is_valid(lv.win.win)) then
                return
            end

            -- What we already have: every current ref tip becomes a negative ref,
            -- so the fetch returns only commits newly reachable since this point.
            local old_tips = {}
            for _, ref in pairs(repo.refs) do
                if ref.commit then old_tips[ref.commit.hash] = true end
            end

            -- Remember the focused commit + scroll so the view holds across the
            -- rebuild (both are hash/topline based, so they survive the reflow).
            local focus
            local cok, pos = pcall(vim.api.nvim_win_get_cursor, win)
            if cok then focus = cursor_hash(pos[1]) end
            local vok, vview = pcall(vim.fn.winsaveview)
            local view = vok and vview or nil

            -- Drop the worktree virtuals during the rebuild; re-applied at the end.
            clear_worktree_nodes()

            fetch_ref_entries().next(function(res)
                reconcile_refs(res.entries, res.head)
                local new_tips, old_list = {}, {}
                for _, e in ipairs(res.entries) do new_tips[e.hash] = true end
                local new_list = {}
                for h in pairs(new_tips) do new_list[#new_list + 1] = h end
                for h in pairs(old_tips) do old_list[#old_list + 1] = h end
                return fetch_new_commits(new_list, old_list)
            end).next(function(commits)
                for _, c in ipairs(commits) do integrate_commit(c) end
                prune_to_reachable()
                return apply_sort() -- re-establish the active sort mode (§3.1)
            end).next(function()
                if opts.working_tree == false then return nil end
                return fetch_worktree_state()
            end).next(function(state)
                if not (lv and lv.win and lv.win.win and vim.api.nvim_win_is_valid(lv.win.win)) then
                    return
                end
                if state then apply_worktree(state) end
                reflow()
                update_footer()
                -- Restore the scroll first, then re-home the cursor on the focused
                -- commit (goto_hash only scrolls if its new row is off-screen).
                if view then pcall(vim.fn.winrestview, view) end
                if not (focus and goto_hash(focus)) then
                    -- The focused commit is gone (rewound away) — fall back to HEAD.
                    local headref = repo.refs["HEAD"]
                    if headref and headref.commit then goto_hash(headref.commit.hash) end
                end
                place_cursor()
                update_cone()
                if lv and lv.controller then lv.controller.refresh() end
                update_panes()
                if not silent then vim.notify("gitloom: resynced") end
            end)
        end

        -- Rebuild the dimmed highlight groups after a colorscheme change (the
        -- derived groups are wiped by `hi clear`) and redraw (§12).
        vim.api.nvim_create_autocmd("ColorScheme", {
            group = vim.api.nvim_create_augroup("GitloomDim_" .. buf, { clear = true }),
            callback = function()
                reset_dim_cache()
                reset_gen_cache()
                if lv and lv.controller then
                    lv.controller.refresh()
                end
            end,
        })

        local group = vim.api.nvim_create_augroup("Gitloom_" .. buf, { clear = true })

        -- Working-tree refresh triggers (§3.4): a buffer write (in-Neovim edit /
        -- stage) or regaining focus (the user did something in another terminal)
        -- re-reads the dirty state, debounced so rapid events coalesce into one git
        -- read. Skipped while a commit selection is active (§13) so a background
        -- write never yanks the selection out from under the user.
        local WT_DEBOUNCE_MS = 200
        local wt_gen = 0
        local function schedule_wt_refresh()
            if opts.working_tree == false then return end
            wt_gen = wt_gen + 1
            local gen = wt_gen
            vim.defer_fn(function()
                if gen ~= wt_gen or not vim.api.nvim_win_is_valid(win) then return end
                if sel.active then return end
                refresh_worktree(true) -- silent: no "history moved" notice on auto-refresh
            end, WT_DEBOUNCE_MS)
        end
        vim.api.nvim_create_autocmd("BufWritePost", {
            group = group,
            callback = schedule_wt_refresh,
        })
        vim.api.nvim_create_autocmd("FocusGained", {
            group = group,
            callback = schedule_wt_refresh,
        })

        -- On moving to a different row, reset the selection to the message,
        -- recompute the cone for the new pivot, redraw the dimming, and re-park.
        -- last_line is declared in the outer scope so a programmatic jump can
        -- pre-set the selection and suppress the reset (the ref picker, §2).
        last_line = nil
        vim.api.nvim_create_autocmd("CursorMoved", {
            group = group,
            buffer = buf,
            callback = function()
                local line = vim.api.nvim_win_get_cursor(win)[1]
                if line == last_line then return end
                last_line = line
                -- Commit selection (§13) drives the cursor and emphasis from its
                -- own handlers; skip the ref pre-select / pivot-cone path entirely.
                if sel.active then return end
                -- Remember the commit under the cursor for this repo so reopening
                -- the graph restores the position (§2). Skip rows with no commit so
                -- a marker-less line never clobbers a good remembered position.
                local h = cursor_hash(line)
                if h then saved_positions[repo_key] = h end
                local item, _, sub = order_at(line)
                -- Landing on a packed marker line pre-selects its first marker
                -- (§10.4), so h/l and <CR> act on a marker right away.
                if item and item.type == "markers" then
                    selection_state.commit = item
                    selection_state.index = (#marker_units(item) > 0) and 1 or nil
                    selection_visible = selection_state.index ~= nil
                    place_cursor()
                    schedule_cone_update()
                    return
                end
                local commit = item and item.commit or nil
                selection_state.commit = commit
                -- In dual mode landing on a labelled commit's first row (sub 0,
                -- where the labels live) pre-selects the first one (§2/§6.1); the
                -- message row and other modes default to the message (no
                -- selection).
                local auto = opts.label_mode == "dual" and sub == 0
                    and commit and #decoration_texts(commit) > 0
                selection_state.index = auto and 1 or nil
                selection_visible = auto and true or false
                -- Park the cursor now (responsive); the cone + dimming redraw is
                -- debounced so it lands once movement stops.
                place_cursor()
                schedule_cone_update()
            end,
        })

        -- Scrolling (no row change) shifts the visible window, so the
        -- window-bounded cone must be recomputed for the newly visible rows too.
        -- Scoped to this window; a guard prevents re-entry from the refresh.
        vim.api.nvim_create_autocmd("WinScrolled", {
            group = group,
            pattern = tostring(win),
            callback = function()
                if not vim.api.nvim_win_is_valid(win) then return end
                if applying then pending = true; return end -- replayed after the refresh
                schedule_cone_update()
            end,
        })

        -- Context panes (spec §6.2): two borderless overlays summarising off-screen
        -- topology folded onto the pinned anchors. The FOOTER (below) continues the
        -- bottom-seam lanes down their first-parent chains to the roots (a sub-DAG
        -- rebuild, `pane.continue`/`footer`). The HEADER (above) is a vertical
        -- compaction of the already-laid-out projection slice above the cutoff
        -- (`pane.header`): linear runs drop, junctions go node-less, heads become ◍,
        -- pinned anchors keep a labelled row. Both seed/match the seam so lanes meet
        -- the main view. (Sizing hysteresis and the async rebuild are still to come.)
        local pane = require("gitloom.graph.pane")
        local pane_ns = vim.api.nvim_create_namespace("gitloom_pane")
        -- Debug overlay (toggled with `i`): a full-line highlight on the buffer line the
        -- header treats as its cutoff/seam (and the footer's), so a misaligned seam is
        -- visible. Lives on the MAIN buffer; refreshed on every pane rebuild.
        local seam_ns = vim.api.nvim_create_namespace("gitloom_seam")
        -- GitloomCutoff: the first VISIBLE main-view line (ground truth). GitloomSeam:
        -- the line the header read its boundary from (the system's belief). They should
        -- be adjacent; a gap (or a hidden seam) means the seam is misaligned.
        vim.api.nvim_set_hl(0, "GitloomCutoff", { link = "Search", default = true })
        vim.api.nvim_set_hl(0, "GitloomSeam", { link = "DiffChange", default = true })
        local PANE_MAX = 12
        -- The header (off-screen-newer) diverges going up — its content grows ~1:1
        -- with how deep the seam is read — so it is capped tighter than the footer to
        -- stay a glanceable summary; the surplus collapses into a `+N above`.
        local HEADER_MAX = 8
        -- The two overlays: the footer (off-screen-older topology, below) and the
        -- header (off-screen-newer topology, above). Each is `{ win, buf }`.
        local footer = { win = nil, buf = nil }
        local header = { win = nil, buf = nil }
        local last_pane_err -- throttle repeated pane-error notifications
        -- Window-local scrolloff (opts.scrolloff, default 10; §8). Set explicitly so
        -- the graph window doesn't inherit the global value, which interacts badly
        -- with the context-pane overlays (§6.2). Set opts.scrolloff = 0 to restore
        -- the old behaviour if the panes' scrolling misbehaves.
        pcall(vim.api.nvim_set_option_value, "scrolloff", opts.scrolloff or 0,
            { scope = "local", win = win })
        -- Inline, node-less merge style for the pane: joins render on one row (no
        -- fan lines) and junctions draw node-less, so the pane stays compact.
        local pane_opts = vim.tbl_extend("force", {}, opts)
        pane_opts.merge_style = {
            allow_merge_on_split = false,
            merge_on_separate_line = false,
            split_on_separate_line = false,
        }

        local function close_pane(p)
            if p.win and vim.api.nvim_win_is_valid(p.win) then
                pcall(vim.api.nvim_win_close, p.win, true)
            end
            p.win = nil
        end
        -- The buffer line a seam tag (e.g. "12s"/"12c") points at.
        local function seam_line(tag) return tag and tonumber(tostring(tag):match("^(%d+)")) end
        -- Refresh the debug cutoff highlight (the `i` overlay). Two full-line marks on
        -- the MAIN buffer, cleared first so they track the view:
        --   • GitloomCutoff — the first FULLY-visible line (the topmost line of the
        --     main view, just below the header overlay): the ground truth.
        --   • GitloomFooterCutoff — the header's seam line (what the system *thinks* the
        --     cutoff is). If the two differ — or the seam line is hidden behind the
        --     overlay — the seam is misaligned (the bug we are chasing).
        local function mark_cutoff()
            pcall(vim.api.nvim_buf_clear_namespace, buf, seam_ns, 0, -1)
            if not opts.show_lane_ids then return end
            pcall(function()
                -- The header's own seam line (may sit behind the overlay).
                local hs = seam_line(header_seam)
                if hs and hs >= 1 and hs <= vim.api.nvim_buf_line_count(buf) then
                    vim.api.nvim_buf_set_extmark(buf, seam_ns, hs - 1, 0,
                        { line_hl_group = "GitloomSeam", priority = 248 })
                end
                -- The first line whose columns row is at/below the overlay's bottom edge
                -- — the topmost VISIBLE line of the main view.
                local r0 = vim.api.nvim_win_call(win, function() return vim.fn.win_screenpos(win)[1] end)
                local floor = r0 + (header_height or 0)
                local w0 = vim.api.nvim_win_call(win, function() return vim.fn.line("w0") end)
                local lastl = vim.api.nvim_buf_line_count(buf)
                for l = w0, lastl do
                    local rr = vim.api.nvim_win_call(win, function() return vim.fn.screenpos(win, l, 1).row end)
                    if rr >= floor then
                        vim.api.nvim_buf_set_extmark(buf, seam_ns, l - 1, 0,
                            { line_hl_group = "GitloomCutoff", priority = 250 })
                        break
                    end
                end
            end)
        end

        local function close_panes()
            close_pane(footer); footer_seam, footer_height = nil, nil
            close_pane(header); header_seam, header_height = nil, nil
            pcall(vim.api.nvim_buf_clear_namespace, buf, seam_ns, 0, -1)
        end

        -- A pane is a borderless overlay covering `height` content rows of the main
        -- window (relative="win"), so its lanes butt directly against the seam with
        -- no border or gap (the sticky-scroll pattern). `top` pins it to the very
        -- top (the header); otherwise the bottom (the footer). The covered main
        -- rows are exactly the off-screen topology the pane replaces with its
        -- summary.
        local function ensure_pane_win(p, top, height)
            local wh = vim.api.nvim_win_get_height(win)
            local cfg = {
                relative = "win", win = win,
                row = top and 0 or math.max(0, wh - height), col = 0,
                width = vim.api.nvim_win_get_width(win),
                height = height,
                style = "minimal",
                focusable = false,
                -- Above the graph window's content, but below the modal commit
                -- view / help float so those cover the panes.
                zindex = ZINDEX.panes,
            }
            if p.win and vim.api.nvim_win_is_valid(p.win) then
                pcall(vim.api.nvim_win_set_config, p.win, cfg)
                return
            end
            p.buf = vim.api.nvim_create_buf(false, true)
            p.win = vim.api.nvim_open_win(p.buf, false, cfg)
            -- A faint background so the pane reads as a distinct band while its
            -- lanes still line up with the main graph.
            pcall(vim.api.nvim_set_option_value, "winhl",
                "Normal:NormalFloat,NormalFloat:NormalFloat", { win = p.win })
        end

        -- Render topology-only pane rows (graph glyphs + ref labels, no
        -- date/author/message; §6.2) into the pane buffer with lane colours.
        -- Align the lanes under the main graph: in normal mode the graph starts at
        -- `goff` (the date+author width), so left-pad by it; under mirror the main
        -- graph is right-aligned at the message edge (`foff`), so right-pad so the
        -- glyphs end there.
        -- A dashed-vertical (┊) separator row: one bar per lane crossing `row`'s
        -- seam edge (`dir` = "up" for the footer's top edge, "down" for the
        -- header's bottom edge), so the eye sees each lane being continued.
        local function sep_row(row, dir)
            local sep = {}
            for j, cell in ipairs(row.columns) do
                local lane
                for _, s in ipairs(cell.lanes or {}) do
                    if s.connectivity[dir] then lane = s; break end
                end
                sep[j] = lane
                    and { connectivity = { up = true, down = true },
                        lanes = { { connectivity = { up = true, down = true }, id = lane.id, color = lane.color } } }
                    or { connectivity = {}, lanes = {} }
            end
            return sep
        end

        -- Render topology-only pane rows. `is_header` flips the layout: a footer
        -- puts its seam separator on TOP (lanes enter from the seam above, then the
        -- rows descend to the root); a header pins the tip at the TOP and the seam
        -- at the BOTTOM, padding any slack between the rows and the seam with
        -- straight lane bars so growth/shrink happens at the bottom and the tip
        -- never bounces (§6.2). `overflow` (header) renders a leading `+N above`;
        -- `height` (header) is the exact overlay height the seam was sized for.
        local function render_pane(buf, rows, goff, foff, is_header, overflow, height, overflow_names, clipped)
            local lines, marks = {}, {}
            local pal = opts.palette or {}
            -- Ref-label highlight by kind, matching the main view's ref colours.
            local label_hl = { head = pal.head, branch = pal.branch, remote = pal.remote, tag = pal.tags }
            -- Render one columns array (graph glyphs) into a padded, aligned line,
            -- recording highlight extmarks; returns the line text for suffixing.
            local function glyph_line(columns)
                local g = get_column_chars(opts, columns, false)
                -- Dash every straight run so the pane reads as a sketch/summary:
                -- vertical │ → ┊ (quadruple), horizontal ─ → ╌ (double — lighter
                -- horizontally). Both 3-byte, so highlight byte offsets are
                -- unchanged. Corners/junctions have no dashed variant, so they
                -- stay solid.
                local gtext = (g.text or ""):gsub("│", "┊"):gsub("─", "╌")
                local pad = goff or 0
                if opts.mirror then
                    -- Right-align so the glyphs end at the graph's right edge (where
                    -- the message begins); columns are adjacent, no separator.
                    pad = math.max(0, (foff or 0) - vim.api.nvim_strwidth(gtext))
                end
                local li = #lines + 1
                for _, hl in ipairs(g.highlight or {}) do
                    marks[#marks + 1] = { li - 1, pad + hl.start_pos, pad + hl.end_pos, hl.hl }
                end
                return string.rep(" ", pad) .. gtext
            end

            local function body_line(row)
                local li = #lines -- 0-based index this line will occupy (for label marks)
                local text = glyph_line(row.columns)
                local c = row.commit
                -- Ref labels in the SAME colours as the main view (HEAD, branches, tags).
                for _, seg in ipairs(c and pane_labels(c, repo.head) or {}) do
                    text = text .. " "
                    local s = #text
                    text = text .. seg.text
                    if label_hl[seg.kind] then marks[#marks + 1] = { li, s, #text, label_hl[seg.kind] } end
                end
                if c and c.collapsed and c.count then text = text .. (" (%d)"):format(c.count) end
                -- Debug (toggled by `i`): the distinct lane ids on this row.
                if opts.show_lane_ids then
                    local ids, seen = {}, {}
                    for _, col in ipairs(row.columns or {}) do
                        for _, s in ipairs(col.lanes or {}) do
                            if s.id and not seen[s.id] then seen[s.id] = true; ids[#ids + 1] = s.id end
                        end
                    end
                    if #ids > 0 then text = text .. "  [" .. table.concat(ids, ",") .. "]" end
                end
                return text
            end

            if is_header then
                local ovfrow = (overflow and overflow > 0) and 1 or 0
                if ovfrow == 1 then
                    -- Name the elided pinned anchors so off-screen branches stay visible
                    -- by name even when their ◍ heads are capped away (§6.2).
                    local tag = ("+%d above"):format(overflow)
                    if overflow_names and #overflow_names > 0 then
                        tag = tag .. ": " .. table.concat(overflow_names, ", ")
                    end
                    lines[#lines + 1] = (string.rep(" ", goff or 0)) .. tag
                end
                for _, row in ipairs(rows) do lines[#lines + 1] = body_line(row) end
                -- Pad the bottom with seam bars down to the exact overlay height, so
                -- the seam (last bar row) butts the main view's top. At least one.
                local seams = math.max(1, (height or (#rows + 1)) - ovfrow - #rows)
                if rows[#rows] then
                    local sep = sep_row(rows[#rows], "down")
                    for k = 1, seams do
                        local li = #lines
                        local sline = glyph_line(sep)
                        -- Annotate the very bottom seam row with how many buffer lines the
                        -- header clips above the seam (a comment-style note).
                        if k == seams and clipped and clipped > 0 then
                            local note = ("   … clipped %d lines …"):format(clipped)
                            local s = #sline
                            sline = sline .. note
                            marks[#marks + 1] = { li, s, #sline, "Comment" }
                        end
                        lines[#lines + 1] = sline
                    end
                end
            else
                if rows[1] then lines[#lines + 1] = glyph_line(sep_row(rows[1], "up")) end
                for _, row in ipairs(rows) do lines[#lines + 1] = body_line(row) end
            end
            if #lines == 0 then lines = { "" } end
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
            vim.api.nvim_buf_clear_namespace(buf, pane_ns, 0, -1)
            for _, m in ipairs(marks) do
                pcall(vim.api.nvim_buf_set_extmark, buf, pane_ns, m[1], m[2],
                    { end_col = m[3], hl_group = m[4] })
            end
        end

        -- Hide both panes and record why (surfaced in the `i` status).
        local function hide_all(why)
            footer_dbg, header_dbg = why, why
            close_panes()
            update_footer()
        end

        -- The pane build, wrapped so any error is fully contained — it runs inside
        -- the scroll/cone path, and must never break the main view's scrolling.
        local function build_panes()
            if opts.panes == false then return hide_all("off") end
            if not vim.api.nvim_win_is_valid(win) then return end
            -- Panes are a focus feature: need HEAD and a graph.
            if not (repo.head and repo.refs[repo.head]) then return hide_all("no HEAD") end
            if not repo.display or #repo.display == 0 then return hide_all("no display") end

            local pinned = effective_pinned()
            -- repo.order index per commit hash, for "below the cutoff" tests (footer).
            local idx = {}
            for i, it in ipairs(repo.order) do idx[it.commit.hash] = i end
            local function item_order(item)
                local c = item and item.commit
                if c then return idx[(c.tip and c.tip.hash) or c.hash] end
                local m = item and item.markers and item.markers[1]
                if m then return idx[(m.tip and m.tip.hash) or m.hash] end
            end
            -- repo.display index per commit hash, for "above the cutoff" (header).
            local didx = {}
            for i, it in ipairs(repo.display) do
                local c = it.commit
                if c then didx[(c.tip and c.tip.hash) or c.hash] = i end
                for _, m in ipairs(it.markers or {}) do didx[(m.tip and m.tip.hash) or m.hash] = i end
            end
            -- DisplayNode per hash (own/tip/region) — for resolving pinned tips and
            -- the boundary lanes' projected begins to the projected nodes (§6.2). Also
            -- each branch's main-view lane { id, color } (its first-parent lane), so
            -- the header can colour every branch the SAME as the graph (distinct per
            -- branch, not all the pivot's colour).
            -- dnode (hash → node), lane_main (hash → its branch's main-view {id,color})
            -- and node_col (hash → the COLUMN the node sits in, i.e. its left-right
            -- position in the graph) so the header can order forks to match the graph.
            local dnode, lane_main, node_col = {}, {}, {}
            for _, it in ipairs(repo.display) do
                local pl = it.parent_lanes
                local main = pl and pl[1] and { id = pl[1].id, color = pl[1].color }
                local hcol = {} -- this row's rendered nodes → their column
                for j, cell in ipairs(it.columns or {}) do
                    if cell.has_commit and cell.commit then hcol[cell.commit.hash] = j end
                end
                local function add(n)
                    if not n then return end
                    local col = hcol[n.hash]
                    dnode[n.hash] = n
                    if main then lane_main[n.hash] = main end
                    if col then node_col[n.hash] = col end
                    if n.tip then
                        dnode[n.tip.hash] = n
                        if main then lane_main[n.tip.hash] = main end
                        if col then node_col[n.tip.hash] = col end
                    end
                    for _, hh in ipairs(n.region or {}) do
                        dnode[hh] = n
                        if main then lane_main[hh] = main end
                        if col then node_col[hh] = col end
                    end
                end
                add(it.commit)
                for _, m in ipairs(it.markers or {}) do add(m) end
            end
            local function order_of(n) return n and didx[(n.tip and n.tip.hash) or n.hash] end
            local function lane_of(n) return n and lane_main[(n.tip and n.tip.hash) or n.hash] end
            local function col_of(n) return n and node_col[(n.tip and n.tip.hash) or n.hash] end

            -- The lanes crossing one edge of whichever RENDERED line sits at
            -- absolute screen row `target` — a commit's columns line, or its split
            -- (above) / merge (below) virtual line. The cutoff can fall on a
            -- split/merge virtual line, which has no buffer line, so reading the
            -- nearest buffer line's lanes was wrong. `up` reads the top edge
            -- (ascending lanes — for the header); default the bottom (footer).
            -- Returns the lanes, a debug tag, the seam's DISPLAY index (header
            -- slice), and its repo.order index (footer cutoff tests).
            local function boundary_at(target, up)
                local w0 = vim.api.nvim_win_call(win, function() return vim.fn.line("w0") end)
                local last = vim.api.nvim_win_call(win, function() return vim.fn.line("w$") end)
                for l = last, w0, -1 do
                    local r = vim.fn.screenpos(win, l, 1).row
                    if r > 0 then
                        local item, disp_idx = order_at(l)
                        -- The item's rendered block spans `r-1` (split, above), `r`
                        -- (columns), `r+1` (merge, below). The seam may fall on any.
                        if item and (r == target or (item.split and r - 1 == target)
                                or (item.merge and r + 1 == target)) then
                            if up then
                                -- HEADER: read the TOP edge of whichever rendered
                                -- sub-line of the item actually sits AT the seam (the
                                -- first *uncovered* screen row). The seam item's block
                                -- spans r-1 (split), r (columns), r+1 (merge); reading
                                -- the wrong one is an off-by-one into the COVERED region.
                                --   • merge at the seam (r+1==target): the commit row is
                                --     covered and only its merge (virtual) line shows —
                                --     read the merge's top edge (the lane up into the
                                --     commit), NOT the covered columns line above it.
                                --   • otherwise (columns/split at the seam): read the
                                --     split when present so a fork right below the
                                --     viewport shows all its off-screen children.
                                local line, suff
                                if item.merge and r + 1 == target then
                                    line, suff = item.merge, "m"
                                else
                                    line, suff = (item.split or item.columns), (item.split and "s" or "c")
                                end
                                return pane.boundary_of(line, true), l .. suff, disp_idx, item_order(item)
                            elseif r == target and item.columns then
                                return pane.boundary_of(item.columns), l .. "c", disp_idx, item_order(item)
                            elseif item.merge and r + 1 == target then
                                return pane.boundary_of(item.merge), l .. "m", disp_idx, item_order(item)
                            elseif item.split and r - 1 == target then
                                return pane.boundary_of(item.split), l .. "s", disp_idx, item_order(item)
                            end
                        end
                    end
                end
                return {}, "?"
            end

            -- The absolute screen row of the seam — the main row adjacent to an
            -- `sh`-tall overlay. Anchored on the window's own position so it is
            -- independent of w0's virtual lines. `top` (header): the row just below
            -- the top overlay; default (footer): the row just above the bottom one.
            local function seam_for(sh, top)
                return vim.api.nvim_win_call(win, function()
                    local r0 = vim.fn.win_screenpos(win)[1]
                    if top then return r0 + sh end
                    return r0 + vim.api.nvim_win_get_height(win) - sh
                end)
            end

            -- Build the footer for a seam screen row: continue ONLY the lanes
            -- crossing it down their first-parent chains to a root
            -- (`pane.continue`), condensed, seeded and laid out — every active lane
            -- reaches a root, no non-active branch introduced. Returns rows, tag on
            -- success; nil, reason on failure.
            local function build_footer(target)
                local boundary, tag, _, seam_idx = boundary_at(target)
                if not next(boundary) then return nil, "no lanes@" .. target end
                -- Pinned-ref tips below the cutoff that aren't on an active lane —
                -- add them so a divergent pinned branch still shows as a marker.
                local extra = {}
                if seam_idx then
                    for name in pairs(pinned) do
                        local ref = repo.refs[name]
                        if ref and ref.commit and (idx[ref.commit.hash] or 0) > seam_idx then
                            extra[#extra + 1] = ref.commit
                        end
                    end
                end
                local cond = pane.continue(boundary, pinned, extra, function(n) return idx[n.hash] end)
                if #cond.items == 0 then return nil, "empty graph@" .. target end
                local res = pane.footer(pane_opts, cond.items, boundary, cond.node_of_hash)
                return res.rows, tag
            end

            -- Build the HEADER for an overlay covering at least `cover` screen rows
            -- (off-screen-NEWER topology). The seam is computed from the display items
            -- directly (`pane.header_seam` — NO screenpos, so it's testable and never
            -- splits a commit across the seam: a covered commit's trailing merge line is
            -- covered with it). `pane.continue_up` then rebuilds the focused sub-DAG and
            -- `pane.header` lays it out seam-up. Returns rows, tag, actual-cover on
            -- success; nil, reason on failure. `actual cover` ≥ `cover` (rounded up to
            -- the commit boundary) is the overlay height the rows must fit in.
            local function build_header(cover)
                local w0 = vim.api.nvim_win_call(win, function() return vim.fn.line("w0") end)
                local _, w0disp = order_at(w0)
                if not w0disp or w0disp <= 1 then return nil, "at top" end
                local seam = pane.header_seam(repo.display, w0disp, cover)
                if not seam then return nil, "past end" end
                local line = (seam.kind == "split") and seam.item.split or seam.item.columns
                local boundary = pane.boundary_of(line, true)
                if not next(boundary) then return nil, "no lanes@" .. seam.idx end
                -- Pinned anchor tips above the cutoff, as the display nodes that
                -- represent them (consistent with the boundary lanes' projected begins).
                local tips = {}
                for name in pairs(pinned) do
                    local ref = repo.refs[name]
                    local dn = ref and ref.commit and dnode[ref.commit.hash]
                    if dn and (order_of(dn) or math.huge) < seam.idx then tips[#tips + 1] = dn end
                end
                local cond = pane.continue_up(boundary, tips, pinned, order_of, seam.idx)
                if #cond.items == 0 then return nil, "empty@" .. seam.idx end
                local res = pane.header(cond.items, boundary, cond.node_of_hash, lane_of, col_of)
                if #res.rows == 0 then return nil, "norows@" .. seam.idx end
                return res.rows, seam.idx .. (seam.kind == "split" and "s" or "c"), seam.cover, seam.idx
            end

            -- The footer overlay is the separator row + the footer rows, so its
            -- screen height is `#rows + 1`. Grow the row count until it stabilises
            -- (§6.2 sizing), bounded by PANE_MAX. The final rows + seam come from the
            -- SAME build so the overlay height and the boundary line up.
            local function converge_footer()
                local R, rows, seam_tag = 0, nil, nil
                for _ = 1, PANE_MAX do
                    local r, tag = build_footer(seam_for(R + 1))
                    if not r then return nil, tag end
                    rows, seam_tag = r, tag
                    local nr = math.min(#r, PANE_MAX)
                    if nr == R then break end -- converged
                    R = nr
                end
                return rows, seam_tag
            end

            -- Size the HEADER by a **min-fit search** (spec §6.2): start at the
            -- guess `cover = (#pinned tips above the viewport) + 1` screen rows, build
            -- the seam that budget implies, and grow `cover` until the folded rows fit
            -- in the overlay (the rows + the seam separator). The overlay height is the
            -- seam's actual cover (whole commit blocks, so ≥ the request). Cap at
            -- PANE_MAX, then clip continuity-preserving with `+N above`. Returns rows,
            -- tag, overlay-height, overflow.
            local function converge_header()
                local w0 = vim.api.nvim_win_call(win, function() return vim.fn.line("w0") end)
                local _, w0disp = order_at(w0)
                -- Nothing scrolled off above the viewport ⇒ no header at all.
                if (w0disp or 1) <= 1 then return nil, "at top" end
                local P = 0
                for name in pairs(pinned) do
                    local ref = repo.refs[name]
                    local di = ref and ref.commit and didx[ref.commit.hash]
                    if di and di < (w0disp or 1) then P = P + 1 end
                end
                local rows, seam_tag, height, sidx
                -- The number of buffer lines the header clips: every line above the seam (the
                -- boundary the overlay stands in for). Read straight from the line-map — the
                -- seam item's first buffer line − 1 — so it is exact and always resolvable
                -- (no order-index lookup that a junction/markers seam could miss), and it
                -- accounts for multi-line items (dual mode). Falls back to the display rows
                -- above only if the map is somehow unavailable.
                local function clipped_lines()
                    if not sidx or sidx <= 1 then return nil end
                    local start = lv.controller.item_start and lv.controller.item_start(sidx)
                    return (start and start > 1 and (start - 1)) or (sidx - 1)
                end
                -- Clamp the guess to the cap so the loop always runs at least once.
                for cover = math.min(math.max(2, P + 1), HEADER_MAX), HEADER_MAX do
                    local r, tag, actual, si = build_header(cover)
                    if not r then return nil, tag end
                    rows, seam_tag, height, sidx = r, tag, actual, si
                    if #r + 1 <= actual then return r, tag, actual, 0, nil, clipped_lines() end -- fits
                end
                if not rows then return nil, "no rows" end
                -- Didn't fit: clip to the overlay height while **preserving continuity**
                -- — keep the seam-continuous bottom slice and elide the far tips into
                -- `+N above` (room for the +N line and the seam separator). Eliding the
                -- middle instead would tear every lane at the gap (the old bug).
                local kept, ovf, ovf_names = pane.cap(rows, math.max(1, height - 2), true)
                return kept, seam_tag, height, ovf, ovf_names, clipped_lines()
            end

            -- Offsets of the main graph column so the pane lanes line up: `goff` =
            -- its left edge (date+author width), `foff` = the message edge (the
            -- graph's right side under mirror). The columns are sticky-aligned, so
            -- any visible commit row measures the same offset; use the first visible
            -- line. col_offset is in BYTES; convert to display columns via the
            -- line's text so multi-byte author names don't skew it.
            local goff, foff = 0, 0
            local refl = vim.api.nvim_win_call(win, function() return vim.fn.line("w0") end)
            if lv.controller.col_offset then
                local ltext = vim.api.nvim_buf_get_lines(buf, refl - 1, refl, false)[1] or ""
                goff = vim.fn.strdisplaywidth(ltext:sub(1, lv.controller.col_offset(refl, "line", GRAPH_COL) or 0))
                foff = vim.fn.strdisplaywidth(ltext:sub(1, lv.controller.col_offset(refl, "line", FLEX_COL) or 0))
            end

            -- FOOTER (off-screen-older topology, below).
            local frows, ftag = converge_footer()
            if not frows or #frows == 0 then
                footer_dbg = ftag or "no rows"; close_pane(footer); footer_seam, footer_height = nil, nil
            else
                frows = pane.cap(frows, PANE_MAX) -- keep the seam-nearest rows AND the root
                footer_seam, footer_height, footer_dbg = ftag, #frows + 1, nil
                ensure_pane_win(footer, false, #frows + 1)
                render_pane(footer.buf, frows, goff, foff, false)
            end

            -- HEADER (off-screen-newer topology, above). The overlay is exactly `H`
            -- tall (the height the seam was sized at), padded at the bottom so the
            -- seam butts the main view's top edge.
            local hrows, htag, H, ovf, ovf_names, hclipped = converge_header()
            if not hrows or #hrows == 0 then
                header_dbg = htag or "no rows"; close_pane(header); header_seam, header_height = nil, nil
            else
                header_seam, header_height, header_dbg = htag, H, nil
                ensure_pane_win(header, true, H)
                render_pane(header.buf, hrows, goff, foff, true, ovf, H, ovf_names, hclipped)
            end

            -- Topology-only debug dump (set `vim.g.gitloom_pane_debug` to a file path):
            -- the live seam/boundary/header-lane structure, no commit messages — for
            -- diagnosing seam alignment. Overwrites each build; never breaks the view.
            if type(vim.g.gitloom_pane_debug) == "string" then
                pcall(function()
                    local w0 = vim.api.nvim_win_call(win, function() return vim.fn.line("w0") end)
                    local _, w0disp = order_at(w0)
                    local out = { ("w0=%d w0disp=%s H=%s seam_tag=%s ovf=%s"):format(
                        w0, tostring(w0disp), tostring(H), tostring(htag), tostring(ovf)) }
                    -- The boundary the header was built from (the whole-commit seam).
                    local seam = w0disp and pane.header_seam(repo.display, w0disp, H or 2)
                    local disp_idx = seam and seam.idx
                    local boundary = seam
                        and pane.boundary_of((seam.kind == "split") and seam.item.split or seam.item.columns, true)
                        or {}
                    out[#out + 1] = ("boundary @disp=%s kind=%s:"):format(
                        tostring(disp_idx), tostring(seam and seam.kind))
                    local bcols = {}
                    for col in pairs(boundary) do bcols[#bcols + 1] = col end
                    table.sort(bcols)
                    for _, col in ipairs(bcols) do
                        local l = boundary[col]
                        local b = l.begin
                        local function hs(ns)
                            local t = {}
                            for _, n in ipairs(ns or {}) do
                                t[#t + 1] = ("%s@%s"):format(tostring(n.hash and n.hash:sub(1, 10)),
                                    tostring(order_of(n)))
                            end
                            return table.concat(t, ",")
                        end
                        out[#out + 1] = ("  col=%d id=%s color=%s begin=%s@%s up[%s] dn[%s]"):format(
                            col, tostring(l.id), tostring(l.color),
                            tostring(b and b.hash and b.hash:sub(1, 10)), tostring(b and order_of(b)),
                            b and hs(b.children) or "", b and hs(b.parents) or "")
                    end
                    -- Pinned-anchor tip resolution: whether each pinned ref resolves to a
                    -- display node ABOVE the cutoff (so it seeds the header as a labelled
                    -- head). If a tip is missing here, the header can't show that anchor.
                    out[#out + 1] = ("pinned tips (seam_idx=%s):"):format(tostring(disp_idx))
                    for name in pairs(effective_pinned()) do
                        local ref = repo.refs[name]
                        local c = ref and ref.commit
                        local dn = c and dnode[c.hash]
                        local oi = dn and order_of(dn)
                        out[#out + 1] = ("  %s -> commit=%s dnode=%s order=%s above=%s"):format(
                            name, tostring(c and c.hash), tostring(dn ~= nil),
                            tostring(oi), tostring(oi ~= nil and disp_idx ~= nil and oi < disp_idx))
                    end
                    -- The header rows (tip-on-top): per row, each cell's lane ids +
                    -- connectivity + whether it carries a node/head.
                    out[#out + 1] = ("header rows = %d (overlay H=%s):"):format(#(hrows or {}), tostring(H))
                    for ri, r in ipairs(hrows or {}) do
                        local parts = {}
                        for ci, cell in ipairs(r.columns or {}) do
                            local ids = {}
                            for _, s in ipairs(cell.lanes or {}) do
                                local c = s.connectivity or {}
                                ids[#ids + 1] = ("%s.col%s%s%s%s%s"):format(tostring(s.id), tostring(s.color),
                                    c.up and "^" or "", c.down and "v" or "", c.left and "<" or "", c.right and ">" or "")
                            end
                            local node = ""
                            if cell.has_commit and cell.commit then
                                local nm = cell.commit.refs and cell.commit.refs[1] and cell.commit.refs[1].name
                                local mv = lane_of(cell.commit)
                                local hh = cell.commit.hash
                                node = ("[%s hash=%s disp=%s gcol=%s mv=%s/%s]"):format(tostring(nm or "head"),
                                    tostring(hh and hh:sub(1, 8)), tostring(hh and didx[hh]),
                                    tostring(col_of(cell.commit)), tostring(mv and mv.id), tostring(mv and mv.color))
                            end
                            if #ids > 0 or node ~= "" then parts[#parts + 1] = ("c%d:%s%s"):format(ci, table.concat(ids, "/"), node) end
                        end
                        out[#out + 1] = ("  R%02d %s"):format(ri, table.concat(parts, "  "))
                        -- The ACTUAL rendered glyphs + per-glyph highlight group, so the
                        -- colour you SEE is captured alongside the structure.
                        local ok, g = pcall(get_column_chars, opts, r.columns, false)
                        if ok and g then
                            local hl = {}
                            for _, m in ipairs(g.highlight or {}) do
                                hl[#hl + 1] = ("%d-%d:%s"):format(m.start_pos, m.end_pos, tostring(m.hl))
                            end
                            out[#out + 1] = ("      render=[%s] %s"):format(g.text or "", table.concat(hl, " "))
                        end
                    end
                    -- The main-view display items around the seam, with their lane ids,
                    -- so the boundary can be checked against the real topology.
                    out[#out + 1] = "main display items (disp: parent_lanes | child_lanes  split/merge):"
                    local lo = math.max(1, (disp_idx or w0disp or 2) - 2)
                    local hi = math.min(#repo.display, (disp_idx or w0disp or 2) + (H or 2) + 1)
                    for di = lo, hi do
                        local it = repo.display[di]
                        if it then
                            local function ids(ls) local t = {}; for _, l in ipairs(ls or {}) do t[#t + 1] = tostring(l.id) end; return table.concat(t, ",") end
                            out[#out + 1] = ("  d%d: P[%s] | C[%s] col=%s%s"):format(di,
                                ids(it.parent_lanes), ids(it.child_lanes),
                                tostring(it.commit and col_of(it.commit)),
                                (it.split and " SPLIT" or "") .. (it.merge and " MERGE" or ""))
                        end
                    end
                    local fh = io.open(vim.g.gitloom_pane_debug, "w")
                    if fh then fh:write(table.concat(out, "\n") .. "\n"); fh:close() end
                end)
            end

            mark_cutoff()   -- refresh the debug cutoff highlight (the `i` overlay)
            update_footer() -- refresh the debug readout (cutoff lines) if `i` is on
        end

        update_panes = function()
            local ok, err = pcall(build_panes)
            if not ok then
                close_panes() -- on any pane error, hide rather than leave a bad state
                err = tostring(err)
                if err ~= last_pane_err then -- surface once per distinct error
                    last_pane_err = err
                    vim.notify("gitloom pane error: " .. err, vim.log.levels.WARN)
                end
            end
        end

        -- (The cursor is kept away from the window edges by the window-local
        -- `scrolloff` set above (opts.scrolloff) — no manual clamping needed.)

        -- Tear the panes down with the main window.
        vim.api.nvim_create_autocmd("WinClosed", {
            group = group,
            pattern = tostring(win),
            callback = close_panes,
        })

        -- No initial cone/refresh here: the fetch is async, so no commits are
        -- loaded yet. Initial dimming happens once the stream completes (above).
        place_cursor()
    end

    return lv
end


return M
