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
---
--- The `inline+mergesplit` style (allow_merge_on_split) is experimental: at a
--- merge an incoming lane terminates and a new parent lane reuses the same
--- column, so a vertical lane's color legitimately changes mid-column. We do
--- not assert color-continuity there (only structural well-formedness), and a
--- separate characterization test locks the current rendering so it can't
--- silently change. See specification.md §5.2 and CLAUDE.md.

local h = require("tests.graph_helpers")
local top_lane = require("gitloom.graph")._internal.top_lane

describe("top_lane colour priority (§5, §6.2)", function()
    local function seg(id, conn) return { id = id, color = id, connectivity = conn } end

    it("a node-less fork bus prefers the horizontal bus over an up-branch stub", function()
        -- A fork-bus cell where a child branch leaves upward: bus (id 1, the fork source)
        -- + the child's up stub (id 3). The cell must read as the BUS so the horizontal
        -- line stays one colour — the child colour begins in the row above. (The header
        -- "dev branch line alternates id 1 / id 3" regression.)
        local segs = { seg(1, { left = true, right = true }), seg(3, { up = true }) }
        assert.equals(1, top_lane(segs, false, false).id)
        -- The bus END (the `┘` turn at the child's column): left-only + up stub — exactly
        -- the live R03 col3 case. Must still read as the bus (id 1), not the stub (id 3).
        local end_segs = { seg(1, { left = true }), seg(3, { up = true }) }
        assert.equals(1, top_lane(end_segs, false, false).id)
    end)

    it("a NODE cell keeps its own lane, not a crossing arm", function()
        -- e.g. a root ◉ with a merge arm turning in: the glyph must read in the node's
        -- own lane (the up stub, id 1), not the arm (id 6) — the snapshot regression.
        local segs = { seg(1, { up = true }), seg(6, { right = true }) }
        assert.equals(1, top_lane(segs, false, true).id)
    end)

    it("a genuine crossing keeps the passing through-lane's colour", function()
        -- A through vertical (up+down, id 5) crossed by a horizontal arm (id 2): the
        -- passing lane wins on BOTH node-less and node cells (continuity).
        local segs = { seg(2, { left = true, right = true }), seg(5, { up = true, down = true }) }
        assert.equals(5, top_lane(segs, false, false).id)
        assert.equals(5, top_lane(segs, false, true).id)
    end)
end)

-- merge_style variants exercised for every fixture.
local STYLES = {
    { name = "split-line",        ms = { split_on_separate_line = true,  merge_on_separate_line = false } },
    { name = "merge-line",        ms = { split_on_separate_line = false, merge_on_separate_line = true } },
    { name = "both-lines",        ms = { split_on_separate_line = true,  merge_on_separate_line = true } },
    { name = "inline",            ms = { split_on_separate_line = false, merge_on_separate_line = false } },
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

local function assert_ok(opts, items, label, skip_color)
    local errors, _, grid = h.check(opts, items, skip_color)
    if #errors > 0 then
        local msg = ("\n%s\n--- graph ---\n%s\n--- errors ---\n%s"):format(
            label or "", h.grid_to_string(grid), table.concat(errors, "\n"))
        assert(false, msg)
    end
end

-- Run the invariants over a batch of random DAGs; fail with details on the
-- first few offenders.
local function fuzz(opts, skip_color)
    local failures = {}
    for seed = 1, 60 do
        local n = 3 + (seed % 10) -- sizes 3..12
        local items = h.dag(h.random_dag(n, seed))
        local errors, _, grid = h.check(opts, items, skip_color)
        if #errors > 0 then
            failures[#failures + 1] = ("seed=%d n=%d:\n%s\n%s"):format(
                seed, n, h.grid_to_string(grid), table.concat(errors, "\n"))
            if #failures >= 3 then break end -- cap the noise
        end
    end
    if #failures > 0 then
        assert(false, "\n=== fuzz failures ===\n" .. table.concat(failures, "\n\n"))
    end
end

for _, style in ipairs(STYLES) do
    describe("graph layout [" .. style.name .. "]", function()
        for _, fx in ipairs(FIXTURES) do
            it("lays out " .. fx.name, function()
                -- big_opts => color is a 1:1 proxy for lane id, so the
                -- color/id-continuity checks are exact (no palette-collision
                -- masking). The experimental style skips color (lane handoff).
                assert_ok(h.big_opts(style.ms), h.dag(fx.rows), style.name .. "/" .. fx.name, style.experimental)
            end)
        end

        if style.experimental then
            it("produces structurally well-formed graphs for random DAGs", function()
                -- Color/id-continuity is intentionally not asserted here (lane
                -- handoff at merges); structural well-formedness still must hold.
                fuzz(h.big_opts(style.ms), true)
            end)
        else
            it("produces well-formed graphs (incl. exact id-continuity) for random DAGs", function()
                fuzz(h.big_opts(style.ms), false)
            end)
        end
    end)
end

describe("compaction never crosses a lane (§5)", function()
    -- A compaction jog must never lay its horizontal across another lane: once two
    -- lanes have separated they share a horizontal only at a commit's own fan
    -- (split/merge funnel). With BOTH fans on their own lines, the commit line
    -- carries no fan, so any crossing there is an illegal compaction jog. Repro:
    -- the linear-commit / survivor compaction used to reach past an occupied
    -- column into a farther gap, jogging the lane across the occupant.
    local build_graph = require("gitloom.graph")._internal.build_graph

    -- Count cells where a vertical lane (up+down) is crossed by a *different*
    -- lane's horizontal segment (left/right) — a crossing.
    local function commit_line_crossings(row)
        local n = 0
        for _, col in ipairs(row.columns or {}) do
            local vid, hid
            for _, s in ipairs(col.lanes or {}) do
                local c = s.connectivity
                if c.up and c.down then vid = s.id end
                if (c.left or c.right) and not (c.up and c.down) then hid = hid or s.id end
            end
            if vid and hid and vid ~= hid then n = n + 1 end
        end
        return n
    end

    it("lays out no commit-line crossing across a fuzz sweep (both-lines style)", function()
        local opts = h.big_opts({ split_on_separate_line = true, merge_on_separate_line = true })
        local bad = {}
        for seed = 1, 250 do
            local n = 3 + (seed % 12) -- sizes 3..14
            local items = h.dag(h.random_dag(n, seed))
            local rows = build_graph(opts, items)
            for ri, row in ipairs(rows) do
                local x = commit_line_crossings(row)
                if x > 0 then
                    bad[#bad + 1] = ("seed=%d row=%d crossings=%d"):format(seed, ri, x)
                end
            end
            if #bad >= 6 then break end
        end
        assert.equals(0, #bad, "\nillegal compaction crossings:\n" .. table.concat(bad, "\n"))
    end)
end)

describe("graph layout [inline+mergesplit] characterization", function()
    -- Locks the current (debatable) rendering of the merge lane-handoff so any
    -- change is flagged for review. NOT an assertion of correctness: at a merge
    -- under allow_merge_on_split an incoming lane terminates and a new parent
    -- lane reuses the same column (the sanctioned two-turn cell), so the vertical
    -- colour changes mid-column. Repro: random_dag(7, 108).
    local EXPECTED = [[
◉─╮  122
○ │  1.2
│ │ ◉─╮  1.2.344
│ │ │ │ ◉  1.2.3.4.5
○─│─│─╯ │  1464344.5
○─│─┴───╯  136335555
◎─╯  166]]

    it("renders the known merge-handoff repro unchanged", function()
        local opts = h.opts({
            split_on_separate_line = false,
            merge_on_separate_line = false,
            allow_merge_on_split = true,
        })
        local items = h.dag(h.random_dag(7, 108))
        assert.equals(EXPECTED, h.snapshot(opts, items))
    end)
end)

describe("lane model decomposition", function()
    -- Cells decompose into two-sided wires (validated broadly by check_lanes
    -- inside h.check); here we also confirm a junction yields >1 lane.
    it("splits junction cells into multiple lanes", function()
        local errors, rows = h.check(h.default_opts(), h.dag({
            { "c1", { "c2", "c3" } },
            { "c2", { "c4" } },
            { "c3", { "c4" } },
            { "c4", {} },
        }))
        assert.equals(0, #errors, table.concat(errors, "\n"))

        local max_lanes = 0
        for _, row in ipairs(rows) do
            for _, lst in ipairs({ row.columns, row.split or {}, row.merge or {} }) do
                for _, t in ipairs(lst) do
                    max_lanes = math.max(max_lanes, #(t.lanes or {}))
                end
            end
        end
        assert.is_true(max_lanes >= 2) -- the diamond has a tee/crossing
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

    it("lane continuity flags a conflated vertical (up id != above down id)", function()
        -- A column whose lane id changes between two connected cells without
        -- being modeled as two lanes — exactly what the handoff split prevents.
        local rows = {
            { columns = { { connectivity = { down = true }, lanes = { { id = 1, connectivity = { down = true } } } } } },
            { columns = { { connectivity = { up = true }, lanes = { { id = 2, connectivity = { up = true } } } } } },
        }
        assert(has(h.check_lane_continuity(rows), "up-lane id"))
    end)

    it("lane continuity accepts a matching column", function()
        local rows = {
            { columns = { { connectivity = { down = true }, lanes = { { id = 7, connectivity = { down = true } } } } } },
            { columns = { { connectivity = { up = true }, lanes = { { id = 7, connectivity = { up = true } } } } } },
        }
        assert.equals(0, #h.check_lane_continuity(rows))
    end)
end)
