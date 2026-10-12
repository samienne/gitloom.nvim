--- Tests for the `%` local ⇄ remote branch cycle (spec §2): the pure pieces
--- `ref_cycle_members` (the ordered cycle of a short name), `ref_cycle_next` (the
--- step from the current ref, wrapping round, stepping past hidden members, with
--- the refusal reasons), `visible_hashes` (what a jump can land on) and
--- `cycle_source` (the row's source ref). The window glue (`GRAPH_HELPERS.ref_cycle`
--- — the jump, the grouped-member memory, the notices) is untested like the rest.

local internal = require("gitloom.graph")._internal
local members_of = internal.ref_cycle_members
local next_of = internal.ref_cycle_next
local cycle_source = internal.cycle_source
local visible_hashes = internal.visible_hashes

local A, B, C = ("a"):rep(40), ("b"):rep(40), ("c"):rep(40)

-- A ref registry from { name, kind, hash } triples (the Refs point at stub commits).
local function registry(list)
    local refs = {}
    for _, t in ipairs(list) do
        refs[t[1]] = { name = t[1], kind = t[2], commit = { hash = t[3], refs = {} } }
    end
    return refs
end

local function names(ms)
    local out = {}
    for _, m in ipairs(ms) do out[#out + 1] = m.name end
    return out
end

-- dev local, on origin and upstream (both remotes); origin/dev on dev's commit.
local refs = registry({
    { "dev", "local", A }, { "origin/dev", "remote", A }, { "upstream/dev", "remote", B },
    { "fork/dev", "remote", C }, { "main", "local", A }, { "origin/solo", "remote", B },
    { "upstream/solo", "remote", C }, { "lonely", "local", B }, { "v1", "tag", A },
    { "wt:x", "worktree", B }, { "HEAD", "head", A },
})

describe("ref_cycle_members (§2)", function()
    it("orders local first, then remotes in `git remote` order, then unlisted remotes by name", function()
        assert.same({ "dev", "upstream/dev", "origin/dev", "fork/dev" },
            names(members_of(refs, { "upstream", "origin" }, "dev")))
        assert.same({ "dev", "origin/dev", "upstream/dev", "fork/dev" },
            names(members_of(refs, { "origin", "upstream" }, "dev")))
    end)

    it("falls back to registry order by name when the remote list has not loaded", function()
        assert.same({ "dev", "fork/dev", "origin/dev", "upstream/dev" }, names(members_of(refs, nil, "dev")))
    end)

    it("includes members on the same commit, carrying each one's hash", function()
        local ms = members_of(refs, { "origin" }, "dev")
        assert.equals(A, ms[1].hash)
        assert.equals("origin/dev", ms[2].name)
        assert.equals(A, ms[2].hash)
        assert.equals("remote", ms[2].kind)
    end)

    it("lists only refs that exist (a remote without the branch is skipped)", function()
        assert.same({ "origin/solo", "upstream/solo" },
            names(members_of(refs, { "origin", "fork", "upstream" }, "solo")))
    end)

    it("is empty for nothing / a tag name", function()
        assert.same({}, members_of(refs, { "origin" }, "nope"))
        assert.same({}, members_of(refs, { "origin" }, "v1"))
        assert.same({}, members_of(nil, { "origin" }, "dev"))
    end)
end)

describe("ref_cycle_next (§2)", function()
    local remotes = { "origin", "upstream", "fork" }

    it("steps local → each remote in order → back to local", function()
        local seq, cur = {}, "dev"
        for _ = 1, 4 do
            local n = assert(next_of(refs, remotes, cur))
            seq[#seq + 1] = n.name
            cur = n.name
        end
        assert.same({ "origin/dev", "upstream/dev", "fork/dev", "dev" }, seq)
    end)

    it("starts from a remote", function()
        local n, ms, short = next_of(refs, remotes, "upstream/dev")
        assert(n)
        assert.equals("fork/dev", n.name)
        assert.equals(4, #ms)
        assert.equals("dev", short)
        assert.equals("dev", (next_of(refs, remotes, "fork/dev")).name) -- wraps
    end)

    it("cycles a remote-only branch among its remotes", function()
        assert.equals("upstream/solo", (next_of(refs, remotes, "origin/solo")).name)
        assert.equals("origin/solo", (next_of(refs, remotes, "upstream/solo")).name)
    end)

    it("reports `alone` with the short name when there is no counterpart", function()
        local n, why, short = next_of(refs, remotes, "lonely")
        assert.is_nil(n)
        assert.equals("alone", why)
        assert.equals("lonely", short)
        assert.equals("alone", select(2, next_of(refs, remotes, "main")))
    end)

    it("refuses a tag, a worktree, HEAD or an unknown ref with `none`", function()
        for _, name in ipairs({ "v1", "wt:x", "HEAD", "missing" }) do
            local n, why = next_of(refs, remotes, name)
            assert.is_nil(n, name)
            assert.equals("none", why, name)
        end
        assert.equals("none", select(2, next_of(refs, remotes, nil)))
    end)
end)

describe("cycle_source (§2)", function()
    local function commit(list) return { hash = A, refs = list } end

    it("takes the h/l-selected decoration (a group stands for its local branch)", function()
        local c = commit({ { kind = "local", name = "main" }, { kind = "local", name = "dev" },
            { kind = "remote", name = "origin/dev" }, { kind = "tag", name = "v1" } })
        assert.same("dev", cycle_source(c, 2).name)
        assert.same("tag", cycle_source(c, 3).kind) -- returned as is; ref_cycle_next refuses it
    end)

    it("defaults to the first branch label, HEAD's branch first", function()
        local c = commit({ { kind = "local", name = "aaa" }, { kind = "remote", name = "origin/dev" },
            { kind = "head", name = "HEAD", branch = "dev" } })
        local s = assert(cycle_source(c, nil))
        assert.equals("remote", s.kind) -- dev has no local here: its first remote
        assert.equals("origin/dev", s.name)
        local c2 = commit({ { kind = "remote", name = "origin/x" }, { kind = "local", name = "y" } })
        assert.equals("origin/x", cycle_source(c2, nil).name)
    end)

    it("is nil on a tag-, worktree-, detached-HEAD-only or ref-less row", function()
        assert.is_nil(cycle_source(commit({ { kind = "tag", name = "v1" } }), nil))
        assert.is_nil(cycle_source(commit({ { kind = "worktree", name = "wt:x" } }), nil))
        assert.is_nil(cycle_source(commit({ { kind = "head", name = "HEAD" } }), nil))
        assert.is_nil(cycle_source(commit({}), nil))
        assert.is_nil(cycle_source(nil, nil))
    end)
end)

describe("visible_hashes (§2)", function()
    it("collects row commits, collapsed regions and packed markers with their regions", function()
        local display = {
            { type = "commit", commit = { hash = "c1" } },
            { type = "commit", commit = { hash = "collapsed:x", collapsed = true, region = { "r1", "r2" } } },
            { type = "markers", markers = { { hash = "m1", region = { "m1", "r3" } }, { hash = "m2" } } },
            { type = "commit", commit = { hash = "j1", junction = true, region = { "nope" } } },
        }
        local v = visible_hashes(display)
        for _, h in ipairs({ "c1", "collapsed:x", "r1", "r2", "m1", "r3", "m2", "j1" }) do
            assert.is_true(v[h], h)
        end
        assert.is_nil(v.nope) -- only a collapsed head's region is folded in
        assert.same({}, visible_hashes(nil))
    end)
end)

describe("ref_cycle_next past hidden refs (§2)", function()
    local remotes = { "origin", "upstream", "fork" }

    it("steps past a member whose commit is not visible", function()
        local vis = { [A] = true, [C] = true } -- upstream/dev (on B) hidden
        assert.equals("fork/dev", (next_of(refs, remotes, "origin/dev", vis)).name)
        assert.equals("dev", (next_of(refs, remotes, "fork/dev", vis)).name)
        assert.equals("origin/dev", (next_of(refs, remotes, "dev", vis)).name)
    end)

    it("wraps round past hidden members, and keeps the full member list", function()
        local vis = { [A] = true } -- only dev + origin/dev visible
        local n, ms = next_of(refs, remotes, "origin/dev", vis)
        assert(n)
        assert.equals("dev", n.name)
        assert.equals(4, #ms)
    end)

    it("reports `hidden` with the short name when no other member is visible", function()
        local n, why, short = next_of(refs, remotes, "origin/solo", { [B] = true })
        assert.is_nil(n)
        assert.equals("hidden", why)
        assert.equals("solo", short)
        -- a member on the current ref's own (visible) commit is still a step
        assert.equals("origin/dev", (next_of(refs, remotes, "dev", { [A] = true })).name)
        -- `alone` still wins when there is no counterpart at all
        assert.equals("alone", select(2, next_of(refs, remotes, "lonely", {})))
    end)

    it("nil visibility = everything visible", function()
        assert.equals("upstream/dev", (next_of(refs, remotes, "origin/dev", nil)).name)
    end)
end)
