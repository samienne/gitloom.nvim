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
local navstack = require("gitloom.navstack")

-- Layout orchestration lives in the engine (gitloom.graph); the controller drives it.
local refresh_columns = graph.refresh_columns
local pack_markers = graph.pack_markers
local owners_from_refs = graph.owners_from_refs

-- Total row budget for a submodule change graph (spec §11.7.3): one row for the
-- shared ancestor, the rest split evenly between the two sides; overflow on each
-- side collapses into a "+K more" note.
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

-- Lane layout policies the viewer cycles through with `C` (spec §5.6): which
-- lanes may move sideways to close a gap. NOTE, deliberately unlike the three
-- cycles above: there is **no module-level index**. Those share one index across
-- every open graph, which is wrong for a comparison feature — the whole point is
-- to hold two repositories' windows at two different policies side by side. The
-- index is derived from `ctx.opts.layout_policy` at each keypress instead, so the
-- cycle is per-window. (The others are left alone; changing them is out of scope.)
local LAYOUT_POLICIES = {
    { name = "compact",   policy = "compact" },
    { name = "survivors", policy = "survivors" },
    { name = "linear",    policy = "linear" },
    { name = "straight",  policy = "straight" },
    { name = "gutter",    policy = "gutter" },
}

--- The cycle index of a policy id, defaulting to 1 (`compact`) for an unknown or
--- absent value — the same degrade-don't-error rule `columns.layout` applies.
---@param policy string?
---@return integer
local function layout_policy_index(policy)
    for i, p in ipairs(LAYOUT_POLICIES) do
        if p.policy == policy then return i end
    end
    return 1
end


-- Remembered cursor position per repository, keyed by the repository root
-- (repo.root, §2.1 — the repo the graph reflects). The value is the hash of the
-- commit under the cursor when the window last closed, so reopening the graph
-- restores the cursor to the same commit instead of re-focusing HEAD (spec §2).
-- In-memory for the Neovim session; not persisted to disk.
local saved_positions = {}

-- Per-repository session MRU for the ref picker (`<leader>b`, §2): the ref names
-- jumped to this session, newest first, keyed by the repository root (like
-- saved_positions). Surfaced at the top of the picker. In-memory for the session.
local recent_refs = {}

-- Tier-1 host-window registry (§14): one **host window** per repository root.
-- `sessions[root]` holds that repo's snacks window (`host`) and the closure that
-- re-establishes its view after a hide/return (`on_show`); `mru` orders the roots
-- most-recently-shown first (the `<leader>wg` return target). Opening a repo
-- already in the registry re-shows its window rather than stacking a new one.
-- A single module-level table so `M.open` references just one upvalue (it sits at
-- LuaJIT's 60-upvalue ceiling — see open_graph).
-- `examine[root]` is the repository's active Checkout & examine (§10.4.2, an
-- `ExamineState`): where Return goes back to and the stash it re-applies. Kept
-- here, not on a ctx, so it survives closing and reopening the graph (like
-- saved_positions; in-memory for the Neovim session). Also here rather than as its
-- own local: this chunk is at LuaJIT's 200-local limit.
-- `ctxs[root]` is the live session of a repository's own (root) graph, so
-- `:GitloomResetView` can reach it from outside the graph (§18.5).
local nav = { sessions = {}, mru = {}, examine = {}, ctxs = {} }

-- Run a frame's on_enter / a session's on_show. Protected, so a failing view
-- restore never aborts the navigation itself — but REPORTED: a silently
-- swallowed error here would leave no trace of a view that failed to restore.
function nav.call_enter(fn)
    local ok, err = pcall(fn)
    if not ok then
        vim.notify("gitloom: restoring the view failed: " .. tostring(err), vim.log.levels.ERROR)
    end
end

function nav.valid(sess)
    return sess ~= nil and sess.host ~= nil and sess.host.buf ~= nil
        and vim.api.nvim_buf_is_valid(sess.host.buf)
end

-- The live host window id for a repo root, or nil when there is no session or it
-- is currently hidden/gone. A frame reads it (through its own `vwin()`) to act on
-- the host only while it is actually showing that frame's buffer (§14.3).
function nav.host_win(root)
    local sess = nav.sessions[root]
    local win = sess and sess.host and sess.host.win
    if win and vim.api.nvim_win_is_valid(win) then return win end
    return nil
end

-- Hide a session's host window **safely** (§14). snacks' `hide()` is
-- `close({ buf = false })`, which deletes its scratch buffer whenever the shown
-- buffer differs from it (win.lua) — and our root (graph) frame's buffer IS that
-- scratch buffer. So while a sub-frame (a commit view) is showing, a plain hide
-- would wipe the graph buffer, fire its BufWipeout, and tear the whole session
-- down. Swap the window back to the root buffer first (a no-op when already
-- there): nothing gets wiped, and the active frame index is left untouched so the
-- return re-enters wherever the stack was (e.g. back into the commit view).
local function host_hide(sess)
    if not (sess and sess.host and sess.host.valid and sess.host:valid()) then return end
    local root_frame = sess.stack and sess.stack.frames[1]
    if root_frame and root_frame.buf and vim.api.nvim_buf_is_valid(root_frame.buf)
        and sess.host.win and vim.api.nvim_win_get_buf(sess.host.win) ~= root_frame.buf then
        pcall(function() sess.host:set_buf(root_frame.buf) end)
    end
    sess.host:hide()
end

-- Hide a repo's host window — the commit frame's `q`, mirroring the graph's `q`
-- (§14): the buffer stays in the stack for a later `<leader>wg` return.
function nav.hide(root)
    host_hide(nav.sessions[root])
end

-- Destroy a repo's host window and clear its stack (`<C-w>q`, §14.1): snacks
-- close() shuts the window and wipes the root (scratch) buffer, whose BufWipeout
-- runs nav_drop to wipe the other frame buffers and drop the session. The explicit
-- teardown vs. q's hide-and-keep.
function nav.destroy(root)
    local sess = nav.sessions[root]
    if sess and sess.host and sess.host.valid and sess.host:valid() then
        sess.host:close()
    end
end

function nav.record_mru(root)
    for i, r in ipairs(nav.mru) do
        if r == root then table.remove(nav.mru, i); break end
    end
    table.insert(nav.mru, 1, root)
end

-- Keep one host window visible at a time (§14): hide every currently-shown
-- session except `except_root` (the rest stay hidden, ready for `<leader>wg`).
function nav.hide_others(except_root)
    for r, s in pairs(nav.sessions) do
        if r ~= except_root and s.host and s.host:valid() then
            host_hide(s)
        end
    end
end

local function nav_drop(root)
    -- Wipe the non-root frame buffers (the commit views, §14.3) — the root frame
    -- IS the host buffer being destroyed, so skip it. Their own BufWipeout
    -- autocmds then tear down each frame's context overlay.
    local sess = nav.sessions[root]
    if sess and sess.stack then
        for i, f in ipairs(sess.stack.frames) do
            if i > 1 and f.buf and vim.api.nvim_buf_is_valid(f.buf) then
                pcall(vim.api.nvim_buf_delete, f.buf, { force = true })
            end
        end
    end
    nav.sessions[root] = nil
    for i, r in ipairs(nav.mru) do
        if r == root then table.remove(nav.mru, i); break end
    end
end

-- Render the breadcrumb back-trail into the host float's title (§14.6): the
-- frames root → current joined with " › ". At the root (just the graph) restore
-- the graph's own title — kept current in `sess.host.opts.title` by its status
-- machinery — rather than overwriting it with a bare repo crumb.
function nav.render_crumbs(sess)
    if not (sess and sess.stack and sess.host) then return end
    local win = sess.host.win
    if not (win and vim.api.nvim_win_is_valid(win)) then return end
    local title
    if sess.stack.idx <= 1 then
        title = (sess.host.opts and sess.host.opts.title) or ""
    else
        local crumbs = navstack.crumbs(sess.stack, function(f) return f.label or f.kind or "?" end)
        title = " " .. table.concat(crumbs, " › ") .. " "
    end
    pcall(vim.api.nvim_win_set_config, win, { title = title, title_pos = "center" })
end

-- Show `frame` in the host window (the tier-2 navigation primitive, §14.3):
-- swap the host's buffer to the frame's (snacks set_buf updates self.buf first,
-- so its fixbuf autocmd no-ops), run the frame's on_enter, refresh the trail.
local function nav_enter(sess, frame)
    if not (frame and frame.buf and vim.api.nvim_buf_is_valid(frame.buf)) then return end
    if sess.host and sess.host.valid and sess.host:valid() then
        sess.host:set_buf(frame.buf)
    end
    if frame.on_enter then nav.call_enter(frame.on_enter) end
    nav.render_crumbs(sess)
end

-- Re-show a hidden (or already-shown) session at **exactly where you were**
-- (§14.1): hide any other visible session, re-open the host (snacks show() picks
-- a fresh window id — caught by the graph's on_win hook), then re-enter the frame
-- that was active when it was hidden. nav_enter runs that frame's on_enter — the
-- graph root's IS the graph on_show (goto_hash/cone/pane rebuild), a sub-frame's
-- restores its own buffer — so `q` then `<leader>wg` lands back in the commit
-- view, not the graph. Falls back to on_show if the active frame's buffer is gone.
function nav.show(sess)
    nav.hide_others(sess.root)
    sess.host:show()
    nav.record_mru(sess.root)
    local frame = sess.stack and navstack.current(sess.stack)
    if frame and frame.buf and vim.api.nvim_buf_is_valid(frame.buf) then
        nav_enter(sess, frame)
    elseif sess.on_show then
        nav.call_enter(sess.on_show)
    end
end

--- Step back along the trail (`<C-o>`, §14.3); no-op at the root.
function nav.back(root)
    local sess = nav.sessions[root]
    if not (sess and sess.stack) then return end
    local f = navstack.back(sess.stack)
    if f then nav_enter(sess, f) end
end

--- Step forward along the trail (`<C-i>`, §14.3); no-op at the tip.
function nav.forward(root)
    local sess = nav.sessions[root]
    if not (sess and sess.stack) then return end
    local f = navstack.forward(sess.stack)
    if f then nav_enter(sess, f) end
end

--- Push a new frame (open a commit / filter / submodule, §14.3), discarding the
--- forward tail and wiping the dropped frames' buffers (the root is never
--- dropped). `frame` = `{ kind, buf, on_enter? }`.
function nav.push_frame(root, frame)
    local sess = nav.sessions[root]
    if not (sess and sess.stack) then return end
    local dropped = navstack.push(sess.stack, frame)
    for _, d in ipairs(dropped) do
        -- Never wipe the shared graph buffer: a stamped-filter frame (§16.5)
        -- reuses host.buf, so a truncated filter frame must not delete it.
        if d.buf and d.buf ~= sess.host.buf and vim.api.nvim_buf_is_valid(d.buf) then
            pcall(vim.api.nvim_buf_delete, d.buf, { force = true })
        end
    end
    nav_enter(sess, frame)
end

-- Install the tier-2 navigation keys on a frame's buffer (§14.3): `<C-o>` steps
-- back along the trail, `<C-i>` steps forward. `<C-i>` is `<Tab>` in a terminal,
-- which used to be the collapse/expand toggle (§10.4) — that moved to `<Space>`
-- precisely to free `<C-i>` for forward navigation everywhere.
--
-- They are **hybrid** (like the commit view's, §11.4): first walk the **in-buffer
-- jumplist** — so `<C-o>` returns to where you were before an in-graph jump (a
-- filter `<CR>`, a ref-pick), the natural Vim feel — and only pop / push the view
-- stack once the jumplist would leave this buffer. j/k don't add to the jumplist,
-- so it holds only real jumps.
function nav.install_nav_keys(buf, root)
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
    local function termcodes(k) return vim.api.nvim_replace_termcodes(k, true, false, true) end
    vim.keymap.set("n", "<C-o>", function()
        local jl = vim.fn.getjumplist()
        local list, curidx = jl[1], jl[2]
        local target = (curidx >= 1) and list[curidx] or nil
        if target and target.bufnr == buf then
            vim.api.nvim_feedkeys(termcodes("<C-o>"), "n", false) -- in-buffer jump back
        else
            nav.back(root)
        end
    end, { buffer = buf, nowait = true, silent = true, desc = "Gitloom: back (§14)" })
    vim.keymap.set("n", "<C-i>", function()
        local jl = vim.fn.getjumplist()
        local list, curidx = jl[1], jl[2]
        -- getjumplist: list[idx] is the <C-o> target, list[idx+1] the *current*
        -- position, list[idx+2] the <C-i> forward target (verified empirically).
        local target = list[curidx + 2]
        if target and target.bufnr == buf then
            vim.api.nvim_feedkeys(termcodes("<C-i>"), "n", false) -- in-buffer jump forward
        else
            nav.forward(root)
        end
    end, { buffer = buf, nowait = true, silent = true, desc = "Gitloom: forward (§14)" })
end

function nav.register(root, host, on_show)
    nav.sessions[root] = {
        host = host,
        root = root,
        on_show = on_show,
        -- The view stack (§14.3), seeded with the graph as its root frame (its
        -- crumb is the repo name; its on_enter is the graph's on_show, so a
        -- `<C-o>` / `<leader>wg` return to it rebuilds the cursor/cone/panes).
        stack = navstack.new({ kind = "graph", buf = host.buf,
            label = vim.fn.fnamemodify(root, ":t"), on_enter = on_show }),
    }
    nav.record_mru(root)
    nav.install_nav_keys(host.buf, root)
    -- `<C-w>q` destroys the window via snacks close(), which wipes the scratch
    -- buffer; drop the session then so the next open rebuilds rather than
    -- re-showing a dead window. hide() keeps the buffer, so this only fires on a
    -- real close/wipe, not on a hide/return.
    if host.buf then
        vim.api.nvim_create_autocmd("BufWipeout", {
            buffer = host.buf,
            once = true,
            callback = function() nav_drop(root) end,
        })
    end
end

-- Column indices in a row's `line` field: date, author, graph, message
-- (specification.md §6; see listview's build_line). Grouped into one table so the
-- big open_graph closure captures a single upvalue rather than four (LuaJIT's
-- 60-upvalue ceiling — see open_graph). `flex` (message) fills the remaining width
-- with refs pinned right; `author` gets a sticky `author_max` cap so it only grows
-- and doesn't bounce as names scroll past; `graph` is sticky under mirroring so the
-- right-aligned graph + message don't shift as the lane width changes.
local COL = { flex = 4, author = 2, author_max = 25, graph = 3 }

-- Floating-window z-order (spec §2.1/§14). With the single-window model there is
-- exactly **one host window** per repo on screen at a time (frames swap its
-- buffer; other repos' hosts are hidden), so there is no stack to climb — just a
-- bounded set of layers over that one host: its **overlays** (the context panes
-- and the commit-view sticky header) and the **transient floats** (`?`/`K`, the
-- pickers). Each is a fixed delta above the host's **live** zindex — the host can
-- hide and re-show with a new id (§14), so always read it. Larger = nearer the user.
--
-- The host is CREATED at `opts.zindex` (default Z_HOST = 41): a full-screen app
-- window, so it sits above ordinary windows' float decorations (treesitter-context
-- 20, scrollbars ~40) but below other plugins' floats (fidget / oil / mason 44–45,
-- pickers / vim.ui.select / notifications 50+). The whole stack is 41 / 42 / 43,
-- and floats gitloom does not own keep their own zindex.
local Z_HOST    = 41  -- the host window itself (the `zindex` option's default; §8)
local Z_OVERLAY = 1   -- panes + the commit-view sticky header, just above the host
local Z_FLOAT   = 2   -- gitloom's transient floats (`?`/`K`, its pickers), above the overlays

-- The host window's live zindex (its current config), defaulting to Z_HOST.
---@param host_win integer?
local function host_zindex(host_win)
    local z = host_win and vim.api.nvim_win_get_config(host_win).zindex
    return z or Z_HOST
end
-- An overlay sits just above the host; a transient float above the overlays.
---@param host_win integer?
local function overlay_zindex(host_win) return host_zindex(host_win) + Z_OVERLAY end
---@param host_win integer?
local function float_zindex(host_win) return host_zindex(host_win) + Z_FLOAT end

-- The graph window footer: live status (the current mode, and whether the graph
-- is mirrored) plus a hint to the help float.
---@param mirror boolean?
---@param modes table<string, string>?  -- explicit branch-mode overrides (§10)
---@param focus boolean?  -- the first-parent focus default is on (§10.7)
---@param sort_label string?  -- the active sort mode's label (§3.1)
---@param layout_label string?  -- the active layout policy id (§5.6)
local function footer_text(mirror, modes, focus, nanchors, sort_label, track_str, layout_label)
    local status = ("Mode: %s | Refs: %s"):format(
        MERGE_STYLES[merge_style_index].name, LABEL_MODES[label_mode_index].name)
    if sort_label then
        status = status .. " | Sort: " .. sort_label
    end
    -- The layout policy (§5.6) shows only when it is NOT the default, so the
    -- ordinary footer is unchanged and a non-default policy is always visible —
    -- the same rule as `(mirrored)` and the collapsed/hidden counts below.
    if layout_label and layout_label ~= "compact" then
        status = status .. " | Layout: " .. layout_label
    end
    -- Current branch's upstream divergence (§6.3), e.g. "master ⇡2⇣3" / "… gone";
    -- omitted when in sync or untracked.
    if track_str and track_str ~= "" then
        status = status .. " | " .. track_str
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

-- Reserved sentinel hashes for the working-tree virtual commits (§4.2), keyed by
-- `Commit.virtual`: values git never produces for a real object, so every
-- hash-keyed path keeps working. One table, not four locals (the 200-local limit).
local WORKTREE_HASH = {
    unstaged = "0000000000000000000000000000000000000000",
    staged = "0000000000000000000000000000000000000001",
    untracked = "0000000000000000000000000000000000000002",
    clean = "0000000000000000000000000000000000000003",
}

-- Working-tree I/O (state + diffs, §3.3) now lives in gitloom.git.fetch.
local fetch_worktree_state = git.fetch_worktree_state
local fetch_worktree_diff = git.fetch_worktree_diff

-- The `git status --porcelain` counter (§3.3) lives in gitloom.git.parse; kept
-- aliased for the graph._internal test seam.
local parse_status = git.parse_status

-- DiffRange builders (§11.5, §13.5) now live in gitloom.git.range.
local commit_range = git.commit_range
local range_endpoints = git.range_endpoints

--- Default diff provider: open diffview for the range (specification.md §11.5),
--- in the range's repository (`range.root`, §2.1) — NOT Neovim's cwd, which
--- diffview would otherwise resolve against. Guarded — reports rather than errors
--- when diffview is not installed. Override opts.diff.open to use another plugin.
---@param range DiffRange
local function open_diffview(range)
    -- diffview is usually lazy-loaded; requiring it triggers the load (a no-op
    -- if already loaded). Its Lua `open(args)` is what `:DiffviewOpen` calls,
    -- and taking an argv LIST means the root needs no Ex-command-line escaping
    -- (spaces, `%`, `#`, `|` in a path would otherwise be split or expanded).
    local ok, dv = pcall(require, "diffview")
    if not (ok and type(dv) == "table" and type(dv.open) == "function") then
        vim.notify("diffview.nvim not found; set diff.open to use another diff plugin",
            vim.log.levels.ERROR)
        return
    end
    dv.open(git.diffview_args(range))
end

--- Open the configured external diff (§11.5) for a commit of the repository at
--- `root`: build its DiffRange and hand it to the provider. No-op when no
--- provider is configured.
---@param opts GraphOptions
---@param commit Commit
---@param root? string  the graph's repository root (§2.1), stamped on the range
local function open_diff(opts, commit, root)
    local open = opts.diff and opts.diff.open
    if open then
        open(commit_range(commit, root))
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

-- Repository picker I/O (§2.1): list a repo's direct submodules and summarize a
-- repo for a picker row. Used by M.pick.
local fetch_submodules = git.fetch_submodules
local fetch_repo_summary = git.fetch_repo_summary

-- Resolve the repository root the graph targets (spec §2.1): the given `folder`
-- or Neovim's cwd, normalized to its git top level so opening from a subdir
-- keys the per-repo session state consistently. Falls back to the raw path when
-- not inside a git repo (a synchronous one-shot at open / pick time).
---@param folder string?
---@return string
local function resolve_root(folder)
    local base = folder or vim.fn.getcwd()
    local top = vim.fn.systemlist({ "git", "-C", base, "rev-parse", "--show-toplevel" })[1]
    top = top and top:gsub("%s+$", "") -- strip a trailing CR/newline (Windows)
    return (vim.v.shell_error == 0 and top and top ~= "") and top or base
end

-- Default marker colours for the submodule change view (§11.7): a deliberately
-- darker, muted green/red (ForestGreen / Firebrick) — brighter diff groups like
-- DiffAdd/Added read pastel. `default = true` so a colorscheme (or the palette's
-- submodule.new/old override) wins; idempotent, re-asserted on each render so a
-- late ColorScheme can't leave them undefined.
local function ensure_submodule_hl()
    pcall(vim.api.nvim_set_hl, 0, "GitloomSubmoduleAdd", { fg = "#3a7d34", ctermfg = 28, default = true })
    pcall(vim.api.nvim_set_hl, 0, "GitloomSubmoduleDel", { fg = "#b03a3a", ctermfg = 124, default = true })
end

--- Render one submodule change's fetched `result` (spec §11.7) into commit-view
--- rows (compose-style `{ text, highlight }`), replacing the raw `Subproject
--- commit` pair. `result` may be nil (not yet fetched) — then the raw hashes are
--- shown, upgraded in place once the fetch resolves (§11.7.4).
---
--- When the gate passes the block is a small **two-lane change graph** (a Y): the
--- commits the bump **added** (`base..new`, green) descend from the new pointer
--- `B`, the commits it **removed** (`base..old`, red) descend from the old pointer
--- `A`, both converging at their shared **ancestor** node (the merge-base, drawn
--- in the first lane colour). A fast-forward / rewind is the degenerate case where
--- one side is empty and the ancestor *is* the coinciding pointer. The lanes carry
--- semantic colour, so this hand-draws the (always linear, first-parent) topology
--- rather than running the free-list lane engine.
---@param opts GraphOptions
---@param change { path: string, old: string, new: string }
---@param result table?
---@return table[] rows
---@return table<integer, string> row_hashes  -- block-row index -> commit hash (§11.7.6)
local function submodule_block(opts, change, result)
    local palette = opts.palette or {}
    local diffp = palette.diff or {}
    ensure_submodule_hl()
    local subp = palette.submodule or {}
    local new_hl = subp.new or "GitloomSubmoduleAdd"                       -- added (dark green fg)
    local old_hl = subp.old or "GitloomSubmoduleDel"                       -- removed (dark red fg)
    local base_hl = subp.base or (palette.tracks and palette.tracks[1]) or "Title" -- ancestor (lane 1)
    local rows = {}
    -- Parallel to `rows`: the **full** commit hash for each commit row (nil for
    -- header / elision / unavailable rows), so the commit view can make each
    -- commit line a link into the submodule's repo (§11.7.6).
    local row_hashes = {}
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
        return rows, row_hashes
    end

    -- Header: path, old → new, and the direction/counts. The ahead (`+N`) and
    -- behind (`−N`) tokens take the added/removed colours so they match the graph.
    local ahead = highlight_text(("+%d"):format(result.ahead), new_hl)
    local behind = highlight_text(("−%d"):format(result.behind), old_hl)
    local header = {
        highlight_text("  submodule ", palette.author),
        highlight_text(change.path, diffp.header),
        highlight_text(("  %s → %s  "):format(short(change.old), short(change.new)), palette.date),
        highlight_text("(", palette.branch),
    }
    if result.class == "ff" then
        header[#header + 1] = ahead
    elseif result.class == "rewind" then
        header[#header + 1] = behind
    else
        header[#header + 1] = highlight_text("diverged ", palette.branch)
        header[#header + 1] = ahead
        header[#header + 1] = highlight_text(" / ", palette.branch)
        header[#header + 1] = behind
    end
    header[#header + 1] = highlight_text(")", palette.branch)
    rows[#rows + 1] = compose(header)

    -- Truncate each side to its even share of the height budget, spilling an
    -- empty/short side's room to the other (§11.7.3). The pointer head (newest) is
    -- always kept; the dropped commits are the middle, shown as a "+K more" marker.
    local budget = submodule.split_budget(SUBMODULE_MAX, #(result.new_commits or {}), #(result.old_commits or {}))
    local new_kept, new_drop = submodule.truncate(result.new_commits or {}, budget.new)
    local old_kept, old_drop = submodule.truncate(result.old_commits or {}, budget.old)
    local base_commit = result.base_commit or { hash = result.base }
    -- Two lanes only when both sides have commits (diverged); otherwise a single
    -- lane down to the ancestor, which then *is* the opposite pointer (ff → old,
    -- rewind → new).
    local two = #new_kept > 0 and #old_kept > 0
    local base_tag = (result.class == "ff" and "old") or (result.class == "rewind" and "new") or nil

    -- A gutter cell is { ch, hl }; a row is the indent + gutter + commit info. The
    -- gutter glyphs (markers and lanes) and the commit **hash** carry the semantic
    -- green / red / ancestor colour (`hl`); the subject stays neutral so the
    -- message reads normally rather than tinted like a diff.
    local function emit(cells, c, tag, hl)
        local segs = { highlight_text("    ", nil) }
        for _, cell in ipairs(cells) do segs[#segs + 1] = highlight_text(cell.ch, cell.hl) end
        segs[#segs + 1] = highlight_text("  " .. short(c.hash), hl)
        if tag then segs[#segs + 1] = highlight_text(" ◀ " .. tag, palette.head) end
        if c.deco and c.deco ~= "" then segs[#segs + 1] = highlight_text(" " .. c.deco, palette.branch) end
        if c.message and c.message ~= "" then segs[#segs + 1] = highlight_text("  " .. c.message, palette.message) end
        rows[#rows + 1] = compose(segs)
        row_hashes[#rows] = c.hash -- this buffer row links to commit c (§11.7.6)
    end
    local function elide(cells, n)
        local segs = { highlight_text("    ", nil) }
        for _, cell in ipairs(cells) do segs[#segs + 1] = highlight_text(cell.ch, cell.hl) end
        segs[#segs + 1] = highlight_text(("  … +%d more"):format(n), DIM_FALLBACK)
        rows[#rows + 1] = compose(segs)
    end

    -- The new (added) side, top-down from B. In the two-lane case its lane keeps
    -- running (`│`) past the old side's rows down to the ancestor.
    local new_node = { ch = "●", hl = new_hl }
    local new_pipe = { ch = "│", hl = new_hl }
    local blank = { ch = " ", hl = nil }
    for i, c in ipairs(new_kept) do
        emit(two and { new_node, blank } or { new_node }, c, i == 1 and "new" or nil, new_hl)
    end
    if new_drop > 0 then elide(two and { new_pipe, blank } or { new_pipe }, new_drop) end

    -- The old (removed) side, top-down from A. In the two-lane case it sits in the
    -- second column while the new lane passes alongside in the first.
    local old_node = { ch = "●", hl = old_hl }
    local old_pipe = { ch = "│", hl = old_hl }
    for i, c in ipairs(old_kept) do
        emit(two and { new_pipe, old_node } or { old_node }, c, i == 1 and "old" or nil, old_hl)
    end
    if old_drop > 0 then elide(two and { new_pipe, old_pipe } or { old_pipe }, old_drop) end

    -- The shared ancestor: the convergence node. In the two-lane case the old lane
    -- bends into it (`╯`); single-lane, it is just the bottom node, marked with the
    -- pointer it coincides with.
    emit(two and { { ch = "●", hl = base_hl }, { ch = "╯", hl = old_hl } }
        or { { ch = "●", hl = base_hl } }, base_commit, base_tag, base_hl)
    return rows, row_hashes
end

local commit_view_ns = vim.api.nvim_create_namespace("gitloom.commit_view")

--- The §11.2.1 message wrap width for window `win`: its text area (the width
--- minus the sign / number / fold columns), capped by `git.message_width`. nil
--- for no valid window, which renders the message as is. A field on M, not a
--- module local (window.lua is at LuaJIT's 200-local ceiling).
---@param win? integer
---@return integer?
function M.commit_wrap_width(win)
    if not (win and vim.api.nvim_win_is_valid(win)) then return nil end
    local info = vim.fn.getwininfo(win)[1]
    if not info then return nil end
    return git.message_width(info.width - info.textoff)
end

--- Build the commit-view content rows (spec §11.2) — the list of compose
--- `{ text, highlight }` rows plus the per-render index maps — for a single
--- commit, a working-tree commit, or a range, **independent of any window or
--- buffer**. The commit view (open_commit_view) renders these into its
--- host-window frame; the commit-search preview (§15.3) renders the same rows
--- into the picker's preview buffer, so the two never drift.
---
--- All index maps are keyed by **1-based row index** within the returned `rows`
--- (the caller adds them to whatever buffer offset it writes at). `spec` fields:
---   commit?       Commit   single-commit / working-tree mode
---   range?        table    range mode (§13.5): { commits, range, title }
---   meta?         string   `git show -s` output for `commit` (real commits)
---   diff?         string   patch (`git show -p` / range diff), or nil
---   diff_error?   string   the git failure that replaced the patch (§13.5), or nil
---   sub_results?  table    per-path submodule change results (§11.7), or {}
---   root?         string   parent repo root; enables submodule commit links
---   action?       boolean  include the diff action label (§11.5); default true
---   width?        integer  the message wrap width (§11.2.1); nil = as is
---@param opts GraphOptions
---@param spec table
---@return table[] rows
---@return table info  -- { action_line?, file_jumps, sub_jumps, diff_ctx?, diff_start?, diff_buf_to_patch?, meta_end }
local function build_commit_rows(opts, spec)
    local commit, range, root = spec.commit, spec.range, spec.root
    local sub_results = spec.sub_results or {}
    local file_jumps, sub_jumps = {}, {}
    local action_line = nil
    local diff_ctx, diff_start, diff_buf_to_patch = nil, nil, nil

    local rows = {}
    -- Diff action label as the first line (§11.5), when a provider is set and the
    -- caller wants it (the preview suppresses it — it is not actionable there).
    if spec.action ~= false and opts.diff and opts.diff.open then
        rows[#rows + 1] = highlight_text(opts.diff.label or "▶ Open diff", opts.palette.action)
        action_line = #rows
        rows[#rows + 1] = highlight_text("")
    end
    -- Metadata: the selected-commit list in range mode (§13.5), the working-tree
    -- state header for a virtual commit (§11.8), else the single commit's detail.
    local meta_rows
    if range then
        meta_rows = format_range_detail(range.commits, opts.palette)
    elseif commit and commit.virtual then
        meta_rows = format_worktree_detail(commit, opts.palette)
    else
        ---@cast commit Commit
        meta_rows = format_commit_detail(parse_show(spec.meta), {
            -- No pin marks in the commit view; only the §6.3 upstream glyph.
            decorations = decoration_texts(commit, nil, { set = {}, upstream_icon = opts.icons and opts.icons.upstream }),
            palette = opts.palette,
            width = spec.width, -- the message wrap width (§11.2.1)
        })
    end
    for _, r in ipairs(meta_rows) do
        rows[#rows + 1] = r
    end
    -- The last metadata row: a re-wrap (§11.2.1) shifts only what lies below it.
    local meta_end = #rows

    -- A git failure the fetch reported (§13.5): say so where the patch would be,
    -- so an empty diff region is never mistaken for "no changes in this range".
    if spec.diff_error and spec.diff_error ~= "" then
        rows[#rows + 1] = highlight_text("")
        rows[#rows + 1] = highlight_text(spec.diff_error, "ErrorMsg")
    end

    -- `git show --format=` prints a leading blank line; drop it.
    local patch = (spec.diff or ""):gsub("^%s+", "")
    if patch ~= "" then
        local files = diffstat_files(patch)
        rows[#rows + 1] = highlight_text("")
        local stat_start = #rows + 1 -- row of the diffstat summary
        for _, r in ipairs(format_diffstat(files, opts.palette)) do
            rows[#rows + 1] = r
        end
        rows[#rows + 1] = highlight_text("")
        diff_start = #rows + 1 -- row of the first patch line

        -- Submodule change blocks (§11.7): replace each `Subproject commit` pair
        -- with its change graph. Splicing shifts rows, so build patch<->row maps
        -- for the file-jump and context-header lookups rather than the plain 1:1
        -- offset (which holds only with no splice).
        local diff_rows = format_diff(patch, opts.palette)
        local repl = {} -- from_line -> { to_line, rows, hashes, path, old, new }
        for _, ch in ipairs(submodule.parse_changes(patch)) do
            local block_rows, block_hashes = submodule_block(opts, ch, sub_results[ch.path])
            repl[ch.from_line] = {
                to_line = ch.to_line,
                rows = block_rows,
                hashes = block_hashes, -- block-row index -> commit hash (§11.7.6)
                path = ch.path,
                old = ch.old, -- the bump's pointers, marked on open (§11.7.6)
                new = ch.new,
            }
        end
        local patch_to_buf, buf_to_patch = {}, {}
        local pi = 1
        while pi <= #diff_rows do
            local r = repl[pi]
            if r then
                local at = #rows + 1 -- row of the block's first line
                for bi, br in ipairs(r.rows) do
                    rows[#rows + 1] = br
                    buf_to_patch[#rows] = pi -- block lines govern by the file's region
                    -- A commit row becomes a link to that commit in the submodule's
                    -- repo (root + the relative path; §11.7.6) — only when linking.
                    if root and r.hashes[bi] then
                        sub_jumps[#rows] = { repo = root .. "/" .. r.path,
                            hash = r.hashes[bi], old = r.old, new = r.new }
                    end
                end
                for k = pi, r.to_line do patch_to_buf[k] = at end
                pi = r.to_line + 1
            else
                rows[#rows + 1] = diff_rows[pi]
                patch_to_buf[pi], buf_to_patch[#rows] = #rows, pi
                pi = pi + 1
            end
        end

        -- Summary sits at stat_start; file j at stat_start + j. Its diff section
        -- starts where its `diff --git` line landed (identity when nothing spliced).
        for j, f in ipairs(files) do
            file_jumps[stat_start + j] = patch_to_buf[f.start] or (diff_start + f.start - 1)
        end
        -- Context-header lookup over the same patch (§11.6); when a block was
        -- spliced the rows are no longer 1:1 with the patch, so keep the inverse map.
        diff_ctx = diff_contexts(patch)
        if next(repl) then diff_buf_to_patch = buf_to_patch end
    end

    return rows, {
        action_line = action_line,
        file_jumps = file_jumps,
        sub_jumps = sub_jumps,
        diff_ctx = diff_ctx,
        diff_start = diff_start,
        diff_buf_to_patch = diff_buf_to_patch,
        meta_end = meta_end,
    }
end
-- Exposed on the module so the search picker (§15.3) can reach it directly.
M.build_commit_rows = build_commit_rows

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
---@param root? string  -- the graph's repo root, to resolve submodule link paths (§11.7.6)
local function open_commit_view(opts, commit, range, root)
    local title
    if range then
        title = range.title
    else
        ---@cast commit Commit
        title = "Commit " .. commit.hash:sub(1, 7)
    end

    -- The commit view is a navigation-stack **frame** in the repo's single host
    -- window (§14.3), not its own float: a scratch buffer the host swaps in. It
    -- stays alive while off-screen (kept by the view stack) so `<C-o>`/`<C-i>`
    -- can revisit it; the frame is pushed at the end, once its keymaps are bound.
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
    -- Name it like the graph buffer (§2, §11), so a GUI title (Neovide) shows
    -- the repo path here too. pcall: a duplicate (E95, the same commit opened
    -- twice) just leaves this buffer unnamed.
    if root then
        pcall(vim.api.nvim_buf_set_name, buf, git.commit_view_buf_name(root, title))
    end

    -- The host window IFF it is currently showing this frame's buffer (§14.3):
    -- nil when the user has navigated to another frame or hidden the host, so the
    -- window ops below no-op cleanly instead of touching the wrong buffer.
    local function vwin()
        local win = nav.host_win(root)
        if win and vim.api.nvim_win_get_buf(win) == buf then return win end
        return nil
    end

    -- Maps a diffstat file row's buffer line -> the buffer line where that
    -- file's diff section begins. Rebuilt on each render; <CR> jumps by it.
    local file_jumps = {}
    -- Maps a submodule change-graph commit row's buffer line -> { repo, hash }:
    -- the submodule's repo path and the commit on that row, so <CR> there opens
    -- the submodule's graph focused on that commit (§11.7.6). Rebuilt each render.
    local sub_jumps = {}
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
        local vw = vwin()
        if not vw then return end
        local line = vim.api.nvim_win_get_cursor(vw)[1]
        if action_line and line == action_line then
            if range then
                if opts.diff and opts.diff.open then opts.diff.open(range.range) end
            else
                ---@cast commit Commit
                open_diff(opts, commit, root)
            end
            return
        end
        -- A submodule change-graph commit row: drill into that submodule's graph
        -- focused on the commit under the cursor (§11.7.6) — a navigation-stack
        -- frame in THIS host window (§14.7), so <C-o> returns here. `root` is the
        -- parent repo whose host window holds this commit frame.
        local jump = sub_jumps[line]
        if jump then
            -- Mark both bump pointers in the drilled-in submodule graph (§11.7.6) as
            -- synthetic pinned `new`/`old` refs — the new pointer green, the old
            -- red (the change view's colours) — revealed + labelled in the panes,
            -- focused on the clicked commit.
            local subp = (opts.palette or {}).submodule or {}
            local seed = {}
            if jump.new then
                seed[#seed + 1] = { hash = jump.new, name = "new", hl = subp.new or "GitloomSubmoduleAdd" }
            end
            if jump.old then
                seed[#seed + 1] = { hash = jump.old, name = "old", hl = subp.old or "GitloomSubmoduleDel" }
            end
            if root then
                M.drill_submodule(root, jump.repo, opts, jump.hash, seed)
            else
                M.open(jump.repo, opts, jump.hash, seed)
            end
            return
        end
        local target = file_jumps[line]
        if target then
            vim.api.nvim_win_call(vw, function()
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
            nav.back(root)
        end
    end, { buffer = buf, nowait = true, silent = true })

    -- <C-i> mirrors it forward: walk the jumplist forward through the view's own
    -- jumps, then — once the next forward target would leave the commit view
    -- (another buffer, or none) — step forward along the view stack (§14.3).
    -- `<C-i>` is `<Tab>`; collapse/expand moved to `<Space>` (§10.4) to free it.
    vim.keymap.set("n", "<C-i>", function()
        local jl = vim.fn.getjumplist()
        local list, curidx = jl[1], jl[2]
        -- The forward target is list[idx+2] (idx = <C-o> target, idx+1 = current).
        local target = list[curidx + 2]
        if target and target.bufnr == buf then
            vim.api.nvim_feedkeys(
                vim.api.nvim_replace_termcodes("<C-i>", true, false, true), "n", false)
        else
            nav.forward(root)
        end
    end, { buffer = buf, nowait = true, silent = true })

    -- q hides the host window (mirroring the graph's q, §14); the frame's buffer
    -- stays in the stack for a later `<leader>wg` return.
    vim.keymap.set("n", "q", function() nav.hide(root) end,
        { buffer = buf, nowait = true, silent = true })

    -- Diff context header (§11.6): a borderless overlay pinned to the top of the
    -- view showing the governing file / hunk while the diff is scrolled past
    -- their real header lines. It tracks the viewport top, not the cursor, and
    -- materializes only when there is something to stick (else it is closed).
    local diff_pal = (opts.palette or {}).diff or {}
    local ctx_win, ctx_buf = nil, nil
    -- The view's scroll/cursor, saved when the frame is navigated away from so a
    -- later return restores it (§14.3); nil until first left.
    local saved_pos = nil

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
        local vw = vwin()
        if not (diff_ctx and vw) then
            close_ctx()
            return
        end
        -- The overlay covers the top `#rows` rows, so the first row the user
        -- actually reads is the window top advanced past it (§11.6). That offset
        -- depends on the count we are computing, so settle it with a short
        -- fixpoint (the height is 0–2; this converges in a step or two).
        local top = vim.fn.line("w0", vw)
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
            relative = "win", win = vw,
            row = 0, col = 0,
            width = vim.api.nvim_win_get_width(vw),
            height = #rows,
            style = "minimal",
            focusable = false,
            -- Just above the host window itself (its sticky-scroll header).
            zindex = overlay_zindex(vwin()),
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

    -- The overlay's lifetime follows the buffer's presence in the host window now,
    -- not a float closing (§14.3). WinScrolled/WinResized refresh it while the host
    -- shows this frame; BufWinEnter/BufWinLeave rebuild it / tear it down as the
    -- frame is shown/hidden by navigation (BufWinLeave also stashes the scroll for
    -- a later return); BufWipeout (the frame dropped from the stack) drops the
    -- group entirely.
    local ctx_group = vim.api.nvim_create_augroup("GitloomCommitCtx_" .. buf, { clear = true })
    -- Re-wrap the message when the window's width changed (§11.2.1); defined
    -- once render() exists, below.
    local rewrap = function() end
    vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized" }, {
        group = ctx_group,
        callback = function()
            -- Global (it must catch scrolls in the host window); when the host is
            -- not showing this frame, vwin() is nil and update_ctx closes the
            -- overlay instead of touching the wrong window.
            if vwin() then
                rewrap()
                update_ctx()
            else
                close_ctx()
            end
        end,
    })
    -- A resized editor resizes the host float in snacks' own VimResized handler;
    -- re-wrap after it (§11.2.1).
    vim.api.nvim_create_autocmd("VimResized", {
        group = ctx_group,
        callback = function() vim.schedule(function() rewrap() end) end,
    })
    vim.api.nvim_create_autocmd("BufWinEnter", {
        group = ctx_group,
        buffer = buf,
        callback = function() update_ctx() end,
    })
    vim.api.nvim_create_autocmd("BufWinLeave", {
        group = ctx_group,
        buffer = buf,
        callback = function()
            local vw = vwin()
            if vw then saved_pos = vim.api.nvim_win_call(vw, vim.fn.winsaveview) end
            close_ctx()
        end,
    })
    -- This view's reported operation (§19.1, the diff load): ended when the diff
    -- lands, or `cancelled` with the frame (§19.4).
    local progress = require("gitloom.progress").tracker(opts.progress)
    vim.api.nvim_create_autocmd("BufWipeout", {
        group = ctx_group,
        buffer = buf,
        callback = function()
            close_ctx()
            progress:close()
            pcall(vim.api.nvim_del_augroup_by_id, ctx_group)
        end,
    })

    set_lines({ "Loading…" })

    -- Entering this frame (the push, or a `<C-o>`/`<C-i>` step back to it, §14.3):
    -- apply window-local scrolloff (opts.scrolloff, §8), restore the saved
    -- scroll/cursor (else let render() park on the action label on first show),
    -- and re-seed the context header for the now-visible viewport.
    local function on_enter()
        local vw = vwin()
        if not vw then return end
        pcall(vim.api.nvim_set_option_value, "scrolloff", opts.scrolloff or 0,
            { scope = "local", win = vw })
        if saved_pos then
            pcall(vim.api.nvim_win_call, vw, function() vim.fn.winrestview(saved_pos) end)
        elseif action_line then
            pcall(vim.api.nvim_win_set_cursor, vw, { action_line, 0 })
        end
        -- The width may have changed while another frame was shown (§11.2.1).
        rewrap()
        update_ctx()
    end

    -- Show the frame in the host window, pushing it onto the view stack (§14.3);
    -- this swaps the host's buffer and runs on_enter. The async render below then
    -- fills the buffer in place once git returns.
    nav.push_frame(root, { kind = "commit", buf = buf, label = title, on_enter = on_enter })

    -- A git failure the diff fetch reported (§13.5), rendered in place of the
    -- patch so a broken spawn never reads as "this range has no changes".
    local diff_error = nil

    -- Render the metadata (format_commit_detail), then the diffstat
    -- (format_diffstat), then the diff (format_diff) into one buffer: real lines
    -- + namespaced extmarks (the diff is highlighted this way, not via
    -- filetype=diff, so the metadata header stays clean §11.3). While laying out
    -- the rows, record each diffstat file row -> its diff section line (§11.4).
    -- The last render's inputs + wrap width + metadata end, for a re-wrap.
    ---@type { meta: string?, diff: string?, width: integer?, meta_end: integer }?
    local last_render = nil
    local function render(meta_output, diff_output, keep_view)
        if not vim.api.nvim_buf_is_valid(buf) then return end
        local vw = vwin()
        -- On an in-place re-render (the submodule upgrade, §11.7.4) preserve the
        -- user's scroll/cursor; the first render parks on the action label.
        local saved_view = keep_view and vw
            and vim.api.nvim_win_call(vw, vim.fn.winsaveview) or nil
        -- Build the content rows + index maps (shared with the search preview,
        -- §15.3), then bind the window-specific upvalues the keymaps/context
        -- header read. Row indices are buffer lines here (we write at line 0).
        local width = M.commit_wrap_width(vw)
        local rows, info = build_commit_rows(opts, {
            commit = commit, range = range, root = root,
            meta = meta_output, diff = diff_output, diff_error = diff_error,
            sub_results = sub_results, width = width,
        })
        -- A re-wrap moves everything below the message by the change in its line
        -- count: keep the user on the same content (§11.2.1).
        local prev_end = last_render and last_render.meta_end
        local delta = prev_end and (info.meta_end - prev_end) or 0
        if saved_view and prev_end and delta ~= 0 then
            local edge = prev_end
            if saved_view.lnum > edge then saved_view.lnum = saved_view.lnum + delta end
            if saved_view.topline > edge then saved_view.topline = saved_view.topline + delta end
        end
        last_render = { meta = meta_output, diff = diff_output, width = width, meta_end = info.meta_end }
        action_line = info.action_line
        file_jumps = info.file_jumps
        sub_jumps = info.sub_jumps
        diff_ctx, diff_start = info.diff_ctx, info.diff_start
        diff_buf_to_patch = info.diff_buf_to_patch

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
            if vw then pcall(vim.api.nvim_win_call, vw, function() vim.fn.winrestview(saved_view) end) end
        elseif action_line and vw then
            -- Park the cursor on the action label so <CR><CR> opens the diff (§11.2).
            pcall(vim.api.nvim_win_set_cursor, vw, { action_line, 0 })
        end

        -- Seed the context header for the initial viewport (§11.6).
        update_ctx()
    end

    -- Fetch the diff (plus metadata in single-commit mode); render once it
    -- arrives (§11.1). Range mode (§13.5) needs no metadata fetch — the commit
    -- list is supplied — so it fetches only the combined range diff.
    local fetched
    local load_op = progress:start("Loading diff")
    if range then
        -- Resolves { code, out, err }: a failing `git diff` must not read as an
        -- empty patch (§13.5), so a non-zero exit becomes a visible error row +
        -- a notification instead of a commit list with nothing under it.
        fetched = fetch_range_diff(range.range).next(function(res)
            if res.code ~= 0 then
                diff_error = git.format_git_error("git diff", res)
                vim.notify("gitloom: " .. diff_error, vim.log.levels.ERROR)
                return { meta = nil, diff = nil }
            end
            return { meta = nil, diff = res.out }
        end)
    elseif commit and commit.virtual == "clean" then
        -- The clean node (§11.8) has no diff: no git is spawned, the view is the
        -- synthesized header alone (format_worktree_detail's `no changes`).
        local future, promise = make_future()
        promise.resolve({ meta = nil, diff = nil })
        fetched = future
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
    rewrap = function()
        if not last_render then return end
        local vw = vwin()
        if not vw or M.commit_wrap_width(vw) == last_render.width then return end
        render(last_render.meta, last_render.diff, true)
    end

    fetched.next(function(res)
        load_op:finish(diff_error and "failed" or "done")
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
---@field zindex? integer  the host's zindex; set from GraphOptions.zindex at open (§8/§14)
---@field on_win? fun(w: table)  snacks calls this on every (re)show; refreshes the live window id (§14)
---@field keys? table  keymaps installed on the graph window (snacks.win keys)

---@class GraphPalette
---@field date? string
---@field author? string
---@field branch? string
---@field remote? string
---@field head? string
---@field message? string
---@field tags? string
---@field worktree? string  a linked worktree's HEAD label, `{wt:<dir>}` (§3.2/§4.1)
---@field selected? string  the h/l-selected ref decoration (§2)
---@field search? string  the filter-search matched substring (§16.7)
---@field pair? string|false  the dual-mode pair bracket (default "NonText"; false leaves the prefix blank); §6.1
---@field action? string  the commit-view diff action label (§11.5)
---@field diff? { add?: string, delete?: string, hunk?: string, header?: string }  commit-view diff colors (§11.3)
---@field submodule? { new?: string, old?: string, base?: string }  submodule change-view lanes: added/removed/ancestor (§11.7)
---@field track? { ahead?: string, behind?: string, gone?: string, upstream?: string, mismatch?: string }  upstream tracking tokens (§6.3)
---@field dim? number  blend factor toward bg for out-of-cone rows/lanes (§12)
---@field counterpart_dim? number  lighter blend factor toward bg for a remote counterpart's lane colour (§5.5)
---@field counterpart_dim_out? number  a counterpart lane's blend OUT of the cone (§12.2); default 0.75 * dim, lighter than the cone dim
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
---@field head? string  HEAD's node marker (default "●"; "" off); §5.3
---@field pin? string   the pinned-anchor label icon (default "⚲"; "" off); §6/§10.6
---@field expanded? string  the expanded-ref label icon, after the pin icon (default "▾"; "" off); §6
---@field upstream? string  the glyph before a non-matching upstream (default "→"; "" leaves the bare name); §6.3

---@class GraphOptions
---@field win GraphWinOptions
---@field palette GraphPalette
-----@field merge_style "compact"|"normal"|"merge"
---@field merge_style MergeStyle
---@field layout_policy? "compact"|"survivors"|"linear"|"straight"|"gutter"  lane layout policy (default "compact", cycled by `C`); §5.6
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
---@field dual_bracket? string[]  the dual-mode pair bracket glyphs { label row, message row } (default { "┬", "└" }); §6.1
---@field lane_label_colors? boolean  ref labels in their node's lane colour (default true); §6
---@field diff? { open?: fun(range: DiffRange), label?: string }  external diff provider; §11.5
---@field working_tree? boolean|"dirty"  the working-tree row above HEAD: true = always (a clean node on a clean tree), "dirty" = only with changes, false = never; §3.3/§4.2
---@field scrolloff? integer  'scrolloff' for the graph + commit-view windows (default 10); §8
---@field pin_upstream? boolean  a pinned local branch also pins its remote counterparts implicitly (default true); §10.6
---@field search? { snippet?: integer, layout?: "vertical" }  commit-search preview (snippet rows, layout); §15
---@field show_lane_ids? boolean  per-window lane-id debug overlay (toggled by `i`); window-owned, read by the renderer
---@field zindex? integer  the host window's zindex (default 41); overlays at +1, gitloom's transient floats at +2; §8/§14
---@field persist? boolean  persist the view toggles + pin lists to stdpath("state")/gitloom.json (default true); §18
---@field progress? ProgressConfig|false  how long-running operations are reported (default { provider = "auto", delay = 300 }); §19

---@class GraphAttach : ListViewAttach
---@field host_root string  the parent repo whose host window/session receives the frame (§14)

-- ── Extracted graph helpers (Phase B1) ──────────────────────────────────────
-- Pure, window-free per-session helpers, lifted out of `open_graph` so its
-- closure stays under LuaJIT's 60-upvalue ceiling. Each takes the GraphCtx as its
-- first argument; the ctx-attached ones (GRAPH_HELPERS) are called `ctx:name()` so
-- sibling dispatch resolves at call time (no definition-order coupling). All the
-- module-level deps they use (order_commits, fetch_rev_order, get_or_create_commit,
-- diff_ref_tips, add_ref, reachable_hashes, range_endpoints, item_lines, the
-- WORKTREE_HASH / SORT_MODES constants, make_future) are declared above.
local GRAPH_HELPERS = {}

-- The OrderItem for a DisplayNode (by hash), or nil when packed into a marker
-- group (§10.4). Internal to the selection/cone helpers below.
local function node_item(ctx, node)
    if not node then return nil end
    local i = ctx.display_index[node.hash]
    return i and ctx.repo.display[i] or nil
end
-- A path endpoint's real newest / oldest Commit: a collapsed head stands for its
-- whole region (§13.1) — newest = tip, oldest = last region member.
local function real_newest(node) return node.collapsed and node.tip or node.commit end
local function real_oldest(ctx, node)
    if node.collapsed then
        local region = node.region or {}
        local h = region[#region]
        return (h and ctx.repo.commits[h]) or node.tip
    end
    return node.commit
end

-- Re-establish gitloom's owned row order (§3.1): order_commits over the real
-- (non-virtual) rows, rebuilding repo.order and reusing the OrderItem objects.
local function reorder_repo(ctx)
    local repo = ctx.repo
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

-- Reorder repo.order to match an external hash sequence (a `rev` sort mode; §3.1).
---@param hashlist string[]
local function reorder_by_hashes(ctx, hashlist)
    local repo = ctx.repo
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

-- The default anchors (§10.6), in order: `master` / `main` / `dev` and the seeded
-- marks (§11.7.6), then HEAD's anchor LAST (its branch when attached, the `HEAD`
-- ref when detached) — each only when the ref exists. Shared by effective_pins and
-- the §18 pin save, which leaves the leading run of unreserved defaults out of the
-- stored list.
---@return string[]
GRAPH_HELPERS.pin_defaults = function(ctx)
    local repo = ctx.repo
    local defaults, seen = {}, {}
    local function def(name)
        if repo.refs[name] and not seen[name] then
            seen[name] = true
            defaults[#defaults + 1] = name
        end
    end
    for _, name in ipairs({ "master", "main", "dev" }) do def(name) end
    -- Seeded pointer marks (§11.7.6) come from a set; sort so the list is stable.
    local seeds = {}
    for name in pairs(ctx.seed_pin_names or {}) do seeds[#seeds + 1] = name end
    table.sort(seeds)
    for _, name in ipairs(seeds) do def(name) end
    if repo.head then def(repo.head) else def("HEAD") end
    return defaults
end

-- Persist one toggled view preference (§18.2); `key` is its GraphOptions field.
GRAPH_HELPERS.save_pref = function(ctx, key)
    require("gitloom.persist").save_pref(ctx.opts, ctx.persist_config or {}, key)
end

-- Persist this repository's pin list after a change (§18.2). Only the repository's
-- own root graph writes (§14.8 — never a drilled-in frame), and only from the BASE
-- view: a stamped filter (§16.5) edits a private copy, recognisable because its
-- `unpinned` table is not the base's (that table is only ever mutated in place).
-- The base's `pins` is re-pointed too, since `P` and the dialog replace the table
-- — so returning from a stamped filter restores the list just saved.
GRAPH_HELPERS.save_pins = function(ctx)
    local vs, base = ctx.view_state, ctx.base_view
    if base and vs.unpinned ~= base.unpinned then return end
    if base then base.pins = vs.pins end
    if not ctx.persist_writable then return end
    require("gitloom.persist").save_pins(ctx.opts, ctx.repo.root, vs.pins, vs.unpinned, GRAPH_HELPERS.pin_defaults(ctx))
end

-- Reset view settings (§18.5): confirm, then reset_view_now.
GRAPH_HELPERS.reset_view = function(ctx)
    require("gitloom.persist").confirm_reset(function() ctx:reset_view_now() end)
end

-- The reset itself, without the prompt: clear the persisted global preferences +
-- this repository's pins, re-apply every persisted key's configuration-resolved
-- value, re-sync the cycle indices, restore the default anchors, then re-sort /
-- re-lay out / re-render as the individual toggles do.
GRAPH_HELPERS.reset_view_now = function(ctx)
    local persist = require("gitloom.persist")
    if ctx.persist_writable then persist.reset(ctx.opts, ctx.repo.root) end
    local cfg = ctx.persist_config or persist.config_values({})
    for _, k in ipairs(persist.KEYS) do ctx.opts[k] = vim.deepcopy(cfg[k]) end
    if ctx.pane_opts then ctx.pane_opts.layout_policy = ctx.opts.layout_policy end
    for i, m in ipairs(MERGE_STYLES) do
        if vim.deep_equal(m.style, ctx.opts.merge_style) then merge_style_index = i; break end
    end
    for i, m in ipairs(LABEL_MODES) do
        if m.mode == ctx.opts.label_mode then label_mode_index = i; break end
    end
    for i, m in ipairs(SORT_MODES) do
        if m.id == ctx.opts.sort_mode then sort_mode_index = i; break end
    end
    -- Pins: back to the defaults. A stamped filter's private copy is replaced too,
    -- but the base then gets tables of its own so the copy still reads as stamped.
    local vs, base = ctx.view_state, ctx.base_view
    local stamped = base and vs.unpinned ~= base.unpinned
    vs.pins, vs.unpinned = {}, {}
    if base then
        if stamped then base.pins, base.unpinned = {}, {} else base.pins, base.unpinned = vs.pins, vs.unpinned end
    end
    ctx.selection_state.index = nil
    local keep
    local ok, pos = pcall(vim.api.nvim_win_get_cursor, ctx:win())
    if ok then keep = ctx:cursor_hash(pos[1]) end
    ctx:apply_sort().next(function()
        ctx:reflow()
        if ctx.lv and ctx.lv.controller then ctx.lv.controller.relayout() end
        ctx:update_footer()
        if keep then ctx:goto_hash(keep) end
        ctx:place_cursor()
        ctx:update_cone()
        if ctx.lv and ctx.lv.controller then ctx.lv.controller.refresh() end
        ctx:update_panes()
        vim.notify("gitloom: view settings reset", vim.log.levels.INFO)
    end)
end

-- The effective **pin list** (§10.6): an ORDERED list of `{ id, reserved }` —
-- exactly the dialog's rows. The default anchors (master/main/dev, the seeded
-- marks, then HEAD's) the user has not explicitly placed come first, then the
-- user's ordered entries (`view_state.pins`); a newly pinned ref is appended to
-- those, so it lands at the bottom. HEAD is an anchor attached OR detached: on a
-- branch it is that branch's owner; detached it is the `HEAD` ref itself (an owner
-- only then — owners_from_refs), so a `HEAD` entry is dropped while HEAD is on a
-- branch; `view_state.unpinned` suppresses a default. `pin_resolve` is the pure
-- core. Implicit remote counterparts are NOT entries (see `pin_rank`).
--- (A GRAPH_HELPERS field rather than a module local — window.lua sits near
--- LuaJIT's 200-local chunk limit, which is what these tables exist to dodge.)
---@return PinEntry[]
GRAPH_HELPERS.effective_pins = function(ctx)
    local repo, view_state = ctx.repo, ctx.view_state
    local pins = selectm.pin_resolve(view_state.pins, view_state.unpinned, GRAPH_HELPERS.pin_defaults(ctx), repo.refs)
    if repo.head then
        -- Attached: the `HEAD` ref is not an owner (its branch is), so an entry the
        -- user pinned while detached would be an inert row in the dialog.
        local kept = {}
        for _, e in ipairs(pins) do
            if e.id ~= "HEAD" then kept[#kept + 1] = e end
        end
        pins = kept
    end
    return pins
end

-- The **pin rank** of every pin-list ENTRY (§5/§10.6): ref id → its place in the
-- resolved list, 1 = highest priority. This is the layout input `opts.pin_rank` —
-- lane identity and the pinned colours (§5.5). Implicit remote counterparts are NOT
-- in it: they take no rank and no pinned colour; they are anchors only (see
-- `effective_pinned`).
---@return table<string, integer>
GRAPH_HELPERS.pin_rank = function(ctx)
    return selectm.pin_rank(ctx:effective_pins(), ctx.repo.refs, ctx.remotes,
        ctx.view_state.unpinned, false)
end

-- Publish the current pin ranks on the layout options (`opts.pin_rank`, §5) — the
-- main view's `ctx.opts` and the panes' frozen copy `ctx.pane_opts` — so the next
-- layout reads them. Run at the top of every reflow (which every pin change, the
-- reset, a resync and a HEAD move go through) and before the open-time stream.
GRAPH_HELPERS.sync_pin_rank = function(ctx)
    local rank = GRAPH_HELPERS.pin_rank(ctx)
    local cp = GRAPH_HELPERS.pin_counterpart(ctx)
    ctx.opts.pin_rank, ctx.opts.pin_counterpart = rank, cp
    if ctx.pane_opts then ctx.pane_opts.pin_rank, ctx.pane_opts.pin_counterpart = rank, cp end
    return rank
end

-- The **counterpart colours** input (§5.5, `opts.pin_counterpart`): every implicit
-- remote counterpart's ref id → its local's rank, so a lane born at one shares the
-- local's pinned colour, lightly dimmed. Empty with `pin_upstream` off.
---@return table<string, integer>
GRAPH_HELPERS.pin_counterpart = function(ctx)
    if ctx.opts.pin_upstream == false then return {} end
    return selectm.pin_counterpart_rank(ctx:effective_pins(), ctx.repo.refs, ctx.remotes,
        ctx.view_state.unpinned)
end

-- The effective anchor **set** — the pinned entries plus their implicit remote
-- counterparts (§10.6, `pin_upstream`, unless explicitly unpinned). This is what
-- `view.owners` / `select.toggle_target` and the pin icon consume. A superset of
-- `pin_rank`'s keys: the counterparts are anchors, but never ranked (§5).
local function effective_pinned(ctx)
    local set = {}
    for id in pairs(selectm.pin_rank(ctx:effective_pins(), ctx.repo.refs, ctx.remotes,
        ctx.view_state.unpinned, ctx.opts.pin_upstream ~= false)) do
        set[id] = true
    end
    return set
end
GRAPH_HELPERS.effective_pinned = effective_pinned

-- The label marks the label renderers are handed (§6/§10.6): the effective anchors
-- (implicit counterparts included) + `icons.pin`, and the expanded refs (§6
-- "Expanded marker") + `icons.expanded`. The pin set is resolved fresh on every
-- call (it is a handful of entries), so a label can never show a stale pin after
-- `P`, the dialog, or a resync; the expanded set is resolved per reflow
-- (`reflow_owners`), the only time a mode changes.
---@return PinMarks
GRAPH_HELPERS.pin_marks = function(ctx)
    local icons = ctx.opts.icons
    return { set = effective_pinned(ctx), icon = icons and icons.pin,
        expanded = ctx.view_state.expanded, expanded_icon = icons and icons.expanded,
        upstream_icon = icons and icons.upstream }
end

-- node hash → repo.display index, and packed-head marker locations (§13.4).
local function build_display_index(ctx)
    ctx.display_index, ctx.node_loc = {}, {}
    local di, nl = ctx.display_index, ctx.node_loc
    local function locate(it, node)
        for c, cell in ipairs(it.columns or {}) do
            if cell.has_commit and cell.commit == node then
                nl[node.hash] = { item = it, col = c }
                return
            end
        end
    end
    for i, it in ipairs(ctx.repo.display or {}) do
        if it.commit then
            di[it.commit.hash] = i
            locate(it, it.commit)
        elseif it.type == "markers" then
            for _, m in ipairs(it.markers or {}) do locate(it, m) end
        end
    end
end
GRAPH_HELPERS.build_display_index = build_display_index

-- Resolve a 1-based *buffer* line to its OrderItem, order index, and 0-based
-- sub-row (dual mode spans two lines; mapped via the listview controller).
local function order_at(ctx, line)
    local idx, first = line, line
    local lv = ctx.lv
    if lv and lv.controller and lv.controller.item_at then
        idx = lv.controller.item_at(line)
        first = lv.controller.item_start and lv.controller.item_start(idx) or idx
    end
    return ctx.repo.display[idx], idx, line - first
end
GRAPH_HELPERS.order_at = order_at

-- Apply the active sort mode to repo.order, returning a Future (the `rev` modes
-- query git asynchronously; §3.1). The caller reflows.
---@return Future
local function apply_sort(ctx)
    local mode = SORT_MODES[sort_mode_index]
    if mode.rev then
        local branch = ctx.opts.branches or { "--all" }
        if type(branch) ~= "table" then branch = { branch } end
        return fetch_rev_order(branch, mode.rev)
            .next(function(hashes) reorder_by_hashes(ctx, hashes) end)
    end
    reorder_repo(ctx)
    local future, promise = make_future()
    promise.resolve()
    return future
end
GRAPH_HELPERS.apply_sort = apply_sort

-- Merge a freshly-parsed Commit into the model (§3): fill its placeholder (or
-- insert it), resolve parent hashes to Commit refs with child back-links, append
-- an OrderItem (returned). nil for an already-loaded commit.
---@param item Commit
---@return OrderItem?
local function integrate_commit(ctx, item)
    local repo = ctx.repo
    local existing = repo.commits[item.hash]
    if existing then
        if existing.loaded then return nil end -- already a row; don't re-link
        -- Fill the placeholder; cepoch (committer date) MUST be copied — ref tips
        -- are pre-created as placeholders and order_commits seeds tips by cepoch
        -- (§3.1); dropping it breaks the order on squash-merge repos.
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
GRAPH_HELPERS.integrate_commit = integrate_commit

-- Reconcile the model's refs with a freshly-read set (§3.4): diff_ref_tips drives
-- drop / add / re-point, then HEAD re-binds to the current branch.
---@param entries { name: string, kind: string, hash: string, upstream?: Upstream }[]
---@param head string?
---@param detached string?  the checked-out commit hash when detached (§3.2)
local function reconcile_refs(ctx, entries, head, detached)
    local repo = ctx.repo
    -- Unlink a Ref from its commit's back-list and the registry.
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
        add_ref(repo, e.name, e.kind, e.hash, e.upstream)
    end
    for _, k in ipairs(d.moved) do
        local e = by_key[k]
        unlink_ref(k) -- detach the old binding before re-pointing
        add_ref(repo, e.name, e.kind, e.hash, e.upstream)
    end
    -- Refresh upstream divergence even where the local tip did not move (§6.3).
    for _, e in ipairs(entries) do
        if e.kind == "local" and repo.refs[e.name] then
            repo.refs[e.name].upstream = e.upstream
        end
    end
    unlink_ref("HEAD")
    repo.head = head
    if head and repo.refs[head] and repo.refs[head].commit then
        add_ref(repo, "HEAD", "head", repo.refs[head].commit.hash).branch = head
    elseif not head and detached then
        add_ref(repo, "HEAD", "head", detached)
    end
end
GRAPH_HELPERS.reconcile_refs = reconcile_refs

-- Prune commits no longer reachable from any ref (§3.4) — force-push/rebase
-- orphans. Walks tips, drops unreachable real commits, prunes child back-links
-- and repo.order.
local function prune_to_reachable(ctx)
    local repo = ctx.repo
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
GRAPH_HELPERS.prune_to_reachable = prune_to_reachable

-- Remove the working-tree virtual commits from the raw model (§4.2). The caller
-- reflows. (ctx.worktree_commits is REPLACED, so write it back through ctx.)
local function clear_worktree_nodes(ctx)
    local repo = ctx.repo
    if #ctx.worktree_commits == 0 then return end
    for _, v in ipairs(ctx.worktree_commits) do
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
    ctx.worktree_commits = {}
end
GRAPH_HELPERS.clear_worktree_nodes = clear_worktree_nodes

-- Rebuild the working-tree virtual commits (§3.3/§4.2) from a fetched state,
-- splicing untracked → unstaged → staged above HEAD — or, on a clean tree, the
-- single clean node (unless `working_tree = "dirty"`). Returns the status string:
-- "off" | "clean" (nothing spliced) | "moved" (HEAD left the model) | "ok".
local function apply_worktree(ctx, state)
    local repo, opts = ctx.repo, ctx.opts
    ctx:clear_worktree_nodes()
    if opts.working_tree == false then return "off" end
    ctx.worktree_head = state and state.head_hash
    local st = state and state.status
    -- No status or an unborn HEAD (no commit to stand on): no node, not even clean.
    if not (st and ctx.worktree_head) then return "clean" end
    local anchor = repo.commits[ctx.worktree_head]
    if not anchor then return "moved" end -- history advanced past the snapshot
    local kinds = {}
    if st.staged > 0 then kinds[#kinds + 1] = { "staged", st.staged } end
    if st.unstaged > 0 then kinds[#kinds + 1] = { "unstaged", st.unstaged } end
    if st.untracked > 0 then kinds[#kinds + 1] = { "untracked", st.untracked } end
    if #kinds == 0 then
        -- A clean tree: the clean node stands in for the change nodes (§3.3).
        if opts.working_tree == "dirty" then return "clean" end
        kinds[1] = { "clean", 0 }
    end
    local ai
    for i, it in ipairs(repo.order) do
        if it.commit == anchor then ai = i; break end
    end
    if not ai then return "moved" end
    -- Build bottom-up (parent first); new_items ends newest-first for the splice.
    local below = anchor
    local new_items = {}
    for _, k in ipairs(kinds) do
        local kind = k[1]
        ---@type Commit
        local v = { hash = WORKTREE_HASH[kind], virtual = kind, parents = { below },
            children = {}, refs = {}, wt = { changed = k[2] } }
        table.insert(below.children, v)
        below = v
        ctx.worktree_commits[#ctx.worktree_commits + 1] = v
        repo.commits[v.hash] = v
        table.insert(new_items, 1, { type = "commit", commit = v, columns = {} })
    end
    for k = #new_items, 1, -1 do
        table.insert(repo.order, ai, new_items[k])
    end
    return "ok"
end
GRAPH_HELPERS.apply_worktree = apply_worktree

-- The selection's DiffRange (§13.5): newest .. oldest real endpoints.
local function selection_range(ctx)
    local p = ctx.sel.path
    if not (p and #p > 0) then return nil end
    local newer, older = real_newest(p[1]), real_oldest(ctx, p[#p])
    if not (newer and older) then return nil end
    return range_endpoints(newer, older, ctx.repo.root)
end
GRAPH_HELPERS.selection_range = selection_range

-- The selected commits newest-first (§13.5): a collapsed head expands to its
-- region members.
local function selection_commits(ctx)
    local repo = ctx.repo
    local out, seen = {}, {}
    local function push(c)
        if c and not seen[c.hash] then seen[c.hash] = true; out[#out + 1] = c end
    end
    for _, node in ipairs(ctx.sel.path or {}) do
        if node.collapsed then
            for _, h in ipairs(node.region or {}) do push(repo.commits[h]) end
        else
            push(node.commit)
        end
    end
    return out
end
GRAPH_HELPERS.selection_commits = selection_commits

-- Emphasis for the selected path (§13.4): light the path's markers + the lane
-- between each consecutive pair, reset the rest in the visible range. Returns the
-- cone set (keyed by DisplayNode) for row dimming.
local function mark_path(ctx, top, bottom)
    local repo = ctx.repo
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
    local p = ctx.sel.path or {}
    for _, node in ipairs(p) do cone[node] = true end
    for i = 1, #p - 1 do
        local a, b = p[i], p[i + 1]
        local it = node_item(ctx, a)
        if it then
            for _, lane in ipairs(it.parent_lanes or {}) do
                if lane.parent == b then lane.highlighted = true end
            end
        else
            local loc = ctx.node_loc[a.hash] or ctx.node_loc[b.hash]
            if loc then
                for _, s in ipairs(loc.item.columns[loc.col].lanes or {}) do
                    for _, e in ipairs(s.edges or {}) do
                        if e.begin == a and e.parent == b then e.highlighted = true end
                    end
                end
            end
        end
    end
    for _, node in ipairs(p) do
        local it = node_item(ctx, node)
        if it then
            for _, line in ipairs(item_lines(it)) do
                for _, t in ipairs(line) do
                    if t.has_commit and t.commit == node then t.active = true end
                end
            end
        else
            local loc = ctx.node_loc[node.hash]
            if loc then loc.item.columns[loc.col].active = true end
        end
    end
    return cone
end
GRAPH_HELPERS.mark_path = mark_path

-- Reachability emphasis seeded from a packed marker head (§10.4 + §12): walk the
-- DisplayNode graph from the head (.parents then .children), bounded to the
-- visible rows, lighting each lane via its shared edge object. Returns the cone.
local function mark_node_cone(ctx, pivot, top, bottom)
    local repo = ctx.repo
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
    local function light_edge(child, parent)
        local it = node_item(ctx, child)
        if it then
            for _, lane in ipairs(it.parent_lanes or {}) do
                if lane.parent == parent then lane.highlighted = true end
            end
        else
            local loc = ctx.node_loc[child.hash] or ctx.node_loc[parent.hash]
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
        local it = node_item(ctx, n)
        if it then
            for _, line in ipairs(item_lines(it)) do
                for _, t in ipairs(line) do
                    if t.has_commit and t.commit == n then t.active = true end
                end
            end
        else
            local loc = ctx.node_loc[n.hash]
            if loc then loc.item.columns[loc.col].active = true end
        end
    end
    return cone
end
GRAPH_HELPERS.mark_node_cone = mark_node_cone

-- ── Commit selection (range) — window glue (spec §13). Module-level, ctx-driven;
-- registered into GRAPH_KEYS alongside the keymap handlers. ────────────────────

-- Hand the selection range to the external diff provider (§13.5; the `D` key and
-- the range view's action label).
local function open_selection_diff(ctx)
    local open = ctx.opts.diff and ctx.opts.diff.open
    if not open then
        vim.notify("gitloom: no diff provider configured (set diff.open)", vim.log.levels.WARN)
        return
    end
    local r = ctx:selection_range()
    if r then open(r) end
end
GRAPH_HELPERS.open_selection_diff = open_selection_diff

-- <CR> while selecting (§13.5): open the commit view in range mode — the selected
-- commit list + the combined range diff/diffstat.
local function open_selection_view(ctx)
    local r = ctx:selection_range()
    if not r then return end
    local commits = ctx:selection_commits()
    local n = #commits
    -- A §4.2 working-tree node has no hash to name the view by (§13.5).
    local one = (n == 1) and commits[1] or nil
    local title = one and (one.virtual and worktree_label(one) or ("Commit " .. one.hash:sub(1, 7)))
        or (("Selection: %d commits"):format(n))
    open_commit_view(ctx.opts, nil, { range = r, commits = commits, title = title }, ctx.repo.root)
end

-- Recompute the path emphasis, move the cursor onto the moving end, and redraw
-- (§13). update_cone branches to mark_path while selection is active.
local function selection_redraw(ctx)
    local sel = ctx.sel
    if sel.cursor then ctx:goto_hash(sel.cursor.hash) end
    ctx:update_cone()
    if ctx.lv and ctx.lv.controller then ctx.lv.controller.refresh() end
    ctx:place_cursor()
    ctx:update_footer()
    ctx:maybe_update_panes()
end

-- V: start selection on the row's commit (a normal commit, a collapsed head, or a
-- §4.2 working-tree node; a packed marker line is not a start point in v1).
-- anchor = cursor = it.
--
-- A working-tree node IS a valid start (§13.2): having no children it can only
-- ever be the path's newest end, and `range_endpoints` turns a virtual newer end
-- into a tree state (§13.5), so its sentinel hash never reaches a git rev.
local function enter_selection(ctx, line)
    local sel = ctx.sel
    local item = ctx:order_at(line)
    if not item or not item.commit or item.type == "markers" then return end
    ctx:build_display_index()
    ctx.selection_state.index = nil -- drop the ref selection (§13.3)
    sel.active, sel.anchor, sel.cursor = true, item.commit, item.commit
    sel.path, sel.dparent, sel.dchild = { item.commit }, {}, {}
    selection_redraw(ctx)
end

local function exit_selection(ctx)
    local sel = ctx.sel
    sel.active, sel.path, sel.anchor, sel.cursor = false, nil, nil, nil
    ctx:update_cone() -- restore the cursor-pivot cone (§12)
    if ctx.lv and ctx.lv.controller then ctx.lv.controller.refresh() end
    ctx:place_cursor()
    ctx:update_footer()
    ctx:update_panes()
end

-- j/k along the branch (§13.2): step the moving end one commit; redraw.
local function selection_move(ctx, dir)
    if not ctx.sel.active then return end
    sel_step(ctx.sel, dir)
    selection_redraw(ctx)
end

-- <C-d>/<C-u>: a half-viewport of branch commits, stopping at a tip/root (§13.2).
local function selection_page(ctx, dir)
    local sel = ctx.sel
    local hw = ctx:win()
    if not (sel.active and hw) then return end
    local steps = math.max(1, math.floor(vim.api.nvim_win_get_height(hw) / 2))
    for _ = 1, steps do
        local before = sel.cursor
        sel_step(sel, dir)
        if sel.cursor == before then break end
    end
    selection_redraw(ctx)
    ctx:center_view()
end

-- h/l: switch branch at the nearest junction (§13.3). Negated under mirroring so
-- `l` always moves toward the visually-right branch.
local function selection_switch(ctx, delta)
    local sel = ctx.sel
    if not sel.active then return end
    if ctx.opts.mirror ~= false then delta = -delta end
    if sel_switch(sel, delta) then selection_redraw(ctx) end
end

-- o: swap the anchor and the moving end (§13.2).
local function selection_swap(ctx)
    local sel = ctx.sel
    if not sel.active then return end
    sel.anchor, sel.cursor = sel.cursor, sel.anchor
    selection_redraw(ctx)
end

-- <Space> while selecting (§13.4): fold/unfold the head under the cursor in place,
-- re-resolving the selection by hash so it covers the same commits and the view
-- holds (saved scroll restored). A no-op on a mainline commit.
local function selection_toggle(ctx)
    local sel, view_state, sig_cache, repo = ctx.sel, ctx.view_state, ctx.sig_cache, ctx.repo
    local node = sel.active and sel.cursor
    if not node or not ctx:win() then return end
    -- The same own-owner rule as <Space> (§10.4): a head expands its own owners, an
    -- open commit collapses its normal non-anchor own owners (a no-op on mainline).
    local hash = node.collapsed and node.tip and node.tip.hash or node.hash
    local owners = selectm.toggle_target(sig_cache.sig, hash, view_state.owner_tip or {},
        ctx:effective_pinned(), view_state.effective, node.collapsed).owners
    local mode = node.collapsed and "normal" or "collapsed"
    if #owners == 0 then return end

    local w = ctx:win() --[[@as integer]] -- guarded non-nil above
    local view = vim.api.nvim_win_call(w, function() return vim.fn.winsaveview() end)
    local anchor_is_top = (sel.path or {})[1] == sel.anchor
    local function members(n) return n.collapsed and (n.region or {}) or { n.hash } end
    local path_h = {}
    for _, n in ipairs(sel.path or {}) do
        for _, h in ipairs(members(n)) do path_h[#path_h + 1] = h end
    end

    for _, oid in ipairs(owners) do view_state.modes[oid] = mode end
    ctx:reflow() -- rebuilds display + node_loc, drops sel

    -- Map every real-commit / head hash to its new node (members → the head).
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

    -- Settle the viewport, then recompute the emphasis over the settled range.
    ctx:goto_hash(sel.cursor.hash)
    vim.api.nvim_win_call(w, function()
        local cur = vim.api.nvim_win_get_cursor(w)
        pcall(vim.fn.winrestview, { topline = view.topline, lnum = cur[1], col = cur[2], leftcol = 0 })
    end)
    ctx:update_cone()
    if ctx.lv.controller then ctx.lv.controller.refresh() end
    ctx:place_cursor()
    ctx:update_footer()
    ctx:update_panes()
end

-- Feed builtin motions without remapping (so j/k/<C-d>/<C-u> fall through to the
-- native motions instead of re-triggering our maps).
local function feed(keys)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "n", false)
end

-- h/l: move the ref selection on the current row (§2), or switch branch while
-- selecting (§13.3). `dir` is -1 (h) / +1 (l).
local function move_ref(ctx, dir)
    local sel, selection_state, opts = ctx.sel, ctx.selection_state, ctx.opts
    -- While selecting (§13.3) h/l switch the followed branch.
    if sel.active then selection_switch(ctx, dir); return end
    local line = vim.api.nvim_win_get_cursor(ctx:win() --[[@as integer]])[1]
    local item, _, sub = ctx:order_at(line)
    -- On a packed marker line, selection moves among the markers (§10.4).
    if item and item.type == "markers" then
        local count = #marker_units(item)
        local pos = (selection_state.commit == item) and selection_state.index or nil
        selection_state.commit = item
        selection_state.index = move_selection(pos, count, dir)
        ctx.selection_visible = selection_state.index ~= nil
        -- The cone is seeded from the selected head (§12) — recompute before redraw.
        ctx:update_cone()
        if ctx.lv and ctx.lv.controller then ctx.lv.controller.refresh() end
        ctx:maybe_update_panes() -- the panes dim with the cone too (§6.2)
        ctx:place_cursor()
        return
    end
    local commit = item and item.commit or nil
    if not commit then return end
    -- In dual mode the labels live on the first row only.
    if opts.label_mode == "dual" and sub ~= 0 then return end
    local count = #decoration_texts(commit)
    local pos = (selection_state.commit == commit) and selection_state.index or nil
    selection_state.commit = commit
    selection_state.index = move_selection(pos, count, dir)
    ctx.selection_visible = selection_state.index ~= nil
    if ctx.lv and ctx.lv.controller then ctx.lv.controller.refresh() end
    ctx:place_cursor()
end

-- ── Keymap handlers (spec §2/§10/§11/§13). Module-level, ctx-driven; collected
-- into GRAPH_KEYS and bound buffer-local in open_graph. ────────────────────────

-- q: HIDE the host window (§14) — keeps the buffer + stack so <leader>wg returns.
local function h_q(ctx) nav.hide(ctx.host_root) end
-- <C-w>q: DESTROY the host window + clear its state (§14).
local function h_destroy(ctx) nav.destroy(ctx.host_root) end

-- m: cycle the merge/split style — full reflow.
local function h_merge_style(ctx)
    merge_style_index = (merge_style_index % #MERGE_STYLES) + 1
    ctx.opts.merge_style = vim.deepcopy(MERGE_STYLES[merge_style_index].style)
    ctx:save_pref("merge_style")
    ctx:reflow()
    ctx:update_footer()
    ctx:place_cursor()
end

-- C: cycle the lane layout policy (§5.6) — full reflow.
--
-- The index is derived from the window's OWN `ctx.opts.layout_policy` (not a
-- module-level counter), so two graphs can sit at two policies at once — the
-- point of the feature. `reflow()` rather than `refresh()`: a different placement
-- can change which markers pack (§10.4), so the display item count can change and
-- the listview needs `set_items`. `goto_hash` is not optional either — without
-- re-anchoring on the same commit the two renderings can't be compared row for
-- row, which is the whole reason the toggle exists.
local function h_layout_policy(ctx)
    local keep
    local ok, pos = pcall(vim.api.nvim_win_get_cursor, ctx:win())
    if ok then keep = ctx:cursor_hash(pos[1]) end
    local i = layout_policy_index(ctx.opts.layout_policy) % #LAYOUT_POLICIES + 1
    ctx.opts.layout_policy = LAYOUT_POLICIES[i].policy
    -- The panes hold a shallow copy of `opts` frozen at window creation, so the
    -- footer would silently keep the open-time policy and read as a pane bug.
    if ctx.pane_opts then ctx.pane_opts.layout_policy = ctx.opts.layout_policy end
    ctx:save_pref("layout_policy")
    ctx:reflow()
    ctx:update_footer()
    if keep then ctx:goto_hash(keep) end
    ctx:place_cursor()
end

-- M: toggle graph mirroring — render-only.
local function h_mirror(ctx)
    ctx.opts.mirror = not ctx.opts.mirror
    ctx:save_pref("mirror")
    if ctx.lv and ctx.lv.controller then ctx.lv.controller.refresh() end
    ctx:update_footer()
    ctx:update_panes()
    ctx:place_cursor()
end

-- B: cycle ref label placement (right / inline / dual; §6.1) — relayout.
local function h_label_mode(ctx)
    label_mode_index = (label_mode_index % #LABEL_MODES) + 1
    ctx.opts.label_mode = LABEL_MODES[label_mode_index].mode
    ctx:save_pref("label_mode")
    ctx.selection_state.index = nil
    if ctx.lv and ctx.lv.controller then ctx.lv.controller.relayout() end
    ctx:update_footer()
    ctx:update_cone()
    ctx:place_cursor()
end

-- <Space>: quick collapse ⇄ expand (§10.4); while selecting, fold/unfold (§13.4).
local function h_space(ctx)
    if ctx.sel.active then selection_toggle(ctx); return end
    local line = vim.api.nvim_win_get_cursor(ctx:win() --[[@as integer]])[1]
    local b = ctx:branch_under_cursor(line)
    if b then GRAPH_HELPERS.toggle_branch(ctx, b) end
end

-- <CR>: examine — the commit view (§11.1) of the row's commit, never a menu: a
-- plain row's commit (a §4.2 working-tree row included), the commit holding the
-- ref selected with h/l, a collapsed head's tip, a packed line's selected marker's
-- tip (the first marker when none is selected). While selecting, the range commit
-- view (§13.5). Every other row action is in the <C-Space> palette (§17).
local function h_cr(ctx)
    if ctx.sel.active then open_selection_view(ctx); return end
    local w = ctx:win()
    if not w then return end
    local item = ctx:order_at(vim.api.nvim_win_get_cursor(w)[1])
    if not item then return end
    local c
    if item.type == "markers" then
        local units, st = marker_units(item), ctx.selection_state
        local u = (st.commit == item and st.index and units[st.index]) or units[1]
        c = u and u.marker.tip
    else
        c = selectm.menu_target(item.commit)
    end
    if c then open_commit_view(ctx.opts, c, nil, ctx.repo.root) end
end

-- D: external diff of the commit, or (selecting) the range (§11.5/§13.5).
local function h_diff(ctx)
    if ctx.sel.active then open_selection_diff(ctx); return end
    local w = ctx:win()
    if not w then return end
    local line = vim.api.nvim_win_get_cursor(w)[1]
    local item = ctx:order_at(line)
    if not item or not item.commit or item.commit.collapsed then return end
    open_diff(ctx.opts, item.commit, ctx.repo.root)
end

-- K: float with the lane breakdown for the commit under the cursor.
local function h_lane(ctx)
    local w = ctx:win()
    if not w then return end
    local line = vim.api.nvim_win_get_cursor(w)[1]
    local item = ctx:order_at(line)
    if not item or not item.commit then return end
    vim.lsp.util.open_floating_preview(format_lane_info(item), "", {
        border = "rounded",
        focusable = true,
        zindex = float_zindex(w),
    })
end

-- d: toggle the date column — render-only.
local function h_date(ctx)
    ctx.opts.date_mode = (ctx.opts.date_mode == "relative") and "absolute" or "relative"
    ctx:save_pref("date_mode")
    if ctx.lv and ctx.lv.controller then ctx.lv.controller.refresh() end
    ctx:place_cursor()
end

-- H: toggle reachability dimming (§12) — render-only.
local function h_dim(ctx)
    ctx.opts.highlight = ctx.opts.highlight == false
    ctx:save_pref("highlight")
    ctx:update_cone()
    if ctx.lv and ctx.lv.controller then ctx.lv.controller.refresh() end
    ctx:maybe_update_panes()
    ctx:place_cursor()
end

-- R: resync with the repository (§3.4).
local function h_resync(ctx) ctx:resync(false) end

-- <C-Space> / <C-@>: the command palette (§17) — gitloom's single action menu.
-- Classifies the cursor row (plain / branch / markers, a packed line's selected
-- marker included) and hands it, with the §13 selection flag, the cached remotes,
-- the examine state and the key registry, to the pure `palette.palette_entries`:
-- the context entries first, then the global commands, then the context's keys,
-- in a `vim.ui.select`. A registry or key entry runs its own `action`; a row
-- entry's `op` is run here against the row resolved now.
-- A GRAPH_HELPERS field, not a module local: this chunk is at LuaJIT's 200-local
-- limit (see CLAUDE.md), and the palette module is required here for the same reason.
GRAPH_HELPERS.palette = function(ctx)
    local opts, repo = ctx.opts, ctx.repo
    local has_diff = (opts.diff and opts.diff.open) and true or false
    local row, b, units
    local w = ctx:win()
    if w and not ctx.sel.active then
        local line = vim.api.nvim_win_get_cursor(w)[1]
        local item = ctx:order_at(line)
        local st = ctx.selection_state
        local ref_selected = item and st.commit == item.commit and st.index ~= nil
        if item and item.type == "markers" then
            units = marker_units(item)
            local texts = {}
            for i, u in ipairs(units) do texts[i] = u.text end
            b = ctx:branch_under_cursor(line)
            local sel_i = (st.commit == item and st.index and units[st.index]) and st.index or nil
            row = { kind = "markers", markers = texts, commit = b and b.commit, selected = sel_i,
                head = sel_i and units[sel_i].marker or nil }
        elseif item and item.commit and not item.commit.collapsed and not ref_selected then
            row = { kind = "plain", commit = item.commit }
        elseif item then
            b = ctx:branch_under_cursor(line)
            if b then
                local ref = ref_selected and selectm.selected_ref(item.commit, st.index) or nil
                -- A remote branch whose local namesake sits elsewhere (§10.4.1).
                if ref then ref.counterpart = selectm.local_counterpart(ref, repo.refs, repo.head) end
                -- The collapse / expand entries name the row's own owners and,
                -- for a collapse, the keepers that will hold it open (§10.4).
                row = { kind = "branch", state = b.state, commit = b.commit, ref = ref,
                    head = item.commit and item.commit.collapsed and item.commit or nil,
                    own = selectm.owner_label(b.owners or {}, repo.refs),
                    keepers = selectm.owner_label(b.keepers or {}, repo.refs) }
            end
        end
    end
    -- Built from cached state only (the remote list is nil until `load_remotes`
    -- lands, so no per-remote entries yet; HEAD's commit from the cached refs) —
    -- the palette never waits on git.
    local sp = ctx.sel.active and ctx.sel.path
    local entries = require("gitloom.graph.palette").palette_entries({
        row = row, selection = ctx.sel.active, remotes = ctx.remotes,
        remote_log = ctx.remote_log ~= nil, examine = nav.examine[repo.root], has_diff = has_diff, keys = ctx:key_registry(),
        head = selectm.head_target(repo.refs),
        newest = sp and #sp > 0 and real_newest(sp[1]) or nil,
    })
    if #entries == 0 then return end
    -- A packed marker's expand opens its own owners (§10.4, as <Space> on a `◍`);
    -- its hide takes every owner in its signature.
    local function owners_of(u, expand)
        if expand then
            local tip = u.marker.tip
            return tip and selectm.open_owners(ctx.sig_cache.sig, tip.hash, ctx.view_state.owner_tip or {},
                ctx.view_state.effective) or {}
        end
        local owners = {}
        for oid in pairs(u.marker.signature or {}) do owners[#owners + 1] = oid end
        return owners
    end
    local function checkout(spec)
        -- §19.1: `Checking out <ref>` — the branch, or the short hash of a detach.
        local target = spec.argv[#spec.argv]
        if spec.argv[3] == "--detach" then target = target:sub(1, 7) end
        local pop = ctx.progress:start("Checking out " .. target, { own_notices = true })
        git.run_checkout(spec.argv, repo.root).next(function(res)
            vim.schedule(function()
                if res.code ~= 0 then
                    pop:finish("failed")
                    vim.notify(git.format_git_error(table.concat(spec.argv, " ", 1, 2), res),
                        vim.log.levels.ERROR)
                    return
                end
                pop:finish("done")
                ctx:resync(false, {}) -- land on HEAD and name it (§10.4.1)
            end)
        end)
    end
    local function run(e)
        if e.action then
            -- A key's handler may open a picker / float of its own: let the select close first.
            if e.id:sub(1, 4) == "key:" then vim.schedule(function() e.action(ctx) end) else e.action(ctx) end
            return
        end
        local op = e.op
        if op == "diff" then
            open_diff(opts, e.commit, repo.root)
        elseif op == "checkout" then
            checkout(e.checkout)
        elseif op == "checkout_examine" or op == "examine" then
            ctx:examine(e.commit, e.commit)
        elseif op == "examine_worktree" then
            -- §10.4.2: the working tree vs HEAD (from the cached refs, else the
            -- stack's anchor) — nothing checked out, stashed or recorded.
            local head = repo.commits[selectm.head_target(repo.refs) or ""]
            if not head then
                head = e.commit
                while head and head.virtual do head = (head.parents or {})[1] end
            end
            local open = opts.diff and opts.diff.open
            if open then open(git.worktree_examine_range(head, repo.root)) end
        elseif op == "fast_forward" or op == "reset_branch" or op == "checkout_ff"
            or op == "checkout_reset" then
            ctx:branch_sync(op, e.sync)
        elseif e.marker then
            local u = units[e.marker]
            if op == "expand" then
                ctx:set_branch({ owners = owners_of(u, true) }, "normal", u.marker.tip and u.marker.tip.hash)
            else
                ctx:set_branch({ owners = owners_of(u) }, "hidden", nil)
            end
        elseif op == "collapse" or op == "expand" then
            GRAPH_HELPERS.toggle_branch(ctx, b) -- <Space>'s, notices included (§10.4)
        elseif op == "hide" then
            ctx:set_branch({ owners = b.hide_owners or {} }, "hidden", nil)
        end
    end
    vim.ui.select(entries, {
        prompt = "gitloom",
        format_item = function(e) return e.label end,
    }, function(choice)
        if choice then run(choice) end
    end)
end

-- The remote list the palette's per-remote Fetch entries come from (§17.1):
-- `git remote` in the graph's repository root, cached on `ctx.remotes`. Run at
-- open and on every resync; a failed read keeps the previous list.
GRAPH_HELPERS.load_remotes = function(ctx)
    git.fetch_remotes(ctx.repo.root).next(function(names)
        if names then ctx.remotes = names end
    end)
end

-- Palette fetch / pull (§17.3): run `git.remote_command(kind, remote)` async in the
-- graph's repository root with GIT_TERMINAL_PROMPT=0, one at a time per session
-- (`ctx.remote_busy`). Success: INFO notice, then resync. Failure: git's error at
-- ERROR level; a pull resyncs anyway (its fetch half may have moved remote-tracking
-- refs before the fast-forward was refused).
-- `resync` itself returns early once the graph window is gone (§14).
--
-- Live status + log (§17.4): the output is streamed into `ctx.remote_log` (the
-- pure `remote.log_feed`); the operation's message is `remote.status_text`,
-- refreshed by a 1 s uv timer (the elapsed clock) and by output at most every
-- 250 ms; an open log buffer is refreshed with it. The start / outcome notices
-- go through one replaceable `progress.notice()`, which the notify provider
-- also shows the live status through when the notifier can replace (§19.3).
-- The timer stops at the job's end, or on its next tick once the session's
-- teardown has ended the operation.
GRAPH_HELPERS.run_remote = function(ctx, kind, remote)
    local cmd = git.remote_command(kind, remote)
    if not cmd then return end
    if ctx.remote_busy then
        vim.notify(("gitloom: %s is still running"):format(ctx.remote_busy), vim.log.levels.WARN)
        return
    end
    ctx.remote_busy = cmd.label
    local function now() return vim.uv.hrtime() / 1e6 end
    local log = git.new_log(table.concat(cmd.argv, " "), now(), os.time())
    ctx.remote_log = log
    local notice = require("gitloom.progress").notice()
    -- A reported operation (§19.1): `Fetching` / `Fetching <remote>` / `Pulling`,
    -- the running notice's own words. Under fidget its entry replaces that notice
    -- (§19.3); the outcome notices below stay under every provider.
    local op = ctx.progress:start(cmd.running:gsub("^gitloom: ", ""):gsub("…$", ""),
        { own_notices = true, notice = notice, message = git.status_text(log, log.t0) })
    if not op.fidget then notice:show(cmd.running) end
    local timer = vim.uv.new_timer()
    local function stop_timer()
        if timer and not timer:is_closing() then
            timer:stop()
            timer:close()
        end
    end
    local last, pending = 0, false
    local function refresh()
        pending = false
        if log.code then return end
        if op.ended then return stop_timer() end -- the session closed (§19.4)
        last = now()
        op:report(git.status_text(log, last))
        ctx:refresh_remote_log()
    end
    if timer then timer:start(1000, 1000, vim.schedule_wrap(refresh)) end
    ctx:refresh_remote_log(true)
    git.run_remote(cmd.argv, ctx.repo.root, cmd.env, function(stream, data)
        git.log_feed(log, stream, data, now())
        if pending then return end
        local wait = 250 - (now() - last)
        if wait <= 0 then return refresh() end
        pending = true
        vim.defer_fn(refresh, math.ceil(wait))
    end).next(function(res)
        vim.schedule(function()
            stop_timer()
            git.log_finish(log, res.code, now())
            ctx:refresh_remote_log()
            ctx.remote_busy = nil
            local ok = res.code == 0
            op:finish(ok and "done" or "failed")
            if ok then
                -- Ref counts by git's flag column (§17.4).
                notice:show(git.summary_text(cmd, git.ref_summary(res.err)), vim.log.levels.INFO)
            else
                -- git's fatal:/error: line, not the progress / hints ahead of it.
                local err = git.failure_text(res.out, res.err)
                notice:show(git.format_git_error(cmd.label, { code = res.code, err = err }),
                    vim.log.levels.ERROR)
            end
            if ok or cmd.resync_on_failure then ctx:resync(false) end
        end)
    end)
end

-- The fetch log (§17.4): the running or last fetch / pull's `ctx.remote_log` in a
-- read-only scratch float over the graph (`q` closes). Re-running it while the log
-- is open focuses that window. `ctx.remote_log_buf` is how `refresh_remote_log`
-- finds it for the live updates; cleared when the buffer is wiped.
GRAPH_HELPERS.show_remote_log = function(ctx)
    if not ctx.remote_log then return end
    local lb = ctx.remote_log_buf
    if lb and vim.api.nvim_buf_is_valid(lb) then
        local w = vim.fn.bufwinid(lb)
        if w ~= -1 then return vim.api.nvim_set_current_win(w) end
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].modifiable = false
    local width = math.max(20, math.min(vim.o.columns - 4, 120))
    local height = math.max(3, math.floor(vim.o.lines * 0.6))
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor", width = width, height = height,
        row = math.floor((vim.o.lines - height) / 2) - 1, col = math.floor((vim.o.columns - width) / 2),
        style = "minimal", border = "rounded", title = " fetch log  (q close) ",
        zindex = float_zindex(ctx:win()),
    })
    pcall(vim.api.nvim_set_option_value, "winhl", "Normal:NormalFloat", { win = win })
    ctx.remote_log_buf = buf
    vim.keymap.set("n", "q", function()
        if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    end, { buffer = buf, nowait = true, desc = "gitloom: close the fetch log" })
    vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, once = true, callback = function()
        if ctx.remote_log_buf == buf then ctx.remote_log_buf = nil end
    end })
    ctx:refresh_remote_log(true)
end

-- Re-render the open fetch log buffer (§17.4), if any, from `ctx.remote_log`.
-- Follows the end when `follow`, or when the cursor was on the last line.
GRAPH_HELPERS.refresh_remote_log = function(ctx, follow)
    local buf, log = ctx.remote_log_buf, ctx.remote_log
    if not (buf and log and vim.api.nvim_buf_is_valid(buf)) then return end
    local win = vim.fn.bufwinid(buf)
    if win ~= -1 and not follow then
        follow = vim.api.nvim_win_get_cursor(win)[1] >= vim.api.nvim_buf_line_count(buf)
    end
    local lines = git.log_lines(log, vim.uv.hrtime() / 1e6)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    if follow and win ~= -1 then vim.api.nvim_win_set_cursor(win, { #lines, 0 }) end
end

-- Branch sync (§17.2): fast-forward (`op == "fast_forward"`) or reset
-- (`"reset_branch"`) the local branch `t` to its upstream, in the graph's
-- repository root. The decisions are the pure `gitloom.git.sync`; the state is
-- read afresh first (`git.sync_probe`) — which branch is CURRENT comes from that
-- read, never from the cached decoration, so a stale label cannot aim a
-- `reset --hard` at another branch. A reset asks (Cancel first) and re-reads
-- right before running, aborting if anything it showed changed. Shares
-- `ctx.remote_busy` with fetch / pull / examine; success → INFO + resync.
-- `"checkout_ff"` / `"checkout_reset"` (§10.4.1: a remote branch whose local
-- namesake tracks it from elsewhere) also check `t.branch` out: when the probe
-- finds it is not current, `sync.checkout_commands` (fetch . + switch / switch -C)
-- runs and success resyncs following HEAD; when it is current, they are the plain
-- current-branch sync. A switch refused after the fast-forward: the error, then a
-- silent resync (the branch did move).
GRAPH_HELPERS.branch_sync = function(ctx, op, t)
    if not t then return end
    if ctx.remote_busy then
        vim.notify(("gitloom: %s is still running"):format(ctx.remote_busy), vim.log.levels.WARN)
        return
    end
    local root = ctx.repo.root
    local checkout = op == "checkout_ff" or op == "checkout_reset"
    local reset = op == "reset_branch" or op == "checkout_reset"
    ctx.remote_busy = (checkout and "checkout of " or reset and "reset of " or "fast-forward of ") .. t.branch
    local function done() ctx.remote_busy = nil end
    local function fail(label, res)
        done()
        vim.notify(ctx:git_failure(label, res), vim.log.levels.ERROR)
    end
    -- `cmds` run in order; `notice` (a plain sync) or `note` (a checkout's
    -- follow-HEAD notice, §10.4.1) names the result.
    local function exec(cmds, notice, note)
        -- The git commands alone are the reported operation (§19.1) — not the
        -- probe or the prompt ahead of them.
        local title = (note and "Checking out " or reset and "Resetting " or "Fast-forwarding ") .. t.branch
        local pop = ctx.progress:start(title, { own_notices = true,
            message = note and (reset and "resetting" or "fast-forwarding") or nil })
        git.run_steps(cmds, root, function(i)
            if i == 2 then pop:report("switching") end -- the checkout's switch (§19.1)
        end).next(function(res)
            vim.schedule(function()
                if res.code ~= 0 then
                    pop:finish("failed")
                    fail(res.failed and res.failed.label or "git", res)
                    -- The fast-forward landed before the switch was refused.
                    if note and (res.step or 1) > 1 then ctx:resync(true) end
                    return
                end
                pop:finish("done")
                done()
                if note then return ctx:resync(false, { note = note }) end
                vim.notify(notice, vim.log.levels.INFO)
                ctx:resync(false)
            end)
        end)
    end
    git.sync_probe(t, root).next(function(before)
        vim.schedule(function()
            if before.err then return fail("git rev-list", before.err) end
            local why = git.sync_unavailable(t, before)
            if why then
                done()
                vim.notify(why, vim.log.levels.WARN)
                return
            end
            local current = before.head_branch == t.branch
            local switching = checkout and not current
            local function run_it()
                if switching then
                    return exec(git.checkout_commands(t, reset), nil, git.checkout_note(t, before, reset))
                end
                if reset then return exec({ git.reset_command(t, current) }, git.reset_done(t, before)) end
                return exec({ git.ff_command(t, current) }, git.ff_done(t, before))
            end
            if not reset then return run_it() end
            vim.ui.select({ "Cancel", "Reset" }, {
                prompt = git.prompt_text(git.reset_prompt(t, before, switching)),
            }, function(_, idx)
                if idx ~= 2 then return done() end
                git.sync_probe(t, root).next(function(after)
                    vim.schedule(function()
                        local stale = git.sync_stale(t, before, after)
                        if stale then
                            done()
                            vim.notify(stale, vim.log.levels.WARN)
                            return
                        end
                        run_it()
                    end)
                end)
            end)
        end)
    end)
end

-- ── Checkout & examine (§10.4.2) — window glue. The decisions are the pure
-- `gitloom.git.examine` plans, the git side `fetch.examine_probe/_run/_return`;
-- these prompt, notify, open the provider, keep `nav.examine[root]` and resync.
-- One at a time per session, sharing `ctx.remote_busy` with fetch / pull (both
-- move HEAD or the working tree). `resync` returns early once the graph window is
-- gone (§14), so a job finishing after a close changes nothing on screen.

-- A failed step as one line: git's fatal:/error: line first (§17.3's formatting).
GRAPH_HELPERS.git_failure = function(_, label, res)
    return git.format_git_error(label, { code = res.code, err = git.failure_text(res.out, res.err) })
end

-- Check `newer` out (detached) and open the single-rev range on `older`'s base
-- (§10.4.2); a dirty tree asks before stashing. `newer == older` for one commit.
-- A newer end that is HEAD's commit (cached refs) or a §4.2 node is Examine: the
-- range opens at once, with no probe, checkout, stash or examine state.
GRAPH_HELPERS.examine = function(ctx, newer, older)
    local open = ctx.opts.diff and ctx.opts.diff.open
    if not open then
        vim.notify("gitloom: no diff provider configured (set diff.open)", vim.log.levels.WARN)
        return
    end
    local root = ctx.repo.root
    local head_hash = selectm.head_target(ctx.repo.refs)
    if not git.needs_checkout(newer, head_hash) then
        -- The working tree already is the newer end (a §4.2 node, or HEAD's own
        -- commit — Examine): nothing to check out, stash or record (§10.4.2).
        local plan = git.examine_plan({ newer = newer, older = older, root = root,
            head = head_hash and { hash = head_hash } or nil })
        if plan.range then open(plan.range) end
        return
    end
    if ctx.remote_busy then
        vim.notify(("gitloom: %s is still running"):format(ctx.remote_busy), vim.log.levels.WARN)
        return
    end
    ctx.remote_busy = "checkout & examine"
    local function done() ctx.remote_busy = nil end
    git.examine_probe(root).next(function(probe)
        vim.schedule(function()
            if probe.err then
                done()
                vim.notify(ctx:git_failure("git status", probe.err), vim.log.levels.ERROR)
                return
            end
            local plan = git.examine_plan({ newer = newer, older = older, status = probe.status,
                head = probe.head, state = nav.examine[root], root = root })
            if plan.kind ~= "checkout" then
                done()
                if plan.kind == "refuse" then
                    vim.notify(plan.reason, vim.log.levels.WARN)
                elseif plan.range then
                    open(plan.range)
                end
                return
            end
            local short = newer.hash:sub(1, 7)
            local function go()
                -- From the confirmed stash / checkout on, a reported operation
                -- (§19.1) — not the probe or the prompt — ended on every branch.
                local op = ctx.progress:start("Examining " .. short, { own_notices = true })
                git.examine_run(plan, root, function(step) op:report(step) end).next(function(r)
                    vim.schedule(function()
                        done()
                        op:finish(r.ok and "done" or "failed")
                        if r.ok then
                            local st = plan.state --[[@as ExamineState]]
                            if plan.stash then
                                -- Nothing actually stashed (e.g. only a dirty submodule).
                                st.stash = r.stash
                                if not r.stash then st.stash_message = nil end
                            end
                            nav.examine[root] = st
                            -- Land on HEAD (the examined commit) and name it; the
                            -- notice says how to get back (§10.4.2).
                            ctx:resync(false, { note = ("examining — %s from the palette (<C-Space>)")
                                :format(git.return_plan(st).label) })
                            open(plan.range)
                            return
                        end
                        if r.stage == "stash" then
                            vim.notify(ctx:git_failure("git stash push", r.res), vim.log.levels.ERROR)
                            return
                        end
                        local msg = ctx:git_failure("git checkout", r.res)
                        if r.stash then
                            msg = msg .. (r.restored and " — your changes were restored"
                                or (" — re-applying the stash failed; it was kept: %s")
                                    :format(plan.stash.message))
                            ctx:resync(false) -- the working tree went through the stash
                        end
                        vim.notify(msg, vim.log.levels.ERROR)
                    end)
                end)
            end
            if not plan.stash then go(); return end
            local n = plan.stash.count
            local choices = { ("Stash %d change%s and continue"):format(n, n == 1 and "" or "s"), "Cancel" }
            vim.ui.select(choices, {
                prompt = ("gitloom: the working tree is dirty — examine %s"):format(short),
            }, function(_, idx)
                if idx == 1 then go() else done() end
            end)
        end)
    end)
end

-- Checkout & examine the active §13 selection (the palette's `selection` scope):
-- its newest .. oldest real ends, as the range view and `D` use them (§13.5).
GRAPH_HELPERS.examine_selection = function(ctx)
    local p = ctx.sel.path
    if not (p and #p > 0) then return end
    local newer, older = real_newest(p[1]), real_oldest(ctx, p[#p])
    if newer and older then ctx:examine(newer, older) end
end

-- Return (§10.4.2): switch back to `orig`, re-apply the examine's stash by SHA with
-- `--index` (falling back to a plain apply, with a WARN, when git refuses to restore
-- the index; dropped only after a clean apply). A failed switch keeps the state (retry); a
-- failed apply keeps the stash, names it, and clears the state.
GRAPH_HELPERS.examine_return = function(ctx)
    local root = ctx.repo.root
    local st = nav.examine[root]
    if not st then return end
    if ctx.remote_busy then
        vim.notify(("gitloom: %s is still running"):format(ctx.remote_busy), vim.log.levels.WARN)
        return
    end
    local rp = git.return_plan(st)
    ctx.remote_busy = rp.label
    -- A reported operation (§19.1): `Returning to <ref>` (the branch, or the
    -- short hash of a detached origin), ended on every branch below.
    local back = rp.switch[#rp.switch]
    if rp.switch[3] == "--detach" then back = back:sub(1, 7) end
    local op = ctx.progress:start("Returning to " .. back, { own_notices = true })
    git.examine_return(rp, root, function(step) op:report(step) end).next(function(r)
        vim.schedule(function()
            ctx.remote_busy = nil
            op:finish(r.ok and "done" or "failed")
            if not r.ok and r.stage == "switch" then
                vim.notify(ctx:git_failure(table.concat(rp.switch, " ", 1, 2), r.res), vim.log.levels.ERROR)
                return -- HEAD did not move: keep the state so Return can be retried
            end
            nav.examine[root] = nil
            if r.ok then
                if r.unstaged then
                    -- git refused `--index`; the plain apply brought the changes back.
                    vim.notify("gitloom: the staged state could not be restored — the changes are back, but unstaged",
                        vim.log.levels.WARN)
                end
                -- The resync names where HEAD landed (§10.4.2).
                ctx:resync(false, { note = rp.apply and (r.unstaged and "changes restored (unstaged)"
                    or "changes restored") or nil })
            else
                vim.notify(ctx:git_failure("git stash apply", r.res)
                    .. (" — the stash was kept: %s"):format(rp.stash_message or rp.stash),
                    vim.log.levels.ERROR)
                ctx:resync(true, {}) -- HEAD did move: land on it, keep the ERROR visible
            end
        end)
    end)
end

-- S: cycle the row sort mode (§3.1).
local function h_sort(ctx)
    local keep
    local ok, pos = pcall(vim.api.nvim_win_get_cursor, ctx:win())
    if ok then keep = ctx:cursor_hash(pos[1]) end
    sort_mode_index = (sort_mode_index % #SORT_MODES) + 1
    ctx.opts.sort_mode = SORT_MODES[sort_mode_index].id
    ctx:save_pref("sort_mode")
    -- A `rev` mode asks git for the order (async), a reported operation (§19.1);
    -- the topo mode is synchronous and reports nothing.
    local mode = SORT_MODES[sort_mode_index]
    local op = mode.rev and ctx.progress:start("Sorting by " .. mode.label)
        or require("gitloom.progress").null_op()
    ctx:apply_sort().next(function()
        op:finish("done")
        ctx:reflow()
        ctx:update_footer()
        if keep then ctx:goto_hash(keep) end
        ctx:place_cursor()
        ctx:update_cone()
        if ctx.lv and ctx.lv.controller then ctx.lv.controller.refresh() end
        ctx:update_panes()
    end)
end

-- c: toggle first-parent focus (§10.7) — reflow.
local function h_focus(ctx)
    ctx.opts.collapse_merged = ctx.opts.collapse_merged == false
    ctx:save_pref("collapse_merged")
    ctx:reflow()
    ctx:update_footer()
    ctx:place_cursor()
end

-- p: toggle marker packing (§10.4) — reflow.
local function h_pack(ctx)
    ctx.opts.pack_markers = ctx.opts.pack_markers == false
    ctx:save_pref("pack_markers")
    ctx:reflow()
    ctx:update_footer()
    ctx:place_cursor()
end

-- The ref-picker row formatter (§2), shared by the `<leader>b` jump picker and the
-- pinned-branches dialog's "Pin new branch…" entry (§10.6.1) so both list refs
-- identically. (A GRAPH_HELPERS field, not a module local — see effective_pins.)
GRAPH_HELPERS.ref_picker_format = function(ctx, align)
    local opts = ctx.opts
    ---@param item { name: string, kind: string, short: string, subject: string, track?: Upstream }
    return function(item)
        local kind_hl = ({
            head = "SnacksPickerGitBranchCurrent",
            ["local"] = "SnacksPickerGitBranch",
            remote = "SnacksPickerGitBranch",
            tag = "SnacksPickerLabel",
            worktree = "SnacksPickerLabel", -- a linked worktree's HEAD (§3.2)
        })[item.kind]
        local track_hl = (opts.palette and opts.palette.track) or {}
        local ret = {}
        ret[#ret + 1] = { align(item.name, 28, { truncate = true }), kind_hl }
        for _, seg in ipairs(git.track_segments(item.track, opts.icons and opts.icons.upstream)) do
            ret[#ret + 1] = { seg.text, track_hl[seg.kind] }
        end
        ret[#ret + 1] = { " " }
        ret[#ret + 1] = { align(item.short, 8), "SnacksPickerGitCommit" }
        ret[#ret + 1] = { " " }
        ret[#ret + 1] = { item.subject, "SnacksPickerComment" }
        return ret
    end
end

-- Jump the graph to a ref's commit and pre-select its label on the landed row
-- (§2). Shared by the `<leader>b` picker and the pinned-branches dialog's `<CR>`
-- (§10.6.1). `gwin` is the graph window to refocus (a picker/dialog float steals
-- focus, and snacks restores it to the window *behind* the float on close).
GRAPH_HELPERS.jump_to_ref = function(ctx, gwin, name, kind, hash)
    if not (gwin and vim.api.nvim_win_is_valid(gwin)) then return end
    pcall(vim.api.nvim_set_current_win, gwin)
    if not ctx:goto_hash(hash) then
        vim.notify(("gitloom: %s is not visible (hidden?)"):format(name), vim.log.levels.INFO)
        return
    end
    local line = vim.api.nvim_win_get_cursor(gwin)[1]
    local landed = ctx:order_at(line)
    local selection_state = ctx.selection_state
    selection_state.commit, selection_state.index = nil, nil
    if landed and landed.type == "markers" then
        for i, u in ipairs(marker_units(landed)) do
            for _, r in ipairs(u.marker.refs or {}) do
                if r.name == name then
                    selection_state.commit, selection_state.index = landed, i
                    break
                end
            end
            if selection_state.commit == landed and selection_state.index == i then break end
        end
    elseif landed and landed.commit then
        local idx = ref_decoration_index(landed.commit, name, kind)
        if idx then
            selection_state.commit, selection_state.index = landed.commit, idx
        end
    end
    ctx:center_view()
    ctx:update_cone()
    if ctx.lv and ctx.lv.controller then ctx.lv.controller.refresh() end
    ctx:place_cursor()
    -- Mark the landed row visited so the CursorMoved reset keeps our
    -- pre-selection; record the remembered position (§2) too.
    ctx.last_line = vim.api.nvim_win_get_cursor(gwin)[1]
    local h = ctx:cursor_hash(ctx.last_line)
    if h then saved_positions[ctx.repo_key] = h end
    ctx:update_panes()
    return true
end

-- %: cycle the row's branch between its local and remote counterparts (§2). The
-- source is the h/l-selected ref, else the row's first branch label; the target
-- is the next member of `selectm.ref_cycle_next`, jumped to like `<leader>b`.
-- A local branch and its same-named remotes on one commit share ONE label (one
-- selection index), so the selection alone cannot say which member is current:
-- `ctx.ref_cycle_last` remembers the ref `%` landed on and the selection it left,
-- and while the selection is still exactly that one (same row object, same index
-- — any h/l, row move or reflow invalidates it) the cycle continues from it. When
-- the cursor stays on its row, a notice names the new ref (`origin/dev (2/3)`).
GRAPH_HELPERS.ref_cycle = function(ctx)
    local w = ctx:win()
    if not w or ctx.sel.active then return end
    local line = vim.api.nvim_win_get_cursor(w)[1]
    local item = ctx:order_at(line)
    if not item then return end
    local st = ctx.selection_state
    local commit, index
    if item.type == "markers" then
        -- A packed line: the selected marker (else the first), its first branch.
        local units = marker_units(item)
        local u = units[(st.commit == item and st.index) or 1]
        commit = u and u.marker
    else
        commit = item.commit
        index = (commit and st.commit == commit) and st.index or nil
    end
    local src = selectm.cycle_source(commit, index)
    if not src or (src.kind ~= "local" and src.kind ~= "remote") then
        vim.notify("gitloom: no branch on this row to cycle", vim.log.levels.INFO)
        return
    end
    local current, refs = src.name, ctx.repo.refs
    local last = ctx.ref_cycle_last
    if last and st.index and last.sel == st.commit and last.index == st.index then
        local lr = refs[last.name]
        local short = src.short or src.name
        local lshort = lr and (lr.kind == "remote" and last.name:match("^[^/]+/(.+)$") or last.name)
        if lshort == short then current = last.name end
    end
    local visible = selectm.visible_hashes(ctx.repo.display)
    local nxt, members, short = selectm.ref_cycle_next(refs, ctx.remotes, current, visible)
    if not nxt then
        if members == "alone" then
            vim.notify(("gitloom: no other ref for %s"):format(short), vim.log.levels.INFO)
        elseif members == "hidden" then
            vim.notify(("gitloom: no other visible ref for %s"):format(short), vim.log.levels.INFO)
        else
            vim.notify("gitloom: no branch on this row to cycle", vim.log.levels.INFO)
        end
        return
    end
    if not ctx:jump_to_ref(w, nxt.name, nxt.kind, nxt.hash) then return end
    ctx.ref_cycle_last = { name = nxt.name, sel = st.commit, index = st.index }
    if vim.api.nvim_win_get_cursor(w)[1] == line then
        local pos = 1
        for i, m in ipairs(members --[[@as RefCycleMember[] ]]) do
            if m.name == nxt.name then pos = i end
        end
        vim.notify(("gitloom: %s (%d/%d)"):format(nxt.name, pos, #members), vim.log.levels.INFO)
    end
end

-- <leader>b: jump to a branch / ref via snacks.picker (§2).
local function h_refpick(ctx)
    local repo = ctx.repo
    local gwin = ctx:win() -- the graph window to refocus / move
    local picker_ok, picker = pcall(require, "snacks.picker")
    if not picker_ok then
        vim.notify("gitloom: snacks.picker not available", vim.log.levels.WARN)
        return
    end
    local items = ref_picker_items(repo.refs, recent_refs[ctx.repo_key])
    if #items == 0 then
        vim.notify("gitloom: no refs to jump to", vim.log.levels.INFO)
        return
    end
    -- ref_picker_items sets each item's `text` for fuzzy matching; snacks keeps the
    -- original (MRU) order when the query is empty.
    picker.pick({
        source = "gitloom_refs",
        title = "Gitloom refs",
        items = items,
        layout = { preset = "select" }, -- compact, no preview window
        format = ctx:ref_picker_format(picker.util.align),
        confirm = function(p, item)
            p:close()
            if not item then return end
            recent_refs[ctx.repo_key] = bump_recent(recent_refs[ctx.repo_key], item.name)
            -- Run after the picker tears down — snacks restores focus to the window
            -- behind the float, so refocus the graph first.
            vim.schedule(function()
                ctx:jump_to_ref(gwin, item.name, item.kind, item.hash)
            end)
        end,
    })
end

-- <leader>gl (and :GitloomSearch): fuzzy commit search (spec §15). A snacks.picker
-- over the in-memory commit set — matching subject + author, already resident so
-- there is no fetch and no cache (§15.2). The preview shows the commit view (§11)
-- under a graph snippet locating the commit (§15.3); confirm jumps and centers the
-- graph (within-view navigation, §14.2 / §15.4). (`/` is the filter-search, §16.)
local function h_commit_search(ctx)
    local opts, repo = ctx.opts, ctx.repo
    local gwin = ctx:win() -- the graph window to refocus / move on confirm
    local picker_ok, picker = pcall(require, "snacks.picker")
    if not picker_ok then
        vim.notify("gitloom: snacks.picker not available", vim.log.levels.WARN)
        return
    end

    -- Items from repo.order (1:1 with commits, the §3.1 --all set). Skip the
    -- working-tree virtual commits (§4.2) — they are not real commits.
    local items = {}
    for _, it in ipairs(repo.order or {}) do
        local c = it.commit
        if c and c.hash and not c.virtual then
            local subject, author = c.message or "", c.author or ""
            local ok, rel = pcall(function() return c.date and format_relative(c.date) or "" end)
            items[#items + 1] = {
                hash = c.hash,
                short = c.hash:sub(1, 8),
                subject = subject,
                author = author,
                reldate = ok and rel or "",
                text = subject .. "  " .. author, -- the fuzzy haystack (§15.2)
            }
        end
    end
    if #items == 0 then
        vim.notify("gitloom: no commits to search", vim.log.levels.INFO)
        return
    end

    -- Full hash -> repo.display row map for the snippet focus (§15.3), including
    -- collapsed region members -> their head's row, so a folded commit locates on
    -- its collapsed head (§10.3). Stable for the picker session (no reflow then).
    local row_of = {}
    local function map_row(node, i)
        if node and node.hash then row_of[node.hash] = i end
        for _, h in ipairs((node and node.region) or {}) do row_of[h] = i end
    end
    for i, dit in ipairs(repo.display or {}) do
        if dit.commit then map_row(dit.commit, i) end
        if dit.type == "markers" then
            for _, m in ipairs(dit.markers or {}) do map_row(m, i) end
        end
    end

    local search_opts = opts.search or {}
    local radius = math.max(0, math.floor(((search_opts.snippet or 7) - 1) / 2))

    -- Per-hash session cache of the fetched detail/diff (§15.3). `showing` is the
    -- hash the preview currently wants; a late fetch writes only if still current
    -- (snacks reuses one preview buffer across items).
    local detail_cache = {}
    local showing = nil

    local function render_preview(pctx)
        local prev = pctx.preview
        local pbuf = prev.win and prev.win.buf
        if not (pbuf and vim.api.nvim_buf_is_valid(pbuf)) then return end
        local item = pctx.item
        local commit = repo.commits[item.hash]
        local rows = {}

        -- Graph snippet (§15.3): the commit's neighbourhood in repo.display.
        local focus = row_of[item.hash]
        if focus then
            for _, r in ipairs(render.graph_snippet(opts, repo.display, focus, radius)) do
                rows[#rows + 1] = r
            end
        else
            rows[#rows + 1] = highlight_text("(not shown in the current view)", "Comment")
        end
        rows[#rows + 1] = highlight_text("")

        -- Commit detail (§11.2 via build_commit_rows) once fetched + present.
        local cached = detail_cache[item.hash]
        if commit and cached then
            for _, r in ipairs(build_commit_rows(opts, {
                commit = commit, meta = cached.meta, diff = cached.diff,
                action = false, -- not actionable in a preview
                width = M.commit_wrap_width(prev.win and prev.win.win), -- §11.2.1
            })) do
                rows[#rows + 1] = r
            end
        elseif commit then
            rows[#rows + 1] = highlight_text("Loading…", "Comment")
        end

        local lines, ns = {}, prev:ns()
        for _, r in ipairs(rows) do lines[#lines + 1] = r.text end
        prev:set_lines(lines)
        vim.api.nvim_buf_clear_namespace(pbuf, ns, 0, -1)
        for i, r in ipairs(rows) do
            for _, hl in ipairs(r.highlight or {}) do
                if hl.hl then
                    pcall(vim.api.nvim_buf_set_extmark, pbuf, ns, i - 1, hl.start_pos,
                        { end_col = hl.end_pos, hl_group = hl.hl })
                end
            end
        end

        -- Centre on the match (§15.3): the first line with a query token, else
        -- the commit subject. Done in the preview window.
        local pwin = prev.win and prev.win.win
        if pwin and vim.api.nvim_win_is_valid(pwin) then
            local pat = pctx.picker and pctx.picker.input and pctx.picker.input.filter
                and pctx.picker.input.filter.pattern or ""
            local target = nil
            for tok in tostring(pat):gmatch("%S+") do
                local needle = tok:lower()
                for i, l in ipairs(lines) do
                    if l:lower():find(needle, 1, true) then target = i break end
                end
                if target then break end
            end
            if not target and item.subject ~= "" then
                for i, l in ipairs(lines) do
                    if l:find(item.subject, 1, true) then target = i break end
                end
            end
            if target then
                pcall(vim.api.nvim_win_set_cursor, pwin, { target, 0 })
                pcall(vim.api.nvim_win_call, pwin, function() vim.cmd("normal! zz") end)
            end
        end
    end

    picker.pick({
        source = "gitloom_search",
        title = "Gitloom search",
        items = items,
        -- Float above the graph: the single-window z-order model (§2.1/§14) keeps
        -- the host at a fixed zindex, so a transient float sits at float_zindex.
        layout = {
            preset = "default",
            layout = { zindex = float_zindex(gwin) },
        },
        ---@param item { short: string, reldate: string, author: string, subject: string }
        format = function(item)
            local al = picker.util.align
            local ret = {}
            ret[#ret + 1] = { al(item.short, 8), "SnacksPickerGitCommit" }
            ret[#ret + 1] = { " " }
            ret[#ret + 1] = { al(item.reldate, 12), "SnacksPickerComment" }
            ret[#ret + 1] = { " " }
            ret[#ret + 1] = { al(item.author, 16, { truncate = true }), "SnacksPickerGitBranch" }
            ret[#ret + 1] = { " " }
            ret[#ret + 1] = { item.subject, "SnacksPickerComment" }
            return ret
        end,
        preview = function(pctx)
            pctx.preview:reset()
            pctx.preview:minimal()
            -- No wrap: the graph snippet's lanes line up by column, so a wrapped
            -- row would mangle them (and the diff). Scrolls horizontally instead.
            pctx.preview:wo({ wrap = false })
            pctx.preview:set_title(pctx.item.short .. "  " .. pctx.item.subject)
            local hash = pctx.item.hash
            showing = hash
            render_preview(pctx)
            -- Fetch detail + diff on demand (§11.1), then re-render if still
            -- current. Cached per hash for the session.
            if repo.commits[hash] and not detail_cache[hash] then
                fetch_commit_detail(hash).next(function(meta)
                    return fetch_commit_diff(hash).next(function(diff)
                        return { meta = meta, diff = diff }
                    end)
                end).next(function(res)
                    detail_cache[hash] = res
                    if showing == hash then render_preview(pctx) end
                end)
            end
        end,
        confirm = function(p, item)
            p:close()
            if not item then return end
            -- Run after the picker tears down; snacks restores focus to the window
            -- behind the float, so refocus the graph first (as the ref picker does).
            vim.schedule(function()
                if not (gwin and vim.api.nvim_win_is_valid(gwin)) then return end
                pcall(vim.api.nvim_set_current_win, gwin)
                if not ctx:goto_hash(item.hash) then
                    vim.notify(
                        ("gitloom: %s is not visible (hidden?)"):format(item.short),
                        vim.log.levels.INFO)
                    return
                end
                ctx:center_view()
                ctx:update_cone()
                ctx:update_panes()
            end)
        end,
    })
end

-- The display index of the cursor's row (§16.5), or 1. `order_at` maps a buffer
-- line to its OrderItem + index in repo.display.
local function filter_cursor_index(ctx)
    local w = ctx:win()
    if not w then return 1 end
    local _, idx = ctx:order_at(vim.api.nvim_win_get_cursor(w)[1])
    return idx or 1
end

-- A display row is a **match** when it is a real commit kept by the active filter
-- (§16.3) — the kept matches render as normal commit rows.
local function is_match_row(ctx, item)
    return item and item.commit and ctx.filter and ctx.filter.keep[item.commit.hash] or false
end

-- n / N: move to the next / previous match (§16.5) in row order, wrapping at the
-- ends like Neovim's search. No-op without an active filter.
local function filter_goto(ctx, dir)
    if not ctx.filter then return end
    local display = ctx.repo.display or {}
    local n = #display
    if n == 0 then return end
    local cur = filter_cursor_index(ctx)
    for step = 1, n do
        local i = ((cur - 1 + dir * step) % n) + 1
        if is_match_row(ctx, display[i]) then
            ctx.filter.current = display[i].commit.hash -- drives the §16.7 highlight
            ctx:goto_hash(display[i].commit.hash)
            ctx:center_view()
            ctx:update_cone()
            if ctx.lv and ctx.lv.controller then ctx.lv.controller.refresh() end
            return
        end
    end
    vim.notify("gitloom: no matches", vim.log.levels.INFO)
end

-- Land on the match nearest the cursor (§16.4). Records it as the current match
-- (driving the §16.7 highlight) and refreshes so the highlight follows.
local function filter_land(ctx)
    if not ctx.filter then return false end
    local display = ctx.repo.display or {}
    local cur = filter_cursor_index(ctx)
    local best, bestd
    for i, it in ipairs(display) do
        if is_match_row(ctx, it) then
            local d = math.abs(i - cur)
            if not bestd or d < bestd then best, bestd = it.commit.hash, d end
        end
    end
    if best then
        ctx.filter.current = best
        ctx:goto_hash(best)
        ctx:center_view()
        ctx:update_cone()
        if ctx.lv and ctx.lv.controller then ctx.lv.controller.refresh() end
        return true
    end
    return false
end

-- `/` — in-graph filter-search (spec §16): a live, debounced query contracting the
-- graph to commits whose subject/author match (kept as normal commits, the rest
-- collapsed via §10), with n/N walking the matches. Opens a single-line floating
-- input; the graph re-filters live as you type (debounced, §16.4); <CR> commits,
-- <Esc> cancels (restoring the pre-edit state). `/` while filtered edits in place.
local FILTER_DEBOUNCE_MS = 150
local function h_filter(ctx)
    local gwin = ctx:win()
    if not gwin then return end

    -- The real commit set to match against (stable for this input session, §16.2).
    local commits = {}
    for _, it in ipairs(ctx.repo.order or {}) do
        if it.commit and it.commit.hash and not it.commit.virtual then
            commits[#commits + 1] = it.commit
        end
    end

    -- The graph view at overlay-open, restored on cancel and used as the jumplist
    -- anchor on `<CR>` (§16.4): select_dismiss restores this cursor then jumps to
    -- the match with a real motion, so the pre-filter spot enters the jumplist and
    -- the hybrid `<C-o>` (§14.3) returns here. The pre-filter spot is also tracked
    -- **by hash**, because opening the match's branch (§16.4) shifts line numbers.
    local saved_view = vim.api.nvim_win_call(gwin, vim.fn.winsaveview)
    local pre_hash = ctx:cursor_hash(saved_view.lnum)
    -- The filter active before the overlay opened: nil from the base graph, or the
    -- stamped filter when re-opened over a stamped view (§16.5). Cancel restores it.
    local prev_filter = ctx.filter
    -- Are we editing a **stamped** filter (the current nav frame is a filter frame)?
    -- Then <CR>/<C-s> refine it in place; otherwise <CR> jumps & dismisses and
    -- <C-s> stamps a new one (§16.5).
    local sess = nav.sessions[ctx.host_root]
    local cur_frame = sess and navstack.current(sess.stack)
    local from_stamp = cur_frame ~= nil and cur_frame.kind == "filter"

    local ibuf = vim.api.nvim_create_buf(false, true)
    vim.bo[ibuf].buftype = "nofile"
    -- No autocompletion in the filter box: a completion plugin (e.g. blink.cmp)
    -- attaches on InsertEnter — after our buffer maps — and grabs insert-mode keys
    -- like <C-k> (blink's signature toggle) before they reach us, so <C-k> appears
    -- "dead". Disabling completion keeps the overlay's keys ours (§16.4); a search
    -- box wants no popup anyway. `b:completion` is blink's per-buffer opt-out.
    vim.b[ibuf].completion = false
    -- Seeded with the active query when re-opened over a stamped filter (§16.5).
    vim.api.nvim_buf_set_lines(ibuf, 0, -1, false, { (ctx.filter and ctx.filter.query) or "" })
    local iwin = vim.api.nvim_open_win(ibuf, true, {
        relative = "win", win = gwin,
        anchor = "SW", row = vim.api.nvim_win_get_height(gwin), col = 0,
        width = vim.api.nvim_win_get_width(gwin), height = 1,
        style = "minimal", border = "rounded",
        title = " filter  (C-j/C-k matches · CR jump · C-s stamp · Esc cancel) ",
        zindex = float_zindex(gwin),
    })
    pcall(vim.api.nvim_set_option_value, "winhl", "Normal:NormalFloat", { win = iwin })

    local function buf_query()
        return vim.api.nvim_buf_is_valid(ibuf)
            and (vim.api.nvim_buf_get_lines(ibuf, 0, 1, false)[1] or "") or ""
    end

    -- Apply the query (the live preview); empty => no filter. After reflow keep a
    -- **current match** under the graph cursor (behind the input) so C-j/C-k and
    -- <CR> have a selection — but only re-home it when the cursor fell off a match,
    -- so narrowing the query doesn't yank the view around on every keystroke.
    local function apply(query)
        ctx.filter = selectm.filter_state(commits, query)
        ctx:reflow()
        if ctx.filter then
            local at = ctx:order_at(vim.api.nvim_win_get_cursor(gwin)[1])
            if not (at and at.commit and ctx.filter.keep[at.commit.hash]) then
                filter_land(ctx)
            end
        end
    end

    -- Debounced live rebuild (§16.6): each keystroke re-arms; only the last fires.
    local function schedule()
        ctx.filter_gen = ctx.filter_gen + 1
        local gen = ctx.filter_gen
        vim.defer_fn(function()
            if gen ~= ctx.filter_gen or not vim.api.nvim_win_is_valid(iwin) then return end
            apply(buf_query())
        end, FILTER_DEBOUNCE_MS)
    end

    local function close_input()
        ctx.filter_gen = ctx.filter_gen + 1 -- cancel any pending rebuild
        -- Leave insert mode before handing focus back, or the graph buffer is
        -- entered in insert mode (the input float was insert-mode, §16.4).
        vim.cmd("stopinsert")
        pcall(vim.api.nvim_win_close, iwin, true)
        if vim.api.nvim_buf_is_valid(ibuf) then pcall(vim.api.nvim_buf_delete, ibuf, { force = true }) end
        if vim.api.nvim_win_is_valid(gwin) then pcall(vim.api.nvim_set_current_win, gwin) end
    end

    -- The current match's hash (the commit under the graph cursor), or nil.
    local function current_match_hash()
        local item = ctx:order_at(vim.api.nvim_win_get_cursor(gwin)[1])
        return item and item.commit and item.commit.hash or nil
    end

    -- <Esc>: cancel (§16.4) — restore the pre-overlay filter (nil from base, or the
    -- stamped filter when refining) and the pre-overlay view.
    local function cancel()
        ctx.filter = prev_filter
        close_input()
        ctx:reflow()
        pcall(vim.api.nvim_win_call, gwin, function() vim.fn.winrestview(saved_view) end)
        ctx:update_cone()
        ctx:update_panes()
    end

    -- <CR> from the base overlay: select the current match and dismiss (§16.4) —
    -- discard the filter, return to the base view, cursor on the match.
    local function select_dismiss()
        apply(buf_query()) -- settle the latest query
        local hash = ctx.filter and current_match_hash() or nil
        ctx.filter = nil
        close_input()
        ctx:reflow()
        -- Open the match's branch (§16.4) so we land on the commit itself, not its
        -- collapsed head — this can shift line numbers, so position the cursor at
        -- the pre-filter commit **by hash** before jumping (else fall back to the
        -- saved view). Then **jump** to the match with a real motion so the
        -- pre-filter spot enters the jumplist and `<C-o>` returns there (§14.3).
        if hash then ctx:ensure_expanded(hash) end
        if not (pre_hash and ctx:goto_hash(pre_hash)) then
            pcall(vim.api.nvim_win_call, gwin, function() vim.fn.winrestview(saved_view) end)
        end
        if hash and ctx:goto_hash(hash, true) then
            ctx:center_view()
        end
        ctx:update_cone()
        ctx:update_panes()
    end

    -- <C-s>/<C-CR> from the base overlay: **stamp** the filtered view into a
    -- persistent nav-stack entry (§16.5). It owns an isolated copy of the view
    -- state (§16.1) — installed here and restored by on_show on `<C-o>` — and
    -- reuses the graph buffer (the wipe guard protects it). The frame's on_enter
    -- re-installs the copy + filter when navigated back to.
    local function do_stamp()
        apply(buf_query()) -- settle the latest query
        local filter = ctx.filter
        if not filter then cancel(); return end -- empty query: nothing to stamp
        filter.current = filter.current or current_match_hash()
        local copy_modes = vim.deepcopy(ctx.view_state.modes)
        local copy_pins = vim.deepcopy(ctx.view_state.pins)
        local copy_unpinned = vim.deepcopy(ctx.view_state.unpinned)
        ctx.view_state.modes = copy_modes
        ctx.view_state.pins, ctx.view_state.unpinned = copy_pins, copy_unpinned
        close_input()
        local frame
        frame = {
            kind = "filter", buf = ctx.buf, label = "/ " .. filter.query,
            on_enter = function()
                ctx.view_state.modes = copy_modes
                ctx.view_state.pins, ctx.view_state.unpinned = copy_pins, copy_unpinned
                ctx.filter = frame.filter or filter
                ctx:reflow()
                filter_land(ctx)
                ctx:update_panes()
            end,
            filter = filter,
        }
        nav.push_frame(ctx.host_root, frame)
    end

    -- <CR>/<C-s> while refining a stamped filter (§16.5): update the current frame's
    -- query in place (no new entry), stay in the stamped view, land on a match. An
    -- emptied query is treated as cancel (the stamp is kept; exit with `<C-o>`).
    local function refine()
        apply(buf_query())
        if not ctx.filter then cancel(); return end
        if cur_frame and cur_frame.kind == "filter" then
            cur_frame.filter = ctx.filter
            cur_frame.label = "/ " .. ctx.filter.query
            if sess then nav.render_crumbs(sess) end
        end
        close_input()
        filter_land(ctx)
        ctx:update_panes()
    end

    -- <C-j>/<C-k>: step the current match while the overlay is open (§16.4).
    local function step(dir)
        if ctx.filter then filter_goto(ctx, dir) end
    end

    vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" },
        { buffer = ibuf, callback = schedule })
    local m = { buffer = ibuf, nowait = true }
    vim.keymap.set({ "i", "n" }, "<CR>", from_stamp and refine or select_dismiss, m)
    vim.keymap.set({ "i", "n" }, "<Esc>", cancel, m)
    vim.keymap.set({ "i", "n" }, "<C-j>", function() step(1) end, m)
    vim.keymap.set({ "i", "n" }, "<C-k>", function() step(-1) end, m)
    -- Arrow aliases (robust where <C-k> is shadowed by digraph/config; a
    -- single-line input has no vertical motion of its own, §16.4).
    vim.keymap.set({ "i", "n" }, "<Down>", function() step(1) end, m)
    vim.keymap.set({ "i", "n" }, "<Up>", function() step(-1) end, m)
    vim.keymap.set({ "i", "n" }, "<C-s>", from_stamp and refine or do_stamp, m)
    vim.keymap.set({ "i", "n" }, "<C-CR>", from_stamp and refine or do_stamp, m)

    -- Preview the seed immediately (editing a stamped filter), then type.
    schedule()
    vim.cmd("startinsert!")
end

-- P: pin / unpin the branch under the cursor as an anchor (§10.6).
local function h_pin(ctx)
    local w = ctx:win()
    if not w then return end
    local line = vim.api.nvim_win_get_cursor(w)[1]
    local b = ctx:branch_under_cursor(line)
    -- The selected ref when there is one, else the row's own owners (§10.2).
    local cands = b and (b.selected or b.owners)
    if not cands then return end
    local repo, view_state = ctx.repo, ctx.view_state
    -- Only refs are pinnable (v1, §10.6) — drop anonymous merge-parent owners.
    local targets = {}
    for _, oid in ipairs(cands) do
        if repo.refs[oid] then targets[#targets + 1] = oid end
    end
    if #targets == 0 then return end
    -- Pinning appends to the end of the ordered list (§10.6), unreserved; unpinning
    -- drops the entry — which drops its reserve flag with it — and records the id
    -- so a defaulted anchor does not come straight back.
    local want = not ctx:effective_pinned()[targets[1]]
    local pins = ctx:effective_pins()
    for _, oid in ipairs(targets) do
        if want then
            view_state.unpinned[oid] = nil
            pins = selectm.pin_add(pins, oid)
        else
            view_state.unpinned[oid] = true
            for i, e in ipairs(pins) do
                if e.id == oid then pins = selectm.pin_remove(pins, i); break end
            end
        end
    end
    view_state.pins = pins
    ctx:save_pins()
    ctx:reflow()
    ctx:update_footer()
    if b.follow then ctx:goto_hash(b.follow) end
    ctx:place_cursor()
end

-- L: the pinned-branches dialog (§10.6.1) — a modal float listing the resolved pin
-- list in priority order, where it is reordered (`<C-j>`/`<C-k>`), given a dedicated
-- lane (`<Space>`, §10.6.2), unpinned (`D`), added to ("Pin new branch…", which
-- reuses the §2 ref picker) or jumped from (`<CR>`). Its keys are buffer-local, so
-- they never collide with the graph's own. Every edit reflows the projection and
-- restores the graph cursor to the commit it was on, exactly as `P` does.
-- (A GRAPH_HELPERS field, not a module local — see effective_pins.)
GRAPH_HELPERS.pin_dialog = function(ctx)
    local gwin = ctx:win()
    if not gwin then return end
    local dbuf = vim.api.nvim_create_buf(false, true)
    vim.bo[dbuf].buftype = "nofile"
    vim.bo[dbuf].bufhidden = "wipe"
    local ns = vim.api.nvim_create_namespace("gitloom_pin_dialog")
    local dwin, rows = nil, {}

    -- Paint the list. `focus` is the entry index (or "new") to leave the cursor on.
    local function render(focus)
        local pins = ctx:effective_pins()
        local lines
        lines, rows = selectm.pin_dialog_lines(pins)
        vim.bo[dbuf].modifiable = true
        vim.api.nvim_buf_set_lines(dbuf, 0, -1, false, lines)
        vim.bo[dbuf].modifiable = false
        vim.api.nvim_buf_clear_namespace(dbuf, ns, 0, -1)
        local function hl(row, col, endcol, group)
            pcall(vim.api.nvim_buf_set_extmark, dbuf, ns, row, col,
                { end_col = endcol, hl_group = group })
        end
        hl(0, 0, #lines[1], "Title")
        hl(#lines - 1, 0, #lines[#lines], "Comment") -- the not-yet-honoured note
        -- Mark the per-entry diamonds so the reserved subsequence stands out. The
        -- title row's legend and the closing note keep their own colour.
        for i = 2, #lines - 1 do
            local s = lines[i]:find("◆", 1, true)
            if s then hl(i - 1, s - 1, s - 1 + #"◆", "Special") end
        end
        -- Fit the float to the content, centered over the graph window.
        local w = 0
        for _, l in ipairs(lines) do w = math.max(w, vim.fn.strdisplaywidth(l)) end
        local gw = vim.api.nvim_win_get_width(gwin)
        local gh = vim.api.nvim_win_get_height(gwin)
        w = math.min(w + 2, math.max(20, gw - 4))
        local h = math.min(#lines, math.max(3, gh - 4))
        local cfg = {
            relative = "win", win = gwin,
            row = math.max(0, math.floor((gh - h) / 2)),
            col = math.max(0, math.floor((gw - w) / 2)),
            width = w, height = h,
        }
        if dwin and vim.api.nvim_win_is_valid(dwin) then
            local full = vim.api.nvim_win_get_config(dwin)
            for k, v in pairs(cfg) do full[k] = v end
            pcall(vim.api.nvim_win_set_config, dwin, full)
        else
            cfg.style, cfg.border = "minimal", "rounded"
            cfg.title, cfg.zindex = " pinned branches ", float_zindex(gwin)
            dwin = vim.api.nvim_open_win(dbuf, true, cfg)
            pcall(vim.api.nvim_set_option_value, "winhl", "Normal:NormalFloat", { win = dwin })
            vim.wo[dwin].cursorline = true
        end
        -- Park on the requested entry (falling back to the first selectable row).
        local target
        for l, v in pairs(rows) do
            if v == focus then target = l end
            if not target and v == 1 then target = l end
        end
        if target then pcall(vim.api.nvim_win_set_cursor, dwin, { target, 0 }) end
    end

    -- The entry index (or "new") under the dialog cursor.
    local function under_cursor()
        if not (dwin and vim.api.nvim_win_is_valid(dwin)) then return nil end
        return rows[vim.api.nvim_win_get_cursor(dwin)[1]]
    end

    -- Store an edited list, reflow, and keep the graph cursor on its commit.
    local function commit(pins, focus)
        local ok, cur = pcall(vim.api.nvim_win_get_cursor, gwin)
        local hash = ok and ctx:cursor_hash(cur[1]) or nil
        ctx.view_state.pins = pins
        GRAPH_HELPERS.save_pins(ctx) -- direct: the dialog's test stub carries no helpers
        ctx:reflow()
        if hash then ctx:goto_hash(hash) end
        ctx:place_cursor()
        ctx:update_footer()
        ctx:update_panes()
        render(focus)
    end

    local function close()
        if dwin and vim.api.nvim_win_is_valid(dwin) then pcall(vim.api.nvim_win_close, dwin, true) end
        dwin = nil
        if vim.api.nvim_win_is_valid(gwin) then pcall(vim.api.nvim_set_current_win, gwin) end
    end

    render(1)

    local function h_move(delta)
        local i = under_cursor()
        if type(i) ~= "number" then return end
        local moved, at = selectm.pin_move(ctx:effective_pins(), i, delta)
        commit(moved, at)
    end

    local function h_toggle()
        local i = under_cursor()
        if type(i) ~= "number" then return end
        commit(selectm.pin_toggle_reserved(ctx:effective_pins(), i), i)
    end

    local function h_unpin()
        local list = ctx:effective_pins()
        local i = under_cursor()
        if type(i) ~= "number" or not list[i] then return end
        -- Record the removal so a defaulted anchor (HEAD / master / …) stays gone.
        ctx.view_state.unpinned[list[i].id] = true
        commit(selectm.pin_remove(list, i), math.min(i, math.max(1, #list - 1)))
    end

    -- "Pin new branch…": the §2 ref picker, minus the refs already on the list and
    -- an attached HEAD (its branch is the owner); a detached HEAD is an owner of its
    -- own, so after an unpin it can be pinned back (`pin_candidate`).
    local function h_add()
        local picker_ok, picker = pcall(require, "snacks.picker")
        if not picker_ok then
            vim.notify("gitloom: snacks.picker not available", vim.log.levels.WARN)
            return
        end
        local on = selectm.pin_ids(ctx:effective_pins())
        local items = {}
        for _, it in ipairs(ref_picker_items(ctx.repo.refs, recent_refs[ctx.repo_key])) do
            if selectm.pin_candidate(it, on, ctx.repo.head) then items[#items + 1] = it end
        end
        if #items == 0 then
            vim.notify("gitloom: every ref is already pinned", vim.log.levels.INFO)
            return
        end
        picker.pick({
            source = "gitloom_refs",
            title = "Pin a branch",
            items = items,
            layout = { preset = "select" },
            format = ctx:ref_picker_format(picker.util.align),
            confirm = function(p, item)
                p:close()
                if not item then return end
                vim.schedule(function()
                    if not (dwin and vim.api.nvim_win_is_valid(dwin)) then return end
                    pcall(vim.api.nvim_set_current_win, dwin)
                    ctx.view_state.unpinned[item.name] = nil
                    local added = selectm.pin_add(ctx:effective_pins(), item.name)
                    commit(added, #added)
                end)
            end,
        })
    end

    -- <CR>: on an entry, jump the graph to that branch (§2 semantics); on the last
    -- row, open the picker.
    local function h_enter()
        local i = under_cursor()
        if i == "new" then h_add(); return end
        if type(i) ~= "number" then return end
        local entry = ctx:effective_pins()[i]
        local ref = entry and ctx.repo.refs[entry.id]
        if not (ref and ref.commit) then return end
        recent_refs[ctx.repo_key] = bump_recent(recent_refs[ctx.repo_key], entry.id)
        close()
        ctx:jump_to_ref(gwin, entry.id, ref.kind, ref.commit.hash)
    end

    local map = { buffer = dbuf, nowait = true }
    vim.keymap.set("n", "<C-j>", function() h_move(1) end, map)
    vim.keymap.set("n", "<C-k>", function() h_move(-1) end, map)
    vim.keymap.set("n", "<Space>", h_toggle, map)
    vim.keymap.set("n", "D", h_unpin, map)
    vim.keymap.set("n", "<CR>", h_enter, map)
    vim.keymap.set("n", "q", close, map)
    vim.keymap.set("n", "<Esc>", close, map)
end

-- i: toggle the per-lane id debug column.
local function h_laneids(ctx)
    ctx.opts.show_lane_ids = not ctx.opts.show_lane_ids
    ctx:save_pref("show_lane_ids")
    if ctx.lv and ctx.lv.controller then ctx.lv.controller.refresh() end
    ctx:update_panes()
    ctx:place_cursor()
end

-- F: toggle the context panes (§6.2).
local function h_panes(ctx)
    ctx.opts.panes = ctx.opts.panes == false
    ctx:save_pref("panes")
    ctx:update_panes()
    ctx:place_cursor()
end

-- <leader>wD: write a topology-only debug dump of the live header/footer seam,
-- boundary, condensed graph and rendered overlay buffers to
-- `stdpath('data')/gitloom_pane_dump.txt`, then force a pane rebuild so the dump
-- reflects the current scroll. Diagnostics only (seam-alignment debugging).
local function h_dump(ctx)
    local path = vim.fn.stdpath("data") .. "/gitloom_pane_dump.txt"
    vim.g.gitloom_pane_debug = path
    ctx:update_panes()
    vim.notify("gitloom: pane dump -> " .. path, vim.log.levels.INFO)
end

-- ?: float listing every graph key, generated from the key registry (§2/§17.1).
local function h_help(ctx)
    local lines = require("gitloom.graph.palette").help_lines(ctx:key_registry())
    vim.lsp.util.open_floating_preview(lines, "", {
        border = "rounded",
        focusable = true,
        zindex = float_zindex(ctx:win()),
    })
end

-- V: enter / exit commit selection (§13).
local function h_select(ctx)
    local w = ctx:win()
    if not w then return end
    if ctx.sel.active then exit_selection(ctx) else enter_selection(ctx, vim.api.nvim_win_get_cursor(w)[1]) end
end

local function h_esc(ctx)
    if ctx.sel.active then exit_selection(ctx) end
end

-- The key registry (§17.1) — the single source of truth for every graph key: the
-- buffer-local mappings are bound from it (open_graph, with `desc`), the `?` help
-- is generated from it and the <C-Space> palette lists its grouped entries. A
-- `GraphKey` list (gitloom.graph.palette), in help / palette order within each
-- group. No `group` = bound and in help, never in the palette (motions, plumbing);
-- no `run` = bound elsewhere (the §14.3 navigation keys), listed in help only.
---@type GraphKey[]
local GRAPH_KEYS = {
    -- Branches, refs & search
    { key = "<leader>b", run = h_refpick, group = "refs", desc = "Jump to branch / ref…",
        help = "Jump to a branch / ref (picker; recent first)" },
    { key = "%", run = function(ctx) ctx:ref_cycle() end, group = "refs", contexts = { "commit", "branch" },
        desc = "Cycle local / remote branch",
        help = "Cycle the branch between its local and remote counterparts (x → origin/x → … → x)" },
    { key = "P", run = h_pin, group = "refs", contexts = { "branch" }, desc = "Pin / unpin branch",
        help = "Pin / unpin the branch under the cursor as an anchor" },
    { key = "<Space>", run = h_space, group = "refs", contexts = { "branch" },
        -- On a mainline row (an anchor's own line) there is nothing to toggle (§10.4).
        when = function(st) return not (st.row and st.row.state == "mainline") end,
        desc = "Collapse / expand branch",
        help = "Collapse / expand the row's own branch(es) under the cursor (selecting: fold / unfold the head)" },
    { key = "L", run = function(ctx) ctx:pin_dialog() end, group = "refs", desc = "Pinned branches…",
        help = "Pinned branches: reorder (C-j/C-k) · dedicated lane (Space) · unpin (D) · add · CR jump" },
    { key = "/", run = h_filter, group = "refs", desc = "Filter the graph…",
        help = "Filter the graph to matching commits (live; C-j/C-k step · CR jump · C-s stamp · Esc cancel)" },
    { key = "<leader>gl", run = h_commit_search, group = "refs", desc = "Search commits…",
        help = "Search commits by subject / author (picker; :GitloomSearch)" },
    -- View
    { key = "m", run = h_merge_style, group = "view", desc = "Cycle merge / split style" },
    { key = "C", run = h_layout_policy, group = "view", desc = "Cycle lane layout policy",
        help = "Cycle the lane layout policy (compact / survivors / linear / straight / gutter)" },
    { key = "M", run = h_mirror, group = "view", desc = "Toggle mirroring",
        help = "Toggle mirroring (lane 1 on the right)" },
    { key = "B", run = h_label_mode, group = "view", desc = "Cycle ref label placement",
        help = "Cycle ref label placement (right / inline / own line)" },
    { key = "d", run = h_date, group = "view", desc = "Toggle absolute / relative dates" },
    { key = "H", run = h_dim, group = "view", desc = "Toggle reachability highlighting" },
    { key = "c", run = h_focus, group = "view", desc = "Toggle first-parent focus",
        help = "Toggle first-parent focus (collapse non-mainline branches)" },
    { key = "p", run = h_pack, group = "view", desc = "Toggle marker packing",
        help = "Toggle marker packing (concurrent collapsed heads share a line)" },
    { key = "S", run = h_sort, group = "view", desc = "Cycle row sort mode",
        help = "Cycle the row sort mode (topo / date / author-date)" },
    { key = "F", run = h_panes, group = "view", desc = "Toggle context panes",
        help = "Toggle the off-screen context panes (header + footer)" },
    { key = "i", run = h_laneids, group = "view", desc = "Toggle lane-id debug",
        help = "Toggle lane-id debug + the cutoff/seam highlight" },
    -- Commit & selection
    { key = "<CR>", run = h_cr, group = "select", contexts = { "commit", "selection" },
        desc = "Open the commit view",
        help = "Open the commit view (a head / packed marker: its tip; selecting: the range)" },
    { key = "D", run = h_diff, group = "select", contexts = { "commit", "selection" },
        when = function(st) return st.has_diff == true end, desc = "Open diff",
        help = "Open the commit's diff (external viewer; selecting: the range)" },
    { key = "V", run = h_select, group = "select", contexts = { "commit", "selection" },
        desc = "Start / exit commit selection",
        help = "Commit selection: range along a branch (j/k walk · h/l switch · o swap · <CR>/D diff · Esc exit)" },
    -- Other
    { key = "R", run = h_resync, group = "other", desc = "Refresh: resync with the repository",
        help = "Resync with the repository (refs + new commits + working tree)" },
    { key = "K", run = h_lane, group = "other", contexts = { "commit", "branch" },
        desc = "Lane breakdown", help = "Lane breakdown for the commit under the cursor" },
    { key = "?", run = h_help, group = "other", desc = "Show key help" },
    -- Motion & misc: bound, in help, never in the palette.
    { key = { "<C-Space>", "<C-@>" }, run = function(ctx) ctx:palette() end,
        -- Many terminals send <C-Space> as <C-@> (= <Nul>).
        desc = "Command palette (actions + keys for the row / selection)" },
    { key = "j", desc = "Next row (selecting: walk the path down)",
        run = function(ctx) if ctx.sel.active then selection_move(ctx, "down") else feed(vim.v.count1 .. "j") end end },
    { key = "k", desc = "Previous row (selecting: walk the path up)",
        run = function(ctx) if ctx.sel.active then selection_move(ctx, "up") else feed(vim.v.count1 .. "k") end end },
    { key = "<C-d>", desc = "Half page down (selecting: walk a page)",
        run = function(ctx) if ctx.sel.active then selection_page(ctx, "down") else feed("<C-d>") end end },
    { key = "<C-u>", desc = "Half page up (selecting: walk a page)",
        run = function(ctx) if ctx.sel.active then selection_page(ctx, "up") else feed("<C-u>") end end },
    { key = "h", run = function(ctx) move_ref(ctx, -1) end,
        desc = "Select previous ref / marker (selecting: switch branch)" },
    { key = "l", run = function(ctx) move_ref(ctx, 1) end,
        desc = "Select next ref / marker (selecting: switch branch)" },
    { key = "n", run = function(ctx) if ctx.filter then filter_goto(ctx, 1) end end,
        desc = "Next filter match" },
    { key = "N", run = function(ctx) if ctx.filter then filter_goto(ctx, -1) end end,
        desc = "Previous filter match" },
    { key = "o", run = function(ctx) if ctx.sel.active then selection_swap(ctx) end end,
        desc = "Swap the selection's ends (selecting)" },
    { key = "<Esc>", run = h_esc, desc = "Exit commit selection" },
    { key = { "<C-o>", "<C-i>" }, desc = "Back / forward through the view history" },
    { key = "q", run = h_q, desc = "Hide the graph (<leader>wg returns; <C-w>q destroys)" },
    { key = "<C-w>q", run = h_destroy, desc = "Destroy the graph window" },
    { key = "<leader>wD", run = h_dump, desc = "Write a pane debug dump to stdpath('data')" },
}
GRAPH_HELPERS.key_registry = function() return GRAPH_KEYS end

-- ── Autocmd bodies + debounce schedulers (spec §3.4/§12). Module-level, ctx-driven;
-- the autocmds are registered in open_graph but their bodies live here. ──────────

-- Recomputing the cone and redrawing on *every* CursorMoved makes held j/k feel
-- sluggish, so debounce it: each move re-arms a short timer and only the last —
-- once the cursor settles — does the work. `ctx.applying` suppresses the
-- WinScrolled the deferred refresh emits; a real scroll that lands during it is
-- remembered in `ctx.pending` and replayed, so the footer never goes stale.
local CONE_DEBOUNCE_MS = 60
local function schedule_cone_update(ctx)
    ctx.cone_gen = ctx.cone_gen + 1
    local gen = ctx.cone_gen
    vim.defer_fn(function()
        local w = ctx:win()
        if gen ~= ctx.cone_gen or not w then return end
        -- Skip if a sub-frame took over the host window since this was scheduled
        -- (§14): don't recompute/redraw the graph onto a commit view.
        if vim.api.nvim_win_get_buf(w) ~= ctx.buf then return end
        ctx:update_cone()
        ctx.applying = true
        if ctx.lv and ctx.lv.controller then ctx.lv.controller.refresh() end
        ctx.applying = false
        ctx:maybe_update_panes()
        if ctx.pending then ctx.pending = false; ctx:schedule_cone_update() end
    end, CONE_DEBOUNCE_MS)
end
GRAPH_HELPERS.schedule_cone_update = schedule_cone_update

-- Working-tree refresh triggers (§3.4): a buffer write, regaining focus, a `:!`
-- command (ShellCmdPost) or leaving a terminal (TermLeave) re-reads the state, debounced so rapid events coalesce into one git read.
-- Skipped while a commit selection is active (§13) so a background write never
-- yanks the selection out from under the user.
local WT_DEBOUNCE_MS = 200
local function schedule_wt_refresh(ctx)
    if ctx.opts.working_tree == false then return end
    ctx.wt_gen = ctx.wt_gen + 1
    local gen = ctx.wt_gen
    vim.defer_fn(function()
        local w = ctx:win()
        if gen ~= ctx.wt_gen or not w then return end
        -- Not while a sub-frame (a commit view, §14) owns the host window.
        if vim.api.nvim_win_get_buf(w) ~= ctx.buf then return end
        if ctx.sel.active then return end
        ctx:refresh_worktree(true) -- silent: no "history moved" notice on auto-refresh
    end, WT_DEBOUNCE_MS)
end
GRAPH_HELPERS.schedule_wt_refresh = schedule_wt_refresh

-- Rebuild the dimmed highlight groups after a colorscheme change (the derived
-- groups are wiped by `hi clear`) and redraw (§12).
local function on_color_scheme(ctx)
    -- The §6.3 same-named-remote warning colour; `default = true` so a
    -- colorscheme's own definition (or `palette.track.mismatch`) wins.
    pcall(vim.api.nvim_set_hl, 0, "GitloomTrackMismatch", { link = "DiagnosticWarn", default = true })
    reset_dim_cache()
    reset_gen_cache()
    if ctx.lv and ctx.lv.controller then ctx.lv.controller.refresh() end
end

-- Stacking (§2.1): the active git root follows the focused graph (graphs/repos
-- stack and the I/O layer has a single active root), so re-target it on entry.
local function on_buf_enter(ctx)
    git.set_cwd(ctx.repo.root)
end

-- On moving to a different row, reset the ref selection to the message, remember
-- the position (§2), recompute the cone for the new pivot (debounced), and
-- re-park. ctx.last_line lets a programmatic jump (the ref picker, §2) pre-set the
-- selection and suppress the reset.
local function on_cursor_moved(ctx)
    local w = ctx:win()
    if not w then return end
    local line = vim.api.nvim_win_get_cursor(w)[1]
    if line == ctx.last_line then return end
    ctx.last_line = line
    -- Commit selection (§13) drives the cursor/emphasis from its own handlers.
    if ctx.sel.active then return end
    -- Remember the commit under the cursor for this repo (§2); skip rows with no
    -- commit so a marker-less line never clobbers a good remembered position.
    local h = ctx:cursor_hash(line)
    if h then saved_positions[ctx.repo_key] = h end
    local item, _, sub = ctx:order_at(line)
    -- A packed marker line pre-selects its first marker (§10.4).
    if item and item.type == "markers" then
        ctx.selection_state.commit = item
        ctx.selection_state.index = (#marker_units(item) > 0) and 1 or nil
        ctx.selection_visible = ctx.selection_state.index ~= nil
        ctx:place_cursor()
        ctx:schedule_cone_update()
        return
    end
    local commit = item and item.commit or nil
    ctx.selection_state.commit = commit
    -- In dual mode, landing on a labelled commit's first row (sub 0) pre-selects
    -- the first label (§2/§6.1); other rows/modes default to the message.
    local auto = ctx.opts.label_mode == "dual" and sub == 0
        and commit and #decoration_texts(commit) > 0
    ctx.selection_state.index = auto and 1 or nil
    ctx.selection_visible = auto and true or false
    ctx:place_cursor()
    ctx:schedule_cone_update()
end

-- Working-tree refresh (§3.4): re-read the dirty state and rebuild the virtual
-- commits on the current HEAD anchor. It first re-resolves HEAD, so it can tell
-- when real history has moved out from under the model ("moved") — the seam the
-- general history resync (below) extends. Keeps the cursor on its commit across
-- the reflow. `silent` suppresses the "history moved" notice for the automatic
-- (write/focus) triggers.
local function refresh_worktree(ctx, silent)
    if ctx.opts.working_tree == false then return end
    fetch_worktree_state().next(function(state)
        local hw = ctx:win()
        if not hw then return end
        local keep
        local ok, pos = pcall(vim.api.nvim_win_get_cursor, hw)
        if ok then keep = ctx:cursor_hash(pos[1]) end
        -- A cursor on a working-tree node follows the stack, not the sentinel: a
        -- clean <-> dirty swap replaces the nodes, so re-home it on the topmost one
        -- (§3.4). The stack is built bottom-up, so the topmost is the last.
        local on_wt = keep and ctx.repo.commits[keep] and ctx.repo.commits[keep].virtual
        -- Save the full view (topline AND topfill) so an auto-refresh (FocusGained /
        -- BufWritePost) doesn't jitter the view: `reflow` re-renders the buffer, which
        -- resets the virtual-line sub-scroll (`topfill` -> 0, a ~1-line jump); restoring
        -- it afterwards holds the scroll, then `goto_hash` only corrects the cursor if its
        -- row actually shifted (same discipline as `resync`).
        local vok, view = pcall(vim.api.nvim_win_call, hw, vim.fn.winsaveview)
        local res = ctx:apply_worktree(state)
        if on_wt then
            local top = ctx.worktree_commits[#ctx.worktree_commits]
            keep = top and top.hash or ctx.worktree_head
        end
        ctx:reflow()
        ctx:update_footer()
        if vok and view then pcall(vim.api.nvim_win_call, hw, function() vim.fn.winrestview(view) end) end
        if keep then ctx:goto_hash(keep) end
        ctx:place_cursor()
        ctx:update_cone()
        if ctx.lv and ctx.lv.controller then ctx.lv.controller.refresh() end
        ctx:update_panes()
        if res == "moved" and not silent then
            vim.notify("gitloom: HEAD moved — reopen to refresh history (§3.4)",
                vim.log.levels.WARN)
        end
    end)
end
GRAPH_HELPERS.refresh_worktree = refresh_worktree

-- History resync (§3.4): re-read refs and reconcile the model in place so a
-- `commit` / `fetch` / `rebase` / HEAD-moving `checkout` shows without a reopen.
-- Snapshot the current ref tips (the rev-list exclude set) and the focused commit,
-- then: re-read refs (non-mutating) → reconcile bindings (add/move/remove) → pull
-- only the newly-reachable commits → link them → prune orphans → re-establish the
-- owned order → refresh the worktree → reflow, restoring the cursor by hash and
-- the scroll. Worktree virtuals are dropped up front and re-applied at the end.
-- `silent` suppresses the completion notice. Re-reads the live window after every
-- async boundary (the host can hide/re-show with a new id, §14).
-- `follow` (checkout / examine / Return, §10.4.1/§10.4.2) lands the cursor on
-- HEAD's row instead of the remembered one and names HEAD in the notice
-- (`git.head_summary`), with `follow.note` appended when given.
---@param follow? { note?: string }
local function resync(ctx, silent, follow)
    -- A reported operation (§19.1), ended on every path below. Its outcome is
    -- named by the resync's own notice, so the notify provider adds none (§19.3).
    local op = ctx.progress:start("Refreshing", { message = "refs", own_notices = true })
    if not ctx:win() then return op:finish("cancelled") end
    local repo = ctx.repo
    ctx:load_remotes() -- the palette's per-remote entries (§17.1)

    -- What we already have: every current ref tip becomes a negative ref, so the
    -- fetch returns only commits newly reachable since this point.
    local old_tips = {}
    for _, ref in pairs(repo.refs) do
        if ref.commit then old_tips[ref.commit.hash] = true end
    end

    -- Remember the focused commit + scroll so the view holds across the rebuild.
    -- (ctx:win() is non-nil here — the early return above guards it.)
    local focus
    local cok, pos = pcall(vim.api.nvim_win_get_cursor, ctx:win())
    if cok then focus = ctx:cursor_hash(pos[1]) end
    local vok, vview = pcall(vim.fn.winsaveview)
    local view = vok and vview or nil

    -- Drop the worktree virtuals during the rebuild; re-applied at the end.
    ctx:clear_worktree_nodes()

    fetch_ref_entries().next(function(res)
        ctx:reconcile_refs(res.entries, res.head, res.detached)
        local new_tips, old_list = {}, {}
        for _, e in ipairs(res.entries) do new_tips[e.hash] = true end
        -- A detached HEAD's commit may be on no branch; seed it so it is
        -- fetched/kept (§3.2).
        if res.detached then new_tips[res.detached] = true end
        local new_list = {}
        for h in pairs(new_tips) do new_list[#new_list + 1] = h end
        for h in pairs(old_tips) do old_list[#old_list + 1] = h end
        op:report("new commits")
        return fetch_new_commits(new_list, old_list)
    end).next(function(commits)
        for _, c in ipairs(commits) do ctx:integrate_commit(c) end
        ctx:prune_to_reachable()
        return ctx:apply_sort() -- re-establish the active sort mode (§3.1)
    end).next(function()
        if ctx.opts.working_tree == false then return nil end
        return fetch_worktree_state()
    end).next(function(state)
        if not ctx:win() then return op:finish("cancelled") end
        op:report("laying out")
        if state then ctx:apply_worktree(state) end
        -- Refs moved, so the owner TIPS may have moved with the owner and commit
        -- counts unchanged (a detached HEAD moving, a force-pushed ref) — which the
        -- signature cache's count key cannot see. Recompute (§10.5).
        ctx.sig_cache.sig = nil
        ctx:reflow()
        ctx:update_footer()
        -- Restore the scroll first, then re-home the cursor on the focused commit
        -- (goto_hash only scrolls if its new row is off-screen) — or, following a
        -- checkout, on HEAD's row (always visible: HEAD is an anchor, §10.6).
        if view then pcall(vim.fn.winrestview, view) end
        local head_hash = selectm.head_target(repo.refs)
        if not (follow and head_hash and ctx:goto_hash(head_hash))
            and not (focus and ctx:goto_hash(focus)) then
            -- The focused commit is gone (rewound away) — fall back to HEAD.
            if head_hash then ctx:goto_hash(head_hash) end
        end
        ctx:place_cursor()
        ctx:update_cone()
        if ctx.lv and ctx.lv.controller then ctx.lv.controller.refresh() end
        ctx:update_panes()
        op:finish("done")
        if silent then return end
        -- The branch's tracking counts from the ref read just made (§10.4.1's
        -- behind notice), never the ones cached before the checkout.
        local head_ref = repo.head and repo.refs[repo.head]
        local said = follow and git.head_summary(repo.head, head_hash, head_ref and head_ref.upstream)
        if said then
            local note = follow and follow.note
            vim.notify("gitloom: " .. said .. (note and (" — " .. note) or ""), vim.log.levels.INFO)
        else
            vim.notify("gitloom: resynced")
        end
    end)
end
GRAPH_HELPERS.resync = resync

-- The heavy graph-window builder. Kept as a module-local (not `M.open`) so the
-- thin `M.open` wrapper below can own the tier-1 session registry (§14) without
-- adding an upvalue here — this function sits at LuaJIT's 60-upvalue ceiling.
---@param opts GraphOptions
---@param focus_hash string?  -- commit to focus on open instead of HEAD (§2.1 / §11.7.6)
---@param seed_refs? { hash: string, name: string, hl: string }[]  -- synthetic pinned pointer refs (§11.7.6)
---@param attach? GraphAttach  -- build into an existing host window+buffer (a drilled-in graph frame, §14) instead of creating a window
-- Returns the listview instance and an `on_show` closure that re-establishes the
-- view after a hide/return (also the frame on-enter for an attached graph); the
-- wrapper registers them. With `attach`, no window is created — the graph renders
-- into the given host window + buffer as a navigation frame (§14 uniform frames).
local function open_graph(folder, opts, focus_hash, seed_refs, attach)
    -- Resolve the repository this graph targets (spec §2.1) up front, so the
    -- window title can show it and the I/O layer is retargeted before any fetch.
    -- Inlined (not the module-scope resolve_root used by M.pick) to keep this
    -- function under LuaJIT's 60-upvalue ceiling — it must not add a new upvalue.
    local root
    do
        local base = folder or vim.fn.getcwd()
        local top = vim.fn.systemlist({ "git", "-C", base, "rev-parse", "--show-toplevel" })[1]
        top = top and top:gsub("%s+$", "") -- strip a trailing CR/newline (Windows)
        root = (vim.v.shell_error == 0 and top and top ~= "") and top or base
    end
    git.set_cwd(root)
    -- The repo root that keys the SESSION / host window (§14). For the root graph
    -- it is `root` itself; for a drilled-in submodule frame it is the PARENT repo
    -- whose host window we render into (attach.host_root) — `root` there is the
    -- submodule, which has no session. The window-lifecycle keys (q / <C-w>q) act
    -- on this, while git I/O still targets `root` (the submodule).
    local host_root = (attach and attach.host_root) or root
    -- The window title identifies the repo (§2.1): its leaf dir name, plus the
    -- current branch once HEAD loads (filled in live by update_footer/graph_title).
    local repo_name = vim.fn.fnamemodify(root, ":t")

    -- Synthetic pointer refs (§11.7.6): the submodule link seeds `new`/`old`
    -- tag refs (with a colour `hl`) onto the bump's commits and pins them, so
    -- they render as refs, reveal via pinning, and show in the panes / ref
    -- picker. `seed_pin_names` feeds effective_pinned; the refs are injected once
    -- the commits exist (stream completion). Empty for an ordinary open.
    local seed_pin_names = {}
    for _, sr in ipairs(seed_refs or {}) do seed_pin_names[sr.name] = true end

    ---@type GraphOptions
    local defaults = {
        win = {
            border = "rounded",
            -- Nearly full screen: a ~2-char margin on each edge (snacks treats
            -- a returned size >= 1 as absolute and centers it). Re-evaluated on
            -- resize.
            width = function() return math.max(vim.o.columns - 4, 1) end,
            height = function() return math.max(vim.o.lines - 4, 1) end,
            title = (" %s "):format(repo_name),
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
            -- Linked-worktree labels (§3.2/§4.1), drawn as `{wt:<dir>}`. Muted
            -- like a remote: a worktree HEAD is real, checked-out work, but it is
            -- not a branch anyone else can see.
            worktree = "Comment",
            selected = "Visual", -- the h/l-selected ref decoration (§2)
            search = "Search",   -- the filter-search matched substring (§16.7)
            pair = "NonText",    -- the dual-mode pair bracket (§6.1); false = blank
            action = "Special",  -- the commit-view diff action label (§11.5)
            -- Reachability dimming (§12): blend factor toward the bg for the
            -- out-of-cone rows/lanes. Higher = more muted.
            dim = 0.45,
            counterpart_dim = 0.25,
            -- Commit-view diff colors (§11.3): per-role highlight groups.
            diff = {
                add = "DiffAdd",
                delete = "DiffDelete",
                hunk = "Title",
                header = "Comment",
            },
            -- Submodule change view (§11.7): the added / removed / common-ancestor
            -- marker colours (foreground only — no row tint). The defaults are a
            -- darker, muted green/red (GitloomSubmoduleAdd/Del, defined with
            -- default=true so a colorscheme can override); base = nil falls back to
            -- the first lane colour (tracks[1]).
            submodule = {
                new = "GitloomSubmoduleAdd",
                old = "GitloomSubmoduleDel",
                base = nil,
            },
            -- Upstream divergence indicator (§6.3): the ⇡N / ⇣N / gone tokens.
            track = {
                ahead = "Added",      -- ahead of upstream (pushable)
                behind = "WarningMsg", -- behind upstream (pull needed)
                gone = "Comment",     -- upstream deleted
                upstream = "Comment", -- a spelled-out non-matching upstream →origin/dev
                mismatch = "GitloomTrackMismatch", -- …when a same-named remote branch exists
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
        -- Lane layout policy (§5.6): which lanes may move sideways to close a
        -- gap. `compact` is today's behaviour. Cycle live with `C`.
        layout_policy = "compact",
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
        -- Float z-order (§14): the host window's zindex. Its overlays (context
        -- panes, the sticky header) sit at zindex+1 and gitloom's transient floats
        -- (`?`/`K`, its pickers and dialogs) at zindex+2. 41 keeps the graph above
        -- ordinary windows' decorations (≤ 40) and below other plugins' floats
        -- (fidget 45, pickers / vim.ui.select 50+).
        zindex = Z_HOST,
        -- Ref label placement (§6.1): "right" (default), "inline", or "dual".
        -- Cycle live with B.
        label_mode = "right",
        -- The dual-mode pair bracket (§6.1): the glyph opening the label row and
        -- the one closing the message row, drawn as-is (`{ "┬ ", "└ " }` for a gap).
        dual_bracket = { "┬", "└" },
        lane_label_colors = true, -- ref labels take their node's lane colour (§6)
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
        -- Pin the pair (§6.3/§10.6): pinning a local branch also pins its tracked
        -- upstream remote ref, so both lanes stay in full and a divergence is drawn.
        pin_upstream = true,
        -- Progress reporting (§19): fidget.nvim when it loads, else vim.notify;
        -- an operation is shown only once it has run for `delay` ms.
        progress = { provider = "auto", delay = 300 },
        -- Commit search (§15): `snippet` graph rows shown around the commit in the
        -- preview (odd, so the commit is centered); `layout` is the preview
        -- arrangement (only "vertical" — snippet above detail — for now, §15.3).
        search = {
            snippet = 7,
            layout = "vertical",
        },
        icons = {
            --merge = "M",
            head = "●", -- HEAD's node marker (§5.3); "" turns it off
            pin = "⚲", -- the pinned-anchor label icon (§6/§10.6); "" turns it off
            expanded = "▾", -- the expanded-ref label icon (§6); "" turns it off
            upstream = "→", -- before a non-matching upstream (§6.3); "" leaves the bare name
        },
    }
    -- The default footer is computed before opts.mirror is resolved; unless the
    -- caller set its own footer, recompute it so the initial mirror state shows.
    local user_footer = opts and opts.win and opts.win.footer
    -- Likewise the default title shows the repo (§2.1); leave a caller-supplied
    -- win.title untouched (graph_title/update_footer also skip it).
    local user_title = opts and opts.win and opts.win.title
    -- Persisted view state (§18): built-in < setup() < persisted. The
    -- configuration-resolved value of each persisted key is taken from the
    -- caller's own options BEFORE the merge — it is the `base` every later save
    -- records, and what Reset restores.
    local persist_config = require("gitloom.persist").config_values(opts)
    ---@type GraphOptions
    opts = vim.tbl_deep_extend("force", defaults, opts or {})
    if require("gitloom.persist").enabled(opts) then
        require("gitloom.persist").overlay(opts, persist_config, require("gitloom.persist").load().view)
    end
    -- Sync the merge-style cycle to the resolved style so `m` advances from it.
    for i, m in ipairs(MERGE_STYLES) do
        if vim.deep_equal(m.style, opts.merge_style) then merge_style_index = i; break end
    end
    if not user_footer then
        opts.win.footer = footer_text(opts.mirror)
    end
    -- Create the host at the configured layer (§14); snacks' default would be 50,
    -- above other plugins' floats. The layers above it read its LIVE zindex.
    opts.win.zindex = opts.zindex
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
    ---@field root string                    the repository root all git queries run in (§2.1)
    ---@field commits table<string, Commit>  hash → Commit (the resolution table)
    ---@field order OrderItem[]              raw commit items, 1:1 with commits (projection input)
    ---@field display? OrderItem[]           the projected OrderItem graph the view renders (§10; set at init)
    ---@field refs table<string, Ref>        name → Ref ("HEAD" for the head)
    ---@field head? string                   current branch name

    ---@class GraphCtx
    --- Per-session state for one graph (one host window / one repo root, §14).
    --- Bundles what were ~20 separate `open_graph` locals so the extracted
    --- helpers/handlers take a single `ctx` instead of closing over the scope —
    --- which keeps `open_graph` clear of LuaJIT's 60-upvalue ceiling. Built below
    --- and threaded into every module-level graph helper (call them as `ctx:foo()`
    --- so sibling dispatch resolves at call time — see the extraction notes).
    ---
    --- == identity / config ==
    ---@field root string                git I/O root (§2.1); == repo.root
    ---@field host_root string           session key — the host window's root (§14)
    ---@field repo_key string            keys saved_positions / recent_refs (== repo.root)
    ---@field repo_name string           the repo's display name (title; § 2.1)
    ---@field opts GraphOptions          the (copied) options table, mutated live by toggles
    ---@field pane_opts? GraphOptions    the panes' shallow copy of opts, frozen at window
    ---                                  creation except for fields a live toggle syncs (§5.6)
    ---@field repo Repo                  commits / order / display / refs / head
    ---@field palette table             == opts.palette
    ---@field seed_pin_names table<string,boolean>  pointer marks pinned by default (§11.7.6)
    --- == live window / buffer (never frozen — §14 hide/show changes the win id) ==
    ---@field buf? integer               stable graph scratch buffer for the session
    ---@field lv? table                  the listview instance (set after it opens)
    ---@field win fun(self:GraphCtx):integer?  live host window id (== gwin)
    --- == view / selection state ==
    ---@field selection_state SelectionState
    ---@field sel GraphSel
    ---@field display_index table<string,integer>
    ---@field node_loc table<string,{item:table,col:integer}>
    ---@field view_state { cone?:table, modes:table, effective:table, owner_tip:table<string,string>, expanded:table<string,boolean>, pins:PinEntry[], unpinned:table<string,boolean> }
    ---@field sig_cache { norder:integer, nowners:integer, cm?:boolean, sig?:table }
    ---@field colstream? table       the streaming Phase-1 sweep held open across
    ---                              batches (graph.extend_columns; §3.1). Cleared by
    ---                              any reflow — the projection is a different list.
    ---@field worktree_commits table
    ---@field worktree_head? string
    ---@field last_line? integer
    ---@field selection_visible boolean
    ---@field filter? { query: string, keep: table<string,boolean>, current?: string }  in-graph filter-search (§16); nil = none
    ---@field filter_gen integer     filter live-rebuild debounce generation (§16.4)
    ---@field remotes? string[]     `git remote` names for the palette (§17.1); nil until the first read lands
    ---@field ref_cycle_last? { name: string, sel: any, index: integer? }  the ref `%` last landed on + the selection it left (§2), so a grouped label's members can be stepped through
    ---@field remote_busy? string   the palette fetch / pull, branch sync, examine or Return running now (its label), nil when idle (§17.3, §10.4.2)
    ---@field base_view { modes: table, pins: PinEntry[], unpinned: table<string,boolean> }  base view-state tables restored on filter exit (§16.1)
    ---@field persist_config table<string, any>  configuration-resolved value of each persisted key: the save base + Reset target (§18.3/§18.5)
    ---@field persist_writable boolean  this session writes its repository's pin list (a root graph, not a drilled-in frame; §14.8/§18.4)
    ---@field progress ProgressTracker  this session's long-running operations (§19); closed when the graph buffer is wiped
    ---@field open_op? ProgressOp     the open's operation (§19.1), ended at the open's `done` / by its projection
    --- == debounce state (Phase B4) ==
    ---@field reflow_gen? integer  async-reflow generation (§10.5): a newer reflow
    ---                           bumps it and the in-flight one drops itself
    ---@field cone_gen integer       cone-update debounce generation
    ---@field applying boolean       suppresses the WinScrolled emitted by the deferred refresh
    ---@field pending boolean        a real scroll dropped during `applying`, replayed after
    ---@field wt_gen integer         working-tree refresh debounce generation
    --- == open-path trace (§10.8; only written while `vim.g.gitloom_open_trace` is armed) ==
    ---@field open_t0? integer       hrtime at the start of this open
    ---@field open_tstream? integer  hrtime at the start of the commit stream
    ---@field open_tsort? integer    hrtime at the start of the completion pass
    ---@field open_nbatch? integer   streamed batches seen so far
    --- == extracted helpers (Phase B1; attached from GRAPH_HELPERS) ==
    ---@field effective_pinned fun(self:GraphCtx):table<string,boolean>
    ---@field pin_rank fun(self:GraphCtx):table<string,integer>  ref id → pin rank of each pin-list entry; no counterparts (§5/§10.6)
    ---@field sync_pin_rank fun(self:GraphCtx):table<string,integer>  publish `pin_rank` + `pin_counterpart` on opts + pane_opts
    ---@field pin_counterpart fun(self:GraphCtx):table<string,integer>  counterpart ref id → its local's rank (§5.5); {} with pin_upstream off
    ---@field pin_marks fun(self:GraphCtx):PinMarks
    ---@field build_display_index fun(self:GraphCtx)
    ---@field order_at fun(self:GraphCtx, line:integer):table?,integer,integer
    ---@field apply_sort fun(self:GraphCtx):Future
    ---@field integrate_commit fun(self:GraphCtx, item:Commit):OrderItem?
    ---@field reconcile_refs fun(self:GraphCtx, entries:table[], head:string?, detached:string?)
    ---@field prune_to_reachable fun(self:GraphCtx)
    ---@field clear_worktree_nodes fun(self:GraphCtx)
    ---@field apply_worktree fun(self:GraphCtx, state:table?):string
    ---@field selection_range fun(self:GraphCtx):table?
    ---@field selection_commits fun(self:GraphCtx):Commit[]
    ---@field mark_path fun(self:GraphCtx, top:integer, bottom:integer):table
    ---@field mark_node_cone fun(self:GraphCtx, pivot:table, top:integer, bottom:integer):table
    --- == extracted helpers (Phase B2; attached from GRAPH_HELPERS) ==
    ---@field reflow fun(self:GraphCtx)
    ---@field reflow_owners fun(self:GraphCtx, cm:boolean):table[]
    ---@field reflow_build fun(self:GraphCtx, yield?:fun(), on_signatures?:fun():boolean?):table
    ---@field reflow_apply fun(self:GraphCtx, display:table)
    ---@field reflow_async fun(self:GraphCtx, done?:fun(), on_signatures?:(fun():boolean?), op?:ProgressOp)
    ---@field update_cone fun(self:GraphCtx)
    ---@field goto_hash fun(self:GraphCtx, hash:string?, record:boolean?):boolean
    ---@field place_cursor fun(self:GraphCtx)
    ---@field center_view fun(self:GraphCtx)
    ---@field cursor_hash fun(self:GraphCtx, line:integer):string?
    ---@field branch_under_cursor fun(self:GraphCtx, line:integer):table?
    ---@field graph_title fun(self:GraphCtx):string
    ---@field set_branch fun(self:GraphCtx, b:table, mode:string, follow:string?)
    ---@field toggle_branch fun(self:GraphCtx, b:table)  the Space toggle's act + notices (§10.4)
    ---@field ensure_expanded fun(self:GraphCtx, hash:string?):boolean
    --- == helpers kept nested in open_graph but exposed for the extracted callers ==
    ---@field update_panes fun(self:GraphCtx)
    ---@field maybe_update_panes fun(self:GraphCtx)
    ---@field update_footer fun(self:GraphCtx)
    ---@field resync fun(self:GraphCtx, silent:boolean?, follow:{ note?: string }?)
    ---@field palette fun(self:GraphCtx)  the command palette (§17)
    ---@field key_registry fun(self:GraphCtx): GraphKey[]  the key registry `GRAPH_KEYS` (§17.1)
    ---@field pin_defaults fun(self:GraphCtx): string[]  the default anchors in order (§10.6)
    ---@field save_pref fun(self:GraphCtx, key: string)  persist one toggled view preference (§18.2)
    ---@field save_pins fun(self:GraphCtx)  persist this repository's pin list (§18.2/§18.4)
    ---@field reset_view fun(self:GraphCtx)  confirm, then reset_view_now (§18.5)
    ---@field reset_view_now fun(self:GraphCtx)  clear the persisted state + restore the configured view (§18.5)
    ---@field run_remote fun(self:GraphCtx, kind:"fetch"|"pull", remote:string?)  palette fetch / pull (§17.3)
    ---@field remote_log? RemoteLog  the running or last fetch / pull's output (§17.4); nil until one runs
    ---@field remote_log_buf? integer  the open fetch log buffer, live-refreshed (§17.4); nil when closed
    ---@field show_remote_log fun(self:GraphCtx)  open the fetch log float (§17.4)
    ---@field refresh_remote_log fun(self:GraphCtx, follow:boolean?)  re-render the open fetch log (§17.4)
    ---@field branch_sync fun(self:GraphCtx, op:"fast_forward"|"reset_branch", t:SyncTarget)  palette branch sync (§17.2)
    ---@field git_failure fun(self:GraphCtx, label:string, res:table):string  a failed git step as one line
    ---@field examine fun(self:GraphCtx, newer:Commit, older:Commit)  Checkout & examine (§10.4.2)
    ---@field examine_selection fun(self:GraphCtx)  Checkout & examine the §13 selection
    ---@field open_selection_diff fun(self:GraphCtx)  the selection range in the diff provider (§13.5)
    ---@field examine_return fun(self:GraphCtx)  Return from an examine (§10.4.2)
    ---@field load_remotes fun(self:GraphCtx)  refresh `remotes` from `git remote` (§17.1)
    ---@field refresh_worktree fun(self:GraphCtx, silent:boolean?)
    --- == debounce schedulers (Phase B4; attached from GRAPH_HELPERS) ==
    ---@field schedule_cone_update fun(self:GraphCtx)
    ---@field schedule_wt_refresh fun(self:GraphCtx)

    ---@type Repo
    local repo = {
        root = root,
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


    -- Commit selection (range) mode (§13). `active` gates the modal keymaps;
    -- `path`/`anchor`/`cursor` are the selected path over the visible projection
    -- (DisplayNodes, newest-first); `dparent`/`dchild` remember the branch chosen
    -- at each junction for h/l. `display_index` maps a node hash → its index in
    -- `repo.display`, rebuilt on reflow and on entering selection.
    -- A structural alias (not a @class) so it stays assignable to the select.lua
    -- helpers' `SelectionPath` param while also carrying the window-glue `active`.
    ---@alias GraphSel { active: boolean, path?: table[], anchor?: table, cursor?: table, dparent: table<string,integer>, dchild: table<string,integer> }
    ---@type GraphSel
    local sel = { active = false, path = nil, anchor = nil, cursor = nil, dparent = {}, dchild = {} }
    local display_index = {}
    -- node hash → { item, col }: the OrderItem holding the node and the index of
    -- the column carrying its marker. Covers both a node on its own row and a
    -- collapsed head packed into a marker group (§10.4) — which has no `.commit`,
    -- so display_index alone can't reach it. Lets the selection emphasis light a
    -- head's lane/marker even when packed (§13.4).
    local node_loc = {}

    -- Reachability cone for the dimming pass (§12); nil until a pivot exists.
    -- `modes` is the branch-mode view state (ref name → mode); empty = all normal
    -- (the projection is then the identity). The reflow below reads it (§10).
    -- `modes` is explicit per-owner overrides; `effective` is the resolved mode
    -- per owner id after the first-parent default (§10.7), kept for the footer
    -- and the `<CR>` cycle. Both filled by reflow.
    -- `pins` is the user's explicitly ordered pin list (§10.6) — `{ id, reserved }`
    -- entries, priority order — and `unpinned` the ids they removed, which suppress
    -- the HEAD / master / main / dev defaults. `ctx:effective_pins()` resolves the
    -- two into the live list and `ctx:effective_pinned()` reduces it to the anchor
    -- set, which generalises the single trunk of §10.7.
    local view_state = { cone = nil, modes = {}, effective = {}, owner_tip = {}, expanded = {}, pins = {}, unpinned = {} }
    -- The repository's persisted pin list (§18.2) seeds the session.
    view_state.pins, view_state.unpinned = require("gitloom.persist").restore_pins(opts, root)

    -- The effective anchor set (§10.6). Pinned by default: the current branch
    -- (HEAD) and the common trunks `master`/`main`/`dev` when present. The user's
    -- explicit pin/unpin overrides apply on top. Returns a set of ref-owner ids.
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
    -- Rebuilds the context panes (§6.2) for the current viewport, asynchronously
    -- (chunked + cancellable). Assigned after the listview opens; forward-declared
    -- so reflow/scroll can trigger it. Forced callers (reflow / toggles) use this
    -- directly; the scroll/cursor debounce uses the gated `maybe_update_panes`.
    local update_panes = function() end
    -- Rebuilds the panes only when the viewport has actually scrolled. The panes
    -- show the topology *outside* the window, so a cursor move that doesn't scroll
    -- leaves them unchanged — this keeps the (chunked) pane walk off the common
    -- navigation path entirely. Assigned in the window block. §6.2.
    local maybe_update_panes = function() end
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

    -- The repository the graph reflects, identified by its root (git runs in
    -- repo.root, §2.1). Keys the remembered cursor position and the ref-picker
    -- MRU so reopening restores them per repository (§2/§2.1).
    local repo_key = repo.root

    -- The listview instance. Forward-declared so the on_controller/stream
    -- callbacks below close over this local (not a stray global) and see it once
    -- it is assigned after the window opens.
    local lv

    -- The graph's window and buffer ids. `buf` is stable for the session; `win`
    -- changes whenever the host window is hidden and re-shown — snacks reopens
    -- with a NEW window id (§14). Declared at function scope (not inside the
    -- open block below) so the `win.on_win` hook — set before the window opens —
    -- and every in-block closure share one upvalue; the hook refreshes it on
    -- each (re)show so all closures read the live window.
    local win, buf

    -- The live host window id, or nil. The graph reads it through here so the same
    -- body works whether it OWNS the window (create mode: lv.winid() is the snacks
    -- window id) or is an ATTACHED frame in a shared host (lv.winid() is the live
    -- host getter, §14 uniform frames). nil before the listview exists or once the
    -- window is gone — callers that pass it to the nvim API must nil-check.
    local function gwin()
        if not (lv and lv.winid) then return nil end
        local w = lv.winid()
        if w and vim.api.nvim_win_is_valid(w) then return w end
        return nil
    end

    -- The session state carrier (see GraphCtx). Aliases the locals above so the
    -- extracted module-level helpers can take `ctx` instead of closing over this
    -- scope. Table fields share the same reference, so a mutation through either
    -- the local or `ctx.field` is visible to both during the incremental migration;
    -- `lv`/`buf` are filled once the window opens, and `ctx:win()` reads the live
    -- host window (the id changes across §14 hide/show — never freeze it).
    ---@type GraphCtx
    -- The helper fields are attached just below by the GRAPH_HELPERS loop, not in
    -- this literal — so the partial table is intentional.
    ---@diagnostic disable-next-line: missing-fields
    local ctx = {
        root = root,
        host_root = host_root,
        repo_key = repo_key,
        repo_name = repo_name,
        opts = opts,
        repo = repo,
        palette = palette,
        seed_pin_names = seed_pin_names,
        selection_state = selection_state,
        sel = sel,
        display_index = display_index,
        node_loc = node_loc,
        view_state = view_state,
        sig_cache = sig_cache,
        worktree_commits = worktree_commits,
        worktree_head = worktree_head,
        last_line = nil,
        selection_visible = false,
        -- In-graph filter-search (§16): nil = no filter; else { query, keep,
        -- current } — the active query, its match set (hashes never contracted,
        -- §16.3), and the current match's hash (drives the §16.7 highlight).
        filter = nil,
        filter_gen = 0, -- live-rebuild debounce generation (§16.4)
        -- The **base** view-state tables (§16.1): a stamped filter installs a
        -- private copy into view_state and restores these on exit, so the base's
        -- collapse/pin are provably untouched (no per-change bookkeeping).
        base_view = { modes = view_state.modes, pins = view_state.pins, unpinned = view_state.unpinned },
        -- §18: the configuration-resolved persisted keys (save base + Reset target),
        -- and whether this session may write its pin list (a root graph — never a
        -- drilled-in frame, §14.8).
        persist_config = persist_config,
        persist_writable = attach == nil,
        -- §19: the session's operations; ended `cancelled` on BufWipeout (below).
        progress = require("gitloom.progress").tracker(opts.progress),
        win = gwin,
    }
    -- Attach the extracted module helpers so they dispatch as `ctx:name()` (one
    -- reference here — GRAPH_HELPERS — instead of one upvalue per helper).
    for k, f in pairs(GRAPH_HELPERS) do ctx[k] = f end
    ctx:load_remotes() -- async; the palette lists per-remote fetches once it lands (§17.1)
    -- Diagnostic / test seam: the most recently assembled graph session. The
    -- window glue has no busted coverage (it needs a real window), so the
    -- headless smoke test reads the projected model through here rather than
    -- guessing at it from the buffer -- which, without a UI, holds no rendered
    -- text at all (the listview draws through a decoration provider).
    M._internal.ctx = ctx
    if not attach then nav.ctxs[root] = ctx end


    -- Re-establish gitloom's owned row order (§3.1): run order_commits over the
    -- real (non-virtual) commit rows and rebuild repo.order in that order, reusing
    -- the existing OrderItem objects so identity is preserved. Called once at
    -- stream completion (the stream appended in provisional arrival order) and on
    -- every resync after new commits land. Worktree virtual commits are spliced
    -- separately (apply_worktree), so they are skipped and re-applied afterwards.

    -- Reorder repo.order to match an external hash sequence (a `rev`-based sort
    -- mode's `git rev-list` output; §3.1). Rows git lists but we lack are skipped;
    -- in-memory rows git didn't list (refspec drift) are appended, so no row is
    -- dropped. Reuses the existing OrderItem objects. Virtual worktree commits are
    -- spliced separately, so they are excluded here.

    -- Apply the active sort mode (§3.1) to repo.order, returning a Future (the
    -- `rev` modes query git asynchronously). The `gitloom` mode sorts the
    -- in-memory DAG (order_commits); the `rev` modes take git's exact sequence.
    -- The caller reflows.

    -- Merge a freshly-parsed Commit into the model (§3): fill its placeholder (or
    -- insert it), resolve its parent hashes to Commit references with child
    -- back-links, and append an OrderItem to repo.order (returned). Shared by the
    -- initial stream (on_batch) and the resync's new-commit pass. Identity-stable:
    -- a placeholder keeps its object and refs. Returns nil for an already-loaded
    -- commit (re-seen) so the caller doesn't double-link or double-list it.



    -- Remove the working-tree virtual commits from the raw model (§4.2): unlink
    -- each from its parent's children, drop it from the commit table, and filter
    -- its OrderItem out of repo.order. Leaves the real DAG untouched. The caller
    -- reflows afterwards.

    -- Rebuild the working-tree virtual commits (§3.3/§4.2) from a fetched state
    -- ({ head_hash, status }). Removes any existing ones, then — when enabled,
    -- dirty, and the HEAD anchor is still in the model — splices up to three nodes
    -- (untracked → unstaged → staged → HEAD) into repo.order just above HEAD.
    -- Returns a status the caller surfaces: "ok" | "clean" | "off" | "moved"
    -- (HEAD advanced past the snapshot, §3.4). The caller reflows.

    -- A full reflow (§10.5): project the raw commit order under the current
    -- branch modes into a fresh OrderItem graph, lay it out, and swap it into the
    -- listview. With all-normal modes the projection is the identity; this is the
    -- path every branch-mode change takes (and the stream takes once the
    -- projection is no longer the identity). Recomputes the cone over the new map.
    reflow = function() return ctx:reflow() end

    -- The "branch" the collapse interactions (§10.4) act on at a buffer line:
    --   { state = "expanded"|"collapsed"|"mainline", owners = ids to flip,
    --     follow = hash to put the cursor on after the flip, commit = a real
    --     Commit for examine/diff }.
    -- Resolved from the selection (a ref or a packed marker) or, failing that,
    -- the region under the cursor via its signature — so it needs no ref.
    local function branch_under_cursor(line) return ctx:branch_under_cursor(line) end

    -- Recompute the footer (active modes + the branch-mode summary, §10) and
    -- apply it to the floating window. Centralised so every state change updates
    -- it the same way.
    --
    -- The window title identifies the repository (§2.1): its name, plus the
    -- current branch once HEAD is known. Recomputed alongside the footer (cheap;
    -- it only changes when the branch resolves) and applied in the same config.
    local function graph_title() return ctx:graph_title() end
    local function update_footer()
        if lv and lv.win and lv.win.win then
            local nanchors = 0
            for _ in pairs(ctx:effective_pinned()) do nanchors = nanchors + 1 end
            -- The current branch's upstream divergence for the footer (§6.3).
            local track_str = nil
            if repo.head and repo.refs[repo.head] then
                local lbl = git.track_label(repo.refs[repo.head].upstream, opts.icons and opts.icons.upstream)
                if lbl ~= "" then track_str = repo.head .. lbl end
            end
            local status = footer_text(opts.mirror, view_state.modes,
                opts.collapse_merged ~= false, nanchors, SORT_MODES[sort_mode_index].label, track_str,
                opts.layout_policy)
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
            local cfg = { footer = lv.win.opts.footer, footer_pos = "center" }
            -- Refresh the repo title too (unless the caller pinned its own).
            if not user_title then
                lv.win.opts.title = graph_title()
                cfg.title = lv.win.opts.title
                cfg.title_pos = "center"
            end
            pcall(vim.api.nvim_win_set_config, lv.win.win, cfg)
        end
    end
    -- Kept nested (reads the local footer_seam/header_seam pane state written by
    -- the still-nested update_panes); exposed so the extracted helpers can call it.
    ctx.update_footer = update_footer

    -- The host window is created at opts.zindex (default Z_HOST = 41, set on
    -- opts.win above); its overlays and the transient floats layer above it via
    -- overlay_zindex / float_zindex (§2.1/§14, the single-window bounded model —
    -- no stacking ladder).

    -- Refresh the live window/buffer ids on every (re)open. snacks calls on_win
    -- after open_win on each show() — including after a hide()/return (§14) — with
    -- a fresh window id, so this keeps the function-scoped `win` current for all
    -- the closures below without re-creating them.
    opts.win.on_win = function(w) win, buf = w.win, w.buf; ctx.buf = w.buf end

    ---@type ListViewOptions
    local listview_options = {
        win = opts.win,
        -- Attach into the host window+buffer when drilling in (§14); nil = create
        -- a window (the repo's root graph). on_win above is then unused.
        attach = attach,
        -- The message (COL.flex) fills the row; refs (line_right) pin to the
        -- right edge, using the free width down to message_min (§6).
        flex = COL.flex,
        message_min = opts.message_min,
        overflow_hl = opts.palette.remote,
        -- Sticky cap on the author column so it only grows (no scroll bounce).
        col_max = { [COL.author] = COL.author_max },
        -- Under mirroring, make the graph column sticky too (only grow) so the
        -- right-aligned graph + message don't bounce as the lane width changes.
        col_sticky = function() return opts.mirror and { COL.graph } or {} end,
        -- Real buffer lines per item: a dual-mode labelled commit is two rows
        -- (label row + message row), everything else one. Cheap — reads only the
        -- commit's refs + mode — so the listview's buffer-line map needs no layout.
        line_count = function(item)
            return dual_two_line(opts, item and item.commit) and 2 or 1
        end,
        display = function(item)
            return display_item(opts, item, selection_state, view_state.cone,
                sel.active and sel.cursor or nil, repo.head, ctx.filter, ctx:pin_marks())
        end,
        on_controller = function(controller)
            -- Refs first: they create sparse Commit placeholders with refs
            -- attached, which the commit stream then fills in (identity
            -- preserved), so rows render with their refs already present.
            -- Open-path phase trace (§10.8, README → Diagnostics). Inert unless
            -- `vim.g.gitloom_open_trace` names a file; see util.open_trace.
            ctx.open_t0 = util.open_now()
            util.open_trace("open", { repo = repo.root })
            -- The open as one reported operation (§19.1): its message follows the
            -- trace points; ended at `done`, or by the projection (superseded /
            -- failed), or by the session's teardown.
            ctx.open_op = ctx.progress:start("Loading " .. vim.fn.fnamemodify(repo.root or "", ":t"),
                { message = "refs" })
            fetch_refs(repo).next(function()
                return fetch_head(repo)
            end).next(function()
                local nrefs = 0
                for _ in pairs(repo.refs) do nrefs = nrefs + 1 end
                util.open_trace("refs", { n = nrefs, ms = util.open_ms(ctx.open_t0) })
                ctx.open_op:report("0 commits")
                ctx.open_tstream = util.open_now()
                ctx:sync_pin_rank() -- the streamed sweep lays out under the pin ranks (§5)
                return fetch_commits({
                    branch = opts.branches or { "--all" },
                    -- One batch of streamed commits (spec §3): link each into the
                    -- model, then lay out and insert the whole batch with a single
                    -- relayout + insert (cheaper than per-commit, and the work is
                    -- off the stdout handler — see fetch_commits).
                    ---@param commits Commit[]
                    on_batch = function(commits)
                        local t_batch = util.open_now()
                        local new_items = {}
                        for _, item in ipairs(commits) do
                            local order_item = ctx:integrate_commit(item)
                            if order_item then
                                new_items[#new_items + 1] = order_item
                            end
                        end
                        if #new_items == 0 then return end

                        -- Fast path while the projection is the identity (the
                        -- common all-normal case): lay out and append the batch.
                        -- The sweep CONTINUES from where the last batch left off
                        -- (graph.extend_columns) — the stream only appends below,
                        -- and the layout is a top-down fold, so the rows above are
                        -- already final. Relaying the whole order per batch made
                        -- the stream O(N²/batch) (spec §3.1).
                        -- Once a branch mode makes the display a separate
                        -- projection, a streamed batch needs a full reflow (§10).
                        if repo.display == repo.order then
                            local from = #repo.order - #new_items + 1
                            ctx.colstream = graph.extend_columns(opts, repo.order, from, ctx.colstream)
                            controller.insert(new_items, from)
                        else
                            ctx.colstream = nil
                            reflow()
                        end
                        ctx.open_nbatch = (ctx.open_nbatch or 0) + 1
                        util.open_trace("batch", { i = ctx.open_nbatch, n = #new_items,
                            rows = #repo.order, ms = util.open_ms(t_batch) })
                        ctx.open_op:report(("%d commits"):format(#repo.order))
                    end,
                })
            end).next(function()
                util.open_trace("stream", { rows = #repo.order, batches = ctx.open_nbatch or 0,
                    ms = util.open_ms(ctx.open_tstream or ctx.open_t0 or 0) })
                ctx.open_op:report("sorting")
                ctx.open_tsort = util.open_now()
                -- Stream closed: apply the active sort mode (§3.1) to establish the
                -- authoritative row order before anything is projected or anchored.
                -- (The stream appended git's --topo-order arrival order.)
                return ctx:apply_sort()
            end).next(function()
                util.open_trace("sort", { mode = SORT_MODES[sort_mode_index]
                    and SORT_MODES[sort_mode_index].name, ms = util.open_ms(ctx.open_tsort or ctx.open_t0 or 0) })
                -- Working-tree virtual commits (§3.3/§4.2): with HEAD now in the
                -- model, read the working-tree state and splice the staged/
                -- unstaged/untracked nodes — or the clean node — above HEAD before
                -- the projection. Gated by working_tree. Chained so the reflow
                -- below projects them.
                if opts.working_tree == false then return nil end
                return fetch_worktree_state()
            end).next(function(state)
                if state then ctx:apply_worktree(state) end
                -- Seed the pointer marks (§11.7.6) now that the commits exist:
                -- inject new/old as `tag` refs carrying their colour, so the
                -- projection attributes them as owners, the default pin (above)
                -- reveals their branches, and the panes / ref picker pick them up.
                -- Only for commits actually present (an absent pointer is left
                -- unmarked, not synthesized as an empty placeholder).
                for _, sr in ipairs(seed_refs or {}) do
                    if repo.commits[sr.hash] then
                        add_ref(repo, sr.name, "tag", sr.hash)
                        local ref = repo.refs[sr.name]
                        if ref then ref.hl = sr.hl end
                    end
                end
                -- Stream done: apply the projection (the first-parent default
                -- collapse, §10.7) and compute the initial dimming (§12).
                --
                -- ASYNC (§10.5): this first projection is the one unavoidable
                -- whole-repository computation on the open path — signatures,
                -- contraction and a full lane layout, seconds of work on a large
                -- `--all` graph. It is chunked across event-loop ticks so the
                -- streamed graph stays scrollable and the keymaps stay live while
                -- it lands; the swap into the view is still atomic, because a
                -- half-collapsed projection is not a graph anyone can read or act
                -- on (every signature would have to be recomputed per branch, and
                -- the row a keypress landed on would move underneath it).
                --
                -- The focus-reveal (§11.7.6) rides INSIDE that one projection via
                -- `on_signatures`: it needs the signatures and the resolved modes,
                -- both of which exist before anything is projected, and the mode
                -- override it writes does not invalidate the signature cache — so
                -- the owners are re-resolved and the projection still runs once,
                -- instead of the whole reflow running a second time.
                local function reveal_focus()
                    local hash = focus_hash
                    if not (hash and sig_cache.sig and sig_cache.sig[hash]) then return false end
                    -- Reveal the focus target if the first-parent default (§10.7)
                    -- folded its branch into a collapsed head: the clicked commit
                    -- may be an intermediate (not a pinned pointer). Set the
                    -- commit's own owners (§10.2, `select.open_owners`) to normal
                    -- **by hash** (via the projection signature) — robust even when
                    -- the head is packed onto a shared marker line (§10.4).
                    local revealed = false
                    -- (inline require: open_graph is at its upvalue ceiling)
                    for _, oid in ipairs(require("gitloom.graph.select").open_owners(sig_cache.sig, hash,
                        view_state.owner_tip or {},
                        view_state.effective)) do
                        view_state.modes[oid] = "normal"
                        revealed = true
                    end
                    return revealed
                end
                local fut, promise = make_future()
                ctx.open_op:report("laying out")
                ctx:reflow_async(function() promise.resolve() end, reveal_focus, ctx.open_op)
                return fut
            end).next(function()
                -- The open's Op ends here on every path (§19.4): a failing focus
                -- step is reported and ends it `failed` rather than leaving the
                -- progress spinning on "laying out" forever.
                local fok, ferr = pcall(function()
                    update_footer()
                    -- Hidden mid-open (`q`, §14): nothing to focus now. Leave an
                    -- explicit focus target where the next show's on_show looks.
                    if focus_hash and not ctx:win() then saved_positions[repo_key] = focus_hash end
                    -- Focus an explicit commit if asked (the submodule link, §11.7.6),
                    -- else the remembered position for this repo, else HEAD; center the
                    -- view on it (§2). goto_hash resolves a folded commit to its
                    -- collapsed head; if the target is gone it leaves the cursor at the
                    -- top. HEAD is HEAD's commit on a branch or detached alike: HEAD is
                    -- always an anchor (§10.6), so a detached HEAD is focused too.
                    local target = focus_hash or saved_positions[repo_key]
                    if not (target and goto_hash(target)) then
                        local head_hash = selectm.head_target(repo.refs)
                        if head_hash then goto_hash(head_hash) end
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
                util.open_trace("done", { rows = #repo.display, ms = util.open_ms(ctx.open_t0 or 0) })
                ctx.open_op:finish(fok and "done" or "failed")
                if not fok then
                    vim.notify("gitloom: open failed: " .. tostring(ferr), vim.log.levels.ERROR)
                end
            end)
        end,
    }

    -- The graph keymaps live in the module-level GRAPH_KEYS registry (§17.1);
    -- bound OURSELVES buffer-local below, not via snacks window keys (snacks binds on
    -- its own buffer only). Buffer-local binding is what lets the same handlers drive
    -- any frame buffer the host swaps in — the uniform frames model (§14). Ensure
    -- snacks doesn't also bind anything.
    opts.win.keys = nil

    lv = listview.open(listview_options)
    ctx.lv = lv

    -- Name the graph buffer after the repository root (§6) so an external GUI
    -- title (e.g. Neovide's titlebar, derived from the active buffer) identifies
    -- the repo by path rather than showing snacks' unnamed scratch buffer as
    -- "[Scratch]". Path first so it leads in a taskbar/alt-tab where titles
    -- truncate from the right. The path is stable, so this is set once. pcall: a
    -- duplicate name (E95 — e.g. the same submodule drilled in twice, §14.7) must
    -- not break open; that buffer just keeps the default name.
    if lv and lv.buf then
        pcall(vim.api.nvim_buf_set_name, lv.buf, root .. " (gitloom)")
    end

    -- Cursor parking (§2/§7): cursorline marks the row; the cursor rests at the
    -- commit message, or on the selected ref. place_cursor reads the rendered
    -- buffer line and positions the cursor accordingly.
    if gwin() then
        -- on_win (create mode) already set these during listview.open; assign the
        -- function-scoped upvalues here too so the block reads them directly. In
        -- attach mode there is no on_win, so this is where the sub-frame graph first
        -- gets its window/buffer (refreshed thereafter by its frame on_enter, §14).
        win, buf = gwin() --[[@as integer]], lv.buf
        pcall(vim.api.nvim_set_option_value, "cursorline", true, { win = win })

        -- Bind each graph key buffer-local, wrapping the module-level handler as a
        -- zero-arg closure over this session's `ctx` — the single upvalue each handler
        -- needs. They read the live host window via ctx:win() and act on the session
        -- via ctx, so the same handlers drive the graph whether it owns the window or
        -- is an attached frame in a shared host (§14 uniform frames).
        for _, k in ipairs(GRAPH_KEYS) do
            local run = k.run
            if run then
                for _, lhs in ipairs(require("gitloom.graph.palette").lhs_of(k)) do
                    vim.keymap.set("n", lhs, function() run(ctx) end,
                        { buffer = buf, nowait = true, desc = "Gitloom: " .. k.desc })
                end
            end
        end
        -- `:GitloomSearch` — the command equivalent of `<leader>gl` (spec §15.1),
        -- bound buffer-local on the graph buffer (search targets this graph's repo).
        pcall(vim.api.nvim_buf_create_user_command, buf, "GitloomSearch",
            function() h_commit_search(ctx) end,
            { desc = "Gitloom: fuzzy commit search (§15)" })

        -- Move the cursor onto the display row that now represents `hash` — a real
        -- commit row, the marker (head/packed) whose region contains it, or a
        -- junction. Used after a collapse/expand reflow so the toggle stays put,
        -- and to focus HEAD / the remembered position on open (§2). Returns true
        -- when a row was found and the cursor moved, false otherwise.
        goto_hash = function(hash) return ctx:goto_hash(hash) end

        place_cursor = function() return ctx:place_cursor() end

        -- Center the view vertically on the cursor's row when there is room,
        -- clamped at the top/bottom of the graph (exactly `zz`'s behaviour). Used
        -- to focus HEAD / the remembered position on open (§2).
        center_view = function() return ctx:center_view() end

        -- The hash of the commit under the cursor at `line`: a real commit row
        -- yields its hash; a packed marker line (§10.4) yields the selected (or
        -- first) marker's tip; any other row yields nil. Drives the remembered
        -- position (§2).
        cursor_hash = function(line) return ctx:cursor_hash(line) end

        -- Recompute the pivot's cone over the visible rows and re-mark track
        -- activeness (§12). Cheap (O(visible)); the caller then refreshes. The
        -- window gives *buffer* lines; map them to order indices (a dual labelled
        -- commit spans two buffer lines) so the cone walk stays in order space.
        update_cone = function() return ctx:update_cone() end

        -- Async-pane-build state (assigned/used by update_panes, below). `pane_gen`
        -- is the cancellation token: bumping it abandons any in-flight chunked
        -- build (so a scroll mid-calculation drops the stale panes). `pane_gate` is
        -- the rebuild gate for `maybe_update_panes` (`pane.gate`, the tested state
        -- machine): it is told when a build for a **scroll key**
        -- (`topline:topfill`, see `pane_scroll_key`) starts, finishes, or is dropped,
        -- and answers "rebuild"/"repaint". Crucially it credits a key only once the
        -- build FINISHED — crediting at start let an abandoned build leave the gate
        -- claiming panes that were never produced, so the debounce repainted forever
        -- and the panes stayed stale (or, if that build had declined and closed them,
        -- stayed gone) until an unrelated scroll moved the key. Declared here so the
        -- scroll autocmd can cancel.
        local pane_gen = 0
        local pane_gate = require("gitloom.graph.pane").gate()

        -- The cone-update debounce generation + scroll-suppress guards (read by the
        -- module-level schedule_cone_update / WinScrolled, §12). `applying`
        -- suppresses the WinScrolled the deferred refresh emits; a real scroll
        -- during it is remembered in `pending` and replayed.
        ctx.cone_gen, ctx.applying, ctx.pending = 0, false, false

        -- Rebuild the dimmed highlight groups after a colorscheme change (the
        -- derived groups are wiped by `hi clear`) and redraw (§12).
        pcall(vim.api.nvim_set_hl, 0, "GitloomTrackMismatch", { link = "DiagnosticWarn", default = true })
        vim.api.nvim_create_autocmd("ColorScheme", {
            group = vim.api.nvim_create_augroup("GitloomDim_" .. buf, { clear = true }),
            callback = function() on_color_scheme(ctx) end,
        })

        local group = vim.api.nvim_create_augroup("Gitloom_" .. buf, { clear = true })

        -- The working-tree refresh debounce generation (read by the module-level
        -- schedule_wt_refresh, §3.4).
        ctx.wt_gen = 0
        -- A write, regaining focus, a `:!` command and leaving a terminal's insert
        -- mode (the last two catch `git add` / `git stash` from inside Neovim with
        -- no write, which would leave the always-shown row stale — §3.4).
        vim.api.nvim_create_autocmd({ "BufWritePost", "FocusGained", "ShellCmdPost", "TermLeave" }, {
            group = group,
            callback = function() ctx:schedule_wt_refresh() end,
        })

        -- Stacking (spec §2.1): the active git root follows the focused graph
        -- (re-target the I/O layer on entry, §2.1).
        vim.api.nvim_create_autocmd("BufEnter", {
            group = group,
            buffer = buf,
            callback = function() on_buf_enter(ctx) end,
        })

        -- On moving to a different row, reset the selection to the message,
        -- recompute the cone for the new pivot, redraw the dimming, and re-park.
        -- ctx.last_line lets a programmatic jump pre-set the selection and suppress
        -- the reset (the ref picker, §2). Body: on_cursor_moved (module-level).
        ctx.last_line = nil
        vim.api.nvim_create_autocmd("CursorMoved", {
            group = group,
            buffer = buf,
            callback = function() on_cursor_moved(ctx) end,
        })

        -- Scrolling (no row change) shifts the visible window, so the
        -- window-bounded cone must be recomputed for the newly visible rows too.
        -- Scoped to this window; a guard prevents re-entry from the refresh.
        vim.api.nvim_create_autocmd("WinScrolled", {
            group = group,
            -- No window pattern: `win` changes across hide/show (§14), so this is
            -- registered window-agnostic and filtered by v:event, whose keys are
            -- the ids of the windows that actually scrolled. Bail unless this
            -- graph's (live) window is among them.
            callback = function()
                if not vim.api.nvim_win_is_valid(win) then return end
                -- The host window may be showing a sub-frame (a commit view, §14):
                -- only react while it is showing THIS graph's buffer, else a scroll
                -- in the commit view would drag the graph's cone/refresh/panes onto
                -- it (the buffer would visibly flip back to the graph).
                if vim.api.nvim_win_get_buf(win) ~= buf then return end
                local ev = vim.v.event
                if not (ev and ev[tostring(win)]) then return end
                if ctx.applying then ctx.pending = true; return end -- replayed after the refresh
                -- The view actually moved: abandon any in-flight pane build (its
                -- seam is now stale) at once; the debounced pass below starts a
                -- fresh one once scrolling settles.
                pane_gen = pane_gen + 1
                pane_gate:dropped() -- the in-flight build is abandoned: it built nothing
                util.pane_trace("winscrolled", { gen = pane_gen })
                ctx:schedule_cone_update()
            end,
        })

        -- Context panes (spec §6.2): two borderless overlays summarising off-screen
        -- topology folded onto the pinned anchors. The FOOTER (below) continues the
        -- bottom-seam lanes down their first-parent chains to the roots (a sub-DAG
        -- rebuild, `pane.continue`/`footer`). The HEADER (above) is a vertical
        -- compaction of the already-laid-out projection slice above the cutoff
        -- (`pane.header`): linear runs drop, junctions go node-less, heads become ◍,
        -- pinned anchors keep a labelled row. Both seed/match the seam so lanes meet
        -- the main view. The rebuild is async — chunked across event-loop ticks and
        -- cancellable (see update_panes/drive_panes) — and scroll-gated, so a deep
        -- history walk never blocks navigation.
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
        -- Cached repo.order index (hash → position) for the footer's "below the
        -- cutoff" tests. repo.order only grows while streaming and is stable after,
        -- so rebuild it only when its length changes rather than on every build.
        ---@type table<string, integer>
        local pane_idx = {}
        local pane_idx_n = nil
        ---@return table<string, integer>
        local function order_idx()
            if pane_idx_n ~= #repo.order then
                pane_idx, pane_idx_n = {}, #repo.order
                for i, it in ipairs(repo.order) do pane_idx[it.commit.hash] = i end
            end
            return pane_idx
        end
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
        -- This copy is FROZEN at window creation, so anything toggled on
        -- `ctx.opts` afterwards never reaches the panes. The layout policy (§5.6)
        -- is toggled live by `C`, so publish the copy on ctx and let the handler
        -- keep this one field in step — otherwise the footer silently keeps the
        -- open-time policy while the main view changes, which reads as a pane bug.
        ctx.pane_opts = pane_opts

        local function close_pane(p)
            if p.win and vim.api.nvim_win_is_valid(p.win) then
                pcall(vim.api.nvim_win_close, p.win, true)
            end
            p.win = nil
            p.state = nil -- drop the stashed cone-repaint state (§6.2)
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
            if util.pane_tracing() then
                util.pane_trace("close", { by = (debug.traceback("", 2) or ""):gsub("%s+", " "):sub(1, 220) })
            end
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
                -- Just above this host's content, below the transient floats
                -- (`?`/`K`, which use float_zindex). Read live (§14 hide/re-show).
                zindex = overlay_zindex(win),
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
                -- Carry the chosen lane's cone state onto the synthetic seam segment so
                -- the seam bars dim with the cone (§6.2); without it the seam row has no
                -- `highlighted`/`edges` and seg_hl reads every bar as out-of-cone, so the
                -- footer's top (and header's bottom) seam line dimmed even fully lit lanes.
                sep[j] = lane
                    and { connectivity = { up = true, down = true },
                        lanes = { { connectivity = { up = true, down = true }, id = lane.id,
                            color = lane.color, highlighted = render.seg_hl(lane) or false } } }
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
        local function render_pane(buf, rows, goff, foff, is_header, overflow, height, overflow_names, clipped,
                                   emphasis, incone)
            local lines, marks = {}, {}
            local pal = opts.palette or {}
            local pins = ctx:pin_marks() -- the pin icon on pinned labels (§6/§10.6)
            -- Ref-label highlight by kind, matching the main view's ref colours.
            local label_hl = { head = pal.head, branch = pal.branch, remote = pal.remote, tag = pal.tags,
                worktree = pal.worktree or pal.tags }
            -- Reachability emphasis (§6.2): when on, a row whose node is outside the
            -- pivot's cone renders its labels/count dimmed (the graph glyphs dim per
            -- cell inside get_column_chars). `incone` is the propagated in-cone node
            -- set; nil/off ⇒ everything lit.
            local function node_lit(c)
                if not emphasis then return true end
                return (c ~= nil and incone ~= nil and incone[c.hash] == true)
            end
            -- Render one columns array (graph glyphs) into a padded, aligned line,
            -- recording highlight extmarks; returns the line text for suffixing.
            local function glyph_line(columns)
                local g = get_column_chars(opts, columns, emphasis)
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
                local lit = node_lit(c)
                -- Ref labels coloured as in the main view: the pane row's node lane
                -- colour on the label OWNING the lane, the rest per-kind (§6 "Label
                -- colour"), HEAD's marker in the HEAD colour; dimmed toward the
                -- background on an out-of-cone row (§6.2).
                local lane, owner
                if c then lane, owner = render.node_label_colour(opts, row.columns, emphasis, c, repo.head, true) end
                local function mark(s0, e0, g)
                    if g and e0 > s0 then
                        marks[#marks + 1] = { li, s0, e0, lit and g or render.dim_hl(opts, g) }
                    end
                end
                for _, seg in ipairs(c and pane_labels(c, repo.head, pins) or {}) do
                    text = text .. " "
                    local s = #text
                    text = text .. seg.text
                    -- A pointer mark (§11.7.6) carries its own colour; a detached
                    -- `HEAD` the HEAD colour; else the lane colour (or by kind).
                    local g = seg.hl or ((seg.kind == "head" and not seg.arrow) and pal.head)
                        or render.label_hl(opts, seg.key == owner and lane or nil, label_hl[seg.kind])
                    -- Sub-spans in their own colour, in text order: the `HEAD → ` prefix
                    -- (unless the whole label is HEAD-coloured) and the spelled-out
                    -- upstream (§6.3, palette.track); the rest takes `g`.
                    local spans = {}
                    if seg.arrow and g ~= pal.head then spans[#spans + 1] = { seg.arrow, pal.head } end
                    if seg.up then spans[#spans + 1] = { seg.up, (pal.track or {})[seg.up_kind] } end
                    local at = s
                    for _, sp in ipairs(spans) do
                        mark(at, s + sp[1][1] - 1, g)
                        mark(s + sp[1][1] - 1, s + sp[1][2], sp[2])
                        at = s + sp[1][2]
                    end
                    mark(at, #text, g)
                end
                if c and c.collapsed and c.count then
                    local s = #text
                    text = text .. (" (%d)"):format(c.count)
                    if not lit then marks[#marks + 1] = { li, s, #text, render.dim_hl(opts, "Normal") } end
                end
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
                -- Seam separator on TOP, then the rows descending to the root at the
                -- bottom. Pad the slack between the seam and the rows with extra straight
                -- seam bars so the overlay is exactly `height` tall and its top butts the
                -- last visible line (mirror of the header's bottom seam-bar pad). Sizing
                -- the overlay to the seam's whole-commit cover — not the row count — is
                -- what fixes the seam-misalignment when a covered commit has a virtual line.
                local seams = math.max(1, (height or (#rows + 1)) - #rows)
                if rows[1] then
                    local sep = sep_row(rows[1], "up")
                    for _ = 1, seams do lines[#lines + 1] = glyph_line(sep) end
                end
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

        -- The main view's graph column offsets, measured LIVE off the first visible
        -- line (spec §6.2): `goff` = the graph's left edge (date+author width),
        -- `foff` = the message edge (the graph's right side, where the mirrored graph
        -- right-aligns). The panes only continue the main view's lanes, so they must
        -- line up with whatever offset the graph shows *right now* — and the shared
        -- column widths are sticky (they grow as wider lane regions scroll in, and
        -- the graph column is sticky under mirror). A value frozen at build time
        -- therefore drifts: once the columns grow past the build-time width the pane
        -- sits left of the graph — under mirror, dramatically, slamming the
        -- right-aligned header to the left edge (the flush-left header bug). So we
        -- recompute on every render (build and cone repaint), not once at build.
        -- col_offset is in BYTES; convert via the line's own text so multi-byte
        -- author names don't skew the display columns. A degenerate read (the row's
        -- item columns transiently nil mid-relayout → col_offset 0) keeps the last
        -- good alignment rather than collapsing the pane to the left edge.
        local last_goff, last_foff = 0, 0
        local function pane_offsets()
            if not (lv and lv.controller and lv.controller.col_offset
                    and vim.api.nvim_win_is_valid(win)) then
                return last_goff, last_foff
            end
            local refl = vim.api.nvim_win_call(win, function() return vim.fn.line("w0") end)
            local ltext = vim.api.nvim_buf_get_lines(buf, refl - 1, refl, false)[1] or ""
            local gb = lv.controller.col_offset(refl, "line", COL.graph) or 0
            local fb = lv.controller.col_offset(refl, "line", COL.flex) or 0
            local goff = vim.fn.strdisplaywidth(ltext:sub(1, gb))
            local foff = vim.fn.strdisplaywidth(ltext:sub(1, fb))
            if foff <= 0 then return last_goff, last_foff end
            last_goff, last_foff = goff, foff
            return goff, foff
        end

        -- Apply the reachability cone to a built pane and (re)render it (spec §6.2).
        -- Cheap and rebuild-free: the in-cone node set is propagated over the pane's
        -- OWN condensed graph from the seam crossing-lanes that are currently in the
        -- cone (read live off their `edges`), then written onto the stored rows — the
        -- footer via its per-edge Lane objects, the header via each segment's `cone`
        -- tag (its governing node). Called once at build time and again on every cone
        -- change (cursor settle) WITHOUT relaying out. Emphasis off ⇒ plain render.
        local function paint_pane(p)
            if not (p and p.buf and vim.api.nvim_buf_is_valid(p.buf) and p.rows) then return end
            local emphasis = (opts.highlight ~= false) and (view_state.cone ~= nil)
            local incone
            if emphasis then
                -- In-cone seam crossing-lanes → their pane entry nodes (the seeds).
                local seeds, seam_lit = {}, {}
                for _, lane in pairs(p.boundary or {}) do
                    local lit = false
                    for _, e in ipairs(lane.edges or {}) do
                        if e.highlighted then lit = true; break end
                    end
                    if lit then
                        if lane.id ~= nil then seam_lit[lane.id] = true end
                        -- header (up): the crossing lane's child end is its pane node;
                        -- footer (down): its parent end.
                        local key = (p.dir == "up") and (lane.begin and lane.begin.hash)
                            or (lane.parent and lane.parent.hash)
                        local n = key and p.node_of and p.node_of[key]
                        if n then seeds[#seeds + 1] = n end
                    end
                end
                incone = pane.mark_pane_cone(seeds, p.dir)
                for _, row in ipairs(p.rows) do
                    for _, cell in ipairs(row.columns or {}) do
                        if cell.has_commit and cell.commit then
                            cell.active = incone[cell.commit.hash] == true
                        end
                        for _, seg in ipairs(cell.lanes or {}) do
                            if p.dir == "up" then
                                seg.highlighted = (seg.cone ~= nil and incone[seg.cone] == true)
                            else
                                -- footer: a wire lights when its child (begin) is in-cone,
                                -- or it IS an in-cone seam crossing (begin off-pane).
                                for _, e in ipairs(seg.edges or {}) do
                                    e.highlighted = (e.begin ~= nil and incone[e.begin.hash] == true)
                                        or (e.id ~= nil and seam_lit[e.id] == true) or false
                                end
                            end
                        end
                    end
                end
            end
            -- Align to the main view's CURRENT graph offset, not the value frozen
            -- when this pane was built (see pane_offsets), so the lanes stay
            -- continuous as the sticky columns grow.
            local goff, foff = pane_offsets()
            render_pane(p.buf, p.rows, goff, foff, p.is_header, p.ovf, p.H, p.ovf_names, p.hclipped,
                emphasis, incone)
        end

        -- Re-dim both panes for the current cone without a rebuild (spec §6.2). Runs
        -- on cursor settle (the cone follows the cursor, but the panes' topology does
        -- not), so it must stay cheap — it only re-walks each pane's own small graph.
        local function repaint_panes()
            if footer.state then pcall(paint_pane, footer.state) end
            if header.state then pcall(paint_pane, header.state) end
        end

        -- Hide both panes and record why (surfaced in the `i` status).
        local function hide_all(why)
            util.pane_trace("hide_all", { why = why })
            footer_dbg, header_dbg = why, why
            close_panes()
            update_footer()
        end

        -- The pane build, wrapped so any error is fully contained — it runs inside
        -- the scroll/cone path, and must never break the main view's scrolling.
        -- The pane build. Runs as a coroutine body driven by `update_panes`, so it
        -- yields (`py`) periodically to keep its O(N) passes and the heavy
        -- first-parent walks off a single event-loop tick, and an in-flight build is
        -- abandoned by bumping `pane_gen` when the view moves. All editor-state
        -- *mutation* (the overlay windows + buffers) happens in the no-yield tail,
        -- so an abandoned build leaves the previous panes intact. `coroutine.yield`
        -- is valid because the driver always resumes this inside a coroutine.
        local function build_panes()
            if opts.panes == false then return hide_all("off") end
            if not vim.api.nvim_win_is_valid(win) then return end
            -- Panes are a focus feature: need a HEAD commit (on a branch OR detached —
            -- HEAD is always an anchor, §10.6) and a graph.
            local declined = pane.decline(opts.panes, repo.refs, repo.display)
            if declined then return hide_all(declined) end

            -- `py` yields to the driver every YIELD_EVERY units so build_panes' own
            -- O(N) index passes don't block; pane.continue/continue_up self-chunk via
            -- the raw `coroutine.yield` hook passed to them.
            local YIELD_EVERY = 2048
            local _yn = 0
            local function py() _yn = _yn + 1; if _yn % YIELD_EVERY == 0 then coroutine.yield() end end

            local pinned = ctx:effective_pinned()
            -- repo.order index per commit hash, for "below the cutoff" tests (cached).
            local idx = order_idx()
            local function item_order(item)
                local c = item and item.commit
                if c then return idx[(c.tip and c.tip.hash) or c.hash] end
                local m = item and item.markers and item.markers[1]
                if m then return idx[(m.tip and m.tip.hash) or m.hash] end
            end
            -- repo.display index per commit hash, for "above the cutoff" (header).
            local didx = {}
            for i, it in ipairs(repo.display) do
                py()
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
            -- lane_main: the node's primary (first-parent) lane { id, color }. lane_set:
            -- the **all-lanes** id set the commit touches — every parent_lanes + child_lanes
            -- id — for the header's per-path loop-back visited list (§6.2).
            -- lane_edge: "<child>><parent>" (tip-keyed) → the main-view lane of that EDGE,
            -- so the header colours a fork child reached through a merge's second parent by
            -- that edge's lane rather than the child's first-parent lane (§6.2 Colour).
            local dnode, lane_main, node_col, lane_set, lane_edge = {}, {}, {}, {}, {}
            for _, it in ipairs(repo.display) do
                py()
                local pl = it.parent_lanes
                local main = pl and pl[1] and { id = pl[1].id, color = pl[1].color }
                for _, l in ipairs(pl or {}) do
                    local b, pa = l.begin, l.parent
                    if b and pa then
                        lane_edge[((b.tip and b.tip.hash) or b.hash) .. ">" .. ((pa.tip and pa.tip.hash) or pa.hash)] =
                            { id = l.id, color = l.color }
                    end
                end
                local lset
                for _, l in ipairs(it.parent_lanes or {}) do lset = lset or {}; lset[l.id] = true end
                for _, l in ipairs(it.child_lanes or {}) do lset = lset or {}; lset[l.id] = true end
                local hcol = {} -- this row's rendered nodes → their column
                for j, cell in ipairs(it.columns or {}) do
                    if cell.has_commit and cell.commit then hcol[cell.commit.hash] = j end
                end
                local function add(n)
                    if not n then return end
                    local col = hcol[n.hash]
                    dnode[n.hash] = n
                    if main then lane_main[n.hash] = main end
                    if lset then lane_set[n.hash] = lset end
                    if col then node_col[n.hash] = col end
                    if n.tip then
                        dnode[n.tip.hash] = n
                        if main then lane_main[n.tip.hash] = main end
                        if lset then lane_set[n.tip.hash] = lset end
                        if col then node_col[n.tip.hash] = col end
                    end
                    for _, hh in ipairs(n.region or {}) do
                        dnode[hh] = n
                        if main then lane_main[hh] = main end
                        if lset then lane_set[hh] = lset end
                        if col then node_col[hh] = col end
                    end
                end
                add(it.commit)
                for _, m in ipairs(it.markers or {}) do add(m) end
            end
            local function order_of(n) return n and didx[(n.tip and n.tip.hash) or n.hash] end
            local function lane_of(n, p)
                if not n then return nil end
                local k = (n.tip and n.tip.hash) or n.hash
                return (p and p.hash and lane_edge[k .. ">" .. ((p.tip and p.tip.hash) or p.hash)]) or lane_main[k]
            end
            local function lanes_at(n) return n and lane_set[(n.tip and n.tip.hash) or n.hash] end
            local function col_of(n) return n and node_col[(n.tip and n.tip.hash) or n.hash] end

            -- The SCREEN-ROW model of the whole display: the flat sequence of rendered
            -- lines (real columns lines PLUS virtual split/merge fan lines), so BOTH pane
            -- seams are computed in screen rows — what the user actually sees — instead of
            -- real buffer lines. A virtual line has no real line number, so `line('w0')`/
            -- `line('w$')` cannot address it; reasoning in real lines drifted the seam by a
            -- partial virtual row at the window edge (§6.2). Built once per pane rebuild and
            -- shared by the footer (bottom edge) and the header (top edge).
            -- Per-item virtual-row counts (above/below) + columns height, matching what the
            -- listview actually renders (§6.1): a fork's split fan and the `gutter` policy's
            -- handover rows are the `above` LIST, a merge fan is one row below, dual label
            -- mode two columns rows. Count-based so multi-row strategies just work.
            local function rows_of(it)
                return {
                    above = #(it.above or {}),
                    height = dual_two_line(opts, it and it.commit) and 2 or 1,
                    below = it.merge and 1 or 0,
                }
            end
            local pane_sm = pane.screen_lines(repo.display, rows_of)

            -- The bottom visible SCREEN row of the window (a `pane_sm` model row), anchored
            -- on the **cursor** via `winline()`. `winline()` (cursor's screen row within the
            -- window) and the window height are BOTH window-relative, so they need no
            -- `win_screenpos` and are border/winbar-robust — the bottom is simply
            -- `cols[cursor] + (win_height - winline())`. (The earlier `w0`/`win_screenpos`
            -- form drifted: `win_screenpos` is the FRAME top, and `line('w0')` can't address a
            -- split rendered above its columns. Verified against real nvim rendering in
            -- tests/screen_window_spec.) The cursor sits on a real columns row; in dual mode
            -- its `sub` offset shifts `winline()` back to the item's FIRST columns row.
            local function footer_bottom_screen()
                return vim.api.nvim_win_call(win, function()
                    local cur = vim.fn.line(".")
                    local _, cdisp, sub = ctx:order_at(cur)
                    if not cdisp or not pane_sm.cols[cdisp] then return nil, "no bs" end
                    local anchor_screen = vim.fn.winline() - (sub or 0)
                    local wh = vim.api.nvim_win_get_height(win)
                    -- nil, "at bottom" when nothing is below the window (§6.2).
                    return pane.footer_bottom(pane_sm, cdisp, anchor_screen, wh)
                end)
            end

            -- Build the footer for an overlay covering at least `cover` screen rows
            -- (off-screen-OLDER topology, below). `pane.footer_seam` rounds `bs` to a whole
            -- commit block; the seam item's bottom line (its merge fan, else columns) seeds
            -- the footer.
            local function build_footer(cover)
                local bs, why = footer_bottom_screen()
                if not bs then return nil, why or "no bs" end
                local seam = pane.footer_seam(pane_sm, bs, cover)
                if not seam then return nil, "past top@" .. cover end
                local line = pane.seam_line(seam)
                local boundary = pane.boundary_of(line)
                if not next(boundary) then return nil, "no lanes@" .. seam.idx end
                -- Pinned-ref tips below the cutoff that aren't on an active lane —
                -- add them so a divergent pinned branch still shows as a marker.
                local seam_ord = item_order(seam.item)
                local extra = {}
                if seam_ord then
                    for name in pairs(pinned) do
                        local ref = repo.refs[name]
                        if ref and ref.commit and (idx[ref.commit.hash] or 0) > seam_ord then
                            extra[#extra + 1] = ref.commit
                        end
                    end
                end
                local cond = pane.continue(boundary, pinned, extra,
                    function(n) return idx[n.hash] end, coroutine.yield)
                if #cond.items == 0 then return nil, "empty graph@" .. seam.idx end
                local res = pane.footer(pane_opts, cond.items, boundary, cond.node_of_hash)
                -- `seam.cover` is the WHOLE-COMMIT screen height the overlay must occupy
                -- for its seam separator to butt the last visible line (it can exceed the
                -- requested `cover` when a covered commit has a split/merge virtual line).
                -- The overlay height is sized to it, NOT to the content row count.
                return res.rows, seam.idx .. (seam.kind == "merge" and "m" or "c"), cond, boundary, seam.cover
            end

            -- The top visible SCREEN row of the window (a `pane_sm` model row), anchored on
            -- the **cursor** via `winline()` — the upward mirror of `footer_bottom_screen`.
            -- The window top sits `winline() - 1` rows above the cursor's columns row, both
            -- window-relative (no `win_screenpos`, so border/winbar-robust). This is the fix
            -- for the header's virtual-line drift: the true window top can be a split fan
            -- rendered ABOVE its columns line, which `line('w0')` (a REAL line) cannot address.
            local function header_top_screen()
                return vim.api.nvim_win_call(win, function()
                    local cur = vim.fn.line(".")
                    local _, cdisp, sub = ctx:order_at(cur)
                    if not cdisp or not pane_sm.cols[cdisp] then return nil end
                    local anchor_screen = vim.fn.winline() - (sub or 0)
                    return pane.header_ts(pane_sm, cdisp, anchor_screen)
                end)
            end

            -- Build the HEADER for an overlay covering at least `cover` screen rows
            -- (off-screen-NEWER topology). The seam is computed in SCREEN rows from the
            -- cursor-anchored window top (`pane.header_seam` — NO screenpos, so it's testable
            -- and never splits a commit across the seam: a covered commit's trailing merge
            -- line is covered with it, and a partial split fan at the window top is handled).
            -- `pane.continue_up` then rebuilds the focused sub-DAG and `pane.header` lays it
            -- out seam-up. Returns rows, tag, actual-cover on success; nil, reason on failure.
            -- `actual cover` ≥ `cover` (rounded up to the commit boundary) is the overlay
            -- height the rows must fit in.
            local function build_header(cover)
                local ts = header_top_screen()
                if not ts or ts <= 1 then return nil, "at top" end
                local seam = pane.header_seam(pane_sm, ts, cover)
                if not seam then return nil, "past end" end
                -- `pane.seam_line` decodes the seam's `virt` (an above-row seam indexes the
                -- item's `above` LIST, `-1` = nearest the columns line; §5 Line).
                local line = pane.seam_line(seam)
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
                local cond = pane.continue_up(boundary, tips, pinned, order_of, seam.idx, coroutine.yield,
                    lane_of, lanes_at)
                if #cond.items == 0 then return nil, "empty@" .. seam.idx end
                -- The pinned colours (§5.5): a header lane de-collided off its main-view
                -- colour must not be handed one of them (§6.2).
                local tracks = ctx.pane_opts.palette and ctx.pane_opts.palette.tracks
                local avoid = require("gitloom.graph.columns").pinned_slots(ctx.pane_opts.pin_rank,
                    tracks and #tracks or 8)
                -- Without generated colours (no truecolor) a replacement shares a curated
                -- slot instead of minting one past the palette (§5.5).
                local res = pane.header(cond.items, boundary, cond.node_of_hash, lane_of, col_of, avoid,
                    not (ctx.pane_opts.palette and ctx.pane_opts.palette.generate) and (tracks and #tracks or 8) or nil)
                if #res.rows == 0 then return nil, "norows@" .. seam.idx end
                return res.rows, seam.idx .. (seam.kind == "above" and "s" or "c"), seam.cover, seam.idx,
                    cond, boundary
            end

            -- The footer overlay is the separator row + the footer rows, so its
            -- screen height is `#rows + 1`. Grow the row count until it stabilises
            -- (§6.2 sizing), bounded by PANE_MAX. The final rows + seam come from the
            -- SAME build so the overlay height and the boundary line up.
            -- Size the FOOTER by a **min-fit search**, the mirror of `converge_header`:
            -- grow the requested `cover` until the condensed rows + the seam separator fit
            -- in the overlay, whose true height is the seam's **whole-commit cover**
            -- (`seam.cover` ≥ the request). Sizing the overlay to that cover — NOT to the
            -- content row count — is what keeps the seam separator butting the last visible
            -- line: when a covered commit carries a split/merge virtual line the cover jumps
            -- by one, and a content-sized overlay would sit a row short (the seam-misalign
            -- discontinuity). Returns rows, tag, overlay-height (cover), cond, boundary.
            local function converge_footer()
                local rows, seam_tag, height, cond, boundary
                for cover = 1, PANE_MAX do
                    if cover > 1 then py() end -- yield between sizing passes (each re-walks)
                    local r, tag, c, b, sc = build_footer(cover)
                    if not r then return nil, tag end
                    rows, seam_tag, height, cond, boundary = r, tag, sc, c, b
                    if #r + 1 <= (sc or (#r + 1)) then break end -- content + separator fits
                end
                return rows, seam_tag, height, cond, boundary
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
                local _, w0disp = ctx:order_at(w0)
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
                local _hi = 0
                local cond, boundary
                for cover = math.min(math.max(2, P + 1), HEADER_MAX), HEADER_MAX do
                    _hi = _hi + 1; if _hi > 1 then py() end -- yield between sizing passes
                    local r, tag, actual, si, c, b = build_header(cover)
                    if not r then return nil, tag end
                    rows, seam_tag, height, sidx, cond, boundary = r, tag, actual, si, c, b
                    if #r + 1 <= actual then
                        return r, tag, actual, 0, nil, clipped_lines(), cond, boundary
                    end -- fits
                end
                if not rows then return nil, "no rows" end
                -- Didn't fit: clip to the overlay height while **preserving continuity**
                -- — keep the seam-continuous bottom slice and elide the far tips into
                -- `+N above` (room for the +N line and the seam separator). Eliding the
                -- middle instead would tear every lane at the gap (the old bug).
                local kept, ovf, ovf_names = pane.cap(rows, math.max(1, height - 2), true)
                return kept, seam_tag, height, ovf, ovf_names, clipped_lines(), cond, boundary
            end

            -- COMPUTE both panes first (the heavy, yielding part). Do this before
            -- any editor-state mutation so a build abandoned mid-walk (the view
            -- scrolled — `pane_gen` bumped) leaves BOTH previous overlays intact,
            -- never a new footer beside a stale header.
            if util.pane_tracing() then
                util.pane_trace("geom", vim.api.nvim_win_call(win, function()
                    local v = vim.fn.winsaveview()
                    local cur = vim.fn.line(".")
                    local _, cdisp, sub = ctx:order_at(cur)
                    return { cur = cur, cdisp = tostring(cdisp), sub = tostring(sub),
                        wl = vim.fn.winline(), wh = vim.api.nvim_win_get_height(win),
                        top = v.topline, fill = v.topfill or 0, w0 = vim.fn.line("w0"),
                        nsm = #pane_sm.lines, ncols = #pane_sm.cols,
                        cols = tostring(cdisp and pane_sm.cols[cdisp]) }
                end))
            end
            local frows, ftag, fH, fcond, fboundary = converge_footer()
            local hrows, htag, H, ovf, ovf_names, hclipped, hcond, hboundary = converge_header()

            -- ===== no-yield tail: all editor-state mutation happens below =====
            -- Seed the pane offsets from the main view's current graph column (see
            -- pane_offsets). These are stored on the pane state for debug only — the
            -- actual render recomputes them live (paint_pane) so growth in the sticky
            -- columns can never strand a pane left of the graph.
            local goff, foff = pane_offsets()

            -- FOOTER (off-screen-older topology, below).
            if not frows or #frows == 0 then
                footer_dbg = ftag or "no rows"; close_pane(footer); footer_seam, footer_height = nil, nil
                footer.state = nil
            else
                frows = pane.cap(frows, PANE_MAX - 1) -- room for the seam separator; keep the root
                -- The overlay height is the seam's whole-commit cover (so the separator
                -- butts the last visible line), clamped to at least the content it must
                -- show (separator + rows) and the cap. `render_pane` pads any slack
                -- between the seam and the rows with straight seam bars.
                local fheight = math.min(PANE_MAX, math.max(fH or (#frows + 1), #frows + 1))
                footer_seam, footer_height, footer_dbg = ftag, fheight, nil
                ensure_pane_win(footer, false, fheight)
                -- Stash everything a cheap cone repaint needs (spec §6.2): the laid-out
                -- rows, the condensed node graph, the seam crossing-lanes (with live
                -- `edges` refs for current cone state), the walk direction and the render
                -- offsets — so a cursor move re-dims without rebuilding the layout.
                footer.state = { buf = footer.buf, rows = frows, dir = "down",
                    node_of = fcond and fcond.node_of_hash, H = fheight,
                    boundary = fboundary, goff = goff, foff = foff, is_header = false }
                paint_pane(footer.state)
            end

            -- HEADER (off-screen-newer topology, above). The overlay is exactly `H`
            -- tall (the height the seam was sized at), padded at the bottom so the
            -- seam butts the main view's top edge.
            if not hrows or #hrows == 0 then
                header_dbg = htag or "no rows"; close_pane(header); header_seam, header_height = nil, nil
                header.state = nil
            else
                header_seam, header_height, header_dbg = htag, H, nil
                ensure_pane_win(header, true, H)
                header.state = { buf = header.buf, rows = hrows, dir = "up",
                    node_of = hcond and hcond.node_of_hash,
                    boundary = hboundary, goff = goff, foff = foff, is_header = true,
                    ovf = ovf, H = H, ovf_names = ovf_names, hclipped = hclipped }
                paint_pane(header.state)
            end

            -- Topology-only debug dump (set `vim.g.gitloom_pane_debug` to a file path):
            -- the live seam/boundary/header-lane structure, no commit messages — for
            -- diagnosing seam alignment. Overwrites each build; never breaks the view.
            if type(vim.g.gitloom_pane_debug) == "string" then
                pcall(function()
                    local w0 = vim.api.nvim_win_call(win, function() return vim.fn.line("w0") end)
                    local _, w0disp = ctx:order_at(w0)
                    -- The cursor-anchored top visible SCREEN row (production formula) — the
                    -- header seam is computed from it, not from `w0disp` (which can't address
                    -- a split fan at the window top).
                    local hdr_ts = header_top_screen()
                    local out = { ("w0=%d w0disp=%s ts=%s H=%s seam_tag=%s ovf=%s"):format(
                        w0, tostring(w0disp), tostring(hdr_ts), tostring(H), tostring(htag), tostring(ovf)) }
                    -- The boundary the header was built from (the whole-commit seam).
                    local seam = hdr_ts and pane.header_seam(pane_sm, hdr_ts, H or 2)
                    local disp_idx = seam and seam.idx
                    local boundary = seam and pane.boundary_of(pane.seam_line(seam), true) or {}
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
                    for name in pairs(ctx:effective_pinned()) do
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
                    out[#out + 1] = "main display items (disp: parent_lanes | child_lanes  above/merge):"
                    local lo = math.max(1, (disp_idx or w0disp or 2) - 2)
                    local hi = math.min(#repo.display, (disp_idx or w0disp or 2) + (H or 2) + 1)
                    for di = lo, hi do
                        local it = repo.display[di]
                        if it then
                            local function ids(ls) local t = {}; for _, l in ipairs(ls or {}) do t[#t + 1] = tostring(l.id) end; return table.concat(t, ",") end
                            out[#out + 1] = ("  d%d: P[%s] | C[%s] col=%s%s"):format(di,
                                ids(it.parent_lanes), ids(it.child_lanes),
                                tostring(it.commit and col_of(it.commit)),
                                ((#(it.above or {}) > 0) and (" ABOVE" .. #it.above) or "") .. (it.merge and " MERGE" or ""))
                        end
                    end
                    -- ===== FOOTER (off-screen-OLDER topology, below) =====
                    local w_last = vim.api.nvim_win_call(win, function() return vim.fn.line("w$") end)
                    local w0f = vim.api.nvim_win_call(win, function() return vim.fn.line("w0") end)
                    local _, wdisp = ctx:order_at(w_last)
                    local dbg_sm = pane.screen_lines(repo.display, function(it)
                        return { above = #(it.above or {}),
                            height = dual_two_line(opts, it and it.commit) and 2 or 1,
                            below = it.merge and 1 or 0 }
                    end)
                    -- Cursor-anchored bottom (production formula) vs the old w0/win_screenpos one.
                    local dbg_cur = vim.api.nvim_win_call(win, function() return vim.fn.line(".") end)
                    local _, dbg_cdisp, dbg_sub = ctx:order_at(dbg_cur)
                    local dbg_wl = vim.api.nvim_win_call(win, function() return vim.fn.winline() end)
                    local dbg_wh = vim.api.nvim_win_get_height(win)
                    local dbg_anchor = dbg_wl - (dbg_sub or 0)
                    local dbg_bs = dbg_cdisp and dbg_sm.cols[dbg_cdisp]
                        and pane.footer_bs(dbg_sm, dbg_cdisp, dbg_anchor, dbg_wh)
                    out[#out + 1] = ("\n==== FOOTER  w0=%d cursor=%d(%s) winline=%s sub=%s wh=%d w$=%d bs=%s fh=%s ftag=%s ===="):format(
                        w0f, dbg_cur, tostring(dbg_cdisp), tostring(dbg_wl), tostring(dbg_sub), dbg_wh, w_last,
                        tostring(dbg_bs), tostring(footer_height), tostring(ftag))
                    local fseam = dbg_bs and pane.footer_seam(dbg_sm, dbg_bs, (footer_height or 2))
                    out[#out + 1] = ("footer_seam -> idx=%s kind=%s cover=%s seam_bottom=%s"):format(
                        tostring(fseam and fseam.idx), tostring(fseam and fseam.kind),
                        tostring(fseam and fseam.cover), tostring(fseam and fseam.seam_bottom))
                    local fb = fboundary or {}
                    local fbcols = {}
                    for col in pairs(fb) do fbcols[#fbcols + 1] = col end
                    table.sort(fbcols)
                    out[#out + 1] = ("footer boundary (%d lanes):"):format(#fbcols)
                    for _, col in ipairs(fbcols) do
                        local l = fb[col]
                        local p = l.parent
                        out[#out + 1] = ("  col=%d id=%s color=%s begin=%s@%s -> parent=%s@%s collapsed=%s"):format(
                            col, tostring(l.id), tostring(l.color),
                            tostring(l.begin and l.begin.hash and l.begin.hash:sub(1, 10)),
                            tostring(l.begin and order_of(l.begin)),
                            tostring(p and p.hash and p.hash:sub(1, 10)), tostring(p and order_of(p)),
                            tostring(p and p.collapsed))
                    end
                    out[#out + 1] = ("footer condensed (%d nodes):"):format(#((fcond and fcond.items) or {}))
                    for _, it in ipairs((fcond and fcond.items) or {}) do
                        local c = it.commit
                        local pars = {}
                        for _, pp in ipairs(c.parents or {}) do pars[#pars + 1] = pp.hash and pp.hash:sub(1, 8) end
                        out[#out + 1] = ("  %s collapsed=%s junction=%s parents=[%s] refs=%d"):format(
                            tostring(c.hash and c.hash:sub(1, 8)), tostring(c.collapsed), tostring(c.junction),
                            table.concat(pars, ","), #(c.refs or {}))
                    end
                    out[#out + 1] = ("footer rows = %d:"):format(#(frows or {}))
                    for ri, r in ipairs(frows or {}) do
                        local parts = {}
                        for ci, cell in ipairs(r.columns or {}) do
                            local ids = {}
                            for _, s in ipairs(cell.lanes or {}) do
                                local c = s.connectivity or {}
                                ids[#ids + 1] = ("%s%s%s%s%s"):format(tostring(s.id),
                                    c.up and "^" or "", c.down and "v" or "", c.left and "<" or "", c.right and ">" or "")
                            end
                            local node = cell.has_commit and "[O]" or ""
                            if #ids > 0 or node ~= "" then parts[#parts + 1] = ("c%d:%s%s"):format(ci, table.concat(ids, "/"), node) end
                        end
                        out[#out + 1] = ("  R%02d %s"):format(ri, table.concat(parts, "  "))
                        local ok, g = pcall(get_column_chars, opts, r.columns, false)
                        if ok and g then out[#out + 1] = ("      render=[%s]"):format(g.text or "") end
                    end
                    -- The ACTUAL rendered overlay buffers (post padding/mirror/separator),
                    -- with |..| markers so leading/trailing spaces are visible — the true
                    -- on-screen alignment. `mirror=%s` flags right-alignment mode.
                    out[#out + 1] = ("overlay offsets: goff=%s foff=%s mirror=%s"):format(
                        tostring(goff), tostring(foff), tostring(opts.mirror))
                    local function dump_buf(label, p)
                        if p and p.buf and vim.api.nvim_buf_is_valid(p.buf) then
                            out[#out + 1] = label .. " buffer lines:"
                            for _, bl in ipairs(vim.api.nvim_buf_get_lines(p.buf, 0, -1, false)) do
                                out[#out + 1] = ("  |%s|"):format(bl)
                            end
                        end
                    end
                    dump_buf("FOOTER", footer)
                    dump_buf("HEADER", header)
                    -- The main-view lines around the footer seam, as actually rendered in
                    -- the graph window — so the seam's on-screen columns can be compared to
                    -- the overlay's top row directly.
                    if fseam and fseam.idx then
                        out[#out + 1] = "main-view lines around the footer seam (buffer):"
                        local sstart = lv.controller.item_start and lv.controller.item_start(fseam.idx)
                        if sstart then
                            local lo2 = math.max(1, sstart - 1)
                            local hi2 = math.min(vim.api.nvim_buf_line_count(buf), sstart + 5)
                            for _, bl in ipairs(vim.api.nvim_buf_get_lines(buf, lo2 - 1, hi2, false)) do
                                out[#out + 1] = ("  |%s|"):format(bl)
                            end
                        end
                        -- disp -> buffer-line-start + split/merge flags + block height, so
                        -- the footer_seam block model can be checked against the render.
                        out[#out + 1] = "footer seam region (disp: start srow #above .merge collapsed  hash):"
                        for di = math.max(1, fseam.idx - 2), math.min(#repo.display, wdisp) do
                            local it = repo.display[di]
                            local st = lv.controller.item_start and lv.controller.item_start(di)
                            local srow = st and vim.fn.screenpos(win, st, 1).row
                            local c = it and it.commit
                            out[#out + 1] = ("  d%d: start=%s srow=%s above=%s merge=%s collapsed=%s hash=%s"):format(
                                di, tostring(st), tostring(srow), tostring(it and #(it.above or {})),
                                tostring(it and it.merge ~= nil), tostring(c and c.collapsed),
                                tostring(c and c.hash and c.hash:sub(1, 8)))
                        end
                        -- The main window's screen extent + the footer overlay's own screen
                        -- position/size, so the overlay's top row can be compared to the
                        -- seam item's screen row directly.
                        local wpos = vim.fn.win_screenpos(win)
                        local wh = vim.api.nvim_win_get_height(win)
                        out[#out + 1] = ("win screen: top=%d height=%d bottom=%d  footer_height=%s"):format(
                            wpos[1], wh, wpos[1] + wh - 1, tostring(footer_height))
                        if footer.win and vim.api.nvim_win_is_valid(footer.win) then
                            local fp = vim.fn.win_screenpos(footer.win)
                            out[#out + 1] = ("footer overlay screen: top=%d height=%d"):format(
                                fp[1], vim.api.nvim_win_get_height(footer.win))
                        end
                    end

                    local fh = io.open(vim.g.gitloom_pane_debug, "w")
                    if fh then fh:write(table.concat(out, "\n") .. "\n"); fh:close() end
                end)
            end

            mark_cutoff()   -- refresh the debug cutoff highlight (the `i` overlay)
            update_footer() -- refresh the debug readout (cutoff lines) if `i` is on
        end

        -- Drive a chunked pane-build coroutine: resume it for one chunk, and if it
        -- yielded (more work to do) reschedule the next chunk on the event loop.
        -- `gen` is captured at scheduling time; a newer build or a scroll bumps
        -- `pane_gen` and this driver abandons the stale coroutine — checked both
        -- before resuming (so no stale work runs) and after (so a result computed
        -- against a now-moved viewport is dropped before it renders). `coroutine.resume`
        -- contains any error in the build (returns false), so a broken build never
        -- wedges the main view — the same guarantee the old pcall gave.
        local function drive_panes(co, gen)
            if gen ~= pane_gen or not vim.api.nvim_win_is_valid(win) then
                util.pane_trace("abandon", { gen = gen, cur = pane_gen, at = "pre" })
                if gen == pane_gen then pane_gate:dropped() end -- the window went away
                return
            end
            local ok, err = coroutine.resume(co)
            if gen ~= pane_gen then
                util.pane_trace("abandon", { gen = gen, cur = pane_gen, at = "post" })
                return
            end -- superseded mid-resume; drop the result (whoever bumped `pane_gen`
            -- already told the gate this build produced nothing)
            if not ok then
                pane_gate:dropped() -- errored: the gate must not claim this scroll
                close_panes() -- on any pane error, hide rather than leave a bad state
                err = tostring(err)
                if err ~= last_pane_err then -- surface once per distinct error
                    last_pane_err = err
                    vim.notify("gitloom pane error: " .. err, vim.log.levels.WARN)
                end
                return
            end
            if coroutine.status(co) ~= "dead" then
                util.pane_trace("yield", { gen = gen })
                vim.schedule(function() drive_panes(co, gen) end)
            else
                -- The build finished and was not superseded: only NOW do the panes on
                -- screen describe this scroll, so only now may the gate be credited
                -- with it (see `pane.gate`).
                pane_gate:built()
                util.pane_trace("built", { gen = gen, key = tostring(pane_gate:key()),
                    ftr = footer_dbg or "ok", hdr = header_dbg or "ok" })
            end
        end

        -- Start an async pane rebuild for the current viewport, superseding any
        -- in-flight one. The first chunk runs synchronously, so small panes (the
        -- common case) still complete in this tick with no visible delay; only a
        -- long history-walk spills onto later ticks.
        -- The scroll key the pane rebuild gate compares (spec §6.2). It must change iff
        -- the visible window REGION moves — including a **sub-scroll through virtual
        -- lines**, where nvim shows more/fewer of the topline's `virt_lines_above` rows and
        -- `line('w0')` stays the same while `winsaveview().topfill` changes. Gating on
        -- `line('w0')` alone left the footer STALE across such a sub-scroll (a
        -- direction-dependent discontinuity that `F`-`F`/refocus "fixed" by tripping a real
        -- topline change). `topline + topfill` captures the true top edge.
        local function pane_scroll_key()
            return vim.api.nvim_win_call(win, function()
                local v = vim.fn.winsaveview()
                return v.topline .. ":" .. (v.topfill or 0)
            end)
        end

        update_panes = function()
            if not vim.api.nvim_win_is_valid(win) then return end
            -- Tell the gate which scroll this build TARGETS, so the debounce does not
            -- restart an identical build every tick while it is in flight. It becomes
            -- the gate's *built* key only once the build actually completes, in
            -- `drive_panes` — see `pane.gate`.
            local key = pane_scroll_key()
            pane_gate:started(key)
            pane_gen = pane_gen + 1
            util.pane_trace("update", { key = key, gen = pane_gen,
                site = util.pane_tracing()
                    and (debug.traceback("", 2) or ""):gsub("%s+", " "):sub(1, 220) or nil })
            drive_panes(coroutine.create(build_panes), pane_gen)
        end

        -- Gated entry for the cursor/scroll debounce. The panes' topology is
        -- independent of the cursor row, so a move that doesn't scroll never rebuilds
        -- them — but the reachability cone DOES follow the cursor, so the panes still
        -- need a cheap re-dim (spec §6.2): rebuild on a real scroll (incl. a virtual-line
        -- sub-scroll), otherwise just repaint the existing rows for the new cone.
        maybe_update_panes = function()
            if not vim.api.nvim_win_is_valid(win) then return end
            local key = pane_scroll_key()
            local act = pane_gate:decide(key)
            util.pane_trace("maybe", { key = key, built = tostring(pane_gate:key()), act = act,
                ftr = footer.win and "up" or "down", hdr = header.win and "up" or "down" })
            if act == "rebuild" then update_panes() else repaint_panes() end
        end
        -- Kept nested (closes over the pane machinery + win); exposed so the
        -- extracted reflow / handlers can call ctx:update_panes() / ctx:maybe_update_panes().
        ctx.update_panes = update_panes
        ctx.maybe_update_panes = maybe_update_panes

        -- (The cursor is kept away from the window edges by the window-local
        -- `scrolloff` set above (opts.scrolloff) — no manual clamping needed.)

        -- Close the panes when THIS graph's window closes — including a hide()
        -- (§14). Matched against the live `win` via ev.match rather than a baked-in
        -- pattern, since `win` changes across hide/show (the panes are rebuilt on
        -- the next show by on_show → update_panes).
        vim.api.nvim_create_autocmd("WinClosed", {
            group = group,
            callback = function(ev)
                if tonumber(ev.match) == win then close_panes() end
            end,
        })
        -- Also close them when the graph buffer is swapped OUT of the host window
        -- by a navigation push (a commit view becomes the active frame, §14.3) —
        -- a buffer swap fires BufWinLeave but not WinClosed, so without this the
        -- panes would float over the sub-frame. Buffer-scoped to the graph buffer
        -- (stable across hide/show; only the window id changes). on_show rebuilds
        -- them when the graph frame is re-entered.
        vim.api.nvim_create_autocmd("BufWinLeave", {
            group = group,
            buffer = buf,
            callback = function() close_panes() end,
        })
        -- The session's teardown (§19.4): the graph buffer wiped ends every
        -- operation still running `cancelled` — the backstop for a chain that
        -- never completes (the futures do not propagate errors). The git job
        -- itself is not killed.
        vim.api.nvim_create_autocmd("BufWipeout", {
            group = group,
            buffer = buf,
            once = true,
            callback = function() ctx.progress:close() end,
        })

        -- No initial cone/refresh here: the fetch is async, so no commits are
        -- loaded yet. Initial dimming happens once the stream completes (above).
        place_cursor()
    end

    -- Re-establish this view when the host window is shown again after a hide
    -- (§14): the buffer (rendered graph) survives, so just restore the remembered
    -- position, recenter, and rebuild the cone + panes (both torn down on hide).
    -- Mirrors the open-time focus sequence (sans focus_hash, which is one-shot).
    -- Also serves as the frame on-enter: an attached graph (§14) has no on_win
    -- hook, so this is where it re-acquires the live host window id on every entry
    -- (the host re-opens with a new id across hide/show). In create mode this just
    -- matches what on_win already set.
    local function on_show()
        local hw = gwin()
        if hw then win = hw end
        if lv and lv.buf then buf = lv.buf end
        -- Returning to the base graph from a stamped filter (§16.5): drop the
        -- filter and restore the base view state (the private copy is discarded),
        -- then reflow to the base before repositioning. No-op when not filtered.
        if ctx.filter then
            ctx.filter = nil
            ctx.view_state.modes = ctx.base_view.modes
            ctx.view_state.pins, ctx.view_state.unpinned = ctx.base_view.pins, ctx.base_view.unpinned
            ctx:reflow()
        end
        local target = saved_positions[repo_key]
        if not (target and goto_hash(target)) then
            local head_hash = selectm.head_target(repo.refs) -- attached or detached (§2)
            if head_hash then goto_hash(head_hash) end
        end
        center_view()
        place_cursor()
        update_cone()
        if lv and lv.controller then lv.controller.refresh() end
        update_panes()
    end

    return lv, on_show
end

-- ── Window-coupled graph helpers (Phase B2) ─────────────────────────────────
-- Extracted from open_graph so their module-level references (the graph engine,
-- the reachability walk, the view builder) leave open_graph's upvalue set. Each
-- takes `ctx` (called as `ctx:NAME()`); open_graph keeps a one-line wrapper that
-- delegates here, so its existing bare call sites are unchanged. The live window
-- is read fresh via `ctx:win()` (§14 hide/show changes the id), never frozen.

-- The owner set for a reflow (§10.5/§10.7), plus the resolved per-owner mode it
-- writes onto `view_state.effective`. Split out because the async reflow may have
-- to redo it once, after the focus-reveal (§11.7.6) writes a mode override --
-- owners are cheap and a mode never enters a signature, so redoing the owners is
-- what lets ONE projection account for the reveal.
---@param ctx GraphCtx
---@param cm boolean
---@return table[] owners
GRAPH_HELPERS.reflow_owners = function(ctx, cm)
    local viewbuilder = require("gitloom.graph.view")
    local pinned = ctx:effective_pinned()
    local owners = viewbuilder.owners(
        ctx.repo.order, owners_from_refs(ctx.repo.refs, {}), pinned, ctx.view_state.modes, cm)
    -- Filter-search (§16.3): contract *everything* -- force every owner collapsed,
    -- so only the matches (the `keep` set) and junctions stay visible. This is a
    -- mode-only override (the owner tips are unchanged), so it does not invalidate
    -- the signature cache.
    if ctx.filter then
        for _, o in ipairs(owners) do o.mode = "collapsed" end
    end
    -- `effective`: the resolved mode per owner. `owner_tip`: each owner's tip hash,
    -- for the own-owner rule (§10.2) the collapse interactions act on. `expanded`:
    -- the ref owners the user opened — effective normal while the §10.7 default is
    -- collapsed (focus on, not an anchor) — which the label renderers mark with
    -- `icons.expanded` (§6). Anonymous owners carry no label, so they are left out.
    local focus = cm and next(pinned) ~= nil
    local vs = ctx.view_state
    vs.effective, vs.owner_tip, vs.expanded = {}, {}, {}
    for _, o in ipairs(owners) do
        vs.effective[o.id] = o.mode
        vs.owner_tip[o.id] = o.tip.hash
        if focus and o.mode == "normal" and not pinned[o.id] and ctx.repo.refs[o.id] then
            vs.expanded[o.id] = true
        end
    end
    return owners
end

-- The COMPUTE half of a reflow (§10.5): owners -> signatures -> projection ->
-- layout -> marker packing, ending in the display list. Touches no window and
-- swaps nothing in, so abandoning it half-way leaves the view exactly as it was
-- (the same discipline as the pane build, §6.2).
--
-- `yield`, when given, is threaded into the three passes that scale with the
-- repository, so a coroutine driver can spread them over event-loop ticks.
-- `on_signatures` runs once the signatures (and `view_state.effective`) exist but
-- before anything is projected; returning true means it changed a mode override,
-- so the owners are re-resolved. Modes do not enter a signature, so the cache
-- stays valid and the projection still runs exactly once.
---@param ctx GraphCtx
---@param yield (fun())?
---@param on_signatures (fun(): boolean?)?
---@return table display  -- the new repo.display
GRAPH_HELPERS.reflow_build = function(ctx, yield, on_signatures)
    local viewbuilder = require("gitloom.graph.view")
    GRAPH_HELPERS.sync_pin_rank(ctx) -- pins are a layout input (§5): publish the ranks
    local cm = ctx.opts.collapse_merged ~= false
    local t = util.open_now()
    local owners = ctx:reflow_owners(cm)
    if util.open_tracing() then
        -- The shape the cost is a function of (§10.8): how many owners, and how
        -- many of them are the anonymous per-merge-parent family (§10.2).
        local merges = 0
        for _, o in ipairs(owners) do
            if tostring(o.id):sub(1, 6) == "merge:" then merges = merges + 1 end
        end
        util.open_trace("owners", { n = #owners, merges = merges, rows = #ctx.repo.order, ms = util.open_ms(t) })
    end
    -- Reuse cached signatures unless the commit/owner set or focus changed.
    t = util.open_now()
    local cached = true
    if ctx.sig_cache.norder ~= #ctx.repo.order or ctx.sig_cache.nowners ~= #owners
        or ctx.sig_cache.cm ~= cm or not ctx.sig_cache.sig then
        cached = false
        ctx.sig_cache.sig = viewbuilder.signatures(ctx.repo.order, owners, yield)
        ctx.sig_cache.norder, ctx.sig_cache.nowners, ctx.sig_cache.cm = #ctx.repo.order, #owners, cm
    end
    util.open_trace("signatures", { cached = cached, ms = util.open_ms(t) })
    if on_signatures and on_signatures() then owners = ctx:reflow_owners(cm) end
    t = util.open_now()
    local proj = viewbuilder.project(ctx.repo.order, owners, ctx.sig_cache.sig,
        ctx.filter and ctx.filter.keep, yield)
    util.open_trace("project", { rows = #proj.items, ms = util.open_ms(t) })
    t = util.open_now()
    refresh_columns(ctx.opts, proj.items, yield)
    util.open_trace("layout", { ms = util.open_ms(t) })
    t = util.open_now()
    local display = (ctx.opts.pack_markers ~= false) and pack_markers(proj.items) or proj.items
    util.open_trace("pack", { rows = #display, ms = util.open_ms(t) })
    return display
end

-- The APPLY half: swap the computed display into the listview and re-derive
-- everything keyed off it. Runs to completion with no yields, so the view never
-- shows a half-swapped state.
---@param ctx GraphCtx
---@param display table
GRAPH_HELPERS.reflow_apply = function(ctx, display)
    local t0_apply = util.open_now()
    -- The streamed sweep described `repo.order` in its arrival order; a reflow
    -- lays out the projection (and `apply_sort` may have reordered the rows
    -- underneath), so that session can no longer be continued.
    ctx.colstream = nil
    ctx.repo.display = display
    -- A reflow recreates the DisplayNodes, so drop any in-flight commit selection.
    ctx.sel.active, ctx.sel.path, ctx.sel.anchor, ctx.sel.cursor = false, nil, nil, nil
    if ctx.lv and ctx.lv.controller and ctx.lv.controller.set_items then
        ctx.lv.controller.set_items(ctx.repo.display)
    end
    ctx:build_display_index()
    ctx:update_cone()
    if ctx.lv and ctx.lv.controller then ctx.lv.controller.refresh() end
    ctx:update_panes()
    util.open_trace("apply", { rows = #display, ms = util.open_ms(t0_apply) })
end

-- A full reflow (§10.5): project the raw commit order under the current branch
-- modes into a fresh OrderItem graph, lay it out, and swap it into the listview.
-- Synchronous -- every keypress-driven reflow goes through here, and it also
-- supersedes any async reflow still in flight.
local function reflow(ctx)
    ctx.reflow_gen = (ctx.reflow_gen or 0) + 1
    ctx:reflow_apply(ctx:reflow_build())
end
GRAPH_HELPERS.reflow = reflow

-- The same reflow, driven across event-loop ticks (§10.5, and §10.8's "reflow
-- must stay responsive"). Used on the open path, where the FIRST projection of a
-- large repository is the one unavoidable multi-second computation: every commit
-- has to be attributed to owners before a single branch can be collapsed, so
-- there is no correct partial answer to show. Chunking keeps the window
-- scrollable and the keymaps live while it lands; the swap itself stays atomic.
--
-- A newer reflow (`reflow`, or another `reflow_async`) bumps `reflow_gen`, and
-- the in-flight one is dropped at its next resume without having touched
-- anything; so is one whose graph buffer was wiped (`<C-w>q` destroys the
-- session, §14.1). One that completes while the host window is merely HIDDEN
-- (`q` mid-open, §14) is applied all the same: the swap re-lays the session's
-- buffer, every view step (cursor, cone, panes) is a no-op without a window, and
-- the next show re-establishes the view (on_show). So `done` always runs and the
-- open's Op always ends (§19.4) — never left waiting on a show that may not come.
---@param ctx GraphCtx
---@param done (fun())?                    called after the display is swapped in
---@param on_signatures (fun(): boolean?)? see reflow_build
---@param op? ProgressOp                   the operation this projection belongs to (§19.4):
---                                        ended `cancelled` when superseded, `failed` on an error
GRAPH_HELPERS.reflow_async = function(ctx, done, on_signatures, op)
    ctx.reflow_gen = (ctx.reflow_gen or 0) + 1
    local gen = ctx.reflow_gen
    local co = coroutine.create(function()
        return ctx:reflow_build(coroutine.yield, on_signatures)
    end)
    local function drive()
        local b = ctx.lv and ctx.lv.buf
        if ctx.reflow_gen ~= gen or (b and not vim.api.nvim_buf_is_valid(b)) then
            if op then op:finish("cancelled") end
            return
        end
        local ok, res = coroutine.resume(co)
        if not ok then
            if op then op:finish("failed") end
            vim.notify("gitloom: reflow failed: " .. tostring(res), vim.log.levels.ERROR)
            return
        end
        if coroutine.status(co) == "dead" then
            -- Applied whether or not the host window is showing (see above): a
            -- hidden graph's buffer is re-laid and its view re-established on show.
            ctx:reflow_apply(res)
            if done then done() end
            return
        end
        -- A 0ms timer, not vim.schedule: a scheduled callback is drained inside
        -- the same pass of the event queue, so the screen would not update
        -- between slices (the same reason §3.1's stream worker uses one).
        vim.defer_fn(drive, 0)
    end
    drive()
end

-- Recompute the pivot's cone over the visible rows and re-mark track activeness
-- (§12). The window gives *buffer* lines; map them to order indices.
local function update_cone(ctx)
    local w = ctx:win()
    if not w then return end
    local topbuf = vim.api.nvim_win_call(w, function() return vim.fn.line("w0") end)
    local botbuf = vim.api.nvim_win_call(w, function() return vim.fn.line("w$") end)
    local curbuf = vim.api.nvim_win_get_cursor(w)[1]
    local item, cur = ctx:order_at(curbuf)
    local top = select(2, ctx:order_at(topbuf))
    local bottom = select(2, ctx:order_at(botbuf))
    -- Commit selection (§13.4): the selected path is the emphasised set.
    if ctx.sel.active then
        ctx.view_state.cone = ctx:mark_path(top, bottom)
        return
    end
    -- A packed marker line (§10.4): the selected head drives the cone.
    if item and item.type == "markers" then
        local sel_node
        if ctx.selection_state.commit == item and ctx.selection_state.index then
            local u = marker_units(item)[ctx.selection_state.index]
            sel_node = u and u.marker
        end
        ctx.view_state.cone = sel_node and ctx:mark_node_cone(sel_node, top, bottom) or nil
        return
    end
    if not (item and item.commit) then
        ctx.view_state.cone = nil
        return
    end
    ctx.view_state.cone = mark_reachable(ctx.repo.display, cur, top, bottom)
end
GRAPH_HELPERS.update_cone = update_cone

-- Move the cursor onto the display row representing `hash` — a real commit row,
-- the marker (head/packed) whose region contains it, or a junction (§2/§10.4).
-- When `record` is set, the move is a **jump motion** (`{lnum}G`) so the prior
-- cursor position lands in the jumplist — used by the filter `<CR>` so `<C-o>`
-- returns to where you were (§16.4); other callers use a plain set_cursor that
-- doesn't pollute the jumplist.
local function goto_hash(ctx, hash, record)
    if not hash then return false end
    local w = ctx:win()
    if not w then return false end
    for i, it in ipairs(ctx.repo.display or {}) do
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
            local lnum = (ctx.lv.controller.item_start and ctx.lv.controller.item_start(i)) or i
            if record then
                pcall(vim.api.nvim_win_call, w, function() vim.cmd("normal! " .. lnum .. "G") end)
            else
                pcall(vim.api.nvim_win_set_cursor, w, { lnum, 0 })
            end
            return true
        end
    end
    return false
end
GRAPH_HELPERS.goto_hash = goto_hash

-- Park the cursor at the message (or the selected ref / marker label) on the
-- current row (§2/§7/§13.2).
local function place_cursor(ctx)
    local w = ctx:win()
    if not w then return end
    local line = vim.api.nvim_win_get_cursor(w)[1]
    if ctx.sel.active then
        local item = ctx:order_at(line)
        if item and item.type == "markers" and ctx.sel.cursor then
            local units = marker_units(item, ctx:pin_marks())
            for i, u in ipairs(units) do
                if u.marker == ctx.sel.cursor then
                    local text = vim.api.nvim_buf_get_lines(ctx.buf, line - 1, line, false)[1] or ""
                    -- Marker labels may repeat (`(3)`); skip the copies drawn before it.
                    local mcol = ref_byte_col(text, u.text, selectm.label_occurrence(
                        vim.tbl_map(function(x) return x.text end, units), i))
                    if mcol then
                        pcall(vim.api.nvim_win_set_cursor, w, { line, mcol })
                        return
                    end
                    break
                end
            end
        end
        local col = ctx.lv and ctx.lv.controller and ctx.lv.controller.col_offset
            and ctx.lv.controller.col_offset(line, "line", COL.graph) or 0
        pcall(vim.api.nvim_win_set_cursor, w, { line, col or 0 })
        return
    end
    local item = ctx:order_at(line)
    if item and item.type == "markers" then
        local col = nil
        if ctx.selection_state.commit == item and ctx.selection_state.index then
            local units = marker_units(item, ctx:pin_marks())
            local u = units[ctx.selection_state.index]
            if u then
                local text = vim.api.nvim_buf_get_lines(ctx.buf, line - 1, line, false)[1] or ""
                -- Marker labels may repeat (`(3)`); skip the copies drawn before it.
                col = ref_byte_col(text, u.text, selectm.label_occurrence(
                    vim.tbl_map(function(x) return x.text end, units), ctx.selection_state.index))
            end
        end
        if not col and ctx.lv and ctx.lv.controller and ctx.lv.controller.col_offset then
            col = ctx.lv.controller.col_offset(line, "line", COL.flex)
        end
        pcall(vim.api.nvim_win_set_cursor, w, { line, col or 0 })
        return
    end
    if not item or not item.commit then return end
    local col = nil
    local sub = select(3, ctx:order_at(line))
    if ctx.selection_state.commit == item.commit and ctx.selection_state.index then
        local texts = decoration_texts(item.commit, nil, ctx:pin_marks())
        if ctx.selection_state.index <= #texts then
            local text = vim.api.nvim_buf_get_lines(ctx.buf, line - 1, line, false)[1] or ""
            col = ref_byte_col(text, texts[ctx.selection_state.index])
        end
    end
    if not col and ctx.lv and ctx.lv.controller and ctx.lv.controller.col_offset then
        col = ctx.lv.controller.col_offset(line, "line", COL.flex)
        -- Both dual rows open the flex column with the pair bracket (§6.1): park
        -- on the labels / message, not the bracket. The prefix's BYTE length
        -- (the glyphs are multibyte and configurable).
        if dual_two_line(ctx.opts, item.commit) then
            col = col + (sub == 1 and render.dual_prefix_bytes(ctx.opts)
                or #(render.dual_prefix(ctx.opts, 1)))
        end
    end
    pcall(vim.api.nvim_win_set_cursor, w, { line, col or 0 })
end
GRAPH_HELPERS.place_cursor = place_cursor

-- Center the view vertically on the cursor row (exactly `zz`; §2).
local function center_view(ctx)
    local w = ctx:win()
    if not w then return end
    pcall(vim.api.nvim_win_call, w, function() vim.cmd("normal! zz") end)
end
GRAPH_HELPERS.center_view = center_view

-- The hash of the commit under the cursor at `line`, or nil on a row with no
-- single commit; a packed marker line yields the selected (or first) tip (§2).
local function cursor_hash(ctx, line)
    local item = ctx:order_at(line)
    if not item then return nil end
    if item.commit then return item.commit.hash end
    if item.type == "markers" then
        local units = marker_units(item)
        local u = units[ctx.selection_state.index] or units[1]
        if u and u.marker and u.marker.tip then return u.marker.tip.hash end
    end
    return nil
end
GRAPH_HELPERS.cursor_hash = cursor_hash

-- The "branch" the collapse interactions (§10.4) act on at a buffer line: the
-- row's **own owners** (§10.2), via `select.toggle_target` over the commit's
-- signature — a `◍` head (or a packed line's selected marker) expands its own
-- owners; an open row collapses its normal, non-anchor own owners, `keepers`
-- naming the branches built on top that keep it open; a row an anchor reaches is
-- `mainline`, with its `anchors`. A ref selected with h/l does NOT narrow
-- `owners` (§10.4); it is returned as `selected` (its owner ids) for the per-ref
-- actions — the palette's hide and `P`. `hide_owners` is what hide acts on: the
-- selected ref's owners, else (a head) every collapsed owner in its signature.
---@return ToggleTarget|{ state: "collapsed" }|nil
local function branch_under_cursor(ctx, line)
    local item = ctx:order_at(line)
    if not item then return nil end
    local vs = ctx.view_state
    local function target(hash, collapsed)
        return selectm.toggle_target(ctx.sig_cache.sig, hash, vs.owner_tip or {},
            ctx:effective_pinned(), vs.effective, collapsed)
    end
    local function collapsed_in(sig)
        local out = {}
        for oid in pairs(sig or {}) do
            if (vs.effective[oid] or "normal") == "collapsed" then out[#out + 1] = oid end
        end
        table.sort(out)
        return out
    end
    if item.type == "markers" then
        if ctx.selection_state.commit == item and ctx.selection_state.index then
            local u = marker_units(item)[ctx.selection_state.index]
            local tip = u and u.marker.tip
            if tip then
                local t = target(tip.hash, true)
                t.hide_owners = collapsed_in(u.marker.signature)
                t.follow, t.commit = tip.hash, tip
                return t
            end
        end
        return { state = "collapsed" } -- packed line, no selection
    end
    local c = item.commit
    if not c then return nil end
    local selected = ctx.selection_state.index and ctx.selection_state.commit == c
        and selected_owner_ids(c, ctx.selection_state.index) or nil
    local t
    if c.collapsed then
        local tip = c.tip
        if not tip then return nil end
        t = target(tip.hash, true)
        t.follow, t.commit = tip.hash, tip
        t.hide_owners = selected or collapsed_in(c.signature)
    else
        t = target(c.hash, false)
        t.follow, t.commit = c.hash, c
        t.hide_owners = selected
    end
    t.selected = selected
    return t
end
GRAPH_HELPERS.branch_under_cursor = branch_under_cursor

-- Act on `<Space>`'s target (§10.4): expand a `◍`'s owners or collapse an open
-- row's, reflowing with the cursor kept on the result. A collapse that leaves
-- keepers (branches built on top) says so — `still open via …` — and so does a
-- row with nothing of its own left to collapse; a mainline row only gets the
-- notice naming its anchors. Never flips a ref's mode back and forth while the row
-- stays put: the row's state decides the direction.
---@param b table  -- a `branch_under_cursor` result
GRAPH_HELPERS.toggle_branch = function(ctx, b)
    local owners = b.owners or {}
    if b.state == "collapsed" then
        if #owners > 0 then ctx:set_branch(b, "normal", b.follow) end
    elseif b.state == "expanded" then
        if #owners > 0 then ctx:set_branch(b, "collapsed", b.follow) end
        if b.keepers and #b.keepers > 0 then
            vim.notify("still open via " .. selectm.owner_label(b.keepers, ctx.repo.refs), vim.log.levels.INFO)
        end
    elseif b.state == "mainline" and b.anchors and #b.anchors > 0 then
        vim.notify(("on %s's mainline — not collapsible"):format(selectm.owner_label(b.anchors, ctx.repo.refs)),
            vim.log.levels.INFO)
    end
end

-- The window title identifying the repository (§2.1): its name + current branch,
-- or `detached @<short>` on a detached HEAD, so it always says what is checked out.
local function graph_title(ctx)
    local b = ctx.repo.head
    if not b then
        local h = ctx.repo.refs["HEAD"]
        b = h and h.commit and ("detached @" .. h.commit.hash:sub(1, 7))
    end
    return b and (" %s · %s "):format(ctx.repo_name, b) or (" %s "):format(ctx.repo_name)
end
GRAPH_HELPERS.graph_title = graph_title

-- Apply a mode to a branch's owners, reflow, and keep the cursor on it (§10.4).
local function set_branch(ctx, b, mode, follow)
    for _, oid in ipairs(b.owners or {}) do ctx.view_state.modes[oid] = mode end
    ctx:reflow()
    ctx:update_footer()
    if follow then ctx:goto_hash(follow) end
    ctx:place_cursor()
end
GRAPH_HELPERS.set_branch = set_branch

-- Expand the collapsed branch(es) containing `hash` so the commit becomes its own
-- visible row (§10.3) rather than staying folded inside a `◍` head. Used by the
-- filter jump (§16.4) so landing on a match **opens** its branch. Sets the
-- commit's own owners (§10.2) normal — `select.open_owners`, the same rule as
-- `<Space>` on a `◍`, so a collapsed branch built on top stays folded — and
-- reflows; a no-op when the commit is already a visible row (or has no
-- signature). Returns true if it reflowed.
local function ensure_expanded(ctx, hash)
    if not hash then return false end
    for _, it in ipairs(ctx.repo.display or {}) do
        if it.commit and it.commit.hash == hash and not it.commit.collapsed then
            return false -- already a visible commit row
        end
    end
    if not (ctx.sig_cache.sig and ctx.sig_cache.sig[hash]) then return false end
    local changed = false
    for _, oid in ipairs(selectm.open_owners(ctx.sig_cache.sig, hash, ctx.view_state.owner_tip or {},
        ctx.view_state.effective)) do
        ctx.view_state.modes[oid] = "normal"
        changed = true
    end
    if changed then
        ctx:reflow()
        ctx:update_footer()
    end
    return changed
end
GRAPH_HELPERS.ensure_expanded = ensure_expanded

--- Drill into a submodule as a navigation FRAME in the current host window
--- (§14.7): push a graph frame for `sub_folder`, focused on `focus_hash` with the
--- `seed_refs` synthetic pointer refs, onto `host_root`'s view stack — NOT the
--- submodule's own host window (that is `<leader>wG`, §14.5). `<C-o>` returns to
--- the commit view it was opened from; the frame stays in the stack and is
--- restored on return. The frame's per-buffer BufEnter hook retargets the git
--- active root to the submodule so its fetches read the submodule, and navigating
--- back retargets to the parent (so each repo's on-demand I/O stays correct).
---@param host_root string  the repo root whose host window receives the frame
---@param sub_folder string  the submodule's path
---@param opts GraphOptions
---@param focus_hash string?
---@param seed_refs? { hash: string, name: string, hl: string }[]
function M.drill_submodule(host_root, sub_folder, opts, focus_hash, seed_refs)
    -- No live host to attach to (shouldn't happen from a commit frame): fall back
    -- to opening the submodule in its own window so the link still works.
    if not (nav.sessions[host_root] and nav.sessions[host_root].stack and nav.host_win(host_root)) then
        return M.open(sub_folder, opts, focus_hash, seed_refs)
    end
    -- Copy opts (and opts.win) so open_graph's in-place mutations (keys/zindex/
    -- on_win) don't touch the parent graph's config; palette / diff provider /
    -- geometry are inherited.
    local sub_opts = vim.tbl_extend("force", opts, { win = vim.tbl_extend("force", opts.win or {}, {}) })
    -- A fresh scratch buffer for the frame; it lives in the stack until dropped.
    local frame_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[frame_buf].bufhidden = "hide"
    local attach = { winid = function() return nav.host_win(host_root) end, buf = frame_buf, host_root = host_root }
    local lv, on_show = open_graph(sub_folder, sub_opts, focus_hash, seed_refs, attach)
    if not lv then
        pcall(vim.api.nvim_buf_delete, frame_buf, { force = true })
        return
    end
    -- A graph frame has no intra-view jumplist (unlike the commit view), so it just
    -- needs the plain back/forward keys — the root graph gets these from
    -- nav.register on the host buffer; a drilled-in frame's own buffer needs them
    -- too, else <C-o> falls through to Vim's native jumplist (§14.3).
    nav.install_nav_keys(frame_buf, host_root)
    nav.push_frame(host_root, {
        kind = "graph",
        buf = frame_buf,
        on_enter = on_show,
        label = vim.fn.fnamemodify(sub_folder, ":t"),
    })
    return lv
end

--- Open the graph for a repository, or **re-show** its host window if one is
--- already open (§14): one host window per repository root, never stacked.
--- `<leader>wG`'s picker and `:GitloomGraph` both route here. `focus_hash` /
--- `seed_refs` (the submodule deep-link, §11.7.6) apply only when the window is
--- built fresh; re-showing an open repo restores where you were.
---@param folder string|nil
---@param opts GraphOptions
---@param focus_hash string|nil
---@param seed_refs table|nil
function M.open(folder, opts, focus_hash, seed_refs)
    local root = resolve_root(folder)
    local sess = nav.sessions[root]
    if nav.valid(sess) then
        git.set_cwd(root)
        nav.show(sess)
        return sess.host
    end
    nav.hide_others(root)
    local lv, on_show = open_graph(folder, opts, focus_hash, seed_refs)
    if lv and lv.win then nav.register(root, lv.win, on_show) end
    return lv
end

--- Reset view settings (`:GitloomResetView`, spec §18.5): the graph in the
--- current window, else the repository at Neovim's cwd. With a live graph for it
--- this is the palette entry (confirm, clear, restore live); with none, it asks the
--- same question and clears that repository's entries + the global preferences
--- from the file.
---@param opts GraphOptions?
function M.reset_view(opts)
    local cur = vim.api.nvim_get_current_buf()
    local target
    for _, c in pairs(nav.ctxs) do
        if c.buf == cur and nav.valid(nav.sessions[c.host_root]) then target = c end
    end
    local root = target and target.repo.root or resolve_root(nil)
    if not target then
        local c = nav.ctxs[root]
        if c and nav.valid(nav.sessions[c.host_root]) then target = c end
    end
    if target then return target:reset_view() end
    local persist = require("gitloom.persist")
    persist.confirm_reset(function()
        persist.reset(opts or {}, root)
        vim.notify("gitloom: view settings reset", vim.log.levels.INFO)
    end)
end

--- Return to the most-recently-shown host window (`<leader>wg`, §14) — the
--- counterpart to `q`: re-show the stack you last left, where you left it. With
--- no session to return to, open the repository at Neovim's cwd (cold start).
---@param opts GraphOptions
function M.return_last(opts)
    local root = nav.mru[1]
    local sess = root and nav.sessions[root]
    if nav.valid(sess) then
        git.set_cwd(sess.root)
        nav.show(sess)
        return sess.host
    end
    return M.open(nil, opts)
end

--- Repository picker (spec §2.1): pick the main module or one of its direct
--- submodules and open the graph for it. The intended binding is the user's own
--- (e.g. `<leader>wG`); `:GitloomPick` forwards setup() config here.
---
--- The picker **opens immediately** with the entries whose paths are known up
--- front (the main module, then each submodule as `fetch_submodules` resolves —
--- one spawn, so in practice they all arrive at once) and **fills each row's
--- branch / commit summary asynchronously** as
--- git returns it (spec §2/§2.1) — mutating the item and re-rendering, so a slow
--- or large submodule never blocks the list. An uninitialized submodule is shown
--- disabled (no local repo to open). Confirming opens `M.open` on that repo.
---@param opts GraphOptions
function M.pick(opts)
    opts = opts or {}
    local picker_ok, picker = pcall(require, "snacks.picker")
    if not picker_ok then
        vim.notify("gitloom: snacks.picker not available", vim.log.levels.WARN)
        return
    end

    local main_root = resolve_root(nil)
    -- The main module is known instantly, so the picker can open at once; its
    -- summary and the submodule list/summaries fill in below.
    local main_item = {
        kind = "main",
        label = vim.fn.fnamemodify(main_root, ":t") .. " (main module)",
        target = main_root,
        state = "ok",
        checked_out = true,
        text = "main module " .. main_root,
    }
    local items = { main_item }

    local align = picker.util.align
    local p
    -- Re-render the open list after mutating an item's fields (cheap, no finder
    -- re-run); add a freshly-discovered item by re-running the finder (which
    -- returns the live `items` table). No-ops once the picker is closed.
    local function rerender()
        if p and not p.closed then p:update({ force = true }) end
    end
    local function readd()
        if p and not p.closed then p:find({ refresh = true }) end
    end

    -- Fill one entry's branch/commit summary in place, then re-render.
    local function fill(item, cwd)
        fetch_repo_summary(cwd).next(function(s)
            item.branch, item.short, item.subject = s.branch, s.short, s.subject
            item.filled = true
            rerender()
        end)
    end

    p = picker.pick({
        source = "gitloom_repos",
        title = "Gitloom repositories",
        items = items,
        layout = { preset = "select" }, -- compact, no preview window
        ---@param item { kind: string, label: string, state: string, branch?: string, short?: string, subject?: string, filled?: boolean }
        format = function(item)
            local ret = {}
            local label_hl = item.kind == "main" and "SnacksPickerGitBranchCurrent" or "SnacksPickerDirectory"
            ret[#ret + 1] = { align(item.label, 32, { truncate = true }), label_hl }
            ret[#ret + 1] = { " " }
            if item.state == "uninitialized" then
                ret[#ret + 1] = { align("(not checked out)", 20), "SnacksPickerComment" }
            elseif item.filled then
                ret[#ret + 1] = { align(item.branch ~= "" and item.branch or "(detached)", 18, { truncate = true }),
                    "SnacksPickerGitBranch" }
                ret[#ret + 1] = { " " }
                ret[#ret + 1] = { align(item.short or "", 8), "SnacksPickerGitCommit" }
                ret[#ret + 1] = { " " }
                ret[#ret + 1] = { item.subject or "", "SnacksPickerComment" }
            else
                ret[#ret + 1] = { "…", "SnacksPickerComment" } -- summary still loading
            end
            return ret
        end,
        confirm = function(pk, item)
            pk:close()
            if not item then return end
            if not item.checked_out then
                vim.notify(
                    ("gitloom: %s is not checked out"):format(item.label),
                    vim.log.levels.INFO)
                return
            end
            -- Open after the picker tears down (it restores focus to the prior
            -- window first), like the ref picker's confirm.
            vim.schedule(function() M.open(item.target, opts) end)
        end,
    })

    -- Fill the main module's summary, then discover + append + fill submodules.
    fill(main_item, main_root)
    fetch_submodules(main_root).next(function(subs)
        for _, s in ipairs(subs) do
            local abspath = main_root .. "/" .. s.path
            local item = {
                kind = "submodule",
                label = s.path,
                target = abspath,
                state = s.state,
                checked_out = s.checked_out,
                text = s.path,
            }
            items[#items + 1] = item
            if s.checked_out then fill(item, abspath) end
        end
        readd() -- bring the new submodule rows into the open list
    end)

    return p
end

-- Test seam (NOT the public API): the pure, ctx-taking graph helpers, exposed so
-- specs can drive them against a hand-built ctx/repo fixture — the resync core
-- (reconcile_refs / prune_to_reachable), the working-tree splice (apply_worktree
-- / clear_worktree_nodes), the owned re-sort (reorder_repo), the per-commit
-- linker (integrate_commit), and the pin resolution (effective_pinned). These
-- mutate only their `ctx.repo`, touching no window. Mirrors graph._internal.
M._internal = {
    ctx = nil, -- set by open_graph; the live session (diagnostics / smoke test)
    effective_pins = GRAPH_HELPERS.effective_pins,
    effective_pinned = effective_pinned,
    pin_rank = GRAPH_HELPERS.pin_rank,
    sync_pin_rank = GRAPH_HELPERS.sync_pin_rank,
    pin_counterpart = GRAPH_HELPERS.pin_counterpart,
    pin_dialog = GRAPH_HELPERS.pin_dialog, -- §10.6.1; windowed smoke test seam
    reconcile_refs = reconcile_refs,
    prune_to_reachable = prune_to_reachable,
    reorder_repo = reorder_repo,
    clear_worktree_nodes = clear_worktree_nodes,
    apply_worktree = apply_worktree,
    integrate_commit = integrate_commit,
    -- The §10.4 collapse target + <Space>'s act-and-notify, over a stub ctx; space_toggle_spec.
    branch_under_cursor = branch_under_cursor,
    toggle_branch = GRAPH_HELPERS.toggle_branch,
    -- The owner resolution (effective modes, owner tips, the §6 expanded set) and
    -- the label marks built from it; space_toggle_spec.
    reflow_owners = GRAPH_HELPERS.reflow_owners,
    pin_marks = GRAPH_HELPERS.pin_marks,
    build_display_index = build_display_index,
    on_cursor_moved = on_cursor_moved, -- the CursorMoved pre-selection (§2); window_internal_spec
    -- Not named `cursor_hash`: specs copy _internal onto stub ctxs whose own
    -- `cursor_hash` it would shadow.
    cursor_hash_at = cursor_hash, -- a packed line's default marker (§2); window_internal_spec
    open_diffview = open_diffview, -- the default diff provider (§11.5); diff_provider_spec
    keys = GRAPH_HELPERS.key_registry(), -- the key registry GRAPH_KEYS (§17.1); palette_spec
    -- §19.4's "always ended" glue paths, driven over a stub ctx; progress_spec
    reflow_async = GRAPH_HELPERS.reflow_async,
    resync = GRAPH_HELPERS.resync,
    -- The palette fetch / pull glue + the fetch log (§17.4), over a stub ctx; palette_spec
    run_remote = GRAPH_HELPERS.run_remote,
    show_remote_log = GRAPH_HELPERS.show_remote_log,
    refresh_remote_log = GRAPH_HELPERS.refresh_remote_log,
    -- The float z-order layers (§14), read off a host window; zorder_spec.
    host_zindex = host_zindex,
    overlay_zindex = overlay_zindex,
    float_zindex = float_zindex,
}

return M
