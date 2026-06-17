--- Tests for the commit view's pure pieces (specification.md §11):
--- `parse_show` (splits `git show -s` output into a CommitDetail) and
--- `format_commit_detail` (renders a CommitDetail into display lines). The
--- window/IO glue (fetch + snacks float) is not unit-tested.

local internal = require("gitloom.graph")._internal
local parse_show = internal.parse_show
local format_commit_detail = internal.format_commit_detail
local format_diff = internal.format_diff
local diffstat_files = internal.diffstat_files
local format_diffstat = internal.format_diffstat

-- Build a `git show -s` output line for the documented format:
-- %H %an %ae %ad %cn %ce %cd %P %B, separated by \x1f, body last.
local function show_output(t)
    return table.concat({
        t.hash or "abc1234",
        t.author_name or "Alice",
        t.author_email or "alice@example.com",
        t.author_date or "2026-06-17 14:00:00 +0300",
        t.committer_name or t.author_name or "Alice",
        t.committer_email or t.author_email or "alice@example.com",
        t.committer_date or t.author_date or "2026-06-17 14:00:00 +0300",
        t.parents or "",
        t.body or "Subject",
    }, "\x1f")
end

-- The `.text` of each rendered line.
local function texts(rows)
    local out = {}
    for _, r in ipairs(rows) do
        out[#out + 1] = r.text
    end
    return out
end

local function contains(list, value)
    for _, v in ipairs(list) do
        if v == value then return true end
    end
    return false
end

describe("parse_show", function()
    it("splits the fields into a CommitDetail", function()
        local d = parse_show(show_output({
            hash = "deadbeef",
            author_name = "Alice",
            author_email = "alice@example.com",
            author_date = "2026-06-17 14:00:00 +0300",
            committer_name = "Bob",
            committer_email = "bob@example.com",
            committer_date = "2026-06-18 09:00:00 +0300",
            parents = "p1 p2",
            body = "Subject",
        }))
        assert.equals("deadbeef", d.hash)
        assert.equals("Alice", d.author_name)
        assert.equals("alice@example.com", d.author_email)
        assert.equals("2026-06-17 14:00:00 +0300", d.author_date)
        assert.equals("Bob", d.committer_name)
        assert.equals("bob@example.com", d.committer_email)
        assert.equals("2026-06-18 09:00:00 +0300", d.committer_date)
        assert.same({ "p1", "p2" }, d.parents)
    end)

    it("yields no parents for a root commit (empty %P)", function()
        local d = parse_show(show_output({ parents = "" }))
        assert.same({}, d.parents)
    end)

    it("keeps a multi-line body and trims trailing whitespace", function()
        local d = parse_show(show_output({
            body = "Subject line\n\nBody paragraph.\nSecond line.\n\n",
        }))
        assert.equals("Subject line\n\nBody paragraph.\nSecond line.", d.body)
    end)
end)

describe("format_commit_detail", function()
    local base = {
        hash = "abc1234",
        author_name = "Alice",
        author_email = "alice@example.com",
        author_date = "2026-06-17 14:00:00 +0300",
        committer_name = "Alice",
        committer_email = "alice@example.com",
        committer_date = "2026-06-17 14:00:00 +0300",
        parents = {},
        body = "Hello\nWorld",
    }

    it("renders the hash, author, and an indented body", function()
        local lines = texts(format_commit_detail(base))
        assert.equals("commit abc1234", lines[1])
        assert.equals("Author:     Alice <alice@example.com>", lines[2])
        assert.equals("AuthorDate: 2026-06-17 14:00:00 +0300", lines[3])
        assert.equals("", lines[4])
        assert.equals("    Hello", lines[5])
        assert.equals("    World", lines[6])
    end)

    it("omits the committer block when it matches the author", function()
        local lines = texts(format_commit_detail(base))
        for _, l in ipairs(lines) do
            assert.is_nil(l:match("^Commit:"))
            assert.is_nil(l:match("^CommitDate:"))
        end
    end)

    it("shows the committer block when it differs", function()
        local detail = vim.tbl_extend("force", base, {
            committer_name = "Bob",
            committer_email = "bob@example.com",
            committer_date = "2026-06-18 09:00:00 +0300",
        })
        local lines = texts(format_commit_detail(detail))
        assert.is_true(contains(lines, "Commit:     Bob <bob@example.com>"))
        assert.is_true(contains(lines, "CommitDate: 2026-06-18 09:00:00 +0300"))
    end)

    it("renders a Refs line from the decorations, abbreviates parents", function()
        local detail = vim.tbl_extend("force", base, { parents = { "p1abcdef0", "p2abcdef0" } })
        local lines = texts(format_commit_detail(detail, {
            decorations = { "(master)", "[v1.0]" },
        }))
        assert.is_true(contains(lines, "Refs:       (master) [v1.0]"))
        assert.is_true(contains(lines, "Parents:    p1abcde p2abcde"))
    end)

    it("omits the Refs line when there are no decorations", function()
        local lines = texts(format_commit_detail(base))
        for _, l in ipairs(lines) do
            assert.is_nil(l:match("^Refs:"))
        end
    end)
end)

describe("format_diff", function()
    local PALETTE = {
        diff = { add = "DiffAdd", delete = "DiffDelete", hunk = "Title", header = "Comment" },
    }

    -- The highlight group covering a rendered row, or "none" (a context line).
    local function role_hl(row)
        local h = row.highlight
        if not h or #h == 0 then return "none" end
        return h[1].hl
    end

    it("colors added and removed lines, leaving context uncolored", function()
        local rows = format_diff("+added\n-removed\n context", PALETTE)
        assert.equals("DiffAdd", role_hl(rows[1]))
        assert.equals("DiffDelete", role_hl(rows[2]))
        assert.equals("none", role_hl(rows[3]))
        assert.equals("+added", rows[1].text)
    end)

    it("treats +++/--- file markers as headers, not add/delete", function()
        local rows = format_diff("--- a/x.lua\n+++ b/x.lua", PALETTE)
        assert.equals("Comment", role_hl(rows[1]))
        assert.equals("Comment", role_hl(rows[2]))
    end)

    it("colors hunk headers and file headers", function()
        local rows = format_diff(
            "diff --git a/x.lua b/x.lua\nindex 1111111..2222222 100644\n@@ -1,2 +1,3 @@ ctx",
            PALETTE)
        assert.equals("Comment", role_hl(rows[1])) -- diff --git
        assert.equals("Comment", role_hl(rows[2])) -- index
        assert.equals("Title", role_hl(rows[3]))   -- hunk header
    end)

    it("uses no highlights when the palette omits diff groups", function()
        local rows = format_diff("+added\n-removed", {})
        assert.equals("none", role_hl(rows[1]))
        assert.equals("none", role_hl(rows[2]))
        assert.equals("+added", rows[1].text)
    end)
end)

describe("diffstat_files", function()
    local patch = table.concat({
        "diff --git a/foo.lua b/foo.lua", -- 1
        "index 1111111..2222222 100644",  -- 2
        "--- a/foo.lua",                  -- 3 (not counted)
        "+++ b/foo.lua",                  -- 4 (not counted)
        "@@ -1,3 +1,4 @@",                -- 5
        " context",                       -- 6
        "-old line",                      -- 7 (removed)
        "+new line one",                  -- 8 (added)
        "+new line two",                  -- 9 (added)
        "diff --git a/bar.txt b/bar.txt", -- 10
        "new file mode 100644",           -- 11
        "index 0000000..3333333",         -- 12
        "--- /dev/null",                  -- 13
        "+++ b/bar.txt",                  -- 14
        "@@ -0,0 +1 @@",                  -- 15
        "+hello",                         -- 16 (added)
        "diff --git a/old.md b/new.md",   -- 17 (rename)
        "similarity index 100%",          -- 18
        "rename from old.md",             -- 19
        "rename to new.md",               -- 20
        "diff --git a/img.png b/img.png", -- 21 (binary)
        "index aaaaaaa..bbbbbbb",         -- 22
        "Binary files a/img.png and b/img.png differ", -- 23
    }, "\n")

    it("parses per-file counts and start offsets", function()
        local files = diffstat_files(patch)
        assert.equals(4, #files)
        assert.same({ path = "foo.lua", added = 2, removed = 1, binary = false, start = 1 }, files[1])
        assert.same({ path = "bar.txt", added = 1, removed = 0, binary = false, start = 10 }, files[2])
    end)

    it("shows renames as old => new and keeps the start offset", function()
        local files = diffstat_files(patch)
        assert.equals("old.md => new.md", files[3].path)
        assert.equals(17, files[3].start)
    end)

    it("flags binary files", function()
        local files = diffstat_files(patch)
        assert.is_true(files[4].binary)
        assert.equals("img.png", files[4].path)
        assert.equals(21, files[4].start)
    end)

    it("is empty for an empty patch", function()
        assert.same({}, diffstat_files(""))
    end)
end)

describe("format_diffstat", function()
    local PALETTE = { diff = { add = "DiffAdd", delete = "DiffDelete" }, author = "Comment" }
    local files = {
        { path = "foo.lua", added = 2, removed = 1, binary = false },
        { path = "bar.txt", added = 1, removed = 0, binary = false },
        { path = "img.png", added = 0, removed = 0, binary = true },
    }
    local function has(s, sub) return s:find(sub, 1, true) ~= nil end

    it("renders a git-style summary first", function()
        local rows = format_diffstat(files, PALETTE)
        assert.equals("3 files changed, 3 insertions(+), 1 deletion(-)", rows[1].text)
    end)

    it("renders one row per file in order, with counts and a bar", function()
        local rows = format_diffstat(files, PALETTE)
        assert.equals(4, #rows) -- summary + 3 files
        assert.is_true(has(rows[2].text, "foo.lua"))
        assert.is_true(has(rows[2].text, "3 ++-")) -- total 3, then ++ and -
        assert.is_true(has(rows[4].text, "Bin"))   -- binary file
    end)

    it("colors the + and - bar segments", function()
        local rows = format_diffstat(files, PALETTE)
        local groups = {}
        for _, hl in ipairs(rows[2].highlight or {}) do groups[hl.hl] = true end
        assert.is_true(groups["DiffAdd"])
        assert.is_true(groups["DiffDelete"])
    end)
end)
