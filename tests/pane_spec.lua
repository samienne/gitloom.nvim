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
        for _, ln in ipairs(h.row_lines(r)) do lines[#lines + 1] = ln.line end
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
                -- A main-view id of one of the head's OTHER edges (a merge's extra-parent
                -- lane) is still the graph's own lane, not a synthetic one: under carried
                -- refs (§5) a head's first-parent lane may END at a fork below it, where a
                -- better-ranked sibling continues, and the header then draws the head on
                -- the merge edge it does keep.
                local edge_ids = {}
                for _, p in ipairs(cell.commit.parents or {}) do
                    local e = lane_of(cell.commit, p)
                    if e and e.id ~= nil then edge_ids[e.id] = true end
                end
                if mv ~= nil and cell.id ~= mv and not edge_ids[cell.id] then
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
    local idx, lane_main, edge_main = {}, {}, {}
    local node_col = {}
    for i, it in ipairs(items) do
        idx[it.commit.hash] = i
        local pl = main[i].parent_lanes
        if pl and pl[1] then lane_main[it.commit.hash] = { id = pl[1].id, color = pl[1].color } end
        for _, l in ipairs(pl or {}) do
            edge_main[l.begin.hash .. ">" .. l.parent.hash] = { id = l.id, color = l.color }
        end
        for j, cell in ipairs(main[i].columns or {}) do
            if cell.has_commit and cell.commit then node_col[cell.commit.hash] = j end
        end
    end
    local seam_line = (main[seam_pos].above or {})[1] or main[seam_pos].columns
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
    -- With `p`, the lane of the EDGE n → p (a merge's second-parent edge is its own
    -- lane, §6.2 Colour), falling back to n's first-parent lane.
    local function key(n) return (n.tip and n.tip.hash) or n.hash end
    local function lane_of(n, p)
        if not n then return nil end
        return (p and p.hash and edge_main[key(n) .. ">" .. key(p)]) or lane_main[key(n)]
    end
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

    it("never de-collides a lane onto a pinned colour (§5.5/§6.2)", function()
        -- The same three anchors, but every branch reports ONE main-view colour (the
        -- main view recycles colours, so concurrent header lanes can arrive sharing
        -- one). Two of them must be de-collided — and a replacement colour must never
        -- be a pinned slot, which reads as its pinned branch.
        local items = h.dag({
            { "b1", { "ca" } }, { "b2", { "ca" } }, { "b3", { "ca" } },
            { "ca", { "base" } }, { "base", {} },
        })
        items[1].commit.refs = { { name = "b1" } }
        items[2].commit.refs = { { name = "b2" } }
        items[3].commit.refs = { { name = "b3" } }
        local opts = h.big_opts()
        local _, boundary, cond, _, lane_of, col_of = header_of(items, opts, 5, { b1 = true, b2 = true, b3 = true })
        local function shared(n)
            local l = lane_of(n)
            return l and { id = l.id, color = 9 }
        end
        local function heads(res)
            local out = {}
            for _, r in ipairs(res.rows) do
                for _, cell in ipairs(r.columns) do
                    if cell.has_commit then out[#out + 1] = cell.color end
                end
            end
            return out
        end
        -- A crossing lane keeps its boundary colour to the seam (never de-collided), so
        -- the pinned slots to avoid are the low ones it does NOT hold.
        local bc = {}
        for _, l in pairs(boundary) do bc[l.color] = true end
        local avoid = {}
        for k = 1, 4 do if not bc[k] then avoid[k] = k end end
        -- Teeth: without `avoid` a replacement lands on one of those low slots.
        local plain = heads(pane.header(cond.items, boundary, cond.node_of_hash, shared, col_of))
        local low = false
        for _, c in ipairs(plain) do if avoid[c] then low = true end end
        assert.is_true(low, "the fixture must de-collide onto a low slot")
        local got = heads(pane.header(cond.items, boundary, cond.node_of_hash, shared, col_of, avoid))
        assert.equals(3, #got)
        local seen = {}
        for _, c in ipairs(got) do
            assert.is_nil(avoid[c], "a de-collided head took pinned slot " .. tostring(c))
            assert.is_nil(seen[c], "two heads share colour " .. tostring(c))
            seen[c] = true
        end
    end)

    it("keeps a muted colour (-k) and never hands slot k to another lane (§5.5/§6.2)", function()
        -- b3 stands for a track carrying a remote of b1's identity in the main view
        -- (colour -1: slot 1, muted); b1 / b2 arrive sharing colour 1 (b1 is the
        -- crossing trunk, which keeps its boundary colour) and b2 must be de-collided —
        -- never onto the pinned slot 1 — while b3 keeps its muted colour as is. b1 is
        -- pinned (rank 1): its lane is the one `ca` continues and it draws slot 1 in
        -- the main view.
        local items = h.dag({
            { "b1", { "ca" } }, { "b2", { "ca" } }, { "b3", { "ca" } },
            { "ca", { "base" } }, { "base", {} },
        })
        items[1].commit.refs = { { name = "b1" } }
        items[2].commit.refs = { { name = "b2" } }
        items[3].commit.refs = { { name = "b3" } }
        local opts = h.big_opts()
        opts.pin_rank = { b1 = 1 }
        local _, boundary, cond, _, lane_of, col_of = header_of(items, opts, 5, { b1 = true, b2 = true, b3 = true })
        local function shared(n)
            local l = lane_of(n)
            if not l then return nil end
            local hsh = (n.tip and n.tip.hash) or n.hash
            return { id = l.id, color = (hsh == "b3") and -1 or 1 }
        end
        local avoid = { [1] = 1 }
        local res = pane.header(cond.items, boundary, cond.node_of_hash, shared, col_of, avoid)
        local by = {}
        for _, r in ipairs(res.rows) do
            for _, cell in ipairs(r.columns) do
                local c = cell.has_commit and cell.commit
                if c then by[(c.tip and c.tip.hash) or c.hash] = cell.color end
            end
        end
        assert.equals(-1, by.b3, vim.inspect(by))
        assert.is_not_nil(by.b2)
        assert.is_true(by.b2 ~= 1 and by.b2 ~= -1, "b2 took slot 1: " .. tostring(by.b2))
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
        -- not by which head the sweep reached first. Both are ranked as the window
        -- ranks the default anchors (trunk first, HEAD's anchor last; §10.6), so dev's
        -- lane is the one `s` continues (§5 tier 0).
        local items = h.dag({
            { "dev", { "s" } }, { "head", { "s" } }, { "s", { "base" } }, { "base", {} },
        })
        items[1].commit.refs = { { name = "dev" } }
        items[2].commit.refs = { { name = "head" } }
        local opts = h.big_opts()
        opts.pin_rank = { dev = 1, head = 2 }
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
        if not dev then error("d1 has no main-view lane") end
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

describe("pane.header_seam — whole-commit cutoff in SCREEN rows (§6.2)", function()
    -- header_seam works on the `screen_lines` model (real columns lines + virtual
    -- split/merge rows) and a top visible SCREEN row `ts` — the upward mirror of
    -- footer_seam. The overlay covers whole commit blocks DOWN from `ts`; the seam is
    -- the first block START leaving ≥ cover rows above it. `ts` is a screen row, so a
    -- split fan at the window top is addressed directly (the header virtual-line bug).
    local function items(specs)
        local out = {}
        for i, s in ipairs(specs) do
            out[i] = { commit = { hash = "n" .. i },
                above = s.split and { {} } or nil, merge = s.merge or nil }
        end
        return out
    end
    local function sm(specs, rows_of) return pane.screen_lines(items(specs), rows_of) end

    it("rounds to a commit boundary with no virtual lines", function()
        -- 5 columns-only items → screen rows 1..5. ts=1, cover=3 covers rows 1,2,3.
        local s = assert(pane.header_seam(sm({ {}, {}, {}, {}, {} }), 1, 3))
        assert.equals(4, s.idx)       -- covered 1,2,3 (3 rows); seam item 4 (screen row 4)
        assert.equals("columns", s.kind)
        assert.equals(3, s.cover)
        assert.equals(4, s.seam_top)
    end)

    it("covers a covered commit's trailing MERGE line with it (the off-by-one regression)", function()
        -- item 3 has a merge (block = screen rows 3,4). Screen: 1,2,[3,4],5,6. ts=1,
        -- cover=3: the overlay can't split item 3's block, so it grows to cover rows 1..4
        -- (items 1,2 whole + item 3 whole) → seam at item 4 (screen row 5), cover 4.
        local s = assert(pane.header_seam(sm({ {}, {}, { merge = {} }, {}, {} }), 1, 3))
        assert.equals(4, s.idx)
        assert.equals(4, s.cover)     -- the overlay grows by item 3's merge line (the +1 padding)
        assert.equals(5, s.seam_top)
    end)

    it("reads the seam commit's own SPLIT line as its top edge", function()
        -- item 4 has a split (block = screen rows 4,5). Screen: 1,2,3,[split=4,cols=5],6.
        -- ts=1, cover=3 covers rows 1,2,3; the seam is item 4 whose TOP rendered row is
        -- its split fan (screen 4) → kind=split.
        local s = assert(pane.header_seam(sm({ {}, {}, {}, { split = {} }, {} }), 1, 3))
        assert.equals(4, s.idx)
        assert.equals("above", s.kind) -- item 4's split fan (its diverging children) is the seam
        assert.equals(-1, s.virt)      -- its only above-row, nearest the columns line
        assert.equals(4, s.seam_top)
    end)

    it("a window top on a VIRTUAL SPLIT line seams past that commit (the bug)", function()
        -- item 2 has a split. Screen: 1,[split=2,cols=3],4,5. If the window top lands on
        -- item 2's SPLIT (screen row 2, its columns just below), that split is part of the
        -- covered region — the seam must round the whole item 2 block into the header.
        local s = assert(pane.header_seam(sm({ {}, { split = {} }, {}, {} }), 2, 1))
        assert.equals(3, s.idx)        -- item 2 (split+cols) covered whole; seam at item 3
        assert.equals("columns", s.kind)
        assert.equals(2, s.cover)      -- rows 2 (split) and 3 (cols) covered
        assert.equals(4, s.seam_top)
    end)

    it("ignores a split scrolled off above the viewport (ts on the columns line)", function()
        -- item 1 has a split but it is scrolled off; ts is item 1's columns row (screen 2).
        local s = assert(pane.header_seam(sm({ { split = {} }, {}, {} }), 2, 1))
        assert.equals(2, s.idx) -- top's split does not count; one row (item 1's columns) covered
        assert.equals(1, s.cover)
    end)

    it("honours a per-commit height (dual label mode = 2 rows)", function()
        -- height 2 each → screen rows: c1[1,2] c2[3,4] c3[5,6] c4[7,8]. ts=1, cover=3
        -- covers rows 1,2,3 but item 2's block is 3,4 → grows to 1..4 → seam item 3.
        local s = assert(pane.header_seam(sm({ {}, {}, {}, {} }, function() return { height = 2 } end), 1, 3))
        assert.equals(3, s.idx)
        assert.equals(4, s.cover)
        assert.equals(5, s.seam_top)
    end)

    it("returns nil past the last commit", function()
        assert.is_nil(pane.header_seam(sm({ {}, {} }), 1, 99))
    end)
end)

describe("pane.footer_seam — whole-commit cutoff in SCREEN rows (§6.2)", function()
    -- footer_seam now works on the `screen_lines` model (real columns lines + virtual
    -- split/merge rows) and a bottom visible SCREEN row `bs`, so it addresses virtual
    -- lines directly. The overlay covers whole commit blocks up from `bs`; the seam is
    -- the first block boundary leaving ≥ cover rows below it. `bs` is a screen row.
    local function items(specs)
        local out = {}
        for i, s in ipairs(specs) do
            out[i] = { commit = { hash = "n" .. i },
                above = s.split and { {} } or nil, merge = s.merge or nil }
        end
        return out
    end
    local function sm(specs, rows_of) return pane.screen_lines(items(specs), rows_of) end

    it("rounds to a commit boundary with no virtual lines", function()
        -- 5 columns-only items → screen rows 1..5. bs=5, cover=3 covers rows 3,4,5.
        local s = assert(pane.footer_seam(sm({ {}, {}, {}, {}, {} }), 5, 3))
        assert.equals(2, s.idx)       -- seam item 2, whose bottom (screen row 2) is above the overlay
        assert.equals("columns", s.kind)
        assert.equals(3, s.cover)
        assert.equals(2, s.seam_bottom)
    end)

    it("covers a covered commit's MERGE line with it (whole-block coverage)", function()
        -- item 3 has a merge (block = screen rows 3,4). Screen: 1,2,[3,4],5,6. bs=6,
        -- cover=3: the overlay can't split item 3's block, so it grows to cover rows
        -- 3..6 (item 3 whole + 4,5) → seam at item 2, cover 4.
        local s = assert(pane.footer_seam(sm({ {}, {}, { merge = {} }, {}, {} }), 6, 3))
        assert.equals(2, s.idx)
        assert.equals(4, s.cover)
        assert.equals(2, s.seam_bottom)
    end)

    it("reads the seam commit's own MERGE line as its bottom edge", function()
        -- item 2 has a merge. Screen: 1,[2,3],4,5,6. bs=6, cover=3 covers rows 4,5,6;
        -- the seam is item 2 whose BOTTOM rendered row is its merge (screen 3) → kind=merge.
        local s = assert(pane.footer_seam(sm({ {}, { merge = {} }, {}, {}, {} }), 6, 3))
        assert.equals(2, s.idx)
        assert.equals("merge", s.kind)
        assert.equals(3, s.seam_bottom)
    end)

    it("a window bottom on a VIRTUAL SPLIT line seams at the last full commit (the bug)", function()
        -- item 4 has a split. Screen: 1,2,3,[split=4,cols=5]. If the window bottom lands
        -- on item 4's SPLIT (screen row 4, its columns scrolled off below), the seam must
        -- be item 3 (the last fully-visible commit) with the split covered — NOT drift up.
        local s = assert(pane.footer_seam(sm({ {}, {}, {}, { split = {} } }), 4, 1))
        assert.equals(3, s.idx)
        assert.equals("columns", s.kind)
        assert.equals(3, s.seam_bottom) -- item 3's columns (screen 3); the split (4) is covered
        assert.equals(1, s.cover)
    end)

    it("honours a per-commit height (dual label mode = 2 rows)", function()
        -- height 2 each → screen rows: c1[1,2] c2[3,4] c3[5,6] c4[7,8]. bs=8, cover=3
        -- covers rows 6,7,8 but item 3's block is 5,6 → grows to 5..8 → seam item 2.
        local s = assert(pane.footer_seam(sm({ {}, {}, {}, {} }, function() return { height = 2 } end), 8, 3))
        assert.equals(2, s.idx)
        assert.equals(4, s.cover)
        assert.equals(4, s.seam_bottom)
    end)

    it("returns nil past the first commit (footer would cover everything)", function()
        assert.is_nil(pane.footer_seam(sm({ {}, {} }), 2, 99))
    end)
end)

describe("several above-rows on ONE commit (§5 Line, §5.6 gutter handover)", function()
    -- `OrderItem.above` is a LIST. The merge style contributes at most the split fan;
    -- the `gutter` policy adds an eviction row and a claim row, so one commit really
    -- renders TWO or THREE virtual lines above its own — which is the only thing that
    -- produces more than one today, so these fixtures are real `gutter` layouts rather
    -- than hand-built items.
    --
    -- The load-bearing detail: the list and the screen model run in OPPOSITE
    -- directions. `screen_lines` emits `virt = -k` with `-1` NEAREST the columns line
    -- (matching nvim's `virt_lines_above` stacking), so the TOPMOST of `n` above-rows
    -- is `virt = -n` = `above[1]`. Decoding that backwards is the silent seam-drift
    -- class the screen-row model exists to prevent, so it is asserted head-on.
    local DEF = { split_on_separate_line = true, merge_on_separate_line = false }

    -- c3 gets an eviction row + a claim row. A plain diamond: c1 forks, its first
    -- parent c2 keeps the gutter down to c4, so when c3's own (junior) lane reaches its
    -- commit the gutter is held by a survivor — evict, then claim. Deliberately NOT a
    -- merge whose second parent owns the next subject row: that is the one shape the
    -- §5.6 parent swap removes the handover from (it used to be this fixture).
    local TWO = { { "c1", { "c2", "c3" } }, { "c2", { "c4" } }, { "c3", { "c4" } }, { "c4", {} } }
    -- c3 gets an eviction row + a claim row + its own split fan.
    local THREE = { { "c1", { "c2", "c3" } }, { "c2", { "c4", "c3" } }, { "c3", { "c4" } }, { "c4", {} } }

    local function gutter_layout(dag)
        local o = h.big_opts(DEF)
        o.layout_policy = "gutter"
        return columns.layout(o, h.dag(dag))
    end

    -- The rendered screen sequence read straight off the rows — an oracle independent
    -- of `screen_lines`: `{ display index, the line rendered there }` per screen row.
    local function expected_lines(rows)
        local out = {}
        for i, r in ipairs(rows) do
            for _, l in ipairs(r.above or {}) do out[#out + 1] = { i, l } end
            out[#out + 1] = { i, r.columns }
            if r.merge then out[#out + 1] = { i, r.merge } end
        end
        return out
    end

    it("the fixtures really carry two and three above-rows", function()
        assert.equals(2, #(gutter_layout(TWO)[3].above or {}))
        assert.equals(3, #(gutter_layout(THREE)[3].above or {}))
    end)

    it("screen_lines stacks them -n..-1, the one nearest the columns line LAST", function()
        local rows = gutter_layout(THREE)
        local sm = pane.screen_lines(rows)
        local exp = expected_lines(rows)
        assert.equals(#exp, #sm.lines)
        for sr, e in ipairs(exp) do assert.equals(e[1], sm.lines[sr].idx) end
        local base = sm.cols[3] -- c3's columns row; its three above-rows sit just above
        assert.same({ -3, -2, -1, 0 }, {
            sm.lines[base - 3].virt, sm.lines[base - 2].virt,
            sm.lines[base - 1].virt, sm.lines[base].virt,
        })
        assert.equals("above", sm.lines[base - 3].kind)
    end)

    it("seam_line decodes virt against the list (topmost = -n = above[1])", function()
        local it3 = gutter_layout(THREE)[3]
        assert.equals(it3.above[1], pane.seam_line({ item = it3, virt = -3 }))
        assert.equals(it3.above[2], pane.seam_line({ item = it3, virt = -2 }))
        assert.equals(it3.above[3], pane.seam_line({ item = it3, virt = -1 }))
        assert.equals(it3.columns, pane.seam_line({ item = it3, virt = 0 }))
    end)

    it("header_seam butts the TOPMOST above-row, at every window top", function()
        -- The header seam is a block START, so on an item with above-rows it is always
        -- the topmost one — the eviction row, never the split fan below it.
        for _, dag in ipairs({ TWO, THREE }) do
            local rows = gutter_layout(dag)
            local sm, exp = pane.screen_lines(rows), expected_lines(rows)
            for ts = 1, #sm.lines do
                for cover = 1, 3 do
                    local s = pane.header_seam(sm, ts, cover)
                    if s then
                        local e = exp[s.seam_top]
                        assert.equals(e[1], s.idx)
                        assert.equals(e[2], pane.seam_line(s)) -- the line actually rendered there
                        local n = #(s.item.above or {})
                        if n > 0 then
                            assert.equals(-n, s.virt)
                            assert.equals("above", s.kind)
                            assert.equals(s.item.above[1], pane.seam_line(s))
                        end
                        if #(s.item.child_lanes or {}) > 0 then
                            assert.is_true(next(pane.boundary_of(pane.seam_line(s), true)) ~= nil,
                                "the header seeds from a line with no up-lanes")
                        end
                    end
                end
            end
        end
    end)

    it("footer_seam butts the BOTTOM row, never inside a block, at every window bottom", function()
        for _, dag in ipairs({ TWO, THREE }) do
            local rows = gutter_layout(dag)
            local sm, exp = pane.screen_lines(rows), expected_lines(rows)
            for bs = 1, #sm.lines do
                for cover = 1, 3 do
                    local s = pane.footer_seam(sm, bs, cover)
                    if s then
                        local e = exp[s.seam_bottom]
                        assert.equals(e[1], s.idx)
                        assert.equals(e[2], pane.seam_line(s))
                        -- above-rows sit at the TOP of a block, so a block boundary is
                        -- never one of them: the footer butts a columns or merge line.
                        assert.is_true(s.virt >= 0)
                    end
                end
            end
        end
    end)

    it("every above-row reaches the §12 emphasis walk (reach.item_lines)", function()
        local reach = require("gitloom.graph.reach")
        local it3 = gutter_layout(THREE)[3]
        local lines = reach.item_lines(it3)
        assert.equals(4, #lines) -- three above-rows + the commit line
        for k = 1, 3 do assert.equals(it3.above[k], lines[k]) end
        assert.equals(it3.columns, lines[4])
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

    -- A footer's entries are DRAWN lines (`drawn_lines`): under `gutter` the root can
    -- carry handover rows drawn right above it (§5.6). Keeping the root alone would
    -- leave its node under a lane that never turns into it.
    it("keeps the virtual lines drawn above the root with it", function()
        local rows = {}
        for i = 1, 10 do rows[i] = { columns = {}, n = i } end
        rows[8].virtual, rows[9].virtual = true, true -- two handover lines onto root 10
        local capped, elided = pane.cap(rows, 5)
        assert.equals(5, #capped)
        assert.equals(5, elided)
        assert.same({ 1, 2, 8, 9, 10 }, vim.tbl_map(function(r) return r.n end, capped))
        -- never more than the cap, even when the root's block alone exceeds it
        local tight = pane.cap(rows, 2)
        assert.same({ 9, 10 }, vim.tbl_map(function(r) return r.n end, tight))
    end)

    it("drawn_lines flattens a row's virtual lines around its commit line", function()
        local a1, a2, c, m = { "a1" }, { "a2" }, { "c" }, { "m" }
        local out = pane.drawn_lines({ { above = { a1, a2 }, columns = c, merge = m, commit = { hash = "x" } } })
        assert.equals(4, #out)
        assert.equals(a1, out[1].columns); assert.is_true(out[1].virtual)
        assert.equals(a2, out[2].columns); assert.is_true(out[2].virtual)
        assert.equals(c, out[3].columns); assert.equals("x", out[3].commit.hash)
        assert.is_nil(out[3].virtual); assert.is_nil(out[3].above); assert.is_nil(out[3].merge)
        assert.equals(m, out[4].columns); assert.is_true(out[4].virtual)
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

    -- Two crossing lanes whose first-parent chains meet only AT a root — a fork at
    -- the root, as LumeEditor's 2.1 line (a separate history: `2.1-lts` and
    -- `janne/ssaaa-113` both fork off `Initial commit 2.1.113`). The root is both a
    -- convergence and a root; condense classified it as a node-less junction, so the
    -- footer ended the two lanes in a bare bracket with no `◎`, reading as history
    -- with no root (§6.2: the footer runs "down to and including the root commit(s)";
    -- §5 `◎` = root commit).
    it("a root that two lanes fork from is drawn as a ◎ root, not a node-less junction", function()
        local map = by_hash(h.dag({
            { "A", { "B" } },
            { "X", { "Y" } },
            { "B", { "R" } },
            { "Y", { "R" } },
            { "R", {} },
        }))
        local bnd = {
            [1] = { id = 1, color = 1, parent = map.A, begin = map.A },
            [2] = { id = 2, color = 2, parent = map.X, begin = map.X },
        }
        local cond = pane.continue(bnd)
        local n = by_hash(cond.items)
        assert.is_not_nil(n.R)
        assert.equals(0, #n.R.parents)
        assert.is_false(n.R.junction, "the root must stay a real node, not a junction")
        local opts = vim.tbl_extend("force", h.big_opts(), { junction_markers = true })
        local res = pane.footer(opts, cond.items, bnd, cond.node_of_hash)
        local text = {}
        for _, r in ipairs(res.rows) do
            local g = get_column_chars(opts, r.columns, false)
            text[#text + 1] = g.text or ""
        end
        assert.is_not_nil(table.concat(text, "\n"):find("◎"),
            "the footer must draw the shared root as ◎:\n" .. table.concat(text, "\n"))
    end)

    -- The two-lane "loop": two crossing lanes converge on a junction J whose first
    -- parent is a COLLAPSED root region (a `◍` head — synthetic hash
    -- `collapsed:<root>`, which the window's hash-keyed `order_of` cannot rank). The
    -- old index sort ranked the unrankable head newest, laying the root out above its
    -- own child: the lanes met at J after the sweep had passed the root and ran off
    -- the bottom of the pane. The order must follow the edges, whatever the index.
    it("orders a collapsed root head after its child, though order_of cannot rank it", function()
        local J = { hash = "J", refs = {}, parents = {}, children = {} }
        local head = { hash = "collapsed:R2", collapsed = true, refs = {}, region = { "R1", "R2" },
            tip = { hash = "R1" }, parents = {}, children = { J } }
        J.parents[1] = head
        local idx = { A = 1, B = 2, J = 3, R1 = 4, R2 = 5 }
        local bnd = {
            [1] = { id = 1, color = 1, parent = J, begin = { hash = "A" } },
            [2] = { id = 2, color = 2, parent = J, begin = { hash = "B" } },
        }
        local cond = pane.continue(bnd, nil, {}, function(n) return idx[n.hash] end)
        local order = {}
        for i, it in ipairs(cond.items) do order[it.commit.hash] = i end
        assert.is_not_nil(order.J)
        assert.is_not_nil(order["collapsed:R2"])
        assert.is_true(order.J < order["collapsed:R2"], "the junction must precede the root head below it")
        -- Laid out: every lane lands on a node inside the pane — nothing leaves the
        -- last line downward.
        local res = pane.footer(h.big_opts(), cond.items, bnd, cond.node_of_hash)
        for col, cell in pairs(res.rows[#res.rows].columns) do
            assert.is_false(cell.connectivity.down and true or false,
                "a wire leaves the footer's last line downward at col " .. col)
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

    -- The footer seam-discontinuity bug: two crossing lanes land on the SAME
    -- parent commit P (P forks: A and B are both children of P), then P descends
    -- linearly P->M->root. P is where the two lanes converge, but its
    -- first-parent child-degree is 0 (both lanes *land on* it, not through it), so
    -- the naive condense splices the whole P->M->root stretch to the root, leaving
    -- the two lanes nowhere to meet — they strand at the seam. P must be kept as
    -- the convergence junction.
    it("keeps the meeting commit when two crossing lanes land on the SAME parent", function()
        local items = h.dag({
            { "A", { "P" } },
            { "B", { "P" } },
            { "P", { "M" } },
            { "M", { "root" } },
            { "root", {} },
        })
        local map = {}
        for _, it in ipairs(items) do map[it.commit.hash] = it.commit end
        local boundary = {
            [1] = { id = 1, color = 1, parent = map.P, begin = map.A },
            [2] = { id = 2, color = 2, parent = map.P, begin = map.B },
        }
        local cond = pane.continue(boundary)
        local n = by_hash(cond.items)
        assert.is_not_nil(n.P)                    -- the meeting commit survives
        assert.is_true(n.P.junction)              -- rendered as the convergence join
        assert.equals(n.P, cond.node_of_hash.P)   -- both lanes' parent maps to it
        assert.is_not_nil(n.root)                 -- and the root is still reached
        assert.equals(0, #n.root.parents)
    end)

    -- End to end through pane.footer: both crossing lanes must enter the seam
    -- (rendered `up` at row 1) and neither may be reported as terminating — a
    -- terminated crossing lane is the dangling-at-the-seam discontinuity.
    it("footer: two lanes on the same parent both reach the seam (none dangle)", function()
        local items, opts = h.dag({
            { "A", { "P" } },
            { "B", { "P" } },
            { "P", { "M" } },
            { "M", { "root" } },
            { "root", {} },
        }), h.big_opts()
        local map = {}
        for _, it in ipairs(items) do map[it.commit.hash] = it.commit end
        local boundary = {
            [1] = { id = 1, color = 1, parent = map.P, begin = map.A },
            [2] = { id = 2, color = 2, parent = map.P, begin = map.B },
        }
        local cond = pane.continue(boundary)
        local res = pane.footer(opts, cond.items, boundary, cond.node_of_hash)
        assert.is_nil(next(res.terminate)) -- no crossing lane strands at the seam
        -- both boundary columns enter from above at the seam row
        assert.is_true(res.rows[1].columns[1] and res.rows[1].columns[1].connectivity.up)
        assert.is_true(res.rows[1].columns[2] and res.rows[1].columns[2].connectivity.up)
        assert_continuous(res.rows)
    end)
end)

describe("pane.footer — fuzz: no crossing lane strands at the seam (§6.2)", function()
    -- Feed random DAGs through the real layout, build a footer at every cutoff, and
    -- assert the seam-discontinuity invariant: an uncapped footer strands NO crossing
    -- lane. Every boundary lane's parent is queued by `continue`, so it maps to a kept
    -- node and must both continue (empty `terminate`) and appear at the seam row with
    -- its own id (up-connected), lane-continuous down to a root. Guards the footer
    -- against the over-collapse that dropped lanes when they converged on a shared node.
    it("holds across a random sweep", function()
        for seed = 1, 60 do
            local n = 8 + (seed % 13) -- 8..20 commits — many branches, deep footers
            local items = h.dag(h.random_dag(n, seed))
            local opts = h.big_opts()
            local main = columns.layout(opts, items)
            for cut = 1, #items - 1 do
                local boundary = pane.boundary_below(main, cut)
                if next(boundary) then
                    local ctx = ("seed=%d n=%d cut=%d"):format(seed, n, cut)
                    local cond = pane.continue(boundary)
                    local res = pane.footer(opts, cond.items, boundary, cond.node_of_hash)
                    -- Uncapped: no crossing lane may terminate (strand) at the seam.
                    assert.is_nil(next(res.terminate), ctx .. " a crossing lane stranded at the seam")
                    -- Every boundary lane id enters from above at the seam row (row 1),
                    -- so none was dropped when lanes converged.
                    local up_ids = {}
                    for _, cell in ipairs(res.rows[1].columns) do
                        for _, s in ipairs(cell.lanes or {}) do
                            if s.connectivity.up then up_ids[s.id] = true end
                        end
                    end
                    for _, lane in pairs(boundary) do
                        assert.is_true(up_ids[lane.id],
                            ctx .. (" boundary lane id %s missing at the seam"):format(tostring(lane.id)))
                    end
                    assert_continuous(res.rows)
                end
            end
        end
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
                local seam_line = (main[si].above or {})[1] or main[si].columns
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
--- The pane-rebuild gate (spec §6.2). The panes' topology is a function of the
--- scroll, not the cursor row, so the cursor/scroll debounce rebuilds them only
--- when the viewport actually moved and otherwise re-dims the rows it has.
---
--- The regression these pin is one of TIMING, not of the comparison: the gate
--- used to store a single key, credited the moment a build STARTED. A pane
--- build is async and cancellable — a scroll landing mid-build bumps the
--- generation and the result is dropped — so an abandoned build left the gate
--- claiming a viewport whose panes were never produced. Every later decision
--- then answered "repaint", forever, until an unrelated scroll changed the key:
--- the panes stay stale, or (when that build had already declined and closed
--- them) stay gone. That is the "gone and staying gone after a reposition"
--- shape, and only a *sequence* can catch it — hence a state machine rather
--- than a predicate.
describe("pane rebuild gate (§6.2)", function()
    it("repaints while the view has not moved since the panes were built", function()
        local g = pane.gate()
        g:started("42:0")
        g:built()
        assert.equals("42:0", g:key())
        assert.equals("repaint", g:decide("42:0"))
    end)

    it("rebuilds once the view moves away from what was built", function()
        local g = pane.gate()
        g:started("42:0")
        g:built()
        assert.equals("rebuild", g:decide("43:0"))
        -- A sub-scroll through a line's virtual rows moves only `topfill`.
        assert.equals("rebuild", g:decide("42:1"))
    end)

    it("does not restart an identical build that is still in flight", function()
        local g = pane.gate()
        g:started("42:0")
        -- Nothing is on screen for 42:0 yet, but a build for it is running: the
        -- debounce must not tear that down and start it again on every tick.
        assert.equals("repaint", g:decide("42:0"))
        assert.is_nil(g:key()) -- ... and it must NOT claim to have built it
    end)

    it("rebuilds after an in-flight build is ABANDONED (the regression)", function()
        local g = pane.gate()
        g:started("36:0"); g:built() -- panes on screen for the old viewport

        -- The reposition shape (`jump_to_ref`, the pinned dialog, the filter and
        -- commit-search confirms): the view is moved, a build is started for the
        -- new scroll, and the WinScrolled the move emits lands while that build
        -- is still yielding. The scroll handler abandons it.
        g:started("83:0")
        assert.equals("repaint", g:decide("83:0")) -- in flight: leave it alone
        g:dropped()                                -- abandoned: it built NOTHING

        -- Therefore the next debounce MUST rebuild. Crediting the key at
        -- `started` answers "repaint" here and the panes never come back.
        assert.equals("rebuild", g:decide("83:0"))
        assert.equals("36:0", g:key()) -- still only the old build is on screen
    end)

    it("rebuilds when nothing has been built or is pending", function()
        assert.equals("rebuild", pane.gate():decide("1:0"))
    end)

    it("keeps the built key when a later build is abandoned", function()
        local g = pane.gate()
        g:started("10:0"); g:built()
        g:started("20:0"); g:dropped()
        assert.equals("10:0", g:key())
        assert.equals("repaint", g:decide("10:0")) -- the old panes are still valid there
        assert.equals("rebuild", g:decide("20:0"))
    end)

    it("ignores a completion that no build is pending for", function()
        -- `built()` can only ever promote a live `started()`; a stray call after
        -- an abandonment must not resurrect the dropped key.
        local g = pane.gate()
        g:started("7:0"); g:dropped(); g:built()
        assert.is_nil(g:key())
        assert.equals("rebuild", g:decide("7:0"))
    end)
end)

describe("pane.header — colours follow the main view (§6.2 Colour)", function()
    -- hash → the colour of the header cell drawing that node
    local function node_colors(res)
        local by = {}
        for _, r in ipairs(res.rows) do
            for _, cell in ipairs(r.columns) do
                local c = cell.has_commit and cell.commit
                if c then by[(c.tip and c.tip.hash) or c.hash] = { color = cell.color, id = cell.id } end
            end
        end
        return by
    end

    it("leaves two heads that are never alive together on their shared colour", function()
        -- Two pinned anchors fork off the trunk one above the other: a1's lane ends
        -- (row a1) BELOW the fork j2 that starts a2's, so the two are never on one header
        -- row. The main view recycles a1's colour onto a2; the header must not recolour
        -- either — only lanes alive together are de-collided.
        local items = h.dag({
            { "top", { "j2" } }, { "a2", { "j2" } }, { "j2", { "j1" } },
            { "a1", { "j1" } }, { "j1", { "base" } }, { "base", {} },
        })
        items[1].commit.refs = { { name = "top" } }
        items[2].commit.refs = { { name = "a2" } }
        items[4].commit.refs = { { name = "a1" } }
        local opts = h.big_opts()
        opts.pin_rank = { top = 1 } -- the trunk continues through both forks (§5 tier 0)
        local _, boundary, cond, _, lane_of, col_of =
            header_of(items, opts, 6, { top = true, a2 = true, a1 = true })
        local function recycled(n, p)
            local l = lane_of(n, p)
            if not l then return nil end
            local hsh = (n.tip and n.tip.hash) or n.hash
            return { id = l.id, color = (hsh == "a1" or hsh == "a2") and 30 or l.color }
        end
        local res = pane.header(cond.items, boundary, cond.node_of_hash, recycled, col_of)
        local by = node_colors(res)
        assert.is_not_nil(by.a1, "a1 shown"); assert.is_not_nil(by.a2, "a2 shown")
        assert.equals(30, by.a1.color, "a1 recoloured although never alive beside a2")
        assert.equals(30, by.a2.color, "a2 recoloured although never alive beside a1")
    end)

    it("draws a lane recoloured at an outranking ref in its colour above it (§5/§5.5)", function()
        -- The LumeScene shape: `dev` pinned rank 1 at X, its remote `origin/dev` on X's
        -- child Y, and HEAD's branch `enne` (rank 2) three commits above Y. In the main
        -- view enne's lane (slot 2) runs down to Y, where `origin/dev` (dev's identity,
        -- pinned 1) outranks enne and the SAME lane continues recoloured in dev's slot 1
        -- (§5 "Carried refs") — muted, as it carries a remote (§5.5). The
        -- header, cut below Y, gets that lane at the seam; the stretch from Y up to
        -- enne's tip must be drawn as the main view draws it — enne's slot 2 — not the
        -- seam lane's colour carried on up through Y.
        local function ref(items, hash, name, kind)
            for _, it in ipairs(items) do
                if it.commit.hash == hash then
                    it.commit.refs = it.commit.refs or {}
                    table.insert(it.commit.refs, { name = name, kind = kind or "local", commit = it.commit })
                end
            end
        end
        for _, pol in ipairs({ "compact", "survivors", "linear", "straight", "gutter" }) do
            local items = h.dag({
                { "H", { "A2" } }, { "A2", { "A1" } }, { "A1", { "Y" } },
                { "Y", { "X" } }, { "X", { "W" } }, { "W", { "V" } }, { "V", {} },
            })
            ref(items, "H", "enne")
            ref(items, "Y", "origin/dev", "remote")
            ref(items, "X", "dev")
            local opts = h.big_opts()
            opts.layout_policy = pol
            h.ranked(opts, items, { pins = { "dev", "enne" }, current = "enne" })
            local res, boundary, _, _, lane_of =
                header_of(items, opts, 5, { dev = true, enne = true, ["origin/dev"] = true })
            local enne = lane_of({ hash = "H" })
            local cp = lane_of({ hash = "Y" })
            if not (enne and cp) then error("fixture: no main-view lanes") end
            assert.equals(2, enne.color, pol .. ": fixture: enne's lane is slot 2")
            assert.equals(-1, cp.color, pol .. ": fixture: the lane is recoloured dev's (muted: origin/dev) at Y")
            assert.equals(enne.id, cp.id, pol .. ": fixture: one lane, recoloured, not a birth")
            local by = node_colors(res)
            assert.is_not_nil(by.H, pol .. ": enne shown")
            assert.equals(2, by.H.color, pol .. ": enne's head took the recoloured lane's colour")
            assert.is_not_nil(by.Y, pol .. ": origin/dev shown")
            assert.equals(-1, by.Y.color, pol .. ": origin/dev's node is in dev's colour, muted (§5.5)")
            -- every segment above origin/dev's row (the last header row) is enne's
            for i = 1, #res.rows - 1 do
                for _, cell in ipairs(res.rows[i].columns) do
                    for _, s in ipairs(cell.lanes or {}) do
                        assert.equals(2, s.color, pol .. ": row " .. i .. " carries colour " .. tostring(s.color))
                    end
                end
            end
            assert_seam_match(res.rows, boundary)
        end
    end)

    it("colours a fork child reached through its SECOND parent by that edge's lane", function()
        -- `c` merges the fork node `n` as its second parent; its first parent `o` is a
        -- root the header never shows. In the main view the edge c → n is its own lane,
        -- coloured differently from c's first-parent lane — and that edge is what the
        -- header draws from n up to c.
        local items = h.dag({
            { "top", { "n" } }, { "c", { "o", "n" } }, { "o", {} },
            { "n", { "base" } }, { "base", {} },
        })
        items[1].commit.refs = { { name = "top" } }
        items[2].commit.refs = { { name = "c" } }
        local opts = h.big_opts()
        local res, _, _, _, lane_of = header_of(items, opts, 5, { top = true, c = true })
        local c, n = { hash = "c" }, { hash = "n" }
        local edge, fp = lane_of(c, n), lane_of(c)
        if not (edge and fp) then error("fixture: c has no main-view lanes") end
        assert.is_true(edge.color ~= fp.color, "fixture: the c → n edge must differ from c's first-parent lane")
        local by = node_colors(res)
        assert.is_not_nil(by.c, "c shown")
        -- every segment of c's header lane
        local seen = 0
        for _, r in ipairs(res.rows) do
            for _, cell in ipairs(r.columns) do
                for _, s in ipairs(cell.lanes or {}) do
                    if s.id == by.c.id then
                        seen = seen + 1
                        assert.equals(edge.color, s.color, "c's header lane is not the c → n edge's colour")
                    end
                end
            end
        end
        assert.is_true(seen > 0)
    end)

    it("without generated colours, a replacement stays within the palette and off the pinned slots", function()
        -- Three concurrent anchors all arriving on colour 2 with a 3-colour palette and
        -- slot 3 pinned: the two replacements must share a curated slot (as the main view
        -- does when exhausted), never mint slot 4 (which wraps onto a curated colour —
        -- possibly a pinned one) and never take the pinned slot 3.
        local items = h.dag({
            { "b1", { "ca" } }, { "b2", { "ca" } }, { "b3", { "ca" } },
            { "ca", { "base" } }, { "base", {} },
        })
        items[1].commit.refs = { { name = "b1" } }
        items[2].commit.refs = { { name = "b2" } }
        items[3].commit.refs = { { name = "b3" } }
        local opts = h.big_opts()
        local _, boundary, cond, _, lane_of, col_of = header_of(items, opts, 5, { b1 = true, b2 = true, b3 = true })
        local b = {}
        for col, l in pairs(boundary) do b[col] = setmetatable({ color = 2 }, { __index = l }) end
        local function shared(n, p)
            local l = lane_of(n, p)
            return l and { id = l.id, color = 2 }
        end
        local avoid = { [3] = 3 }
        local res = pane.header(cond.items, b, cond.node_of_hash, shared, col_of, avoid, 3)
        local heads = 0
        for _, r in ipairs(res.rows) do
            for _, cell in ipairs(r.columns) do
                for _, s in ipairs(cell.lanes or {}) do
                    assert.is_true(s.color >= 1 and s.color <= 3, "colour outside the palette: " .. s.color)
                    assert.is_true(s.color ~= 3, "a replacement took pinned slot 3")
                end
                if cell.has_commit then heads = heads + 1 end
            end
        end
        assert.equals(3, heads)
    end)
end)
