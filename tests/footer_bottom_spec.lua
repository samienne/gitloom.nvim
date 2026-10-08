-- The footer must HIDE when nothing is below the window (spec §6.2: "the footer [vanishes]
-- when scrolled to the bottom (the roots are then already on-screen)"), the mirror of the
-- header's `w0disp <= 1` rule. Rendered in a REAL nvim window with virt_lines, like
-- screen_window_spec. The production pipeline is `footer_bs` → `footer_seam`; a non-nil
-- seam means window.lua builds and shows a footer overlay.
local pane = require("gitloom.graph.pane")

local function items_of(spec)
    local out = {}
    for i, s in ipairs(spec) do
        out[i] = { commit = { hash = ("h%02d"):format(i) },
            above = s.split and { {} } or nil, merge = s.merge or nil }
    end
    return out
end

local function render(spec, win_height)
    local buf = vim.api.nvim_create_buf(false, true)
    local lines = {}
    for i = 1, #spec do lines[i] = ("L%02d"):format(i) end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local ns = vim.api.nvim_create_namespace("footer_bottom_test")
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
        relative = "editor", row = 1, col = 1, width = 30, height = win_height, style = "minimal",
    })
    vim.api.nvim_set_option_value("scrolloff", 0, { win = win })
    return win, function()
        pcall(vim.api.nvim_win_close, win, true)
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
end

-- Exactly window.lua's footer_bottom_screen() + build_footer()'s seam step.
local function production_seam(win, sm, cover)
    local r = vim.api.nvim_win_call(win, function()
        local cur = vim.fn.line(".")
        return { pane.footer_bottom(sm, cur, vim.fn.winline(), vim.api.nvim_win_get_height(win)) }
    end)
    local bs, why = r[1], r[2]
    if not bs then return nil, -1, why end
    return pane.footer_seam(sm, bs, cover), bs, why
end

local SPEC = {
    {}, { merge = true }, {}, { split = true }, {}, {}, { merge = true }, {},
    { split = true }, {}, {}, {}, { merge = true }, {}, {}, {},
}

describe("footer at the bottom of the graph (§6.2)", function()
    it("is hidden when the whole graph fits in the window (filler below)", function()
        local win, done = render(SPEC, 40) -- 16 items + 5 virt rows = 21 screen rows < 40
        local sm = pane.screen_lines(items_of(SPEC))
        vim.api.nvim_win_set_cursor(win, { 1, 0 })
        local last_visible = vim.fn.screenpos(win, #SPEC, 1).row > 0
        assert.is_true(last_visible)
        for cover = 1, 6 do
            local seam, bs, why = production_seam(win, sm, cover)
            assert.is_nil(seam, ("cover=%d: footer seam built at item %s (bs=%d of %d rows) "
                .. "although nothing is below the window"):format(cover,
                tostring(seam and seam.idx), bs, #sm.lines))
            assert.equals("at bottom", why)
        end
        done()
    end)

    it("is hidden after G (last row at the window bottom)", function()
        local win, done = render(SPEC, 10)
        local sm = pane.screen_lines(items_of(SPEC))
        vim.api.nvim_win_call(win, function() vim.cmd("normal! G") end)
        for cover = 1, 4 do
            local seam, bs, why = production_seam(win, sm, cover)
            assert.is_nil(seam, ("cover=%d: footer seam built at item %s (bs=%d of %d rows) "
                .. "although the last row is on screen"):format(cover,
                tostring(seam and seam.idx), bs, #sm.lines))
            assert.equals("at bottom", why)
        end
        done()
    end)

    it("is still shown one row before the bottom", function()
        local win, done = render(SPEC, 10)
        local sm = pane.screen_lines(items_of(SPEC))
        vim.api.nvim_win_call(win, function()
            vim.cmd("normal! G")
            vim.cmd([[exe "normal! \<C-y>"]]) -- scroll the view up one line
        end)
        assert.is_true(vim.api.nvim_win_call(win, function() return vim.fn.line("w$") end) < #SPEC)
        local s, bs = production_seam(win, sm, 1)
        local seam = assert(s)
        assert.equals(#sm.lines - 1, bs) -- the true bottom: one row above the last
        assert.equals(bs - seam.cover, seam.seam_bottom)
        assert.is_true(seam.cover >= 1)
        done()
    end)
end)

describe("pane.footer_bottom (§6.2)", function()
    local sm = pane.screen_lines(items_of({ {}, { merge = true }, {}, {} })) -- 5 rows
    it("declines exactly when the raw window bottom reaches the last row", function()
        -- anchor item 1 (row 1) at window row 1: bottom = window height
        assert.equals(4, (pane.footer_bottom(sm, 1, 1, 4)))
        local bs, why = pane.footer_bottom(sm, 1, 1, 5)
        assert.is_nil(bs); assert.equals("at bottom", why)
        bs, why = pane.footer_bottom(sm, 1, 1, 30) -- filler rows below the graph
        assert.is_nil(bs); assert.equals("at bottom", why)
    end)
    it("agrees with footer_bs whenever it does not decline", function()
        for anchor = 1, 4 do
            for wl = 1, 3 do
                for wh = 1, 8 do
                    local bs = pane.footer_bottom(sm, anchor, wl, wh)
                    if bs then assert.equals(pane.footer_bs(sm, anchor, wl, wh), bs) end
                end
            end
        end
    end)
end)
