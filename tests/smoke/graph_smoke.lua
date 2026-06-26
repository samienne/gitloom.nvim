-- Headless smoke-test for the window glue (which has no busted coverage).
--
-- Opens the REAL graph on this repository, waits for the async commit stream to
-- settle, then drives the main keymaps and asserts that NO runtime error fired in
-- any handler or async callback (the exact failure mode a closure→module-function
-- refactor risks: a stale window id, a bare sibling call resolving to nil). The
-- specific per-key invariants are deliberately light and observable so this test
-- survives the refactor unchanged.
--
-- Run:  nvim --headless -u tests/minimal_init.lua \
--         -c "lua require('tests.smoke.graph_smoke').run()"
-- Exits 0 on PASS (qa!), 1 on FAIL (cq) so `make smoke` reflects the result.

local M = {}

-- Collected failures; the run prints them and sets the exit code.
local fails = {}
local function fail(msg) fails[#fails + 1] = msg end

-- Scan the message history for an error logged by an async callback (timer /
-- jobstart / vim.schedule / autocmd) — these don't propagate through pcall.
-- Returns the offending line, or nil.
local function async_error()
    local ok, msgs = pcall(vim.fn.execute, "messages")
    if not ok or not msgs then return nil end
    for _, line in ipairs(vim.split(msgs, "\n", { plain = true })) do
        if line:match("Error executing")
            or line:match("E5108")
            or line:match("stack traceback")
            or line:match("^E%d+:") then
            return line
        end
    end
    return nil
end

local function feed(keys)
    local t = vim.api.nvim_replace_termcodes(keys, true, false, true)
    pcall(vim.api.nvim_feedkeys, t, "x", false)
end

-- Run `label`'s key sequence, settle the event loop, and record any error.
local function step(label, keys, win)
    vim.v.errmsg = ""
    vim.cmd("messages clear")
    if keys then feed(keys) end
    vim.wait(250, function() return false end) -- let debounced cone/pane work run
    local aerr = async_error()
    if aerr then fail(("[%s] async error: %s"):format(label, aerr)) end
    if vim.v.errmsg ~= "" then fail(("[%s] errmsg: %s"):format(label, vim.v.errmsg)) end
    if win and not vim.api.nvim_win_is_valid(win) then
        fail(("[%s] host window became invalid"):format(label))
    end
end

function M.run()
    -- snacks is needed for the real window; minimal_init only wires the plugin.
    vim.opt.rtp:prepend(vim.fn.stdpath("data") .. "/lazy/snacks.nvim")
    vim.o.lines, vim.o.columns = 60, 160
    local ok_snacks = pcall(function()
        require("snacks").setup({ picker = { enabled = true }, input = { enabled = true } })
        vim.ui.select = require("snacks.picker").select
    end)
    if not ok_snacks then fail("snacks setup failed"); return M.finish() end

    local window = require("gitloom.window")
    -- open_graph fills GraphOptions defaults at runtime; this harness passes none.
    ---@diagnostic disable-next-line: missing-fields
    local OPTS = {} --[[@as GraphOptions]]

    local ok_open, lv = pcall(window.open, nil, OPTS)
    if not ok_open or not lv then
        fail("window.open errored: " .. tostring(lv)); return M.finish()
    end

    -- Wait for the stream to populate the graph buffer (rows arrive async, then a
    -- reflow lands the §10.7 default collapse). Settle on a stable line count.
    local buf = lv.buf
    local last_n, stable = -1, 0
    vim.wait(8000, function()
        if not (buf and vim.api.nvim_buf_is_valid(buf)) then return false end
        local n = vim.api.nvim_buf_line_count(buf)
        if n == last_n and n > 1 then stable = stable + 1 else stable = 0 end
        last_n = n
        return stable >= 4 -- ~1s of no change
    end, 60)

    local win = lv.winid and lv.winid()
    if not (win and vim.api.nvim_win_is_valid(win)) then
        fail("no valid host window after open"); return M.finish()
    end
    local n0 = vim.api.nvim_buf_line_count(buf)
    if n0 < 2 then fail("graph buffer never populated (" .. n0 .. " lines)") end
    if async_error() then fail("async error during open: " .. async_error()) end

    -- Make the window current so feedkeys lands in it.
    pcall(vim.api.nvim_set_current_win, win)

    -- Drive the main surface. Each step asserts no error + a live window.
    step("nav-down", "jjjj", win)
    step("nav-up", "kk", win)
    step("page-down", "<C-d>", win)
    step("page-up", "<C-u>", win)

    -- Collapse/expand on a collapsed head if one is visible, else at HEAD.
    pcall(vim.api.nvim_set_current_win, win)
    pcall(vim.fn.search, "◍", "w")
    step("collapse-toggle-1", "<Space>", win)
    step("collapse-toggle-2", "<Space>", win)

    -- Style / mode toggles (render + relayout paths).
    step("merge-style", "m", win)
    step("mirror", "M", win)
    step("mirror-off", "M", win)
    step("label-mode", "B", win)
    step("label-mode-off", "BB", win)
    step("dates", "d", win)
    step("dim-toggle", "H", win)
    step("dim-on", "H", win)
    step("focus-toggle", "c", win)
    step("focus-on", "c", win)
    step("pack", "p", win)
    step("pack-on", "p", win)
    step("panes-toggle", "F", win)
    step("panes-on", "F", win)

    -- Sort cycle (async rev modes).
    step("sort-1", "S", win)
    vim.wait(400, function() return false end)
    step("sort-2", "S", win)
    vim.wait(400, function() return false end)

    -- Commit selection (range) walk.
    step("select-start", "V", win)
    step("select-walk", "jj", win)
    step("select-swap", "o", win)
    step("select-exit", "<Esc>", win)

    -- Commit view open + close (a navigation-stack frame). Park on HEAD (a normal
    -- commit) first so <CR> opens the view rather than the action menu; <Esc>
    -- defensively dismisses a menu/picker if one opened instead.
    pcall(vim.api.nvim_set_current_win, win)
    feed("gg")
    step("commit-view-open", "<CR>", win)
    vim.wait(600, function() return false end)
    if async_error() then fail("commit-view async error: " .. tostring(async_error())) end
    step("commit-view-back", "q", win)
    feed("<Esc>")

    -- Resync (the R history refresh).
    pcall(vim.api.nvim_set_current_win, win)
    step("resync", "R", win)
    vim.wait(800, function() return false end)
    if async_error() then fail("resync async error: " .. tostring(async_error())) end

    -- Hide → re-show: the host re-opens with a NEW window id (§14 live-id path).
    -- M.open returns the snacks `host` for an existing session, so locate the
    -- re-shown window via the (stable) graph buffer.
    vim.cmd("messages clear")
    feed("q") -- hides the host
    vim.wait(400, function() return false end)
    pcall(window.open, nil, OPTS)
    vim.wait(600, function() return false end)
    local win2 = buf and vim.api.nvim_buf_is_valid(buf) and vim.fn.bufwinid(buf) or -1
    if not (win2 and win2 ~= -1 and vim.api.nvim_win_is_valid(win2)) then
        fail("re-show did not put the graph buffer in a valid window")
    else
        step("re-show-nav", "jk", win2)
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
        vim.cmd("cq") -- non-zero exit
    end
end

return M
