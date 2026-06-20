--- Phase 1 (lane layout) invariants, checked on columns.layout output directly
--- (no build_graph), so the new engine can be TDD'd before it is wired in.
local columns = require("gitloom.columns")
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

for style, ms in pairs(STYLES) do
    describe("columns.layout [" .. style .. "]", function()
        local opts = h.big_opts(ms)
        for name, rows_spec in pairs(FIXTURES) do
            it("is well-formed for " .. name, function()
                local rows = columns.layout(opts, h.dag(rows_spec))
                local errs = check(opts, rows)
                if #errs > 0 then
                    print("\n=== " .. style .. "/" .. name .. " ===\n" .. render(opts, rows)
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

    it("does not stack a branch head under a root", function()
        -- Two independent chains: a1->a2(root), then b1(head)->b2(root). Without
        -- the break, b1 reuses a2's column and the four nodes read as one lane.
        local rows = columns.layout(h.big_opts(), h.dag({
            { "a1", { "a2" } }, { "a2", {} },
            { "b1", { "b2" } }, { "b2", {} },
        }))
        assert.is_true(commit_col(rows, "a2") ~= commit_col(rows, "b1"))
    end)

    it("alternates columns for a run of stacked roots", function()
        -- The block lasts one row, so consecutive single-commit roots zigzag
        -- between two columns rather than marching ever rightward.
        local rows = columns.layout(h.big_opts(), h.dag({
            { "a", {} }, { "b", {} }, { "c", {} }, { "d", {} },
        }))
        local a, b, c = commit_col(rows, "a"), commit_col(rows, "b"), commit_col(rows, "c")
        assert.is_true(a ~= b) -- b offset off a
        assert.equals(a, c)    -- a's column free again by c
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
end)
