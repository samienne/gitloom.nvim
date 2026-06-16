--- Invariant-based tests for the graph layout algorithm.
---
--- Rather than golden snapshots (which would pin one visual style and need
--- constant re-blessing), these feed artificial commit DAGs through
--- build_graph and assert structural + rendered invariants: every commit is
--- laid out once, and the rendered glyph grid is a well-formed, fully
--- connected picture with continuous lane colors. See tests/graph_helpers.lua.

local h = require("tests.graph_helpers")

local function assert_ok(items, label)
    local errors, _, grid = h.check(h.default_opts(), items)
    if #errors > 0 then
        local msg = ("\n%s\n--- graph ---\n%s\n--- errors ---\n%s"):format(
            label or "", h.grid_to_string(grid), table.concat(errors, "\n"))
        assert(false, msg)
    end
end

describe("graph layout", function()
    it("lays out a linear history", function()
        assert_ok(h.dag({
            { "c1", { "c2" } },
            { "c2", { "c3" } },
            { "c3", {} },
        }), "linear")
    end)

    it("lays out a diamond (split + merge)", function()
        assert_ok(h.dag({
            { "c1", { "c2", "c3" } }, -- merge of two branches
            { "c2", { "c4" } },
            { "c3", { "c4" } },
            { "c4", {} },             -- root; split point for c2/c3
        }), "diamond")
    end)

    it("lays out an octopus merge (3 parents)", function()
        assert_ok(h.dag({
            { "c1", { "c2", "c3", "c4" } },
            { "c2", { "c5" } },
            { "c3", { "c5" } },
            { "c4", { "c5" } },
            { "c5", {} },
        }), "octopus")
    end)

    it("lays out multiple roots", function()
        assert_ok(h.dag({
            { "c1", { "c2", "c3" } },
            { "c2", {} }, -- root A
            { "c3", {} }, -- root B
        }), "multiple-roots")
    end)

    it("lays out interleaved branches (likely crossings)", function()
        assert_ok(h.dag({
            { "c1", { "c3" } },
            { "c2", { "c4" } },
            { "c3", { "c5" } },
            { "c4", { "c5" } },
            { "c5", { "c6", "c7" } },
            { "c6", { "c8" } },
            { "c7", { "c8" } },
            { "c8", {} },
        }), "interleaved")
    end)
end)

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

describe("graph layout fuzzing", function()
    it("produces well-formed graphs for random DAGs", function()
        local failures = {}
        for seed = 1, 60 do
            local n = 3 + (seed % 10) -- sizes 3..12
            local items = h.dag(h.random_dag(n, seed))
            local errors, _, grid = h.check(h.default_opts(), items)
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
end)
