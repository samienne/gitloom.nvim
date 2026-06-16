--- Invariant-based tests for the graph layout algorithm.
---
--- Rather than golden snapshots (which would pin one visual style and need
--- constant re-blessing), these feed artificial commit DAGs through
--- build_graph and assert structural + rendered invariants: every commit is
--- laid out once, and the rendered glyph grid is a well-formed, fully
--- connected picture with continuous lane colors. See tests/graph_helpers.lua.
---
--- Every fixture is run under each merge_style — the options that decide
--- whether merges/splits get their own virtual line (above/below the commit)
--- to make room for crossings, or are folded onto the commit line.

local h = require("tests.graph_helpers")

-- merge_style variants exercised for every fixture. `experimental` styles run
-- the hand fixtures but skip the fuzzer (see the pending note below): the
-- allow_merge_on_split path has a known lane-id-across-crossing bug.
local STYLES = {
    { name = "split-line",      ms = { split_on_separate_line = true,  merge_on_separate_line = false } },
    { name = "merge-line",      ms = { split_on_separate_line = false, merge_on_separate_line = true } },
    { name = "both-lines",      ms = { split_on_separate_line = true,  merge_on_separate_line = true } },
    { name = "inline",          ms = { split_on_separate_line = false, merge_on_separate_line = false } },
    { name = "inline+mergesplit", experimental = true, ms = { split_on_separate_line = false, merge_on_separate_line = false, allow_merge_on_split = true } },
}

local FIXTURES = {
    {
        name = "linear",
        rows = { { "c1", { "c2" } }, { "c2", { "c3" } }, { "c3", {} } },
    },
    {
        name = "diamond",
        rows = {
            { "c1", { "c2", "c3" } },
            { "c2", { "c4" } },
            { "c3", { "c4" } },
            { "c4", {} },
        },
    },
    {
        name = "octopus",
        rows = {
            { "c1", { "c2", "c3", "c4" } },
            { "c2", { "c5" } },
            { "c3", { "c5" } },
            { "c4", { "c5" } },
            { "c5", {} },
        },
    },
    {
        name = "multiple-roots",
        rows = {
            { "c1", { "c2", "c3" } },
            { "c2", {} },
            { "c3", {} },
        },
    },
    {
        name = "interleaved",
        rows = {
            { "c1", { "c3" } },
            { "c2", { "c4" } },
            { "c3", { "c5" } },
            { "c4", { "c5" } },
            { "c5", { "c6", "c7" } }, -- merge AND split
            { "c6", { "c8" } },
            { "c7", { "c8" } },
            { "c8", {} },
        },
    },
}

local function assert_ok(opts, items, label)
    local errors, _, grid = h.check(opts, items)
    if #errors > 0 then
        local msg = ("\n%s\n--- graph ---\n%s\n--- errors ---\n%s"):format(
            label or "", h.grid_to_string(grid), table.concat(errors, "\n"))
        assert(false, msg)
    end
end

for _, style in ipairs(STYLES) do
    describe("graph layout [" .. style.name .. "]", function()
        for _, fx in ipairs(FIXTURES) do
            it("lays out " .. fx.name, function()
                assert_ok(h.opts(style.ms), h.dag(fx.rows), style.name .. "/" .. fx.name)
            end)
        end

        if style.experimental then
            -- Known bug: with allow_merge_on_split, a vertical lane's id (and
            -- thus color) flips where a merge's horizontal line crosses it —
            -- a vertical color break. Reproduces at seed=8 (n=11). Re-enable
            -- this as a real fuzz test once the layout path is fixed.
            pending("produces well-formed graphs for random DAGs (known crossing-id bug)")
        else
            it("produces well-formed graphs for random DAGs", function()
                local opts = h.opts(style.ms)
                local failures = {}
                for seed = 1, 60 do
                    local n = 3 + (seed % 10) -- sizes 3..12
                    local items = h.dag(h.random_dag(n, seed))
                    local errors, _, grid = h.check(opts, items)
                    if #errors > 0 then
                        failures[#failures + 1] = ("seed=%d n=%d:\n%s\n%s"):format(
                            seed, n, h.grid_to_string(grid), table.concat(errors, "\n"))
                        if #failures >= 3 then break end -- cap the noise
                    end
                end
                if #failures > 0 then
                    assert(false, "\n=== fuzz failures ===\n" .. table.concat(failures, "\n\n"))
                end
            end)
        end
    end)
end

describe("invariant checker self-test", function()
    -- Guards against the checker silently becoming vacuous: it must flag
    -- the very defects it exists to catch.
    local opts = h.default_opts()

    local function grid(rows)
        return vim.tbl_map(function(line)
            return vim.tbl_map(function(cell)
                if type(cell) == "string" then return { ch = cell, hl = nil } end
                return cell
            end, line)
        end, rows)
    end

    local function has(errors, needle)
        for _, e in ipairs(errors) do
            if e:find(needle, 1, true) then return true end
        end
        return false
    end

    it("flags a dangling horizontal stub", function()
        local errors = h.check_grid(grid({ { "─", " " } }), opts)
        assert(has(errors, "dangling"), table.concat(errors, "\n"))
    end)

    it("flags a color change across a crossing", function()
        -- ─ │ ─ with mismatched horizontal colors on either side of the bar
        local errors = h.check_grid(grid({ {
            { ch = "─", hl = "Hl1" },
            { ch = "│", hl = "Hl3" },
            { ch = "─", hl = "Hl2" },
        } }), opts)
        assert(has(errors, "across crossing"), table.concat(errors, "\n"))
    end)

    it("flags an unknown glyph", function()
        local errors = h.check_grid(grid({ { "x" } }), opts)
        assert(has(errors, "unknown glyph"), table.concat(errors, "\n"))
    end)
end)
