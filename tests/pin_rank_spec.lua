--- Pin priority in lane identity (spec §5 "Lane identity", §5.5, §6.2, §3.1):
--- `opts.pin_rank` (ref id → rank, 1 = highest) adds tier 0 to the continuation
--- choice and the **birth at a pinned tip** rule, and must leave the layout
--- byte-identical when it is nil or empty.
local h = require("tests.graph_helpers")
local graph = require("gitloom.graph")
local columns = require("gitloom.graph.columns")
local pane = require("gitloom.graph.pane")
local fix = require("tests.large_topo")

local STYLES = {
    { name = "split-line", s = { merge_on_separate_line = false, split_on_separate_line = true } },
    { name = "merge-line", s = { merge_on_separate_line = true, split_on_separate_line = false } },
    { name = "mergesplit", s = { merge_on_separate_line = true, split_on_separate_line = true } },
    { name = "inline",     s = { merge_on_separate_line = false, split_on_separate_line = false } },
}
local POLICIES = { "compact", "survivors", "linear", "straight", "gutter" }

local function opts(ms, policy, rank)
    local o = h.big_opts(ms)
    o.layout_policy = policy
    o.pin_rank = rank
    return o
end

--- Hang a `local` ref named `name` on the commit `hash` of `items`.
local function ref(items, hash, name, kind)
    for _, it in ipairs(items) do
        if it.commit.hash == hash then
            it.commit.refs = it.commit.refs or {}
            table.insert(it.commit.refs, { name = name, kind = kind or "local", commit = it.commit })
            return it.commit
        end
    end
    error("no commit " .. hash)
end

--- Pin a deterministic scattering of a fuzz DAG's commits (tips AND interior ones,
--- so births happen), with ranks 1..4 — repeated ranks included, so ties are hit.
local function scatter_pins(items, seed)
    local rank = {}
    for i, it in ipairs(items) do
        if (i * 7 + seed) % 5 == 0 then
            local id = "p" .. i
            local c = it.commit
            c.refs = c.refs or {}
            table.insert(c.refs, { name = id, kind = "local" })
            rank[id] = ((i + seed) % 4) + 1
        end
    end
    return rank
end

local function corpus(n)
    local out = {}
    for seed = 1, n do
        local items = h.dag(h.random_dag(6 + (seed % 17), seed))
        if seed % 2 == 0 then items = h.focused(items) end
        out[#out + 1] = { seed = seed, items = items }
    end
    return out
end

local function row_of(rows, hash)
    for _, r in ipairs(rows) do
        if r.commit and r.commit.hash == hash then return r end
    end
end

--- Glyphs only (colour stripped) of one row's Lines — what "geometry" means here.
local function geometry(o, r)
    local gtc = graph._internal.get_column_chars
    local out = {}
    for _, ln in ipairs(h.row_lines(r)) do
        out[#out + 1] = (gtc(o, ln.line).text:gsub("%s+$", ""))
    end
    return table.concat(out, "|")
end

describe("pin rank (§5)", function()
    describe("commit_rank", function()
        it("is the best rank among the commit's refs, keyed by repo.refs id", function()
            local c = { refs = {
                { name = "feature", kind = "local" },
                { name = "origin/dev", kind = "remote" },
                { name = "dev", kind = "local" },
            } }
            assert.equals(2, columns.commit_rank(c, { dev = 2, ["origin/dev"] = 3 }))
            assert.is_nil(columns.commit_rank(c, { main = 1 }))
            assert.is_nil(columns.commit_rank(c, nil))
            assert.is_nil(columns.commit_rank({}, { dev = 1 }))
            -- the head ref is keyed `HEAD`, whatever its name field says
            local d = { refs = { { name = "HEAD", kind = "head" } } }
            assert.equals(1, columns.commit_rank(d, { HEAD = 1 }))
            assert.equals(columns.commit_rank, graph.commit_rank)
        end)
    end)

    it("nil, empty and non-matching pin_rank lay out byte-identically", function()
        local bad = {}
        local sets = corpus(40)
        sets[#sets + 1] = { seed = 0, items = h.dag(fix.dag) }
        sets[#sets + 1] = { seed = -1, items = h.focused(h.dag(fix.dag)) }
        for _, set in ipairs(sets) do
            for _, st in ipairs(STYLES) do
                for _, pol in ipairs(POLICIES) do
                    local base = columns.layout(opts(st.s, pol, nil), set.items)
                    for _, pr in ipairs({ {}, { nonexistent = 1 } }) do
                        local other = columns.layout(opts(st.s, pol, pr), set.items)
                        for i = 1, #base do
                            if h.row_sig(base[i]) ~= h.row_sig(other[i]) and #bad < 3 then
                                bad[#bad + 1] = ("seed=%d %s/%s row %d"):format(set.seed, st.name, pol, i)
                            end
                        end
                    end
                end
            end
        end
        assert.equals(0, #bad, table.concat(bad, "\n"))
    end)

    describe("birth at a pinned tip", function()
        -- The reported case: `feature1` branched off `dev`'s newest commit. Unpinned,
        -- feature1's lane runs down all of dev's history; with dev pinned, dev's lane
        -- is born at dev's tip and the history below is dev's colour.
        local function fixture()
            local items = h.dag({ { "f1", { "d" } }, { "d", { "c" } }, { "c", { "b" } }, { "b", {} } })
            ref(items, "f1", "feature1")
            ref(items, "d", "dev")
            return items
        end

        it("ends the incoming lane and births the pinned one (id and colour)", function()
            for _, pol in ipairs(POLICIES) do
                local plain = columns.layout(opts(STYLES[1].s, pol, nil), fixture())
                assert.equals(plain[1].parent_lanes[1].id, row_of(plain, "c").parent_lanes[1].id)

                local rows = columns.layout(opts(STYLES[1].s, pol, { dev = 1 }), fixture())
                local f1, d, c = rows[1].parent_lanes[1], row_of(rows, "d").parent_lanes[1],
                    row_of(rows, "c").parent_lanes[1]
                assert.is_true(f1.id ~= d.id, pol)
                assert.is_true(f1.color ~= d.color, pol)
                assert.equals(1, d.rank, pol)
                assert.is_nil(f1.rank, pol)
                -- dev's history is dev's lane
                assert.equals(d.id, c.id, pol)
                assert.equals(d.color, c.color, pol)
                assert.equals(1, c.rank, pol)
            end
        end)

        it("under gutter the birth pays no handover and is a licensed spine break", function()
            for _, st in ipairs(STYLES) do
                local o = opts(st.s, "gutter", { dev = 1 })
                local rows = columns.layout(o, fixture())
                assert.equals(0, #(row_of(rows, "d").above or {}), st.name)
                local errors, _, kinds = h.check_spine(rows, o)
                assert.equals(0, #errors, table.concat(errors, "\n"))
                assert.equals(1, kinds.birth, st.name)
            end
        end)

        it("a merged pinned tip adopts the merge edge's lane and colour", function()
            -- master merged dev; dev still points at the merged commit.
            local function items()
                local it = h.dag({ { "m", { "a", "d" } }, { "a", { "b" } }, { "d", { "b" } }, { "b", {} } })
                ref(it, "m", "master")
                ref(it, "d", "dev")
                return it
            end
            for _, pol in ipairs(POLICIES) do
                local rows = columns.layout(opts(STYLES[1].s, pol, { master = 1, dev = 2 }), items())
                local edge = rows[1].parent_lanes[2]
                local d = row_of(rows, "d").parent_lanes[1]
                assert.equals(edge.id, d.id, pol)
                assert.equals(edge.color, d.color, pol)
                assert.is_nil(edge.rank, pol)
                assert.equals(2, d.rank, pol)
                assert.equals(1, rows[1].parent_lanes[1].rank, pol)
            end
        end)

        it("an equal rank births nothing: x and origin/x stay one lane", function()
            local items = h.dag({ { "x", { "o" } }, { "o", { "b" } }, { "b", {} } })
            ref(items, "x", "x")
            ref(items, "o", "origin/x", "remote")
            local rows = columns.layout(opts(STYLES[1].s, "compact", { x = 1, ["origin/x"] = 1 }), items)
            local id = rows[1].parent_lanes[1].id
            assert.equals(id, rows[2].parent_lanes[1].id)
            assert.equals(1, rows[2].parent_lanes[1].rank)
        end)

        it("a worse rank births nothing: the better lane keeps its rank", function()
            local items = h.dag({ { "x", { "o" } }, { "o", { "b" } }, { "b", {} } })
            ref(items, "x", "main")
            ref(items, "o", "old")
            local rows = columns.layout(opts(STYLES[1].s, "compact", { main = 1, old = 2 }), items)
            assert.equals(rows[1].parent_lanes[1].id, rows[2].parent_lanes[1].id)
            assert.equals(1, rows[2].parent_lanes[1].rank)
        end)
    end)

    it("tier 0 beats seniority where two first-parent lanes converge", function()
        -- `t` is senior (minted first); `dv` is pinned. Both have `c` as first parent.
        local function items()
            local it = h.dag({ { "t", { "c" } }, { "dv", { "c" } }, { "c", { "r" } }, { "r", {} } })
            ref(it, "dv", "dev")
            return it
        end
        for _, pol in ipairs(POLICIES) do
            local plain = columns.layout(opts(STYLES[1].s, pol, nil), items())
            assert.equals(plain[1].parent_lanes[1].id, row_of(plain, "c").parent_lanes[1].id)
            local rows = columns.layout(opts(STYLES[1].s, pol, { dev = 1 }), items())
            local dv = rows[2].parent_lanes[1]
            assert.equals(dv.id, row_of(rows, "c").parent_lanes[1].id, pol)
            assert.equals(dv.color, row_of(rows, "c").parent_lanes[1].color, pol)
            -- and a pinned lane ends where it meets a better one
            local r2 = columns.layout(opts(STYLES[1].s, pol, { dev = 2, t = 1 }),
                (function()
                    local it = items()
                    ref(it, "t", "t")
                    return it
                end)())
            assert.equals(r2[1].parent_lanes[1].id, row_of(r2, "c").parent_lanes[1].id, pol)
        end
    end)

    it("lane identity is identical under every policy with pins set", function()
        local function identity(rows)
            local out = {}
            for i, row in ipairs(rows) do
                local per = {}
                for _, kind in ipairs({ "child_lanes", "parent_lanes" }) do
                    for _, l in ipairs(row[kind] or {}) do
                        per[#per + 1] = ("%s|%s->%s=%s/%s/%s"):format(kind,
                            tostring(l.begin and l.begin.hash), tostring(l.parent and l.parent.hash),
                            tostring(l.id), tostring(l.color), tostring(l.rank))
                    end
                end
                table.sort(per)
                out[i] = table.concat(per, ",")
            end
            return table.concat(out, "\n")
        end
        local bad = {}
        for _, set in ipairs(corpus(60)) do
            local rank = scatter_pins(set.items, set.seed)
            for _, st in ipairs(STYLES) do
                local base = identity(columns.layout(opts(st.s, "compact", rank), set.items))
                for _, pol in ipairs({ "survivors", "linear", "straight", "gutter" }) do
                    if identity(columns.layout(opts(st.s, pol, rank), set.items)) ~= base and #bad < 3 then
                        bad[#bad + 1] = ("seed=%d %s/%s"):format(set.seed, st.name, pol)
                    end
                end
            end
        end
        assert.equals(0, #bad, table.concat(bad, "\n"))
    end)

    -- The spec's §5 `gutter` risk note, as an assertion: under the four lane-column
    -- policies a rank changes colour only — the glyphs are untouched — while `gutter`
    -- may move geometry but must keep every invariant, and its births must be seen.
    it("pins move no glyph under the lane-column policies; gutter keeps every invariant", function()
        local moved, errs, births = {}, {}, 0
        for _, set in ipairs(corpus(80)) do
            local rank = scatter_pins(set.items, set.seed)
            for _, st in ipairs(STYLES) do
                for _, pol in ipairs(POLICIES) do
                    local o0, o1 = opts(st.s, pol, nil), opts(st.s, pol, rank)
                    local errors, r1 = h.check(o1, set.items)
                    for _, e in ipairs(errors) do
                        if #errs < 3 then errs[#errs + 1] = ("seed=%d %s/%s: %s"):format(set.seed, st.name, pol, e) end
                    end
                    if pol == "gutter" then
                        local se, _, kinds = h.check_spine(r1, o1)
                        births = births + kinds.birth
                        for _, e in ipairs(se) do
                            if #errs < 3 then errs[#errs + 1] = ("seed=%d %s spine: %s"):format(set.seed, st.name, e) end
                        end
                    else
                        local r0 = columns.layout(o0, set.items)
                        for i = 1, #r0 do
                            if geometry(o0, r0[i]) ~= geometry(o1, r1[i]) and #moved < 3 then
                                moved[#moved + 1] = ("seed=%d %s/%s row %d"):format(set.seed, st.name, pol, i)
                            end
                        end
                    end
                end
            end
        end
        assert.equals(0, #errs, table.concat(errs, "\n"))
        assert.equals(0, #moved, table.concat(moved, "\n"))
        assert.is_true(births > 0, "no pinned birth was exercised")
    end)

    it("streaming equals one-shot with pins, and a pin change re-lays the stream", function()
        local function stream(o_first, o_rest, items, batch)
            local order, st, i = {}, nil, 1
            while i <= #items do
                local stop = math.min(i + batch - 1, #items)
                for k = i, stop do order[#order + 1] = items[k] end
                st = graph.extend_columns(i == 1 and o_first or o_rest, order, i, st)
                i = stop + 1
            end
            return order
        end
        local bad = {}
        local rows = fix.dag
        for _, st in ipairs(STYLES) do
            for _, pol in ipairs({ "compact", "straight" }) do
                local items = h.dag(rows)
                local rank = scatter_pins(items, 3)
                local o = opts(st.s, pol, rank)
                local one = columns.layout(o, items)
                -- carried across batches under one pin set
                local a = stream(o, o, items, 37)
                -- the first batch under NO pins: the fingerprint must force a rebuild
                local b = stream(opts(st.s, pol, nil), o, items, 37)
                for i = 1, #one do
                    if h.row_sig(one[i]) ~= h.row_sig(a[i]) and #bad < 3 then
                        bad[#bad + 1] = ("%s/%s carried row %d"):format(st.name, pol, i)
                    end
                    if h.row_sig(one[i]) ~= h.row_sig(b[i]) and #bad < 3 then
                        bad[#bad + 1] = ("%s/%s re-pinned row %d"):format(st.name, pol, i)
                    end
                end
            end
        end
        assert.equals(0, #bad, table.concat(bad, "\n"))
    end)

    it("the footer's seeded lanes carry their main-view rank (§6.2)", function()
        -- Main view: dev (rank 1) runs down through `o`, pinned at rank 2 — no birth.
        local items = h.dag({ { "d", { "o" } }, { "o", { "y" } }, { "y", {} } })
        ref(items, "d", "dev")
        ref(items, "o", "old")
        local o = opts(STYLES[1].s, "compact", { dev = 1, old = 2 })
        local main = columns.layout(o, items)
        local boundary = pane.boundary_below(main, 1)
        local seam
        for _, lane in pairs(boundary) do seam = lane end
        assert.equals(1, seam.rank)
        -- The footer continues `d`'s lane through `o` exactly as the main view does.
        local node_of = {}
        for _, it in ipairs(items) do node_of[it.commit.hash] = it.commit end
        local res = pane.footer(o, { items[2], items[3] }, boundary, node_of)
        assert.equals(main[2].parent_lanes[1].id, res.rows[1].parent_lanes[1].id)
        assert.equals(seam.id, res.rows[1].parent_lanes[1].id)
    end)
end)
