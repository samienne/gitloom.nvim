--- Ref labels take their node's lane colour (spec §6 "Label colour", §12.2):
--- a label is drawn in exactly the colour `get_column_chars` gives its row's node
--- glyph — incl. a `gutter` parent-swapped node (`own_lane_up`, §5.6), a collapsed
--- `◍` head and each marker of a packed row (§10.4) — dimmed with the same
--- hue-preserving `dim_hl` blend out of the cone. HEAD's marker keeps
--- `palette.head`, the h/l-selected label `palette.selected`, and
--- `lane_label_colors = false` restores the per-kind groups. Driven through the
--- real `display_item` on hand-built rows, plus the pane pieces (`pane_labels`'s
--- `arrow` span and `node_lane_hl` on a pane-style row).

local render = require("gitloom.graph.render")
local helpers = require("tests.graph_helpers")

local function opts(extra)
    local o = helpers.big_opts() -- tracks C0..C63; slot n -> "C" .. (n - 1)
    o.palette.head = "HeadHl"
    o.palette.selected = "SelHl"
    o.palette.branch = "BranchHl"
    o.palette.remote = "RemoteHl"
    o.palette.tags = "TagHl"
    o.palette.worktree = "WtHl"
    o.icons = {}
    for k, v in pairs(extra or {}) do o[k] = v end
    return o
end

local function commit(t)
    t.parents = t.parents or { {} }
    t.children = t.children or { {} }
    t.refs = t.refs or {}
    t.message = t.message or "msg"
    return t
end

-- A straight node cell in palette slot `slot`.
local function node_cell(c, slot, extra)
    local cell = {
        connectivity = { up = true, down = true },
        lanes = { { connectivity = { up = true, down = true }, id = slot, color = slot, edges = {} } },
        has_commit = true,
        commit = c,
    }
    for k, v in pairs(extra or {}) do cell[k] = v end
    return cell
end

local function row(c, cells)
    return { type = "commit", commit = c, columns = cells }
end

-- `display_item` with no ref selection (and an optional cone).
local function draw(o, item, sel, cone)
    return render.display_item(o, item, sel or {}, cone)
end

-- Every highlight run of a rendered piece as { text, hl } in order.
local function runs(piece)
    local out = {}
    for _, h in ipairs(piece.highlight or {}) do
        out[#out + 1] = { piece.text:sub(h.start_pos + 1, h.end_pos), h.hl }
    end
    return out
end

-- The distinct highlight groups of a rendered piece.
local function groups(piece)
    local set, out = {}, {}
    for _, r in ipairs(runs(piece)) do
        if not set[r[2]] then set[r[2]] = true; out[#out + 1] = r[2] end
    end
    return out
end

-- The node glyph's highlight on a row (what the label must match).
local function node_glyph_hl(o, cells, emphasis)
    local res = render.get_column_chars(o, cells, emphasis)
    return res.highlight[1].hl
end

local LOCAL = { kind = "local", name = "feat" }
local REMOTE = { kind = "remote", name = "origin/feat" }
local TAG = { kind = "tag", name = "v1" }

describe("ref labels take their lane colour (§6)", function()
    it("a plain row: every label (branch group incl. ↑remote, tag) in the node's colour", function()
        local o = opts()
        local c = commit({ refs = { LOCAL, REMOTE, TAG } })
        local cells = { node_cell(c, 3) }
        local el = draw(o, row(c, cells))
        assert.equals(2, #el.line_right)
        assert.equals("C2", node_glyph_hl(o, cells))
        assert.same({ "C2" }, groups(el.line_right[1]))
        assert.same({ "C2" }, groups(el.line_right[2]))
    end)

    it("a gutter parent-swapped node (own_lane_up) colours its labels from the up wire", function()
        local o = opts()
        local c = commit({ refs = { LOCAL } })
        local function cells(flag)
            return { {
                connectivity = { up = true, down = true },
                lanes = {
                    { connectivity = { up = true }, id = 5, color = 5, edges = {} },
                    { connectivity = { down = true }, id = 7, color = 7, edges = {} },
                },
                has_commit = true, commit = c, own_lane_up = flag,
            } }
        end
        local swapped = cells(true)
        assert.equals("C4", node_glyph_hl(o, swapped))
        assert.same({ "C4" }, groups(draw(o, row(c, swapped)).line_right[1]))
        -- sanity: unflagged, both the node and its label read the down wire
        local plain = cells(nil)
        assert.equals("C6", node_glyph_hl(o, plain))
        assert.same({ "C6" }, groups(draw(o, row(c, plain)).line_right[1]))
    end)

    it("a collapsed ◍ head's labels take its node colour", function()
        local o = opts()
        local c = commit({ refs = { LOCAL }, collapsed = true, count = 4 })
        local el = draw(o, row(c, { node_cell(c, 9) }))
        local r = runs(el.line[4])
        assert.same({ { "(", "C8" }, { "feat", "C8" }, { ")", "C8" } }, { r[1], r[2], r[3] })
    end)

    it("a packed marker row: each marker's labels take THAT marker's node colour", function()
        local o = opts()
        local m1 = commit({ refs = { { kind = "local", name = "a" } }, collapsed = true, count = 1 })
        local m2 = commit({ refs = { { kind = "local", name = "b" } }, collapsed = true, count = 2 })
        local item = { type = "markers", markers = { m1, m2 }, columns = { node_cell(m1, 2), node_cell(m2, 4) } }
        local el = draw(o, item)
        assert.same({ "C1" }, groups(el.line_right[1]))
        assert.same({ "C3" }, groups(el.line_right[2]))
    end)

    describe("HEAD and selection keep their own highlight", function()
        it("the attached label: `HEAD → ` in palette.head, the rest in the lane colour", function()
            local o = opts()
            local c = commit({ refs = { { kind = "head", name = "HEAD", branch = "feat" }, LOCAL } })
            local el = draw(o, row(c, { node_cell(c, 3) }))
            assert.same({
                { "(", "C2" }, { "HEAD → ", "HeadHl" }, { "feat", "C2" }, { ")", "C2" },
            }, runs(el.line_right[1]))
        end)

        it("a detached HEAD's bare label stays palette.head", function()
            local o = opts()
            local c = commit({ refs = { { kind = "head", name = "HEAD" }, LOCAL } })
            local el = draw(o, row(c, { node_cell(c, 3) }))
            assert.same({ { "HEAD", "HeadHl" } }, runs(el.line_right[1]))
            assert.same({ "C2" }, groups(el.line_right[2]))
        end)

        it("the h/l-selected label draws palette.selected over the lane colour", function()
            local o = opts()
            local c = commit({ refs = { LOCAL, TAG } })
            local el = draw(o, row(c, { node_cell(c, 3) }), { commit = c, index = 2 })
            assert.same({ "C2" }, groups(el.line_right[1]))
            assert.same({ "SelHl" }, groups(el.line_right[2]))
        end)

        it("a ref's own colour (a submodule pointer mark) is kept", function()
            local o = opts()
            local c = commit({ refs = { { kind = "tag", name = "new", hl = "MarkHl" } } })
            local el = draw(o, row(c, { node_cell(c, 3) }))
            assert.same({ "MarkHl" }, groups(el.line_right[1]))
        end)
    end)

    describe("dimming (§12.2)", function()
        local saved
        before_each(function()
            saved = vim.o.termguicolors
            vim.o.termguicolors = true
            vim.api.nvim_set_hl(0, "C2", { fg = 0x33aaff })
            render.reset_dim_cache()
        end)
        after_each(function()
            vim.o.termguicolors = saved
            render.reset_dim_cache()
        end)

        it("an out-of-cone row dims its labels with the lane colour's dim_hl blend", function()
            local o = opts()
            local c = commit({ refs = { LOCAL } })
            local el = draw(o, row(c, { node_cell(c, 3, { active = false }) }), nil, {})
            local dim = render.dim_hl(o, "C2")
            assert.is_true(dim ~= render.DIM_FALLBACK)
            assert.same({ dim }, groups(el.line_right[1]))
        end)

        it("an in-cone row stays the undimmed lane colour; no pivot = undimmed", function()
            local o = opts()
            local c = commit({ refs = { LOCAL } })
            local cells = { node_cell(c, 3) }
            assert.same({ "C2" }, groups(draw(o, row(c, cells), nil, { [c] = true }).line_right[1]))
            assert.same({ "C2" }, groups(draw(o, row(c, cells), nil, nil).line_right[1]))
        end)

        it("an out-of-cone packed marker dims with its own lane colour", function()
            local o = opts()
            local m1 = commit({ refs = { { kind = "local", name = "a" } }, collapsed = true })
            local m2 = commit({ refs = { { kind = "local", name = "b" } }, collapsed = true })
            local item = { type = "markers", markers = { m1, m2 }, columns = { node_cell(m1, 3), node_cell(m2, 5) } }
            local el = draw(o, item, nil, { [m2] = true })
            assert.same({ render.dim_hl(o, "C2") }, groups(el.line_right[1]))
            assert.same({ "C4" }, groups(el.line_right[2]))
        end)
    end)

    it("lane_label_colors = false restores the per-kind groups", function()
        local o = opts({ lane_label_colors = false })
        local c = commit({ refs = { { kind = "head", name = "HEAD", branch = "feat" }, LOCAL, REMOTE, TAG } })
        local el = draw(o, row(c, { node_cell(c, 3) }))
        assert.same({ "HeadHl", "RemoteHl" }, groups(el.line_right[1]))
        assert.same({ "TagHl" }, groups(el.line_right[2]))
    end)

    describe("context panes (§6.2)", function()
        it("pane_labels marks the `HEAD → ` span of the current branch's label", function()
            local c = commit({ refs = { { kind = "head", name = "HEAD", branch = "feat" }, LOCAL } })
            local segs = render.pane_labels(c, "feat")
            assert.equals("head", segs[1].kind)
            local a = assert(segs[1].arrow)
            assert.equals("HEAD → ", segs[1].text:sub(a[1], a[2]))
            -- a detached HEAD's bare label and an ordinary branch carry no span
            local d = render.pane_labels(commit({ refs = { { kind = "head", name = "HEAD" }, LOCAL } }), nil)
            assert.equals("HEAD", d[1].text)
            assert.is_nil(d[1].arrow)
            assert.is_nil(d[2].arrow)
        end)

        it("node_lane_hl on a pane-style row matches the pane node glyph's colour", function()
            local o = opts()
            local c = commit({ refs = { LOCAL } })
            -- a header-style cell: segment-level `highlighted`, no per-edge `edges`
            local cells = { {
                connectivity = { up = true, down = true },
                lanes = { { connectivity = { up = true, down = true }, id = 2, color = 6, highlighted = true } },
                has_commit = true, commit = c,
            } }
            assert.equals(node_glyph_hl(o, cells, true), render.node_lane_hl(o, cells, true, c))
            assert.equals("C5", render.node_lane_hl(o, cells, true, c))
            assert.equals("C5", render.label_hl(o, "C5", "BranchHl"))
            assert.equals("BranchHl", render.label_hl(opts({ lane_label_colors = false }), "C5", "BranchHl"))
            assert.equals("BranchHl", render.label_hl(o, nil, "BranchHl"))
        end)
    end)
end)
