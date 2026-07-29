--- Phase 1 of branch modes (spec §10): the view builder `view.project`.
---
--- Tests the pure transform — signatures, the display-mode join, contraction of
--- collapsed regions to a single head, hidden removal, and edge re-pointing —
--- by feeding artificial DAGs + owner/mode maps and asserting properties (the
--- same invariant-style approach as graph_helpers). The projection is also fed
--- through the real layout (`build_graph` + the wires-connect grid checks) so a
--- projection that columns.layout can't lay out is caught.

local view = require("gitloom.graph.view")
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

--- Whether `c` is a **kept junction**: a fork/merge that stays its own visible,
--- node-less node (spec §10.3) and must never be absorbed into a head. Every
--- fork/merge is kept EXCEPT a **merge tip** — a merge (≥2 visible parents) with
--- no visible child — which, being the branch's tip, folds into a ◍ head.
local function is_kept_junction(c, mode)
    local nc, np = count_visible(c.children, mode), count_visible(c.parents, mode)
    if nc < 2 and np < 2 then return false end -- not a fork/merge
    return nc >= 1                             -- merge tip (nc == 0) folds; else kept
end

--- Branch topology must be preserved by the projection (the §10.3 contract): a
--- collapsed head contracts a linear run — or a merge tip plus its same-region
--- mainline — but never a **kept junction** (a fork, or a merge that still has a
--- visible child), which stays its own visible node. Also: no visible commit is
--- dropped, and no collapsed head floats (a region with external visible
--- neighbours but no edge).
local function assert_topology(proj, by_hash, label)
    label = label and (" (" .. label .. ")") or ""
    local mode, node_of = proj.mode, proj.node_of_hash
    -- 1. no head's region contains a kept junction (it must stay node-less)
    for _, n in ipairs(proj.nodes) do
        if n.collapsed then
            for _, h in ipairs(n.region) do
                assert.falsy(is_kept_junction(by_hash[h], mode),
                    "head absorbed a kept junction: " .. h .. label)
            end
        end
    end
    -- 2. every visible commit maps to a node; a kept junction stays real (not
    --    collapsed). A merge tip may fold into a head.
    for h, c in pairs(by_hash) do
        if mode[h] ~= "hidden" then
            assert.is_not_nil(node_of[h], "visible commit dropped: " .. h .. label)
            if is_kept_junction(c, mode) then
                assert.falsy(node_of[h].collapsed, "kept junction collapsed away: " .. h .. label)
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

    it("folds a merge tip (no visible children) into a collapsed head", function()
        -- The branch's tip is a merge with no children: tip = merge(f1, om). f1
        -- is the branch's own (collapsed) work; om is the merged-in side, kept
        -- visible by a normal owner. The merge tip must fold into a ◍ head that
        -- carries its ref and keeps the merged-in side as a lane — NOT a node-less
        -- junction (spec §10.3, the merge-tip exception).
        local items, by_hash = dag({
            { "tip", { "f1", "om" } }, -- merge tip, ref T (no children)
            { "f1", { "base" } },      -- the branch's own work
            { "om", { "base" } },      -- merged-in side, ref O (normal ⇒ visible)
            { "base", {} },
        })
        local proj = view.project(items, owners(by_hash, {
            T = { "tip", "collapsed" },
            O = { "om" }, -- normal
        }))
        assert_topology(proj, by_hash)
        local head = proj.node_of_hash.tip
        assert.is_true(head.collapsed, "merge tip should fold into a collapsed head")
        assert.falsy(head.junction)
        assert.equals("tip", head.tip.hash)         -- tip-anchored
        assert.is_true(hash_set(head.region).tip)   -- the tip is in its head's region
        assert.falsy(proj.node_of_hash.om.collapsed) -- merged-in side stays visible
        -- the head keeps the merged-in side as a parent edge (the merge still shows)
        local reaches_om = false
        for _, p in ipairs(head.parents) do
            if p == proj.node_of_hash.om then reaches_om = true end
        end
        assert.is_true(reaches_om, "head keeps the merged-in side as a parent edge")
    end)
end)

describe("get_column_chars — crossing vs node-less junction glyph", function()
    local function cell(conn, lanes)
        return { connectivity = conn, lanes = lanes, has_commit = false }
    end

    it("renders a real crossing as │ (not ┼)", function()
        -- a through-vertical and an independent through-horizontal in one cell
        local col = cell({ up = true, down = true, left = true, right = true }, {
            { connectivity = { up = true, down = true }, id = 1, color = 1, edges = {} },
            { connectivity = { left = true, right = true }, id = 2, color = 2, edges = {} },
        })
        local res = graph._internal.get_column_chars(helpers.big_opts(), { col })
        assert.equals("│", vim.trim(res.text))
    end)

    it("renders a genuine four-way junction (fan both sides) as ┼", function()
        -- a trunk vertical plus two fan *turns* — no straight horizontal segment
        local col = cell({ up = true, down = true, left = true, right = true }, {
            { connectivity = { up = true, down = true }, id = 1, color = 1, edges = {} },
            { connectivity = { left = true, down = true }, id = 2, color = 2, edges = {} },
            { connectivity = { right = true, down = true }, id = 3, color = 3, edges = {} },
        })
        local res = graph._internal.get_column_chars(helpers.big_opts(), { col })
        assert.equals("┼", vim.trim(res.text))
    end)
end)

describe("junction markers — node-less junctions (§10.4)", function()
    local function node_count(grid)
        local n = 0
        for _, line in ipairs(grid) do
            for _, cell in ipairs(line) do
                if cell.ch == "○" or cell.ch == "◉" or cell.ch == "◎" or cell.ch == "◍" then
                    n = n + 1
                end
            end
        end
        return n
    end

    -- a,b fork from x; x->y->root, all collapsed ⇒ x is a kept junction.
    local function fixture()
        local items, by_hash = dag({
            { "a", { "x" } }, { "b", { "x" } }, { "x", { "y" } },
            { "y", { "root" } }, { "root", {} },
        })
        local proj = view.project(items, owners(by_hash, {
            A = { "a", "collapsed" }, B = { "b", "collapsed" },
        }))
        return proj
    end

    it("flags a kept junction and draws it node-less (default on)", function()
        local proj = fixture()
        assert.is_true(proj.node_of_hash.x.junction) -- x flagged
        local opts = helpers.big_opts() -- junction_markers defaults on
        local grid = helpers.render_grid(opts, graph._internal.build_graph(opts, proj.items))
        assert.same({}, helpers.check_grid(grid, opts)) -- wires still connect
        -- the 3 heads (head_a, head_b, head_{y,root}) render nodes; x does not
        assert.equals(3, node_count(grid))
    end)

    it("lays a node-less junction out inline — no separate split line", function()
        -- x forks (children a,b) so under split-on-its-own-line it would get a
        -- split row; as a node-less junction it renders inline (one row).
        local proj = fixture()
        local opts = helpers.big_opts() -- split_on_separate_line = true
        local rows = graph._internal.build_graph(opts, proj.items)
        local saw_junction = false
        for _, row in ipairs(rows) do
            if row.commit and row.commit.junction then
                saw_junction = true
                assert.is_nil(row.split, "a node-less junction should have no separate split line")
            end
        end
        assert.is_true(saw_junction)
    end)

    it("junction_markers = false renders the junction with a node", function()
        local proj = fixture()
        local opts = helpers.big_opts()
        opts.junction_markers = false
        local grid = helpers.render_grid(opts, graph._internal.build_graph(opts, proj.items))
        assert.same({}, helpers.check_grid(grid, opts))
        assert.equals(4, node_count(grid)) -- x now shows a node too
    end)

    it("a fork+merge node-less junction keeps its fan-in on a separate split line (§5.1)", function()
        -- j is BOTH a fork (children ca, cb) and a merge (parents pa, pb), all
        -- collapsed ⇒ a node-less junction. Collapsing both funnels onto one row
        -- would lay two independent fans across it (§5.1 forbids two separated
        -- lanes sharing a horizontal except at a *single* fan). So under
        -- split_on_separate_line its fan-in must go to its own split line.
        local items, by_hash = dag({
            { "ca", { "j" } },          -- child a (ref A)
            { "cb", { "j" } },          -- child b (ref B)
            { "j", { "pa", "pb" } },    -- fork (ca,cb) + merge (pa,pb)
            { "pa", { "base" } },
            { "pb", { "base" } },
            { "base", {} },
        })
        local proj = view.project(items, owners(by_hash, {
            A = { "ca", "collapsed" }, B = { "cb", "collapsed" },
        }))
        local jnode = proj.node_of_hash.j
        assert.is_true(jnode.junction) -- node-less fork+merge junction
        local opts = helpers.big_opts() -- split_on_separate_line = true
        local rows = graph._internal.build_graph(opts, proj.items)
        local jrow
        for _, row in ipairs(rows) do
            if row.commit and row.commit.hash == "j" then jrow = row end
        end
        assert.is_not_nil(jrow)
        assert.is_not_nil(jrow.split, "fork+merge junction must get a separate split line, not collapse inline")
        -- and the layout is still valid end-to-end
        assert.same({}, helpers.check_grid(helpers.render_grid(opts, rows), opts))
    end)

    -- x forks (children a, b) collapsed ⇒ a kept junction; optionally label it.
    local function junction_line(opts, ref)
        local items, by_hash = dag({
            { "a", { "x" } }, { "b", { "x" } }, { "x", { "root" } }, { "root", {} },
        })
        if ref then by_hash.x.refs = { { name = ref, kind = "local" } } end
        local proj = view.project(items, owners(by_hash, {
            A = { "a", "collapsed" }, B = { "b", "collapsed" },
        }))
        assert.is_true(proj.node_of_hash.x.junction) -- a kept junction in the model
        local rows = graph._internal.build_graph(opts, proj.items)
        local xrow
        for _, r in ipairs(rows) do if r.commit and r.commit.hash == "x" then xrow = r end end
        assert.same({}, helpers.check_grid(helpers.render_grid(opts, rows), opts))
        return graph._internal.get_column_chars(opts, xrow.columns).text
    end

    it("a labelled junction shows the ◍ marker so its ref is anchored (§10.4)", function()
        -- A ref must be anchored to a node, so a junction that carries refs renders
        -- the ◍ collapsed marker instead of a bare node-less box.
        local txt = junction_line(helpers.big_opts(), "topic")
        assert.is_not_nil(txt:find("◍"), "a labelled junction must render ◍, got: " .. txt)
    end)

    it("a ref-less junction stays node-less (no marker)", function()
        local txt = junction_line(helpers.big_opts(), nil)
        assert.is_nil(txt:find("◍"), "a ref-less junction should stay node-less, got: " .. txt)
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
        local os = view.owners(items, ref_owners, { head = true },{}, false)
        assert.equals(#ref_owners, #os) -- no anonymous merge owners added
        for _, o in ipairs(os) do
            assert.equals("normal", o.mode)
            assert.falsy(o.fp_only)
        end
    end)

    it("collapse_merged on → trunk normal+fp, others collapsed, merge owner added", function()
        local items, ref_owners = fixture()
        local os = view.owners(items, ref_owners, { head = true },{}, true)
        local by_id = {}
        for _, o in ipairs(os) do by_id[o.id] = o end
        assert.equals("normal", by_id.head.mode)
        assert.is_true(by_id.head.fp_only)
        assert.equals("collapsed", by_id.feat.mode)
        assert.is_true(by_id.feat.fp_only) -- every owner is first-parent-only under focus
        assert.is_not_nil(by_id["merge:m:2"]) -- f1 is m's second parent
        assert.equals("collapsed", by_id["merge:m:2"].mode)
        assert.is_true(by_id["merge:m:2"].fp_only)
    end)

    it("an explicit mode overrides the default", function()
        local items, ref_owners = fixture()
        local os = view.owners(items, ref_owners, { head = true }, { feat = "normal" }, true)
        for _, o in ipairs(os) do
            if o.id == "feat" then assert.equals("normal", o.mode) end
        end
    end)

    it("a second pinned anchor defaults normal too (multi-anchor, §10.6)", function()
        local items, ref_owners = fixture()
        local os = view.owners(items, ref_owners, { head = true, feat = true }, {}, true)
        local by_id = {}
        for _, o in ipairs(os) do by_id[o.id] = o end
        assert.equals("normal", by_id.head.mode)
        assert.equals("normal", by_id.feat.mode) -- pinned anchor stays normal
        assert.is_true(by_id.feat.fp_only)        -- still first-parent-only under focus
        assert.equals("collapsed", by_id["merge:m:2"].mode) -- anonymous owners are never anchors
    end)

    it("no anchors ⇒ focus is inert, all normal (§10.6)", function()
        local items, ref_owners = fixture()
        -- collapse_merged on but an empty anchor set: nothing distinguishes a
        -- trunk, so the projection is the plain full graph (on == false).
        local os = view.owners(items, ref_owners, {}, {}, true)
        assert.equals(#ref_owners, #os) -- no anonymous merge owners added
        for _, o in ipairs(os) do
            assert.equals("normal", o.mode)
            assert.falsy(o.fp_only)
        end
    end)

    it("projects to mainline-full, merged-branch-collapsed", function()
        local items, ref_owners = fixture()
        local os = view.owners(items, ref_owners, { head = true }, {}, true)
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

describe("view.owners — owner coverage of the loaded commit set (§10.7)", function()
    -- REGRESSION (fix/reactive-unpacked). §3.1 loads commits with `git log --all`
    -- while §3.2 reads refs from `refs/heads`, `refs/remotes` and `refs/tags`
    -- only. In a repository with linked worktrees (`--all` walks every worktree's
    -- HEAD) or a `refs/original/*` backup namespace, the model therefore holds
    -- real commits that **no owner reaches**. `mode_of` then applies the
    -- "uncovered ⇒ normal" fallback (§10.2) and the whole branch renders as a run
    -- of full commit rows — no `◍` head, nothing for `pack_markers` to pack — in
    -- a view whose stated result is "current branch in full, every other branch a
    -- `◍` head" (§10.7).
    --
    -- The fixture is the topology only: a trunk with a pinned ref, plus a branch
    -- that forks off it and carries **no ref at all**.
    local function fixture()
        local items, by_hash = dag({
            { "h",  { "t2" } }, -- master tip (the pinned anchor)
            { "x1", { "x2" } }, -- an UNREFERENCED branch tip
            { "x2", { "x3" } },
            { "x3", { "t2" } }, -- ... forking off the trunk
            { "t2", { "t3" } },
            { "t3", {} },
        })
        local ref_owners = { { id = "master", tip = by_hash.h } }
        return items, by_hash, ref_owners
    end

    it("every real commit in the model is reached by some owner", function()
        local items, _, ref_owners = fixture()
        local os = view.owners(items, ref_owners, { master = true }, {}, true)
        local sig = view.signatures(items, os)
        for _, it in ipairs(items) do
            assert.is_true(next(sig[it.commit.hash]) ~= nil,
                "commit " .. it.commit.hash .. " has an empty signature — no owner covers it")
        end
    end)

    it("an unreferenced branch collapses to one ◍ head, not a run of commits", function()
        local items, _, ref_owners = fixture()
        local os = view.owners(items, ref_owners, { master = true }, {}, true)
        local proj = view.project(items, os)

        -- the pinned anchor's first-parent mainline stays in full
        assert.equals("normal", proj.mode.h)
        assert.equals("normal", proj.mode.t2)
        assert.equals("normal", proj.mode.t3)

        -- the ref-less branch is "every other branch": collapsed to one head
        assert.equals("collapsed", proj.mode.x1)
        assert.equals("collapsed", proj.mode.x2)
        assert.equals("collapsed", proj.mode.x3)

        local heads, normals = 0, 0
        for _, n in ipairs(proj.nodes) do
            if n.collapsed then heads = heads + 1 else normals = normals + 1 end
        end
        assert.equals(1, heads)   -- one ◍ standing for x1..x3
        assert.equals(3, normals) -- only the trunk h, t2, t3
    end)
end)

describe("view.owners — the tip-owner backstop (§10.2)", function()
    local view = require("gitloom.graph.view")
    local helpers = require("tests.graph_helpers")

    -- h (ref "master", the anchor) -> t2 -> t3 ; x1 is a ref-less tip forking
    -- off t2 — the shape a commit reachable only from `--all` makes.
    local function fixture()
        local items = helpers.dag({
            { "h", { "t2" } },
            { "x1", { "x2" } },
            { "x2", { "t2" } },
            { "t2", { "t3" } },
            { "t3", {} },
        })
        local by = {}
        for _, it in ipairs(items) do by[it.commit.hash] = it.commit end
        return items, by
    end

    -- owner list → id → owner, so an absent owner is a plain nil assertion.
    local function by_id(os)
        local m = {}
        for _, o in ipairs(os) do m[o.id] = o end
        return m
    end

    it("mints a tip: owner for an uncovered tip, collapsed and fp-only", function()
        local items, by = fixture()
        local os = view.owners(items, { { id = "master", tip = by.h } }, { master = true }, {}, true)
        local o = by_id(os)["tip:x1"]
        assert.is_not_nil(o)
        assert.equals("collapsed", o.mode)
        assert.is_true(o.fp_only)
        assert.equals(by.x1, o.tip)
    end)

    it("mints none for a tip a ref already owns", function()
        local items, by = fixture()
        local os = view.owners(items, { { id = "master", tip = by.h } }, { master = true }, {}, true)
        assert.is_nil(by_id(os)["tip:h"])
    end)

    it("mints none for an interior commit", function()
        local items, by = fixture()
        local os = view.owners(items, { { id = "master", tip = by.h } }, { master = true }, {}, true)
        local ids = by_id(os)
        assert.is_nil(ids["tip:x2"])
        assert.is_nil(ids["tip:t3"]) -- a root has children, so it is not a tip
    end)

    it("an explicit mode overrides a tip owner like any other", function()
        local items, by = fixture()
        local os = view.owners(items, { { id = "master", tip = by.h } }, { master = true },
            { ["tip:x1"] = "normal" }, true)
        for _, o in ipairs(os) do
            if o.id == "tip:x1" then assert.equals("normal", o.mode) end
        end
    end)

    it("EXCLUDES a working-tree virtual commit (§4.2 must stay visible)", function()
        local items = helpers.dag({ { "wt", { "h" } }, { "h", { "t2" } }, { "t2", {} } })
        local by = {}
        for _, it in ipairs(items) do by[it.commit.hash] = it.commit end
        by.wt.virtual = "staged" -- the §4.2 marker; childless by construction
        local os = view.owners(items, { { id = "master", tip = by.h } }, { master = true }, {}, true)
        assert.is_nil(by_id(os)["tip:wt"])
        -- ... and it therefore still projects as a normal, always-visible row.
        local proj = view.project(items, os)
        assert.equals("normal", proj.mode.wt)
        assert.is_false(proj.node_of_hash.wt.collapsed)
    end)

    it("adds no anonymous owners at all with focus off", function()
        local items, by = fixture()
        local os = view.owners(items, { { id = "master", tip = by.h } }, { master = true }, {}, false)
        assert.equals(1, #os) -- the ref owner only
    end)
end)
