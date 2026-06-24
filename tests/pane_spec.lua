--- Context-pane layout core (spec §6.2): boundary extraction + the footer
--- builder, tested purely (no snacks). The pane shares commit identities with
--- the main layout (one DAG), as production shares repo.order.
local pane = require("gitloom.pane")
local columns = require("gitloom.columns")
local h = require("tests.graph_helpers")

-- t1 merges the trunk (t2..) and a side branch (b1); both flow down past the
-- visible boundary at row 2 (t2). Off-screen below: trunk t3,t4 (the anchor)
-- and the folded branch b1.
local function fixture()
    local items = h.dag({
        { "t1", { "t2", "b1" } },
        { "t2", { "t3" } },
        { "b1", { "t3" } },
        { "t3", { "t4" } },
        { "t4", {} },
    })
    return items, h.big_opts()
end

local function find_col(boundary, parent_hash)
    for col, lane in pairs(boundary) do
        if lane.parent and lane.parent.hash == parent_hash then return col, lane end
    end
end

-- Match a boundary lane by the commit it ascends from (its `begin` child) — for
-- the header, where several seam lanes can share a parent.
local function find_col_begin(boundary, begin_hash)
    for col, lane in pairs(boundary) do
        if lane.begin and lane.begin.hash == begin_hash then return col, lane end
    end
end

-- A node_of map (hash → pane node) as view.project's node_of_hash builds it: each
-- pane node under its own hash, plus every member hash of a collapsed head.
local function node_of(pane_items)
    local m = {}
    for _, it in ipairs(pane_items) do
        local c = it.commit
        m[c.hash] = c
        for _, h in ipairs(c.region or {}) do m[h] = c end
    end
    return m
end

-- Vertical id-continuity across a pane's rendered lines: a cell's up-lane id must
-- equal the down-lane id directly above. Guards the seed and the header flip.
local function assert_continuous(rows)
    local lines = {}
    for _, r in ipairs(rows) do
        if r.split then lines[#lines + 1] = r.split end
        lines[#lines + 1] = r.columns
        if r.merge then lines[#lines + 1] = r.merge end
    end
    local function up_id(c) for _, s in ipairs(c.lanes or {}) do if s.connectivity.up then return s.id end end end
    local function down_id(c) for _, s in ipairs(c.lanes or {}) do if s.connectivity.down then return s.id end end end
    for i = 1, #lines - 1 do
        for col, cell in ipairs(lines[i + 1]) do
            if cell.connectivity.up and lines[i][col] and lines[i][col].connectivity.down then
                assert.equals(down_id(lines[i][col]), up_id(cell))
            end
        end
    end
end

describe("pane.boundary_below (§6.2)", function()
    it("reports every lane flowing down out of a row, by column", function()
        local items, opts = fixture()
        local main = columns.layout(opts, items)
        local b = pane.boundary_below(main, 2) -- below t2
        -- two lanes cross down: the trunk (→ t3) and the side branch (→ b1)
        local tcol = find_col(b, "t3")
        local bcol = find_col(b, "b1")
        assert.is_not_nil(tcol)
        assert.is_not_nil(bcol)
        assert.is_true(tcol ~= bcol)
    end)
end)

describe("pane.split_boundary (§6.2)", function()
    it("continues lanes whose parent is in the pane, terminates the rest", function()
        local items, opts = fixture()
        local main = columns.layout(opts, items)
        local b = pane.boundary_below(main, 2)
        local pane_items = { items[4], items[5] } -- t3, t4 (anchors-only)
        local cont, term = pane.split_boundary(b, node_of(pane_items))
        assert.is_not_nil(find_col(cont, "t3")) -- trunk continues
        assert.is_not_nil(find_col(term, "b1")) -- folded branch terminates
        assert.is_nil(find_col(cont, "b1"))
        assert.is_nil(find_col(term, "t3"))
    end)
end)

describe("pane.footer (§6.2)", function()
    it("seeds the continuing lane so the seam matches the main view exactly", function()
        local items, opts = fixture()
        local main = columns.layout(opts, items)
        local b = pane.boundary_below(main, 2)
        local tcol, tlane = find_col(b, "t3")
        local pane_items = { items[4], items[5] } -- t3, t4
        local res = pane.footer(opts, pane_items, b, node_of(pane_items))

        -- The footer's top row is the seam: the trunk lane enters from above in
        -- the SAME column and colour the main view left it.
        local seam = res.rows[1].columns[tcol]
        assert.is_not_nil(seam)
        assert.is_true(seam.connectivity.up)
        assert.equals(tlane.id, seam.id)
        assert.equals(tlane.color, seam.color)
        -- The trunk continues down to its root, one continuous id.
        assert.is_true(res.rows[1].columns[tcol].connectivity.down)
        -- The folded branch did not seed the pane; it is reported as terminating.
        assert.is_not_nil(find_col(res.terminate, "b1"))
        assert_continuous(res.rows)
    end)

    it("translates the seam parent through node_of into a collapsed lane", function()
        local items, opts = fixture()
        local main = columns.layout(opts, items)
        local b = pane.boundary_below(main, 2)
        local tcol, tlane = find_col(b, "t3")
        -- a collapsed head standing for the trunk tail (t3..t4); node_of maps the
        -- real seam parent t3 to it, so the seed must terminate at the head.
        local head = { hash = "H", collapsed = true, region = { "t3", "t4" },
            parents = {}, children = {}, refs = {} }
        local res = pane.footer(opts, { { type = "commit", commit = head } }, b,
            { t3 = head, t4 = head })
        local seam = res.rows[1].columns[tcol]
        assert.is_not_nil(seam)
        assert.is_true(seam.connectivity.up)  -- enters from the seam
        assert.equals(tlane.id, seam.id)
        assert.is_true(seam.has_commit or false) -- the head node sits here (lane ends)
    end)
end)

-- The seam separator render_pane draws below the header: a bar per lane leaving
-- the bottom row downward (into the main view). Including it makes the grid a
-- closed picture so the wires-connect checker sees the seam-bound tips connect.
local function seam_sep(bottom)
    local sep = {}
    for j, cell in ipairs(bottom.columns) do
        local lane
        for _, s in ipairs(cell.lanes or {}) do
            if s.connectivity.down then lane = s; break end
        end
        sep[j] = lane
            and { connectivity = { up = true, down = true },
                lanes = { { connectivity = { up = true, down = true }, id = lane.id, color = lane.color } } }
            or { connectivity = {}, lanes = {} }
    end
    return { columns = sep }
end

-- Render a header's rows (plus the seam separator) to a glyph grid and run the
-- wires-connect checker.
local function header_grid_errors(opts, rows)
    local full = vim.list_extend({}, rows)
    full[#full + 1] = seam_sep(rows[#rows])
    return h.check_grid(h.render_grid(opts, full), opts)
end

-- Every boundary lane must appear as a down-lane in the header's bottom row, in
-- the same column and with the same id (the seam matches the main view exactly).
local function assert_seam_match(rows, boundary)
    local bottom = rows[#rows].columns
    for col, lane in pairs(boundary) do
        local cell = bottom[col]
        assert.is_not_nil(cell)
        local found
        for _, s in ipairs(cell.lanes or {}) do
            if s.connectivity.down and s.id == lane.id then found = true end
        end
        assert.is_true(found,
            ("seam lane id %s missing at col %d of the header bottom row"):format(tostring(lane.id), col))
    end
end

-- No row may render an ordinary commit node: every node cell must be a ◍ marker
-- (collapsed). Junctions/linear runs are node-less; only heads carry a node.
local function assert_no_regular_commits(rows)
    for ri, r in ipairs(rows) do
        for ci, cell in ipairs(r.columns) do
            if cell.has_commit then
                assert.is_true(cell.commit and cell.commit.collapsed or false,
                    ("row %d col %d renders a non-collapsed node"):format(ri, ci))
            end
        end
    end
end

-- No two ◍ heads may share a colour. Each head is a distinct branch tip, so it must
-- read as a distinct colour — the regression: HEAD and dev both drawn the same colour
-- with one lane between them. (Stronger than the per-row distinct-colour check: heads
-- on different rows must still differ.)
local function assert_distinct_head_colours(rows, ctx)
    local by_colour = {}
    for ri, r in ipairs(rows) do
        for _, cell in ipairs(r.columns or {}) do
            if cell.has_commit and cell.color ~= nil then
                assert.is_nil(by_colour[cell.color],
                    (ctx or "") .. (" two heads share colour %s (rows %s, %d)"):format(
                        tostring(cell.color), tostring(by_colour[cell.color]), ri))
                by_colour[cell.color] = ri
            end
        end
    end
end

-- The header must never invent heads: the number of ◍ heads cannot exceed the number
-- of SEEDS — the lanes crossing the cutoff plus any pinned anchor whose tip sits above
-- the cutoff without crossing it (a disconnected anchor still gets one labelled head).
-- Each seed terminates at most once; merges only REDUCE the head count. A blowup — 27
-- heads from 2 crossing lanes — fails here. `extra` = the non-crossing pinned tips.
local function assert_heads_le_crossing(rows, boundary, extra, ctx)
    local crossing = 0
    for _ in pairs(boundary) do crossing = crossing + 1 end
    local heads = 0
    for _, r in ipairs(rows) do
        for _, cell in ipairs(r.columns or {}) do
            if cell.has_commit then heads = heads + 1 end
        end
    end
    assert.is_true(heads <= crossing + (extra or 0),
        (ctx or "") .. (" %d heads but only %d crossing lanes (+%d pinned)"):format(
            heads, crossing, extra or 0))
end

-- The header's heads must sit in the SAME left-right order as the graph: for any two
-- heads, the one whose main-view column is further left must be further left in the
-- header too. Catches the bottom-up sweep ordering heads by which it reached first.
local function assert_head_order(rows, col_of, ctx)
    local heads = {} -- { header_col, main_col }
    for _, r in ipairs(rows) do
        for ci, cell in ipairs(r.columns or {}) do
            if cell.has_commit and cell.commit then
                local mc = col_of(cell.commit)
                if mc then heads[#heads + 1] = { hc = ci, mc = mc } end
            end
        end
    end
    table.sort(heads, function(a, b) return a.mc < b.mc end)
    for i = 2, #heads do
        if heads[i].mc ~= heads[i - 1].mc then
            assert.is_true(heads[i].hc > heads[i - 1].hc,
                (ctx or "") .. (" head order ≠ graph (main %d→%d but header %d→%d)"):format(
                    heads[i - 1].mc, heads[i].mc, heads[i - 1].hc, heads[i].hc))
        end
    end
end

-- A branch's colour in the header must equal its colour in the graph (lane_of), so the
-- summary reads consistently with the main view — UNLESS the main view recycled that
-- colour onto another concurrent header lane (then one is legitimately de-collided). We
-- assert the no-clash case: a head whose main-view colour is unique among the heads.
--
-- Two kinds of head are EXEMPT, both because the seam-never-switches rule pins their
-- colour so it CAN'T also be set to lane_of:
--  * Convergence head — a head where ≥2 lanes merge (the cell has horizontal arms): a
--    dead-end junction whose colour is pinned by the lanes converging into it.
--  * Crossing-lane head — a head on a boundary lane (id ≤ boundary_max): the lane carries
--    its boundary colour straight up to the head. When the main view changed colour at a
--    junction that `condense` spliced away, the header shows a straight lane with NO
--    junction to switch at, so it legitimately keeps the boundary colour (this is the
--    desired dev/HEAD behaviour: a crossing lane's head reads in its seam colour).
-- Only an above-seam head (a fresh-id fork child / in-header merge continuation) must
-- match its graph colour.
local function assert_head_colour_matches_graph(rows, lane_of, boundary, ctx)
    local boundary_ids = {}
    for _, l in pairs(boundary or {}) do if l.id ~= nil then boundary_ids[l.id] = true end end
    -- Every head's rendered colour (exempt or not) — a graph colour already shown by
    -- ANOTHER head means the main view recycled it onto two header-concurrent lanes, so a
    -- de-collision off it is legitimate (the palette-recycling limit), not a drift.
    local shown = {}
    for _, r in ipairs(rows) do
        for _, cell in ipairs(r.columns or {}) do
            if cell.has_commit and cell.commit then shown[cell.color] = (shown[cell.color] or 0) + 1 end
        end
    end
    local heads = {}
    for _, r in ipairs(rows) do
        for _, cell in ipairs(r.columns or {}) do
            if cell.has_commit and cell.commit then
                local exempt = boundary_ids[cell.id] or false
                for _, s in ipairs(cell.lanes or {}) do
                    local c = s.connectivity or {}
                    if c.left or c.right then exempt = true end -- convergence
                    if boundary_ids[s.id] and c.down then exempt = true end -- crossing lane
                end
                if not exempt then
                    local l = lane_of(cell.commit)
                    heads[#heads + 1] = { cell = cell, mc = l and l.color }
                end
            end
        end
    end
    for _, hd in ipairs(heads) do
        if hd.mc then
            -- legitimate de-collision: another head already shows this graph colour
            local others = (shown[hd.mc] or 0) - (hd.cell.color == hd.mc and 1 or 0)
            if others == 0 then
                assert.equals(hd.mc, hd.cell.color,
                    (ctx or "") .. " a head's colour drifted from its graph colour")
            end
        end
    end
end



-- Run the full header pipeline on a laid-out DAG: read the up-boundary at the seam
-- line, rebuild the focused sub-DAG (continue_up), and lay it out (header).
-- `seam_pos` is the order index of the cutoff line. Returns res, boundary, cond.
local function header_of(items, opts, seam_pos, pinned)
    pinned = pinned or {}
    local main = columns.layout(opts, items)
    local idx, lane_main = {}, {}
    local node_col = {}
    for i, it in ipairs(items) do
        idx[it.commit.hash] = i
        local pl = main[i].parent_lanes
        if pl and pl[1] then lane_main[it.commit.hash] = { id = pl[1].id, color = pl[1].color } end
        for j, cell in ipairs(main[i].columns or {}) do
            if cell.has_commit and cell.commit then node_col[cell.commit.hash] = j end
        end
    end
    local seam_line = main[seam_pos].split or main[seam_pos].columns
    local boundary = pane.boundary_of(seam_line, true)
    local tips = {}
    for _, it in ipairs(items) do
        local c = it.commit
        if idx[c.hash] < seam_pos then
            for _, r in ipairs(c.refs or {}) do
                if pinned[r.name] then tips[#tips + 1] = c; break end
            end
        end
    end
    local cond = pane.continue_up(boundary, tips, pinned, function(n) return idx[n.hash] end, seam_pos)
    -- main-view lane { id, color } per node's branch (its tip), so each branch keeps
    -- its own distinct colour (matching the graph) — mirrors graph.lua's lane_of.
    local function lane_of(n) return n and lane_main[(n.tip and n.tip.hash) or n.hash] end
    local function col_of(n) return n and node_col[(n.tip and n.tip.hash) or n.hash] end
    return pane.header(cond.items, boundary, cond.node_of_hash, lane_of, col_of), boundary, cond, idx, lane_of, col_of
end

-- The minimal-subgraph oracle (mirrors continue_up Pass 1): a **confluence** is a
-- commit reached going UP (via children, above the cutoff) by ≥2 DISTINCT seeds —
-- each boundary column is a seed, as is each pinned anchor tip. These are the only
-- places an off-screen lane legitimately *interconnects*; an unpinned head that is
-- neither a confluence nor a seam head is an irrelevant head the header must NOT show.
local function confluences_of(items, idx, boundary, seam_pos, pinned)
    pinned = pinned or {}
    local function above(c) return c and idx[c.hash] and idx[c.hash] < seam_pos end
    local reach = {} -- hash → { seed-id → true }
    local function seedwalk(start, sid)
        if not start then return end
        reach[start.hash] = reach[start.hash] or {}; reach[start.hash][sid] = true
        local seen, stack = { [start.hash] = true }, { start }
        while #stack > 0 do
            local c = stack[#stack]; stack[#stack] = nil
            for _, ch in ipairs(c.children or {}) do
                if above(ch) then
                    reach[ch.hash] = reach[ch.hash] or {}; reach[ch.hash][sid] = true
                    if not seen[ch.hash] then seen[ch.hash] = true; stack[#stack + 1] = ch end
                end
            end
        end
    end
    for col, l in pairs(boundary) do seedwalk(l.begin, "c" .. tostring(col)) end
    for _, it in ipairs(items) do
        local c = it.commit
        for _, r in ipairs(c.refs or {}) do
            if pinned[r.name] and above(c) then seedwalk(c, "t" .. c.hash); break end
        end
    end
    local conf = {}
    for hash, r in pairs(reach) do
        local n = 0; for _ in pairs(r) do n = n + 1 end
        if n >= 2 then conf[hash] = true end
    end
    return conf
end

-- Every rendered ◍ head must be legitimate: a pinned anchor (carries refs), a
-- crossing lane's own terminus (its `begin` — an isolated seam lane ending at its
-- tip, drawn continuously up from the seam), or a confluence output (a junction's
-- merged lane that dead-ends). Anything else is an irrelevant head the minimal header
-- must not introduce (the gpu regression: an unpinned branch that connects to nothing).
local function assert_no_irrelevant_heads(rows, conf, boundary, ctx)
    local begin_hash = {}
    for _, l in pairs(boundary or {}) do if l.begin then begin_hash[l.begin.hash] = true end end
    for _, r in ipairs(rows) do
        for _, cell in ipairs(r.columns) do
            if cell.has_commit and cell.commit and cell.commit.collapsed then
                local hash = cell.commit.hash
                local pinned_head = cell.commit.refs and #cell.commit.refs > 0
                if not pinned_head and not begin_hash[hash] and not conf[hash] then
                    assert.is_true(false, (ctx or "") .. " irrelevant head " .. tostring(hash))
                end
            end
        end
    end
end

describe("pane.header — focused rebuild, laid out seam-up (§6.2)", function()
    it("a crossing lane's head ABOVE the cutoff is always shown (lane continuity)", function()
        -- The most basic case the invariant protects: one branch, two consecutive
        -- commits g1->g2; the cutoff is over the FIRST (g1 covered, g2 the seam).
        -- g1 (the head) MUST appear in the header — the lane cannot stop at the seam.
        local items = h.dag({
            { "g1", { "g2" } },
            { "g2", { "base" } },
            { "base", {} },
        })
        local opts = h.big_opts()
        local res, boundary, cond = header_of(items, opts, 2) -- seam at g2; g1 above
        local present = {}
        for _, it in ipairs(cond.items) do present[it.commit.hash] = true end
        assert.is_true(present.g1, "the head g1 was dropped — lane stopped at the seam")
        assert_seam_match(res.rows, boundary)
        assert_continuous(res.rows)
        assert.same({}, header_grid_errors(opts, res.rows))
    end)

    it("terminates an isolated crossing lane at the seam — its unrelated forks are pruned", function()
        -- Two real branches feat/topic fork from m1; the cutoff is BELOW m1 (at base),
        -- so only the merged trunk crosses as a SINGLE lane. With nothing pinned, that
        -- lane connects to no anchor and to no other crossing lane, so per the minimal
        -- model it terminates at the seam with ONE head — the unpinned feat/topic forks
        -- are irrelevant and must NOT appear (the "no unnecessary heads" rule).
        local items = h.dag({
            { "feat1", { "feat2" } },
            { "topic1", { "topic2" } },
            { "feat2", { "m1" } },
            { "topic2", { "m1" } },
            { "m1", { "base" } },
            { "base", {} },
        })
        local opts = h.big_opts()
        local res, boundary, cond, idx = header_of(items, opts, 6) -- seam at base (below the fork)
        local present = {}
        for _, it in ipairs(cond.items) do present[it.commit.hash] = true end
        assert.is_nil(present.feat1, "feat1 is irrelevant (no anchor/seed) and must be pruned")
        assert.is_nil(present.topic1, "topic1 is irrelevant and must be pruned")
        assert.is_true(present.m1, "the crossing lane must terminate at the seam with a head")
        assert_no_irrelevant_heads(res.rows, confluences_of(items, idx, boundary, 6), boundary)
        assert_seam_match(res.rows, boundary)
        assert_continuous(res.rows)
        assert.same({}, header_grid_errors(opts, res.rows))
    end)

    it("prunes an unpinned branch forking off a pinned anchor's mainline; anchors junction", function()
        -- HEAD (pinned) runs h1->h2->ca; a busy common ancestor `ca` is on HEAD's spine,
        -- and a feature `gpu` plus another pinned branch `dev` both fork off `ca`. With
        -- the cutoff BELOW ca only ca's lane crosses. In the minimal model gpu connects
        -- to nothing (its own tip only) → PRUNED; the two anchors (HEAD, dev) and their
        -- meeting at `ca` are what the header shows — `ca` is a confluence/junction.
        local items = h.dag({
            { "h1", { "h2" } },   -- HEAD tip
            { "gpu", { "ca" } },  -- feature forks off ca (unpinned, connects to nothing)
            { "dev", { "ca" } },  -- another pinned branch forks off ca
            { "h2", { "ca" } },
            { "ca", { "x" } },    -- common ancestor, on HEAD's first-parent spine
            { "x", {} },
        })
        items[1].commit.refs = { { name = "head" } }
        items[3].commit.refs = { { name = "dev" } }
        local opts = h.big_opts()
        -- seam at x (index 6), below ca: only ca's lane crosses.
        local res, boundary, cond, idx = header_of(items, opts, 6, { head = true, dev = true })
        local nb = 0; for _ in pairs(boundary) do nb = nb + 1 end
        assert.equals(1, nb) -- exactly one lane crosses the seam (ca's mainline)
        local present = {}
        for _, it in ipairs(cond.items) do present[it.commit.hash] = true end
        assert.is_nil(present.gpu, "gpu connects to nothing and must be pruned")
        assert.is_true(present.h1, "the HEAD anchor tip must be shown")
        assert.is_true(present.dev, "the dev anchor tip must be shown")
        -- ca carries two useful up-children (the HEAD and dev spines), so it is kept as
        -- a node-less junction where the anchors diverge — not pruned, not a head.
        assert.is_true(present.ca, "ca is where the two anchors diverge — a junction")
        assert_no_irrelevant_heads(res.rows, confluences_of(items, idx, boundary, 6, { head = true, dev = true }), boundary)
        assert_seam_match(res.rows, boundary)
        assert_continuous(res.rows)
        assert.same({}, header_grid_errors(opts, res.rows))
    end)

    it("collapses an internal bubble on a pinned spine (its two sides reconverge)", function()
        -- master (pinned) m1->M->m2->m3->m4; a feature f1 forks off m3 and merges back at
        -- M, entirely above the cutoff. Both sides of the bubble (m2 and f1) reconverge to
        -- the SAME node m3, so it is internal noise — not a relationship between two
        -- branches — and the minimal header collapses it: the master spine is a single
        -- continuous lane to the anchor, with no junction and no stray head for f1/M.
        local items = h.dag({
            { "m1", { "M" } },
            { "M", { "m2", "f1" } },
            { "m2", { "m3" } },
            { "f1", { "m3" } },
            { "m3", { "m4" } },
            { "m4", {} },
        })
        items[1].commit.refs = { { name = "master" } }
        local opts = h.big_opts()
        local res, boundary, cond, idx = header_of(items, opts, 6, { master = true }) -- seam at m4
        local present = {}
        for _, it in ipairs(cond.items) do present[it.commit.hash] = true end
        assert.is_nil(present.f1) -- the bubble's side commit condenses away
        assert.is_nil(present.M, "an internal reconverging bubble collapses — no junction")
        assert.is_true(present.m1, "only the master anchor head remains")
        assert_no_irrelevant_heads(res.rows, confluences_of(items, idx, boundary, 6, { master = true }), boundary)
        assert_seam_match(res.rows, boundary)
        assert_continuous(res.rows)
        assert.same({}, header_grid_errors(opts, res.rows))
        assert_no_regular_commits(res.rows)
    end)

    it("prunes an above-cutoff bubble unrelated to any anchor or seed", function()
        -- The same bubble but with NOTHING pinned: the single crossing lane connects to
        -- no anchor and no other seed, so the whole off-screen run (incl. the M/f1
        -- bubble) collapses — the lane terminates at the seam with one head. The minimal
        -- header shows no junction and no stray heads for irrelevant topology.
        local items = h.dag({
            { "m1", { "M" } },
            { "M", { "m2", "f1" } },
            { "m2", { "m3" } },
            { "f1", { "m3" } },
            { "m3", { "m4" } },
            { "m4", {} },
        })
        local opts = h.big_opts()
        local res, boundary, cond, idx = header_of(items, opts, 6) -- seam at m4
        local present = {}
        for _, it in ipairs(cond.items) do present[it.commit.hash] = true end
        assert.is_nil(present.f1)
        assert.is_nil(present.M, "an unrelated bubble must be pruned, not shown as a junction")
        assert.is_true(present.m3, "the crossing lane terminates at the seam with a head")
        assert_no_irrelevant_heads(res.rows, confluences_of(items, idx, boundary, 6), boundary)
        assert_seam_match(res.rows, boundary)
        assert_continuous(res.rows)
        assert.same({}, header_grid_errors(opts, res.rows))
    end)

    it("colours each shown branch distinctly (matching the graph)", function()
        -- Three PINNED branches fork from a common ancestor; the cutoff is below it, so
        -- the single crossing lane diverges up into all three anchors. Each anchor head
        -- must keep its OWN colour — the regression was every fork child sharing one.
        local items = h.dag({
            { "b1", { "ca" } }, { "b2", { "ca" } }, { "b3", { "ca" } },
            { "ca", { "base" } }, { "base", {} },
        })
        items[1].commit.refs = { { name = "b1" } }
        items[2].commit.refs = { { name = "b2" } }
        items[3].commit.refs = { { name = "b3" } }
        local opts = h.big_opts()
        local res = header_of(items, opts, 5, { b1 = true, b2 = true, b3 = true })
        local head_colors, seen = {}, {}
        for _, r in ipairs(res.rows) do
            for _, cell in ipairs(r.columns) do
                if cell.has_commit then head_colors[#head_colors + 1] = cell.color end
            end
        end
        assert.equals(3, #head_colors)
        for _, c in ipairs(head_colors) do
            assert.is_nil(seen[c], "two branch heads share colour " .. tostring(c))
            seen[c] = true
        end
    end)

    it("collapses the shared future above a meeting point (no head blowup)", function()
        -- Two crossing lanes a, b meet at the confluence M; ABOVE M their shared future
        -- forks into many branches (t1..t5). Those forks don't relate to a or b, so the
        -- minimal header must collapse them — the merged lane shows ONE continuation, not
        -- five heads. heads must not exceed the crossing lanes (the line-122 blowup).
        local items = h.dag({
            { "t1", { "u" } }, { "t2", { "u" } }, { "t3", { "u" } },
            { "u", { "M" } }, { "t4", { "M" } }, { "t5", { "M" } },
            { "M", { "a", "b" } },
            { "a", { "base" } }, { "b", { "base" } }, { "base", {} },
        })
        local opts = h.big_opts()
        local res, boundary, cond, idx = header_of(items, opts, 10) -- seam at base; a,b cross
        local nb = 0; for _ in pairs(boundary) do nb = nb + 1 end
        assert.equals(2, nb)
        assert.is_true(cond.items ~= nil)
        assert.is_true(confluences_of(items, idx, boundary, 10).M == true)
        assert_heads_le_crossing(res.rows, boundary, 0)
        assert_distinct_head_colours(res.rows)
        assert_seam_match(res.rows, boundary)
        assert_continuous(res.rows)
        assert.same({}, header_grid_errors(opts, res.rows))
    end)

    it("orders forked heads left-to-right to match the graph (no bottom-up swap)", function()
        -- dev and HEAD fork from a shared lane s. In the graph dev sits in the LEFT
        -- column (it forks first), HEAD in the right. The header — though it lays out
        -- bottom-up — must place them in the SAME left-right order, by main-view column,
        -- not by which head the sweep reached first.
        local items = h.dag({
            { "dev", { "s" } }, { "head", { "s" } }, { "s", { "base" } }, { "base", {} },
        })
        items[1].commit.refs = { { name = "dev" } }
        items[2].commit.refs = { { name = "head" } }
        local opts = h.big_opts()
        local main = columns.layout(opts, items)
        -- the graph's column for each head
        local gcol = {}
        for i, it in ipairs(items) do
            for j, cell in ipairs(main[i].columns or {}) do
                if cell.has_commit and cell.commit then gcol[cell.commit.hash] = j end
            end
        end
        assert.is_true(gcol.dev < gcol.head) -- dev is left in the graph
        local res, _, _, _, _, col_of = header_of(items, opts, 4, { head = true, dev = true })
        local hcol = {}
        for _, r in ipairs(res.rows) do
            for ci, cell in ipairs(r.columns) do
                if cell.has_commit and cell.commit.refs and cell.commit.refs[1] then
                    hcol[cell.commit.refs[1].name] = ci
                end
            end
        end
        assert.is_true(hcol.dev ~= nil and hcol.head ~= nil)
        assert.is_true(hcol.dev < hcol.head, "header must keep dev left of HEAD, as in the graph")
        assert_head_order(res.rows, col_of) -- the general invariant, on this clean case
    end)

    it("keeps each pinned anchor's colour STABLE and DISTINCT across cutoffs", function()
        -- Two long-lived pinned branches, head (h1..h4) and dev (d1..d4), both off a
        -- shared base. As the cutoff scrolls, each anchor's header colour must stay the
        -- SAME (its main-view colour, which is fixed) and the two must stay DISTINCT —
        -- the regression was the anchors swapping ids/colours between cutoffs (HEAD 1→2,
        -- dev 3→1) because the recolour grabbed whichever lane it saw first.
        local items = h.dag({
            { "h1", { "h2" } }, { "h2", { "h3" } }, { "h3", { "h4" } }, { "h4", { "base" } },
            { "d1", { "d2" } }, { "d2", { "d3" } }, { "d3", { "d4" } }, { "d4", { "base" } },
            { "base", {} },
        })
        items[1].commit.refs = { { name = "head" } } -- h1
        items[5].commit.refs = { { name = "dev" } }  -- d1
        local opts = h.big_opts()
        local main = columns.layout(opts, items)
        local idx, lane_main = {}, {}
        for i, it in ipairs(items) do
            idx[it.commit.hash] = i
            local pl = main[i].parent_lanes
            if pl and pl[1] then lane_main[it.commit.hash] = { id = pl[1].id, color = pl[1].color } end
        end
        local want_head = lane_main.h1 and lane_main.h1.color
        local want_dev = lane_main.d1 and lane_main.d1.color
        assert.is_true(want_head ~= want_dev) -- distinct in the main view to begin with

        -- The colour of a named anchor's head in the header, at a given cutoff.
        local function anchor_colour(res, name)
            for _, r in ipairs(res.rows) do
                for _, cell in ipairs(r.columns) do
                    if cell.has_commit and cell.commit.refs then
                        for _, rf in ipairs(cell.commit.refs) do
                            if rf.name == name then return cell.color end
                        end
                    end
                end
            end
        end
        -- Every cutoff that leaves both anchors above it.
        for si = 2, 9 do
            local res = header_of(items, opts, si, { head = true, dev = true })
            local hc, dc = anchor_colour(res, "head"), anchor_colour(res, "dev")
            if hc and dc then
                assert.equals(want_head, hc, ("si=%d head colour drifted"):format(si))
                assert.equals(want_dev, dc, ("si=%d dev colour drifted"):format(si))
                assert.is_true(hc ~= dc, ("si=%d head and dev share a colour"):format(si))
            end
        end
    end)

    it("packs isolated seam heads onto a shared row; a pinned anchor keeps its own", function()
        -- A fork at the seam `X` diverges into three unpinned tips and one pinned. Each
        -- unpinned tip is an isolated crossing lane → a bare ◍ on the seam row, packed
        -- together; the pinned `master` is an anchor and keeps its own labelled line.
        local items = h.dag({
            { "b1", { "X" } }, { "b2", { "X" } }, { "b3", { "X" } }, { "m1", { "X" } },
            { "X", { "base" } }, { "base", {} },
        })
        items[4].commit.refs = { { name = "master" } }
        local opts = h.big_opts()
        local res = header_of(items, opts, 5, { master = true }) -- seam AT X (its split line)
        local max_heads, master_alone = 0, false
        for _, r in ipairs(res.rows) do
            local n, has_master = 0, false
            for _, cell in ipairs(r.columns) do
                if cell.has_commit then
                    n = n + 1
                    local rf = cell.commit.refs and cell.commit.refs[1]
                    if rf and rf.name == "master" then has_master = true end
                end
            end
            if n > max_heads then max_heads = n end
            if has_master and n == 1 then master_alone = true end
        end
        assert.is_true(max_heads >= 3, "isolated seam heads were not packed onto one row")
        assert.is_true(master_alone, "the pinned anchor was packed with other heads")
    end)

    it("draws a crossing lane merging into a pinned anchor as a node-less junction", function()
        -- master (pinned) m1->M->m2->m3 and a feature x1->x2 that merges into master
        -- at M; both cross the cutoff at m4/x3. The merge must render as a junction.
        local items = h.dag({
            { "m1", { "M" } },
            { "M", { "m2", "x1" } },
            { "m2", { "m3" } },
            { "x1", { "x2" } },
            { "m3", { "m4" } },
            { "x2", { "x3" } },
            { "m4", { "base" } },
            { "x3", { "base" } },
            { "base", {} },
        })
        items[1].commit.refs = { { name = "master" } }
        local opts = h.big_opts()
        local res, boundary, cond = header_of(items, opts, 7, { master = true }) -- seam at m4
        -- Both master and feat cross the seam.
        assert.is_not_nil(find_col_begin(boundary, "m3"))
        assert.is_not_nil(find_col_begin(boundary, "x2"))
        -- M is kept as a node-less junction (≥2 parents in the focused set).
        local junction
        for _, it in ipairs(cond.items) do if it.commit.hash == "M" then junction = it.commit end end
        assert.is_not_nil(junction)
        assert.is_true(junction.junction)
        -- master's tip is the only labelled node; the junction carries no node glyph.
        assert_seam_match(res.rows, boundary)
        assert_continuous(res.rows)
        assert.same({}, header_grid_errors(opts, res.rows))
        assert_no_regular_commits(res.rows)
    end)

    it("converges two unpinned crossing lanes at a confluence head (rule 4 dead-end)", function()
        -- a1 and b1 both cross the cutoff and MERGE at M above it; M then dead-ends (its
        -- own tip). Nothing is pinned, yet the merge is relevant because two seeds meet
        -- there: M is a confluence, drawn as the head where the two lanes converge — and
        -- the dangling continuation above is just M itself (no extra branch invented).
        local items = h.dag({
            { "M", { "a1", "b1" } }, -- M merges the two crossing lanes
            { "a1", { "base" } },
            { "b1", { "base" } },
            { "base", {} },
        })
        local opts = h.big_opts()
        local res, boundary, cond, idx = header_of(items, opts, 4) -- seam at base; a1,b1 cross
        local nb = 0; for _ in pairs(boundary) do nb = nb + 1 end
        assert.equals(2, nb)
        local present = {}
        for _, it in ipairs(cond.items) do present[it.commit.hash] = true end
        assert.is_true(present.M, "the two lanes must converge at M")
        local conf = confluences_of(items, idx, boundary, 4)
        assert.is_true(conf.M, "M is reached by both seeds — a confluence")
        assert.is_nil(present.a1) -- the linear approach splices away
        assert.is_nil(present.b1)
        assert_no_irrelevant_heads(res.rows, conf, boundary)
        assert_seam_match(res.rows, boundary)
        assert_continuous(res.rows)
        assert.same({}, header_grid_errors(opts, res.rows))
    end)

    it("keeps nested confluences — a lower junction feeding a higher one", function()
        -- Three crossing lanes a1,b1,c1. a1,b1 merge at M2; M2 and c1 merge at `top`.
        -- Both meeting points must survive: M2 a node-less junction, `top` the head where
        -- all three converge. (Tests multi-level confluence detection.)
        local items = h.dag({
            { "top", { "M2", "c1" } },
            { "M2", { "a1", "b1" } },
            { "a1", { "base" } },
            { "b1", { "base" } },
            { "c1", { "base" } },
            { "base", {} },
        })
        local opts = h.big_opts()
        local res, boundary, cond, idx = header_of(items, opts, 6) -- seam at base; a1,b1,c1 cross
        local present = {}
        for _, it in ipairs(cond.items) do present[it.commit.hash] = true end
        assert.is_true(present.M2, "the lower junction M2 must be kept")
        assert.is_true(present.top, "the upper confluence top must be kept")
        local conf = confluences_of(items, idx, boundary, 6)
        assert.is_true(conf.M2 and conf.top, "both meeting points are confluences")
        assert_no_irrelevant_heads(res.rows, conf, boundary)
        assert_seam_match(res.rows, boundary)
        assert_continuous(res.rows)
        assert.same({}, header_grid_errors(opts, res.rows))
        assert_no_regular_commits(res.rows)
    end)

    it("gives a pinned anchor a labelled head; an unpinned crossing lane a bare ◍", function()
        -- master (pinned) and feature each a lone crossing lane up to its own tip.
        local items = h.dag({
            { "m1", { "m2" } },
            { "f1", { "f2" } },
            { "m2", { "base" } },
            { "f2", { "base" } },
            { "base", {} },
        })
        items[1].commit.refs = { { name = "master" } }
        items[2].commit.refs = { { name = "feature" } }
        local opts = h.big_opts()
        local res = header_of(items, opts, 3, { master = true }) -- seam at m2 (both lanes pass)
        local labels = {}
        for _, r in ipairs(res.rows) do
            for _, ref in ipairs((r.commit and r.commit.refs) or {}) do labels[ref.name] = true end
        end
        assert.is_true(labels.master)   -- anchor labelled
        assert.is_nil(labels.feature)   -- unpinned tip is bare (no label)
        assert_no_regular_commits(res.rows)
    end)
end)

describe("pane.header_seam — whole-commit cutoff (§6.2)", function()
    -- Items as the display layer sees them: each may carry a `split` (above) and/or
    -- `merge` (below) virtual line. The top item's split is scrolled off.
    local function items(specs)
        local out = {}
        for i, s in ipairs(specs) do
            out[i] = { commit = { hash = "n" .. i }, split = s.split or nil, merge = s.merge or nil }
        end
        return out
    end

    it("rounds to a commit boundary with no virtual lines", function()
        local it = items({ {}, {}, {}, {}, {} })
        local s = assert(pane.header_seam(it, 1, 3))
        assert.equals(4, s.idx)       -- covered 1,2,3 (3 rows); seam at 4
        assert.equals("columns", s.kind)
        assert.equals(3, s.cover)
    end)

    it("covers a commit's trailing MERGE line with it (the off-by-one regression)", function()
        -- commit 3 has a merge line (block height 2). A naive screen-row cutoff at 3
        -- rows would land ON commit 3's merge line, leaving its commit covered but its
        -- merge dangling. The seam must instead cover commit 3 whole → seam at 4.
        local it = items({ {}, {}, { merge = {} }, {}, {} })
        local s = assert(pane.header_seam(it, 1, 3))
        assert.equals(4, s.idx)   -- 1,2 (2 rows) then 3+merge (2 rows) = 4 ≥ 3 ⇒ seam at 4
        assert.equals(4, s.cover) -- the overlay grows by the merge line (the +1 padding)
    end)

    it("reads the SPLIT line when the seam commit forks (its children are off-screen)", function()
        local it = items({ {}, {}, {}, { split = {} }, {} })
        local s = assert(pane.header_seam(it, 1, 3))
        assert.equals(4, s.idx)
        assert.equals("split", s.kind) -- commit 4's split (its diverging children) is the seam
    end)

    it("ignores the top item's split (scrolled off above the viewport)", function()
        local it = items({ { split = {} }, {}, {} })
        local s = assert(pane.header_seam(it, 1, 1))
        assert.equals(2, s.idx) -- top's split does not count; one row (top's columns) covered
    end)

    it("honours a per-commit height (dual label mode = 2 rows)", function()
        local it = items({ {}, {}, {}, {} })
        local s = assert(pane.header_seam(it, 1, 3, function() return 2 end))
        assert.equals(3, s.idx) -- 1,2 cover 4 rows ≥ 3 ⇒ seam at 3
        assert.equals(4, s.cover)
    end)

    it("returns nil past the last commit", function()
        local it = items({ {}, {} })
        assert.is_nil(pane.header_seam(it, 1, 99))
    end)
end)

describe("pane.cap — header keeps a continuous seam-adjacent slice (§6.2)", function()
    it("keeps the contiguous bottom rows (no torn middle), reports the elided tips", function()
        local rows = {}
        for i = 1, 10 do rows[i] = { columns = {}, n = i } end
        local capped, elided = pane.cap(rows, 4, true)
        assert.equals(4, #capped)
        -- A CONTIGUOUS slice ending at the seam (rows 7..10) — so every lane runs
        -- unbroken from the seam up; the far tips (1..6) elide into `+N above`.
        assert.equals(7, capped[1].n)
        assert.equals(8, capped[2].n)
        assert.equals(9, capped[3].n)
        assert.equals(10, capped[4].n) -- the seam-adjacent row, always
        assert.equals(6, elided)       -- 10 - 4 hidden (rendered as "+N above")
    end)

    it("preserves vertical id-continuity of a real header when capped", function()
        -- A tall header (six crossing lanes all converging at M above the cutoff)
        -- capped must stay continuous: a contiguous seam slice never breaks a lane (the
        -- regression: eliding the middle left lanes dangling with no head/junction).
        local fan = { { "M", { "c1", "c2", "c3", "c4", "c5", "c6" } } }
        for i = 1, 6 do fan[#fan + 1] = { "c" .. i, { "base" } } end
        fan[#fan + 1] = { "base", {} }
        local items = h.dag(fan)
        local opts = h.big_opts()
        local res = header_of(items, opts, 8) -- seam at base; six lanes converge at M
        local capped = pane.cap(res.rows, math.max(2, #res.rows - 2), true)
        -- The capped slice must remain a valid, continuous header.
        assert_continuous(capped)
        assert.same({}, header_grid_errors(opts, capped))
    end)
end)

describe("pane.condense (§6.2)", function()
    -- Projection node graph (anchors collapsed): master tip A and dev tip D fork
    -- at J; B and K are ref-less linear pass-throughs that should splice out.
    local function graph()
        local A = { hash = "A", refs = { {} }, collapsed = true, region = { "A" } }
        local B = { hash = "B", refs = {}, collapsed = true, region = { "B" } }
        local D = { hash = "D", refs = { {} }, collapsed = true, region = { "D" } }
        local J = { hash = "J", refs = {}, junction = true, collapsed = false, region = {} }
        local K = { hash = "K", refs = {}, collapsed = true, region = { "K" } }
        local R = { hash = "root", refs = {}, collapsed = true, region = { "root" } }
        A.parents, A.children = { B }, {}
        B.parents, B.children = { J }, { A }
        D.parents, D.children = { J }, {}
        J.parents, J.children = { K }, { B, D }
        K.parents, K.children = { R }, { J }
        R.parents, R.children = {}, { K }
        return { A, B, D, J, K, R } -- newest-first
    end
    local function by_hash(items)
        local m = {}
        for _, it in ipairs(items) do m[it.commit.hash] = it.commit end
        return m
    end

    it("keeps ref heads, junctions and roots; splices linear pass-throughs", function()
        local c = pane.condense(graph())
        local n = by_hash(c.items)
        assert.equals(4, #c.items) -- A, D, J, root (B, K spliced)
        assert.is_not_nil(n.A)
        assert.is_not_nil(n.D)
        assert.is_not_nil(n.J)
        assert.is_not_nil(n.root)
        assert.is_nil(n.B)
        assert.is_nil(n.K)
    end)

    it("re-points edges across the spliced runs", function()
        local c = pane.condense(graph())
        local n = by_hash(c.items)
        assert.equals("J", n.A.parents[1].hash)     -- A -> (B) -> J
        assert.equals("J", n.D.parents[1].hash)
        assert.equals("root", n.J.parents[1].hash)  -- J -> (K) -> root
        assert.equals("J", n.root.children[1].hash)
        local jc = {}
        for _, ch in ipairs(n.J.children) do jc[ch.hash] = true end
        assert.is_true(jc.A and jc.D)
    end)

    it("maps spliced hashes to the next kept node toward the root", function()
        local c = pane.condense(graph())
        assert.equals("J", c.node_of_hash.B.hash)    -- B between A and J -> J
        assert.equals("root", c.node_of_hash.K.hash) -- K between J and root -> root
        assert.equals("A", c.node_of_hash.A.hash)
    end)

    it("with anchor_names, a non-anchor ref does not keep a node", function()
        -- X (master tip) -> T (tag-only) -> root: T must splice away.
        local X = { hash = "X", refs = { { name = "master" } }, collapsed = true, region = { "X" } }
        local T = { hash = "T", refs = { { name = "v1" } }, collapsed = true, region = { "T" } }
        local R = { hash = "root", refs = {}, collapsed = true, region = { "root" } }
        X.parents, X.children = { T }, {}
        T.parents, T.children = { R }, { X }
        R.parents, R.children = {}, { T }
        local c = pane.condense({ X, T, R }, { master = true })
        local n = by_hash(c.items)
        assert.is_not_nil(n.X)                       -- master tip kept
        assert.is_not_nil(n.root)
        assert.is_nil(n.T)                           -- tag-only node spliced
        assert.equals("root", n.X.parents[1].hash)   -- X -> (T) -> root
        assert.equals("root", c.node_of_hash.T.hash) -- T folds toward the root
        assert.equals(1, #n.X.refs)                  -- only the anchor ref kept
    end)

    it("splices a false junction (flagged junction but degree-1 projected)", function()
        -- F is flagged a junction but its projected edges are 1-in-1-out (the
        -- non-anchor side was dropped), so it must splice like a pass-through.
        local X = { hash = "X", refs = { { name = "m" } }, collapsed = true, region = { "X" } }
        local F = { hash = "F", refs = {}, junction = true, collapsed = false, region = { "F" } }
        local R = { hash = "root", refs = {}, collapsed = true, region = { "root" } }
        X.parents, X.children = { F }, {}
        F.parents, F.children = { R }, { X } -- 1 parent, 1 child despite the flag
        R.parents, R.children = {}, { F }
        local c = pane.condense({ X, F, R }, { m = true })
        local n = by_hash(c.items)
        assert.is_nil(n.F)                         -- false junction spliced away
        assert.equals("root", n.X.parents[1].hash) -- X -> (F) -> root
    end)

    it("renders the root as a real node (no collapsed count)", function()
        local c = pane.condense(graph())
        local n = by_hash(c.items)
        assert.is_false(n.root.collapsed) -- root marker, not ◍ (N)
    end)
end)

describe("pane.cap — root always visible (§6.2)", function()
    it("keeps the seam-nearest rows and always the root when over the cap", function()
        local rows = {}
        for i = 1, 10 do rows[i] = { columns = {}, n = i } end
        local capped = pane.cap(rows, 4)
        assert.equals(4, #capped)
        assert.equals(1, capped[1].n)   -- seam-nearest kept
        assert.equals(3, capped[3].n)
        assert.equals(10, capped[4].n)  -- the root (last) always kept
    end)

    it("returns the rows unchanged when within the cap", function()
        local rows = { { columns = {}, n = 1 }, { columns = {}, n = 2 } }
        local capped = pane.cap(rows, 5)
        assert.equals(2, #capped)
        assert.equals(10, pane.cap({ { n = 10 } }, 1)[1].n) -- single row stays the root
    end)
end)

describe("pane.continue — active lanes reach a root (§6.2)", function()
    -- A trunk A->B->C->root and a branch X->Y->B (its first parent rejoins the
    -- trunk at B). h.dag wires .parents/.children; we build a boundary of the two
    -- lanes (A and X) crossing the seam.
    local function dag()
        local items, by = h.dag({
            { "A", { "B" } },
            { "X", { "Y" } },
            { "Y", { "B" } },
            { "B", { "C" } },
            { "C", { "root" } },
            { "root", {} },
        }), nil
        local map = {}
        for _, it in ipairs(items) do map[it.commit.hash] = it.commit end
        return map
    end
    local function boundary(map)
        return {
            [1] = { id = 1, color = 1, parent = map.A, begin = map.A },
            [2] = { id = 2, color = 2, parent = map.X, begin = map.X },
        }
    end
    local function by_hash(items)
        local m = {}
        for _, it in ipairs(items) do m[it.commit.hash] = it.commit end
        return m
    end

    it("continues both lanes; they converge at B and reach the root", function()
        local map = dag()
        local cond = pane.continue(boundary(map))
        local n = by_hash(cond.items)
        assert.is_not_nil(n.root)         -- a root is present
        assert.equals(0, #n.root.parents) -- and it is a real root
        assert.is_false(n.root.junction)  -- rendered as a real node, not a join
        -- B is the junction where the two lanes meet; the bare entry tips A and X
        -- splice away, so both lanes' seeds terminate AT B (converging there).
        assert.is_not_nil(n.B)
        assert.is_true(n.B.junction)
        assert.equals(n.B, cond.node_of_hash.A)
        assert.equals(n.B, cond.node_of_hash.X)
    end)

    it("every node's first-parent chain reaches a root (never cut off)", function()
        local map = dag()
        local cond = pane.continue(boundary(map))
        for _, it in ipairs(cond.items) do
            local c, guard = it.commit, 0
            while #c.parents > 0 do
                c = c.parents[1]
                guard = guard + 1
                assert.is_true(guard < 100, "first-parent chain did not terminate")
            end
            assert.equals(0, #c.parents) -- ended at a real root
        end
    end)

    it("introduces no non-active branch (the merged-in b1 is absent)", function()
        -- Seam boundary has only the trunk lane (parent t2); b1 merged into t1
        -- above the seam and must not appear in the footer.
        local items = h.dag({
            { "t1", { "t2", "b1" } },
            { "t2", { "t3" } },
            { "b1", { "t3" } },
            { "t3", {} },
        })
        local map = {}
        for _, it in ipairs(items) do map[it.commit.hash] = it.commit end
        local cond = pane.continue({ [1] = { id = 1, color = 1, parent = map.t2 } })
        local n = by_hash(cond.items)
        assert.is_nil(n.b1)   -- the non-active branch is not introduced
        assert.is_not_nil(n.t3) -- the trunk reaches its root
    end)
end)

-- On a single rendered row, two lanes with DIFFERENT ids must not share a colour
-- (concurrent lanes are visually distinct). With big_opts colour is a 1:1 proxy for
-- id, so this catches the "every branch one colour" regression.
local function assert_distinct_colours(rows)
    for ri, r in ipairs(rows) do
        local by_color = {}
        for _, cell in ipairs(r.columns) do
            for _, s in ipairs(cell.lanes or {}) do
                if s.id ~= nil and s.color ~= nil then
                    local prev = by_color[s.color]
                    assert.is_true(prev == nil or prev == s.id,
                        ("row %d: lanes %s and %s share colour %s"):format(ri, tostring(prev), tostring(s.id), tostring(s.color)))
                    by_color[s.color] = s.id
                end
            end
        end
    end
end

-- A lane id may TERMINATE (end at a ◍ head — a down-lane with no up) at most once in
-- a header. Two heads ending the same id means two branches were drawn as one lane —
-- the colour/id mixup (pinned branches sharing id 1 instead of 1 and 3).
local function assert_unique_terminations(rows, ctx)
    local ended = {} -- lane id → row it terminated on
    for ri, r in ipairs(rows) do
        for _, cell in ipairs(r.columns or {}) do
            if cell.has_commit then -- a ◍ head: find the lane that ends here (down, not up)
                for _, s in ipairs(cell.lanes or {}) do
                    local c = s.connectivity or {}
                    if s.id ~= nil and c.down and not c.up then
                        assert.is_nil(ended[s.id], (ctx or "") ..
                            (" lane id %s terminates twice (rows %s and %d)"):format(
                                tostring(s.id), tostring(ended[s.id]), ri))
                        ended[s.id] = ri
                    end
                end
            end
        end
    end
end

-- No header CONTENT row may be purely vertical bars (every occupied cell only up/down,
-- no node and no junction turn). Such a row carries no information — a condensed graph
-- splices linear runs, so every row must justify itself with a head or a junction. The
-- only all-vertical rows allowed are the seam-separator padding render_pane appends
-- (not part of `rows`).
local function assert_no_idle_rows(rows, ctx)
    for ri, r in ipairs(rows) do
        local occupied, meaningful = false, false
        for _, cell in ipairs(r.columns or {}) do
            local c = cell.connectivity or {}
            if cell.has_commit or c.left or c.right then meaningful = true end
            if cell.has_commit or c.up or c.down or c.left or c.right then occupied = true end
        end
        assert.is_true(meaningful or not occupied,
            (ctx or "") .. (" row %d is purely vertical bars (no head/junction)"):format(ri))
    end
end

describe("pane.header — fuzz invariants (§6.2)", function()
    -- Feed random DAGs (deliberately LARGE so the header is tall and the invariants
    -- are stressed — the header is NOT capped here, unlike production) through the
    -- real layout, rebuild a header at every cutoff, and assert: the seam matches the
    -- main view (every crossing lane continues), the rendered grid passes "wires must
    -- connect" (no lane dangles — termination), lanes stay id-continuous, concurrent
    -- lanes have distinct colours, and no ordinary commit node leaks in.
    it("holds across a random sweep", function()
        for seed = 1, 60 do
            local n = 8 + (seed % 13) -- 8..20 commits — many branches, tall headers
            local items = h.dag(h.random_dag(n, seed))
            -- Mark every real tip (no children) a head ref; pin a deterministic
            -- subset so the pinned-anchor path is exercised too.
            for _, it in ipairs(items) do
                if #it.commit.children == 0 then it.commit.refs = { { name = it.commit.hash } } end
            end
            local pinned = {}
            if items[1] and seed % 2 == 0 then pinned[items[1].commit.hash] = true end

            -- Every cutoff that leaves at least one item above it.
            for si = 2, #items do
                local opts2 = h.big_opts()
                local main = columns.layout(opts2, items)
                local seam_line = main[si].split or main[si].columns
                local boundary = pane.boundary_of(seam_line, true)
                if next(boundary) then
                    local res, _, cond, idx, lane_of, col_of = header_of(items, opts2, si, pinned)
                    local ctx = ("seed=%d n=%d si=%d"):format(seed, n, si)
                    if #res.rows > 0 then
                        -- Continuity/termination: every crossing lane appears at the
                        -- seam (so none is dropped) and the grid has no dangling wires.
                        assert_seam_match(res.rows, boundary)
                        assert_continuous(res.rows)
                        assert_no_regular_commits(res.rows)
                        assert_distinct_colours(res.rows)
                        assert_distinct_head_colours(res.rows, ctx)
                        assert_unique_terminations(res.rows, ctx)
                        assert_head_colour_matches_graph(res.rows, lane_of, boundary, ctx)
                        -- non-crossing pinned tips above the cutoff (each a lone head)
                        local begins = {}
                        for _, l in pairs(boundary) do if l.begin then begins[l.begin.hash] = true end end
                        local extra = 0
                        for _, it in ipairs(items) do
                            local c = it.commit
                            if idx[c.hash] and idx[c.hash] < si and not begins[c.hash] then
                                for _, rf in ipairs(c.refs or {}) do
                                    if pinned[rf.name] then extra = extra + 1; break end
                                end
                            end
                        end
                        assert_heads_le_crossing(res.rows, boundary, extra, ctx)
                        assert_no_idle_rows(res.rows, ctx)
                        local errs = header_grid_errors(opts2, res.rows)
                        assert.same({}, errs, ctx .. " grid: " .. table.concat(errs, "; "))
                        -- Minimality: no irrelevant heads — every ◍ is a pinned anchor,
                        -- a seam head, or a confluence output (never an unrelated branch).
                        assert_no_irrelevant_heads(res.rows, confluences_of(items, idx, boundary, si, pinned), boundary, ctx)
                    end
                end
            end
        end
    end)
end)
