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

describe("pane.header (§6.2)", function()
    -- The header summarises commits NEWER than the viewport. With the visible
    -- region at the bottom (t3, t4), the header is the anchors-only newer set
    -- {t1, t2}; the side branch b1 is folded out.
    it("flips so the seam is the bottom row, matching the main view's top edge", function()
        local items, opts = fixture()
        local main = columns.layout(opts, items)
        local b = pane.boundary_above(main, 4) -- above t3 (the first visible row)
        -- two lanes ascend: the trunk (begin t2) and the side branch (begin b1)
        local tcol, tlane = find_col_begin(b, "t2")
        assert.is_not_nil(tcol)
        assert.is_not_nil(find_col_begin(b, "b1"))

        local header_items = { items[1], items[2] } -- t1 (tip), t2 (anchors-only)
        local res = pane.header(opts, header_items, b)

        -- Display order: tip at top, seam at bottom. The seam (last row) carries
        -- the trunk lane DOWN toward the main view, in the same column/colour.
        local seam = res.rows[#res.rows].columns[tcol]
        assert.is_not_nil(seam)
        assert.is_true(seam.connectivity.down) -- exits downward into the main view
        assert.equals(tlane.id, seam.id)
        assert.equals(tlane.color, seam.color)
        -- Orientation: tip on top, seam-adjacent commit at the bottom (flip worked).
        assert.equals("t1", res.rows[1].commit.hash)
        assert.equals("t2", res.rows[#res.rows].commit.hash)
        -- The seam commit also continues up toward the tip — one unbroken line.
        assert.is_true(seam.connectivity.up)
        -- The folded branch terminates at the seam.
        assert.is_not_nil(find_col_begin(res.terminate, "b1"))
        assert_continuous(res.rows)
    end)
end)
