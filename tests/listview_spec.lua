--- Tests for the listview's multi-real-line bookkeeping (spec §6.1 dual mode):
--- the buffer-line <-> item offset map (`rebuild_starts` / `item_index_at`) and a
--- windowed smoke test that an item can render several real buffer lines.
local lv = require("gitloom.listview")._internal

--- A model whose item i occupies `counts[i]` real buffer lines.
local function model_with(counts)
    local items = {}
    for _, c in ipairs(counts) do
        items[#items + 1] = { data = { n = c } }
    end
    local model = { items = items, starts = {}, total = 0, line_count = function(d) return d.n end }
    lv.rebuild_starts(model, 1)
    return model
end

describe("offset map (rebuild_starts / item_index_at)", function()
    it("computes block starts and total for mixed line counts", function()
        local m = model_with({ 1, 2, 1, 3 }) -- blocks: 1 | 2-3 | 4 | 5-7
        assert.same({ 1, 2, 4, 5 }, m.starts)
        assert.equals(7, m.total)
    end)

    it("maps every buffer line back to its item", function()
        local m = model_with({ 1, 2, 1, 3 })
        local expect = { 1, 2, 2, 3, 4, 4, 4 } -- buffer line -> item index
        for bl, item in ipairs(expect) do
            assert.equals(item, lv.item_index_at(m, bl), "buffer line " .. bl)
        end
    end)

    it("clamps out-of-range buffer lines to the end items", function()
        local m = model_with({ 1, 2, 1, 3 })
        assert.equals(1, lv.item_index_at(m, 0))
        assert.equals(1, lv.item_index_at(m, -5))
        assert.equals(4, lv.item_index_at(m, 8))
        assert.equals(4, lv.item_index_at(m, 999))
    end)

    it("rebuilds incrementally from a position (the append fast path)", function()
        local m = model_with({ 1, 1, 1 }) -- starts {1,2,3}, total 3
        table.insert(m.items, { data = { n = 2 } })
        lv.rebuild_starts(m, 4)
        assert.equals(4, m.starts[4])
        assert.equals(5, m.total)
        assert.equals(4, lv.item_index_at(m, 4))
        assert.equals(4, lv.item_index_at(m, 5))
    end)

    it("handles a single multi-line item", function()
        local m = model_with({ 3 })
        assert.same({ 1 }, m.starts)
        assert.equals(3, m.total)
        assert.equals(1, lv.item_index_at(m, 1))
        assert.equals(1, lv.item_index_at(m, 3))
    end)
end)

describe("multi-line rendering (windowed)", function()
    -- Stub snacks.win with a real window/buffer so listview.open works headless,
    -- then re-require listview so its lazy `require("snacks.win")` picks up the stub.
    local listview, ctrl, buf
    local mode_two = false -- when true, item.two commits render as two rows

    before_each(function()
        package.loaded["snacks.win"] = {
            new = function(o)
                local b = vim.api.nvim_create_buf(false, true)
                local w = vim.api.nvim_open_win(b, false,
                    { relative = "editor", width = 80, height = 20, row = 1, col = 1 })
                return { win = w, buf = b, opts = o or {} }
            end,
        }
        package.loaded["gitloom.listview"] = nil
        listview = require("gitloom.listview")
    end)

    after_each(function()
        package.loaded["gitloom.listview"] = nil
        package.loaded["snacks.win"] = nil
    end)

    it("allocates and renders the right number of real buffer lines", function()
        local inst = listview.open({
            win = {},
            flex = 4,
            message_min = 10,
            line_count = function(d) return (mode_two and d.two) and 2 or 1 end,
            display = function(d)
                if mode_two and d.two then
                    return { lines = {
                        { "", "", "", "L" .. d.id },
                        { "", "", "", "M" .. d.id },
                    } }
                end
                return { line = { "", "", "", "S" .. d.id } }
            end,
            on_controller = function(c) ctrl = c end,
        })
        buf = inst.win.buf

        -- Three items, the middle one flagged `two` (but mode is single-line now).
        ctrl.insert({ { id = 1 }, { id = 2, two = true }, { id = 3 } }, 1)
        assert.equals(3, vim.api.nvim_buf_line_count(buf)) -- all single-line
        assert.equals(2, ctrl.item_at(2))

        -- Switch to two-line mode and relayout: the middle item becomes two rows.
        mode_two = true
        ctrl.relayout()
        assert.equals(4, vim.api.nvim_buf_line_count(buf)) -- 1 + 2 + 1
        -- Buffer line 2 and 3 both belong to item 2; line 4 is item 3.
        assert.equals(2, ctrl.item_at(2))
        assert.equals(2, ctrl.item_at(3))
        assert.equals(3, ctrl.item_at(4))
        assert.equals(2, ctrl.item_start(2)) -- item 2 starts at buffer line 2
    end)

    it("set_items swaps the whole list and re-lays the buffer (reflow, §10.5)", function()
        local inst = listview.open({
            win = {},
            flex = 4,
            line_count = function() return 1 end,
            display = function(d) return { line = { "", "", "", "X" .. d.id } } end,
            on_controller = function(c) ctrl = c end,
        })
        buf = inst.win.buf

        ctrl.insert({ { id = 1 }, { id = 2 }, { id = 3 }, { id = 4 } }, 1)
        assert.equals(4, vim.api.nvim_buf_line_count(buf))

        -- Reflow to a shorter projection (a region contracted to one head).
        ctrl.set_items({ { id = 1 }, { id = 9 } })
        assert.equals(2, vim.api.nvim_buf_line_count(buf))
        assert.equals(1, ctrl.item_at(1))
        assert.equals(2, ctrl.item_at(2))
        assert.equals(2, ctrl.item_start(2))
    end)
end)
