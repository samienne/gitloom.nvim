--- Tests for gitloom.graph parse_commit_line — git log pretty-format parsing.

local internal = require("gitloom.graph")._internal
local parse_commit_line = internal.parse_commit_line
local parse_timestamp = internal.parse_timestamp
local format_absolute = internal.format_absolute
local format_relative = internal.format_relative

-- The pretty-format uses %x1f (unit separator) as the field delimiter:
-- hash, parents, author, epoch (%at), iso date (%ai), subject (refs are
-- resolved separately).
local US = "\31"

local function line(fields)
    return table.concat(fields, US)
end

describe("parse_commit_line", function()
    it("parses a commit with a single parent", function()
        local c = parse_commit_line(line({
            "abc123", "def456", "Alice", "1704110400", "2024-01-01 12:00:00 +0000", "1704110500", "Initial commit",
        }))
        ---@cast c -nil
        assert.equals("abc123", c.hash)
        assert.same({ "def456" }, c.parents)
        assert.equals("Alice", c.author)
        assert.equals(1704110400, c.date.epoch)
        assert.equals(0, c.date.offset)
        assert.equals(1704110500, c.cepoch) -- committer epoch (%ct), seeds the sort (§3.1)
        assert.equals("Initial commit", c.message)
        assert.is_true(c.loaded)
    end)

    it("parses multiple parents", function()
        local c = parse_commit_line(line({ "h", "p1 p2", "A", "0", "d", "0", "merge" }))
        ---@cast c -nil
        assert.same({ "p1", "p2" }, c.parents)
    end)

    it("handles a root commit with no parents", function()
        local c = parse_commit_line(line({ "h", "", "A", "0", "d", "0", "root" }))
        ---@cast c -nil
        assert.same({}, c.parents)
    end)

    it("starts with an empty refs list (refs are resolved separately)", function()
        local c = parse_commit_line(line({ "h", "", "A", "0", "d", "0", "subj" }))
        ---@cast c -nil
        assert.same({}, c.refs)
    end)
end)

describe("parse_timestamp", function()
    it("reads the epoch and a positive tz offset", function()
        local ts = parse_timestamp("1704110400", "2024-01-01 15:00:00 +0300")
        assert.equals(1704110400, ts.epoch)
        assert.equals(3 * 3600, ts.offset)
    end)

    it("reads a negative tz offset (with minutes)", function()
        local ts = parse_timestamp("1704110400", "2024-01-01 06:30:00 -0530")
        assert.equals(-(5 * 3600 + 30 * 60), ts.offset)
    end)

    it("defaults to epoch 0 / offset 0 on missing input", function()
        local ts = parse_timestamp(nil, nil)
        assert.equals(0, ts.epoch)
        assert.equals(0, ts.offset)
    end)
end)

describe("format_absolute", function()
    -- Author-local wall clock = epoch + offset, independent of the viewer tz.
    it("renders the author's local time, not the viewer's", function()
        local ts = { epoch = 1704110400, offset = 3 * 3600 } -- 12:00 UTC -> 15:00 +03
        assert.equals("2024-01-01 15:00", format_absolute(ts, "%Y-%m-%d %H:%M"))
    end)

    it("honors a custom format", function()
        local ts = { epoch = 1704110400, offset = 0 }
        assert.equals("2024-01-01", format_absolute(ts, "%Y-%m-%d"))
    end)
end)

describe("format_relative", function()
    local function rel(secs_ago)
        return format_relative({ epoch = 1000000 - secs_ago, offset = 0 }, 1000000)
    end

    it("buckets by the largest fitting unit, pluralizing", function()
        assert.equals("just now", rel(0))
        assert.equals("1 second ago", rel(1))
        assert.equals("5 minutes ago", rel(5 * 60))
        assert.equals("1 hour ago", rel(3600))
        assert.equals("3 days ago", rel(3 * 86400))
        assert.equals("2 weeks ago", rel(14 * 86400))
        assert.equals("1 year ago", rel(400 * 86400))
    end)

    it("treats future timestamps as just now", function()
        assert.equals("just now", format_relative({ epoch = 2000000, offset = 0 }, 1000000))
    end)
end)

-- The de-chunker that turns an unbuffered jobstart stdout stream (lists of
-- strings split on "\n", with partial lines at the chunk seams) into whole
-- lines. This is the new logic behind streaming the git log in batches.
describe("make_line_buffer", function()
    local make_line_buffer = internal.make_line_buffer

    it("returns complete lines and holds the trailing partial", function()
        local lb = make_line_buffer()
        -- "a\nb\nc" — "a" and "b" are complete; "c" is partial (no newline yet).
        assert.same({ "a", "b" }, lb.feed({ "a", "b", "c" }))
        assert.equals("c", lb.flush())
    end)

    it("stitches a line split across two chunks", function()
        local lb = make_line_buffer()
        -- First chunk ends mid-line ("hel"); next chunk continues it ("lo").
        assert.same({}, lb.feed({ "hel" }))
        assert.same({ "hello" }, lb.feed({ "lo", "" }))
        assert.equals("", lb.flush())
    end)

    it("reassembles a stream chunked at arbitrary byte boundaries", function()
        local lb = make_line_buffer()
        local source = "one\ntwo\nthree\nfour"
        -- Feed one byte at a time, splitting on "\n" the way Neovim does.
        local got = {}
        for i = 1, #source do
            local ch = source:sub(i, i)
            local data = ch == "\n" and { "", "" } or { ch }
            for _, l in ipairs(lb.feed(data)) do
                got[#got + 1] = l
            end
        end
        got[#got + 1] = lb.flush()
        assert.same({ "one", "two", "three", "four" }, got)
    end)

    it("handles an empty chunk without emitting a line", function()
        local lb = make_line_buffer()
        assert.same({}, lb.feed({}))
        assert.equals("", lb.flush())
    end)

    it("emits a blank line between consecutive newlines", function()
        local lb = make_line_buffer()
        -- "a\n\nb" -> "a", "" (blank), then "b" partial.
        assert.same({ "a", "" }, lb.feed({ "a", "", "b" }))
        assert.equals("b", lb.flush())
    end)
end)
