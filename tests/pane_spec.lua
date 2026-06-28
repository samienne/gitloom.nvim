--- Context-pane layout core (spec §6.2): boundary extraction + the footer
--- builder, tested purely (no snacks). The pane shares commit identities with
--- the main layout (one DAG), as production shares repo.order.
local pane = require("gitloom.graph.pane")
local columns = require("gitloom.graph.columns")
local h = require("tests.graph_helpers")
local get_column_chars = require("gitloom.graph")._internal.get_column_chars

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

describe("pane.mark_pane_cone (§6.2 reachability emphasis)", function()
    -- A diamond of condensed pane nodes: root R <- M <- {A, B} <- T (T merges A,B).
    -- `.parents` point older (down, toward roots); `.children` point newer (up).
    local function diamond()
        local n = {}
        for _, hh in ipairs({ "R", "M", "A", "B", "T" }) do n[hh] = { hash = hh, parents = {}, children = {} } end
        local function link(child, parent)
            table.insert(n[child].parents, n[parent])
            table.insert(n[parent].children, n[child])
        end
        link("M", "R"); link("A", "M"); link("B", "M"); link("T", "A"); link("T", "B")
        return n
    end

    it("footer (down) marks an in-cone crossing lane's ancestors, not its siblings", function()
        local n = diamond()
        -- Seed at A (an in-cone crossing lane continuing into the footer): everything
        -- below A is a pivot-ancestor (A, its parent M, the root R); the sibling B and
        -- the newer T are NOT.
        local cone = pane.mark_pane_cone({ n.A }, "down")
        assert.is_true(cone.A and cone.M and cone.R)
        assert.is_nil(cone.B)
        assert.is_nil(cone.T)
    end)

    it("up (header) marks an in-cone crossing lane's descendants, not its ancestors", function()
        local n = diamond()
        -- Seed at M (a crossing lane continuing up into the header): everything above M
        -- is a pivot-descendant (M, both fork children A and B, the merge T); the older
        -- root R is NOT.
        local cone = pane.mark_pane_cone({ n.M }, "up")
        assert.is_true(cone.M and cone.A and cone.B and cone.T)
        assert.is_nil(cone.R)
    end)

    it("a confluence below an in-cone lane is in-cone from the join on", function()
        local n = diamond()
        -- A is in-cone, B is not. Going down they meet at M: M (and R below it) are in
        -- the cone via A, even though B — A's sibling that also reaches M — is dimmed.
        local cone = pane.mark_pane_cone({ n.A }, "down")
        assert.is_true(cone.M) -- the confluence is lit
        assert.is_nil(cone.B)  -- the sibling that merges in is not
    end)

    it("an empty seed set yields an empty cone", function()
        assert.same({}, pane.mark_pane_cone({}, "down"))
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
    -- A disconnected pinned anchor renders as a lone, wireless ◍ head (§6.2), so floating
    -- ◍ heads are allowed in the header grid.
    return h.check_grid(h.render_grid(opts, full), opts, false, true)
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
                local wired = false
                for _, s in ipairs(cell.lanes or {}) do
                    local c = s.connectivity or {}
                    if c.left or c.right then exempt = true end -- convergence
                    if boundary_ids[s.id] and c.down then exempt = true end -- crossing lane
                    if c.up or c.down or c.left or c.right then wired = true end
                end
                -- A lone DISCONNECTED anchor renders wireless (no up/down/left/right); its
                -- colour can legitimately de-collide (it has no continuity to preserve), so
                -- it is exempt from the graph-colour match.
                if not wired then exempt = true end
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

-- A branch head's lane id must equal its MAIN-VIEW lane id (lane_of), so the header is a
-- faithful continuation of the graph — a branch never silently switches to a synthetic
-- id. Crossing/boundary lanes are pinned at the seam (covered by assert_seam_match) and a
-- merge-tip can legitimately end on a sibling lane, so both are checked elsewhere; here we
-- cover lanes BORN above the seam (fork children), whose id IS the head's main-view id.
-- A genuine de-collision (the main view recycled that id onto another header-concurrent
-- lane, so it is taken) is allowed.
local function assert_head_id_matches_graph(rows, lane_of, boundary, ctx)
    local boundary_ids = {}
    for _, l in pairs(boundary or {}) do if l.id ~= nil then boundary_ids[l.id] = true end end
    local used = {} -- every lane id rendered anywhere (to detect a forced de-collision)
    for _, r in ipairs(rows) do
        for _, cell in ipairs(r.columns or {}) do
            for _, s in ipairs(cell.lanes or {}) do if s.id ~= nil then used[s.id] = true end end
        end
    end
    for _, r in ipairs(rows) do
        for _, cell in ipairs(r.columns or {}) do
            if cell.has_commit and cell.commit and not boundary_ids[cell.id] then
                local l = lane_of(cell.commit)
                local mv = l and l.id
                if mv ~= nil and cell.id ~= mv then
                    -- allowed only when the graph id is taken by another header lane
                    assert.is_true(used[mv] == true,
                        (ctx or "") .. (" a branch head switched id: header %s vs graph %s"):format(
                            tostring(cell.id), tostring(mv)))
                end
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
    -- main-view lane { id, color } per node's branch (its tip), so each branch keeps
    -- its own distinct colour (matching the graph) — mirrors graph.lua's lane_of. Passed
    -- into continue_up too: the tracked-lane induce matches lanes by id (§6.2).
    local function lane_of(n) return n and lane_main[(n.tip and n.tip.hash) or n.hash] end
    local function col_of(n) return n and node_col[(n.tip and n.tip.hash) or n.hash] end
    local cond = pane.continue_up(boundary, tips, pinned, function(n) return idx[n.hash] end, seam_pos,
        nil, lane_of)
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
-- must not introduce (the stray-fork regression: an unpinned branch that connects to nothing).
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

    it("never shows working-tree virtual commits — the highest head is the topmost real commit (§4.2/§6.2)", function()
        -- u (untracked) -> s (staged) -> HEAD stack above HEAD, then real commits.
        -- The cutoff is at c1, so the virtual stack and HEAD are all above the seam.
        -- The header must stop at HEAD (the topmost REAL commit) and never draw the
        -- virtual nodes u/s — they are the live state, not topology.
        local items = h.dag({
            { "u", { "s" } },
            { "s", { "H" } },
            { "H", { "c1" } },
            { "c1", { "c2" } },
            { "c2", {} },
        })
        items[1].commit.virtual = "untracked"
        items[2].commit.virtual = "staged"
        items[3].commit.refs = { { name = "HEAD" } }
        local opts = h.big_opts()
        local res, boundary, cond = header_of(items, opts, 4, { HEAD = true }) -- seam at c1
        local present = {}
        for _, it in ipairs(cond.items) do present[it.commit.hash] = true end
        assert.is_nil(present.u, "the untracked virtual commit must not appear in the header")
        assert.is_nil(present.s, "the staged virtual commit must not appear in the header")
        assert.is_nil(cond.node_of_hash.u)
        assert.is_nil(cond.node_of_hash.s)
        assert.is_true(present.H, "HEAD (the topmost real commit) must be the highest head")
        -- And nothing virtual leaks into the rendered rows either.
        for _, r in ipairs(res.rows) do
            for _, cell in ipairs(r.columns or {}) do
                if cell.has_commit and cell.commit then
                    assert.is_true(cell.commit.hash ~= "u" and cell.commit.hash ~= "s",
                        "a virtual node was rendered: " .. tostring(cell.commit.hash))
                end
            end
        end
        assert_seam_match(res.rows, boundary)
        assert_continuous(res.rows)
        assert.same({}, header_grid_errors(opts, res.rows))
    end)

    it("hides the header when the only off-screen-newer content is virtual (§4.2/§6.2)", function()
        -- Viewport top is HEAD; only the virtual stack (u, s) sits above the seam.
        -- With virtual commits excluded there is no real topology to show, so the
        -- focused rebuild is empty (the window glue then renders no header).
        local items = h.dag({
            { "u", { "s" } },
            { "s", { "H" } },
            { "H", { "c1" } },
            { "c1", {} },
        })
        items[1].commit.virtual = "untracked"
        items[2].commit.virtual = "staged"
        items[3].commit.refs = { { name = "HEAD" } }
        local opts = h.big_opts()
        local _, _, cond = header_of(items, opts, 3, { HEAD = true }) -- seam at H; only u,s above
        assert.equals(0, #cond.items, "a virtual-only off-screen region yields no header")
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
        -- and a feature `feat` plus another pinned branch `dev` both fork off `ca`. With
        -- the cutoff BELOW ca only ca's lane crosses. In the minimal model feat connects
        -- to nothing (its own tip only) → PRUNED; the two anchors (HEAD, dev) and their
        -- meeting at `ca` are what the header shows — `ca` is a confluence/junction.
        local items = h.dag({
            { "h1", { "h2" } },   -- HEAD tip
            { "feat", { "ca" } },  -- feature forks off ca (unpinned, connects to nothing)
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
        assert.is_nil(present.feat, "feat connects to nothing and must be pruned")
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

    it("declutters a 2x2 parallel-merge diamond — clean parallel lanes, no crisscross (§6.2)", function()
        -- Two crossing lanes (P1, P2) both fork up to the SAME two children — two anchor
        -- merges TM (-> master) and FH (-> feat) — so drawing all four edges crisscrosses the
        -- header with rake arms (the feature/repo-switching case). The declutter keeps each
        -- child's FIRST-parent edge and drops the redundant cross-arm: TM connects via P1,
        -- FH via P2 -> two clean parallel lanes. The regression keeps all four edges, leaving
        -- TM/FH as junctions — caught here by asserting NEITHER merge stays a junction.
        local items = h.dag({
            { "master", { "TM" } },
            { "feat", { "FH" } },
            { "TM", { "P1", "P2" } }, -- trunk merge: first parent P1
            { "FH", { "P2", "P1" } }, -- feature merge: first parent P2
            { "P1", { "base" } }, -- crossing lane
            { "P2", { "base" } }, -- crossing lane
            { "base", {} },
        })
        items[1].commit.refs = { { name = "master" } }
        items[2].commit.refs = { { name = "feat" } }
        local opts = h.big_opts()
        local res, boundary, cond = header_of(items, opts, 7, { master = true, feat = true }) -- seam at base
        local present, junctions = {}, {}
        for _, it in ipairs(cond.items) do
            present[it.commit.hash] = true
            -- a real junction = a node-bearing row with ≥2 kept parents/children
            local c = it.commit
            if (#(c.parents or {}) >= 2) or (#(c.children or {}) >= 2) then junctions[c.hash] = true end
        end
        assert.is_true(present.master, "the master anchor is shown")
        assert.is_true(present.feat, "the feat anchor is shown")
        -- The declutter resolves the diamond to a matching — each merge keeps ONE parent, so
        -- NEITHER TM nor FH stays a junction. (Without it both have 2 parents -> crisscross.)
        assert.is_nil(junctions.TM, "TM declutters to one parent — not a junction")
        assert.is_nil(junctions.FH, "FH declutters to one parent — not a junction")
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
        -- five heads. heads must not exceed the crossing lanes (the shared-future blowup).
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

    it("gives each fork head the SAME lane id as the main view (no switch to a synthetic id)", function()
        -- Same two-branch shape: head (h1..h4) continues the trunk off `base`, dev
        -- (d1..d4) forks. Each head must render with ITS OWN main-view lane id — head keeps
        -- the boundary/trunk id, dev keeps dev's graph id — never a fresh synthetic id and
        -- never the trunk's id (the dump bug: dev kept head's id=1 while head got a fresh
        -- id). The id must also stay stable as the cutoff scrolls.
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
        assert.is_true(lane_main.h1.id ~= lane_main.d1.id) -- distinct lanes in the graph

        local function head_id(res, name)
            for _, r in ipairs(res.rows) do
                for _, cell in ipairs(r.columns) do
                    if cell.has_commit and cell.commit.refs then
                        for _, rf in ipairs(cell.commit.refs) do
                            if rf.name == name then return cell.id end
                        end
                    end
                end
            end
        end
        for si = 2, 9 do
            local res = header_of(items, opts, si)
            local hid, did = head_id(res, "head"), head_id(res, "dev")
            if hid and did then
                assert.equals(lane_main.h1.id, hid, ("si=%d head id ≠ graph"):format(si))
                assert.equals(lane_main.d1.id, did, ("si=%d dev id ≠ graph (switched to a synthetic id)"):format(si))
                assert.is_true(hid ~= did, ("si=%d head and dev share an id"):format(si))
            end
        end
    end)

    it("renders a fork arm in the BRANCH's colour without alternation (dev-branch regression)", function()
        -- The live bug: in the header the dev branch's horizontal arm alternated between the
        -- trunk colour (id 1) and the branch colour (id 3). One lane crosses the seam; above
        -- it F forks into HEAD-line, dev-line and extra branches that push dev to a
        -- NON-ADJACENT column (so the arm spans a passthrough — the 2-connector case the
        -- alternation needs). The diverging arm must read as the BRANCH (dev), end-to-end
        -- through the real renderer, with NO colour reappearing (no alternation); the
        -- pivot's own vertical stays the trunk colour. Earlier tests missed it because they
        -- checked the cell glyphs (top_lane), not the inter-column CONNECTOR scan.
        local items = h.dag({
            { "h1", { "h2" } }, { "h2", { "F" } },
            { "x", { "F" } }, -- a branch BEFORE dev so dev lands on main-view lane 3
            { "d1", { "d2" } }, { "d2", { "F" } },
            { "yy", { "F" } },
            { "F", { "trunk1" } }, { "trunk1", { "base" } }, { "base", {} },
        })
        items[1].commit.refs = { { name = "HEAD", kind = "head" } } -- h1
        items[4].commit.refs = { { name = "dev", kind = "local" } } -- d1
        local opts = h.big_opts()
        opts.palette = opts.palette or {}
        opts.palette.tracks = {}
        for i = 1, 32 do opts.palette.tracks[i] = "Track" .. i end
        local res, _, _, _, lane_of = header_of(items, opts, 8, { HEAD = true, dev = true })
        -- The fork-fan row: a node-less row with a horizontal run (a cell with left/right).
        local bus
        for _, r in ipairs(res.rows) do
            for _, cell in ipairs(r.columns or {}) do
                if cell.connectivity and (cell.connectivity.left or cell.connectivity.right)
                    and not cell.has_commit then bus = r; break end
            end
            if bus then break end
        end
        assert.is_not_nil(bus, "expected a fork-fan row with a horizontal run")
        local g = get_column_chars(opts, bus.columns, false)
        local seq = {}
        for _, hl in ipairs(g.highlight or {}) do seq[#seq + 1] = hl.hl end
        assert.is_true(#seq >= 3, "expected a multi-segment arm (a passthrough between pivot and dev)")
        -- (1) NO ALTERNATION: each colour forms a single contiguous run (the regression was
        --     the arm flipping trunk/branch/trunk/branch at each column).
        local started = {}
        for i, c in ipairs(seq) do
            if c ~= seq[i - 1] then
                assert.is_nil(started[c],
                    ("colour %s reappears (alternation) in [%s]"):format(c, g.text or ""))
                started[c] = true
            end
        end
        -- (2) The diverging arm is the BRANCH's (dev's) colour, not the trunk's: the arm
        --     glyphs (everything past the pivot's vertical, which is the first run) are dev's.
        local dev = lane_of({ hash = "d1" })
        assert.is_not_nil(dev)
        local dev_hl = opts.palette.tracks[dev.color]
        assert.equals(dev_hl, seq[#seq], ("arm tip is not dev's colour in [%s]"):format(g.text or ""))
        -- the arm is NOT the trunk colour (id 1) end-to-end — i.e. >1 colour on the row
        local distinct = {}
        for _, c in ipairs(seq) do distinct[c] = true end
        local n = 0; for _ in pairs(distinct) do n = n + 1 end
        assert.is_true(n >= 2, "the arm must differ from the trunk (branch colour), not be all id 1")
    end)

    it("shows a DISCONNECTED pinned anchor as a lone labelled head (§6.2)", function()
        -- The live merge-at-cutoff bug: at a deep cutoff the lanes crossing the seam lead UP into a
        -- collapsed branch (B), not to the pinned anchor; HEAD is seeded but disconnected
        -- from the boundary, so the boundary-driven sweep never reaches it. A pinned anchor
        -- must ALWAYS be visible, so it renders as a lone labelled ◍ head even with nothing
        -- connecting it to the seam.
        local opts = h.big_opts()
        local B = { hash = "B", refs = {}, parents = {}, children = {}, collapsed = true }
        local H = { hash = "H", refs = { { name = "HEAD" } }, parents = {}, children = {}, collapsed = true }
        local items = { { commit = H }, { commit = B } } -- newest-first: anchor on top, B at seam
        local boundary = { [1] = { id = 1, color = 1, begin = B } }
        local node_of = { B = B, H = H }
        local lm = { B = { id = 1, color = 1 }, H = { id = 2, color = 2 } }
        local nc = { B = 1, H = 2 }
        local function lane_of(n) return n and lm[n.hash] end
        local function col_of(n) return n and nc[n.hash] end
        local res = pane.header(items, boundary, node_of, lane_of, col_of)
        local found
        for _, r in ipairs(res.rows) do
            for _, cell in ipairs(r.columns or {}) do
                if cell.has_commit and cell.commit and cell.commit.refs then
                    for _, rf in ipairs(cell.commit.refs) do if rf.name == "HEAD" then found = true end end
                end
            end
        end
        assert.is_true(found, "the disconnected pinned anchor (HEAD) must render as a lone head")
        assert_seam_match(res.rows, boundary) -- the boundary lane still terminates at the seam
        assert_continuous(res.rows)
        assert.same({}, header_grid_errors(opts, res.rows))
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

    it("keeps a merge at the cutoff as a junction, connecting crossing lanes to the anchor (§6.2)", function()
        -- The merge-at-cutoff bug: a merge M sits just ABOVE the cutoff; its two parents are the
        -- two crossing lanes, BELOW the cutoff. In the above-cutoff induced graph M's
        -- parents are gone so it looks linear and was SPLICED — dropping the whole
        -- connection up to HEAD (which then rendered as a disconnected floating head). The
        -- per-edge seam terminals keep M a junction, so HEAD stays connected through it.
        local HEAD = { hash = "HEAD", refs = { { name = "HEAD" } }, parents = {}, children = {} }
        local t = { hash = "t", refs = {}, parents = {}, children = {} } -- trunk HEAD..M (splices)
        local M = { hash = "M", refs = {}, parents = {}, children = {} } -- the merge at the cutoff
        local p1 = { hash = "p1", parents = {}, children = {} } -- crossing lane, below the cutoff
        local p2 = { hash = "p2", parents = {}, children = {} } -- crossing lane, below the cutoff
        HEAD.parents = { t }; t.children = { HEAD }
        t.parents = { M }; M.children = { t }
        M.parents = { p1, p2 }; p1.children = { M }; p2.children = { M }
        local disp = { HEAD = 1, t = 2, M = 3, p1 = 4, p2 = 4 } -- p1,p2 at/below the cutoff (4)
        local function order_of(n) return disp[n.hash] end
        -- trunk HEAD..t..M all on lane id 1, so the tracked-lane walk follows it (§6.2).
        local lm = { HEAD = { id = 1, color = 1 }, t = { id = 1, color = 1 }, M = { id = 1, color = 1 } }
        local function lane_of(n) return n and lm[n.hash] end
        local boundary = { [1] = { id = 1, color = 1, begin = M }, [2] = { id = 2, color = 2, begin = M } }
        local cond = pane.continue_up(boundary, { HEAD }, { HEAD = true }, order_of, 4, nil, lane_of)
        local present = {}
        for _, it in ipairs(cond.items) do present[it.commit.hash] = it.commit end
        assert.is_not_nil(present.M, "the merge at the cutoff must be kept (a junction), not spliced")
        assert.is_not_nil(present.HEAD, "HEAD must be kept")
        -- HEAD connects DOWN to M (the trunk t splices through) — not orphaned/floating
        assert.equals("M", present.HEAD.parents[1] and present.HEAD.parents[1].hash)
        assert.equals("HEAD", present.M.children[1] and present.M.children[1].hash)
        assert.equals(present.M, cond.node_of_hash["M"]) -- the boundary begin resolves to M itself
    end)

    it("a merge at the cutoff keeps the trunk ONE colour through the junction (§6.2)", function()
        -- A bump rejoining the trunk at a merge just above the cutoff must NOT switch the
        -- trunk to a fresh id/colour: the seam lane keeps its colour straight up to the
        -- anchor. (The "lane colours switched" regression: the merge handed the trunk off
        -- to a fresh id that overlapped the arriving lane at the junction row and
        -- de-collided off the seam colour.)
        local HEAD = { hash = "HEAD", refs = { { name = "HEAD" } }, parents = {}, children = {} }
        local t = { hash = "t", refs = {}, parents = {}, children = {} }
        local M = { hash = "M", refs = {}, parents = {}, children = {} }
        local tp = { hash = "tp", parents = {}, children = {} }   -- trunk parent, below cutoff
        local bump = { hash = "bump", parents = {}, children = {} } -- bump, below cutoff
        HEAD.parents = { t }; t.children = { HEAD }
        t.parents = { M }; M.children = { t }
        M.parents = { tp, bump }; tp.children = { M }; bump.children = { M }
        local disp = { HEAD = 1, t = 2, M = 3, tp = 4, bump = 4 }
        local lm = { HEAD = { id = 1, color = 1 }, t = { id = 1, color = 1 }, M = { id = 1, color = 1 } }
        local function order_of(n) return disp[n.hash] end
        local function lane_of(n) return n and lm[n.hash] end
        local function col_of() return 1 end
        local boundary = { [1] = { id = 1, color = 1, begin = M }, [2] = { id = 38, color = 8, begin = M } }
        local cond = pane.continue_up(boundary, { HEAD }, { HEAD = true }, order_of, 4, nil, lane_of)
        local res = pane.header(cond.items, boundary, cond.node_of_hash, lane_of, col_of)
        local opts = h.big_opts()
        opts.palette = opts.palette or {}
        opts.palette.tracks = {}
        for i = 1, 32 do opts.palette.tracks[i] = "Track" .. i end
        local seam_hl = opts.palette.tracks[1] -- the boundary trunk colour (id 1 -> colour 1)
        -- The HEAD node and every glyph of the trunk lane (id 1) must render in the seam
        -- colour — the trunk never switches colour between the seam and the anchor.
        local head_hl
        for _, r in ipairs(res.rows) do
            for _, cell in ipairs(r.columns or {}) do
                if cell.has_commit and cell.commit and cell.commit.refs then
                    for _, rf in ipairs(cell.commit.refs) do
                        if rf.name == "HEAD" then
                            local g = get_column_chars(opts, r.columns, false)
                            head_hl = g.highlight and g.highlight[1] and g.highlight[1].hl
                        end
                    end
                end
            end
        end
        assert.equals(seam_hl, head_hl, "HEAD's lane drifted off the seam colour at the merge")
        assert_continuous(res.rows)
    end)

    it("keeps the trunk id through a COLLAPSED continuation at a merge (merge-at-cutoff) (§6.2)", function()
        -- The merge-at-cutoff anchor-severing bug: a merge M just above the cutoff continues up to HEAD
        -- through a COLLAPSED node. Its `lane_of` is the **collapsed head's first-parent lane**
        -- (its `parent_lanes[1]`, the trunk id 1) — keyed by the tip hash, NOT the tip's own
        -- (recycled) lane — so the tracked-lane walk (§6.2) follows it: lane 1 is tracked, ct
        -- is on it, and the seam id runs unbroken to HEAD.
        local HEAD = { hash = "HEAD", refs = { { name = "HEAD" } }, parents = {}, children = {} }
        local ct = { hash = "collapsed:trunk", collapsed = true, tip = { hash = "ct_tip" }, refs = {}, parents = {}, children = {} }
        local M = { hash = "M", refs = {}, parents = {}, children = {} }
        local bump = { hash = "collapsed:bump", collapsed = true, tip = { hash = "bp_tip" }, refs = {}, parents = {}, children = {} }
        local F = { hash = "F", parents = {}, children = {} }
        HEAD.parents = { ct }; ct.children = { HEAD }; ct.parents = { M }
        M.children = { ct }; M.parents = { F, bump }; bump.children = { M }; bump.parents = { F }; F.children = { M, bump }
        local disp = { HEAD = 1, ["collapsed:trunk"] = 50, M = 118, ["collapsed:bump"] = 119, F = 120 }
        -- ct's lane (keyed by tip hash) is the trunk's first-parent lane (id 1); bump's is 38.
        local lm = { HEAD = { id = 1, color = 1 }, ct_tip = { id = 1, color = 1 },
            M = { id = 1, color = 1 }, bp_tip = { id = 38, color = 8 } }
        local function order_of(n) return disp[n.hash] end
        local function lane_of(n) return n and lm[(n.tip and n.tip.hash) or n.hash] end
        local function col_of() return 1 end
        local boundary = { [1] = { id = 1, color = 1, begin = M }, [2] = { id = 38, color = 8, begin = bump } }
        local cond = pane.continue_up(boundary, { HEAD }, { HEAD = true }, order_of, 119, nil, lane_of)
        local res = pane.header(cond.items, boundary, cond.node_of_hash, lane_of, col_of)
        local head_id
        for _, r in ipairs(res.rows) do
            for _, cell in ipairs(r.columns or {}) do
                if cell.has_commit and cell.commit and cell.commit.refs then
                    for _, rf in ipairs(cell.commit.refs) do
                        if rf.name == "HEAD" then head_id = cell.id end
                    end
                end
            end
        end
        assert.equals(1, head_id, "HEAD must keep the trunk id (1), not switch to a fresh id at the merge")
        assert_seam_match(res.rows, boundary)
        assert_continuous(res.rows)
    end)

    it("connects a divergent pinned anchor DOWN its spine — never a floating head (§6.2)", function()
        -- dev (pinned) is divergent/ahead of master: its tip d1's first-parent spine
        -- d1->x->trunk reaches the trunk through `x` on a THIRD (untracked) lane, so the
        -- up-walk from the master crossing lane never reaches d1. The anchor down-connect
        -- must walk d1's spine to the trunk so dev renders connected, not as a floating
        -- labelled head (the regression behind the disconnected `(feature/repo-targeting)`).
        local d1 = { hash = "d1", refs = { { name = "dev" } }, parents = {}, children = {} }
        local x = { hash = "x", parents = {}, children = {} }
        local m1 = { hash = "m1", refs = { { name = "master" } }, parents = {}, children = {} }
        local trunk = { hash = "trunk", parents = {}, children = {} }
        local base = { hash = "base", parents = {}, children = {} }
        d1.parents = { x }; x.children = { d1 }; x.parents = { trunk }
        trunk.children = { m1, x }; m1.parents = { trunk }; trunk.parents = { base }; base.children = { trunk }
        local disp = { d1 = 1, m1 = 2, x = 3, trunk = 4, base = 5 }
        local lm = { d1 = { id = 2, color = 2 }, m1 = { id = 1, color = 1 },
            x = { id = 3, color = 3 }, trunk = { id = 1, color = 1 } }
        local function order_of(n) return disp[n.hash] end
        local function lane_of(n) return n and lm[n.hash] end
        local boundary = { [1] = { id = 1, color = 1, begin = trunk } } -- only the trunk crosses
        local cond = pane.continue_up(boundary, { m1, d1 }, { master = true, dev = true }, order_of, 5, nil, lane_of)
        local present = {}
        for _, it in ipairs(cond.items) do present[it.commit.hash] = it.commit end
        assert.is_not_nil(present.d1, "the dev anchor must be shown")
        assert.is_not_nil(present.m1, "the master anchor must be shown")
        assert.is_true(present.d1.parents and #present.d1.parents >= 1,
            "the divergent anchor must connect down its spine, not float")
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

    it("names the elided pinned anchors so off-screen branches stay visible (§6.2)", function()
        -- A tall header whose far tips are pinned anchors (HEAD, dev). Capping keeps the
        -- continuous seam-adjacent slice and drops the tip ROWS — but their anchor names
        -- must be reported so the `+N above` marker can name them. This is the elided-anchor
        -- bug: HEAD/dev were elided into a bare `+N above` with no indication they were up
        -- there.
        local rows = {}
        -- Row 1's anchor commit carries BOTH a branch and the HEAD marker (HEAD points at
        -- that branch) — the name surfaced must be HEAD, not the branch sharing the commit.
        rows[1] = { columns = {}, n = 1, pinned = true, commit = { refs = {
            { name = "feature/topic", kind = "local" }, { name = "HEAD", kind = "head" } } } }
        rows[2] = { columns = {}, n = 2, pinned = true, commit = { refs = { { name = "dev", kind = "local" } } } }
        for i = 3, 10 do rows[i] = { columns = {}, n = i } end
        local capped, elided, names = pane.cap(rows, 4, true)
        assert.equals(4, #capped)             -- the continuous seam-adjacent slice
        assert.equals(7, capped[1].n)         -- rows 7..10 kept (no torn middle)
        assert.equals(6, elided)              -- rows 1..6 elided
        assert.same({ "HEAD", "dev" }, names) -- HEAD preferred over the branch; one per anchor
    end)

    it("reports no anchor names when nothing pinned is elided", function()
        local rows = {}
        for i = 1, 10 do rows[i] = { columns = {}, n = i } end
        local _, _, names = pane.cap(rows, 4, true)
        assert.same({}, names)
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

    it("keeps the HEAD marker even when HEAD isn't the anchor name (§6.2)", function()
        -- HEAD points at branch `feat`; the pinned set is keyed by the BRANCH name (`feat`,
        -- = repo.head), NOT "HEAD". Condensing with anchor_names = { feat } must still keep
        -- the HEAD marker ref, or the header shows only `feat` and loses HEAD entirely.
        local A = { hash = "A", region = { "A" }, refs = {
            { name = "feat", kind = "local" }, { name = "HEAD", kind = "head" } } }
        local R = { hash = "R", region = { "R" }, refs = {} }
        A.parents, A.children = { R }, {}
        R.parents, R.children = {}, { A }
        local c = pane.condense({ A, R }, { feat = true }, true)
        local n = by_hash(c.items)
        assert.is_not_nil(n.A, "the anchor tip must be kept")
        local has_head, has_branch = false, false
        for _, rf in ipairs(n.A.refs or {}) do
            if rf.kind == "head" then has_head = true end
            if rf.name == "feat" then has_branch = true end
        end
        assert.is_true(has_head, "the HEAD marker must survive condense")
        assert.is_true(has_branch, "the branch it points at is kept too")
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
                        assert_head_id_matches_graph(res.rows, lane_of, boundary, ctx)
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

describe("pane.continue / condense — chunking hook (async pane build, §6.2)", function()
    -- A long linear first-parent chain c1 (tip) -> ... -> cN (root), with one
    -- boundary lane entering at the tip. Deep enough to cross the internal
    -- YIELD_EVERY threshold several times so the yield hook is exercised.
    local DEPTH = 6000
    local function deep_chain()
        local spec = {}
        for i = 1, DEPTH - 1 do spec[i] = { "c" .. i, { "c" .. (i + 1) } } end
        spec[DEPTH] = { "c" .. DEPTH, {} }
        local items = h.dag(spec)
        local map = {}
        for _, it in ipairs(items) do map[it.commit.hash] = it.commit end
        return map
    end
    local function boundary(map)
        return { [1] = { id = 1, color = 1, parent = map.c1, begin = map.c1 } }
    end
    local function hashes(cond)
        local hs = {}
        for _, it in ipairs(cond.items) do hs[#hs + 1] = it.commit.hash end
        table.sort(hs)
        return hs
    end

    it("invokes the yield hook on a deep walk", function()
        local map = deep_chain()
        local ticks = 0
        pane.continue(boundary(map), nil, nil, nil, function() ticks = ticks + 1 end)
        assert.is_true(ticks > 0, "yield hook was never called on a deep chain")
    end)

    it("produces output identical to the synchronous (no-yield) path", function()
        local map = deep_chain()
        local sync = pane.continue(boundary(map))
        local async = pane.continue(boundary(map), nil, nil, nil, function() end)
        assert.same(hashes(sync), hashes(async)) -- same kept nodes
        -- Same hash → node mapping for every member hash.
        local sn, an = 0, 0
        for _ in pairs(sync.node_of_hash) do sn = sn + 1 end
        for _ in pairs(async.node_of_hash) do an = an + 1 end
        assert.equals(sn, an)
        for hsh, node in pairs(sync.node_of_hash) do
            assert.equals(node.hash, async.node_of_hash[hsh].hash)
        end
    end)
end)
