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

local function count_visible(list, mode)
    local n = 0
    for _, c in ipairs(list or {}) do
        if mode[c.hash] ~= "hidden" then n = n + 1 end
    end
    return n
end

--- Branch topology must be preserved by the projection (the §10.3 contract): a
--- collapsed head may only contract a *linear* run, so a commit with ≥2 visible
--- children (a fork) or ≥2 visible parents (a merge) is never collapsed away — it
--- stays its own visible node. Also: no visible commit is dropped, and no
--- collapsed head floats (a region with external visible neighbours but no edge).
local function assert_topology(proj, by_hash, label)
    label = label and (" (" .. label .. ")") or ""
    local mode, node_of = proj.mode, proj.node_of_hash
    -- 1. no head's region contains a junction (fork or merge)
    for _, n in ipairs(proj.nodes) do
        if n.collapsed then
            for _, h in ipairs(n.region) do
                local c = by_hash[h]
                assert.is_true(count_visible(c.children, mode) <= 1, "head absorbed a fork: " .. h .. label)
                assert.is_true(count_visible(c.parents, mode) <= 1, "head absorbed a merge: " .. h .. label)
            end
        end
    end
    -- 2. every visible commit maps to a node; junctions stay real (not collapsed)
    for h, c in pairs(by_hash) do
        if mode[h] ~= "hidden" then
            assert.is_not_nil(node_of[h], "visible commit dropped: " .. h .. label)
            if count_visible(c.children, mode) >= 2 or count_visible(c.parents, mode) >= 2 then
                assert.falsy(node_of[h].collapsed, "junction collapsed away: " .. h .. label)
            end
        end
    end
    -- 3. no floating head: an external visible neighbour ⇒ a corresponding edge
    for _, n in ipairs(proj.nodes) do
        if n.collapsed then
            local ext_parent, ext_child = false, false
            for _, h in ipairs(n.region) do
                local c = by_hash[h]
                for _, p in ipairs(c.parents) do
                    if mode[p.hash] ~= "hidden" and node_of[p.hash] ~= n then ext_parent = true end
                end
                for _, ch in ipairs(c.children) do
                    if mode[ch.hash] ~= "hidden" and node_of[ch.hash] ~= n then ext_child = true end
                end
            end
            if ext_parent then assert.is_true(#n.parents >= 1, "floating head (no parent edge)" .. label) end
            if ext_child then assert.is_true(#n.children >= 1, "floating head (no child edge)" .. label) end
        end
    end
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

    it("a first-parent-only owner covers only its first-parent mainline", function()
        -- h -> m(merge: p1 first, p2 second) ; p1,p2 -> base. A fp_only trunk
        -- owner at h reaches the first-parent chain (h,m,p1,base) but not p2.
        local items, by_hash = dag({
            { "h", { "m" } },
            { "m", { "p1", "p2" } },
            { "p1", { "base" } },
            { "p2", { "base" } },
            { "base", {} },
        })
        local sig = view.signatures(items, {
            { id = "trunk", tip = by_hash.h, fp_only = true },
        })
        assert.is_true(sig.h.trunk)
        assert.is_true(sig.m.trunk)
        assert.is_true(sig.p1.trunk)
        assert.is_true(sig.base.trunk) -- shared ancestor, reached via p1 (first)
        assert.is_nil(sig.p2.trunk)    -- the merged-in (second-parent) side
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

describe("pack_markers — packing concurrent collapsed heads (§10.4)", function()
    local function count_glyph(grid, ch)
        local total = 0
        for _, line in ipairs(grid) do
            for _, cell in ipairs(line) do if cell.ch == ch then total = total + 1 end end
        end
        return total
    end

    it("packs two concurrent collapsed leaf heads onto one line, wires intact", function()
        -- a and b both branch off root; both collapsed leaves ⇒ concurrent heads.
        local items, by_hash = dag({
            { "a", { "root" } },
            { "b", { "root" } },
            { "root", {} },
        })
        local proj = view.project(items, owners(by_hash, {
            A = { "a", "collapsed" }, B = { "b", "collapsed" },
        }))
        local opts = helpers.big_opts()
        local rows = graph._internal.build_graph(opts, proj.items)
        local packed = graph._internal.pack_markers(rows)
        assert.is_true(#packed < #rows, "packing should reduce the row count")

        local grid = helpers.render_grid(opts, packed)
        assert.same({}, helpers.check_grid(grid, opts)) -- wires still connect
        -- exactly the two heads, now sharing a line
        assert.equals(2, count_glyph(grid, "◍"))
        local shared = false
        for _, line in ipairs(grid) do
            local n = 0
            for _, cell in ipairs(line) do if cell.ch == "◍" then n = n + 1 end end
            if n >= 2 then shared = true end
        end
        assert.is_true(shared, "expected a line carrying two markers")
    end)

    it("does not merge non-marker (real) rows", function()
        -- all-normal: no markers, so packing is a no-op.
        local items = helpers.dag(helpers.random_dag(15, 3))
        local proj = view.project(items, {})
        local opts = helpers.big_opts()
        local rows = graph._internal.build_graph(opts, proj.items)
        local packed = graph._internal.pack_markers(rows)
        assert.equals(#rows, #packed)
    end)

    it("packed output still passes the wires-connect grid check (fuzz)", function()
        -- The real safety net: pack random collapsed projections and feed the
        -- packed grid through the same checker the layout uses — a bad overlay
        -- shows up as a dangling/floating/unknown glyph or a colour break.
        for seed = 1, 40 do
            local items, by_hash = dag(helpers.random_dag(18, seed))
            local ospec = {}
            for i, it in ipairs(items) do
                if i % 3 == 0 then ospec["r" .. i] = { it.commit.hash, "collapsed" } end
            end
            local proj = view.project(items, owners(by_hash, ospec))
            local opts = helpers.big_opts()
            local rows = graph._internal.build_graph(opts, proj.items)
            local packed = graph._internal.pack_markers(rows)
            local grid = helpers.render_grid(opts, packed)
            assert.same({}, helpers.check_grid(grid, opts), "packed grid (seed " .. seed .. ")")
        end
    end)
end)

describe("view.project — branch topology preservation", function()
    it("keeps a fork inside a collapsed region as its own visible node", function()
        -- a,b both fork from x (x has two children); x->y->root. With A and B
        -- collapsed, x is a collapsed fork: it must NOT be absorbed into a head.
        local items, by_hash = dag({
            { "a", { "x" } },
            { "b", { "x" } },
            { "x", { "y" } },
            { "y", { "root" } },
            { "root", {} },
        })
        local proj = view.project(items, owners(by_hash, {
            A = { "a", "collapsed" },
            B = { "b", "collapsed" },
        }))
        assert_topology(proj, by_hash)
        local x_in_head = false
        for _, n in ipairs(proj.nodes) do
            if n.collapsed then
                for _, h in ipairs(n.region) do if h == "x" then x_in_head = true end end
            end
        end
        assert.falsy(x_in_head) -- the fork commit stays a real node
        assert.falsy(proj.node_of_hash.x.collapsed)
    end)

    it("keeps a merge inside a collapsed region as its own visible node", function()
        -- root forks to p1,p2 which merge at m; m->tip. All collapsed ⇒ m is a
        -- collapsed merge (two parents) and must stay its own node.
        local items, by_hash = dag({
            { "tip", { "m" } },
            { "m", { "p1", "p2" } },
            { "p1", { "root" } },
            { "p2", { "root" } },
            { "root", {} },
        })
        local proj = view.project(items, owners(by_hash, { T = { "tip", "collapsed" } }))
        assert_topology(proj, by_hash)
        assert.falsy(proj.node_of_hash.m.collapsed) -- the merge stays real
        assert.falsy(proj.node_of_hash.root.collapsed) -- the fork stays real
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

describe("view.owners — first-parent default (spec §10.7)", function()
    -- HEAD mainline h -> m(merge: main1 first, f1 second) ; main1,f1 -> base.
    -- f1 is a one-commit feature merged into the trunk (ref "feat").
    local function fixture()
        local items, by_hash = dag({
            { "h", { "m" } },
            { "m", { "main1", "f1" } },
            { "main1", { "base" } },
            { "f1", { "base" } },
            { "base", {} },
        })
        local ref_owners = {
            { id = "head", tip = by_hash.h },
            { id = "feat", tip = by_hash.f1 },
        }
        return items, ref_owners
    end

    it("collapse_merged off → every owner normal, no anonymous owners", function()
        local items, ref_owners = fixture()
        local os = view.owners(items, ref_owners, "head", {}, false)
        assert.equals(#ref_owners, #os) -- no anonymous merge owners added
        for _, o in ipairs(os) do
            assert.equals("normal", o.mode)
            assert.falsy(o.fp_only)
        end
    end)

    it("collapse_merged on → trunk normal+fp, others collapsed, merge owner added", function()
        local items, ref_owners = fixture()
        local os = view.owners(items, ref_owners, "head", {}, true)
        local by_id = {}
        for _, o in ipairs(os) do by_id[o.id] = o end
        assert.equals("normal", by_id.head.mode)
        assert.is_true(by_id.head.fp_only)
        assert.equals("collapsed", by_id.feat.mode)
        assert.falsy(by_id.feat.fp_only)
        assert.is_not_nil(by_id["merge:m:2"]) -- f1 is m's second parent
        assert.equals("collapsed", by_id["merge:m:2"].mode)
    end)

    it("an explicit mode overrides the default", function()
        local items, ref_owners = fixture()
        local os = view.owners(items, ref_owners, "head", { feat = "normal" }, true)
        for _, o in ipairs(os) do
            if o.id == "feat" then assert.equals("normal", o.mode) end
        end
    end)

    it("projects to mainline-full, merged-branch-collapsed", function()
        local items, ref_owners = fixture()
        local os = view.owners(items, ref_owners, "head", {}, true)
        local proj = view.project(items, os)
        assert.equals("normal", proj.mode.h)
        assert.equals("normal", proj.mode.m)
        assert.equals("normal", proj.mode.main1)
        assert.equals("normal", proj.mode.base) -- shared, reached by the trunk
        assert.equals("collapsed", proj.mode.f1) -- the merged-in feature
        local heads = 0
        for _, n in ipairs(proj.nodes) do if n.collapsed then heads = heads + 1 end end
        assert.equals(1, heads)
    end)
end)

describe("view.project — precomputed signatures (caching split)", function()
    it("a reused sig yields the same projection as computing it fresh", function()
        local items, by_hash = dag({
            { "m1", { "fork" } },
            { "f1", { "f2" } },
            { "f2", { "fork" } },
            { "fork", {} },
        })
        local os = owners(by_hash, { main = { "m1" }, feat = { "f1", "collapsed" } })
        local sig = view.signatures(items, os)
        local a = view.project(items, os)        -- computes its own sig
        local b = view.project(items, os, sig)   -- reuses the cached one
        local function shape(p)
            local out = {}
            for _, it in ipairs(p.items) do
                out[#out + 1] = it.commit.hash .. (it.commit.collapsed and "*" or "")
            end
            return out
        end
        assert.same(shape(a), shape(b))
        assert.same(a.mode, b.mode)
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
            assert_topology(proj, by_hash, "seed " .. seed)
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
            assert_topology(proj, by_hash, "seed " .. seed)
            local errors = helpers.check(helpers.big_opts(), proj.items)
            for _, e in ipairs(errors) do
                assert.truthy(e:match("^floating node"),
                    "unexpected layout error (seed " .. seed .. "): " .. e)
            end
        end
    end)
end)
