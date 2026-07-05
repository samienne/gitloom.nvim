-- FAITHFUL screen-coordinate tests against a REAL nvim window with virtual lines.
--
-- Every footer bug came from mis-modelling how nvim renders the split/merge virtual lines
-- and from reasoning in real buffer-line numbers (`line('w0')`/`line('w$')`) that can't
-- address a virtual row. This spec renders a buffer with `virt_lines` EXACTLY as gitloom
-- does (split → `virt_lines_above=true`; merge → `virt_lines_above=false`) and checks two
-- things against nvim's ACTUAL rendering across many scroll positions:
--
--   1. Model fidelity: `pane.screen_lines` reproduces nvim's layout (each VISIBLE real
--      line's `screenpos` delta from the cursor equals the model's `cols` delta).
--   2. The CURSOR-ANCHORED window bottom `pane.footer_bs(sm, cursor_disp, winline(), WH)`
--      = `cols[cursor] + (WH - winline())` names the SAME `(line, virt)` nvim actually
--      renders at the window's bottom screen row — cross-checked independently via
--      `line('w$')` + `screenpos` (a DIFFERENT anchor), and INCLUDING when the bottom is a
--      virtual SPLIT line whose columns line is scrolled off below the window.
--
-- Key nvim facts (verified by probe): `winline()`/`win_height` are window-relative (border
-- robust; `win_screenpos` is the frame top and drifts). `line('w$')` is the last real line
-- whose COLUMNS is visible — a split at the bottom belongs to `w$+1`, a merge to `w$`.
local pane = require("gitloom.graph.pane")

local function items_of(spec)
    local out = {}
    for i, s in ipairs(spec) do
        out[i] = { commit = { hash = ("h%02d"):format(i) }, split = s.split or nil, merge = s.merge or nil }
    end
    return out
end

-- Render `spec` (spec[i] = {split=bool, merge=bool}) into a REAL window with virt_lines
-- attached exactly like gitloom (split above, merge below). scrolloff=0 so the cursor can
-- reach the true top/bottom. Returns buf, win, cleanup.
local function render(spec, win_height, border)
    local buf = vim.api.nvim_create_buf(false, true)
    local lines = {}
    for i = 1, #spec do lines[i] = ("L%02d"):format(i) end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local ns = vim.api.nvim_create_namespace("screen_window_test")
    for i, s in ipairs(spec) do
        if s.split then
            vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0,
                { virt_lines = { { { "split" .. i, "Comment" } } }, virt_lines_above = true })
        end
        if s.merge then
            vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0,
                { virt_lines = { { { "merge" .. i, "Comment" } } }, virt_lines_above = false })
        end
    end
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor", row = 3, col = 4, width = 30, height = win_height,
        style = "minimal", border = border or "none",
    })
    vim.api.nvim_set_option_value("scrolloff", 0, { win = win })
    return buf, win, function()
        pcall(vim.api.nvim_win_close, win, true)
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
end

-- nvim's ACTUAL (line, virt) at the window bottom screen row `bottom_abs`, derived from
-- `line('w$')` (the last visible-columns real line), its screenpos, and the known virt
-- structure. This is INDEPENDENT of the cursor-anchored model computation.
local function nvim_bottom(win, spec, bottom_abs)
    local V = vim.fn.line("w$")
    local vr = vim.fn.screenpos(win, V, 1).row -- V's columns screen row
    if vr == 0 then return nil end
    if bottom_abs == vr then return V, 0 end
    local r = vr
    if spec[V] and spec[V].merge then
        r = r + 1
        if bottom_abs == r then return V, 1 end
    end
    if spec[V + 1] and spec[V + 1].split then
        r = r + 1
        if bottom_abs == r then return V + 1, -1 end
    end
    return nil -- bottom is somewhere the simple model doesn't expect
end

local SPEC = {
    {}, {}, { split = true }, { merge = true }, {},
    { split = true }, {}, { merge = true }, { split = true }, {},
    {}, { split = true }, {}, { merge = true }, { split = true },
    {}, { split = true }, {}, {}, { merge = true },
    { split = true }, {}, { split = true }, {}, {},
}

describe("screen coordinates vs real nvim rendering (§6.2)", function()
    it("pane.screen_lines reproduces nvim's virtual-line layout (delta check)", function()
        local sm = pane.screen_lines(items_of(SPEC))
        local buf, win, cleanup = render(SPEC, 12, "rounded")
        local bad = {}
        for cursor = 1, #SPEC do
            for _, z in ipairs({ "zt", "zz", "zb" }) do
                vim.api.nvim_win_set_cursor(win, { cursor, 0 })
                vim.api.nvim_win_call(win, function() vim.cmd("normal! " .. z) end)
                vim.api.nvim_win_call(win, function()
                    local cur_abs = vim.fn.screenpos(win, cursor, 1).row
                    for L = 1, #SPEC do
                        local r = vim.fn.screenpos(win, L, 1).row
                        if r > 0 then -- only lines whose COLUMNS is actually on screen
                            local sd, md = r - cur_abs, sm.cols[L] - sm.cols[cursor]
                            if sd ~= md then
                                bad[#bad + 1] = ("cursor=%d %s L=%d screenpos_delta=%d model_delta=%d")
                                    :format(cursor, z, L, sd, md)
                            end
                        end
                    end
                end)
            end
        end
        cleanup()
        assert.equals(0, #bad,
            ("%d model mismatches:\n  "):format(#bad) .. table.concat(bad, "\n  ", 1, math.min(#bad, 15)))
    end)

    it("cursor-anchored footer_bs matches nvim's actual window bottom (line, virt)", function()
        local sm = pane.screen_lines(items_of(SPEC))
        local total = #sm.lines
        local bad, split_bottoms, merge_bottoms, checked = {}, 0, 0, 0
        for _, WH in ipairs({ 6, 8, 11, 14 }) do
            for _, border in ipairs({ "none", "rounded" }) do
                local buf, win, cleanup = render(SPEC, WH, border)
                for cursor = 1, #SPEC do
                    for _, z in ipairs({ "zt", "zz", "zb" }) do
                        vim.api.nvim_win_set_cursor(win, { cursor, 0 })
                        vim.api.nvim_win_call(win, function() vim.cmd("normal! " .. z) end)
                        vim.api.nvim_win_call(win, function()
                            local wl = vim.fn.winline()
                            local cur_abs = vim.fn.screenpos(win, cursor, 1).row
                            local bottom_abs = cur_abs + (WH - wl)
                            -- nvim's independent truth (w$-anchored):
                            local nl, nv = nvim_bottom(win, SPEC, bottom_abs)
                            if not nl then return end -- edge the simple oracle skips
                            checked = checked + 1
                            if nv == -1 then split_bottoms = split_bottoms + 1 end
                            if nv == 1 then merge_bottoms = merge_bottoms + 1 end
                            -- our cursor-anchored model computation:
                            local bs = pane.footer_bs(sm, cursor, wl, WH)
                            local pos = (bs >= 1 and bs <= total) and sm.lines[bs] or nil
                            local mv = pos and pos.virt
                            if not pos or pos.idx ~= nl or mv ~= nv then
                                bad[#bad + 1] = ("WH=%d %s cursor=%d %s: model bs=%d -> (L%s,%s) but nvim bottom=(L%d,virt%d)")
                                    :format(WH, border, cursor, z, bs,
                                        pos and tostring(pos.idx) or "?", pos and pos.kind or "?", nl, nv)
                            end
                        end)
                    end
                end
                cleanup()
            end
        end
        assert.equals(0, #bad,
            ("%d/%d bottom mismatches:\n  "):format(#bad, checked)
            .. table.concat(bad, "\n  ", 1, math.min(#bad, 20)))
        assert.is_true(split_bottoms > 0, "never exercised a window bottom on a virtual SPLIT line")
        assert.is_true(merge_bottoms > 0, "never exercised a window bottom on a virtual MERGE line")
    end)

    -- CATCH THE BUG: production (`footer_bottom_screen`) anchors on `w0` and computes the
    -- window bottom as `win_screenpos[1] + height - 1`. But `win_screenpos` returns the
    -- FRAME top (drifts by the border), so that bottom is wrong with a bordered window —
    -- and the seam lands on the wrong (line, virt). This asserts the production formula is
    -- WRONG in some cases while the cursor-anchored one (above) is always right.
    it("the production w0 + win_screenpos formula is wrong where the cursor-anchored one is right", function()
        local sm = pane.screen_lines(items_of(SPEC))
        local total = #sm.lines
        local cursor_wrong, prod_wrong, compared = 0, 0, 0
        for _, WH in ipairs({ 6, 8, 11, 14 }) do
            local buf, win, cleanup = render(SPEC, WH, "rounded") -- bordered host, like the graph
            for cursor = 1, #SPEC do
                for _, z in ipairs({ "zt", "zz", "zb" }) do
                    vim.api.nvim_win_set_cursor(win, { cursor, 0 })
                    vim.api.nvim_win_call(win, function() vim.cmd("normal! " .. z) end)
                    vim.api.nvim_win_call(win, function()
                        local wl = vim.fn.winline()
                        local cur_abs = vim.fn.screenpos(win, cursor, 1).row
                        local bottom_abs = cur_abs + (WH - wl)
                        local nl, nv = nvim_bottom(win, SPEC, bottom_abs)
                        if not nl then return end
                        compared = compared + 1
                        local function pos_virt(bs)
                            local p = (bs >= 1 and bs <= total) and sm.lines[bs] or nil
                            if not p then return nil end
                            return p.idx, p.virt
                        end
                        -- cursor-anchored (the fix): winline + WH, both window-relative.
                        local ci, cv = pos_virt(pane.footer_bs(sm, cursor, wl, WH))
                        if ci ~= nl or cv ~= nv then cursor_wrong = cursor_wrong + 1 end
                        -- production (the bug): w0 + screenpos(w0) + win_screenpos-based bottom.
                        local w0 = vim.fn.line("w0")
                        local w0_real = vim.fn.screenpos(win, w0, 1).row
                        local wp = vim.fn.win_screenpos(win)
                        local win_bottom_real = wp[1] + WH - 1
                        local pi, pv = pos_virt(pane.footer_bs(sm, w0, w0_real, win_bottom_real))
                        if pi ~= nl or pv ~= nv then prod_wrong = prod_wrong + 1 end
                    end)
                end
            end
            cleanup()
        end
        -- The cursor-anchored formula is ALWAYS right; the production formula is wrong
        -- often (the bug we've been chasing). This is what the fix must change.
        assert.equals(0, cursor_wrong,
            ("cursor-anchored footer_bs was wrong %d/%d times"):format(cursor_wrong, compared))
        assert.is_true(prod_wrong > 0,
            "the production w0/win_screenpos formula was never wrong — the bug was not reproduced")
    end)
end)
