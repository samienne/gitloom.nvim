--- Phase 1 (lane layout) invariants, checked on columns.layout output directly
--- (no build_graph), so the new engine can be TDD'd before it is wired in.
local columns = require("gitloom.graph.columns")
local graph = require("gitloom.graph")
local h = require("tests.graph_helpers")

local SIDES = { "up", "down", "left", "right" }
local function nsides(c)
    local n = 0
    for _, k in ipairs(SIDES) do if c[k] then n = n + 1 end end
    return n
end

-- The Phase 1 well-formedness + continuity invariants, returned as error strings.
local function check(opts, rows)
    local errs = {}
    local function err(m) errs[#errs + 1] = m end

    for ri, row in ipairs(rows) do
        for _, line in ipairs({ row.split or {}, row.columns, row.merge or {} }) do
        for ti, t in ipairs(line) do
            local segs = t.lanes or {}
            -- union of segments == cell connectivity
            local u = {}
            for _, s in ipairs(segs) do
                for _, k in ipairs(SIDES) do if s.connectivity[k] then u[k] = true end end
            end
            for _, k in ipairs(SIDES) do
                if (t.connectivity[k] and true or false) ~= (u[k] and true or false) then
                    err(("r%d c%d: union != connectivity at %s"):format(ri, ti, k))
                end
            end
            -- per-column limits: <=1 vertical, <=1 turn (<=2 with merge_on_split)
            local verticals, turns = 0, 0
            for _, s in ipairs(segs) do
                local c = s.connectivity
                if c.up and c.down then verticals = verticals + 1 end
                if (c.left or c.right) and (c.up or c.down) then turns = turns + 1 end
                if nsides(c) > 2 then err(("r%d c%d: segment >2 sides"):format(ri, ti)) end
                if nsides(c) < 2 and not (t.has_commit or #segs > 1) then
                    err(("r%d c%d: 1-sided non-endpoint"):format(ri, ti))
                end
                if c.down and not s.parent then err(("r%d c%d: down without parent"):format(ri, ti)) end
            end
            if verticals > 1 then err(("r%d c%d: %d vertical segments"):format(ri, ti, verticals)) end
            local turn_cap = opts.merge_style.allow_merge_on_split and 2 or 1
            if turns > turn_cap then err(("r%d c%d: %d turns (cap %d)"):format(ri, ti, turns, turn_cap)) end
        end
        end
    end

    -- vertical continuity across every rendered line (split, commit, merge): a
    -- cell's up-lane id must equal the down-lane id directly above it.
    local lines = {}
    for _, row in ipairs(rows) do
        if row.split then lines[#lines + 1] = row.split end
        lines[#lines + 1] = row.columns
        if row.merge then lines[#lines + 1] = row.merge end
    end
    local function up_id(x) for _, s in ipairs(x.lanes or {}) do if s.connectivity.up then return s.id end end end
    local function down_id(x) for _, s in ipairs(x.lanes or {}) do if s.connectivity.down then return s.id end end end
    for li = 1, #lines - 1 do
        local upper, lower = lines[li], lines[li + 1]
        for i, t in ipairs(lower) do
            if t.connectivity.up and upper[i] and upper[i].connectivity.down then
                if up_id(t) ~= down_id(upper[i]) then
                    errs[#errs + 1] = ("line %d col %d: up id %s != above down id %s")
                        :format(li + 1, i, tostring(up_id(t)), tostring(down_id(upper[i])))
                end
            end
        end
    end

    -- Root column break: a root ends its lane, so the line directly below must
    -- not reuse the root's column with a vertical wire or a node (a horizontal
    -- crossing is fine). Otherwise an independent history stacks under the root
    -- and reads as one continuous lane.
    local flat = {} -- { line = GraphColumn[], root_col = int|nil }
    for _, row in ipairs(rows) do
        if row.split then flat[#flat + 1] = { line = row.split } end
        local ccol
        for j, t in ipairs(row.columns) do if t.has_commit then ccol = j end end
        local is_root = row.commit and #(row.commit.parents or {}) == 0
        flat[#flat + 1] = { line = row.columns, root_col = is_root and ccol or nil }
        if row.merge then flat[#flat + 1] = { line = row.merge } end
    end
    for fi = 1, #flat - 1 do
        local rc = flat[fi].root_col
        local below = rc and flat[fi + 1].line[rc]
        if below and (below.has_commit or below.connectivity.up or below.connectivity.down) then
            err(("root col %d reused by a node/vertical on the line below"):format(rc))
        end
    end

    return errs
end

-- Render every line of every row (split above, commit, merge below).
local function render(opts, rows)
    local gtc = graph._internal.get_column_chars
    local out = {}
    for _, row in ipairs(rows) do
        for _, line in ipairs({ row.split or false, row.columns, row.merge or false }) do
            if line then out[#out + 1] = (gtc(opts, line, false).text or ""):gsub("%s+$", "") end
        end
    end
    return table.concat(out, "\n")
end

local FIXTURES = {
    linear  = { { "c1", { "c2" } }, { "c2", { "c3" } }, { "c3", {} } },
    diamond = { { "m", { "a", "b" } }, { "a", { "base" } }, { "b", { "base" } }, { "base", {} } },
    octopus = { { "c1", { "c2", "c3", "c4" } }, { "c2", { "c5" } }, { "c3", { "c5" } }, { "c4", { "c5" } }, { "c5", {} } },
}

local STYLES = {
    inline     = { split_on_separate_line = false, merge_on_separate_line = false },
    ["split"]  = { split_on_separate_line = true, merge_on_separate_line = false },
    ["merge"]  = { split_on_separate_line = false, merge_on_separate_line = true },
    both       = { split_on_separate_line = true, merge_on_separate_line = true },
    mergesplit = { split_on_separate_line = false, merge_on_separate_line = false, allow_merge_on_split = true },
}

-- Layout policies (spec §5.6). Phase 1's per-cell well-formedness, continuity and
-- colouring are all UNIVERSAL invariants (§5.1), so the whole style sweep runs
-- under every policy.
local POLICIES = { "compact", "survivors", "linear", "straight", "gutter" }
-- The policies that run the linear-commit slide — the one §5.6 policy-specific
-- behaviour, so assertions about a *commit* moving belong to these two only.
local SLIDING = { "compact", "linear" }

local function policy_opts(ms, policy)
    local o = h.big_opts(ms)
    o.layout_policy = policy
    return o
end

for style, ms in pairs(STYLES) do
    for _, policy in ipairs(POLICIES) do
        describe("columns.layout [" .. style .. " / " .. policy .. "]", function()
            local opts = policy_opts(ms, policy)
            for name, rows_spec in pairs(FIXTURES) do
                it("is well-formed for " .. name, function()
                    local rows = columns.layout(opts, h.dag(rows_spec))
                    local errs = check(opts, rows)
                    if #errs > 0 then
                        print("\n=== " .. style .. "/" .. policy .. "/" .. name .. " ===\n" .. render(opts, rows)
                            .. "\n--- errors ---\n" .. table.concat(errs, "\n"))
                    end
                    assert.equals(0, #errs)
                end)
            end

            it("is well-formed across random DAGs", function()
                local failures = {}
                for seed = 1, 60 do
                    local n = 3 + (seed % 10)
                    local rows = columns.layout(opts, h.dag(h.random_dag(n, seed)))
                    local errs = check(opts, rows)
                    if #errs > 0 then
                        failures[#failures + 1] = ("seed=%d n=%d:\n%s\n%s")
                            :format(seed, n, render(opts, rows), table.concat(errs, "\n"))
                        if #failures >= 3 then break end
                    end
                end
                if #failures > 0 then
                    assert(false, "\n=== fuzz failures ===\n" .. table.concat(failures, "\n\n"))
                end
            end)
        end)
    end
end

describe("columns.layout dumps", function()
    it("renders fixtures for eyeballing", function()
        for style, ms in pairs(STYLES) do
            local opts = h.big_opts(ms)
            for name, rows_spec in pairs(FIXTURES) do
                local rows = columns.layout(opts, h.dag(rows_spec))
                print("\n=== " .. style .. "/" .. name .. " ===\n" .. render(opts, rows))
            end
        end
        assert.is_true(true)
    end)
end)

describe("columns.layout lane identity (spec §5)", function()
    -- Identity is chosen from the DAG and the row order — never from a column. The
    -- regression: `spawn_lanes` used to inherit the LEFTMOST incoming lane, a
    -- positional proxy for "the trunk" that holds only while the trunk happens to
    -- sit leftmost. Where a topic lane landed left of the trunk, the merge and the
    -- whole spine below it were drawn as the topic.
    --
    --   m1 -> m2
    --   m2 -> m3, t1      (merge: FIRST parent m3 = master spine)
    --   t1 -> t2
    --   t2 -> m3          (the topic forked from m3)
    --   m3 -> m4
    --
    -- Both m2 and t2 have m3 as their first parent, so the tiebreak decides: the
    -- SENIOR chain (smallest id — master's, born at the tip) must continue.
    local MERGED = {
        { "m1", { "m2" } },
        { "m2", { "m3", "t1" } },
        { "t1", { "t2" } },
        { "t2", { "m3" } },
        { "m3", { "m4" } },
        { "m4", {} },
    }

    --- id/colour of each commit's first-parent lane.
    local function spine(rows)
        local out = {}
        for _, row in ipairs(rows) do
            local pl = row.parent_lanes and row.parent_lanes[1]
            if pl then out[row.commit.hash] = pl end
        end
        return out
    end

    local function ordered(spec)
        local items = h.dag(spec)
        local commits = {}
        for _, it in ipairs(items) do commits[#commits + 1] = it.commit end
        local ord = {}
        for _, c in ipairs(require("gitloom.git.order").order_commits(commits)) do
            ord[#ord + 1] = { type = "commit", commit = c }
        end
        return ord
    end

    for _, policy in ipairs(POLICIES) do
        it("the trunk survives a merge whose lineage is expanded [" .. policy .. "]", function()
            local opts = policy_opts(nil, policy)
            local sp = spine(columns.layout(opts, ordered(MERGED)))
            assert.is_not_nil(sp.m1)
            assert.equals(sp.m1.id, sp.m2.id, "m1->m2 and m2->m3 must be one lane")
            assert.equals(sp.m2.id, sp.m3.id, "the spine must survive the merge at m3")
            assert.equals(sp.m1.color, sp.m3.color, "and keep one colour")
            assert.is_true(sp.t1.id ~= sp.m3.id, "the topic must not become the spine")
        end)
    end

    it("a merged-in branch tip carries its own lane on", function()
        -- `base` is reached only as a SECOND parent, from two different merges. Each
        -- of those edges IS the merged-in branch, and `base` is its tip continuing
        -- downward — so the continuation keeps one of them (the senior) rather than
        -- being born afresh. Minting here would recolour every merged-in branch tip.
        for _, policy in ipairs(POLICIES) do
            local opts = policy_opts(nil, policy)
            local rows = columns.layout(opts, ordered({
                { "a", { "a2", "base" } },
                { "a2", { "tail" } },
                { "b", { "b2", "base" } },
                { "b2", { "tail" } },
                { "base", { "tail" } },
                { "tail", {} },
            }))
            local sp = spine(rows)
            local incoming = {}
            for _, row in ipairs(rows) do
                if row.commit.hash == "base" then
                    for _, l in ipairs(row.child_lanes or {}) do incoming[l.id] = true end
                end
            end
            assert.is_true(next(incoming) ~= nil, "base must have incoming lanes")
            assert.is_true(incoming[sp.base.id] == true,
                policy .. ": base must continue one of its incoming lanes")
        end
    end)

    it("the tiebreak is SENIORITY, not arrival order", function()
        -- Both `m2` and `t2` have `m3` as their first parent; the senior chain (the
        -- smaller id — master's, born at the tip) must win under every policy, which
        -- is what makes identity independent of where the lanes were placed.
        for _, policy in ipairs(POLICIES) do
            local sp = spine(columns.layout(policy_opts(nil, policy), ordered(MERGED)))
            assert.is_true(sp.m3.id < sp.t1.id,
                policy .. ": the senior lane must be the one that continues")
        end
    end)
end)

describe("columns.layout track-id reuse", function()
    local function distinct_ids(rows)
        local ids = {}
        for _, row in ipairs(rows) do
            for _, line in ipairs({ row.split or false, row.columns, row.merge or false }) do
                if line then
                    for _, t in ipairs(line) do if t.id then ids[t.id] = true end end
                end
            end
        end
        local n = 0
        for _ in pairs(ids) do n = n + 1 end
        return n
    end

    it("keeps one id along a straight chain", function()
        -- A linear history is a single continuous lane: one track id (colour).
        local rows = columns.layout(h.big_opts(),
            h.dag({ { "a", { "b" } }, { "b", { "c" } }, { "c", {} } }))
        assert.equals(1, distinct_ids(rows))
    end)

    it("mints a new id only at branch heads and merges", function()
        -- diamond m->{a,b}->base: the first-parent mainline (m->a->base) keeps the
        -- tip's id; only the second parent (m->b->base) is a new lane. Two ids.
        local rows = columns.layout(h.big_opts(),
            h.dag({ { "m", { "a", "b" } }, { "a", { "base" } }, { "b", { "base" } }, { "base", {} } }))
        assert.equals(2, distinct_ids(rows))
    end)
end)

describe("columns.layout root column break", function()
    local function commit_col(rows, hash)
        for _, row in ipairs(rows) do
            if row.commit and row.commit.hash == hash then
                for j, t in ipairs(row.columns) do if t.has_commit then return j end end
            end
        end
    end

    -- UNIVERSAL (§5.1): the break lives in the sweep's own `blocked` bookkeeping —
    -- read by tip placement and fan-out, never produced by a compaction move — so
    -- it must survive a policy that moves nothing. Asserted across the matrix.
    for _, policy in ipairs(POLICIES) do
        it("does not stack a branch head under a root [" .. policy .. "]", function()
            -- Two independent chains: a1->a2(root), then b1(head)->b2(root). Without
            -- the break, b1 reuses a2's column and the four nodes read as one lane.
            local rows = columns.layout(policy_opts(nil, policy), h.dag({
                { "a1", { "a2" } }, { "a2", {} },
                { "b1", { "b2" } }, { "b2", {} },
            }))
            assert.is_true(commit_col(rows, "a2") ~= commit_col(rows, "b1"))
        end)

        it("alternates columns for a run of stacked roots [" .. policy .. "]", function()
            -- The block lasts one row, so consecutive single-commit roots zigzag
            -- between two columns rather than marching ever rightward.
            local rows = columns.layout(policy_opts(nil, policy), h.dag({
                { "a", {} }, { "b", {} }, { "c", {} }, { "d", {} },
            }))
            local a, b, c = commit_col(rows, "a"), commit_col(rows, "b"), commit_col(rows, "c")
            assert.is_true(a ~= b) -- b offset off a
            assert.equals(a, c)    -- a's column free again by c
        end)
    end
end)

describe("columns.layout compact column reuse (spec §5.1)", function()
    -- A staircase of sequential feature-branch merges off one trunk: each mK is a
    -- merge whose first parent is the next trunk commit and whose second parent is
    -- a one-commit branch fK that forks from that same next trunk commit. The merge
    -- fans must reuse interior gaps earlier branches vacated, so the graph stays a
    -- bounded width instead of growing one column wider per merge (the regression).
    local function staircase(n)
        local rows = {}
        for k = 1, n do
            rows[#rows + 1] = { "m" .. k, { "m" .. (k + 1), "f" .. k } }
            rows[#rows + 1] = { "f" .. k, { "m" .. (k + 1) } }
        end
        rows[#rows + 1] = { "m" .. (n + 1), {} }
        return rows
    end

    local function max_width(rows)
        local w = 0
        for _, row in ipairs(rows) do
            for _, line in ipairs({ row.split or {}, row.columns, row.merge or {} }) do
                if #line > w then w = #line end
            end
        end
        return w
    end

    -- Column reuse is the **fan-out placement** rule (§5.1) — a separate axis from
    -- compaction: it decides where a newly diverging lane is PUT, not whether an
    -- existing one moves, and it lives in `fan_out`, which every policy chain runs.
    -- So the bounded widths must be identical under every policy; running the
    -- matrix here is what keeps a future `interval` placement policy (§5.6) from
    -- reading as a §5.1 violation.
    for _, policy in ipairs(POLICIES) do
        it("keeps a staircase of merges bounded, not growing per merge [" .. policy .. "]", function()
            local opts = policy_opts({ split_on_separate_line = false, merge_on_separate_line = false }, policy)
            -- Width must not scale with the number of merges: a short and a long
            -- staircase render the same bounded width (3: trunk + the alternating gap).
            assert.equals(3, max_width(columns.layout(opts, h.dag(staircase(3)))))
            assert.equals(3, max_width(columns.layout(opts, h.dag(staircase(12)))))
        end)

        it("stays well-formed and connected across the staircase [" .. policy .. "]", function()
            local opts = policy_opts({ split_on_separate_line = false, merge_on_separate_line = false }, policy)
            local errs = check(opts, columns.layout(opts, h.dag(staircase(8))))
            assert.equals(0, #errs, table.concat(errs, "\n"))
        end)

        it("reuses a terminated child's column on a separate merge line [" .. policy .. "]", function()
            -- merge_on_separate_line (split inline, the "merge on its own line" style):
            -- a merge's fan-out is a row *below* the commit, where the just-merged
            -- child has already ended — so the outgoing parent reuses that freed column
            -- instead of leaving an empty-column gap. The gap made the width oscillate
            -- (2 vs 3) and bounced a right-aligned mirror graph. Width must stay STABLE.
            --
            -- `gutter` (§5.6) is one wider on this pathological staircase and stable
            -- there: the gutter may be entered ONLY by the lane owning the next subject
            -- row, so a fan-out may not reclaim it even when a terminating child just
            -- freed it. The claim being made — a short and a long staircase render the
            -- same width, i.e. it does not grow per merge — is unchanged; only the
            -- constant differs, so it is pinned per policy rather than loosened.
            local expect = policy == "gutter" and 3 or 2
            local opts = policy_opts({ split_on_separate_line = false, merge_on_separate_line = true }, policy)
            assert.equals(expect, max_width(columns.layout(opts, h.dag(staircase(3)))))
            assert.equals(expect, max_width(columns.layout(opts, h.dag(staircase(12)))))
            local errs = check(opts, columns.layout(opts, h.dag(staircase(8))))
            assert.equals(0, #errs, table.concat(errs, "\n"))
        end)
    end

    -- POLICY-SPECIFIC (§5.6): this asserts the product of the `slide` stage — a
    -- linear commit MOVING — which is the one genuine existence claim about
    -- compaction. It is therefore pinned to the policies that run the slide, not
    -- run across the matrix. Under `survivors` / `straight` the branch legitimately
    -- stays in the column it was born in; that is the policy, not a regression.
    for _, policy in ipairs(SLIDING) do
        it("compacts an expanded inline branch next to the trunk [" .. policy .. "]", function()
            -- Inline mode, two-commit branches: each branch is born one column out (a
            -- fork-merge can't reuse the just-freed inline cell, the gated handoff),
            -- but its body must then compact next to the trunk via a single jog rather
            -- than stranding an empty column its whole length. Every branch commit ends
            -- up at column 2 (adjacent to the trunk at column 1), node and body alike.
            local opts = policy_opts({ split_on_separate_line = false, merge_on_separate_line = false }, policy)
            local rows = {}
            for k = 1, 4 do
                rows[#rows + 1] = { "m" .. k, { "m" .. (k + 1), "g" .. k .. "b" } }
                rows[#rows + 1] = { "g" .. k .. "b", { "g" .. k .. "a" } }
                rows[#rows + 1] = { "g" .. k .. "a", { "m" .. (k + 1) } }
            end
            rows[#rows + 1] = { "m5", {} }
            local laid = columns.layout(opts, h.dag(rows))
            local function col(hash)
                for _, row in ipairs(laid) do
                    if row.commit and row.commit.hash == hash then
                        for j, t in ipairs(row.columns) do if t.has_commit then return j end end
                    end
                end
            end
            -- g1 is born at column 2 (no preceding terminator); g2..g4 are born at
            -- column 3 then jog to 2. All branch commits sit adjacent to the trunk.
            for k = 1, 4 do
                assert.equals(2, col("g" .. k .. "b"))
                assert.equals(2, col("g" .. k .. "a"))
            end
            assert.equals(0, #check(opts, laid), "ill-formed")
        end)
    end
end)

describe("columns.layout gutter policy (§5.6)", function()
    -- The gutter rule is "the node that owns its row's SUBJECT", so the interesting
    -- cases are the node kinds that do NOT own one. A collapsed head and a kept
    -- junction are markers (§10.4) — ref labels, no subject, and several may share a
    -- packed line — so they keep their lane column; a working-tree virtual commit
    -- (§4.2) carries a synthesized subject, so it is a gutter node. Getting this
    -- wrong is invisible on plain fixtures (every fuzz commit owns a subject), which
    -- is why it is pinned here.
    local function build()
        local items = h.dag({
            { "wt", { "c1" } }, { "c1", { "c2" } }, { "topic", { "c3" } },
            { "c2", { "c3", "c5" } }, { "c5", { "c4" } }, { "c3", { "c4" } }, { "c4", {} },
        })
        local by = {}
        for _, it in ipairs(items) do by[it.commit.hash] = it.commit end
        by.wt.virtual = "staged"                                  -- has a subject
        by.topic.collapsed = true                                 -- marker
        by.topic.count = 7
        by.topic.refs = { { name = "topic", kind = "local" } }
        by.c2.junction = true                                     -- node-less junction
        by.c2.refs = {}
        by.c3.junction = true                                     -- LABELLED junction
        by.c3.refs = { { name = "release", kind = "local" } }
        return items
    end

    local function node_col(rows, hash)
        for _, row in ipairs(rows) do
            if row.commit and row.commit.hash == hash then
                for j, t in ipairs(row.columns) do if t.has_commit then return j end end
            end
        end
    end

    it("puts subject-owning nodes in the gutter and markers on their lanes", function()
        for _, ms in ipairs({
            { split_on_separate_line = true, merge_on_separate_line = false },
            { split_on_separate_line = false, merge_on_separate_line = false },
        }) do
            local opts = policy_opts(ms, "gutter")
            opts.junction_markers = true
            local rows = columns.layout(opts, build())
            for _, hash in ipairs({ "wt", "c1", "c5", "c4" }) do
                assert.equals(1, node_col(rows, hash), hash .. " should be in the gutter")
            end
            -- A marker sits on its OWN lane. That lane may itself be the gutter —
            -- a junction on the trunk is on the trunk — so the claim is "not
            -- relocated", i.e. its node column is its incoming lane's column.
            for _, hash in ipairs({ "topic", "c2", "c3" }) do
                local col, inc = node_col(rows, hash), nil
                for _, row in ipairs(rows) do
                    if row.commit.hash == hash and row.child_lanes and row.child_lanes[1] then
                        for j, t in ipairs(row.columns) do
                            for _, sg in ipairs(t.lanes or {}) do
                                if sg.connectivity.up and sg.edges and sg.edges[1] == row.child_lanes[1] then
                                    inc = j
                                end
                            end
                        end
                    end
                end
                if inc then
                    assert.equals(inc, col, hash .. " is a marker: it keeps its own lane")
                end
            end
            assert.equals(0, #check(opts, rows), "ill-formed")
        end
    end)

    it("keeps the gutter for THIS row's own chain", function()
        -- The rule that makes the whole policy work (§5.6): the gutter carries the
        -- chain of the row being read. A commit's first parent continues there and
        -- no other parent may enter — so a merge keeps its own identity under its
        -- node instead of handing the column to the lineage it merged in. When the
        -- next subject row belongs to a different lane, the occupant vacates on its
        -- own virtual row (`evict_gutter`) and the fan-in turns the new one in.
        --
        -- Asserted as the observable consequence — every subject row's node IS in
        -- the gutter — with two documented exceptions: a root occupying it on the
        -- previous row blocks it for one Line (§5.1 root column break), and a row
        -- whose own split fan already owns the above-slot cannot also carry an
        -- eviction row, so it degrades to its own lane.
        for _, ms in ipairs({
            { split_on_separate_line = true,  merge_on_separate_line = false },
            { split_on_separate_line = false, merge_on_separate_line = true },
            { split_on_separate_line = true,  merge_on_separate_line = true },
            { split_on_separate_line = false, merge_on_separate_line = false },
        }) do
            local opts = policy_opts(ms, "gutter")
            for seed = 1, 80 do
                local rows = columns.layout(opts, h.dag(h.random_dag(3 + (seed % 12), seed)))
                for ri, row in ipairs(rows) do
                    local cc
                    for j, t in ipairs(row.columns) do if t.has_commit then cc = j end end
                    if cc ~= 1 then
                        local prev = rows[ri - 1]
                        local root_blocked = prev and prev.commit
                            and #(prev.commit.parents or {}) == 0
                            and prev.columns[1] and prev.columns[1].has_commit
                        assert(root_blocked or row.split ~= nil,
                            ("seed=%d row=%d: subject node at column %d, with neither a root block nor a split fan")
                            :format(seed, ri, cc))
                    end
                end
            end
        end
    end)

    it("holds the gutter across marker rows", function()
        -- The rule keys on SUBJECT rows, so a marker between two commits of one lane
        -- must not disturb the gutter — otherwise a collapsed head sitting on the
        -- trunk would cost two handovers and two connectors for nothing.
        local items = h.dag({
            { "t1", { "t2" } },
            { "mark", { "t2" } }, -- a collapsed head hanging off the same parent
            { "t2", { "t3" } },
            { "t3", {} },
        })
        for _, it2 in ipairs(items) do
            if it2.commit.hash == "mark" then
                it2.commit.collapsed = true
                it2.commit.count = 4
                it2.commit.refs = { { name = "mark", kind = "local" } }
            end
        end
        local opts = policy_opts(nil, "gutter")
        local rows = columns.layout(opts, items)
        local col = {}
        for _, row in ipairs(rows) do
            for j, t in ipairs(row.columns) do
                if t.has_commit then col[t.commit.hash] = j end
            end
        end
        assert.equals(1, col.t1)
        assert.equals(1, col.t2)  -- the marker in between changed nothing
        assert.equals(1, col.t3)
        assert.is_true(col.mark > 1)
        -- ...and the trunk drew no horizontal at all on its own rows
        for _, row in ipairs(rows) do
            if row.commit and row.commit.hash == "t2" then
                for _, t in ipairs(row.columns) do
                    assert.is_nil(t.connectivity.left or t.connectivity.right or nil)
                end
            end
        end
        assert.equals(0, #check(opts, rows))
    end)

    it("moves a pass-through lane only on an eviction row, and alone", function()
        -- `gutter` keeps `straight`'s no-move rule (§5.6) on every ORDINARY row: a
        -- lane not incident to this row's commit is a pure vertical there, so the
        -- only horizontals on a commit Line are that commit's own fans.
        --
        -- The one exception is the **eviction** row — the swap-out that frees the
        -- gutter for the next run. Exactly one lane moves on it, which is the whole
        -- reason it gets a row of its own: a lane leaving (left-to-right) must never
        -- share a row with a fan-in arriving (right-to-left).
        --
        -- Stated on SURVIVORS rather than as "a Lane occupies one column for life",
        -- which is not the right property: with a separate merge Line the first
        -- parent legitimately drops out of the node on the commit Line and fans to
        -- its column on the Line below — the hub spanning two Lines, not a jog.
        for _, ms in ipairs({
            { split_on_separate_line = true,  merge_on_separate_line = true },
            { split_on_separate_line = true,  merge_on_separate_line = false },
            { split_on_separate_line = false, merge_on_separate_line = true },
            { split_on_separate_line = false, merge_on_separate_line = false },
        }) do
            local opts = policy_opts(ms, "gutter")
            for seed = 1, 80 do
                local rows = columns.layout(opts, h.dag(h.random_dag(4 + (seed % 11), seed)))
                for ri, row in ipairs(rows) do
                    local C = row.commit
                    for _, pair in ipairs({ { "split", row.split }, { "columns", row.columns },
                        { "merge", row.merge } }) do
                        local line = pair[2]
                        if line then
                            -- every lane drawing a horizontal on this line, and
                            -- whether it is a pass-through (not incident to C)
                            local horiz, survivors = {}, 0
                            for _, t in ipairs(line) do
                                for _, sg in ipairs(t.lanes or {}) do
                                    if sg.connectivity.left or sg.connectivity.right then
                                        local e = #(sg.edges or {}) == 1 and sg.edges[1] or nil
                                        local key = e or sg
                                        if horiz[key] == nil then
                                            horiz[key] = true
                                            if e and e.begin ~= C and e.parent ~= C then
                                                survivors = survivors + 1
                                            end
                                        end
                                    end
                                end
                            end
                            local n = 0
                            for _ in pairs(horiz) do n = n + 1 end
                            if survivors > 0 then
                                -- This is the EVICTION row: a pass-through moving is
                                -- allowed here and nowhere else, it must be the only
                                -- lane moving, and it must sit above the commit.
                                assert(pair[1] == "split",
                                    ("seed=%d row=%d: a pass-through moved on the %s line")
                                    :format(seed, ri, pair[1]))
                                assert(survivors == 1 and n == 1,
                                    ("seed=%d row=%d: eviction row moved %d lanes (%d pass-through), expected exactly 1")
                                    :format(seed, ri, n, survivors))
                            end
                        end
                    end
                end
            end
        end
    end)
end)

describe("columns.layout free-list colouring", function()
    local function all_lines(rows)
        local lines = {}
        for _, row in ipairs(rows) do
            if row.split then lines[#lines + 1] = row.split end
            lines[#lines + 1] = row.columns
            if row.merge then lines[#lines + 1] = row.merge end
        end
        return lines
    end

    -- A lane keeps one colour for its whole life: every Segment edge carrying a
    -- given lane id resolves to a single, non-nil colour slot.
    it("assigns each lane a single stable colour", function()
        for style, ms in pairs(STYLES) do
            local opts = h.big_opts(ms)
            for seed = 1, 40 do
                local rows = columns.layout(opts, h.dag(h.random_dag(3 + (seed % 10), seed)))
                local id_color = {}
                for _, line in ipairs(all_lines(rows)) do
                    for _, t in ipairs(line) do
                        for _, s in ipairs(t.lanes or {}) do
                            for _, e in ipairs(s.edges or {}) do
                                assert.is_not_nil(e.color, style .. " seed " .. seed .. ": lane without colour")
                                if id_color[e.id] then
                                    assert.equals(id_color[e.id], e.color)
                                else
                                    id_color[e.id] = e.color
                                end
                            end
                        end
                    end
                end
            end
        end
    end)

    -- Lanes alive at the same time never share a colour: on any line, two
    -- distinct straight-through verticals (`│`) must differ in colour. big_opts
    -- has 64 slots, so the palette is never exhausted into a duplicate here.
    it("gives concurrent lanes distinct colours", function()
        for style, ms in pairs(STYLES) do
            local opts = h.big_opts(ms)
            for seed = 1, 40 do
                local rows = columns.layout(opts, h.dag(h.random_dag(3 + (seed % 10), seed)))
                for li, line in ipairs(all_lines(rows)) do
                    local seen = {}
                    for ci, t in ipairs(line) do
                        for _, s in ipairs(t.lanes or {}) do
                            local c = s.connectivity
                            if c.up and c.down and #(s.edges or {}) == 1 then
                                assert.is_nil(seen[s.color],
                                    ("%s seed %d line %d col %d: colour %s reused by a concurrent vertical")
                                        :format(style, seed, li, ci, tostring(s.color)))
                                seen[s.color] = true
                            end
                        end
                    end
                end
            end
        end
    end)

    it("keeps one colour along a straight first-parent chain", function()
        local rows = columns.layout(h.big_opts(),
            h.dag({ { "a", { "b" } }, { "b", { "c" } }, { "c", {} } }))
        local colors = {}
        for _, line in ipairs(all_lines(rows)) do
            for _, t in ipairs(line) do if t.color then colors[t.color] = true end end
        end
        local n = 0
        for _ in pairs(colors) do n = n + 1 end
        assert.equals(1, n)
    end)

    -- A colour is returned to the free list when its lane ends, so it is
    -- available again later. With a 4-slot palette, six short-lived side branches
    -- (born and ended one row later) are far more lanes than colours; only
    -- because their slots are recycled can the trailing 4-way fan still draw four
    -- distinct colours. (Without recycling the list would be drained into
    -- duplicates before the fan.)
    it("recycles colours of ended lanes so a later fan stays distinct", function()
        local o = h.opts()
        o.palette.tracks = { "T1", "T2", "T3", "T4" }
        local rows = columns.layout(o, h.dag({
            { "t0", { "t1", "r0" } }, { "r0", {} },
            { "t1", { "t2", "r1" } }, { "r1", {} },
            { "t2", { "t3", "r2" } }, { "r2", {} },
            { "t3", { "t4", "r3" } }, { "r3", {} },
            { "t4", { "t5", "r4" } }, { "r4", {} },
            { "t5", { "t6", "r5" } }, { "r5", {} },
            { "t6", { "f1", "f2", "f3", "f4" } },
            { "f1", {} }, { "f2", {} }, { "f3", {} }, { "f4", {} },
        }))
        local fork
        for _, row in ipairs(rows) do
            if row.commit and row.commit.hash == "t6" then fork = row end
        end
        assert.is_not_nil(fork)
        local seen, n = {}, 0
        for _, lane in ipairs(fork.parent_lanes) do
            assert.is_not_nil(lane.color)
            assert.is_true(lane.color >= 1 and lane.color <= 4)
            if not seen[lane.color] then
                seen[lane.color] = true; n = n + 1
            end
        end
        assert.equals(4, n)
    end)

    -- After a brief exhaustion forces a slot to be shared, that slot must not be
    -- returned to the free list until its *last* holder ends. Otherwise a lane
    -- born later (when colours are plentiful again) is handed a colour still in
    -- use by a live lane — a collision that should not exist (the recycling
    -- leak). Here a 3-slot palette and a 4-way octopus exhaust the pool once;
    -- later only the main line and a fresh branch are alive, so their colours
    -- must differ.
    it("does not hand a live colour to a later lane after exhaustion", function()
        local o = h.opts()
        o.palette.tracks = { "P1", "P2", "P3" }
        local rows = columns.layout(o, h.dag({
            { "m0", { "m1", "b1", "c1", "d1" } }, -- octopus: 3 slots + 1 duplicate
            { "d1", { "d2" } }, { "d2", {} },     -- d ends, returns its (shared) slot
            { "b1", { "b2" } }, { "b2", {} },
            { "c1", { "c2" } }, { "c2", {} },
            { "m1", { "m2" } },
            { "m2", { "m3", "n1" } },             -- main continues (m3); n1 is new
            { "n1", { "n2" } }, { "n2", {} },
            { "m3", {} },
        }))
        local line
        for _, row in ipairs(rows) do
            if row.commit and row.commit.hash == "n1" then line = row.columns end
        end
        assert.is_not_nil(line)
        local id_by_color, ids = {}, {}
        for _, t in ipairs(line) do
            for _, s in ipairs(t.lanes or {}) do
                if s.id and s.color then
                    assert.is_true(id_by_color[s.color] == nil or id_by_color[s.color] == s.id,
                        "two live lanes share colour " .. tostring(s.color) .. " on n1's line")
                    id_by_color[s.color] = s.id
                    ids[s.id] = true
                end
            end
        end
        local n = 0
        for _ in pairs(ids) do n = n + 1 end
        assert.is_true(n >= 2) -- the main line and n1 are both present (non-vacuous)
    end)
end)

describe("columns.layout colour generation (spec §5.5)", function()
    -- Generation mints palette slots beyond #tracks; Phase 2 renders those as
    -- OKLCH colours. Here we only check the slot *policy* (Phase 1).
    local function gen_opts(ntracks, buffer)
        local o = h.opts()
        o.palette.tracks = {}
        for i = 1, ntracks do o.palette.tracks[i] = "P" .. i end
        o.palette.generate = true
        o.palette.buffer = buffer or 3
        return o
    end

    local function lane_color(rows, hash, parent_index)
        for _, row in ipairs(rows) do
            if row.commit and row.commit.hash == hash then
                local l = row.parent_lanes[parent_index or 1]
                return l and l.color
            end
        end
    end

    it("uses only curated colours below capacity", function()
        -- A 3-way octopus exactly fills a 3-slot palette: no generation (no slot
        -- exceeds #tracks).
        local o = gen_opts(3)
        local rows = columns.layout(o, h.dag({
            { "o", { "a", "b", "c" } },
            { "a", {} }, { "b", {} }, { "c", {} },
        }))
        for _, row in ipairs(rows) do
            for _, line in ipairs({ row.split or false, row.columns, row.merge or false }) do
                if line then
                    for _, t in ipairs(line) do
                        if t.color then assert.is_true(t.color <= 3, "generated below capacity") end
                    end
                end
            end
        end
    end)

    it("mints an overflow colour past capacity", function()
        -- A 4-way octopus exceeds the 3-slot palette: the 4th lane is generated.
        local o = gen_opts(3)
        local rows = columns.layout(o, h.dag({
            { "o", { "a", "b", "c", "d" } },
            { "a", {} }, { "b", {} }, { "c", {} }, { "d", {} },
        }))
        local maxc = 0
        for _, lane in ipairs(rows[1].parent_lanes) do maxc = math.max(maxc, lane.color) end
        assert.is_true(maxc > 3, "expected a generated slot > #tracks")
    end)

    it("keeps breathing room: a freed colour is not reused by the next lane", function()
        -- 2 curated slots, buffer 3. x1's lane (slot 2) ends at x2; the next head
        -- h2 is born while h1's lane still holds slot 1 — with the cooldown it
        -- must NOT immediately reuse slot 2, so it generates instead.
        local o = gen_opts(2, 3)
        local rows = columns.layout(o, h.dag({
            { "h1", { "p" } },
            { "x1", { "x2" } }, { "x2", {} },
            { "h2", { "p" } },
            { "p", {} },
        }))
        local x1c, h2c = lane_color(rows, "x1"), lane_color(rows, "h2")
        assert.is_not_nil(h2c)
        assert.is_true(h2c ~= x1c) -- did not immediately reuse the freed colour
        assert.is_true(h2c > 2)    -- generated an overflow colour instead
    end)

    it("retires surplus generated colours instead of recycling them", function()
        -- Two independent 4-way octopuses over a 2-slot palette. The first's
        -- generated slots are retired as its branches end, so the second mints
        -- fresh slots rather than reusing the first's.
        local o = gen_opts(2, 0)
        local rows = columns.layout(o, h.dag({
            { "o1", { "a", "b", "c", "d" } },
            { "a", {} }, { "b", {} }, { "c", {} }, { "d", {} },
            { "o2", { "e", "f", "g", "h" } },
            { "e", {} }, { "f", {} }, { "g", {} }, { "h", {} },
        }))
        local function gen_set(hash)
            local set = {}
            for _, row in ipairs(rows) do
                if row.commit and row.commit.hash == hash then
                    for _, lane in ipairs(row.parent_lanes) do
                        if lane.color > 2 then set[lane.color] = true end
                    end
                end
            end
            return set
        end
        local g1, g2 = gen_set("o1"), gen_set("o2")
        assert.is_true(next(g1) ~= nil and next(g2) ~= nil) -- both generated
        for c in pairs(g2) do
            assert.is_nil(g1[c], "o2 reused a retired generated colour " .. tostring(c))
        end
    end)

    it("no generation without the flag (curated + sharing unchanged)", function()
        -- generate off (the default in tests): a 4-way octopus over 2 slots shares
        -- curated colours rather than generating any.
        local o = h.opts()
        o.palette.tracks = { "P1", "P2" }
        local rows = columns.layout(o, h.dag({
            { "o", { "a", "b", "c", "d" } },
            { "a", {} }, { "b", {} }, { "c", {} }, { "d", {} },
        }))
        for _, lane in ipairs(rows[1].parent_lanes) do
            assert.is_true(lane.color <= 2, "no generation when the flag is off")
        end
    end)
end)

describe("columns.layout boundary seed (§6.2)", function()
    local opts = h.big_opts()

    -- A context pane's seam: a lane crossing in from above in a fixed column and
    -- colour, terminating at a commit inside the pane. `a` is a merge so a fresh
    -- lane is born under the seed (to exercise colour reservation).
    local function laid()
        local items = h.dag({
            { "a", { "b", "d" } },
            { "b", { "c" } },
            { "d", { "c" } },
            { "c", {} },
            { "p", {} }, -- the seed lane's parent (keeps its column alive to the end)
        })
        local p
        for _, it in ipairs(items) do if it.commit.hash == "p" then p = it.commit end end
        local seed = { [3] = { id = 99, color = 1, begin = items[1].commit, parent = p, highlighted = false } }
        return columns.layout(opts, items, seed)
    end

    it("a seeded lane enters from above in its column and stays continuous", function()
        local rows = laid()
        local cell = rows[1].columns[3]
        assert.is_not_nil(cell)
        assert.is_true(cell.connectivity.up)   -- crosses in from above the pane
        assert.is_true(cell.connectivity.down) -- continues downward
        assert.equals(99, cell.id)
        assert.equals(1, cell.color)
        assert.same({}, check(opts, rows)) -- well-formed + continuous
    end)

    it("reserves the seed colour so a pane-born lane never reuses it", function()
        local rows = laid()
        -- colour slot 1 belongs only to the seed lane (id 99); the merge-born
        -- lanes must have taken other slots even though 1 is normally first out.
        for _, row in ipairs(rows) do
            for _, line in ipairs({ row.split or {}, row.columns, row.merge or {} }) do
                for _, t in ipairs(line) do
                    for _, s in ipairs(t.lanes or {}) do
                        if s.color == 1 then assert.equals(99, s.id) end
                    end
                end
            end
        end
    end)
end)
