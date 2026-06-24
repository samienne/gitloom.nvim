--- Tests for gitloom.graph classify_ref — full refname → (kind, name) —
--- and group_refs — collapsing branch refs that share a short name for display.

local internal = require("gitloom.graph")._internal
local classify_ref = internal.classify_ref
local group_refs = internal.group_refs
local owners_from_refs = internal.owners_from_refs
local next_mode = internal.next_mode
local selected_owner_ids = internal.selected_owner_ids
local collapse_owners = internal.collapse_owners

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

describe("pane_labels (header/footer §6.2)", function()
    local pane_labels = internal.pane_labels
    local function ref(kind, name) return { kind = kind, name = name } end

    it("shows ONLY HEAD, dropping the branch HEAD points at on the same commit", function()
        -- The report: HEAD points at `enne/backport-cmake-fixes`, both on the same commit.
        -- HEAD already represents that branch, so the pane shows just HEAD — not the branch
        -- (passed as head_branch = repo.head) that merely co-locates with it.
        local labels = pane_labels({ refs = {
            ref("local", "enne/backport-cmake-fixes"),
            ref("head", "HEAD"),
        } }, "enne/backport-cmake-fixes")
        assert.same({ "HEAD" }, labels)
    end)

    it("also drops the HEAD branch's remote-tracking ref", function()
        local labels = pane_labels({ refs = {
            ref("local", "feat"),
            ref("remote", "origin/feat"),
            ref("head", "HEAD"),
        } }, "feat")
        assert.same({ "HEAD" }, labels)
    end)

    it("keeps ANOTHER pinned anchor on HEAD's commit, dropping only the HEAD branch", function()
        -- HEAD is on `feat`, but pinned `release` also lands here — show both HEAD and the
        -- other anchor; only the HEAD branch itself is suppressed.
        local labels = pane_labels({ refs = {
            ref("local", "feat"),
            ref("local", "release"),
            ref("head", "HEAD"),
        } }, "feat")
        assert.same({ "HEAD", "(release)" }, labels)
    end)

    it("shows a detached HEAD as HEAD even with no branch on the commit", function()
        local labels = pane_labels({ refs = { ref("head", "HEAD") } }, nil)
        assert.same({ "HEAD" }, labels)
    end)

    it("omits HEAD when the commit has no HEAD marker (just branches/tags)", function()
        local labels = pane_labels({ refs = { ref("local", "feat"), ref("tag", "v1.0") } })
        assert.same({ "(feat)", "[v1.0]" }, labels) -- identical to decoration_texts
    end)
end)

describe("owners_from_refs", function()
    -- The view builder's owner list (spec §10): one owner per ref, keyed by ref
    -- name, carrying its current mode; the HEAD symref is skipped.
    local function refs(spec)
        local out = {}
        for name, r in pairs(spec) do
            out[name] = { name = name, kind = r.kind, commit = { hash = r.hash } }
        end
        return out
    end

    it("emits one owner per ref, defaulting to normal", function()
        local owners = owners_from_refs(refs({
            main = { kind = "local", hash = "a" },
            ["origin/main"] = { kind = "remote", hash = "a" },
        }), {})
        assert.equals(2, #owners)
        local by_id = {}
        for _, o in ipairs(owners) do by_id[o.id] = o end
        assert.equals("a", by_id.main.tip.hash)
        assert.equals("normal", by_id.main.mode)
        assert.equals("normal", by_id["origin/main"].mode)
    end)

    it("applies the mode keyed by ref name", function()
        local owners = owners_from_refs(refs({
            feat = { kind = "local", hash = "f" },
            main = { kind = "local", hash = "m" },
        }), { feat = "collapsed" })
        local mode = {}
        for _, o in ipairs(owners) do mode[o.id] = o.mode end
        assert.equals("collapsed", mode.feat)
        assert.equals("normal", mode.main)
    end)

    it("skips the HEAD marker (it is a symref onto a branch already present)", function()
        local owners = owners_from_refs(refs({
            HEAD = { kind = "head", hash = "m" },
            main = { kind = "local", hash = "m" },
        }), {})
        assert.equals(1, #owners)
        assert.equals("main", owners[1].id)
    end)
end)

describe("branch-mode toggle helpers", function()
    local function commit(spec)
        local out = {}
        for _, r in ipairs(spec) do out[#out + 1] = { kind = r[1], name = r[2] } end
        return { refs = out }
    end

    it("next_mode cycles normal → collapsed → hidden → normal", function()
        assert.equals("collapsed", next_mode(nil))
        assert.equals("collapsed", next_mode("normal"))
        assert.equals("hidden", next_mode("collapsed"))
        assert.equals("normal", next_mode("hidden"))
    end)

    it("selected_owner_ids maps a branch group to its local + remote owners", function()
        local c = commit({ { "local", "main" }, { "remote", "origin/main" } })
        assert.same({ "main", "origin/main" }, selected_owner_ids(c, 1))
    end)

    it("selected_owner_ids maps a remote-only group to its remote owner", function()
        local c = commit({ { "remote", "origin/feature" } })
        assert.same({ "origin/feature" }, selected_owner_ids(c, 1))
    end)

    it("selected_owner_ids maps a tag decoration (after the branches)", function()
        local c = commit({ { "local", "main" }, { "tag", "v1.0" } })
        assert.same({ "v1.0" }, selected_owner_ids(c, 2))
    end)

    it("selected_owner_ids is nil out of range", function()
        assert.is_nil(selected_owner_ids(commit({ { "local", "main" } }), 5))
    end)

    it("collapse_owners returns nil for a mainline commit (an anchor reaches it)", function()
        assert.is_nil(collapse_owners({ trunk = true, feat = true }, { trunk = true },
            { trunk = "normal", feat = "normal" }))
    end)

    it("collapse_owners returns the non-anchor normal owners off the mainline", function()
        -- feat is normal (keeps it visible); the merge owner is already collapsed
        assert.same({ "feat" }, collapse_owners({ feat = true, ["merge:m:2"] = true }, { trunk = true },
            { feat = "normal", ["merge:m:2"] = "collapsed" }))
    end)

    it("collapse_owners is nil when nothing normal keeps the commit visible", function()
        assert.is_nil(collapse_owners({ feat = true }, { trunk = true }, { feat = "collapsed" }))
    end)

    it("collapse_owners treats every pinned anchor as mainline (§10.6)", function()
        -- two anchors; a commit reached by either is mainline (not collapsible),
        -- even if a non-anchor ref also reaches it.
        assert.is_nil(collapse_owners({ dev = true, feat = true }, { trunk = true, dev = true },
            { dev = "normal", feat = "normal" }))
        -- off both anchors: feat alone keeps it visible, so it is collapsible.
        assert.same({ "feat" }, collapse_owners({ feat = true }, { trunk = true, dev = true },
            { feat = "normal" }))
    end)
end)
