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
        local cont, term = pane.split_boundary(b, pane_items)
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
        local res = pane.footer(opts, pane_items, b)

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
    end)
end)
