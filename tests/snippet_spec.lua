--- Tests for the commit-search graph snippet (`graph_snippet`, spec §15.3): the
--- compact "where is this commit in the graph" locator rendered into the search
--- preview. Pure over already-laid-out items (build_graph output), so it is
--- testable without snacks/a window.
---
--- The contract: a window of `[focus - radius, focus + radius]` rows clamped to
--- the item range, each row = a left gutter + the graph cells (padded to a shared
--- width) + a short subject, the focus row marked; the returned `focus_row` is
--- the focus's 1-based index within the rendered rows.

local graph = require("gitloom.graph")
local helpers = require("tests.graph_helpers")

local graph_snippet = graph._internal.graph_snippet
local build_graph = graph._internal.build_graph

-- A laid-out linear chain A→B→C→D→E (newest first; message == hash).
local function chain()
    local items = helpers.dag({
        { "A", { "B" } },
        { "B", { "C" } },
        { "C", { "D" } },
        { "D", { "E" } },
        { "E", {} },
    })
    return build_graph(helpers.default_opts(), items)
end

describe("graph_snippet (§15.3)", function()
    local opts = helpers.default_opts()

    it("windows [focus-radius, focus+radius] and reports the focus row", function()
        local rows = chain()
        local out, focus_row = graph_snippet(opts, rows, 3, 1) -- centre on C
        assert.equals(3, #out)                                 -- B, C, D
        assert.equals(2, focus_row)
    end)

    it("marks the focus row with the gutter; others are blank", function()
        local rows = chain()
        local out = graph_snippet(opts, rows, 3, 1)
        assert.is_true(vim.startswith(out[2].text, "▸ ")) -- focus (C)
        assert.is_true(vim.startswith(out[1].text, "  ")) -- B
        assert.is_true(vim.startswith(out[3].text, "  ")) -- D
    end)

    it("ends each row with the commit subject", function()
        local rows = chain()
        local out = graph_snippet(opts, rows, 3, 1)
        assert.is_true(vim.endswith(out[1].text, "B"))
        assert.is_true(vim.endswith(out[2].text, "C"))
        assert.is_true(vim.endswith(out[3].text, "D"))
    end)

    it("clamps the window at the top", function()
        local rows = chain()
        local out, focus_row = graph_snippet(opts, rows, 1, 2) -- A, radius 2
        assert.equals(3, #out)                                 -- A, B, C (no rows above A)
        assert.equals(1, focus_row)
        assert.is_true(vim.startswith(out[1].text, "▸ "))
    end)

    it("clamps the window at the bottom", function()
        local rows = chain()
        local out, focus_row = graph_snippet(opts, rows, 5, 2) -- E, radius 2
        assert.equals(3, #out)                                 -- C, D, E
        assert.equals(3, focus_row)
        assert.is_true(vim.startswith(out[3].text, "▸ "))
    end)

    it("pads the graph cells so the subjects start at a common column", function()
        local rows = chain()
        local out = graph_snippet(opts, rows, 3, 2)
        -- The subject is the last field; its preceding text (gutter + graph + the
        -- separating space) must be the same display width on every row so the
        -- labels line up. Strip the trailing subject and compare widths.
        local subjects = { "A", "B", "C", "D", "E" } -- rows 1..5 == the chain
        local widths = {}
        for i, r in ipairs(out) do
            local subj = subjects[i]
            local prefix = r.text:sub(1, #r.text - #subj)
            widths[#widths + 1] = vim.fn.strdisplaywidth(prefix)
        end
        for i = 2, #widths do
            assert.equals(widths[1], widths[i])
        end
    end)

    it("labels a collapsed head by its region count, not a subject", function()
        local rows = chain()
        -- Mark C as a collapsed head (spec §10.3) covering 3 commits.
        rows[3].commit.collapsed = true
        rows[3].commit.count = 3
        local out = graph_snippet(opts, rows, 3, 0)
        assert.is_true(vim.endswith(out[1].text, "3 commits"))
    end)
end)
