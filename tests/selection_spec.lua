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
end)
