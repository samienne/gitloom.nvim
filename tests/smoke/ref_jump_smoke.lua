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
-- Two environment knobs, because the default (this repo, the 4th picker entry)
-- is a weak stress:
--   GL_REPO=<path>  open the graph on another repository (§2.1). Read-only, and
--                   a BIGGER history is the realistic case — the pane build only
--                   spills onto later event-loop ticks, and so becomes
--                   abandonable at all, once its walks are long. This repo's own
--                   history never yields; a ~1000-commit one does.
--   GL_NEXT=<n>     how far down the picker to move before confirming. Which
--                   entry you land on decides whether the jump moves the view at
--                   all: a ref that is hidden in the focused projection makes
--                   `jump_to_ref` bail with a notify, and a run that never jumped
--                   proves nothing. Sweep it.
--
-- Set `vim.g.gitloom_pane_trace` (README → Diagnostics) alongside a run to get
-- the pane lifecycle — every gate decision, build outcome and decline reason —
-- which is what turns a PASS/FAIL into a diagnosis.
--
-- Run:  nvim --headless -u tests/minimal_init.lua \
--         -c "lua require('tests.smoke.ref_jump_smoke').run()"
-- Exits 0 on PASS (qa!), 1 on FAIL (cq) so `make smoke-refjump` reflects it.
--
-- **Status: the reported symptom does not reproduce here.** It was chased again
-- on **nvim 0.12.5** (the version the report came from), driven through this
-- harness AND through the owner's own Neovim config with the real snacks picker
-- against a 1011-commit repository, across picker offsets and both projections:
-- both overlays survive every jump. The one case where the header is legitimately
-- absent afterwards is a jump that lands at the top of the graph, where §6.2 says
-- it hides. What the trace DOES show on 0.12.5 is that the `WinScrolled` from the
-- jump's own `center_view` arrives AFTER the synchronous chain that follows it —
-- i.e. after the pane build has already finished — exactly as on 0.11.6.

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

-- Assert both overlays are up, EXCEPT where §6.2 says one is legitimately
-- absent. Two such edges, and both must be excused or the check is unsound:
--   * at the TOP of the graph nothing has scrolled off above, so there is no
--     header (`converge_header` reports "at top");
--   * at the BOTTOM nothing is below the seam, so the footer has no rows.
-- Which ref a picker offset lands on shifts as the repository changes (the §4.2
-- working-tree nodes alone move every row), so a run can land on either edge;
-- excusing only the top is what made this flaky.
local function check(when)
    local w = live_win()
    if not w then
        fail("graph window gone " .. when)
        return
    end
    local top, bottom = panes()
    local view = vim.api.nvim_win_call(w, vim.fn.winsaveview)
    local last = vim.api.nvim_buf_line_count(ctx_buf)
    local wlast = vim.api.nvim_win_call(w, function() return vim.fn.line("w$") end)
    local at_top, at_bottom = view.topline <= 1, wlast >= last
    if top < 1 and not at_top then
        fail(("header gone %s (topline=%d)"):format(when, view.topline))
    end
    if bottom < 1 and not at_bottom then
        fail(("footer gone %s (w$=%d of %d)"):format(when, wlast, last))
    end
end

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
        local before = #fails
        check("BEFORE the jump")
        if #fails > before then
            fails[#fails] = fails[#fails] .. " — the rest of this run proves nothing"
        end
    end)
    add(function() input((vim.g.mapleader or "\\") .. "b") end)
    add()
    add(function()
        check("while the picker was open")
        -- Walk a few entries down so we do not land on HEAD (row 1), where the
        -- header legitimately reports "at top". `GL_NEXT` sweeps this.
        for _ = 1, (tonumber(vim.env.GL_NEXT) or 7) do input("<C-n>") end
    end)
    add()
    add(function() input("<CR>") end)
    add(); add(); add(); add()
    add(function() check("after the jump") end)
    -- ... and they must survive the settling that follows (the cone debounce
    -- runs ~60ms later and takes the gated `maybe_update_panes` path).
    add(); add()
    add(function() check("after the jump settled") end)
    chain(steps)
end

function M.run()
    vim.opt.rtp:prepend(vim.g.gitloom_test_deps .. "/snacks.nvim")
    vim.o.lines, vim.o.columns = 45, 200
    local ok_snacks = pcall(function()
        require("snacks").setup({ picker = { enabled = true }, input = { enabled = true } })
    end)
    if not ok_snacks then fail("snacks setup failed"); return M.finish() end

    local window = require("gitloom.window")
    -- `GL_REPO` targets another repository (§2.1). The graph is read-only, and a
    -- BIGGER history is the realistic case: the pane build only spills onto later
    -- event-loop ticks (and so becomes abandonable) once its walks are long.
    local repo = vim.env.GL_REPO
    if repo == "" then repo = nil end
    ---@diagnostic disable-next-line: missing-fields
    local lv = window.open(repo, {} --[[@as GraphOptions]])
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
