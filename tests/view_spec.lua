--- Phase 1 of branch modes (spec §10): the view builder `view.project`.
---
--- Tests the pure transform — signatures, the display-mode join, contraction of
--- collapsed regions to a single head, hidden removal, and edge re-pointing —
--- by feeding artificial DAGs + owner/mode maps and asserting properties (the
--- same invariant-style approach as graph_helpers). The projection is also fed
--- through the real layout (`build_graph` + the wires-connect grid checks) so a
--- projection that columns.layout can't lay out is caught.

local view = require("gitloom.view")
local graph = require("gitloom.graph")
local helpers = require("tests.graph_helpers")

--- Build wired commit items from a compact spec (reuses the graph helper) and
--- return both the items and a hash → Commit lookup so owners can point at the
--- real commit objects.
---@param rows table[]
---@return table[] items, table<string, table> by_hash
local function dag(rows)
    local items = helpers.dag(rows)
    local by_hash = {}
    for _, it in ipairs(items) do by_hash[it.commit.hash] = it.commit end
    return items, by_hash
end

--- An owner list from { ref_name = { hash, mode } } against a hash → Commit map.
local function owners(by_hash, spec)
    local out = {}
    for id, o in pairs(spec) do
        out[#out + 1] = { id = id, tip = by_hash[o[1]], mode = o[2] or "normal" }
    end
    return out
end

--- Map a projection's nodes by their (real) commit hash; collapsed heads keyed
--- by "collapsed:<root>".
local function nodes_by_hash(proj)
    local m = {}
    for _, n in ipairs(proj.nodes) do m[n.hash] = n end
    return m
end

local function hash_set(list)
    local s = {}
    for _, x in ipairs(list) do s[x] = true end
    return s
end

describe("view.project — signatures", function()
    it("are monotone: a parent's signature is a superset of its child's", function()
        -- c1 (tip, ref a) -> c2 -> c3 (root)
        local items, by_hash = dag({ { "c1", { "c2" } }, { "c2", { "c3" } }, { "c3", {} } })
        local sig = view.signatures(items, owners(by_hash, { a = { "c1" } }))
        assert.is_true(sig.c1.a)
        assert.is_true(sig.c2.a)
        assert.is_true(sig.c3.a)
    end)

    it("unions owners across a merge", function()
        -- m (merge) -> a1, b1 ; a/b refs on a1/b1's own tips above
        --   ta(ref a) -> m ; tb(ref b) -> m  is awkward; use two tips merging:
        -- tip_a -> base ; tip_b -> base, with refs a,b on the tips
        local items, by_hash = dag({
            { "ta", { "base" } },
            { "tb", { "base" } },
            { "base", {} },
        })
        local sig = view.signatures(items, owners(by_hash, { a = { "ta" }, b = { "tb" } }))
        assert.same({ a = true }, sig.ta)
        assert.same({ b = true }, sig.tb)
        assert.same({ a = true, b = true }, sig.base) -- shared ancestor
    end)
end)

describe("view.project — all normal is the identity", function()
    it("keeps every commit, none collapsed, with no owners", function()
        local items = helpers.dag(helpers.random_dag(20, 7))
        local proj = view.project(items, {})
        assert.equals(#items, #proj.items)
        for _, n in ipairs(proj.nodes) do assert.falsy(n.collapsed) end
        -- every input hash present exactly once
        local seen = {}
        for _, it in ipairs(proj.items) do
            assert.falsy(seen[it.commit.hash])
            seen[it.commit.hash] = true
        end
        for _, it in ipairs(items) do assert.is_true(seen[it.commit.hash]) end
    end)
end)

describe("view.project — hidden", function()
    it("removes a branch's exclusive commits but keeps shared ancestors", function()
        -- main: m1 -> base ; feat: f1 -> f2 -> base   (base shared)
        local items, by_hash = dag({
            { "m1", { "base" } },
            { "f1", { "f2" } },
            { "f2", { "base" } },
            { "base", {} },
        })
        local proj = view.project(items, owners(by_hash, {
            main = { "m1" },
            feat = { "f1", "hidden" },
        }))
        assert.equals("hidden", proj.mode.f1)
        assert.equals("hidden", proj.mode.f2)
        assert.equals("normal", proj.mode.m1)
        assert.equals("normal", proj.mode.base) -- reached by main too
        local by = nodes_by_hash(proj)
        assert.is_nil(by.f1)
        assert.is_nil(by.f2)
        assert.is_not_nil(by.base)
        -- base's child edge to the hidden f2 is dropped (only main's m1 remains)
        local child_hashes = {}
        for _, ch in ipairs(by.base.children) do child_hashes[ch.hash] = true end
        assert.falsy(child_hashes.f2)
        assert.is_true(child_hashes.m1)
    end)
end)

describe("view.project — collapsed", function()
    it("contracts an exclusive chain to one head and keeps the junction", function()
        -- feat: f1 -> f2 -> fork ; main: m1 -> fork (fork shared = junction)
        local items, by_hash = dag({
            { "m1", { "fork" } },
            { "f1", { "f2" } },
            { "f2", { "fork" } },
            { "fork", {} },
        })
        local proj = view.project(items, owners(by_hash, {
            main = { "m1" },
            feat = { "f1", "collapsed" },
        }))
        assert.equals("collapsed", proj.mode.f1)
        assert.equals("collapsed", proj.mode.f2)
        assert.equals("normal", proj.mode.fork) -- shared ⇒ junction stays
        local by = nodes_by_hash(proj)
        local head = by["collapsed:f1"] or by["collapsed:f2"]
        assert.is_not_nil(head)
        assert.is_true(head.collapsed)
        assert.equals(2, head.count)
        assert.same({ f1 = true, f2 = true }, hash_set(head.region))
        assert.equals("f1", head.tip.hash) -- newest member
        -- head hangs off the fork; fork is its only projected parent
        assert.equals(1, #head.parents)
        assert.equals(by.fork.hash, head.parents[1].hash)
    end)

    it("keeps two collapsed regions of different signature as separate heads", function()
        -- C branches off inside B's chain, both collapsed ⇒ region {B} and
        -- region {B,C} are distinct heads with the junction (cfork) between.
        local items, by_hash = dag({
            { "b1", { "b2" } },     -- ref b, exclusive {b}
            { "c1", { "cfork" } },  -- ref c, exclusive {c}
            { "b2", { "cfork" } },
            { "cfork", { "root" } }, -- where c forks off b's line: {b,c}
            { "root", {} },
        })
        local proj = view.project(items, owners(by_hash, {
            b = { "b1", "collapsed" },
            c = { "c1", "collapsed" },
        }))
        -- cfork is reached by both b and c ⇒ collapsed combined region, but a
        -- *different* signature than {b}-only b1/b2, so a separate head.
        local roots = {}
        for _, n in ipairs(proj.nodes) do
            if n.collapsed then roots[#roots + 1] = n end
        end
        assert.is_true(#roots >= 2, "expected at least two distinct collapsed heads")
    end)
end)

describe("view.project — collapsed-head rendering", function()
    it("renders a collapsed head with the ◍ node glyph (once)", function()
        local items, by_hash = dag({
            { "m1", { "fork" } },
            { "f1", { "f2" } },
            { "f2", { "fork" } },
            { "fork", {} },
        })
        local proj = view.project(items, owners(by_hash, {
            main = { "m1" },
            feat = { "f1", "collapsed" },
        }))
        local opts = helpers.big_opts()
        local rows = graph._internal.build_graph(opts, proj.items)
        local grid = helpers.render_grid(opts, rows)
        local s = helpers.grid_to_string(grid)
        assert.truthy(s:find("◍"), "expected a collapsed head glyph in:\n" .. s)
        local _, n = s:gsub("◍", "")
        assert.equals(1, n) -- exactly one head for the one collapsed region
    end)
end)

describe("view.project — combined-region join", function()
    -- ta, tb merge histories sharing `base`; vary their modes and read base.
    local function base_mode(mode_a, mode_b)
        local items, by_hash = dag({
            { "ta", { "base" } },
            { "tb", { "base" } },
            { "base", {} },
        })
        local proj = view.project(items, owners(by_hash, {
            a = { "ta", mode_a },
            b = { "tb", mode_b },
        }))
        return proj.mode.base
    end

    it("is normal if either owner is normal", function()
        assert.equals("normal", base_mode("normal", "collapsed"))
        assert.equals("normal", base_mode("collapsed", "normal"))
    end)
    it("is collapsed only if all owners are collapsed", function()
        assert.equals("collapsed", base_mode("collapsed", "collapsed"))
    end)
    it("ignores hidden owners (stays visible if the other is retained)", function()
        assert.equals("normal", base_mode("normal", "hidden"))
        assert.equals("collapsed", base_mode("collapsed", "hidden"))
    end)
    it("is hidden only if every owner is hidden", function()
        assert.equals("hidden", base_mode("hidden", "hidden"))
    end)
end)

describe("view.project — output is layout-valid", function()
    -- every projected item's children precede it (valid topo order), no node is
    -- dropped by a cycle, and the real layout lays the projection out cleanly.
    local function assert_topo(proj)
        local pos = {}
        for i, it in ipairs(proj.items) do pos[it.commit] = i end
        assert.equals(#proj.nodes, #proj.items) -- nothing lost to a cycle
        for _, it in ipairs(proj.items) do
            for _, ch in ipairs(it.commit.children) do
                if pos[ch] then
                    assert.is_true(pos[ch] < pos[it.commit],
                        "child must precede parent in the order")
                end
            end
        end
    end

    -- Every third commit is a ref tip; its mode comes from the seed so the sweep
    -- covers many owner/mode combinations deterministically.
    local function fuzz_owners(items, by_hash, seed, modes)
        local ospec = {}
        for i, it in ipairs(items) do
            if i % 3 == 0 then
                ospec["r" .. i] = { it.commit.hash, modes[((seed + i) % #modes) + 1] }
            end
        end
        return owners(by_hash, ospec)
    end

    it("normal+collapsed projections lay out cleanly (full grid check)", function()
        -- Contraction keeps junctions and never disconnects, so the full
        -- wires-connect suite must pass exactly.
        for seed = 1, 40 do
            local items, by_hash = dag(helpers.random_dag(18, seed))
            local proj = view.project(items, fuzz_owners(items, by_hash, seed, { "normal", "collapsed" }))
            assert_topo(proj)
            local errors = helpers.check(helpers.big_opts(), proj.items)
            assert.same({}, errors, "layout invariants on projection (seed " .. seed .. ")")
        end
    end)

    it("hidden projections stay a valid topo order with connected wires", function()
        -- Hiding can legitimately isolate a retained commit (all its neighbours
        -- were hidden), which the connected-layout check reports as a floating
        -- node — allow only that, so broken wires/glyphs still fail.
        for seed = 1, 40 do
            local items, by_hash = dag(helpers.random_dag(18, seed))
            local proj = view.project(items, fuzz_owners(items, by_hash, seed, { "normal", "collapsed", "hidden" }))
            assert_topo(proj)
            local errors = helpers.check(helpers.big_opts(), proj.items)
            for _, e in ipairs(errors) do
                assert.truthy(e:match("^floating node"),
                    "unexpected layout error (seed " .. seed .. "): " .. e)
            end
        end
    end)
end)
