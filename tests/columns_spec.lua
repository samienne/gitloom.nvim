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

    it("keeps a staircase of merges bounded, not growing per merge", function()
        local opts = h.big_opts({ split_on_separate_line = false, merge_on_separate_line = false })
        -- Width must not scale with the number of merges: a short and a long
        -- staircase render the same bounded width (3: trunk + the alternating gap).
        assert.equals(3, max_width(columns.layout(opts, h.dag(staircase(3)))))
        assert.equals(3, max_width(columns.layout(opts, h.dag(staircase(12)))))
    end)

    it("stays well-formed and connected across the staircase", function()
        local opts = h.big_opts({ split_on_separate_line = false, merge_on_separate_line = false })
        local errs = check(opts, columns.layout(opts, h.dag(staircase(8))))
        assert.equals(0, #errs, table.concat(errs, "\n"))
    end)

    it("reuses a terminated child's column on a separate merge line", function()
        -- merge_on_separate_line (split inline, the "merge on its own line" style):
        -- a merge's fan-out is a row *below* the commit, where the just-merged
        -- child has already ended — so the outgoing parent reuses that freed column
        -- instead of leaving an empty-column gap. The gap made the width oscillate
        -- (2 vs 3) and bounced a right-aligned mirror graph. Width must stay 2.
        local opts = h.big_opts({ split_on_separate_line = false, merge_on_separate_line = true })
        assert.equals(2, max_width(columns.layout(opts, h.dag(staircase(3)))))
        assert.equals(2, max_width(columns.layout(opts, h.dag(staircase(12)))))
        local errs = check(opts, columns.layout(opts, h.dag(staircase(8))))
        assert.equals(0, #errs, table.concat(errs, "\n"))
    end)

    it("compacts an expanded inline branch next to the trunk (no persistent gap)", function()
        -- Inline mode, two-commit branches: each branch is born one column out (a
        -- fork-merge can't reuse the just-freed inline cell, the gated handoff),
        -- but its body must then compact next to the trunk via a single jog rather
        -- than stranding an empty column its whole length. Every branch commit ends
        -- up at column 2 (adjacent to the trunk at column 1), node and body alike.
        local opts = h.big_opts({ split_on_separate_line = false, merge_on_separate_line = false })
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
