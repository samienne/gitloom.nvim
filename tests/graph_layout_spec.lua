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

-- Layout policies (spec §5.6) exercised for every fixture, alongside the merge
-- styles. Every §5.1 UNIVERSAL invariant and both §5.1 GUARDS must hold under all
-- of them — the guards are violation counts, so they simply go vacuous where a
-- policy makes no jog. Only the linear-commit slide itself is policy-specific
-- (§5.6), and it is asserted separately below.
local POLICIES = { "compact", "survivors", "linear", "straight", "gutter" }
-- The policies that let a commit's node fall wherever its own lane already is.
-- `gutter` (§5.6) pins the current subject lane to a fixed column, so on the rows
-- where that column changes hands a linear commit's fan is not degenerate and the
-- §5.1 no-crossings COROLLARY does not apply to it. Its replacement guarantee is
-- asserted separately below. (Verified, not assumed: the corollary's check finds
-- 1154 offending commit lines over 400 DAGs under `gutter`, 0 under `straight`.)
local LANE_COLUMN = { "compact", "survivors", "linear", "straight" }

--- big_opts for a merge style, pinned to a layout policy.
local function policy_opts(ms, policy)
    local o = h.big_opts(ms)
    o.layout_policy = policy
    return o
end

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
    for _, policy in ipairs(POLICIES) do
        describe("graph layout [" .. style.name .. " / " .. policy .. "]", function()
            local opts = policy_opts(style.ms, policy)
            for _, fx in ipairs(FIXTURES) do
                it("lays out " .. fx.name, function()
                    -- big_opts => color is a 1:1 proxy for lane id, so the
                    -- color/id-continuity checks are exact (no palette-collision
                    -- masking). The experimental style skips color (lane handoff).
                    assert_ok(opts, h.dag(fx.rows), style.name .. "/" .. policy .. "/" .. fx.name, style.experimental)
                end)
            end

            if style.experimental then
                it("produces structurally well-formed graphs for random DAGs", function()
                    -- Color/id-continuity is intentionally not asserted here (lane
                    -- handoff at merges); structural well-formedness still must hold.
                    fuzz(opts, true)
                end)
            else
                it("produces well-formed graphs (incl. exact id-continuity) for random DAGs", function()
                    fuzz(opts, false)
                end)
            end
        end)
    end
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

    -- The guard is UNIVERSAL (§5.1): it constrains any jog a policy makes, so it
    -- holds under every layout policy — vacuously under `straight`, which makes
    -- none. Asserting it as a violation COUNT is what lets the same test body run
    -- unchanged across the matrix.
    for _, policy in ipairs(LANE_COLUMN) do
        it("lays out no commit-line crossing across a fuzz sweep (both-lines / " .. policy .. ")", function()
            local opts = policy_opts({ split_on_separate_line = true, merge_on_separate_line = true }, policy)
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
    end

    -- The `gutter` replacement for the corollary (§5.6). On the rows where the
    -- gutter changes hands its commit Lines DO carry horizontals, and therefore
    -- crossings. What must still hold is that a reader follows exactly ONE run per
    -- row and it always touches that row's node: every horizontal wire on the Line
    -- belongs to a single contiguous run containing the node's column, with no
    -- second, unrelated horizontal anywhere. That is strictly checkable and it is
    -- the guarantee the policy offers in place of "no crossings".
    it("every horizontal belongs to one run containing the node (gutter)", function()
        local STYLE_LIST = {
            { split_on_separate_line = true,  merge_on_separate_line = true },
            { split_on_separate_line = true,  merge_on_separate_line = false },
            { split_on_separate_line = false, merge_on_separate_line = true },
            { split_on_separate_line = false, merge_on_separate_line = false },
        }
        local bad = {}
        for si, ms in ipairs(STYLE_LIST) do
            local opts = policy_opts(ms, "gutter")
            for seed = 1, 150 do
                local rows = build_graph(opts, h.dag(h.random_dag(3 + (seed % 12), seed)))
                for ri, row in ipairs(rows) do
                    local ccol
                    for j, col in ipairs(row.columns) do if col.has_commit then ccol = j end end
                    for _, line in ipairs({ row.split or false, row.columns, row.merge or false }) do
                        if line then
                            local near, far = nil, 0
                            for j, col in ipairs(line) do
                                local c = col.connectivity
                                if c.left or c.right then
                                    near = near or j
                                    if j > far then far = j end
                                end
                            end
                            if near then
                                for j = near, far do
                                    local c = line[j] and line[j].connectivity
                                    if not (c and (c.left or c.right)) then
                                        bad[#bad + 1] = ("style=%d seed=%d row=%d: horizontal run breaks at col %d")
                                            :format(si, seed, ri, j)
                                    end
                                end
                                if ccol and not (ccol >= near - 1 and ccol <= far + 1) then
                                    bad[#bad + 1] = ("style=%d seed=%d row=%d: run [%d,%d] does not reach the node at %d")
                                        :format(si, seed, ri, near, far, ccol)
                                end
                            end
                        end
                    end
                end
                if #bad >= 6 then break end
            end
        end
        assert.equals(0, #bad, "\n" .. table.concat(bad, "\n"))
    end)
end)

describe("a fan line carries no compaction (§5)", function()
    -- On a commit line whose fan is *inline* (no separate split/merge line), a
    -- pass-through lane must cross the fan vertically, never compact horizontally
    -- along it — two separated lanes may share a horizontal only at a fan they
    -- belong to. So a pure survivor (begin ≠ C and parent ≠ C) draws NO horizontal
    -- segment on an inline-fan commit line. (Compaction on a non-fan line, or on a
    -- line whose fan sits on its own split/merge Line, is fine.)
    local build_graph = require("gitloom.graph")._internal.build_graph

    local function inline_fan_compaction(row)
        local C = row.commit and row.commit.hash
        local inline_fan = ((#(row.child_lanes or {}) > 1) and not row.split)
            or ((#(row.parent_lanes or {}) > 1) and not row.merge)
        if not inline_fan then return 0 end
        local n = 0
        for _, col in ipairs(row.columns or {}) do
            for _, s in ipairs(col.lanes or {}) do
                local c = s.connectivity
                local b = s.begin and s.begin.hash
                local p = s.parent and s.parent.hash
                if (c.left or c.right) and b ~= C and p ~= C then n = n + 1 end
            end
        end
        return n
    end

    local CASES = {
        { name = "inline",     ms = { split_on_separate_line = false, merge_on_separate_line = false } },
        { name = "split-line", ms = { split_on_separate_line = true,  merge_on_separate_line = false } },
        { name = "merge-line", ms = { split_on_separate_line = false, merge_on_separate_line = true } },
    }
    -- Like the crossing guard above, this is UNIVERSAL (§5.1) — a constraint on
    -- compaction where it runs, vacuous where it does not — so it runs unchanged
    -- under every policy.
    local MATRIX = {}
    for _, style in ipairs(CASES) do
        for _, policy in ipairs(POLICIES) do
            MATRIX[#MATRIX + 1] = { name = style.name .. " / " .. policy, ms = style.ms, policy = policy }
        end
    end
    for _, style in ipairs(MATRIX) do
        it("keeps survivors vertical across an inline fan [" .. style.name .. "]", function()
            local opts = policy_opts(style.ms, style.policy)
            local bad = {}
            for seed = 1, 250 do
                local n = 3 + (seed % 12)
                local rows = build_graph(opts, h.dag(h.random_dag(n, seed)))
                for ri, row in ipairs(rows) do
                    local x = inline_fan_compaction(row)
                    if x > 0 then
                        bad[#bad + 1] = ("seed=%d row=%d count=%d"):format(seed, ri, x)
                    end
                end
                if #bad >= 6 then break end
            end
            assert.equals(0, #bad, "\nsurvivor compacted along a fan line:\n" .. table.concat(bad, "\n"))
        end)
    end
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
        -- A golden snapshot is a picture of ONE policy's output (§5.6), so pin it
        -- explicitly rather than inheriting whatever the default happens to be —
        -- otherwise changing the default silently re-blesses a characterization test.
        opts.layout_policy = "compact"
        local items = h.dag(h.random_dag(7, 108))
        assert.equals(EXPECTED, h.snapshot(opts, items))
    end)
end)

describe("layout policy (§5.6)", function()
    local build_graph = require("gitloom.graph")._internal.build_graph

    -- A compact, order-independent signature of one laid-out graph: enough to tell
    -- two policies' output apart without pinning a rendering.
    local function shape(rows)
        local out = {}
        for _, row in ipairs(rows) do
            for _, line in ipairs({ row.split or false, row.columns, row.merge or false }) do
                if line then
                    for j, col in ipairs(line) do
                        for _, s in ipairs(col.lanes or {}) do
                            local c = s.connectivity
                            out[#out + 1] = ("%d:%s%s%s%s:%s"):format(j, c.up and "U" or "", c.down and "D" or "",
                                c.left and "L" or "", c.right and "R" or "", tostring(s.id))
                        end
                    end
                end
            end
            out[#out + 1] = "/"
        end
        return table.concat(out, ",")
    end

    local STYLE_MS = {
        { split_on_separate_line = false, merge_on_separate_line = false },
        { split_on_separate_line = true,  merge_on_separate_line = false },
        { split_on_separate_line = false, merge_on_separate_line = true },
        { split_on_separate_line = true,  merge_on_separate_line = true },
    }

    -- How many DAGs each policy renders differently from `compact`.
    local function divergence()
        local n, d = 0, { survivors = 0, linear = 0, straight = 0 }
        for _, ms in ipairs(STYLE_MS) do
            for seed = 1, 45 do
                local size = 6 + (seed % 9) -- 6..14
                local items = h.dag(h.random_dag(size, seed))
                local base = shape(build_graph(policy_opts(ms, "compact"), items))
                n = n + 1
                for p in pairs(d) do
                    if shape(build_graph(policy_opts(ms, p), items)) ~= base then d[p] = d[p] + 1 end
                end
            end
        end
        return n, d
    end

    it("the linear-commit slide almost never changes the layout", function()
        -- The measured justification behind §5.6: dropping the slide (compact →
        -- survivors) leaves the graph identical on the overwhelming majority of
        -- DAGs, while dropping survivor compaction (compact → linear) changes a
        -- large fraction. Asserted as a wide-margin RELATION, not an exact count,
        -- so it stays stable as the fixtures/fuzz change.
        local n, d = divergence()
        assert.is_true(d.survivors > 0,
            "the slide never fired at all — the `slide` stage may be dead")
        assert.is_true(d.survivors < n * 0.25,
            ("the slide changed the layout on %d/%d DAGs (expected a small minority)"):format(d.survivors, n))
        assert.is_true(d.linear > d.survivors * 3,
            ("survivor compaction (%d/%d) should dominate the slide (%d/%d)")
            :format(d.linear, n, d.survivors, n))
    end)

    it("under `straight` a lane never changes column", function()
        -- The defining property of the policy (§5.6): every lane holds its column
        -- for life. Checked on the pass-through verticals — a jog would show the
        -- same lane as a vertical in two different columns.
        --
        -- Tracked by EDGE IDENTITY, not by lane `id`. A first-parent continuation
        -- inherits the id of the chain that continues into it (§5), so one id spans
        -- a whole chain of distinct Lanes — and since identity is chosen from the
        -- DAG rather than from a column, the chain may legitimately continue in a
        -- different column from the one the senior lane arrived in. That is two
        -- Lanes meeting at a node, not a lane sliding.
        for _, ms in ipairs(STYLE_MS) do
            for seed = 1, 60 do
                local size = 4 + (seed % 11)
                local items = h.dag(h.random_dag(size, seed))
                local rows = build_graph(policy_opts(ms, "straight"), items)
                local col_of = {}
                for ri, row in ipairs(rows) do
                    for _, line in ipairs({ row.split or false, row.columns, row.merge or false }) do
                        if line then
                            for j, col in ipairs(line) do
                                for _, s in ipairs(col.lanes or {}) do
                                    -- one edge only: a multi-edge hub segment (§5)
                                    -- stands in for every converging edge at once
                                    if s.connectivity.up and s.connectivity.down
                                        and #(s.edges or {}) == 1 then
                                        local e = s.edges[1]
                                        local prev = col_of[e]
                                        assert(prev == nil or prev == j,
                                            ("seed=%d row=%d lane %s moved column %s -> %d under `straight`")
                                            :format(seed, ri, tostring(s.id), tostring(prev), j))
                                        col_of[e] = j
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end)

    -- THE GUARANTEE (spec §5 / §5.6): lane identity is chosen from the DAG and the
    -- row order alone, never from a column — so every policy produces the SAME lane
    -- ids and colours for the same input, differing only in where each lane is
    -- drawn. Switching policy with `C` moves the graph; it never recolours it.
    --
    -- Keyed by EDGE (begin, parent) with position deliberately absent, and sorted,
    -- so the comparison cannot accidentally encode column order. Any difference
    -- here is a placement dependence that has crept back into identity — chase it,
    -- do not relax this.
    it("lane identity is identical under every policy", function()
        local function identity(rows)
            local out = {}
            for i, row in ipairs(rows) do
                local per = {}
                for _, kind in ipairs({ "child_lanes", "parent_lanes" }) do
                    for _, l in ipairs(row[kind] or {}) do
                        per[#per + 1] = ("%s|%s->%s=%s/%s"):format(kind,
                            tostring(l.begin and l.begin.hash), tostring(l.parent and l.parent.hash),
                            tostring(l.id), tostring(l.color))
                    end
                end
                table.sort(per)
                out[i] = table.concat(per, ",")
            end
            return table.concat(out, "\n")
        end
        local bad = {}
        for _, ms in ipairs(STYLE_MS) do
            for seed = 1, 60 do
                local items = h.dag(h.random_dag(4 + (seed % 11), seed))
                local base = identity(build_graph(policy_opts(ms, "compact"), items))
                for _, p in ipairs({ "survivors", "linear", "straight", "gutter" }) do
                    local other = identity(build_graph(policy_opts(ms, p), items))
                    if other ~= base and #bad < 3 then
                        bad[#bad + 1] = ("seed=%d policy=%s"):format(seed, p)
                    end
                end
            end
        end
        assert.equals(0, #bad,
            "lane identity differs by policy — a placement dependence remains:\n"
            .. table.concat(bad, "\n"))
    end)

    it("an unknown or absent policy falls back to compact", function()
        -- `layout_policy` is read from user config, so a typo must degrade, not error.
        local items = h.dag(h.random_dag(11, 7))
        local base = shape(build_graph(policy_opts({}, "compact"), items))
        for _, bogus in ipairs({ "nonsense", "", "COMPACT", "slide" }) do
            assert.equals(base, shape(build_graph(policy_opts({}, bogus), items)))
        end
        local plain = h.big_opts() -- no layout_policy field at all
        assert.equals(base, shape(build_graph(plain, items)))
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
