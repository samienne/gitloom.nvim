--- Tests for reachability emphasis (specification.md §12).
---
--- `reachable_cone` (the pure cone computation) is tested by properties: the
--- pivot is included, ancestors come via parent links and descendants via child
--- links, no unrelated "cousin" is pulled in (each sweep is monotonic), and the
--- visible-window bound clips nodes outside `top..bottom`.
---
--- `mark_reachable` walks the Lane graph from the pivot and is checked on real
--- layouts (build_graph): cone commit markers light, and an edge is highlighted
--- iff it lies on the pivot's ancestor/descendant cone.

local internal = require("gitloom.graph")._internal
local reachable_cone = internal.reachable_cone
local mark_reachable = internal.mark_reachable
local build_graph = internal.build_graph
local helpers = require("tests.graph_helpers")

-- Whether the Lane for edge begin->parent (by hash) is highlighted.
local function lane_hl(rows, begin_hash, parent_hash)
    for _, row in ipairs(rows) do
        for _, l in ipairs(row.parent_lanes or {}) do
            if l.begin.hash == begin_hash and l.parent.hash == parent_hash then
                return l.highlighted
            end
        end
    end
end

-- Build an ordered, parent/child-wired commit list from a compact spec
-- (rows newest-first; see graph_helpers.dag). Returns the order array and a
-- hash -> Commit map.
local function make_order(rows)
    local items = helpers.dag(rows)
    local by_hash = {}
    for _, it in ipairs(items) do
        by_hash[it.commit.hash] = it.commit
    end
    return items, by_hash
end

local function count(set)
    local n = 0
    for _ in pairs(set) do n = n + 1 end
    return n
end

-- A linear chain: c1 (newest) -> c2 -> c3 -> c4 (oldest, a root).
local LINEAR = {
    { "c1", { "c2" } },
    { "c2", { "c3" } },
    { "c3", { "c4" } },
    { "c4", {} },
}

-- A fork that merges back:  m -> {a, b} -> base.
--   m    (merge, newest)
--   a  b (siblings)
--   base (root)
local DIAMOND = {
    { "m", { "a", "b" } },
    { "a", { "base" } },
    { "b", { "base" } },
    { "base", {} },
}

describe("reachable_cone", function()
    it("includes the pivot itself", function()
        local order, c = make_order(LINEAR)
        local cone = reachable_cone(order, 2, 1, #order)
        assert.is_true(cone[c.c2] == true)
    end)

    it("includes all of a linear chain from any pivot (full window)", function()
        local order, c = make_order(LINEAR)
        local cone = reachable_cone(order, 2, 1, #order)
        assert.is_true(cone[c.c1] == true) -- descendant
        assert.is_true(cone[c.c2] == true) -- pivot
        assert.is_true(cone[c.c3] == true) -- ancestor
        assert.is_true(cone[c.c4] == true) -- ancestor
        assert.equals(4, count(cone))
    end)

    it("follows parents for ancestors and children for descendants", function()
        local order, c = make_order(DIAMOND)
        -- pivot = base (oldest): no ancestors, every commit descends from it.
        local from_base = reachable_cone(order, 4, 1, #order)
        assert.is_true(from_base[c.base] == true)
        assert.is_true(from_base[c.a] == true)
        assert.is_true(from_base[c.b] == true)
        assert.is_true(from_base[c.m] == true)

        -- pivot = m (newest): no descendants, every commit is an ancestor.
        local from_m = reachable_cone(order, 1, 1, #order)
        assert.is_true(from_m[c.m] == true)
        assert.is_true(from_m[c.a] == true)
        assert.is_true(from_m[c.b] == true)
        assert.is_true(from_m[c.base] == true)
    end)

    it("excludes a sibling (cousin) that is neither ancestor nor descendant", function()
        local order, c = make_order(DIAMOND)
        -- pivot = a: ancestor = base, descendant = m; b is a's sibling and must
        -- NOT be pulled in (a bidirectional flood would wrongly include it).
        local cone = reachable_cone(order, 2, 1, #order)
        assert.is_true(cone[c.a] == true)
        assert.is_true(cone[c.base] == true)
        assert.is_true(cone[c.m] == true)
        assert.is_nil(cone[c.b])
        assert.equals(3, count(cone))
    end)

    it("clips the cone to the visible window", function()
        local order, c = make_order(LINEAR)
        -- pivot = c2, but only rows 2..3 are on screen: c1 (descendant) and c4
        -- (ancestor) are off-screen and must be excluded.
        local cone = reachable_cone(order, 2, 2, 3)
        assert.is_true(cone[c.c2] == true)
        assert.is_true(cone[c.c3] == true)
        assert.is_nil(cone[c.c1])
        assert.is_nil(cone[c.c4])
        assert.equals(2, count(cone))
    end)

    it("is empty when the pivot is outside the visible window", function()
        local order = make_order(LINEAR)
        local cone = reachable_cone(order, 1, 2, 4) -- pivot row 1 not in 2..4
        assert.equals(0, count(cone))
    end)

    it("is empty for an out-of-range pivot", function()
        local order = make_order(LINEAR)
        assert.equals(0, count(reachable_cone(order, 99, 1, #order)))
    end)
end)

describe("lane model (build_graph)", function()
    local function row_for(rows, hash)
        for _, r in ipairs(rows) do
            if r.commit and r.commit.hash == hash then return r end
        end
    end
    local function edges(lanes)
        local out = {}
        for _, l in ipairs(lanes or {}) do out[#out + 1] = l.begin.hash .. "->" .. l.parent.hash end
        table.sort(out)
        return out
    end

    it("attaches parent_lanes and child_lanes per edge (octopus)", function()
        local items = helpers.dag({
            { "c1", { "c2", "c3", "c4" } },
            { "c2", { "c5" } }, { "c3", { "c5" } }, { "c4", { "c5" } }, { "c5", {} },
        })
        local rows = build_graph(helpers.big_opts(), items)

        assert.same({ "c1->c2", "c1->c3", "c1->c4" }, edges(row_for(rows, "c1").parent_lanes))
        assert.same({}, edges(row_for(rows, "c1").child_lanes)) -- tip
        assert.same({ "c2->c5" }, edges(row_for(rows, "c2").parent_lanes))
        assert.same({ "c1->c2" }, edges(row_for(rows, "c2").child_lanes))
        assert.same({}, edges(row_for(rows, "c5").parent_lanes)) -- root
        assert.same({ "c2->c5", "c3->c5", "c4->c5" }, edges(row_for(rows, "c5").child_lanes))
    end)

    it("shares one Lane object between a parent's child_lane and the child's parent_lane", function()
        local items = helpers.dag({ { "a", { "b" } }, { "b", {} } })
        local rows = build_graph(helpers.big_opts(), items)
        local a, b = row_for(rows, "a"), row_for(rows, "b")
        assert.equals(a.parent_lanes[1], b.child_lanes[1]) -- same object (the edge a->b)
        assert.equals(a.commit, a.parent_lanes[1].begin)
        assert.equals(b.commit, a.parent_lanes[1].parent)
    end)
end)

describe("rendered dimming (per-lane)", function()
    local get_column_chars = internal.get_column_chars

    -- Count rendered highlight groups across the whole laid-out grid.
    local function grid_hls(opts, rows)
        local set = {}
        for _, row in ipairs(rows) do
            for _, ln in ipairs(helpers.row_lines(row)) do
                do
                    local res = get_column_chars(opts, ln.line)
                    for _, h in ipairs(res.highlight or {}) do
                        set[h.hl] = (set[h.hl] or 0) + 1
                    end
                end
            end
        end
        return set
    end

    local function commit_lane_id(rows, hash)
        for _, row in ipairs(rows) do
            for _, t in ipairs(row.columns) do
                if t.has_commit and t.commit.hash == hash then return t.id end
            end
        end
    end

    -- The commit marker track on a laid-out row.
    local function marker(rows, hash)
        for _, row in ipairs(rows) do
            for _, t in ipairs(row.columns) do
                if t.has_commit and t.commit.hash == hash then return t end
            end
        end
    end

    it("connects a cone lane through a shared split to its parent", function()
        -- octopus: c5 is a 3-way split (children c2, c3, c4 share parent c5).
        -- Pivot c3: its edge to the shared parent c5 must be highlighted while
        -- the siblings' edges stay dim — exact, no fan over-lighting.
        local items = helpers.dag({
            { "c1", { "c2", "c3", "c4" } },
            { "c2", { "c5" } }, { "c3", { "c5" } }, { "c4", { "c5" } }, { "c5", {} },
        })
        local rows = build_graph(helpers.big_opts(), items)
        mark_reachable(rows, 3, 1, #rows) -- pivot = c3

        assert.is_true(marker(rows, "c3").active == true) -- pivot
        assert.is_true(marker(rows, "c5").active == true) -- ancestor (parent)
        assert.is_true(marker(rows, "c1").active == true) -- descendant (child)
        assert.is_false(marker(rows, "c2").active)        -- sibling, out of cone
        assert.is_false(marker(rows, "c4").active)

        assert.is_true(lane_hl(rows, "c3", "c5"))         -- cone edge lit
        assert.is_true(lane_hl(rows, "c1", "c3"))
        assert.is_false(lane_hl(rows, "c4", "c5"))        -- sibling edge dim
        assert.is_false(lane_hl(rows, "c1", "c4"))
    end)

    -- Whether a `dir`-bearing segment of the cell carrying that direction has a
    -- highlighted edge (the renderer's union-of-highlighted glyph would keep it).
    local function lit_in_dir(line, dir)
        for _, t in ipairs(line or {}) do
            if t.connectivity[dir] then
                for _, s in ipairs(t.lanes or {}) do
                    if s.connectivity[dir] then
                        for _, e in ipairs(s.edges or {}) do
                            if e.highlighted then return true end
                        end
                    end
                end
            end
        end
        return false
    end

    it("keeps the descent into a merge lit for a non-trunk cone child", function()
        -- octopus c5 split line: the single descent into c5 is shared by every
        -- converging child. Pivot c3 (a non-trunk child) — even though the trunk
        -- child c2 is dim, the descent must stay lit so the cone reaches c5 (else
        -- the convergence glyph loses its `down`).
        local items = helpers.dag({
            { "c1", { "c2", "c3", "c4" } },
            { "c2", { "c5" } }, { "c3", { "c5" } }, { "c4", { "c5" } }, { "c5", {} },
        })
        local rows = build_graph(helpers.big_opts(), items) -- split on its own line
        mark_reachable(rows, 3, 1, #rows)                   -- pivot c3
        local split
        for _, row in ipairs(rows) do if row.commit.hash == "c5" then split = (row.above or {})[1] end end
        assert.is_not_nil(split)
        assert.is_true(lit_in_dir(split, "down"))
    end)

    it("keeps the ascent out of a split lit for a non-first cone parent", function()
        -- c has parents d, e on a merge line; the single ascent out of c is shared
        -- by both. Pivot e (the non-first parent) — even though the first parent d
        -- is dim, the ascent must stay lit (else the convergence glyph loses `up`).
        local items = helpers.dag({
            { "c", { "d", "e" } }, { "d", { "f" } }, { "e", { "f" } }, { "f", {} },
        })
        local opts = helpers.big_opts({ split_on_separate_line = false, merge_on_separate_line = true })
        local rows = build_graph(opts, items)
        local pidx
        for i, r in ipairs(rows) do if r.commit.hash == "e" then pidx = i end end
        mark_reachable(rows, pidx, 1, #rows)
        local merge
        for _, row in ipairs(rows) do if row.commit.hash == "c" then merge = row.merge end end
        assert.is_not_nil(merge)
        assert.is_true(lit_in_dir(merge, "up"))
    end)

    -- A row's split line rendered as a "glyph(hl) glyph(hl) ..." string.
    local function render_split(opts, rows, emphasis)
        for _, row in ipairs(rows) do
            if (row.above or {})[1] then
                local res = get_column_chars(opts, row.above[1], emphasis)
                local text, hls, out, i = res.text, res.highlight or {}, {}, 1
                local function hl_at(bp)
                    for _, h in ipairs(hls) do
                        if bp >= h.start_pos and bp < h.end_pos then return h.hl end
                    end
                    return "."
                end
                while i <= #text do
                    local b = text:byte(i)
                    local n = (b < 0x80) and 1 or (b < 0xE0) and 2 or (b < 0xF0) and 3 or 4
                    out[#out + 1] = text:sub(i, i + n - 1) .. "(" .. hl_at(i - 1) .. ")"
                    i = i + n
                end
                return table.concat(out, " ")
            end
        end
    end

    it("renders the split identically regardless of pivot when emphasis is off", function()
        -- octopus: marking different pivots must not change the off-emphasis
        -- render — the split is pivot-independent when highlighting is disabled.
        local items = helpers.dag({
            { "c1", { "c2", "c3", "c4" } },
            { "c2", { "c5" } }, { "c3", { "c5" } }, { "c4", { "c5" } }, { "c5", {} },
        })
        local opts = helpers.big_opts()
        local r3 = build_graph(opts, items); mark_reachable(r3, 3, 1, #r3)
        local r4 = build_graph(opts, items); mark_reachable(r4, 4, 1, #r4)
        assert.equals(render_split(opts, r3, false), render_split(opts, r4, false))
    end)

    it("keeps a split fan exact when it crosses an unrelated lane", function()
        -- p is a 2-way split (children a, b); x->base is an unrelated lane that
        -- spans p's row, so it crosses p's split line. With pivot a, only a->p
        -- (and p->base) light; the sibling b->p and the crossing x->base stay
        -- dim — the hub must be p's own descent, not the unrelated `down`.
        local items = helpers.dag({
            { "t", { "x" } }, { "a", { "p" } }, { "b", { "p" } },
            { "x", { "base" } }, { "p", { "base" } }, { "base", {} },
        })
        local rows = build_graph(helpers.big_opts(), items)
        local pidx
        for i, r in ipairs(rows) do if r.commit.hash == "a" then pidx = i end end
        mark_reachable(rows, pidx, 1, #rows)

        assert.is_true(lane_hl(rows, "a", "p"))
        assert.is_true(lane_hl(rows, "p", "base"))
        assert.is_false(lane_hl(rows, "b", "p"))    -- sibling
        assert.is_false(lane_hl(rows, "x", "base")) -- crossing, unrelated
        assert.is_false(lane_hl(rows, "t", "x"))
    end)

    it("leaves an out-of-cone commit and its edges fully dim", function()
        -- Feature branch: h merges main(a) and feature(f); a and f share parent b.
        -- Pivot a: f is out of the cone. f's marker and *both* its edges stay dim
        -- (exact — no fan-cap over-lighting now the Lane model is per-edge).
        local items = helpers.dag({
            { "h", { "a", "f" } }, { "a", { "b" } }, { "f", { "b" } },
            { "b", { "c" } }, { "c", {} },
        })
        local rows = build_graph(helpers.big_opts(), items)
        mark_reachable(rows, 2, 1, #rows) -- pivot = a

        assert.is_false(marker(rows, "f").active)
        for _, hash in ipairs({ "a", "b", "c", "h" }) do
            assert.is_true(marker(rows, hash).active == true)
        end
        assert.is_false(lane_hl(rows, "f", "b")) -- f's edges dim
        assert.is_false(lane_hl(rows, "h", "f"))
        assert.is_true(lane_hl(rows, "a", "b"))  -- a's cone edge lit
        assert.is_true(lane_hl(rows, "b", "c"))
    end)
end)

describe("mark_reachable", function()
    local function marker(rows, hash)
        for _, row in ipairs(rows) do
            for _, t in ipairs(row.columns) do
                if t.has_commit and t.commit.hash == hash then return t end
            end
        end
    end
    local function all_lanes(rows)
        local seen, out = {}, {}
        for _, row in ipairs(rows) do
            for _, l in ipairs(row.parent_lanes or {}) do
                if not seen[l] then seen[l] = true; out[#out + 1] = l end
            end
        end
        return out
    end

    it("lights every commit marker when the whole chain is in the cone", function()
        local order = make_order(LINEAR)
        local rows = build_graph(helpers.big_opts(), order)
        local cone = mark_reachable(rows, 2, 1, #rows)
        for _, hash in ipairs({ "c1", "c2", "c3", "c4" }) do
            assert.is_true(marker(rows, hash).active == true)
        end
        assert.equals(4, count(cone))
    end)

    it("lights every edge when the whole graph is in the cone", function()
        -- DIAMOND, pivot m (tip): everything is an ancestor, so every Lane lights.
        local rows = build_graph(helpers.big_opts(), make_order(DIAMOND))
        mark_reachable(rows, 1, 1, #rows)
        for _, l in ipairs(all_lanes(rows)) do
            assert.is_true(l.highlighted)
        end
    end)

    it("highlights an edge to an off-window parent", function()
        -- LINEAR c1->c2->c3->c4 with only rows 1..3 visible (c4 off-window).
        -- Pivot c2: the edge c3->c4 leaves the bottom of the view but is still a
        -- cone ancestor edge, so its visible stub must light (the window bound
        -- clips the walk, not the highlight of on-screen wires).
        local rows = build_graph(helpers.big_opts(), make_order(LINEAR))
        mark_reachable(rows, 2, 1, 3)       -- pivot c2, window excludes c4
        assert.is_true(lane_hl(rows, "c2", "c3")) -- in-window
        assert.is_true(lane_hl(rows, "c3", "c4")) -- to the off-window parent
    end)

    it("leaves a sibling's marker and edges dim", function()
        -- DIAMOND, pivot a: b is a sibling (neither ancestor nor descendant).
        local order, c = make_order(DIAMOND)
        local rows = build_graph(helpers.big_opts(), order)
        local cone = mark_reachable(rows, 2, 1, #rows)
        assert.is_false(marker(rows, "b").active)
        assert.is_false(lane_hl(rows, "b", "base"))
        assert.is_false(lane_hl(rows, "m", "b"))
        assert.is_true(lane_hl(rows, "a", "base"))
        assert.is_nil(cone[c.b])
    end)

    -- A packed marker row (§10.4) carries no `commit` of its own: its collapsed
    -- heads are its `markers`. A head the cone reaches is in the cone like any
    -- other row's commit (§12.2: packed markers included) — its node cell lights,
    -- its label reads the cone, and the walk continues through it.
    it("puts a packed marker head the cone reaches in the cone and lights its node", function()
        -- m merges a and b; a and b are collapsed heads on adjacent rows (packed).
        local order, c = make_order({
            { "m", { "a", "b" } },
            { "a", { "base" } },
            { "b", { "base" } },
            { "base", {} },
        })
        local rows = build_graph(helpers.big_opts(), order)
        c.a.collapsed = true; c.b.collapsed = true
        local display = require("gitloom.graph").pack_markers(rows)
        local packed
        for _, it in ipairs(display) do
            if it.type == "markers" then packed = it end
        end
        assert.is_not_nil(packed, "fixture must pack a and b into one markers row")
        local pivot
        for i, it in ipairs(display) do if it.commit == c.m then pivot = i end end
        local cone = mark_reachable(display, pivot, 1, #display)
        assert.is_true(cone[c.a] == true)
        assert.is_true(cone[c.b] == true)
        assert.is_true(cone[c.base] == true) -- the walk passes through the heads
        for _, t in ipairs(packed.columns) do
            if t.has_commit then assert.is_true(t.active == true) end
        end
    end)

    it("leaves a packed marker head outside the cone dim", function()
        -- Two unrelated chains whose collapsed heads a and b pack onto one row;
        -- pivot t1 reaches a only, so b's node cell on the packed row stays dim.
        local order, c = make_order({
            { "t1", { "a" } },
            { "t2", { "b" } },
            { "a", { "r1" } },
            { "b", { "r2" } },
            { "r1", {} },
            { "r2", {} },
        })
        local rows = build_graph(helpers.big_opts(), order)
        c.a.collapsed = true; c.b.collapsed = true
        local display = require("gitloom.graph").pack_markers(rows)
        local packed
        for _, it in ipairs(display) do
            if it.type == "markers" then packed = it end
        end
        assert.is_not_nil(packed, "fixture must pack a and b into one markers row")
        local cone = mark_reachable(display, 1, 1, #display) -- pivot t1
        assert.is_true(cone[c.a] == true)
        assert.is_nil(cone[c.b])
        assert.is_true(cone[c.r1] == true)
        for _, t in ipairs(packed.columns) do
            if t.has_commit then assert.equals(t.commit == c.a, t.active == true) end
        end
    end)
end)
