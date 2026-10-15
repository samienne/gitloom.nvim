--- A commit's own owners (spec §10.2) and what `<Space>` / the palette's
--- collapse-expand act on (§10.4): the pure `select.own_owners`,
--- `select.toggle_target` and `select.owner_label`, over real interned signatures
--- from `view.signatures` (the handle-comparison path) and over plain tables of
--- sets (the fallback path).

local view = require("gitloom.graph.view")
local helpers = require("tests.graph_helpers")
local internal = require("gitloom.graph")._internal
local own_owners = internal.own_owners
local toggle_target = internal.toggle_target
local owner_label = internal.owner_label

--- Items, the focus owner set (§10.7) and the owner-id -> tip-hash map for refs
--- `{ id = hash }` with `pinned` anchors and `modes` overrides.
local function build(rows, refs, pinned, modes)
    local items = helpers.dag(rows)
    local by_hash = {}
    for _, it in ipairs(items) do by_hash[it.commit.hash] = it.commit end
    local ref_owners = {}
    for id, h in pairs(refs) do ref_owners[#ref_owners + 1] = { id = id, tip = by_hash[h] } end
    table.sort(ref_owners, function(a, b) return a.id < b.id end)
    local owners = view.owners(items, ref_owners, pinned, modes, true)
    local tip_of, effective = {}, {}
    for _, o in ipairs(owners) do
        tip_of[o.id] = o.tip.hash
        effective[o.id] = o.mode
    end
    return { items = items, owners = owners, sig = view.signatures(items, owners),
        tip_of = tip_of, effective = effective }
end

-- d1 (D) -> a (A, B) -> a1 -> base ; x (main, pinned) -> base.
-- D is built on top of A/B; base is mainline.
local STACK = {
    { "d1", { "a" } }, { "a", { "a1" } }, { "a1", { "base" } },
    { "x", { "base" } }, { "base", {} },
}
local STACK_REFS = { D = "d1", A = "a", B = "a", main = "x" }

describe("own_owners (§10.2)", function()
    it("is the owners whose tip shares the row's signature", function()
        local g = build(STACK, STACK_REFS, { main = true })
        assert.same({ "A", "B" }, own_owners(g.sig, "a", g.tip_of))
        assert.same({ "A", "B" }, own_owners(g.sig, "a1", g.tip_of)) -- a ref-less row in A/B's stretch
        assert.same({ "D" }, own_owners(g.sig, "d1", g.tip_of))
    end)

    it("is empty on a stretch shared below a fork", function()
        -- f1 (F1) and f2 (F2) fork from s; s -> base; x (main) -> base.
        local g = build({
            { "f1", { "s" } }, { "f2", { "s" } }, { "s", { "base" } },
            { "x", { "base" } }, { "base", {} },
        }, { F1 = "f1", F2 = "f2", main = "x" }, { main = true })
        assert.same({}, own_owners(g.sig, "s", g.tip_of))
    end)

    it("agrees on a plain table of sets (the fallback path)", function()
        local sig = { a = { A = true, D = true }, d1 = { D = true } }
        assert.same({ "A" }, own_owners(sig, "a", { A = "a", D = "d1" }))
        assert.same({}, own_owners(sig, "nope", {}))
    end)
end)

describe("toggle_target (§10.4)", function()
    it("collapse on a multi-ref row takes both own refs and keeps a branch built on top", function()
        local g = build(STACK, STACK_REFS, { main = true }, { A = "normal", B = "normal", D = "normal" })
        local t = toggle_target(g.sig, "a", g.tip_of, { main = true }, g.effective, false)
        assert.equals("expanded", t.state)
        assert.same({ "A", "B" }, t.owners)
        assert.same({ "D" }, t.keepers)
    end)

    it("a selected ref does not matter: both refs fold together", function()
        local g = build(STACK, { A = "a", B = "a", main = "x" }, { main = true }, { A = "normal", B = "normal" })
        local t = toggle_target(g.sig, "a", g.tip_of, { main = true }, g.effective, false)
        assert.same({ "A", "B" }, t.owners)
        assert.same({}, t.keepers)
    end)

    it("with the own owners already collapsed there is nothing to collapse, only keepers", function()
        local g = build(STACK, STACK_REFS, { main = true }, { D = "normal" })
        local t = toggle_target(g.sig, "a", g.tip_of, { main = true }, g.effective, false)
        assert.equals("expanded", t.state)
        assert.same({}, t.owners)
        assert.same({ "D" }, t.keepers)
    end)

    it("expanding a ◍ opens only its own owners, never a collapsed branch above", function()
        local g = build(STACK, STACK_REFS, { main = true }) -- D, A, B all collapsed
        local t = toggle_target(g.sig, "a", g.tip_of, { main = true }, g.effective, true)
        assert.equals("collapsed", t.state)
        assert.same({ "A", "B" }, t.owners)
    end)

    it("expanding a shared stretch's ◍ opens every collapsed owner reaching it", function()
        local g = build({
            { "f1", { "s" } }, { "f2", { "s" } }, { "s", { "base" } },
            { "x", { "base" } }, { "base", {} },
        }, { F1 = "f1", F2 = "f2", main = "x" }, { main = true })
        local t = toggle_target(g.sig, "s", g.tip_of, { main = true }, g.effective, true)
        assert.same({ "F1", "F2" }, t.owners)
        -- Collapse there has nothing of its own: it only names the keepers.
        g.effective.F1, g.effective.F2 = "normal", "normal"
        local c = toggle_target(g.sig, "s", g.tip_of, { main = true }, g.effective, false)
        assert.same({}, c.owners)
        assert.same({ "F1", "F2" }, c.keepers)
    end)

    it("a mainline row is not collapsible and names its anchors", function()
        local g = build(STACK, STACK_REFS, { main = true }, { A = "normal" })
        local t = toggle_target(g.sig, "base", g.tip_of, { main = true }, g.effective, false)
        assert.equals("mainline", t.state)
        assert.same({}, t.owners)
        assert.same({ "main" }, t.anchors)
    end)
end)

describe("first-parent-only reach (§10.2/§10.7)", function()
    it("an open mainline does not open what it merged in", function()
        -- m (main, pinned) merges g1 (ref-less feature) into x.
        local g = build({
            { "m", { "x", "g1" } }, { "g1", { "base" } }, { "x", { "base" } }, { "base", {} },
        }, { main = "m" }, { main = true })
        local proj = view.project(g.items, g.owners, g.sig)
        assert.equals("normal", proj.mode.m)
        assert.equals("normal", proj.mode.x)
        assert.equals("collapsed", proj.mode.g1)
    end)

    it("an open feature branch does not open a branch merged into it", function()
        -- dv (dev, opened) merges f (feat, collapsed) ; main pinned elsewhere.
        local g = build({
            { "dv", { "d0", "f" } }, { "f", { "base" } }, { "d0", { "base" } },
            { "x", { "base" } }, { "base", {} },
        }, { dev = "dv", feat = "f", main = "x" }, { main = true }, { dev = "normal" })
        local proj = view.project(g.items, g.owners, g.sig)
        assert.equals("normal", proj.mode.dv)
        assert.equals("normal", proj.mode.d0)
        assert.equals("collapsed", proj.mode.f)
    end)
end)

describe("owner_label (§10.4)", function()
    local refs = {
        ["feature/x"] = { kind = "local" }, ["origin/feature/x"] = { kind = "remote" },
        ["fix/y"] = { kind = "local" }, v1 = { kind = "tag" },
    }
    it("names refs once per branch and counts anonymous owners", function()
        assert.equals("feature/x, fix/y +1 merged",
            owner_label({ "origin/feature/x", "feature/x", "merge:abc:2", "fix/y" }, refs))
        assert.equals("v1", owner_label({ "v1" }, refs))
        assert.equals("2 merged", owner_label({ "merge:a:2", "tip:b" }, refs))
        assert.equals("", owner_label({}, refs))
    end)
end)
