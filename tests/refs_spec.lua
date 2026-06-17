--- Tests for gitloom.graph classify_ref — full refname → (kind, name).

local classify_ref = require("gitloom.graph")._internal.classify_ref

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
