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
