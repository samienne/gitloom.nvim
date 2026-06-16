--- Tests for gitloom.graph parse_refs — git decorate (%D) parsing.

local parse_refs = require("gitloom.graph")._internal.parse_refs

describe("parse_refs", function()
    it("returns an empty result for an empty string", function()
        local r = parse_refs("")
        assert.same({}, r.branches)
        assert.same({}, r.tags)
        assert.same({}, r.symbols)
        assert.same({}, r.raw)
    end)

    it("parses a plain branch ref", function()
        local r = parse_refs("refs/heads/master")
        assert.equals(1, #r.branches)
        assert.equals("master", r.branches[1].name)
    end)

    it("parses a tag ref", function()
        local r = parse_refs("tag: refs/tags/v1.0")
        assert.equals(1, #r.tags)
        assert.equals("refs/tags/v1.0", r.tags[1].name)
    end)

    it("parses a HEAD symbol and records its target as a branch", function()
        local r = parse_refs("HEAD -> refs/heads/master")
        assert.equals(1, #r.symbols)
        assert.equals("HEAD", r.symbols[1].from)
        assert.equals("refs/heads/master", r.symbols[1].to)
        assert.equals(1, #r.branches)
        assert.equals("refs/heads/master", r.branches[1].name)
    end)

    it("collects unrecognized refs as raw", function()
        local r = parse_refs("refs/remotes/origin/master")
        assert.equals(1, #r.raw)
        assert.equals("refs/remotes/origin/master", r.raw[1])
    end)

    it("parses a full decorate string with mixed refs", function()
        local r = parse_refs(
            "HEAD -> refs/heads/master, refs/heads/dev, tag: refs/tags/v1, refs/remotes/origin/master")
        assert.equals(1, #r.symbols)
        -- master (symbol target) + dev
        assert.equals(2, #r.branches)
        assert.equals(1, #r.tags)
        assert.equals(1, #r.raw)
    end)
end)
