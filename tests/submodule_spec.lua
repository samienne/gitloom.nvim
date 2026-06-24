--- Tests for the submodule change view's pure core (specification.md §11.7):
--- `parse_changes` (find Subproject bumps in a patch), `classify` (the
--- relationship from a merge-base), and `link` (a flat commit list into
--- layout-ready OrderItems). The git I/O, layout, and render splice in graph.lua
--- are window/IO glue and not unit-tested.

local submodule = require("gitloom.submodule")

-- A 40-hex hash from a single seed character (readable in assertions).
local function H(ch) return string.rep(ch, 40) end

-- A submodule bump file section as git renders it (160000 mode, the old/new
-- `Subproject commit` pair).
local function bump(path, old, new)
    return table.concat({
        "diff --git a/" .. path .. " b/" .. path,
        "index " .. old:sub(1, 7) .. ".." .. new:sub(1, 7) .. " 160000",
        "--- a/" .. path,
        "+++ b/" .. path,
        "@@ -1 +1 @@",
        "-Subproject commit " .. old,
        "+Subproject commit " .. new,
    }, "\n")
end

describe("submodule.parse_changes", function()
    it("finds a single submodule bump with line indices", function()
        local patch = bump("libs/foo", H("a"), H("b"))
        local changes = submodule.parse_changes(patch)
        assert.equals(1, #changes)
        local c = changes[1]
        assert.equals("libs/foo", c.path)
        assert.equals(H("a"), c.old)
        assert.equals(H("b"), c.new)
        -- diff --git is line 1; the Subproject pair lands on lines 6 and 7.
        assert.equals(1, c.file_line)
        assert.equals(6, c.from_line)
        assert.equals(7, c.to_line)
    end)

    it("finds several bumps and ignores normal file diffs", function()
        local normal = table.concat({
            "diff --git a/src/main.lua b/src/main.lua",
            "index 1234567..89abcde 100644",
            "--- a/src/main.lua",
            "+++ b/src/main.lua",
            "@@ -1,2 +1,2 @@",
            "-Subproject commit lookalike in context",
            "+local x = 1",
            " unchanged",
        }, "\n")
        local patch = table.concat({
            bump("libs/foo", H("a"), H("b")),
            normal,
            bump("vendor/bar", H("c"), H("d")),
        }, "\n")
        local changes = submodule.parse_changes(patch)
        assert.equals(2, #changes)
        assert.equals("libs/foo", changes[1].path)
        assert.equals("vendor/bar", changes[2].path)
        -- The "-Subproject commit lookalike…" context line is a removal in a
        -- 100644 file, not a gitlink pair, so it is not mistaken for a bump.
    end)

    it("skips a one-sided change (submodule added or removed)", function()
        local added = table.concat({
            "diff --git a/libs/new b/libs/new",
            "new file mode 160000",
            "index 0000000.." .. H("e"):sub(1, 7),
            "--- /dev/null",
            "+++ b/libs/new",
            "@@ -0,0 +1 @@",
            "+Subproject commit " .. H("e"),
        }, "\n")
        assert.equals(0, #submodule.parse_changes(added))
    end)

    it("returns nothing for an empty or nil patch", function()
        assert.equals(0, #submodule.parse_changes(""))
        assert.equals(0, #submodule.parse_changes(nil))
    end)
end)

describe("submodule.classify", function()
    it("is ff when the merge-base is the old pointer", function()
        assert.equals("ff", submodule.classify(H("a"), H("b"), H("a")))
    end)

    it("is rewind when the merge-base is the new pointer", function()
        assert.equals("rewind", submodule.classify(H("a"), H("b"), H("b")))
    end)

    it("is diverged when the merge-base is a third commit", function()
        assert.equals("diverged", submodule.classify(H("a"), H("b"), H("c")))
    end)

    it("is unrelated when there is no merge-base", function()
        assert.equals("unrelated", submodule.classify(H("a"), H("b"), ""))
        assert.equals("unrelated", submodule.classify(H("a"), H("b"), nil))
    end)
end)

describe("submodule.link", function()
    it("resolves in-list parents and sets child back-links, preserving order", function()
        -- c -> b -> a (newest first); parents given as hash strings.
        local commits = {
            { hash = "c", parents = { "b" }, message = "third" },
            { hash = "b", parents = { "a" }, message = "second" },
            { hash = "a", parents = { "root" }, message = "first" },
        }
        local items = submodule.link(commits)
        assert.equals(3, #items)
        assert.equals("commit", items[1].type)
        -- Order preserved (newest-first in -> newest-first out).
        assert.equals("c", items[1].commit.hash)
        assert.equals("a", items[3].commit.hash)

        local a, b, c = commits[3], commits[2], commits[1]
        -- Parents resolved to the in-list Commit objects.
        assert.equals(b, c.parents[1])
        assert.equals(a, b.parents[1])
        -- `root` is not in the list (the cone boundary): dropped, so `a` is a root.
        assert.equals(0, #a.parents)
        -- Child back-links point the other way.
        assert.equals(c, b.children[1])
        assert.equals(b, a.children[1])
        assert.equals(0, #c.children)
    end)

    it("links a merge with two in-list parents", function()
        -- m merges p1 and p2; both present in the list.
        local commits = {
            { hash = "m", parents = { "p1", "p2" } },
            { hash = "p1", parents = {} },
            { hash = "p2", parents = {} },
        }
        local items = submodule.link(commits)
        assert.equals(3, #items)
        local m, p1, p2 = commits[1], commits[2], commits[3]
        assert.equals(2, #m.parents)
        assert.equals(p1, m.parents[1])
        assert.equals(p2, m.parents[2])
        assert.equals(m, p1.children[1])
        assert.equals(m, p2.children[1])
    end)
end)
