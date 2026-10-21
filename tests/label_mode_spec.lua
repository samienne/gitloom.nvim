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

-- The dual pair bracket (spec §6.1): a labelled commit's two rows open the flex
-- column with `┬` (labels) / `└` (message), no gap — inside the flex column, so no fixed
-- column changes. Through the real display_item.
describe("dual pair bracket (§6.1)", function()
    local function o(mode, mirror)
        local base = helpers.opts()
        base.palette.search = "Search"
        base.label_mode, base.highlight, base.mirror = mode, false, mirror
        return base
    end
    local function commit(refs)
        return { hash = "h", message = "fix the thing", author = "ann", date = 0,
            parents = {}, refs = refs or {} }
    end
    local function labelled() return commit({ { kind = "local", name = "alpha" } }) end
    local function item(c)
        return { type = "commit", commit = c,
            columns = { col({ up = true, down = true }, 1), col({ up = true, down = true }, 2) } }
    end
    local function render(opts, c, match)
        return g.display_item(opts, item(c), {}, nil, nil, nil, match)
    end
    local function same(a, b) assert.same(a, b) end

    for _, mirror in ipairs({ false, true }) do
        local tag = mirror and " (mirrored)" or ""

        it("prefixes row 2's message with the closing bracket" .. tag, function()
            local two = render(o("dual", mirror), labelled())
            local one = render(o("dual", mirror), commit())
            assert.equals(2, #two.lines)
            assert.equals("fix the thing", one.line[4].text)
            assert.equals("└fix the thing", two.lines[2][4].text)
            -- The fixed columns (date / author / graph) are untouched by the prefix.
            assert.equals("", two.lines[2][1])
            assert.equals("", two.lines[2][2])
            assert.equals(two.lines[1][3].text:len(), two.lines[2][3].text:len())
        end)

        it("prefixes row 1's labels with the opening bracket" .. tag, function()
            local two = render(o("dual", mirror), labelled())
            assert.equals("┬(alpha)", two.lines[1][4].text)
        end)

        it("draws both glyphs in palette.pair" .. tag, function()
            local opts = o("dual", mirror)
            opts.palette.pair = "PairHl"
            local two = render(opts, labelled())
            for row, glyph in ipairs({ "┬", "└" }) do
                local f = two.lines[row][4]
                local hit
                for _, hl in ipairs(f.highlight) do
                    if hl.hl == "PairHl" then hit = hl end
                end
                assert.is_not_nil(hit, "row " .. row)
                assert.equals(glyph, f.text:sub(hit.start_pos + 1, hit.end_pos))
            end
        end)

        it("defaults the bracket to NonText when palette.pair is unset" .. tag, function()
            local opts = o("dual", mirror)
            opts.palette.pair = nil
            local f = render(opts, labelled()).lines[2][4]
            assert.equals("NonText", f.highlight[1].hl)
            assert.equals(0, f.highlight[1].start_pos)
        end)

        it("dims the bracket with the row outside the cone" .. tag, function()
            local tgc = vim.o.termguicolors
            vim.o.termguicolors = true
            local opts = o("dual", mirror)
            opts.highlight, opts.palette.pair = true, "NonText"
            local c = labelled()
            local out = g.display_item(opts, item(c), {}, {}, nil, nil, nil) -- c not in cone
            local lit = g.display_item(opts, item(c), {}, { [c] = true }, nil, nil, nil)
            local dim = require("gitloom.graph.render").dim_hl(opts, "NonText")
            vim.o.termguicolors = tgc
            assert.is_true(dim ~= "NonText", "the dim group differs from the lit one")
            for row = 1, 2 do
                assert.equals(dim, out.lines[row][4].highlight[1].hl, "row " .. row)
                assert.equals("NonText", lit.lines[row][4].highlight[1].hl, "row " .. row)
            end
        end)

        it("leaves a same-width blank prefix with palette.pair = false" .. tag, function()
            local opts = o("dual", mirror)
            opts.palette.pair = false
            local two = render(opts, labelled())
            assert.equals(" (alpha)", two.lines[1][4].text)
            assert.equals(" fix the thing", two.lines[2][4].text)
            for row = 1, 2 do
                for _, hl in ipairs(two.lines[row][4].highlight) do
                    assert.is_true(hl.start_pos >= 1, "no highlight on the blank prefix")
                end
            end
        end)

        it("uses custom dual_bracket glyphs" .. tag, function()
            local opts = o("dual", mirror)
            opts.dual_bracket = { "╭", "╰" }
            local two = render(opts, labelled())
            assert.equals("╭(alpha)", two.lines[1][4].text)
            assert.equals("╰fix the thing", two.lines[2][4].text)
        end)

        it("restores the gap with a trailing space in dual_bracket" .. tag, function()
            local r = require("gitloom.graph.render")
            local opts = o("dual", mirror)
            opts.dual_bracket = { "┬ ", "└ " }
            local two = render(opts, labelled())
            assert.equals("┬ (alpha)", two.lines[1][4].text)
            assert.equals("└ fix the thing", two.lines[2][4].text)
            assert.equals(4, r.dual_prefix_bytes(opts))
            assert.equals("fix the thing", two.lines[2][4].text:sub(r.dual_prefix_bytes(opts) + 1))
            opts.palette.pair = false
            assert.equals("  (alpha)", render(opts, labelled()).lines[1][4].text)
        end)

        it("gives the row-2 cursor the prefix's byte length" .. tag, function()
            local r = require("gitloom.graph.render")
            local opts = o("dual", mirror)
            local msg = render(opts, labelled()).lines[2][4].text
            local off = r.dual_prefix_bytes(opts)
            assert.equals(3, off) -- "└" is 3 bytes, no gap
            assert.equals("fix the thing", msg:sub(off + 1))
            opts.dual_bracket = { "+", "`" }
            assert.equals(1, r.dual_prefix_bytes(opts))
            opts.palette.pair = false
            opts.dual_bracket = nil
            assert.equals(1, r.dual_prefix_bytes(opts))
        end)

        it("shifts the filter match highlight with the indent" .. tag, function()
            local two = render(o("dual", mirror), labelled(), { query = "thing" })
            local f = two.lines[2][4]
            local hit
            for _, hl in ipairs(f.highlight) do
                if hl.hl == "Search" then hit = hl end
            end
            assert.is_not_nil(hit)
            assert.equals("thing", f.text:sub(hit.start_pos + 1, hit.end_pos))
        end)

        it("leaves one-line dual and the other modes byte-identical" .. tag, function()
            -- A labelless dual commit renders exactly as in `right` mode.
            same(render(o("right", mirror), commit()).line, render(o("dual", mirror), commit()).line)
            for _, mode in ipairs({ "right", "inline" }) do
                local el = render(o(mode, mirror), labelled())
                assert.is_nil(el.lines)
                assert.is_nil(el.line[4].text:find("^ "), mode)
                assert.is_nil(el.line[4].text:find("┬", 1, true), mode)
            end
        end)
    end
end)
