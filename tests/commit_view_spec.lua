--- Tests for the commit view's pure pieces (specification.md §11):
--- `parse_show` (splits `git show -s` output into a CommitDetail) and
--- `format_commit_detail` (renders a CommitDetail into display lines). The
--- window/IO glue (fetch + snacks float) is not unit-tested.

local internal = require("gitloom.graph")._internal
local parse_show = internal.parse_show
local format_commit_detail = internal.format_commit_detail
local format_diff = internal.format_diff
local diffstat_files = internal.diffstat_files
local diff_contexts = internal.diff_contexts
local format_diffstat = internal.format_diffstat
local commit_range = internal.commit_range
local commit_view_buf_name = internal.commit_view_buf_name

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

describe("diff_contexts", function()
    local patch = table.concat({
        "diff --git a/foo.lua b/foo.lua",   -- 1
        "index 1111111..2222222 100644",    -- 2
        "--- a/foo.lua",                    -- 3
        "+++ b/foo.lua",                    -- 4
        "@@ -1,3 +1,4 @@ function foo()",    -- 5
        " context",                         -- 6
        "+added",                           -- 7
        "@@ -20,2 +21,3 @@ function bar()",  -- 8
        " more",                            -- 9
        "diff --git a/old.md b/new.md",     -- 10 (rename)
        "rename from old.md",               -- 11
        "rename to new.md",                 -- 12
        "@@ -1 +1 @@",                      -- 13
        "-x",                               -- 14
    }, "\n")

    it("tracks the governing file and hunk per line, with begin indices", function()
        local ctx = diff_contexts(patch)
        -- File-header region of foo.lua: file set from the `diff --git` line, no
        -- hunk yet (before the first @@).
        assert.same({ file = "foo.lua", file_line = 1 }, ctx[3])
        -- Inside the first hunk's body: governing file + hunk, each with the
        -- patch-line where it begins.
        assert.same(
            { file = "foo.lua", file_line = 1, hunk = "@@ -1,3 +1,4 @@ function foo()", hunk_line = 5 },
            ctx[7])
        -- The second hunk governs from its own @@ line onward.
        assert.same(
            { file = "foo.lua", file_line = 1, hunk = "@@ -20,2 +21,3 @@ function bar()", hunk_line = 8 },
            ctx[9])
    end)

    it("resets the hunk at a new file and shows renames as old => new", function()
        local ctx = diff_contexts(patch)
        -- The new file's header region: file is the rename path, and the hunk is
        -- cleared even though the previous file had hunks.
        assert.same({ file = "old.md => new.md", file_line = 10 }, ctx[11])
        assert.same(
            { file = "old.md => new.md", file_line = 10, hunk = "@@ -1 +1 @@", hunk_line = 13 },
            ctx[14])
    end)

    it("is empty for an empty patch", function()
        assert.same({}, diff_contexts(""))
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

describe("commit_range", function()
    it("uses <hash>^! for a commit with parents, from = first parent", function()
        local p1, p2 = { hash = "p1" }, { hash = "p2" }
        local c = { hash = "abc1234", parents = { p1, p2 } }
        local r = commit_range(c)
        assert.equals("abc1234^!", r.rev)
        assert.equals(p1, r.from)
        assert.equals(c, r.to)
    end)

    it("uses the empty-tree range for a root commit (no parents)", function()
        local c = { hash = "root123", parents = {} }
        local r = commit_range(c)
        assert.equals("4b825dc642cb6eb9a060e54bf8d69288fbee4904..root123", r.rev)
        assert.is_nil(r.from)
        assert.equals(c, r.to)
    end)

    it("treats a missing parents field as a root", function()
        -- deliberately partial: exercises commit_range's `parents or {}` fallback
        ---@diagnostic disable-next-line: missing-fields
        local r = commit_range({ hash = "x" })
        assert.equals("4b825dc642cb6eb9a060e54bf8d69288fbee4904..x", r.rev)
        assert.is_nil(r.from)
    end)
end)

describe("wrap_message (§11.2.1)", function()
    local wrap_message = internal.wrap_message
    local message_width = internal.message_width
    local W = vim.fn.strdisplaywidth

    local function fits(lines, width)
        for _, l in ipairs(lines) do
            assert.is_true(W(l) <= width, ("%q is wider than %d"):format(l, width))
        end
    end

    it("caps the window width at 100 cells, nil stays nil", function()
        assert.equals(60, message_width(60))
        assert.equals(100, message_width(250))
        assert.is_nil(message_width(nil))
    end)

    it("joins a paragraph and re-wraps it at word boundaries", function()
        local out = wrap_message(
            "Subject\n\nthe quick brown\nfox jumps over the\nlazy dog again", 16)
        assert.same({ "Subject", "", "the quick brown", "fox jumps over", "the lazy dog", "again" }, out)
        fits(out, 16)
    end)

    it("keeps blank lines and separates paragraphs", function()
        local out = wrap_message("S\n\na b\n\n\nc d", 40)
        assert.same({ "S", "", "a b", "", "", "c d" }, out)
    end)

    it("leaves indented lines and fenced blocks untouched", function()
        local long = "    " .. string.rep("x ", 30)
        local msg = table.concat({
            "S", "", "intro text", long, "\tтаб line with a tab",
            "```", "fenced line that is quite long indeed and must stay", "not joined", "```",
            "after",
        }, "\n")
        local out = wrap_message(msg, 20)
        assert.same({
            "S", "", "intro text", long, "\tтаб line with a tab",
            "```", "fenced line that is quite long indeed and must stay", "not joined", "```",
            "after",
        }, out)
    end)

    it("keeps trailers in the final paragraph and URL-only lines verbatim", function()
        local url = "https://example.com/a/very/long/path/that/overflows/the/width"
        local msg = table.concat({
            "S", "", "see", url, "[1]: " .. url, "",
            "Signed-off-by: Somebody With A Long Name <somebody@example.com>",
            "Co-Authored-By: Another Person <another.person@example.com>",
        }, "\n")
        local out = wrap_message(msg, 30)
        assert.same({
            "S", "", "see", url, "[1]: " .. url, "",
            "Signed-off-by: Somebody With A Long Name <somebody@example.com>",
            "Co-Authored-By: Another Person <another.person@example.com>",
        }, out)
    end)

    it("does not treat a Key: value line outside the final paragraph as a trailer", function()
        local out = wrap_message("S\n\nNote: this sentence is long enough to wrap\n\nend", 20)
        assert.same({ "S", "", "Note: this sentence", "is long enough to", "wrap", "", "end" }, out)
    end)

    it("wraps list items with a hanging indent and joins their continuations", function()
        local msg = table.concat({
            "S", "",
            "- first item that runs",
            "  on to an aligned continuation",
            "* lazy",
            "continuation",
            "1. numbered item wraps here",
            "2) other",
        }, "\n")
        local out = wrap_message(msg, 18)
        assert.same({
            "S", "",
            "- first item that", "  runs on to an", "  aligned", "  continuation",
            "* lazy", "  continuation",
            "1. numbered item", "   wraps here",
            "2) other",
        }, out)
        fits(out, 18)
    end)

    it("never breaks a word wider than the width", function()
        local big = string.rep("a", 30)
        local out = wrap_message("S\n\nshort " .. big .. " tail", 10)
        assert.same({ "S", "", "short", big, "tail" }, out)
    end)

    it("measures display width, so double-width text wraps correctly", function()
        -- Each 漢字 is 4 cells; 3 of them plus 2 spaces = 14 cells.
        local out = wrap_message("S\n\n漢字 漢字 漢字 漢字", 14)
        assert.same({ "S", "", "漢字 漢字 漢字", "漢字" }, out)
        fits(out, 14)
    end)

    it("wraps the subject on its own, not joined with the body", function()
        local out = wrap_message("a long subject line here\nbody", 10)
        assert.same({ "a long", "subject", "line here", "body" }, out)
    end)
end)

describe("format_commit_detail with a wrap width (§11.2.1)", function()
    local detail = {
        hash = "abc1234", author_name = "A", author_email = "a@x", author_date = "d",
        committer_name = "A", committer_email = "a@x", committer_date = "d",
        parents = {},
        body = "Subject\n\none two three four five six seven eight nine ten",
    }

    it("wraps the indented message to the width, indent included", function()
        local lines = texts(format_commit_detail(detail, { width = 24 }))
        local msg = {}
        for i = 5, #lines do msg[#msg + 1] = lines[i] end
        assert.same({ "    Subject", "    ", "    one two three four", "    five six seven eight",
            "    nine ten" }, msg)
        for _, l in ipairs(msg) do assert.is_true(#l <= 24) end
    end)

    it("leaves the message as is without a width", function()
        local lines = texts(format_commit_detail(detail))
        assert.equals("    one two three four five six seven eight nine ten", lines[#lines])
    end)
end)

describe("build_commit_rows offsets after a wrapped body (§11.2.1/§11.4/§11.6)", function()
    local window = require("gitloom.window")
    local patch = table.concat({
        "diff --git a/f.txt b/f.txt",
        "index 1111111..2222222 100644",
        "--- a/f.txt",
        "+++ b/f.txt",
        "@@ -1 +1 @@",
        "-old",
        "+new",
        "diff --git a/g.txt b/g.txt",
        "index 3333333..4444444 100644",
        "--- a/g.txt",
        "+++ b/g.txt",
        "@@ -1 +1 @@",
        "-a",
        "+b",
    }, "\n")
    local meta = show_output({ body = "Subject\n\n" .. string.rep("word ", 60) })
    local opts = { palette = {} }
    local commit = { hash = "abc1234", refs = {} }

    local function build(width)
        return window.build_commit_rows(opts, {
            commit = commit, meta = meta, diff = patch, action = false, width = width,
        })
    end

    it("the file jumps and the diff start follow the wrapped body", function()
        local plain_rows, plain = build(nil)
        local rows, info = build(30)
        local delta = info.meta_end - plain.meta_end
        assert.is_true(delta > 0)
        assert.equals(#plain_rows + delta, #rows)
        assert.equals(plain.diff_start + delta, info.diff_start)
        assert.equals("diff --git a/f.txt b/f.txt", rows[info.diff_start].text)
        local jumps = 0
        for stat_row, target in pairs(info.file_jumps) do
            jumps = jumps + 1
            local file = rows[stat_row].text:match("([fg]%.txt)")
            assert.is_not_nil(file)
            assert.equals("diff --git a/" .. file .. " b/" .. file, rows[target].text)
        end
        assert.equals(2, jumps)
        -- The context-header lookup is relative to diff_start: the patch line
        -- at diff_start + k - 1 is still patch line k.
        local plines = vim.split(patch, "\n")
        for k, l in ipairs(plines) do
            assert.equals(l, rows[info.diff_start + k - 1].text)
        end
    end)
end)

describe("commit_view_buf_name (§11)", function()
    it("names a single commit view `<root> (gitloom) <short hash>`", function()
        assert.equal("/repo (gitloom) abc1234", commit_view_buf_name("/repo", "Commit abc1234"))
    end)

    it("keeps a range / working-tree title whole", function()
        assert.equal("/repo (gitloom) abc1234..def5678",
            commit_view_buf_name("/repo", "abc1234..def5678"))
        assert.equal("C:/src/x (gitloom) Working tree",
            commit_view_buf_name("C:/src/x", "Working tree"))
    end)

    it("strips only a leading `Commit `", function()
        assert.equal("/r (gitloom) Range Commit x", commit_view_buf_name("/r", "Range Commit x"))
    end)

    it("leaves a named scratch buffer nofile (no write prompt)", function()
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(buf, commit_view_buf_name("/repo", "Commit abc1234"))
        assert.equal("nofile", vim.bo[buf].buftype)
        assert.is_true(vim.api.nvim_buf_get_name(buf):find("(gitloom) abc1234", 1, true) ~= nil)
        vim.api.nvim_buf_delete(buf, { force = true })
    end)
end)
