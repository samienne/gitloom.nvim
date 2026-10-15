--- HEAD's node marker (spec §5.3): the commit HEAD points at — attached or
--- detached — renders `●` (`icons.head`) in the HEAD colour (`palette.head`)
--- instead of the shape marker (`○ ◉ ◎` / the merge icon). A working-tree node
--- keeps `◌` but takes the HEAD colour (its lane keeps its own); a collapsed `◍` head / labelled junction containing HEAD keeps `◍`
--- but takes the HEAD colour; out-of-cone dimming still applies; `""` disables.
--- Driven through the real Phase-2 renderer, `get_column_chars`, on hand-built
--- cells, plus one end-to-end layout (incl. mirrored).

local graph = require("gitloom.graph")
local render = require("gitloom.graph.render")
local helpers = require("tests.graph_helpers")
local gcc = graph._internal.get_column_chars

local HEAD_ATTACHED = { kind = "head", name = "HEAD", branch = "main" }
local HEAD_DETACHED = { kind = "head", name = "HEAD" }

local function opts(icons)
    local o = helpers.big_opts()
    o.palette.head = "HeadHl"
    o.icons = icons or {}
    return o
end

-- One node cell (a straight vertical through the node) for `commit`.
local function node_cell(commit, extra)
    local c = {
        connectivity = { up = true, down = true },
        lanes = { { connectivity = { up = true, down = true }, id = 1, color = 1, edges = {} } },
        has_commit = true,
        commit = commit,
    }
    for k, v in pairs(extra or {}) do c[k] = v end
    return c
end

local function commit(t)
    t.parents = t.parents or { {} }
    t.children = t.children or { {} }
    t.refs = t.refs or {}
    return t
end

-- Render one cell; return its glyph and the highlight group drawn on it.
local function draw(o, cell, emphasis)
    local res = gcc(o, { cell }, emphasis)
    local hl = res.highlight and res.highlight[1] and res.highlight[1].hl
    return vim.trim(res.text), hl
end

describe("HEAD node marker (§5.3)", function()
    it("an ordinary commit HEAD points at draws ● in the HEAD colour", function()
        local g, hl = draw(opts(), node_cell(commit({ refs = { HEAD_ATTACHED } })))
        assert.equals("●", g)
        assert.equals("HeadHl", hl)
    end)

    it("a detached HEAD is marked the same way", function()
        local g, hl = draw(opts(), node_cell(commit({ refs = { HEAD_DETACHED } })))
        assert.equals("●", g)
        assert.equals("HeadHl", hl)
    end)

    it("a commit without the head ref keeps its shape marker and lane colour", function()
        local g, hl = draw(opts(), node_cell(commit({ refs = { { kind = "local", name = "x" } } })))
        assert.equals("○", g)
        assert.equals("C0", hl)
    end)

    it("overrides the tip, root and merge-icon markers", function()
        local o = opts({ merge = "M" })
        assert.equals("●", (draw(o, node_cell(commit({ children = {}, refs = { HEAD_ATTACHED } })))))
        assert.equals("●", (draw(o, node_cell(commit({ parents = {}, refs = { HEAD_ATTACHED } })))))
        assert.equals("●", (draw(o, node_cell(commit({ parents = { {}, {} }, refs = { HEAD_ATTACHED } })))))
        -- sanity: without HEAD those are ◉ / ◎ / the merge icon
        assert.equals("◉", (draw(o, node_cell(commit({ children = {} })))))
        assert.equals("◎", (draw(o, node_cell(commit({ parents = {} })))))
        assert.equals("M", (draw(o, node_cell(commit({ parents = { {}, {} } })))))
    end)

    it("a working-tree virtual node keeps ◌ (precedence) in the HEAD colour", function()
        local g, hl = draw(opts(), node_cell(commit({ virtual = "staged", refs = { HEAD_ATTACHED } })))
        assert.equals("◌", g)
        assert.equals("HeadHl", hl)
        -- the clean node (no refs at all) too
        g, hl = draw(opts(), node_cell(commit({ virtual = "clean" })))
        assert.equals("◌", g)
        assert.equals("HeadHl", hl)
    end)

    it("icons.head = \"\" leaves ◌ in its lane colour", function()
        local g, hl = draw(opts({ head = "" }), node_cell(commit({ virtual = "clean" })))
        assert.equals("◌", g)
        assert.equals("C0", hl)
    end)

    it("dims an out-of-cone ◌ like any node (§12)", function()
        local o = opts()
        local _, hl = draw(o, node_cell(commit({ virtual = "clean" }), { active = false }), true)
        assert.equals(render.dim_hl(o, "HeadHl"), hl)
    end)

    it("a collapsed head containing HEAD keeps ◍ but takes the HEAD colour", function()
        local g, hl = draw(opts(), node_cell(commit({ collapsed = true, refs = { HEAD_DETACHED } })))
        assert.equals("◍", g)
        assert.equals("HeadHl", hl)
    end)

    it("dims an out-of-cone HEAD node like any node (§12)", function()
        local o = opts()
        local g, hl = draw(o, node_cell(commit({ refs = { HEAD_ATTACHED } }), { active = false }), true)
        assert.equals("●", g)
        assert.equals(render.dim_hl(o, "HeadHl"), hl)
    end)

    it("honours icons.head, and \"\" turns the marker off", function()
        assert.equals("@", (draw(opts({ head = "@" }), node_cell(commit({ refs = { HEAD_ATTACHED } })))))
        local g, hl = draw(opts({ head = "" }), node_cell(commit({ refs = { HEAD_ATTACHED } })))
        assert.equals("○", g)
        assert.equals("C0", hl)
    end)

    it("marks exactly HEAD's row in a laid-out graph, mirrored or not", function()
        local items = helpers.dag({ { "a", { "b" } }, { "b", { "c" } }, { "c", {} } })
        items[2].commit.refs = { HEAD_ATTACHED }
        for _, mirror in ipairs({ false, true }) do
            local o = opts()
            o.mirror = mirror
            local rows = graph._internal.build_graph(o, items)
            local glyphs = {}
            for i, row in ipairs(rows) do glyphs[i] = vim.trim(gcc(o, row.columns).text) end
            assert.same({ "◉", "●", "◎" }, glyphs)
        end
    end)
end)
