--- Tests for the dual label mode's branch-line graph (spec §6.1):
--- `passthrough_columns` (the vertical-only projection of a commit's lanes) and
--- its rendering through `get_column_chars`. Pure — no listview/Neovim window.
local g = require("gitloom.graph")._internal
local helpers = require("tests.graph_helpers")

--- A GraphColumn carrying one lane with the given connectivity/colour.
local function col(conn, color, lane_conn)
    return {
        connectivity = conn,
        color = color,
        lanes = { { connectivity = lane_conn or conn, edges = {}, color = color } },
        has_commit = false,
    }
end

describe("passthrough_columns (spec §6.1)", function()
    it("turns a lane entering from above into a vertical, keeping its colour", function()
        local pt = g.passthrough_columns({
            col({ up = true, down = true, left = false, right = false }, 2),
        })
        assert.equals(1, #pt)
        local c = pt[1]
        assert.is_true(c.connectivity.up and c.connectivity.down)
        assert.is_nil(c.connectivity.left)
        assert.is_nil(c.connectivity.right)
        assert.is_false(c.has_commit) -- the node is not drawn on the branch line
        assert.equals(2, c.color)
        assert.equals(1, #c.lanes)
        assert.equals(2, c.lanes[1].color)
        assert.is_true(c.lanes[1].connectivity.up and c.lanes[1].connectivity.down)
    end)

    it("blanks a column with no lane entering from above", function()
        -- A parent lane *born* at the commit (down only) does not belong above it.
        local pt = g.passthrough_columns({
            col({ up = false, down = true, left = true, right = false }, 5),
        })
        assert.equals(1, #pt)
        local c = pt[1]
        assert.is_nil(c.connectivity.up)
        assert.is_nil(c.connectivity.down)
        assert.equals(0, #c.lanes)
    end)

    it("keeps only the through-vertical of a crossing (drops the horizontal)", function()
        local crossing = {
            connectivity = { up = true, down = true, left = true, right = true },
            color = 3,
            lanes = {
                { connectivity = { up = true, down = true }, edges = {}, color = 3 },
                { connectivity = { left = true, right = true }, edges = {}, color = 4 },
            },
            has_commit = false,
        }
        local pt = g.passthrough_columns({ crossing })
        local c = pt[1]
        assert.is_true(c.connectivity.up and c.connectivity.down)
        assert.is_nil(c.connectivity.left)
        assert.is_nil(c.connectivity.right)
        assert.equals(1, #c.lanes) -- only the up-going segment survives
        assert.equals(3, c.lanes[1].color)
    end)

    it("preserves the edge objects so reachability dimming still applies", function()
        local edge = { highlighted = false }
        local pt = g.passthrough_columns({
            {
                connectivity = { up = true, down = true, left = false, right = false },
                color = 1,
                lanes = { {
                    connectivity = { up = true, down = true, left = false, right = false },
                    edges = { edge },
                    color = 1,
                } },
                has_commit = false,
            },
        })
        assert.equals(edge, pt[1].lanes[1].edges[1]) -- same object, not a copy
    end)
end)

describe("passthrough_columns down (dual message row, §6.1)", function()
    it("continues lanes leaving below as verticals", function()
        local pt = g.passthrough_columns({
            -- a lane born at the commit (down only, no up) -> continues below
            col({ up = false, down = true, left = false, right = false }, 7),
            -- a lane that only entered from above (up only) -> nothing below
            col({ up = true, down = false, left = false, right = false }, 2),
        }, "down")
        assert.is_true(pt[1].connectivity.up and pt[1].connectivity.down)
        assert.equals(7, pt[1].color)
        assert.is_nil(pt[2].connectivity.up)
        assert.is_nil(pt[2].connectivity.down)
        assert.equals(0, #pt[2].lanes)
    end)

    it("keeps a pass-through lane (both up and down) on both directions", function()
        local through = { up = true, down = true, left = false, right = false }
        assert.is_true(g.passthrough_columns({ col(through, 4) }, "up")[1].connectivity.down)
        assert.is_true(g.passthrough_columns({ col(through, 4) }, "down")[1].connectivity.down)
    end)
end)

describe("branch-line rendering", function()
    local opts = helpers.opts()

    it("renders only vertical wires and blanks (no node or junctions)", function()
        local pt = g.passthrough_columns({
            col({ up = true, down = true }, 2),
            col({ up = false, down = true, left = true }, 5), -- born here -> blank
            col({ up = true, down = true }, 3),
        })
        local rendered = g.get_column_chars(opts, pt, false)
        assert.is_not_nil(rendered.text:find("│", 1, true))
        for _, glyph in ipairs({ "○", "◉", "◎", "├", "┤", "┬", "┴", "╭", "╮", "╯", "╰", "─" }) do
            assert.is_nil(rendered.text:find(glyph, 1, true),
                ("branch line must not contain %q"):format(glyph))
        end
    end)

    it("colours each vertical by its lane slot", function()
        local pt = g.passthrough_columns({ col({ up = true, down = true }, 2) })
        local rendered = g.get_column_chars(opts, pt, false)
        local found = false
        for _, hl in ipairs(rendered.highlight or {}) do
            if hl.hl == "Hl2" then found = true end -- tracks[2]
        end
        assert.is_true(found, "the │ should take the lane's palette slot")
    end)
end)
