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
-- Every policy: the §5.1 no-crossings COROLLARY (a both-lines commit Line carries
-- no horizontal, hence no crossing) holds under all five. It once failed under
-- `gutter`: the handover's swap-in rode on the arriving commit's own Line, so a
-- linear commit's "fan" spanned from its lane's column to the gutter and crossed
-- whatever lay between (1154 offending commit Lines over 400 DAGs). Giving the
-- swap-in a virtual row of its own removed that, and `gutter` now produces commit-
-- Line horizontals identical in count to `straight`'s.
local LANE_COLUMN = { "compact", "survivors", "linear", "straight", "gutter" }

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
-- first few offenders. `project` feeds each DAG through the §10.7 focused
-- projection first (`h.focused`), which is what a graph actually renders.
local function fuzz(opts, skip_color, project)
    local failures = {}
    -- Projection CONTRACTS a DAG (a collapsed run becomes one `◍`), so it needs more
    -- raw material than the plain sweep to produce the interesting rows — junctions
    -- and heads. Sizes 3..14 over 80 seeds is enough that several land on the shape
    -- the freed-column regression below needs (seeds 20, 42, 46 among them).
    local seeds = project and 80 or 60
    for seed = 1, seeds do
        local n = project and (3 + (seed % 12)) or (3 + (seed % 10)) -- 3..14 / 3..12
        local items = h.dag(h.random_dag(n, seed))
        if project then items = h.focused(items) end
        local ok, errors, _, grid = pcall(h.check, opts, items, skip_color)
        if not ok then
            -- `columns.layout`'s own oracle errors out, so an offender never reaches
            -- the invariants. Report it as the failure it is instead of blowing up
            -- the whole sweep on the first one.
            failures[#failures + 1] = ("seed=%d n=%d: LAYOUT ERROR %s"):format(seed, n, tostring(errors))
            errors = {}
        end
        if #errors > 0 then
            failures[#failures + 1] = ("seed=%d n=%d:\n%s\n%s"):format(
                seed, n, h.grid_to_string(grid), table.concat(errors, "\n"))
        end
        if #failures >= 3 then break end -- cap the noise
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

            -- The SAME sweep over the §10.7 FOCUSED PROJECTION — what an opened graph
            -- actually lays out (spec §10.7: the anchor's mainline in full, every other
            -- branch a `◍` head). A raw `dag()` is all ordinary commits, so every
            -- non-subject-row path in `columns.lua` (`owns_subject` false — a collapsed
            -- head or a junction marker) is unreachable no matter how hard the raw DAGs
            -- are fuzzed. That gap is what let `gutter` × `merge_on_separate_line` /
            -- `allow_merge_on_split` ship a hard `columns.layout` error while the whole
            -- policy × style matrix stayed green (see the regression below).
            it("produces well-formed graphs over the focused projection (§10.7)", function()
                fuzz(opts, style.experimental, true)
            end)
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

    -- The four stable merge styles (allow_merge_on_split excluded — its sanctioned
    -- two-turn cell is a colour handoff by design, §5.2).
    local STYLE_LIST = {
        { split_on_separate_line = true,  merge_on_separate_line = true },
        { split_on_separate_line = true,  merge_on_separate_line = false },
        { split_on_separate_line = false, merge_on_separate_line = true },
        { split_on_separate_line = false, merge_on_separate_line = false },
    }

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

    -- `gutter`'s own guarantee, on EVERY rendered line — including the two handover
    -- rows (§5.6), which are the only lines that carry a horizontal no fan asked
    -- for. A reader follows exactly ONE run per row and it always touches that
    -- row's node column (the gutter): every horizontal wire on the Line belongs to
    -- a single contiguous run reaching the node, with no second, unrelated
    -- horizontal anywhere. Strictly checkable, and stronger than the §5.1
    -- corollary the policy also satisfies now that the swap-in has its own row.
    it("every horizontal belongs to one run containing the node (gutter)", function()
        local bad = {}
        for si, ms in ipairs(STYLE_LIST) do
            local opts = policy_opts(ms, "gutter")
            for seed = 1, 150 do
                local rows = build_graph(opts, h.dag(h.random_dag(3 + (seed % 12), seed)))
                for ri, row in ipairs(rows) do
                    local ccol
                    for j, col in ipairs(row.columns) do if col.has_commit then ccol = j end end
                    for _, ln0 in ipairs(h.row_lines(row)) do
                        local line = ln0.line
                        do
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

    -- THE SPINE THROUGH A NODE (§5, §5.6). A commit's node sits on its OWN lane's
    -- column — the incoming lane its first parent continues — so the wire above the
    -- node and the wire below it are one Lane, one id, one colour (§5.6, verbatim).
    -- Under `gutter` this is exact: the gutter fixes the node column, and the
    -- handover rows are what bring the right lane into it.
    --
    -- The regression: the handover declined whenever ANY converging child already
    -- sat in the gutter, reading §5.6's "a lane already in the gutter needs no
    -- claim" as *any* lane rather than the CLAIMING one. Because the row order emits
    -- a merged-in lineage right after its merge (§3.1), the gutter at a fork is
    -- routinely held by the lineage that is ending there, not by the trunk the fork
    -- continues on — so the split hub and the wire down into the node rendered in
    -- the topic branch's colour while the spine below the node rendered in the
    -- trunk's. 85 of 986 nodes on a 1040-commit repository fully expanded, 21 of 605
    -- on `tests/large_topo`; `compact` showed 0–1 on the same corpora, which is why
    -- it read as a gutter-only defect.
    -- The one LICENSED exception is the §5.6 gutter parent swap: at a merge whose
    -- non-first parent owns the next subject row (and can keep the gutter), that parent
    -- takes the gutter and the first parent fans out, which removes the next row's two
    -- handover rows. `check_spine` prices that rather than exempting it — the break must
    -- be in the gutter, between this commit's first and a non-first parent Lane, AND
    -- observably save the handover (see `graph_helpers`). So this stays a hard 0.
    it("keeps one lane through a node's spine, or licenses the swap (gutter)", function()
        local bad, licensed_raw, licensed_foc = {}, 0, 0
        local kraw = { merge = 0, split = 0 }
        for _, ms in ipairs(STYLE_LIST) do
            local opts = policy_opts(ms, "gutter")
            for seed = 1, 200 do
                local items = h.dag(h.random_dag(4 + (seed % 14), seed))
                -- BOTH corpora: the raw DAG (all subject rows — where the swaps can fire)
                -- and the §10.7 projection (◍ heads and junction markers, i.e. non-subject
                -- rows, where the merge swap's clause 2 declines it and the split swap has
                -- no foreign occupant to keep). A raw-only sweep would miss the decline
                -- entirely, which is the whole point of the merge swap's clause 2.
                local raw = build_graph(opts, items)
                local e1, n1, k1 = h.check_spine(raw, opts)
                licensed_raw = licensed_raw + n1
                kraw.merge, kraw.split = kraw.merge + k1.merge, kraw.split + k1.split
                for _, e in ipairs(e1) do
                    if #bad < 6 then bad[#bad + 1] = ("raw seed=%d %s"):format(seed, e) end
                end
                -- The projection's anchor ranked, as the window ranks it (§10.6): with §5
                -- tier 2 picking the NEWEST lane, an unranked trunk would hand its forks to
                -- the topic already in the gutter, and the swaps would fire here too.
                local fopts = vim.tbl_extend("force", opts, { pin_rank = { t1 = 1 } })
                local foc = build_graph(fopts, h.focused(h.dag(h.random_dag(4 + (seed % 14), seed))))
                local e2, n2 = h.check_spine(foc, fopts)
                licensed_foc = licensed_foc + n2
                for _, e in ipairs(e2) do
                    if #bad < 6 then bad[#bad + 1] = ("focused seed=%d %s"):format(seed, e) end
                end
            end
        end
        assert.equals(0, #bad, "\nnode spine changes lane mid-column:\n" .. table.concat(bad, "\n"))
        -- Not vacuous: the swaps really do fire on the raw (fully expanded) corpus, and
        -- BOTH licences are exercised — the merge swap's on any style, the split swap's
        -- only where the fan-in is inline (with a split Line of its own it breaks nothing).
        assert.is_true(licensed_raw > 0, "the gutter parent swap never fired — test is vacuous")
        assert.is_true(kraw.merge > 0, "the MERGE swap licence never fired — test is vacuous")
        assert.is_true(kraw.split > 0, "the SPLIT swap licence never fired — test is vacuous")
        -- ... and never in the focused projection, where a collapsed head sits after the
        -- merge and owns no subject row (§5.6 clause 2). This is the byte-identity claim
        -- in invariant form: no break, so nothing about the focused view moved.
        assert.equals(0, licensed_foc)
    end)

    -- The reported case, as a fixture rather than a fuzz hit, so the failure names
    -- the shape: a fork `f` that three lines of history came out of — the trunk
    -- (`main`) plus two topic branches — where the row order puts a TOPIC's last
    -- commit directly above the fork. That is not contrived: the ordering emits a
    -- merged-in lineage contiguously right after its merge (§3.1), so at a fork with
    -- more than two children the trunk's own commit is emitted early and a junior
    -- lineage ends up adjacent — it is the shape of 21 of `tests/large_topo`'s 605
    -- expanded nodes. The junior lane then holds the gutter when the fork arrives, and
    -- the fork must still render on the trunk: the split hub above the node, the node,
    -- and the wire below it are one lane, one colour (§5.6).
    it("draws a fork hub in the TRUNK's colour, not the merged-in topic's (gutter)", function()
        local items = h.dag({
            { "tip",   { "main", "topic" } }, -- merges the trunk and a topic
            { "main",  { "f" } },             -- the trunk: SENIOR lane, emitted early
            { "topic", { "t1", "t2" } },      -- the topic itself merges two lines
            { "t1",    { "f" } },
            { "t2",    { "f" } },             -- junior, and directly above the fork
            { "f",     { "r" } },
            { "r",     {} },
        })
        -- The trunk is pinned (as the window pins `master`/`main`/`dev`, §10.6): §5 tier
        -- 0 is what continues it through `f`; unpinned, tier 2 would continue the NEWEST
        -- lane (`t2`'s, already in the gutter) and there would be no trunk to keep.
        items[1].commit.refs = { { kind = "local", name = "trunk" } }
        local opts = policy_opts({ split_on_separate_line = true, merge_on_separate_line = false }, "gutter")
        opts.pin_rank = { trunk = 1 }
        local rows = build_graph(opts, items)
        assert.equals(0, #h.check_spine(rows, opts), "the fork's spine changes lane at the node")

        -- Locate f's row: the trunk lane it continues on must own the split hub above
        -- it, its node cell, and the wire below — and the topics must be ARMS.
        local frow
        for _, row in ipairs(rows) do
            if row.commit.hash == "f" then frow = row end
        end
        assert.truthy(frow)
        assert.equals(3, #frow.child_lanes) -- main's, t1's and t2's edges converge here
        local trunk = frow.parent_lanes[1].id
        -- the trunk's own edge into f is the RANKED incoming lane (§5 identity, tier 0)
        local ranked
        for _, l in ipairs(frow.child_lanes) do if l.rank == 1 then ranked = l.id end end
        assert.equals(ranked, trunk, "f must continue the pinned (trunk) lane")

        local fan = frow.above[#frow.above] -- fan_in appends the split Line last
        local ncol
        for j, cell in ipairs(frow.columns) do if cell.has_commit then ncol = j end end
        local hub_down
        for _, s in ipairs(fan[ncol].lanes or {}) do
            if s.connectivity.down then hub_down = s end
        end
        assert.truthy(hub_down, "the split hub must descend into the node's column")
        assert.equals(trunk, hub_down.id, "the split hub must be the trunk's lane, not the topic's")
        assert.equals(frow.parent_lanes[1].color, hub_down.color)
    end)
end)

-- THE GUTTER PARENT SWAP (§5.6). At a merge, send the parent that owns the NEXT
-- subject row down the gutter and the first parent out to the side, so that row needs
-- no handover at all. It is deliberately hard to fire, and every clause is load-bearing:
--
--   1. that parent's next commit comes earlier in row order than the first parent's;
--   2. that parent OWNS the next subject row;
--   3. this merge is its only in-set child, so it can KEEP the gutter it is handed.
--
-- Clause 2 is the one measurement forced. With clause 1 alone the gate fires at 100% of
-- merges in the shipping FOCUSED view and buys nothing — §3.1's lineage grouping parks
-- the merged-in branch's `◍` head right after its merge, so clause 1 passes, but a
-- collapsed head owns no subject row and never wanted the gutter. That is why every case
-- below is asserted on BOTH corpora: the raw DAG, where the branch is expanded and the
-- swap pays off, and `h.focused` (§10.7), where the very same DAG must decline.
describe("the gutter parent swap (§5.6)", function()
    local build_graph = require("gitloom.graph")._internal.build_graph
    local opts = policy_opts({ split_on_separate_line = true, merge_on_separate_line = false }, "gutter")

    --- Which of a row's parent Lanes leaves through its node cell — 1 normally, 2+ when
    --- the swap fired. Read off the rendered row, not from any internal flag.
    local function cont_index(row)
        local down
        for _, cell in ipairs(row.columns or {}) do
            if cell.has_commit then
                for _, s in ipairs(cell.lanes or {}) do
                    if s.connectivity.down and not down then down = s end
                end
            end
        end
        if not down then return nil end
        for i, l in ipairs(row.parent_lanes or {}) do
            if l.id == down.id then return i end
        end
    end

    local function row_of(rows, hash)
        for i, r in ipairs(rows) do
            if r.commit.hash == hash then return r, i end
        end
    end

    --- Virtual above-rows that are HANDOVER rows: a split fan always carries the shared
    --- multi-edge descent (§5), an eviction or claim row never does.
    local function handover_rows(row)
        local n = 0
        for _, ln in ipairs(row.above or {}) do
            local multi = false
            for _, cell in ipairs(ln) do
                for _, s in ipairs(cell.lanes or {}) do
                    if #(s.edges or {}) > 1 then multi = true end
                end
            end
            if not multi then n = n + 1 end
        end
        return n
    end

    -- A trunk merge `m` taking in a topic run `b1 -> b2`, which §3.1 emits immediately
    -- after it. Expanded, `b1` owns the next subject row, so the gutter goes to it.
    -- `h` sits above the merge so its node cell has a wire arriving from above — without
    -- one there is no spine to break and nothing to license.
    local TOPIC = {
        { "h",  { "m" } },        -- the tip, so `m` is entered from above on the trunk lane
        { "m",  { "t3", "b1" } }, -- merge: first parent the trunk (row 5), then the topic
        { "b1", { "b2" } },       -- the merged-in lineage, contiguous after its merge
        { "b2", { "t3" } },
        { "t3", { "t4" } },
        { "t4", {} },
    }

    it("fires: the merged-in parent takes the gutter, the first parent fans out", function()
        local rows = build_graph(opts, h.dag(TOPIC))
        local m = row_of(rows, "m")
        assert.equals(2, #m.parent_lanes)
        assert.equals(2, cont_index(m), "the SECOND parent must continue in the gutter")
        -- ... and the row it was handed to needs no handover, which is the entire point.
        local b1 = row_of(rows, "b1")
        assert.equals(0, handover_rows(b1))
        -- The break is licensed, and the licence is earned (see graph_helpers).
        local errors, licensed = h.check_spine(rows, opts)
        assert.equals(0, #errors, table.concat(errors, "\n"))
        assert.equals(1, licensed)
    end)

    it("colours the swapped merge from its OWN lane (the trunk), not the topic", function()
        -- `top_lane` normally takes a node's colour from the cell's DOWN wire, which
        -- after a swap is the topic's lane — so a trunk merge would render as the branch
        -- it merged (the perception this policy already had to fix once). The layout marks
        -- the cell `own_lane_up`, and the node then reads in the first parent's colour
        -- while the topic lane simply BEGINS below it.
        local rows = build_graph(opts, h.dag(TOPIC))
        local m = row_of(rows, "m")
        local cell
        for _, c in ipairs(m.columns) do if c.has_commit then cell = c end end
        assert.is_true(cell.own_lane_up)
        local seg = assert(top_lane(cell.lanes, false, true, cell.own_lane_up))
        assert.equals(m.parent_lanes[1].id, seg.id)
        assert.equals(m.parent_lanes[1].color, seg.color)
        -- Without the flag it would be the topic's — the defect, stated so the fix cannot
        -- silently become a no-op.
        assert.equals(m.parent_lanes[2].id, top_lane(cell.lanes, false, true).id)
    end)

    it("declines when clause 2 fails: the next row is a COLLAPSED HEAD (focused)", function()
        -- The same DAG through the §10.7 projection: `b1`/`b2` contract to one `◍`, which
        -- carries labels but no subject (§5.6), so the merged-in parent does NOT own the
        -- next subject row. Clause 1 still passes — this is exactly the 100%-fire /
        -- 0%-saving case, and the reason clause 2 exists.
        local raw = build_graph(opts, h.dag(TOPIC))
        assert.equals(2, cont_index(row_of(raw, "m")), "precondition: it fires expanded")

        local rows = build_graph(opts, h.focused(h.dag(TOPIC)))
        local m = row_of(rows, "m")
        assert.equals(2, #m.parent_lanes, "the merge must still have both parents projected")
        assert.equals(1, cont_index(m), "the FIRST parent must keep the gutter")
        local errors, licensed = h.check_spine(rows, opts)
        assert.equals(0, #errors, table.concat(errors, "\n"))
        assert.equals(0, licensed, "no break at all in the focused view")
    end)

    it("declines when clause 1 fails: the FIRST parent already comes first", function()
        -- c2's first parent c3 is the next row, so nothing needs swapping.
        local rows = build_graph(opts, h.dag({
            { "c1", { "c2" } }, { "c2", { "c3", "c4" } }, { "c3", { "c4" } }, { "c4", {} },
        }))
        assert.equals(1, cont_index(row_of(rows, "c2")))
        assert.equals(0, select(2, h.check_spine(rows, opts)))
    end)

    it("declines when clause 3 fails: that parent has another child, so it cannot keep it", function()
        -- c3 owns the next subject row and comes before c5, but c1 forks to it as well —
        -- so c1's edge is the SENIOR lane arriving at c3 and the one c3 continues (§5).
        -- The lane the swap would hand over gets evicted anyway, so the break would buy
        -- nothing: exactly the 15-of-100 residue clause 3 removes.
        local items = h.dag({
            { "c1", { "c2", "c3" } }, { "c2", { "c5", "c3" } }, { "c3", { "c4" } },
            { "c4", { "c5" } }, { "c5", {} },
        })
        local rows = build_graph(opts, items)
        local c3 = row_of(rows, "c3")
        assert.equals(2, #c3.child_lanes, "precondition: two lanes arrive at c3")
        assert.equals(1, cont_index(row_of(rows, "c2")))
        assert.equals(0, select(2, h.check_spine(rows, opts)))
    end)

    it("never fires under any other policy (§5.6: only `gutter` constrains a column)", function()
        for _, policy in ipairs({ "compact", "survivors", "linear", "straight" }) do
            for _, style in ipairs(STYLES) do
                local o = policy_opts(style.ms, policy)
                for _, items in ipairs({ h.dag(TOPIC), h.focused(h.dag(TOPIC)) }) do
                    local rows = build_graph(o, items)
                    local m = row_of(rows, "m")
                    assert.equals(1, cont_index(m),
                        ("%s/%s must leave the first parent continuing"):format(policy, style.name))
                    for _, r in ipairs(rows) do
                        for _, c in ipairs(r.columns) do assert.is_nil(c.own_lane_up) end
                    end
                end
            end
        end
    end)
end)

-- THE GUTTER SPLIT SWAP (§5.6), the mirror at a FORK. The gutter is held by one of this
-- commit's converging children that is not the one it continues; instead of evicting that
-- child and claiming the column back (two virtual rows), the node takes the gutter WHERE
-- THE CHILD ALREADY IS and the commit's own lane converges into it as an ordinary fan arm.
--
-- No lookahead is involved: the sweep runs top to bottom, so the occupant is already
-- decided when the fork is reached. What varies is where the fan-in is drawn, and it
-- decides whether anything is broken at all:
--
--   * a separate split Line — the occupant terminates up there and the hub descent into
--     the node carries the commit's own lane, so the spine is INTACT (nothing licensed);
--   * an inline fan-in — the occupant's up-stub IS the node's wire from above, so the
--     spine breaks and the break is licensed 1:1 against the two rows it removed.
--
-- Both are asserted, and on BOTH corpora: the raw DAG (expanded, where it fires) and
-- `h.focused` (§10.7, the shipping default, where the gutter is already the trunk's and
-- there is nothing to swap).
describe("the gutter split swap (§5.6)", function()
    -- Every fixture's TRUNK (its first row) carries a `trunk` ref pinned at rank 1, and
    -- the §10.7 projection's anchor (`t1`, `h.focused`) is ranked too — as the window
    -- ranks its anchors (§10.6). The swap exists for a fork the trunk continues while a
    -- topic holds the gutter; with §5 tier 2 picking the NEWEST lane, an UNPINNED fork
    -- continues the topic already in the gutter and there is nothing to swap.
    local function gopts(ms, policy)
        local o = policy_opts(ms, policy)
        o.pin_rank = { trunk = 1, t1 = 1 }
        return o
    end
    local function gdag(spec)
        local items = h.dag(spec)
        local c = items[1].commit
        c.refs = c.refs or {}
        table.insert(c.refs, { kind = "local", name = "trunk" })
        return items
    end
    local build_graph = require("gitloom.graph")._internal.build_graph
    local SPLITLINE = { split_on_separate_line = true, merge_on_separate_line = false }
    local INLINE = { split_on_separate_line = false, merge_on_separate_line = false }

    local function row_of(rows, hash)
        for i, r in ipairs(rows) do
            if r.commit.hash == hash then return r, i end
        end
    end

    --- Virtual above-rows that are HANDOVER rows (an eviction or a claim): a split fan
    --- always carries the shared multi-edge descent (§5), a handover row never does.
    local function handover_rows(row)
        local n = 0
        for _, ln in ipairs(row.above or {}) do
            local multi = false
            for _, cell in ipairs(ln) do
                for _, s in ipairs(cell.lanes or {}) do
                    if #(s.edges or {}) > 1 then multi = true end
                end
            end
            if not multi then n = n + 1 end
        end
        return n
    end

    --- Did the split swap fire on this row? Read off the RENDERED row only, so it works
    --- on every merge style (under a separate split Line the swap leaves no spine break,
    --- so `check_spine` cannot see it): the node is in the gutter, the row paid no
    --- handover Line, and the gutter cell of the row's FIRST rendered Line is entered
    --- from above by one of this commit's converging children that its first parent does
    --- not continue (§5 identity: the first parent inherits the id of the child lane it
    --- continues, so "a child lane whose id is not `parent_lanes[1]`'s" is exact).
    local function split_swapped(row)
        local ncol
        for j, cell in ipairs(row.columns or {}) do
            if cell.has_commit then ncol = j end
        end
        if ncol ~= 1 or handover_rows(row) > 0 then return false end
        -- A ROOT continues nothing, so there is no gutter to keep and every arriving child
        -- trivially "is not the continuation" — it must not read as a swap.
        local first = row.parent_lanes[1] and row.parent_lanes[1].id
        if not first then return false end
        local kids = {}
        for _, l in ipairs(row.child_lanes or {}) do kids[l.id] = true end
        local line = (row.above or {})[1] or row.columns
        for _, s in ipairs((line[1] or {}).lanes or {}) do
            if s.connectivity.up and kids[s.id] and s.id ~= first then return true end
        end
        return false
    end

    local function swaps(rows)
        local n = 0
        for _, row in ipairs(rows) do
            if split_swapped(row) then n = n + 1 end
        end
        return n
    end

    -- A fork `f` that three lines of history came out of — the trunk (`main`) plus two
    -- topic branches — where §3.1's ordering puts a TOPIC's last commit (`t2`) directly
    -- above the fork. `t2`'s lane therefore holds the gutter when `f` arrives, and it is
    -- not the lane `f` continues (`main`'s is senior). Same shape as the fork-hub colour
    -- fixture above, which is the shape this swap exists for.
    local FORK = {
        { "tip",   { "main", "topic" } },
        { "main",  { "f" } }, -- the trunk: SENIOR lane, so `f` continues it
        { "topic", { "t1", "t2" } },
        { "t1",    { "f" } },
        { "t2",    { "f" } }, -- junior, and directly above the fork => holds the gutter
        { "f",     { "r" } },
        { "r",     {} },
    }

    it("fires with a split Line: the node takes the gutter and BREAKS NOTHING", function()
        local o = gopts(SPLITLINE, "gutter")
        local rows = build_graph(o, gdag(FORK))
        local f = row_of(rows, "f")
        assert.equals(3, #f.child_lanes) -- main's, t1's and t2's edges converge here
        assert.is_true(split_swapped(f))
        -- The whole point: no eviction row, no claim row — only the split fan.
        assert.equals(0, handover_rows(f))
        assert.equals(1, #f.above)
        -- And the spine is intact, because `fan_in` labels the hub from the commit's own
        -- lane wherever the node landed: the descent into the node, the node and the
        -- continuation below it are one id. Nothing is licensed because nothing broke.
        local errors, licensed = h.check_spine(rows, o)
        assert.equals(0, #errors, table.concat(errors, "\n"))
        assert.equals(0, licensed)
        local ncol
        for j, cell in ipairs(f.columns) do if cell.has_commit then ncol = j end end
        assert.equals(1, ncol)
        local hub
        for _, s in ipairs(f.above[1][ncol].lanes or {}) do
            if s.connectivity.down then hub = s end
        end
        assert.equals(f.parent_lanes[1].id, assert(hub).id, "the hub must be the commit's own lane")
        assert.equals(f.parent_lanes[1].color, hub.color)
    end)

    it("fires with an inline fan-in: the break is LICENSED, priced in the rows it saved", function()
        local o = gopts(INLINE, "gutter")
        local rows = build_graph(o, gdag(FORK))
        local f = row_of(rows, "f")
        assert.is_true(split_swapped(f))
        assert.equals(0, handover_rows(f))
        -- Here the occupant's up-stub IS the node's wire from above, so the node's column
        -- carries the ending topic above and the first parent below.
        local cell
        for _, c in ipairs(f.columns) do if c.has_commit then cell = c end end
        local up, down
        for _, s in ipairs(cell.lanes) do
            if s.connectivity.up and not up then up = s.id end
            if s.connectivity.down and not down then down = s.id end
        end
        assert.is_true(up ~= down, "the node's column must change lane at the node")
        assert.equals(f.parent_lanes[1].id, down, "the spine below the node is intact")
        local errors, licensed, kinds = h.check_spine(rows, o)
        assert.equals(0, #errors, table.concat(errors, "\n"))
        assert.equals(1, licensed)
        assert.equals(1, kinds.split)
        -- The node still reads in its OWN lane's colour with no extra mark: a Column's
        -- colour comes from its DOWN wire (§5), which here is the first parent. So,
        -- unlike the merge swap, there is no `own_lane_up`.
        assert.is_nil(cell.own_lane_up)
        assert.equals(f.parent_lanes[1].id, assert(top_lane(cell.lanes, false, true)).id)
    end)

    -- THE PASS-THROUGH GUARD, and it is the hard floor rather than a nicety: a survivor
    -- draws a through-vertical in the gutter, so a node placed over it would put two
    -- lanes' verticals in one cell — and `place_gutter` would instead fall back
    -- off-gutter, costing a node-in-gutter row (§5.6's whole purpose) to save two Lines.
    -- `s` is a subject row whose lane continues PAST the fork, so it is in the gutter at
    -- `f` while both of `f`'s children sit elsewhere.
    local PASSTHROUGH = {
        { "c1", { "f" } },
        { "c2", { "f" } },
        { "s",  { "z" } }, -- holds the gutter, and is not incident to `f` at all
        { "f",  { "r" } },
        { "z",  { "r" } },
        { "r",  {} },
    }

    it("declines for a PASS-THROUGH occupant: it is evicted and the node stays in the gutter", function()
        for _, ms in ipairs({ SPLITLINE, INLINE }) do
            local o = gopts(ms, "gutter")
            local rows = build_graph(o, gdag(PASSTHROUGH))
            local f = row_of(rows, "f")
            -- precondition: the gutter's occupant is not one of `f`'s converging children
            local kids = {}
            for _, l in ipairs(f.child_lanes) do kids[l.id] = true end
            assert.equals(2, #f.child_lanes)
            local sz = row_of(rows, "s").parent_lanes[1]
            assert.is_nil(kids[sz.id], "precondition: a pass-through holds the gutter")
            assert.is_false(split_swapped(f))
            assert.equals(2, handover_rows(f), "the pass-through is evicted and the column claimed")
            local ncol
            for j, cell in ipairs(f.columns) do if cell.has_commit then ncol = j end end
            assert.equals(1, ncol, "the node must still be in the gutter — the hard floor")
            assert.equals(0, #h.check_spine(rows, o))
        end
    end)

    -- A COMMIT THAT BOTH FORKS AND MERGES (§10.4's both-fans case), satisfying BOTH gates:
    -- `b`'s lane holds the gutter and `f` continues `a`'s (senior), so the split swap is
    -- available; and `k` — a non-first parent — owns the next subject row, comes before
    -- the first parent `t`, and has only `f` as an in-set child, so the merge gate passes.
    local BOTH = {
        { "a", { "f" } },      -- senior child: `f` continues its lane
        { "b", { "f" } },      -- junior child, directly above => holds the gutter
        { "f", { "t", "k" } }, -- merges (t, k) AND forks (a, b)
        { "k", { "t" } },      -- the non-first parent, owning the next subject row
        { "t", { "r" } },
        { "r", {} },
    }

    it("composes with the merge swap when the fan-in has a Line of its own", function()
        -- Both fire: this row pays no handover (the split swap) and the next subject row
        -- pays none either (the merge swap). The node's wire from above is still the
        -- commit's own lane — the hub descent — so it is the MERGE licence that applies,
        -- unchanged, and the node keeps the trunk's colour via `own_lane_up`.
        local o = gopts(SPLITLINE, "gutter")
        local rows = build_graph(o, gdag(BOTH))
        local f = row_of(rows, "f")
        assert.is_true(split_swapped(f))
        assert.equals(0, handover_rows(f))
        assert.equals(0, handover_rows(row_of(rows, "k")))
        local cell
        for _, c in ipairs(f.columns) do if c.has_commit then cell = c end end
        assert.is_true(cell.own_lane_up)
        local errors, licensed, kinds = h.check_spine(rows, o)
        assert.equals(0, #errors, table.concat(errors, "\n"))
        assert.equals(1, licensed)
        assert.equals(1, kinds.merge)
        assert.equals(0, kinds.split)
    end)

    it("yields to the merge swap on an inline fan-in (they cannot share a node cell)", function()
        -- Inline, the two swaps would leave the commit's own lane on NEITHER side of its
        -- own node cell — a foreign child above, a non-first parent below — which no
        -- licence can price and which could not even be coloured from its own lane. The
        -- merge swap wins (same two rows saved, on the next row instead of this one), so
        -- this row pays its handover and the break is the merge's.
        local o = gopts(INLINE, "gutter")
        local rows = build_graph(o, gdag(BOTH))
        local f = row_of(rows, "f")
        assert.is_false(split_swapped(f))
        assert.equals(2, handover_rows(f))
        local cell
        for _, c in ipairs(f.columns) do if c.has_commit then cell = c end end
        assert.is_true(cell.own_lane_up)
        local up
        for _, s in ipairs(cell.lanes) do
            if s.connectivity.up and not up then up = s.id end
        end
        assert.equals(f.parent_lanes[1].id, up, "the wire above is the commit's own lane")
        local errors, _, kinds = h.check_spine(rows, o)
        assert.equals(0, #errors, table.concat(errors, "\n"))
        assert.equals(1, kinds.merge)
    end)

    it("never fires in the FOCUSED projection (§10.7, the shipping default)", function()
        -- §3.1's lineage grouping keeps consecutive subject rows on one lane, and every
        -- other branch contracts to a `◍` head that claims no gutter (§5.6), so the
        -- gutter at a kept fork is the trunk's own and there is nothing to swap. This is
        -- the byte-identity claim in invariant form for the default view.
        for _, ms in ipairs({ SPLITLINE, INLINE }) do
            local o = gopts(ms, "gutter")
            for _, spec in ipairs({ FORK, PASSTHROUGH, BOTH }) do
                assert.equals(0, swaps(build_graph(o, h.focused(gdag(spec)))))
            end
            local total = 0
            for seed = 1, 60 do
                total = total + swaps(build_graph(o, h.focused(h.dag(h.random_dag(4 + (seed % 14), seed)))))
            end
            assert.equals(0, total, "the split swap fired in a focused projection")
        end
    end)

    it("never fires under any other policy (§5.6: only `gutter` constrains a column)", function()
        for _, policy in ipairs({ "compact", "survivors", "linear", "straight" }) do
            for _, style in ipairs(STYLES) do
                local o = gopts(style.ms, policy)
                for _, items in ipairs({ gdag(FORK), h.focused(gdag(FORK)) }) do
                    local rows = build_graph(o, items)
                    -- Without a gutter the node is not pinned to column 1, so the swap has
                    -- no column to keep; asserted through the same rendered predicate.
                    assert.equals(0, swaps(rows),
                        ("%s/%s must not swap at a fork"):format(policy, style.name))
                end
            end
        end
    end)
end)

describe("a freed fan-out column is never the node's own (§5.1/§5.6)", function()
    -- REGRESSION (fix/gutter-freed-own-column). `fan_out` may reuse a column a
    -- terminating child just vacated for an extra merge parent (§5.1 fan-out
    -- placement, reachable under `allow_merge_on_split` or a separate merge Line).
    -- It derived the candidates POSITIONALLY — `commit_incoming[2..n]`, "every
    -- incoming lane but the leftmost" — which stands in for "every incoming column
    -- this row has not claimed" only while the node sits on the LEFTMOST incoming
    -- lane. `place_commit` does exactly that; `place_gutter` puts the node on the
    -- commit's OWN lane (§5, `trunk_entry`), which can be any incoming entry. The
    -- node's column then appeared in the freed list, an extra parent was assigned
    -- it, and the first parent — assigned the same column a moment earlier — was
    -- overwritten in `active`: `columns.layout` errored outright with
    -- "did not carry an outgoing edge forward".
    --
    -- Three things had to coincide, which is why nothing caught it: the `gutter`
    -- policy (`C`), a merge style that populates `freed` at all (`m`), and a
    -- NON-SUBJECT row (a `◍` head or a junction marker — the rows the handover
    -- deliberately skips, so the node's lane is wherever it happens to be). The
    -- third is only reachable on a PROJECTED view, and the layout matrix fed it raw
    -- DAGs, all of whose rows own a subject.
    local build_graph = require("gitloom.graph")._internal.build_graph

    -- The shape, as a named fixture: a junction `f` that is both a fork and a merge,
    -- reached by TWO lanes — a merge's second-parent edge (from `x`, whose mainline
    -- goes elsewhere) and `f`'s own line of history (`y`, whose FIRST parent is `f`).
    -- Row order puts `x` above `y`, so `f`'s own lane is the RIGHTMOST of the two and
    -- the node lands off the leftmost incoming column. Not contrived: §3.1 emits a
    -- merged-in lineage right after its merge, so a junction reached by a foreign
    -- second-parent edge above its own is ordinary.
    local FIXTURE = {
        { "x", { "p", "f" } }, -- a merge; `f` is its SECOND parent
        { "y", { "f" } },      -- `f`'s own line of history
        { "p", { "g" } },
        { "f", { "g", "r" } }, -- merges (x, y) AND forks (g, r) => a kept junction
        { "g", { "r" } },
        { "r", {} },
    }

    -- Every (line, column) where TWO DISTINCT outgoing lanes of this row turn down.
    -- Two parents given one column is the defect, whatever the style draws around
    -- it. Counted per rendered line and by lane identity, because one parent
    -- legitimately turns down at the same column on two lines (the commit Line's
    -- stub into the merge fan, then the fan itself), and a fan's shared ascent is a
    -- BUNDLE of every parent's edge in one segment.
    local function parent_column_clashes(row)
        local out, seen = {}, {}
        for _, l in ipairs(row.parent_lanes or {}) do seen[l] = true end
        for _, ln in ipairs(h.row_lines(row)) do
            for j, col in ipairs(ln.line or {}) do
                local lanes = {}
                for _, s in ipairs(col.lanes or {}) do
                    if s.connectivity.down then
                        for _, e in ipairs(s.edges or {}) do
                            if seen[e] then lanes[e] = true end
                        end
                    end
                end
                local n = 0
                for _ in pairs(lanes) do n = n + 1 end
                if n > 1 then
                    out[#out + 1] = ("%s col %d: %d outgoing lanes turn down"):format(ln.name, j, n)
                end
            end
        end
        return out
    end

    local CASES = {
        { name = "merge-line", ms = { split_on_separate_line = false, merge_on_separate_line = true } },
        { name = "inline+mergesplit", exp = true,
          ms = { split_on_separate_line = false, merge_on_separate_line = false, allow_merge_on_split = true } },
    }

    for _, case in ipairs(CASES) do
        it("lays out a junction whose own lane is not the leftmost [gutter / " .. case.name .. "]", function()
            local opts = policy_opts(case.ms, "gutter")
            local items = h.focused(h.dag(FIXTURE))

            -- The row order must still produce the shape this pins, or the test would
            -- pass vacuously if the projection or the ordering changed.
            local fnode
            for _, it0 in ipairs(items) do
                if it0.commit.hash == "f" then fnode = it0.commit end
            end
            assert.truthy(fnode, "the fixture must project `f` as a kept node")
            assert.is_true(fnode.junction and not fnode.collapsed,
                "`f` must be a kept JUNCTION — a non-subject row is what the bug needs")

            local rows = build_graph(opts, items)
            local frow
            for _, row in ipairs(rows) do
                if row.commit and row.commit.hash == "f" then frow = row end
            end
            assert.truthy(frow)
            assert.equals(2, #frow.child_lanes)
            assert.equals(2, #frow.parent_lanes)

            -- The node is off the leftmost incoming lane (`place_gutter` puts it on
            -- `trunk_entry`, §5) — the precondition the positional `freed` derivation
            -- got wrong.
            local ncol, inset = nil, {}
            for _, l in ipairs(frow.child_lanes) do inset[l] = true end
            for j, col in ipairs(frow.columns) do if col.has_commit then ncol = j end end
            local left_child
            for j = 1, ncol - 1 do
                for _, s in ipairs(frow.columns[j].lanes or {}) do
                    if s.connectivity.up and inset[s.edges and s.edges[1]] then left_child = j end
                end
            end
            assert.truthy(left_child,
                "the fixture must put a converging child LEFT of the node column")

            -- The defect itself: both parents assigned one column.
            assert.same({}, parent_column_clashes(frow))
            -- And the full suite, incl. the spine (§5.6) — a colour handoff is
            -- sanctioned only for `allow_merge_on_split`.
            assert_ok(opts, items, "gutter/" .. case.name .. "/freed-own-column", case.exp)
            assert.equals(0, #h.check_spine(rows, opts))
        end)
    end

    -- The class, over the whole matrix: whatever a placement stage does with the node
    -- column, no extra parent may be given a column the row has already claimed.
    it("never stacks two outgoing lanes in one column (every style x policy, projected)", function()
        local bad = {}
        for _, style in ipairs(STYLES) do
            for _, policy in ipairs(POLICIES) do
                local opts = policy_opts(style.ms, policy)
                for seed = 1, 120 do
                    local items = h.focused(h.dag(h.random_dag(3 + (seed % 12), seed)))
                    local ok, rows = pcall(build_graph, opts, items)
                    if not ok then
                        bad[#bad + 1] = ("%s/%s seed=%d: LAYOUT ERROR %s")
                            :format(style.name, policy, seed, tostring(rows))
                    else
                        for ri, row in ipairs(rows) do
                            for _, e in ipairs(parent_column_clashes(row)) do
                                bad[#bad + 1] = ("%s/%s seed=%d row=%d %s")
                                    :format(style.name, policy, seed, ri, e)
                            end
                        end
                    end
                    if #bad >= 6 then break end
                end
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
        local inline_fan = ((#(row.child_lanes or {}) > 1) and #(row.above or {}) == 0)
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
    -- colour changes mid-column. Repro: random_dag(7, 108). (The glyphs are
    -- unchanged by §5 tier 2 picking the NEWEST lane; only the last two rows' lane
    -- ids moved, 1 -> 5: the newer lane now continues at the merge.)
    local EXPECTED = [[
◉─╮  122
○ │  1.2
│ │ ◉─╮  1.2.344
│ │ │ │ ◉  1.2.3.4.5
○─│─│─╯ │  1464344.5
○─│─┴───╯  536335555
◎─╯  566]]

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
            for _, ln0 in ipairs(h.row_lines(row)) do
                local line = ln0.line
                do
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
                    for _, ln0 in ipairs(h.row_lines(row)) do
                        local line = ln0.line
                        do
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
            for _, ln in ipairs(h.row_lines(row)) do
                for _, t in ipairs(ln.line) do
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

    -- Horizontal sharing (§5.1). One cell, three columns; each `edge` is a distinct
    -- table so the checker can tell the runs apart, and `child_lanes`/`parent_lanes`
    -- say which fan each belongs to.
    local function hrow(a, b)
        local function seg(e, c) return { id = e.id, connectivity = c, edges = { e } } end
        local function cell(...) return { lanes = { ... }, connectivity = {} } end
        return {
            child_lanes = { a }, parent_lanes = { b },
            columns = {
                cell(seg(a, { right = true, down = true }), seg(b, { right = true, down = true })),
                cell(seg(a, { left = true, right = true }), seg(b, { left = true, right = true })),
                cell(seg(a, { left = true, up = true }), seg(b, { left = true, up = true })),
            },
        }
    end

    it("horizontal sharing flags a fan-in and a fan-out sharing a run", function()
        -- `a` is a converging child (enters at col 3, exits down at col 1); `b` is a
        -- diverging parent travelling the other way. Same cells, opposite directions —
        -- one glyph and one colour for two wires, which is the defect.
        local a = { id = 1 }                                     -- in: 3 -> 1
        local b = { id = 2 }                                     -- out: 1 -> 3
        local row = hrow(a, b)
        row.columns[1].lanes[2].connectivity = { right = true, up = true }
        row.columns[3].lanes[2].connectivity = { left = true, down = true }
        local errors = h.check_horizontals({ row })
        assert(has(errors, "MIXED-DIRECTION"), table.concat(errors, "\n"))
    end)

    it("horizontal sharing accepts two arms of the SAME fan", function()
        -- Both runs are converging children of this commit — a fan bus, which §5.1
        -- explicitly permits to share cells.
        local a, b = { id = 1 }, { id = 2 }
        local row = hrow(a, b)
        row.child_lanes, row.parent_lanes = { a, b }, {}
        assert.equals(0, #h.check_horizontals({ row }))
    end)

    -- THE SPINE, AND ITS ONE LICENCE (§5, §5.6). `check_spine` no longer just counts
    -- breaks: the §5.6 gutter parent swap breaks the spine on purpose, so the checker
    -- must accept exactly the break that PAYS for itself and still flag every other.
    -- These feed it hand-built rows that isolate each licence clause, so a checker that
    -- quietly became "gutter is exempt" fails here.
    --
    -- The shape: a merge M at row 1 in the gutter, its first parent lane (id 1) arriving
    -- from above and a non-first parent lane (id 2) leaving below — then the next
    -- subject row N, whose node is in the gutter, entered by lane 2. That is the swap
    -- having saved N's handover.
    local function spine_rows(o)
        o = o or {}
        local p1, p2 = { id = 1 }, { id = 2 }
        local function node(col, upid, downid, ncols)
            local lanes = {}
            if upid then lanes[#lanes + 1] = { id = upid, connectivity = { up = true } } end
            if downid then lanes[#lanes + 1] = { id = downid, connectivity = { down = true } } end
            local cols = {}
            for j = 1, (ncols or col) do cols[j] = { lanes = {}, connectivity = {} } end
            cols[col] = { lanes = lanes, connectivity = {}, has_commit = true }
            return cols
        end
        local merge = {
            commit = { hash = "M" }, parent_lanes = { p1, p2 }, child_lanes = {},
            columns = node(o.break_col or 1, 1, o.below_id or 2, 2),
        }
        local nxt = {
            commit = { hash = "N", collapsed = o.next_collapsed },
            parent_lanes = {}, child_lanes = { p2 },
            columns = node(o.next_col or 1, o.next_up or 2, nil, 2),
        }
        return { merge, nxt }
    end

    it("spine licenses the swap that saves a handover", function()
        local errors, licensed = h.check_spine(spine_rows(), opts)
        assert.equals(0, #errors, table.concat(errors, "\n"))
        assert.equals(1, licensed)
    end)

    it("spine flags a break outside the gutter column", function()
        -- Same break, column 2: no policy constrains that column, so nothing licenses it.
        local errors = h.check_spine(spine_rows({ break_col = 2 }), opts)
        assert(has(errors, "not in the gutter column"), table.concat(errors, "\n"))
    end)

    it("spine flags a swap that SAVED NOTHING", function()
        -- The gutter was handed to lane 2, but the next subject row is entered by lane 3
        -- — lane 2 was evicted after all, so the row paid its handover anyway and the
        -- break bought nothing. This is the case clause 3 of the gate exists to prevent.
        local errors = h.check_spine(spine_rows({ next_up = 3 }), opts)
        assert(has(errors, "SAVED NOTHING"), table.concat(errors, "\n"))
    end)

    it("spine flags a break whose next subject row is not in the gutter", function()
        local errors = h.check_spine(spine_rows({ next_col = 2 }), opts)
        assert(has(errors, "does not put its node in the gutter"), table.concat(errors, "\n"))
    end)

    it("spine flags a break where the wire below is not a parent lane of the merge", function()
        -- id 9 is on no `parent_lanes` entry, so the break is not a parent swap at all.
        local errors = h.check_spine(spine_rows({ below_id = 9, next_up = 9 }), opts)
        assert(has(errors, "not a non-first parent lane"), table.concat(errors, "\n"))
    end)

    it("spine looks past a marker row to the next SUBJECT row", function()
        -- A collapsed head between the two owns no subject row (§5.6), so it is not
        -- where the gutter changes hands and cannot supply the licence. With the
        -- marker's node in the gutter on a foreign lane, the real next subject row
        -- still decides — here it is absent, so the break is unlicensed.
        local rows = spine_rows({ next_collapsed = true })
        local errors = h.check_spine(rows, opts)
        assert(has(errors, "no subject row follows"), table.concat(errors, "\n"))
    end)

    -- THE SECOND LICENCE (§5.6 gutter SPLIT swap). At a fork the swap touches the other
    -- side of the node cell: the wire BELOW stays the first parent and the wire ABOVE is a
    -- converging child the first parent does not continue. Its earning is on its OWN row —
    -- it declined to hand the gutter back, so the row must show no handover Line. One test
    -- per clause, plus a fire that saved nothing.
    --
    -- The shape: a fork F at row 1 in the gutter, entered from above by child lane 3 (not
    -- the continuation — the first parent carries lane 1's id, §5) and leaving on the first
    -- parent's lane 1, with no eviction/claim row above it.
    local function split_rows(o)
        o = o or {}
        local c_cont, c_foreign = { id = 1 }, { id = 3 }
        local p1, p2 = { id = 1 }, { id = 2 }
        local cols = { { lanes = {}, connectivity = {} }, { lanes = {}, connectivity = {} } }
        cols[o.break_col or 1] = {
            lanes = {
                { id = o.above_id or 3, connectivity = { up = true } },
                { id = o.below_id or 1, connectivity = { down = true } },
            },
            connectivity = {}, has_commit = true,
        }
        local row = {
            commit = { hash = "F" },
            child_lanes = { c_cont, c_foreign },
            parent_lanes = o.below_id == 2 and { p1, p2 } or { p1 },
            columns = cols,
        }
        if o.handover then
            -- One virtual Line with only single-edge segments: an eviction/claim row.
            row.above = { { { lanes = { { id = 3, connectivity = { up = true, right = true }, edges = { c_foreign } } } },
                { lanes = { { id = 3, connectivity = { left = true, down = true }, edges = { c_foreign } } } } } }
        end
        return { row }
    end

    it("spine licenses a split swap that saved its own handover", function()
        local errors, licensed, kinds = h.check_spine(split_rows(), opts)
        assert.equals(0, #errors, table.concat(errors, "\n"))
        assert.equals(1, licensed)
        assert.equals(1, kinds.split)
        assert.equals(0, kinds.merge)
    end)

    it("spine flags a split swap that SAVED NOTHING (a handover Line anyway)", function()
        -- The gutter was kept for the converging child AND the row still emitted an
        -- eviction/claim row, so the break bought nothing. Impossible by construction in
        -- the layout, which is exactly what this pins.
        local errors = h.check_spine(split_rows({ handover = true }), opts)
        assert(has(errors, "SAVED NOTHING: this row paid a handover Line"), table.concat(errors, "\n"))
    end)

    it("spine flags a break whose wire above is not a converging child", function()
        -- id 9 is on no `child_lanes` entry, so the node is simply mis-placed: neither
        -- swap's shape.
        local errors = h.check_spine(split_rows({ above_id = 9 }), opts)
        assert(has(errors, "neither swap"), table.concat(errors, "\n"))
    end)

    it("spine flags a cell where BOTH swaps fired (own lane on neither side)", function()
        -- A foreign converging child above AND a non-first parent below: the commit's own
        -- Lane is on neither side of its own node cell, so no licence can price it. This is
        -- the composition the layout forbids on an inline fan-in.
        local errors = h.check_spine(split_rows({ below_id = 2 }), opts)
        assert(has(errors, "the wire above is not the first parent's lane"), table.concat(errors, "\n"))
    end)
end)
