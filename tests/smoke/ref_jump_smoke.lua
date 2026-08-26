-- Headless smoke-test for the `<leader>b` ref-picker jump vs. the context panes
-- (spec §2 / §6.2).
--
-- Reported symptom: after jumping to a branch with `<leader>b`, the header and
-- footer overlays are no longer shown, and stay gone. `jump_to_ref` ends in
-- `ctx:update_panes()`, so a jump must leave both panes standing exactly as the
-- `on_show` sequence does.
--
-- This drives the REAL snacks picker (no stubbing) in a real window and checks
-- the overlays structurally — the non-focusable floats anchored to the graph
-- window — so it needs no test seam into window.lua.
--
-- **Harness note, and the reason every step runs from `vim.defer_fn`:** nvim
-- triggers `WinScrolled` from its MAIN LOOP (`may_trigger_win_scrolled_resized`),
-- not from the libuv event loop. A harness that blocks in `vim.wait()` never
-- returns to the main loop, so `WinScrolled` NEVER FIRES in it — measured: 0
-- events across a `zz` that moved the topline from 1 to 137. The pane machinery
-- is scroll-gated on that autocmd (`maybe_update_panes`, and the handler that
-- bumps `pane_gen` to abandon an in-flight build), so a `vim.wait`-driven
-- harness silently exercises a different code path. Stepping via `vim.defer_fn`
-- returns to the main loop between steps and the events fire normally.
--
-- Run:  nvim --headless -u tests/minimal_init.lua \
--         -c "lua require('tests.smoke.ref_jump_smoke').run()"
-- Exits 0 on PASS (qa!), 1 on FAIL (cq) so `make smoke-refjump` reflects it.

local M = {}

local fails = {}
local function fail(msg) fails[#fails + 1] = msg end

local ctx_buf, graph_win

-- The graph window, re-resolved live (§14 changes the id across hide/show).
local function live_win()
    local w = ctx_buf and vim.fn.bufwinid(ctx_buf) or -1
    return (w ~= -1 and vim.api.nvim_win_is_valid(w)) and w or nil
end

-- The context panes, found structurally: borderless, non-focusable floats
-- anchored to the graph window (`relative = "win"`), one at the top (header),
-- one at the bottom (footer).
local function panes()
    local w = live_win()
    if not w then return 0, 0 end
    local top, bottom = 0, 0
    for _, p in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local c = vim.api.nvim_win_get_config(p)
        if c.relative == "win" and c.win == w and c.focusable == false then
            local row = type(c.row) == "table" and (c.row[false] or c.row[1]) or c.row
            if (row or 0) == 0 then top = top + 1 else bottom = bottom + 1 end
        end
    end
    return top, bottom
end

local function input(keys) pcall(vim.api.nvim_input, keys) end

-- Run `steps` one per deferred tick, so nvim's main loop runs in between (see
-- the harness note above), then finish.
local function chain(steps, i)
    i = i or 1
    if i > #steps then return M.finish() end
    vim.defer_fn(function()
        local ok, err = pcall(steps[i])
        if not ok then fail("step " .. i .. ": " .. tostring(err)) end
        chain(steps, i + 1)
    end, 220)
end

local function scenario()
    local steps = {}
    local function add(f) steps[#steps + 1] = f or function() end end

    add(function()
        graph_win = assert(live_win(), "graph window vanished")
        vim.api.nvim_set_current_win(graph_win)
        -- Park mid-graph and centre, so BOTH panes have off-screen topology.
        local n = vim.api.nvim_buf_line_count(ctx_buf)
        vim.api.nvim_win_set_cursor(graph_win, { math.floor(n / 2), 0 })
    end)
    add(function() input("zz") end)
    add()
    add(function()
        local top, bottom = panes()
        if top < 1 or bottom < 1 then
            fail(("panes missing BEFORE the jump (header=%d footer=%d) — the rest of "
                .. "this run proves nothing"):format(top, bottom))
        end
    end)
    add(function() input((vim.g.mapleader or "\\") .. "b") end)
    add()
    add(function()
        local top, bottom = panes()
        if top < 1 or bottom < 1 then
            fail(("panes closed while the picker was open (header=%d footer=%d)"):format(top, bottom))
        end
        -- Walk a few entries down so we do not land on HEAD (row 1), where the
        -- header legitimately reports "at top".
        for _ = 1, 7 do input("<C-n>") end
    end)
    add()
    add(function() input("<CR>") end)
    add(); add(); add(); add()
    add(function()
        local w = live_win()
        if not w then
            fail("graph window gone after the jump")
            return
        end
        local top, bottom = panes()
        local view = vim.api.nvim_win_call(w, vim.fn.winsaveview)
        if view.topline <= 1 then
            -- Landed at the very top: the header is *meant* to hide there (§6.2),
            -- so this run cannot judge it. Only the footer is conclusive.
            if bottom < 1 then
                fail("footer gone after a <leader>b jump (landed at the top of the graph)")
            end
        elseif top < 1 or bottom < 1 then
            fail(("panes gone after a <leader>b jump (header=%d footer=%d, topline=%d)")
                :format(top, bottom, view.topline))
        end
    end)
    -- ... and they must survive the settling that follows (the cone debounce
    -- runs ~60ms later and takes the gated `maybe_update_panes` path).
    add(); add()
    add(function()
        local w = live_win()
        if not w then return end
        local top, bottom = panes()
        local view = vim.api.nvim_win_call(w, vim.fn.winsaveview)
        if view.topline > 1 and (top < 1 or bottom < 1) then
            fail(("panes disappeared after the jump settled (header=%d footer=%d)"):format(top, bottom))
        end
    end)
    chain(steps)
end

function M.run()
    vim.opt.rtp:prepend(vim.fn.stdpath("data") .. "/lazy/snacks.nvim")
    vim.o.lines, vim.o.columns = 45, 200
    local ok_snacks = pcall(function()
        require("snacks").setup({ picker = { enabled = true }, input = { enabled = true } })
    end)
    if not ok_snacks then fail("snacks setup failed"); return M.finish() end

    local window = require("gitloom.window")
    ---@diagnostic disable-next-line: missing-fields
    local lv = window.open(nil, {} --[[@as GraphOptions]])
    if not lv then fail("window.open returned nil"); return M.finish() end
    ctx_buf = lv.buf

    -- Poll for the async stream from a timer (never vim.wait — see the note).
    local tries = 0
    local function wait_stream()
        tries = tries + 1
        local n = (ctx_buf and vim.api.nvim_buf_is_valid(ctx_buf))
            and vim.api.nvim_buf_line_count(ctx_buf) or 0
        if n > 50 then
            vim.defer_fn(scenario, 1200) -- let the §10.7 default reflow land
        elseif tries > 200 then
            fail("graph buffer never populated (" .. n .. " lines)")
            M.finish()
        else
            vim.defer_fn(wait_stream, 100)
        end
    end
    vim.defer_fn(wait_stream, 300)
end

function M.finish()
    if #fails == 0 then
        print("REF-JUMP SMOKE: PASS")
        vim.cmd("qa!")
    else
        print("REF-JUMP SMOKE: FAIL (" .. #fails .. ")")
        for _, f in ipairs(fails) do print("  - " .. f) end
        vim.cmd("cq")
    end
end

return M
