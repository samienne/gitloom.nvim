---@diagnostic disable: missing-fields
--- The row's fixed-width columns (specification.md §6, §8 `author_width` /
--- `graph_min_width`, §5.4): the date, author and graph widths come from one
--- rule each and are never measured from the rows on screen, so nothing moves
--- while scrolling.
---   * date   — a function of the date mode (and `date_format`) alone;
---   * author — exactly `author_width` cells, a longer name cut with `…`;
---   * graph  — the widest graph of the whole current view, floored by
---              `graph_min_width`; recomputed (may shrink) on a relayout, only
---              widened by a streamed batch.

local date = require("gitloom.git.date")
local render = require("gitloom.graph.render")
local columns = require("gitloom.graph.columns")
local h = require("tests.graph_helpers")

describe("date column width (§6)", function()
    it("absolute: the widest output of date_format over the probe dates", function()
        assert.equals(16, date.absolute_width("%Y-%m-%d %H:%M"))
        assert.equals(16, date.absolute_width(nil)) -- the default format
        assert.equals(10, date.absolute_width("%Y-%m-%d"))
    end)

    it("absolute: a format with month / weekday names gets the longest name", function()
        local function widest(fmt, list)
            local w = 0
            for _, t in ipairs(list) do
                w = math.max(w, vim.fn.strdisplaywidth(os.date("!" .. fmt, t) --[[@as string]]))
            end
            return w
        end
        -- One mid-month day per month (2001), and the seven days of one week.
        local months, days = {}, {}
        for m = 0, 11 do months[#months + 1] = 978307200 + (m * 30 + 15) * 86400 end
        for d = 0, 6 do days[#days + 1] = 978307200 + d * 86400 end
        assert.equals(widest("%B", months), date.absolute_width("%B"))
        assert.equals(widest("%A", days), date.absolute_width("%A"))
        -- "%d %B %Y": a two-digit day + the longest month name + the year.
        assert.equals(3 + widest("%B", months) + 5, date.absolute_width("%d %B %Y"))
        -- Two-digit hours (and the PM/AM marker) are covered.
        assert.equals(2, date.absolute_width("%H"))
        assert.equals(2, date.absolute_width("%I"))
    end)

    it("relative: the longest phrase of the vocabulary, 14 cells", function()
        assert.equals(14, date.relative_width())
        -- No relative age is ever wider (a sweep across every unit boundary).
        local ts = { epoch = 0, offset = 0 }
        for _, secs in ipairs({ 0, 1, 59, 60, 3599, 3600, 86399, 86400, 604799, 604800,
            2591999, 2592000, 31535999, 31536000, 99 * 31536000, 9999 * 31536000 }) do
            assert.is_true(#date.format_relative(ts, secs) <= 14, tostring(secs))
        end
        assert.equals(14, #date.format_relative(ts, 59))
    end)

    it("date_width follows the mode alone", function()
        assert.equals(16, date.date_width({ date_mode = "absolute" }))
        assert.equals(14, date.date_width({ date_mode = "relative" }))
        assert.equals(10, date.date_width({ date_mode = "absolute", date_format = "%Y-%m-%d" }))
    end)
end)

describe("author column (§6, §8 author_width)", function()
    it("validates author_width: a non-positive-integer value falls back to 18", function()
        assert.equals(18, render.author_width({}))
        assert.equals(7, render.author_width({ author_width = 7 }))
        assert.equals(1, render.author_width({ author_width = 1 }))
        for _, bad in ipairs({ 0, -3, 2.5, "12", true }) do
            assert.equals(18, render.author_width({ author_width = bad }), tostring(bad))
        end
    end)

    it("validates graph_min_width: a non-negative integer, else 0", function()
        assert.equals(0, render.graph_min_width({}))
        assert.equals(0, render.graph_min_width({ graph_min_width = 0 }))
        assert.equals(12, render.graph_min_width({ graph_min_width = 12 }))
        for _, bad in ipairs({ -1, 1.5, "4" }) do
            assert.equals(0, render.graph_min_width({ graph_min_width = bad }), tostring(bad))
        end
    end)

    local function author_cell(author, width)
        local o = h.opts()
        o.highlight, o.author_width = false, width
        local item = { type = "commit", commit = { hash = "h", message = "m", author = author,
            date = 0, parents = {}, children = {}, refs = {} },
            columns = { { connectivity = {}, lanes = {}, has_commit = false } } }
        return render.display_item(o, item, {}, nil).line[2].text
    end

    it("truncates a longer name to author_width cells with …, keeping the gap", function()
        assert.equals("Bartholomew Jo… ", author_cell("Bartholomew Johnson-Smith", 15))
        assert.equals(16, vim.fn.strdisplaywidth(author_cell("Bartholomew Johnson-Smith", 15)))
        -- The default 18; a multi-byte name is cut by cells, not bytes.
        assert.equals(19, vim.fn.strdisplaywidth(author_cell(("Ö"):rep(30), nil)))
        -- A name that fits (exactly, or shorter) is left for the listview to pad.
        assert.equals("Ann ", author_cell("Ann", 15))
        assert.equals(("x"):rep(15) .. " ", author_cell(("x"):rep(15), 15))
    end)
end)

describe("graph column width (§6)", function()
    -- A DAG whose widest region is in the middle: three concurrent branches.
    local WIDE = {
        { "a", { "b" } }, { "b", { "c", "x" } }, { "x", { "y", "z" } }, { "y", { "c" } },
        { "z", { "c" } }, { "c", { "d" } }, { "d", {} },
    }
    local LINEAR = { { "a", { "c" } }, { "c", { "d" } }, { "d", {} } }

    it("is two cells per lane column — the rendered width — in both mirror modes", function()
        for _, mirror in ipairs({ false, true }) do
            local o = h.opts()
            o.mirror = mirror
            local rows = columns.layout(o, h.dag(WIDE))
            local widest = 0
            for _, r in ipairs(rows) do
                local lines = { r.columns }
                for _, l in ipairs(r.above or {}) do lines[#lines + 1] = l end
                if r.merge then lines[#lines + 1] = r.merge end
                for _, l in ipairs(lines) do
                    widest = math.max(widest, vim.fn.strdisplaywidth(render.get_column_chars(o, l).text))
                end
            end
            assert.is_true(widest > 2)
            assert.equals(widest, render.graph_width(rows))
        end
    end)

    it("is the max over the whole view, not the visible slice", function()
        local rows = columns.layout(h.opts(), h.dag(WIDE))
        local full = render.graph_width(rows)
        -- The first row alone (the "screen" at the top) is narrower, but the
        -- whole-view width covers it.
        assert.is_true(render.graph_width(rows, 1, 1) < full)
        assert.equals(full, render.graph_width(rows, 1, #rows))
        -- above / merge lines count.
        assert.equals(6, render.graph_width({ { columns = { {} }, merge = { {}, {}, {} } } }))
        assert.equals(8, render.graph_width({ { columns = { {} }, above = { { {}, {}, {}, {} } } } }))
    end)

    -- reflow_apply sets the whole-view width — it may shrink — except for a
    -- streamed batch's reflow (graph_widen), which may only widen it.
    describe("reflow_apply", function()
        local wi = require("gitloom.window")._internal
        local function stub(graph_w)
            local ctx = { repo = {}, sel = {}, graph_w = graph_w }
            function ctx:build_display_index() end
            function ctx:update_cone() end
            function ctx:update_panes() end
            return ctx
        end

        it("recomputes the width from the new view and may shrink it (a collapse)", function()
            local wide = columns.layout(h.opts(), h.dag(WIDE))
            local ctx = stub(nil)
            wi.reflow_apply(ctx, wide)
            assert.equals(render.graph_width(wide), ctx.graph_w)
            -- A narrower view, as a collapse folding the side branches away leaves.
            local narrow = columns.layout(h.opts(), h.dag(LINEAR))
            assert.is_true(render.graph_width(narrow) < ctx.graph_w)
            wi.reflow_apply(ctx, narrow)
            assert.equals(render.graph_width(narrow), ctx.graph_w)
        end)

        it("only widens it for a streamed batch's reflow", function()
            local narrow = columns.layout(h.opts(), h.dag(LINEAR))
            local ctx = stub(40)
            ctx.graph_widen = true
            wi.reflow_apply(ctx, narrow)
            assert.equals(40, ctx.graph_w)
            ctx.graph_w = 0
            wi.reflow_apply(ctx, narrow)
            assert.equals(render.graph_width(narrow), ctx.graph_w)
        end)
    end)
end)

-- End to end on this repository (needs snacks in the test deps dir): the
-- listview's fixed widths put the message edge — and under mirroring lane 1, at
-- the graph's right edge — at one screen column on every row, wherever the
-- window is scrolled to.
describe("fixed columns in the real graph (§6, §5.4)", function()
    local window, ctx, win, snacks_ready

    before_each(function()
        vim.opt.rtp:prepend(vim.g.gitloom_test_deps .. "/snacks.nvim")
        vim.o.lines, vim.o.columns = 30, 160
        if not snacks_ready then require("snacks").setup({}); snacks_ready = true end
        window = require("gitloom.window")
        ---@diagnostic disable-next-line: missing-fields
        local lv = window.open(nil, { panes = false, persist = false } --[[@as GraphOptions]])
        local gbuf = lv.buf
        local last_n, stable = -1, 0
        vim.wait(8000, function()
            local n = vim.api.nvim_buf_line_count(gbuf)
            if n == last_n and n > 1 then stable = stable + 1 else stable = 0 end
            last_n = n
            return stable >= 4
        end, 60)
        ctx = window._internal.ctx
        win = vim.fn.bufwinid(gbuf)
    end)

    after_each(function()
        if win and vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
    end)

    -- The message's display column on each visible line, after laying out the
    -- window scrolled so `top` is its first line (what the decoration provider
    -- does on a scroll: lay out + draw the visible range).
    local function message_cols(top)
        vim.api.nvim_win_call(win, function()
            vim.api.nvim_win_set_cursor(win, { top, 0 })
            vim.cmd("normal! zt")
        end)
        ctx.lv.controller.refresh()
        local first = vim.api.nvim_win_call(win, function() return vim.fn.line("w0") end)
        local h_ = vim.api.nvim_win_get_height(win)
        local buf = vim.api.nvim_win_get_buf(win)
        local out = {}
        for l = first, math.min(first + h_ - 1, vim.api.nvim_buf_line_count(buf)) do
            local text = vim.api.nvim_buf_get_lines(buf, l - 1, l, false)[1] or ""
            local b = ctx.lv.controller.col_offset(l, "line", 4)
            if b > 0 then out[#out + 1] = vim.fn.strdisplaywidth(text:sub(1, b)) end
        end
        return out
    end

    for _, mirror in ipairs({ true, false }) do
        it("keeps the message edge put across scroll positions (mirror=" .. tostring(mirror) .. ")", function()
            assert.is_true(win ~= -1, "graph not shown")
            if ctx.opts.mirror ~= mirror then
                vim.api.nvim_set_current_win(win)
                vim.api.nvim_feedkeys("M", "x", false)
            end
            assert.equals(mirror, ctx.opts.mirror)
            -- The graph width is the whole view's.
            assert.equals(render.graph_width(ctx.repo.display), ctx.graph_w)
            local n = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
            local edge
            for _, top in ipairs({ 1, math.floor(n / 2), math.max(1, n - 5) }) do
                for _, c in ipairs(message_cols(top)) do
                    edge = edge or c
                    assert.equals(edge, c, "message edge moved at top=" .. top)
                end
            end
            -- date (16 + gap) + author (18 + gap) + the whole-view graph width.
            assert.equals(17 + 19 + ctx.graph_w, edge)
        end)
    end
end)
