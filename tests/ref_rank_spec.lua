--- Tests for ranked refs and identities (spec §5 "Ranked refs and identities"):
--- the pure identity pairing (`rank.pair`) and the total rank order
--- (`rank.infos` + `rank.better` / `rank.order`, `rank.generated`).

local rank = require("gitloom.graph.rank")

--- A ref registry from shorthand: "name" = local, "r:origin/x" = remote,
--- "t:v1" = tag, "name>origin/up" = local tracking `origin/up`.
local function registry(...)
    local out = {}
    for _, s in ipairs({ ... }) do
        local kind, rest = s:match("^(%a):(.+)$")
        if kind == "r" then
            out[rest] = { name = rest, kind = "remote" }
        elseif kind == "t" then
            out[rest] = { name = rest, kind = "tag" }
        else
            local name, up = s:match("^(.-)>(.+)$")
            name = name or s
            out[name] = { name = name, kind = "local", upstream = up and { short = up } or nil }
        end
    end
    return out
end

local function pins(...)
    local out = {}
    for _, id in ipairs({ ... }) do out[#out + 1] = { id = id } end
    return out
end

local REMOTES = { "origin", "fork" }

local function members(p, name) return p.of[name] and p.of[name].members end

describe("rank.pair (§5 identities)", function()
    it("pairs a local with same-named remotes on every remote", function()
        local p = rank.pair(registry("foo", "r:origin/foo", "r:fork/foo"), { remotes = REMOTES })
        assert.same({ "foo", "fork/foo", "origin/foo" }, members(p, "foo"))
        assert.equal(p.of["foo"], p.of["origin/foo"])
        assert.equal(p.of["foo"], p.of["fork/foo"])
        assert.is_nil(p.of["foo"].upstream)
    end)

    it("pairs a configured upstream with a different name", function()
        local p = rank.pair(registry("feat>origin/dev", "r:origin/dev", "r:origin/feat"),
            { remotes = REMOTES })
        assert.same({ "feat", "origin/dev", "origin/feat" }, members(p, "feat"))
        assert.equal("origin/dev", p.of["feat"].upstream)
    end)

    it("ignores a local upstream (not a remote-tracking branch)", function()
        local p = rank.pair(registry("a>b", "b"), { remotes = REMOTES })
        assert.same({ "a" }, members(p, "a"))
        assert.same({ "b" }, members(p, "b"))
    end)

    it("gives a remote claimed by several locals to the same-named local", function()
        local p = rank.pair(registry("main", "feat>origin/main", "r:origin/main"), { remotes = REMOTES })
        assert.same({ "main", "origin/main" }, members(p, "main"))
        assert.same({ "feat" }, members(p, "feat"))
        assert.is_nil(p.of["feat"].upstream)
    end)

    it("otherwise to the first claimer in pin order, then by name", function()
        local reg = registry("a>origin/x", "b>origin/x", "r:origin/x")
        assert.same({ "a", "origin/x" }, members(rank.pair(reg, { remotes = REMOTES }), "a"))
        local p = rank.pair(reg, { remotes = REMOTES, pins = pins("b", "a") })
        assert.same({ "b", "origin/x" }, members(p, "b"))
        assert.same({ "a" }, members(p, "a"))
        assert.equal("origin/x", p.of["b"].upstream)
    end)

    it("groups same-named remote-only branches into one identity", function()
        local p = rank.pair(registry("r:origin/foo", "r:fork/foo", "r:origin/bar"), { remotes = REMOTES })
        local id = p.of["origin/foo"]
        assert.equal(id, p.of["fork/foo"])
        assert.is_nil(id.local_name)
        assert.equal("foo", id.name)
        assert.not_equal(id, p.of["origin/bar"])
    end)

    it("keeps a claimed remote out of the remote-only identity of its short name", function()
        local p = rank.pair(registry("x>origin/foo", "r:origin/foo", "r:fork/foo"), { remotes = REMOTES })
        assert.same({ "x", "origin/foo" }, members(p, "x"))
        assert.same({ "fork/foo" }, members(p, "fork/foo"))
    end)

    it("leaves tags, HEAD, worktrees and <remote>/HEAD unranked", function()
        local reg = registry("main", "t:v1", "r:origin/HEAD", "r:origin/main")
        reg.HEAD = { name = "HEAD", kind = "head" }
        reg["wt:x"] = { name = "wt:x", kind = "worktree" }
        local p = rank.pair(reg, { remotes = REMOTES })
        assert.is_nil(p.of["v1"])
        assert.is_nil(p.of["HEAD"])
        assert.is_nil(p.of["wt:x"])
        assert.is_nil(p.of["origin/HEAD"])
        assert.same({ "main", "origin/main" }, members(p, "main"))
    end)

    it("splits remote names on the longest known remote", function()
        local p = rank.pair(registry("x", "r:my/fork/x"), { remotes = { "my/fork" } })
        assert.same({ "x", "my/fork/x" }, members(p, "x"))
    end)

    it("accepts an array of refs", function()
        local p = rank.pair({ { name = "foo", kind = "local" }, { name = "origin/foo", kind = "remote" } })
        assert.same({ "foo", "origin/foo" }, members(p, "foo"))
    end)
end)

describe("rank order (§5 rank)", function()
    --- The order of the visible ranked refs.
    local function order(reg, rows, o)
        o = o or {}
        local p = rank.pair(reg, { remotes = REMOTES, pins = o.pins })
        local infos = rank.infos(p, {
            visible = o.visible, pins = o.pins, current = o.current, remotes = REMOTES,
        })
        return rank.order(infos, rows), infos
    end

    it("ranks pinned > unpinned with a local > remote-only", function()
        local reg = registry("a", "p", "r:origin/z")
        -- rows would favour z, then a; the tiers win.
        local got = order(reg, { a = 5, p = 1, ["origin/z"] = 9 }, { pins = pins("p") })
        assert.same({ "p", "a", "origin/z" }, got)
    end)

    it("orders pinned identities by pin rank, regardless of rows", function()
        local got = order(registry("a", "b"), { a = 9, b = 1 }, { pins = pins("b", "a") })
        assert.same({ "b", "a" }, got)
    end)

    it("takes an identity's pin rank from any member's entry", function()
        local got = order(registry("a", "r:origin/a", "b"), { a = 1, ["origin/a"] = 1, b = 9 },
            { pins = pins("b", "origin/a") })
        assert.same({ "b", "a", "origin/a" }, got)
        got = order(registry("a", "r:origin/a", "b"), { a = 1, ["origin/a"] = 1, b = 9 },
            { pins = pins("origin/a", "b") })
        -- pins first: identity a (pinned via origin/a) above b, its local before its remote
        assert.same({ "a", "origin/a", "b" }, got)
    end)

    it("ranks an identity whose local is not visible as remote-only", function()
        local reg = registry("a", "r:origin/a", "b")
        local got = order(reg, { ["origin/a"] = 9, b = 1 }, { visible = { ["origin/a"] = true, b = true } })
        assert.same({ "b", "origin/a" }, got)
    end)

    it("excludes refs the caller leaves out of visible", function()
        local _, infos = order(registry("a", "b", "t:v1"), { a = 1, b = 2 }, { visible = { a = true } })
        assert.is_not_nil(infos.a)
        assert.is_nil(infos.b)
        assert.is_nil(infos.v1)
    end)

    it("within an unpinned tier, the lower standing row wins", function()
        assert.same({ "base", "topic" }, order(registry("topic", "base"), { topic = 1, base = 4 }))
        assert.same({ "origin/y", "origin/x" },
            order(registry("r:origin/x", "r:origin/y"), { ["origin/x"] = 2, ["origin/y"] = 3 }))
    end)

    it("a remote whose local is at or above it stands at the local's row", function()
        -- origin/a (row 8) stands at a's row 2, so b (row 5) beats it.
        local got = order(registry("a", "r:origin/a", "b"), { a = 2, ["origin/a"] = 8, b = 5 })
        assert.same({ "b", "a", "origin/a" }, got)
        -- A remote above its local stands at its own row.
        got = order(registry("a", "r:origin/a", "b"), { a = 8, ["origin/a"] = 2, b = 5 })
        assert.same({ "a", "b", "origin/a" }, got)
    end)

    it("the local outranks its remotes in every tier", function()
        local reg = registry("a", "r:origin/a")
        local rows = { a = 3, ["origin/a"] = 3 }
        assert.same({ "a", "origin/a" }, order(reg, rows))
        assert.same({ "a", "origin/a" }, order(reg, { a = 1, ["origin/a"] = 7 }, { pins = pins("a") }))
    end)

    it("orders remotes by standing row, then upstream, then git remote order", function()
        local reg = registry("a>fork/a", "r:origin/a", "r:fork/a", "r:zz/a")
        -- All at or below the local: all stand at its row; upstream first, then
        -- `git remote` order, unknown remotes last.
        local got = order(reg, { a = 1, ["origin/a"] = 2, ["fork/a"] = 3, ["zz/a"] = 2 })
        assert.same({ "a", "fork/a", "origin/a", "zz/a" }, got)
        -- Above the local, the lower one wins first.
        got = order(reg, { a = 9, ["origin/a"] = 5, ["fork/a"] = 2, ["zz/a"] = 9 })
        assert.same({ "a", "zz/a", "origin/a", "fork/a" }, got)
    end)

    it("orders a remote-only identity by row, then git remote order", function()
        local reg = registry("r:origin/f", "r:fork/f")
        assert.same({ "origin/f", "fork/f" }, order(reg, { ["origin/f"] = 4, ["fork/f"] = 4 }))
        assert.same({ "fork/f", "origin/f" }, order(reg, { ["origin/f"] = 4, ["fork/f"] = 6 }))
    end)

    it("breaks a tie between identities by current branch, then name", function()
        local reg = registry("b", "a")
        assert.same({ "a", "b" }, order(reg, { a = 3, b = 3 }))
        assert.same({ "b", "a" }, order(reg, { a = 3, b = 3 }, { current = "b" }))
        -- The current branch's identity includes its remotes.
        local reg2 = registry("b", "r:origin/b", "a")
        assert.same({ "a", "b", "origin/b" }, order(reg2, { a = 3, b = 1, ["origin/b"] = 3 }))
        assert.same({ "b", "a", "origin/b" },
            order(reg2, { a = 3, b = 3, ["origin/b"] = 3 }, { current = "b" }))
    end)

    it("ranks generated refs last, the first created winning", function()
        local p = rank.pair(registry("a", "r:origin/z"))
        local infos = rank.infos(p)
        local rows = { a = 1, ["origin/z"] = 1 }
        local g1, g2 = rank.generated(1), rank.generated(2)
        assert.is_true(rank.better(infos["origin/z"], g1, rows))
        assert.is_false(rank.better(g1, infos["a"], rows))
        assert.is_true(rank.better(g1, g2, rows))
        assert.is_false(rank.better(g2, g1, rows))
        assert.is_false(rank.better(g1, g1, rows))
    end)

    it("is a strict total order (antisymmetric) over a mixed set", function()
        local reg = registry("a>origin/x", "b", "r:origin/a", "r:origin/x", "r:fork/b",
            "r:origin/c", "r:fork/c", "main")
        local p = rank.pair(reg, { remotes = REMOTES, pins = pins("main") })
        local infos = rank.infos(p, { pins = pins("main"), current = "b", remotes = REMOTES })
        local rows = { a = 2, b = 2, ["origin/a"] = 4, ["origin/x"] = 1, ["fork/b"] = 2,
            ["origin/c"] = 3, ["fork/c"] = 3, main = 6 }
        local list = {}
        for _, i in pairs(infos) do list[#list + 1] = i end
        list[#list + 1] = rank.generated(1)
        for _, x in ipairs(list) do
            for _, y in ipairs(list) do
                if x ~= y then
                    assert.not_equal(rank.better(x, y, rows), rank.better(y, x, rows))
                end
            end
        end
        -- level 1 (main pinned, then b / a tied on row 2: current first), then level 2:
        -- fork/b and origin/a tie on row 2 (current first), origin/x stands higher
        -- (row 1); then the remote-only identity.
        assert.same({ "main", "b", "a", "fork/b", "origin/a", "origin/x", "origin/c", "fork/c" },
            rank.order(infos, rows))
    end)
end)

describe("brightness levels (§5 'Brightness level')", function()
    local function infos_of(reg, o)
        o = o or {}
        local p = rank.pair(reg, { remotes = REMOTES, pins = o.pins })
        return rank.infos(p, { visible = o.visible, collapsed = o.collapsed, pins = o.pins,
            current = o.current, remotes = REMOTES })
    end

    it("levels: expanded local 1, expanded remote 2, collapsed unpinned 3, pinned never 3", function()
        local reg = registry("a", "r:origin/a", "p", "r:origin/p", "r:origin/z")
        local all = { a = true, ["origin/a"] = true, p = true, ["origin/p"] = true, ["origin/z"] = true }
        local i = infos_of(reg, { pins = pins("p") })
        assert.same({ 1, 2, 1, 2, 2 }, { i.a.level, i["origin/a"].level, i.p.level, i["origin/p"].level,
            i["origin/z"].level })
        i = infos_of(reg, { pins = pins("p"), collapsed = all })
        assert.same({ 3, 3, 1, 2, 3 }, { i.a.level, i["origin/a"].level, i.p.level, i["origin/p"].level,
            i["origin/z"].level })
        assert.is_true(i.a.collapsed)
        assert.equal(4, rank.generated(1).level)
        assert.equal(1, rank.drawn_level(rank.generated(1)))
        assert.equal(3, rank.drawn_level(i.a))
    end)

    it("a pinned identity's remote ranks above every unpinned expanded local", function()
        -- dev pinned, origin/dev ahead of it; feature forked from origin/dev's commits:
        -- pinning comes before brightness, so origin/dev (level 2) outranks feature
        -- (level 1) (§5 "Rank", the dev example).
        local reg = registry("dev", "r:origin/dev", "feature")
        local got = rank.order(infos_of(reg, { pins = pins("dev") }),
            { feature = 1, ["origin/dev"] = 2, dev = 5 })
        assert.same({ "dev", "origin/dev", "feature" }, got)
    end)

    it("a pinned remote-only ref outranks a worse-pinned local and every unpinned one", function()
        -- the owner's case: origin/release (remote-only, level 2) pinned above dev
        local reg = registry("dev", "r:origin/release", "feature")
        local infos = infos_of(reg, { pins = pins("origin/release", "dev") })
        assert.equal(2, infos["origin/release"].level)
        assert.equal(1, infos.dev.level)
        assert.equal(1, infos.feature.level)
        for _, rows in ipairs({
            { ["origin/release"] = 1, dev = 5, feature = 9 },
            { ["origin/release"] = 9, dev = 5, feature = 1 },
        }) do
            assert.same({ "origin/release", "dev", "feature" }, rank.order(infos, rows))
        end
        -- unpinned dev: origin/release still outranks the expanded local
        infos = infos_of(reg, { pins = pins("origin/release") })
        assert.is_true(rank.better(infos["origin/release"], infos.dev, { ["origin/release"] = 1, dev = 9 }))
        assert.is_true(rank.better(infos["origin/release"], infos.feature, { ["origin/release"] = 1, feature = 9 }))
    end)

    it("every expanded or pinned ref outranks every collapsed unpinned one", function()
        local reg = registry("base", "r:origin/base", "top", "r:origin/z")
        -- base stands lowest and would own its commits at one level; collapsed, it
        -- ranks below even the remote-only origin/z.
        local col = { base = true, ["origin/base"] = true }
        local got = rank.order(infos_of(reg, { collapsed = col }),
            { top = 1, ["origin/z"] = 2, base = 9, ["origin/base"] = 9 })
        assert.same({ "top", "origin/z", "base", "origin/base" }, got)
        -- pinning lifts the collapsed identity back to levels 1 and 2
        got = rank.order(infos_of(reg, { collapsed = col, pins = pins("base") }),
            { top = 1, ["origin/z"] = 2, base = 9, ["origin/base"] = 9 })
        assert.same({ "base", "origin/base", "top", "origin/z" }, got)
    end)

    it("at level 3 the local still outranks its own remote", function()
        local reg = registry("a", "r:origin/a")
        local col = { a = true, ["origin/a"] = true }
        assert.same({ "a", "origin/a" },
            rank.order(infos_of(reg, { collapsed = col }), { a = 1, ["origin/a"] = 7 }))
        -- a collapsed local below its expanded remote: the remote is brighter
        assert.same({ "origin/a", "a" },
            rank.order(infos_of(reg, { collapsed = { a = true } }), { a = 7, ["origin/a"] = 1 }))
    end)

    it("pinned refs first by pin rank, brightness wins among unpinned, generated last (fuzz)", function()
        local s = 7
        local function rnd(n) s = (s * 16807) % 2147483647; return s % n end
        for _ = 1, 60 do
            local names, rows, col, pl = {}, {}, {}, {}
            for k = 1, 3 + rnd(6) do
                local n = "x" .. rnd(5)
                if rnd(3) == 0 then n = (rnd(2) == 0 and "origin/" or "fork/") .. n end
                if not rows[n] then
                    names[#names + 1] = n:find("/") and ("r:" .. n) or n
                    rows[n] = rnd(10)
                    if rnd(3) == 0 then col[n] = true end
                    if rnd(4) == 0 then pl[#pl + 1] = n end
                end
                local _ = k
            end
            local infos = infos_of(registry(unpack(names)), { collapsed = col, pins = pins(unpack(pl)),
                current = rnd(2) == 0 and "x1" or nil })
            local list = { rank.generated(1) }
            for _, i in pairs(infos) do list[#list + 1] = i end
            for _, a in ipairs(list) do
                for _, b in ipairs(list) do
                    if a ~= b then
                        local pa, pb = a.pin or math.huge, b.pin or math.huge
                        local expect
                        if b.level == 4 and a.level ~= 4 then expect = true
                        elseif a.level == 4 then expect = nil
                        elseif pa < pb then expect = true
                        elseif pa == math.huge and pb == math.huge and a.level < b.level then expect = true
                        end
                        if expect then
                            assert.is_true(rank.better(a, b, rows), a.name .. " over " .. b.name)
                        end
                        assert.not_equal(rank.better(a, b, rows), rank.better(b, a, rows))
                    end
                end
            end
        end
    end)

    it("packs a slot and a level into one drawn colour", function()
        for _, k in ipairs({ 1, 7, 30 }) do
            for level = 1, 3 do
                local c = rank.drawn(k, level)
                assert.equal(k, rank.slot_of(c))
                assert.equal(level, rank.level_of(c))
            end
        end
        assert.equal(5, rank.drawn(5, 1))
        assert.equal(-5, rank.drawn(5, 2))
        assert.is_true(rank.drawn(5, 3) < 0)
    end)
end)

describe("rank.start_set (§5.5 pending while streaming)", function()
    local reg = registry("a", "b", "r:origin/a", "t:v1")
    it("is every ref under --all (the default)", function()
        assert.is_true(rank.start_set(nil, reg))
        assert.is_true(rank.start_set({ "main", "--all" }, reg))
    end)
    it("names the refs a narrower refspec starts from", function()
        assert.same({ a = true }, rank.start_set({ "a" }, reg))
        assert.same({ a = true, b = true }, rank.start_set({ "--branches" }, reg))
        assert.same({ ["origin/a"] = true, b = true }, rank.start_set({ "--remotes", "refs/heads/b" }, reg))
        assert.same({}, rank.start_set({ "deadbeef", "HEAD~3" }, reg))
    end)
end)
