--- Tests for gitloom.graph parse_commit_line — git log pretty-format parsing.

local parse_commit_line = require("gitloom.graph")._internal.parse_commit_line

-- The pretty-format uses %x1f (unit separator) as the field delimiter.
local US = "\31"

local function line(fields)
    return table.concat(fields, US)
end

describe("parse_commit_line", function()
    it("parses a commit with a single parent", function()
        local c = parse_commit_line(line({
            "abc123", "def456", "Alice", "2024-01-01 12:00:00 +0000", "Initial commit", "",
        }))
        assert.equals("abc123", c.hash)
        assert.same({ "def456" }, c.parents)
        assert.equals("Alice", c.author)
        assert.equals("2024-01-01 12:00:00 +0000", c.date)
        assert.equals("Initial commit", c.message)
        assert.is_true(c.loaded)
    end)

    it("parses multiple parents", function()
        local c = parse_commit_line(line({ "h", "p1 p2", "A", "d", "merge", "" }))
        assert.same({ "p1", "p2" }, c.parents)
    end)

    it("handles a root commit with no parents", function()
        local c = parse_commit_line(line({ "h", "", "A", "d", "root", "" }))
        assert.same({}, c.parents)
    end)

    it("parses refs from the decorate field", function()
        local c = parse_commit_line(line({ "h", "", "A", "d", "subj", "refs/heads/main" }))
        assert.equals("main", c.refs.branches[1].name)
    end)
end)
