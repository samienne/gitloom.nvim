--- The **streaming** Phase-1 sweep (spec §3.1): `graph.extend_columns` continues the
--- layout batch by batch instead of redoing the whole order every time.
---
--- Two things need proving, and the second is what gives the first its teeth:
---
---  1. **Parity** — the streamed sweep is byte-identical to the one-shot layout, over
---     every merge style x every layout policy, on fixtures, a fuzz sweep, and a large
---     real-world topology. Compared cell-for-cell: every rendered Line's connectivity,
---     lane id, colour, node flag and per-segment endpoints, plus the row's
---     parent/child lanes.
---  2. **It really is incremental** — the session is carried across batches and each
---     batch sweeps only its own rows. Without this a "parity" test passes trivially by
---     rebuilding from scratch, which is exactly the behaviour being replaced.
---
--- And the boundary: a policy whose `prepass` reads rows BELOW the current one
--- (`gutter`) cannot be resumed, so it must fall back to a full rebuild. Remove that
--- guard and the parity block fails on `gutter` — the prefix property genuinely does
--- not hold there (its parent-swap gate needs the next subject row).

local h = require("tests.graph_helpers")
local graph = require("gitloom.graph")
local columns = require("gitloom.graph.columns")
local fix = require("tests.large_topo")

local STYLES = {
    { name = "split-line", s = { merge_on_separate_line = false, split_on_separate_line = true } },
    { name = "merge-line", s = { merge_on_separate_line = true, split_on_separate_line = false } },
    { name = "mergesplit", s = { merge_on_separate_line = true, split_on_separate_line = true } },
    { name = "inline",     s = { merge_on_separate_line = false, split_on_separate_line = false } },
    { name = "inline-mos", s = { allow_merge_on_split = true } },
}
local POLICIES = { "compact", "survivors", "linear", "straight", "gutter" }

--- A rendered Line's full cell content, as a comparable string.
local function line_sig(line)
    if not line then return "-" end
    local out = {}
    for j, col in ipairs(line) do
        local c = col.connectivity or {}
        local segs = {}
        for _, sg in ipairs(col.lanes or {}) do
            local sc = sg.connectivity or {}
            segs[#segs + 1] = ("%s:%s:%s%s%s%s:%s>%s"):format(tostring(sg.id), tostring(sg.color),
                sc.up and "u" or "", sc.down and "d" or "", sc.left and "l" or "", sc.right and "r" or "",
                sg.begin and tostring(sg.begin.hash) or "-",
                sg.parent and tostring(sg.parent.hash) or "-")
        end
        out[#out + 1] = ("%d[%s%s%s%s|%s|%s|%s|%s]{%s}"):format(j,
            c.up and "u" or "", c.down and "d" or "", c.left and "l" or "", c.right and "r" or "",
            tostring(col.id), tostring(col.color), col.has_commit and "N" or "",
            col.own_lane_up and "^" or "", table.concat(segs, ","))
    end
    return table.concat(out, " ")
end

--- Every Line of one row, plus the lanes the reachability walk reads.
local function row_sig(r)
    local parts = {}
    for _, a in ipairs(r.above or {}) do parts[#parts + 1] = "A" .. line_sig(a) end
    parts[#parts + 1] = "C" .. line_sig(r.columns)
    if r.merge then parts[#parts + 1] = "M" .. line_sig(r.merge) end
    local pl, cl = {}, {}
    for _, l in ipairs(r.parent_lanes or {}) do pl[#pl + 1] = tostring(l.id) end
    for _, l in ipairs(r.child_lanes or {}) do cl[#cl + 1] = tostring(l.id) end
    parts[#parts + 1] = "P" .. table.concat(pl, ",") .. "/K" .. table.concat(cl, ",")
    return table.concat(parts, "\n")
end

local function nlines(r) return 1 + #(r.above or {}) + (r.merge and 1 or 0) end

--- Feed `rows` (a dag() spec) through `extend_columns` in batches of `batch`,
--- exactly as window.lua's `on_batch` does: a growing `order` array, appended to,
--- with the session carried across calls.
---@return table[] order, table? stream, integer sweeps  -- sweeps = extend_columns calls
local function stream(opts, rows, batch)
    local items = h.dag(rows)
    local order = {}
    local st, sweeps = nil, 0
    local i = 1
    while i <= #items do
        local stop = math.min(i + batch - 1, #items)
        for k = i, stop do order[#order + 1] = items[k] end
        st = graph.extend_columns(opts, order, i, st)
        sweeps = sweeps + 1
        i = stop + 1
    end
    return order, st, sweeps
end

--- Compare a streamed order against the one-shot layout of the same DAG.
---@return integer differing, integer lines
local function compare(opts, rows, batch)
    local one = columns.layout(opts, h.dag(rows))
    local order = stream(opts, rows, batch)
    local bad, lines = 0, 0
    for i = 1, #one do
        lines = lines + nlines(one[i])
        if row_sig(one[i]) ~= row_sig(order[i]) then bad = bad + 1 end
    end
    return bad, lines
end

local FIXTURES = {
    linear = { { "a", { "b" } }, { "b", { "c" } }, { "c", { "d" } }, { "d", {} } },
    fork = {
        { "a", { "c" } }, { "b", { "c" } }, { "c", { "d" } }, { "d", {} },
    },
    merge = {
        { "m", { "f", "g" } }, { "f", { "b" } }, { "g", { "b" } }, { "b", { "r" } }, { "r", {} },
    },
    diamonds = {
        { "h", { "m1" } }, { "m1", { "a", "b" } }, { "a", { "m2" } }, { "b", { "m2" } },
        { "m2", { "c", "d" } }, { "c", { "e" } }, { "d", { "e" } }, { "e", {} },
    },
}

describe("streaming Phase 1 — extend_columns (§3.1)", function()
    it("is byte-identical to the one-shot layout on fixtures, every style x policy", function()
        local lines, bad = 0, 0
        for _, pol in ipairs(POLICIES) do
            for _, st in ipairs(STYLES) do
                local o = h.big_opts(st.s)
                o.layout_policy = pol
                for name, rows in pairs(FIXTURES) do
                    for _, batch in ipairs({ 1, 2, 3 }) do
                        local d, n = compare(o, rows, batch)
                        lines = lines + n
                        bad = bad + d
                        assert.equals(0, d, ("%s/%s/%s batch=%d"):format(pol, st.name, name, batch))
                    end
                end
            end
        end
        assert.equals(0, bad)
        assert.is_true(lines > 1000) -- the corpus is not vacuous
    end)

    it("is byte-identical over a fuzz sweep, every style x policy", function()
        local lines, bad = 0, 0
        for _, pol in ipairs(POLICIES) do
            for _, st in ipairs(STYLES) do
                local o = h.big_opts(st.s)
                o.layout_policy = pol
                for seed = 1, 20 do
                    local rows = h.random_dag(24, seed * 977)
                    local d, n = compare(o, rows, 5)
                    lines = lines + n
                    bad = bad + d
                    assert.equals(0, d, ("%s/%s seed=%d"):format(pol, st.name, seed))
                end
            end
        end
        assert.equals(0, bad)
        assert.is_true(lines > 5000)
    end)

    it("is byte-identical on a large real-world topology, every style x policy", function()
        local lines, bad = 0, 0
        for _, pol in ipairs(POLICIES) do
            for _, st in ipairs(STYLES) do
                local o = h.big_opts(st.s)
                o.layout_policy = pol
                local d, n = compare(o, fix.dag, 64)
                lines = lines + n
                bad = bad + d
                assert.equals(0, d, ("%s/%s large_topo"):format(pol, st.name))
            end
        end
        assert.equals(0, bad)
        assert.is_true(lines > 10000)
    end)

    it("carries ONE session across batches and sweeps each row once", function()
        local o = h.big_opts()
        o.layout_policy = "compact"
        local rows = h.random_dag(40, 12345)
        local items = h.dag(rows)
        local order, seen = {}, {}
        local st = nil
        for i = 1, #items, 8 do
            local stop = math.min(i + 7, #items)
            for k = i, stop do order[#order + 1] = items[k] end
            local prev = st and st.session
            st = graph.extend_columns(o, order, i, st)
            if prev then
                -- the same live sweep, not a fresh one (a rebuild would mint a new session)
                assert.is_true(rawequal(prev, st.session))
            end
            seen[#seen + 1] = st.session.n
        end
        -- the session's row count tracks the order exactly: every row swept once
        assert.equals(#items, st.session.n)
        assert.equals(#items, #st.session.rows)
        assert.equals(#items, st.n)
        -- and the counts grew monotonically in batch-sized steps
        for k = 2, #seen do assert.is_true(seen[k] > seen[k - 1]) end
    end)

    it("mints a fresh sweep when the order is not a pure append", function()
        local o = h.big_opts()
        o.layout_policy = "compact"
        local items = h.dag(h.random_dag(20, 42))
        local order = {}
        for k = 1, 10 do order[k] = items[k] end
        local st = graph.extend_columns(o, order, 1, nil)
        local first = st.session
        -- a start_pos that does not continue where the sweep stopped
        for k = 11, 20 do order[k] = items[k] end
        st = graph.extend_columns(o, order, 5, st)
        assert.is_false(rawequal(first, st.session))
        assert.equals(#order, st.session.n)
    end)

    it("mints a fresh sweep when the layout options change", function()
        local o = h.big_opts()
        o.layout_policy = "compact"
        local items = h.dag(h.random_dag(20, 7))
        local order = {}
        for k = 1, 10 do order[k] = items[k] end
        local st = graph.extend_columns(o, order, 1, nil)
        local first = st.session
        o.layout_policy = "straight"
        for k = 11, 20 do order[k] = items[k] end
        st = graph.extend_columns(o, order, 11, st)
        assert.is_false(rawequal(first, st.session))
    end)

    it("refuses to resume a look-ahead policy and rebuilds in full", function()
        local o = h.big_opts()
        o.layout_policy = "gutter"
        assert.is_true(columns.session(o).lookahead)
        local items = h.dag(h.random_dag(20, 99))
        local order = {}
        local st = nil
        for i = 1, #items, 5 do
            for k = i, math.min(i + 4, #items) do order[#order + 1] = items[k] end
            st = graph.extend_columns(o, order, i, st)
            -- no session is kept: the sweep cannot be continued, so each batch
            -- rebuilds (which is what keeps the `gutter` output correct)
            assert.is_nil(st.session)
        end
        o.layout_policy = "compact"
        assert.is_false(columns.session(o).lookahead)
    end)
end)

describe("columns.session (§3.1)", function()
    it("extended once equals columns.layout", function()
        local o = h.big_opts()
        local rows = h.random_dag(30, 555)
        local a = columns.layout(o, h.dag(rows))
        local b = columns.session(o).extend(h.dag(rows))
        assert.equals(#a, #b)
        for i = 1, #a do assert.equals(row_sig(a[i]), row_sig(b[i])) end
    end)

    it("calls the yield hook while sweeping a long list and gives identical output", function()
        local o = h.big_opts()
        local rows = h.random_dag(400, 31337)
        local plain = columns.layout(o, h.dag(rows))
        local n = 0
        local chunked = columns.layout(o, h.dag(rows), nil, function() n = n + 1 end)
        assert.is_true(n > 0)
        assert.equals(#plain, #chunked)
        for i = 1, #plain do assert.equals(row_sig(plain[i]), row_sig(chunked[i])) end
    end)
end)
