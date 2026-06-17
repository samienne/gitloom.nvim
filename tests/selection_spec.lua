--- Tests for the ref-selection helpers (specification.md §2).
--- The row has `count` cursor positions: 1..count-1 are ref decorations and
--- `count` is the commit message (rightmost, default). move_selection clamps
--- (no wrap); decoration_texts is the shared decoration-string source;
--- cursor_column finds the byte column to park the cursor on.

local internal = require("gitloom.graph")._internal
local move_selection = internal.move_selection
local decoration_texts = internal.decoration_texts
local cursor_column = internal.cursor_column

describe("move_selection", function()
    -- count = 4: positions 1..3 are decorations, 4 is the message (default).
    it("starts from the message (nil): h -> last decoration, l stays", function()
        assert.equals(3, move_selection(nil, 4, -1))
        assert.equals(4, move_selection(nil, 4, 1))
    end)

    it("steps within range", function()
        assert.equals(2, move_selection(3, 4, -1))
        assert.equals(3, move_selection(2, 4, 1))
    end)

    it("clamps at both ends (no wrap)", function()
        assert.equals(1, move_selection(1, 4, -1)) -- first decoration
        assert.equals(4, move_selection(4, 4, 1))  -- message
    end)

    it("is a no-op when only the message exists (count 1)", function()
        assert.equals(1, move_selection(nil, 1, -1))
        assert.equals(1, move_selection(1, 1, -1))
        assert.equals(1, move_selection(1, 1, 1))
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

describe("cursor_column", function()
    it("lands on a decoration's first occurrence (0-based byte col)", function()
        assert.equals(2, cursor_column("ab(main) fix bug", "fix bug", "(main)"))
    end)

    it("falls back to the message tail when no decoration is given", function()
        -- "xx (main) hello" then trailing padding; message is the line's tail.
        assert.equals(10, cursor_column("xx (main) hello    ", "hello", nil))
    end)

    it("falls back to the message tail when the decoration is absent", function()
        assert.equals(10, cursor_column("xx (main) hello", "hello", "(nope)"))
    end)
end)
