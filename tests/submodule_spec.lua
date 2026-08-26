--- Tests for the submodule change view's pure core (specification.md §11.7):
--- `parse_changes` (find Subproject bumps in a patch), `classify` (the
--- relationship from a merge-base), `split_budget` (the even-with-spill height
--- distribution between the added/removed sides) and `truncate` (keep the newest
--- N, report the dropped middle). The git I/O, layout, and render splice in
--- graph.lua are window/IO glue and not unit-tested. The module's *other* half —
--- the repository picker's submodule discovery (§2.1) — is covered by
--- `tests/repo_picker_spec.lua`.

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

describe("submodule.split_budget", function()
    -- max includes the one reserved ancestor row, so the two sides share max-1.
    it("splits the remaining budget evenly, leftover to the new side", function()
        -- max 12 -> 11 to share; new gets ceil(11/2)=6, old gets 5.
        assert.same({ new = 6, old = 5 }, submodule.split_budget(12, 100, 100))
        -- Odd leftover always lands on the new (added) side.
        local b = submodule.split_budget(11, 100, 100) -- 10 to share -> 5 / 5
        assert.same({ new = 5, old = 5 }, b)
    end)

    it("gives the whole budget to the non-empty side (ff / rewind)", function()
        -- Fast-forward: old side empty -> new side takes all 11 rows.
        assert.same({ new = 11, old = 0 }, submodule.split_budget(12, 30, 0))
        -- Rewind: new side empty -> old side takes all 11 rows.
        assert.same({ new = 0, old = 11 }, submodule.split_budget(12, 0, 30))
    end)

    it("spills a short side's unused share to the other", function()
        -- new only has 2 commits; its surplus (6-2=4) spills to old (5+4=9).
        assert.same({ new = 2, old = 9 }, submodule.split_budget(12, 2, 100))
        -- Symmetric the other way.
        assert.same({ new = 9, old = 2 }, submodule.split_budget(12, 100, 2))
    end)

    it("never exceeds what each side actually has", function()
        -- Both sides small: keep them all, no padding.
        assert.same({ new = 1, old = 1 }, submodule.split_budget(12, 1, 1))
        assert.same({ new = 3, old = 4 }, submodule.split_budget(12, 3, 4))
    end)
end)

describe("submodule.truncate", function()
    it("keeps the newest N and reports the dropped middle", function()
        local commits = { "a", "b", "c", "d", "e" } -- newest-first
        local kept, dropped = submodule.truncate(commits, 2)
        assert.same({ "a", "b" }, kept) -- the pointer head (index 1) is always kept
        assert.equals(3, dropped)
    end)

    it("keeps everything when the budget covers the list", function()
        local kept, dropped = submodule.truncate({ "a", "b" }, 5)
        assert.same({ "a", "b" }, kept)
        assert.equals(0, dropped)
    end)

    it("handles an empty list and a zero budget", function()
        local kept, dropped = submodule.truncate({}, 4)
        assert.same({}, kept)
        assert.equals(0, dropped)
        kept, dropped = submodule.truncate({ "a", "b" }, 0)
        assert.same({}, kept)
        assert.equals(2, dropped)
    end)
end)
