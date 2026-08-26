--- Tests for the repository picker's discovery core (specification.md §2.1) —
--- the pure pieces that let `<leader>wG` list the main module plus its direct
--- submodules for **one** `git ls-files --stage` spawn plus one `git log -1` per
--- row, instead of `git submodule status` (whose cost is linear in the submodule
--- count) plus two spawns per row:
---
---   `submodule.parse_gitlinks`   — the index's 160000 entries → one entry per
---                                  direct submodule (the path set
---                                  `git submodule status` walks),
---   `submodule.submodule_state`  — that entry + what is on disk → the same four
---                                  checkout states git reports,
---   `parse.parse_gitdir`         — a submodule's `.git` *file* pointer,
---   `parse.parse_head`           — `HEAD`: attached branch vs detached hash,
---   `parse.packed_ref`           — a refname's hash out of `packed-refs`,
---   `parse.parse_summary`        — `git log -1 --format=%h%x1f%s%x1f%D`, whose
---                                  `%D` carries the branch so it needs no
---                                  second spawn.
---
--- The filesystem reads that feed these (git/fetch.lua's `git_dir`/`head_info`)
--- and the async picker orchestration in window.lua are I/O glue and are not
--- unit-tested, like the rest of the glue.

local submodule = require("gitloom.submodule")
local parse = require("gitloom.git.parse")

-- A 40-hex hash from a single seed character (readable in assertions).
local function H(ch) return string.rep(ch, 40) end

-- One `git ls-files --stage` line.
local function ls(mode, sha, stage, path)
    return ("%s %s %d\t%s"):format(mode, sha, stage, path)
end

describe("submodule.parse_gitlinks", function()
    it("keeps the 160000 gitlinks and skips ordinary files", function()
        local subs = submodule.parse_gitlinks({
            ls("100644", H("a"), 0, "README.md"),
            ls("160000", H("b"), 0, "libs/one"),
            ls("100755", H("c"), 0, "scripts/build.sh"),
            ls("160000", H("d"), 0, "libs/two"),
            ls("120000", H("e"), 0, "link"),
        })
        assert.equals(2, #subs)
        assert.same({ name = "libs/one", path = "libs/one", sha = H("b"), conflict = false }, subs[1])
        assert.same({ name = "libs/two", path = "libs/two", sha = H("d"), conflict = false }, subs[2])
    end)

    it("keeps index order", function()
        local subs = submodule.parse_gitlinks({
            ls("160000", H("1"), 0, "z"),
            ls("160000", H("2"), 0, "a"),
            ls("160000", H("3"), 0, "m"),
        })
        assert.same({ "z", "a", "m" }, { subs[1].path, subs[2].path, subs[3].path })
    end)

    it("reports a path with spaces", function()
        local subs = submodule.parse_gitlinks({ ls("160000", H("f"), 0, "vendor/some lib") })
        assert.equals("vendor/some lib", subs[1].path)
    end)

    it("collapses a conflicted gitlink's stages into one flagged entry", function()
        -- An unmerged path has no stage 0: base (1), ours (2), theirs (3).
        local subs = submodule.parse_gitlinks({
            ls("160000", H("1"), 1, "libs/x"),
            ls("160000", H("2"), 2, "libs/x"),
            ls("160000", H("3"), 3, "libs/x"),
        })
        assert.equals(1, #subs)
        assert.is_true(subs[1].conflict)
        -- "Ours" is the best available object name when there is no stage 0.
        assert.equals(H("2"), subs[1].sha)
    end)

    it("prefers the resolved stage-0 object name whatever the line order", function()
        local subs = submodule.parse_gitlinks({
            ls("160000", H("3"), 3, "libs/x"),
            ls("160000", H("0"), 0, "libs/x"),
        })
        assert.equals(1, #subs)
        assert.equals(H("0"), subs[1].sha)
    end)

    it("ignores blank and malformed lines", function()
        local subs = submodule.parse_gitlinks({
            "",
            "not an ls-files line",
            "160000 nothex 0\tlibs/bad",
            ls("160000", H("e"), 0, "libs/good"),
        })
        assert.equals(1, #subs)
        assert.equals("libs/good", subs[1].path)
    end)

    it("returns an empty list for no submodules (empty / nil input)", function()
        assert.same({}, submodule.parse_gitlinks({}))
        assert.same({}, submodule.parse_gitlinks(nil))
    end)
end)

describe("submodule.submodule_state", function()
    it("is uninitialized without a local repository — whatever else is true", function()
        assert.equals("uninitialized", submodule.submodule_state(H("a"), { gitdir = false }))
        -- Nothing to open outranks the conflict flag: `checked_out` is the one
        -- distinction the picker acts on.
        assert.equals("uninitialized",
            submodule.submodule_state(H("a"), { gitdir = false, conflict = true }))
    end)

    it("is ok when checked out at the recorded commit", function()
        assert.equals("ok", submodule.submodule_state(H("a"), { gitdir = true, head = H("a") }))
    end)

    it("is modified when checked out at a different commit", function()
        assert.equals("modified", submodule.submodule_state(H("a"), { gitdir = true, head = H("b") }))
    end)

    it("is conflict for an unmerged gitlink", function()
        assert.equals("conflict",
            submodule.submodule_state(H("a"), { gitdir = true, head = H("b"), conflict = true }))
    end)

    it("degrades to ok when the checked-out commit is unknown", function()
        -- An unreadable HEAD must leave the row openable rather than guess.
        assert.equals("ok", submodule.submodule_state(H("a"), { gitdir = true }))
    end)

    it("tolerates a missing probe", function()
        assert.equals("uninitialized", submodule.submodule_state(H("a"), nil))
    end)
end)

describe("parse.parse_gitdir", function()
    it("reads a relative gitdir pointer", function()
        assert.equals("../../.git/modules/libs/one",
            parse.parse_gitdir("gitdir: ../../.git/modules/libs/one"))
    end)

    it("reads an absolute (Windows) gitdir pointer and trims the line end", function()
        assert.equals("C:/src/super/.git/modules/x",
            parse.parse_gitdir("gitdir: C:/src/super/.git/modules/x   "))
    end)

    it("is nil for anything that is not a gitdir line", function()
        assert.is_nil(parse.parse_gitdir("ref: refs/heads/main"))
        assert.is_nil(parse.parse_gitdir("gitdir:   "))
        assert.is_nil(parse.parse_gitdir(""))
        assert.is_nil(parse.parse_gitdir(nil))
    end)
end)

describe("parse.parse_head", function()
    it("reads an attached HEAD's branch and full ref", function()
        local h = parse.parse_head("ref: refs/heads/feature/pick")
        assert.equals("feature/pick", h.branch)
        assert.equals("refs/heads/feature/pick", h.ref)
        assert.is_nil(h.hash)
    end)

    it("reports no branch for a symref outside refs/heads", function()
        local h = parse.parse_head("ref: refs/remotes/origin/main")
        assert.equals("", h.branch)
        assert.equals("refs/remotes/origin/main", h.ref)
    end)

    it("reads a detached HEAD's hash and reports no branch", function()
        local h = parse.parse_head(H("a"))
        assert.equals("", h.branch)
        assert.equals(H("a"), h.hash)
        assert.is_nil(h.ref)
    end)

    it("tolerates surrounding whitespace / a trailing CR", function()
        assert.equals("main", parse.parse_head("ref: refs/heads/main\r").branch)
        assert.equals(H("b"), parse.parse_head("  " .. H("b") .. "  ").hash)
    end)

    it("yields neither branch nor hash for an unreadable HEAD", function()
        for _, bad in ipairs({ "", "garbage", "abc" }) do
            local h = parse.parse_head(bad)
            assert.equals("", h.branch)
            assert.is_nil(h.hash)
            assert.is_nil(h.ref)
        end
        assert.equals("", parse.parse_head(nil).branch)
    end)
end)

describe("parse.packed_ref", function()
    local packed = {
        "# pack-refs with: peeled fully-peeled sorted",
        H("a") .. " refs/heads/main",
        H("b") .. " refs/heads/dev",
        H("c") .. " refs/tags/v1",
        "^" .. H("d"),
    }

    it("finds a branch by its full refname", function()
        assert.equals(H("a"), parse.packed_ref(packed, "refs/heads/main"))
        assert.equals(H("b"), parse.packed_ref(packed, "refs/heads/dev"))
    end)

    it("does not match a peel line or the header", function()
        -- The `^<hash>` peel belongs to the tag above it, not to any refname.
        assert.equals(H("c"), parse.packed_ref(packed, "refs/tags/v1"))
        assert.is_nil(parse.packed_ref(packed, "^" .. H("d")))
    end)

    it("is nil for an absent ref, an empty file or a nil ref", function()
        assert.is_nil(parse.packed_ref(packed, "refs/heads/nope"))
        assert.is_nil(parse.packed_ref({}, "refs/heads/main"))
        assert.is_nil(parse.packed_ref(nil, "refs/heads/main"))
        assert.is_nil(parse.packed_ref(packed, nil))
    end)
end)

describe("parse.parse_summary", function()
    it("splits the short hash, subject and branch", function()
        local s = parse.parse_summary("a1b2c3d\x1fFix the thing\x1fHEAD -> main, origin/main")
        assert.equals("a1b2c3d", s.short)
        assert.equals("Fix the thing", s.subject)
        assert.equals("main", s.branch)
    end)

    it("reports no branch for a detached HEAD, even beside coinciding refs", function()
        -- `%D` only writes the `HEAD -> x` arrow when HEAD is attached; a branch
        -- that merely points at the same commit is listed without it.
        local s = parse.parse_summary("a1b2c3d\x1fSubject\x1fHEAD, tag: v1, main")
        assert.equals("", s.branch)
        assert.equals("a1b2c3d", s.short)
    end)

    it("reports no branch when the commit carries no decoration at all", function()
        assert.equals("", parse.parse_summary("a1b2c3d\x1fSubject\x1f").branch)
        assert.equals("Subject", parse.parse_summary("a1b2c3d\x1fSubject\x1f").subject)
    end)

    it("keeps a subject containing the field separator's neighbours", function()
        local s = parse.parse_summary("a1b2c3d\x1fmerge: take theirs -> ours\x1fHEAD -> dev")
        assert.equals("merge: take theirs -> ours", s.subject)
        assert.equals("dev", s.branch)
    end)

    it("yields empty fields for an empty repository (no HEAD commit)", function()
        for _, empty in ipairs({ "", nil }) do
            local s = parse.parse_summary(empty)
            assert.equals("", s.short)
            assert.equals("", s.subject)
            assert.equals("", s.branch)
        end
    end)
end)
