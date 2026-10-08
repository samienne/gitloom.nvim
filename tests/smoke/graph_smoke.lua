-- Headless smoke-test for the window glue (which has no busted coverage).
--
-- Opens the REAL graph on this repository, waits for the async commit stream to
-- settle, then drives the main keymaps and asserts that NO runtime error fired in
-- any handler or async callback (the exact failure mode a closure→module-function
-- refactor risks: a stale window id, a bare sibling call resolving to nil).
--
-- The §14 single-window model deliberately changes the host window id across
-- hide/show, so this harness NEVER holds a window id — it re-resolves the live
-- window from the (stable) graph buffer each time. The per-key invariants are
-- intentionally light/observable so the test survives the refactor unchanged.
--
-- Run:  nvim --headless -u tests/minimal_init.lua \
--         -c "lua require('tests.smoke.graph_smoke').run()"
-- Exits 0 on PASS (qa!), 1 on FAIL (cq) so `make smoke` reflects the result.

local M = {}

local fails = {}
local function fail(msg) fails[#fails + 1] = msg end

-- Busy-wait helper for vim.wait: just spin the event loop for the full duration.
local function settle(ms) vim.wait(ms or 250, function() return false end) end

-- Scan the message history for an error logged by an async callback (timer /
-- jobstart / vim.schedule / autocmd) — these don't propagate through pcall.
local function async_error()
    local ok, msgs = pcall(vim.fn.execute, "messages")
    if not ok or not msgs then return nil end
    for _, line in ipairs(vim.split(msgs, "\n", { plain = true })) do
        if line:match("Error executing") or line:match("E5108")
            or line:match("stack traceback") or line:match("^E%d+:") then
            return line
        end
    end
    return nil
end

local function feed(keys)
    local t = vim.api.nvim_replace_termcodes(keys, true, false, true)
    pcall(vim.api.nvim_feedkeys, t, "x", false)
end

-- State shared across the run.
local window, OPTS, gbuf

-- The window currently showing the graph buffer (re-resolved live), or nil when
-- the graph frame is off-screen (a commit-view frame is up, or the host is hidden).
local function live()
    if not (gbuf and vim.api.nvim_buf_is_valid(gbuf)) then return nil end
    local w = vim.fn.bufwinid(gbuf)
    return (w ~= -1 and vim.api.nvim_win_is_valid(w)) and w or nil
end

-- Ensure the graph frame is shown and current; returns the live window or nil.
local function focus()
    local w = live()
    if not w then
        pcall(window.open, nil, OPTS) -- re-show a hidden session / pop to graph
        settle(500)
        feed("<C-o>") -- if a commit-view frame is up, walk back to the graph
        settle(200)
        w = live()
    end
    if w then pcall(vim.api.nvim_set_current_win, w) end
    return w
end

-- Feed `label`'s keys, settle, and record any async error. No window assertion —
-- some steps (q) intentionally hide the host.
local function step(label, keys)
    vim.v.errmsg = ""
    pcall(function() vim.cmd("messages clear") end)
    if keys then feed(keys) end
    settle(250)
    local aerr = async_error()
    if aerr then fail(("[%s] async error: %s"):format(label, aerr)) end
    if vim.v.errmsg ~= "" then fail(("[%s] errmsg: %s"):format(label, vim.v.errmsg)) end
end

function M.run()
    vim.opt.rtp:prepend(vim.fn.stdpath("data") .. "/lazy/snacks.nvim")
    vim.o.lines, vim.o.columns = 60, 160
    local ok_snacks = pcall(function()
        require("snacks").setup({ picker = { enabled = true }, input = { enabled = true } })
        vim.ui.select = require("snacks.picker").select
    end)
    if not ok_snacks then fail("snacks setup failed"); return M.finish() end

    window = require("gitloom.window")
    ---@diagnostic disable-next-line: missing-fields
    OPTS = {} --[[@as GraphOptions]]

    local ok_open, lv = pcall(window.open, nil, OPTS)
    if not ok_open or not lv then
        fail("window.open errored: " .. tostring(lv)); return M.finish()
    end
    gbuf = lv.buf

    -- Wait for the stream to populate the graph buffer and settle (rows arrive
    -- async, then a reflow lands the §10.7 default collapse). Stable line count.
    local last_n, stable = -1, 0
    vim.wait(8000, function()
        if not (gbuf and vim.api.nvim_buf_is_valid(gbuf)) then return false end
        local n = vim.api.nvim_buf_line_count(gbuf)
        if n == last_n and n > 1 then stable = stable + 1 else stable = 0 end
        last_n = n
        return stable >= 4
    end, 60)

    if not focus() then fail("no valid host window after open"); return M.finish() end
    if vim.api.nvim_buf_line_count(gbuf) < 2 then
        fail("graph buffer never populated (" .. vim.api.nvim_buf_line_count(gbuf) .. " lines)")
    end
    if async_error() then fail("async error during open: " .. async_error()) end
    -- The §10.7 default collapse must have LANDED, not merely been scheduled:
    -- the projection is applied by an async reflow (§10.5) driven across
    -- event-loop ticks, so "the buffer stopped growing" is also true of a reflow
    -- that never ran. Headless has no UI, so the rendered text does not exist to
    -- be inspected -- the listview draws through a decoration provider, and the
    -- buffer lines themselves are empty. Read the projected model instead.
    local sess = require("gitloom.window")._internal.ctx
    local function collapsed_heads()
        local n = 0
        for _, it in ipairs((sess and sess.repo.display) or {}) do
            if it.type == "markers" then
                n = n + #(it.markers or {})
            elseif it.commit and it.commit.collapsed then
                n = n + 1
            end
        end
        return n
    end
    if not sess then
        fail("no graph session was recorded")
    else
        -- `repo.display ~= repo.order` is NOT the signal: `apply_sort` rebuilds
        -- repo.order into a fresh table, and `view.project` always returns fresh
        -- OrderItems. The collapse itself is: this repository has unpinned
        -- branches, so a focused view must carry collapsed heads.
        vim.wait(6000, function() return collapsed_heads() > 0 end, 50)
        if collapsed_heads() == 0 then
            fail(("the §10.7 default collapse never landed (no collapsed head over %d rows)")
                :format(#((sess and sess.repo.display) or {})))
        end
    end

    -- Navigation.
    focus(); step("nav-down", "jjjj"); step("nav-up", "kk")
    step("page-down", "<C-d>"); step("page-up", "<C-u>")

    -- Collapse/expand on a collapsed head if visible, else wherever the cursor is.
    focus(); pcall(vim.fn.search, "◍", "w")
    step("collapse-1", "<Space>"); step("collapse-2", "<Space>")

    -- Style / mode toggles (render + relayout paths).
    focus()
    step("merge-style", "m")
    step("mirror", "M"); step("mirror-off", "M")
    step("label-mode", "B"); step("label-mode-off", "BB")
    step("dates", "d")
    step("dim-off", "H"); step("dim-on", "H")
    step("focus-off", "c"); step("focus-on", "c")
    step("pack", "p"); step("pack-on", "p")
    step("panes-toggle", "F"); step("panes-on", "F")

    -- Sort cycle (async rev modes).
    step("sort-1", "S"); settle(400)
    step("sort-2", "S"); settle(400)

    -- Commit selection (range) walk.
    focus()
    step("select-start", "V"); step("select-walk", "jj")
    step("select-swap", "o"); step("select-exit", "<Esc>")

    -- Commit view: park on HEAD, <CR> opens the frame directly (§11.1; the
    -- <Esc> is harmless). Then walk back to the graph.
    focus(); feed("gg")
    step("commit-view-open", "<CR>"); settle(500)
    feed("<Esc>")
    step("commit-view-back", "<C-o>")

    -- Resync (the R history refresh).
    focus(); step("resync", "R"); settle(800)
    if async_error() then fail("resync async error: " .. tostring(async_error())) end

    -- Hide → re-show: the host re-opens with a NEW window id (§14 live-id path).
    focus()
    pcall(function() vim.cmd("messages clear") end)
    feed("q"); settle(400)
    if live() ~= nil then fail("q did not hide the host (graph buffer still windowed)") end
    pcall(window.open, nil, OPTS); settle(600)
    local w2 = live()
    if not w2 then
        fail("re-show did not put the graph buffer in a valid window")
    else
        pcall(vim.api.nvim_set_current_win, w2)
        step("re-show-nav", "jk")
    end
    if async_error() then fail("re-show async error: " .. tostring(async_error())) end

    return M.finish()
end

function M.finish()
    if #fails == 0 then
        print("SMOKE: PASS")
        vim.cmd("qa!")
    else
        print("SMOKE: FAIL (" .. #fails .. ")")
        for _, f in ipairs(fails) do print("  - " .. f) end
        vim.cmd("cq")
    end
end

return M
