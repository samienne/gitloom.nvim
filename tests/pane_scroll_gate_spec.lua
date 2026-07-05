-- The pane-rebuild GATE and virtual-line SUB-SCROLLS (§6.2), tested against a real nvim
-- window. `maybe_update_panes` rebuilds the footer only when its scroll key changes; today
-- that key is `line('w0')` (the topline real line). But with virtual lines the window can
-- scroll by one screen ROW while `line('w0')` stays the same — nvim shows more/fewer of the
-- topline's `virt_lines_above` rows, tracked by `winsaveview().topfill`. Across such a
-- sub-scroll the footer's bottom row (and therefore its seam) changes, yet `line('w0')`
-- does NOT — so a `line('w0')`-only gate leaves the footer STALE. Which stale state you get
-- depends on scroll direction (the reported direction-dependent discontinuity); `F`-`F`
-- forces a rebuild and the FocusGained wt-refresh nudges the topline, both "fixing" it.
--
-- This reproduces the bug and pins the fix: the gate key must be `(topline, topfill)`, not
-- `line('w0')` alone.
local pane = require("gitloom.graph.pane")

-- spec[i] = { above = n, below = n } (n virtual rows above/below line i). Rendered with
-- virt_lines exactly like gitloom (above = virt_lines_above=true).
local function render(spec, win_height)
    local buf = vim.api.nvim_create_buf(false, true)
    local lines = {}
    for i = 1, #spec do lines[i] = ("L%02d"):format(i) end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local ns = vim.api.nvim_create_namespace("pane_scroll_gate")
    for i, s in ipairs(spec) do
        if (s.above or 0) > 0 then
            local rows = {}
            for k = 1, s.above do rows[k] = { { ("above%d.%d"):format(i, k) } } end
            vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { virt_lines = rows, virt_lines_above = true })
        end
        if (s.below or 0) > 0 then
            local rows = {}
            for k = 1, s.below do rows[k] = { { ("below%d.%d"):format(i, k) } } end
            vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { virt_lines = rows, virt_lines_above = false })
        end
    end
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor", row = 2, col = 2, width = 24, height = win_height,
        style = "minimal", border = "none",
    })
    vim.api.nvim_set_option_value("scrolloff", 0, { win = win })
    return buf, win, function()
        pcall(vim.api.nvim_win_close, win, true)
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
end

-- Items + rows_of matching the spec, for pane.screen_lines.
local function model(spec)
    local items = {}
    for i = 1, #spec do items[i] = { commit = { hash = ("h%02d"):format(i) } } end
    return pane.screen_lines(items, function(it)
        local i = tonumber(it.commit.hash:sub(2))
        return { above = spec[i].above or 0, height = 1, below = spec[i].below or 0 }
    end)
end

-- Read the live scroll state + the cursor-anchored footer bottom row.
local function snapshot(win, sm, WH)
    return vim.api.nvim_win_call(win, function()
        local v = vim.fn.winsaveview()
        local wl = vim.fn.winline()
        local cur = vim.fn.line(".")
        return {
            w0 = vim.fn.line("w0"),
            topline = v.topline,
            topfill = v.topfill,
            bs = pane.footer_bs(sm, cur, wl, WH),
        }
    end)
end

describe("pane rebuild gate vs virtual-line sub-scroll (§6.2)", function()
    -- Line 8 carries THREE rows above (a tall split fan), so scrolling up reveals them one
    -- at a time while the topline stays at 8 (topfill 0→1→2→3).
    local SPEC = {}
    for i = 1, 25 do SPEC[i] = {} end
    SPEC[8] = { above = 3 }
    SPEC[12] = { below = 1 }

    it("winsaveview().topfill changes on a sub-scroll while line('w0') stays constant", function()
        local WH = 8
        local sm = model(SPEC)
        local buf, win, cleanup = render(SPEC, WH)
        vim.api.nvim_win_set_cursor(win, { 11, 0 })
        vim.api.nvim_win_call(win, function() vim.cmd("normal! zt") end)
        -- Scroll UP one screen row at a time; collect states whose topline is 8.
        local at8 = {}
        for _ = 1, 8 do
            local s = snapshot(win, sm, WH)
            if s.topline == 8 then at8[#at8 + 1] = s end
            vim.api.nvim_win_call(win, function() vim.cmd("normal! \025") end) -- Ctrl-Y
        end
        cleanup()
        -- We reached line 8 as the topline in several distinct sub-scroll states.
        assert.is_true(#at8 >= 2, "did not reach >=2 sub-scroll states with topline 8")
        -- Every one has the SAME line('w0'), but topfill differs across them.
        local w0s, topfills, bses = {}, {}, {}
        for _, s in ipairs(at8) do
            w0s[s.w0] = true; topfills[s.topfill] = true; bses[s.bs] = true
        end
        assert.equals(1, vim.tbl_count(w0s), "line('w0') should be constant across the sub-scroll")
        assert.is_true(vim.tbl_count(topfills) >= 2, "topfill should differ across the sub-scroll")
        -- ...and the CURSOR-ANCHORED footer bottom changes across them — so a gate on
        -- line('w0') alone leaves the footer stale, but a (topline, topfill) gate rebuilds.
        assert.is_true(vim.tbl_count(bses) >= 2,
            "footer bottom (bs) should change across the sub-scroll — the stale-footer bug")
    end)

    it("the (topline, topfill) gate key distinguishes states that line('w0') cannot", function()
        local WH = 8
        local sm = model(SPEC)
        local buf, win, cleanup = render(SPEC, WH)
        vim.api.nvim_win_set_cursor(win, { 11, 0 })
        vim.api.nvim_win_call(win, function() vim.cmd("normal! zt") end)
        local prev, w0_missed, key_caught = nil, 0, 0
        for _ = 1, 12 do
            local s = snapshot(win, sm, WH)
            if prev then
                local bs_changed = s.bs ~= prev.bs
                local w0_changed = s.w0 ~= prev.w0
                local key_changed = (s.topline ~= prev.topline) or (s.topfill ~= prev.topfill)
                if bs_changed and not w0_changed then w0_missed = w0_missed + 1 end -- gate would MISS a rebuild
                if bs_changed and key_changed then key_caught = key_caught + 1 end  -- (topline,topfill) catches it
                -- The footer never changes without the (topline, topfill) key changing.
                assert.is_true((not bs_changed) or key_changed,
                    "footer bottom changed but (topline, topfill) did not — gate key insufficient")
            end
            prev = s
            vim.api.nvim_win_call(win, function() vim.cmd("normal! \025") end)
        end
        cleanup()
        assert.is_true(w0_missed > 0,
            "never hit a footer change that line('w0') alone would miss — bug not reproduced")
        assert.is_true(key_caught >= w0_missed, "(topline, topfill) must catch every footer change")
    end)
end)

-- The alt-tab / BufWritePost auto-scroll (§3.3). `refresh_worktree` re-renders the buffer
-- (reflow -> set_items). Re-rendering RESETS the virtual-line sub-scroll (`topfill` -> 0),
-- snapping the view to a clean line boundary — the ~1-line jump on every focus. The fix is
-- to `winsaveview()` before and `winrestview()` after (like `resync`), which DOES restore
-- `topfill`. This guards that mechanism.
describe("re-rendering resets topfill; save/restore preserves it (§3.3)", function()
    local SPEC = {}
    for i = 1, 25 do SPEC[i] = {} end
    SPEC[8] = { above = 3 }

    local function topfill_of(win) return vim.api.nvim_win_call(win, function() return vim.fn.winsaveview().topfill end) end
    local function setup()
        local buf, win, cleanup = render(SPEC, 8)
        vim.api.nvim_win_set_cursor(win, { 11, 0 })
        vim.api.nvim_win_call(win, function() vim.cmd("normal! zt") end)
        -- Scroll UP one screen row at a time until a virtual (split) row shows at the top
        -- (topfill > 0) — the sub-scrolled state a bare re-render would snap away.
        for _ = 1, 10 do
            if topfill_of(win) > 0 then break end
            vim.api.nvim_win_call(win, function() vim.cmd("normal! \025") end)
        end
        return buf, win, cleanup
    end
    local function rerender(buf)
        local lines = {}
        for i = 1, #SPEC do lines[i] = ("L%02d"):format(i) end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        local ns = vim.api.nvim_create_namespace("pane_scroll_gate")
        vim.api.nvim_buf_set_extmark(buf, ns, 8 - 1, 0,
            { virt_lines = { { { "above8.1" } }, { { "above8.2" } }, { { "above8.3" } } }, virt_lines_above = true })
    end
    it("a bare re-render loses the sub-scroll (reproduces the auto-scroll)", function()
        local buf, win, cleanup = setup()
        assert.is_true(topfill_of(win) > 0, "expected a sub-scrolled (topfill>0) starting state")
        rerender(buf)
        assert.equals(0, topfill_of(win)) -- the ~1-line jump: sub-scroll reset
        cleanup()
    end)

    it("winsaveview/winrestview around the re-render preserves the sub-scroll (the fix)", function()
        local buf, win, cleanup = setup()
        local before = topfill_of(win)
        assert.is_true(before > 0)
        local saved = vim.api.nvim_win_call(win, function() return vim.fn.winsaveview() end)
        rerender(buf)
        vim.api.nvim_win_call(win, function() vim.fn.winrestview(saved) end)
        assert.equals(before, topfill_of(win)) -- view held; no auto-scroll
        cleanup()
    end)
end)
