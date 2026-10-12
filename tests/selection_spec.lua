--- Tests for the ref-selection helpers (specification.md §2).
--- The row has `count` cursor positions: 1..count-1 are ref decorations and
--- `count` is the commit message (rightmost, default). move_selection clamps
--- (no wrap); decoration_texts is the shared decoration-string source;
--- cursor_column finds the byte column to park the cursor on.

local internal = require("gitloom.graph")._internal
local move_selection = internal.move_selection
local decoration_texts = internal.decoration_texts
local ref_byte_col = internal.ref_byte_col
local pack_right = require("gitloom.listview")._internal.pack_right
local window_right = require("gitloom.listview")._internal.window_right
local refresh_columns = require("gitloom.listview")._internal.refresh_columns

describe("move_selection", function()
    -- nil = message (default, leftmost); 1..count = decorations, left to right.
    it("from the message (nil): l selects the first ref, h stays", function()
        assert.equals(1, move_selection(nil, 3, 1))
        assert.is_nil(move_selection(nil, 3, -1))
    end)

    it("l steps right through the refs, clamping at the last", function()
        assert.equals(2, move_selection(1, 3, 1))
        assert.equals(3, move_selection(3, 3, 1)) -- clamp
    end)

    it("h steps left, returning to the message past the first", function()
        assert.equals(1, move_selection(2, 3, -1))
        assert.is_nil(move_selection(1, 3, -1)) -- back to the message
    end)

    it("is a no-op when there are no refs (count 0)", function()
        assert.is_nil(move_selection(nil, 0, 1))
        assert.is_nil(move_selection(nil, 0, -1))
    end)
end)

describe("decoration_texts", function()
    local function ref(kind, name) return { kind = kind, name = name } end

    it("renders a grouped branch then a tag, in selection order", function()
        local texts = decoration_texts({ refs = {
            ref("local", "mybranch"),
            ref("remote", "origin/mybranch"),
            ref("remote", "otherremote/mybranch"),
            ref("tag", "v1.0"),
        } })
        assert.same({ "(mybranch ↑origin,otherremote)", "[v1.0]" }, texts)
    end)

    it("ignores HEAD (a marker, not selectable)", function()
        local texts = decoration_texts({ refs = { ref("head", "HEAD"), ref("local", "main") } })
        assert.same({ "(main)" }, texts)
    end)

    it("is empty for a commit with no refs", function()
        assert.same({}, decoration_texts({ refs = {} }))
    end)
end)

describe("ref_byte_col", function()
    it("returns the 0-based byte column of a decoration's first occurrence", function()
        assert.equals(2, ref_byte_col("ab(main) fix bug", "(main)"))
    end)

    it("returns nil when the decoration is absent", function()
        assert.is_nil(ref_byte_col("xx hello world", "(nope)"))
    end)

    it("finds the nth occurrence, the last one past the end", function()
        local line = "(3) (dev) (3) (3)"
        assert.equals(0, ref_byte_col(line, "(3)", 1))
        assert.equals(10, ref_byte_col(line, "(3)", 2))
        assert.equals(14, ref_byte_col(line, "(3)", 3))
        assert.equals(14, ref_byte_col(line, "(3)", 9))
        assert.is_nil(ref_byte_col(line, "(x)", 2))
    end)
end)

describe("label_occurrence", function()
    local label_occurrence = internal.label_occurrence
    it("counts the same-text labels drawn before it", function()
        local t = { "(3)", "(dev)", "(3)", "(3)" }
        assert.equals(1, label_occurrence(t, 1))
        assert.equals(2, label_occurrence(t, 3))
        assert.equals(3, label_occurrence(t, 4))
        assert.equals(1, label_occurrence(t, 2))
    end)
end)

-- Mirroring does NOT flip the label order (§5.4): reading order carries the
-- labels' priority in every mode, mirrored or not. The pure display_item output,
-- without a window.
describe("display_item label order under mirroring", function()
    local PAL = { branch = "B", remote = "R", tags = "T", head = "H", selected = "S",
        date = "D", author = "A" }
    local function opts(mode, mirror)
        return { palette = PAL, label_mode = mode, highlight = false, mirror = mirror }
    end
    local function commit()
        return { hash = "h", message = "msg", author = "", parents = {}, refs = {
            { kind = "local", name = "alpha" }, { kind = "local", name = "beta" },
            { kind = "tag", name = "v1" }, { kind = "head", name = "HEAD", branch = "alpha" } } }
    end
    local function order(text)
        local a, b, t = text:find("(HEAD → alpha)", 1, true), text:find("(beta)", 1, true),
            text:find("[v1]", 1, true)
        assert.is_true(a ~= nil and b ~= nil and t ~= nil, text)
        return (a < b and b < t) and "logical" or "other"
    end
    local function flex(el) return (el.lines and el.lines[1] or el.line)[4].text end
    local function right(el)
        local parts = {}
        for _, it in ipairs(el.line_right) do parts[#parts + 1] = it.text end
        return table.concat(parts, " ")
    end

    for _, case in ipairs({
        { "inline", flex }, { "dual", flex }, { "right", right },
    }) do
        it(case[1] .. " mode keeps the logical order", function()
            local item = { type = "commit", commit = commit(), columns = {} }
            for _, mirror in ipairs({ false, true }) do
                assert.equals("logical", order(case[2](internal.display_item(opts(case[1], mirror), item, {}))))
            end
        end)
    end

    it("a selected label keeps its logical index", function()
        local c = commit()
        local item = { type = "commit", commit = c, columns = {} }
        local el = internal.display_item(opts("right", true), item, { commit = c, index = 2 })
        assert.equals("(beta)", el.line_right[el.line_right_sel].text)
    end)
end)

describe("pack_right", function()
    -- Items of given display widths packed into a budget; whole items only, in
    -- order, reserving room for a "+N" marker when some overflow.
    it("shows all items when they fit", function()
        local shown, overflow, used = pack_right({ 6, 8 }, 40)
        assert.equals(2, shown)
        assert.equals(0, overflow)
        assert.equals(6 + 1 + 8, used) -- one-cell gap between
    end)

    it("overflows the rest into a +N marker when the budget is tight", function()
        -- 6 fits; "+2" marker (width 2) plus a gap also fits within 10.
        local shown, overflow = pack_right({ 6, 8, 9 }, 10)
        assert.equals(1, shown)
        assert.equals(2, overflow)
    end)

    it("can show nothing but the marker when nothing fits", function()
        local shown, overflow = pack_right({ 30, 30 }, 3)
        assert.equals(0, shown)
        assert.equals(2, overflow)
    end)
end)

describe("window_right", function()
    -- A contiguous window around the selected item, fitting the budget, with
    -- separate left/right "+N" markers for the items hidden on each side (§6).

    it("shows every item with no markers when they all fit", function()
        local lo, hi, left, right = window_right({ 3, 3, 3 }, 20, 2)
        assert.same({ 1, 3, 0, 0 }, { lo, hi, left, right })
    end)

    it("windows around the selection with markers on both sides", function()
        -- five width-5 items, sel 3, budget 17: grows right first (hi→4); left
        -- can't fit, leaving +2 hidden on the left and +1 on the right.
        local lo, hi, left, right, used = window_right({ 5, 5, 5, 5, 5 }, 17, 3)
        assert.same({ 3, 4, 2, 1 }, { lo, hi, left, right })
        assert.equals(17, used)
    end)

    it("omits the left marker when the selection is the first item", function()
        local lo, hi, left, right, used = window_right({ 4, 4, 4, 4 }, 12, 1)
        assert.same({ 1, 2, 0, 2 }, { lo, hi, left, right })
        assert.equals(12, used)
    end)

    it("omits the right marker when the selection is the last item", function()
        local lo, hi, left, right, used = window_right({ 4, 4, 4, 4 }, 12, 4)
        assert.same({ 3, 4, 2, 0 }, { lo, hi, left, right })
        assert.equals(12, used)
    end)

    it("always shows the selected item even when it alone exceeds the budget", function()
        local lo, hi, left, right = window_right({ 30 }, 5, 1)
        assert.same({ 1, 1, 0, 0 }, { lo, hi, left, right })
    end)

    it("keeps the selection visible even when its markers overflow the budget", function()
        -- sel alone + both markers (3 + "+1" + "+1" + gaps = 9) exceeds 4, but the
        -- selected item is shown regardless.
        local lo, hi, left, right = window_right({ 3, 3, 3 }, 4, 2)
        assert.same({ 2, 2, 1, 1 }, { lo, hi, left, right })
    end)

    it("clamps an out-of-range selection into the item list", function()
        local lo, hi = window_right({ 3, 3 }, 100, 9)
        assert.same({ 1, 2 }, { lo, hi }) -- sel clamped to 2, everything fits
    end)

    it("returns an empty window for no items", function()
        local lo, hi, left, right, used = window_right({}, 10, 1)
        assert.same({ 1, 0, 0, 0, 0 }, { lo, hi, left, right, used })
    end)
end)

describe("refresh_columns", function()
    -- Regression: aligned column widths must be driven by `below` (merge) lines
    -- too, not just `above`/`line`/`text`. A `below` line wider than every other
    -- line previously left model.columns[j] = nil, which fix_width then compared
    -- against (listview.lua "attempt to compare number with nil"). `below` is now
    -- a list of rows (stacked virtual lines), so the row is wrapped once.
    it("sizes columns from below (merge) lines", function()
        local model = {
            flex = nil,
            columns = {},
            items = { { data = 1 }, { data = 2 } },
            display = function(data)
                if data == 1 then
                    return { line = { { text = "A" } } }
                end
                -- a merge line below (one row), wider than any commit line
                return {
                    line = { { text = "B" } },
                    below = { { { text = "X" }, { text = "Y" }, { text = "Z" } } },
                }
            end,
        }
        refresh_columns(nil, model, 1, 2)
        assert.equals(3, #model.columns)
        assert.is_not_nil(model.columns[3]) -- was nil before the fix
        assert.equals(1, model.columns[3])
    end)

    -- Stacked virtual rows: `above`/`below` may carry several rows (e.g. the
    -- dual-mode branch line on top of a split line), each driving the shared
    -- widths independently.
    it("sizes columns from every stacked above/below row", function()
        local model = {
            flex = nil,
            columns = {},
            items = { { data = 1 } },
            display = function()
                return {
                    line = { { text = "B" } },
                    above = {
                        { { text = "" }, { text = "" }, { text = "wide split" } },
                        { { text = "" }, { text = "" }, { text = "x" } },
                    },
                }
            end,
        }
        refresh_columns(nil, model, 1, 1)
        assert.equals(#"wide split", model.columns[3]) -- the wider row wins
    end)

    -- A `col_max` column is sticky: it grows up to its cap as wider values scroll
    -- in, but never shrinks — so it doesn't bounce (the author column, spec §6).
    it("caps a column and only grows it (sticky)", function()
        local model = {
            flex = nil,
            columns = {},
            col_max = { [1] = 5 },
            items = { { data = "abc" }, { data = "abcdefghij" }, { data = "ab" } },
            display = function(d) return { line = { { text = d } } } end,
        }
        refresh_columns(nil, model, 1, 1) -- width 3 → grows to 3
        assert.equals(3, model.columns[1])
        refresh_columns(nil, model, 2, 2) -- width 10 → capped at 5
        assert.equals(5, model.columns[1])
        refresh_columns(nil, model, 3, 3) -- width 2 → sticky, stays 5
        assert.equals(5, model.columns[1])
    end)

    -- col_sticky (no cap) just keeps a column from shrinking — for the graph
    -- column under mirroring (spec §5.4). A function form is supported too.
    it("a col_sticky column only grows, with no cap", function()
        local model = {
            flex = nil,
            columns = {},
            col_sticky = function() return { 1 } end,
            items = { { data = "abcdefghij" }, { data = "ab" } },
            display = function(d) return { line = { { text = d } } } end,
        }
        refresh_columns(nil, model, 1, 1) -- width 10 → grows to 10 (no cap)
        assert.equals(10, model.columns[1])
        refresh_columns(nil, model, 2, 2) -- width 2 → sticky, stays 10
        assert.equals(10, model.columns[1])
    end)
end)
