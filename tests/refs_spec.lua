--- Tests for gitloom.graph classify_ref — full refname → (kind, name) —
--- and group_refs — collapsing branch refs that share a short name for display.

local internal = require("gitloom.graph")._internal
local classify_ref = internal.classify_ref
local group_refs = internal.group_refs

describe("classify_ref", function()
    it("classifies a local branch", function()
        local kind, name = classify_ref("refs/heads/master")
        assert.equals("local", kind)
        assert.equals("master", name)
    end)

    it("keeps the slashes in a local branch name", function()
        local kind, name = classify_ref("refs/heads/feature/lane-model")
        assert.equals("local", kind)
        assert.equals("feature/lane-model", name)
    end)

    it("classifies a remote branch, keeping the remote prefix", function()
        local kind, name = classify_ref("refs/remotes/origin/master")
        assert.equals("remote", kind)
        assert.equals("origin/master", name)
    end)

    it("skips a remote's HEAD symref", function()
        assert.is_nil(classify_ref("refs/remotes/origin/HEAD"))
    end)

    it("classifies a tag", function()
        local kind, name = classify_ref("refs/tags/v1.0")
        assert.equals("tag", kind)
        assert.equals("v1.0", name)
    end)

    it("returns nil for refs it doesn't render", function()
        assert.is_nil(classify_ref("refs/stash"))
        assert.is_nil(classify_ref("HEAD"))
    end)
end)

describe("group_refs", function()
    local function ref(kind, name) return { kind = kind, name = name } end

    it("collapses a local branch and its remotes into one group", function()
        local g = group_refs({
            ref("local", "mybranch"),
            ref("remote", "origin/mybranch"),
            ref("remote", "otherremote/mybranch"),
        })
        assert.is_false(g.head)
        assert.equals(1, #g.branches)
        assert.equals("mybranch", g.branches[1].name)
        assert.is_true(g.branches[1].has_local)
        assert.same({ "origin", "otherremote" }, g.branches[1].remotes)
    end)

    it("marks a remote-only group as not local", function()
        local g = group_refs({
            ref("remote", "origin/feature"),
            ref("remote", "fork/feature"),
        })
        assert.equals(1, #g.branches)
        assert.is_false(g.branches[1].has_local)
        assert.same({ "origin", "fork" }, g.branches[1].remotes)
    end)

    it("keeps a slashed branch name, splitting only the remote", function()
        local g = group_refs({ ref("remote", "origin/feature/foo") })
        assert.equals("feature/foo", g.branches[1].name)
        assert.same({ "origin" }, g.branches[1].remotes)
    end)

    it("keeps branches with different names in separate groups", function()
        local g = group_refs({
            ref("local", "main"),
            ref("remote", "origin/dev"),
        })
        assert.equals(2, #g.branches)
        assert.equals("main", g.branches[1].name)
        assert.equals("dev", g.branches[2].name)
        assert.same({ "origin" }, g.branches[2].remotes)
    end)

    it("separates HEAD and tags from branch groups", function()
        local g = group_refs({
            ref("head", "HEAD"),
            ref("local", "main"),
            ref("tag", "v1.0"),
        })
        assert.is_true(g.head)
        assert.equals(1, #g.branches)
        assert.is_true(g.branches[1].has_local)
        assert.same({}, g.branches[1].remotes)
        assert.same({ "v1.0" }, g.tags)
    end)
end)
