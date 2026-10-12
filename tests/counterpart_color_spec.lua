--- Counterpart colours (spec §5.5 "Counterpart colours", §6 "Label colour", §12):
--- a lane born unranked at an implicit remote counterpart's tip (`opts.pin_counterpart`,
--- ref id → its local's rank) shares the local's held pinned slot `k`, as colour `-k`
--- — the counterpart variant, drawn as a light hue-preserving blend
--- (`palette.counterpart_dim`) on which the cone dim composes. Colour only: no glyph
--- and no lane id moves; nil / empty maps are byte-identical; the slot returns to the
--- free list only when its last holder ends; footer seeds carry it, the header keeps
--- it; `pin_upstream = false` publishes no map.
local h = require("tests.graph_helpers")
local graph = require("gitloom.graph")
local columns = require("gitloom.graph.columns")
local pane = require("gitloom.graph.pane")
local render = require("gitloom.graph.render")
local selectm = require("gitloom.graph.select")
local fix = require("tests.large_topo")

local STYLES = {
    { name = "split-line", s = { merge_on_separate_line = false, split_on_separate_line = true } },
    { name = "merge-line", s = { merge_on_separate_line = true, split_on_separate_line = false } },
    { name = "mergesplit", s = { merge_on_separate_line = true, split_on_separate_line = true } },
    { name = "inline",     s = { merge_on_separate_line = false, split_on_separate_line = false } },
}
local POLICIES = { "compact", "survivors", "linear", "straight", "gutter" }

local function opts(ms, policy, rank, cp)
    local o = h.big_opts(ms)
    o.layout_policy = policy
    o.pin_rank = rank
    o.pin_counterpart = cp
    return o
end

--- A small palette, so slots run out and the accounting is actually tested.
local function small(rank, cp, n)
    local o = opts(STYLES[1].s, "compact", rank, cp)
    local p = {}
    for i = 1, n do p[i] = "C" .. i end
    o.palette.tracks = p
    o.palette.generate = false
    o.palette.buffer = 0
    return o
end

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

local function row_of(rows, hash)
    for _, r in ipairs(rows) do
        if r.commit and r.commit.hash == hash then return r end
    end
end

local function lane(rows, hash) return row_of(rows, hash).parent_lanes[1] end

--- Glyphs only (colour stripped) of one row's Lines.
local function geometry(o, r)
    local gtc = graph._internal.get_column_chars
    local out = {}
    for _, ln in ipairs(h.row_lines(r)) do
        out[#out + 1] = (gtc(o, ln.line).text:gsub("%s+$", ""))
    end
    return table.concat(out, "|")
end

--- Lane ids of a row (identity, independent of colour).
local function ids(r)
    local out = {}
    for _, l in ipairs(r.parent_lanes or {}) do out[#out + 1] = tostring(l.id) end
    for _, l in ipairs(r.child_lanes or {}) do out[#out + 1] = tostring(l.id) end
    return table.concat(out, ",")
end

--- Pin 4 local entries (ranks 1..4) and hang remote counterparts of them on OTHER
--- commits (ahead / diverged / anywhere), so counterpart births happen.
local function scatter(items, seed)
    local rank, cp, k = {}, {}, 0
    for i, it in ipairs(items) do
        local c = it.commit
        if k < 4 and (i * 5 + seed) % 3 == 0 then
            k = k + 1
            c.refs = c.refs or {}
            table.insert(c.refs, { name = "u" .. i, kind = "local" })
            rank["u" .. i] = k
        elseif (i * 7 + seed) % 4 == 0 then
            c.refs = c.refs or {}
            table.insert(c.refs, { name = "origin/o" .. i, kind = "remote" })
            cp["origin/o" .. i] = ((i + seed) % 4) + 1
        end
    end
    return rank, cp
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

describe("counterpart colours (§5.5)", function()
    it("a counterpart ahead of its local: slot -k above the local's tip, full k from it", function()
        local items = h.dag({ { "ox", { "x" } }, { "x", { "b" } }, { "b", {} } })
        ref(items, "ox", "origin/x", "remote")
        ref(items, "x", "x")
        for _, pol in ipairs(POLICIES) do
            local rows = columns.layout(opts(STYLES[1].s, pol, { x = 1 }, { ["origin/x"] = 1 }), items)
            local o, x = lane(rows, "ox"), lane(rows, "x")
            assert.equals(-1, o.color, pol)
            assert.is_nil(o.rank, pol) -- colour only: still unranked
            assert.equals(1, x.color, pol)
            assert.is_true(o.id ~= x.id, pol)
        end
    end)

    it("a diverged counterpart shares slot k with the concurrent pinned lane; nothing else takes it", function()
        local items = h.dag({
            { "x", { "a" } }, { "ox", { "b" } }, { "y", { "b" } }, { "a", { "b" } }, { "b", {} },
        })
        ref(items, "x", "x")
        ref(items, "ox", "origin/x", "remote")
        for _, pol in ipairs(POLICIES) do
            local rows = columns.layout(opts(STYLES[1].s, pol, { x = 1 }, { ["origin/x"] = 1 }), items)
            assert.equals(1, lane(rows, "x").color, pol)
            assert.equals(-1, lane(rows, "ox").color, pol)
            assert.is_true(math.abs(lane(rows, "y").color) ~= 1, pol)
        end
    end)

    it("the slot returns only when the pinned lane AND every counterpart lane holding it ended", function()
        -- 2 curated slots, no truecolor. u holds slot 2 throughout; x (rank 1) and its
        -- counterpart ox both hold slot 1. x ends at b first: g, born while ox still
        -- holds slot 1, must SHARE slot 2 rather than receive slot 1. Once ox ends at c,
        -- slot 1 is an ordinary free colour again and h takes it.
        local items = h.dag({
            { "u", { "z" } }, { "x", { "b" } }, { "ox", { "c" } }, { "b", {} }, { "g", { "w" } },
            { "c", {} }, { "hh", { "y" } }, { "w", {} }, { "y", {} }, { "z", {} },
        })
        ref(items, "x", "x")
        ref(items, "ox", "origin/x", "remote")
        local rows = columns.layout(small({ x = 1 }, { ["origin/x"] = 1 }, 2), items)
        assert.equals(2, lane(rows, "u").color)
        assert.equals(1, lane(rows, "x").color)
        assert.equals(-1, lane(rows, "ox").color)
        assert.equals(2, lane(rows, "g").color)
        assert.equals(1, lane(rows, "hh").color)
        -- Teeth: without the counterpart holder, x's end at b releases slot 1 for g.
        local plain = columns.layout(small({ x = 1 }, nil, 2), items)
        assert.equals(1, lane(plain, "g").color)
    end)

    it("no ordinary lane holds slot k while a pinned or counterpart lane does (fuzz)", function()
        local bad, cps = {}, 0
        for _, set in ipairs(corpus(60)) do
            local rank, cp = scatter(set.items, set.seed)
            for _, st in ipairs(STYLES) do
                local o = small(rank, cp, 6)
                o.merge_style = vim.tbl_extend("force", o.merge_style or {}, st.s)
                local rows = columns.layout(o, set.items)
                -- lane id → { color, rank, from, to } over row indices
                local at = {}
                for i, r in ipairs(rows) do if r.commit then at[r.commit.hash] = i end end
                local by = {}
                for _, r in ipairs(rows) do
                    for _, l in ipairs(r.parent_lanes or {}) do
                        local c = by[l.id] or { color = l.color, rank = l.rank, from = math.huge, to = 0 }
                        by[l.id] = c
                        local b = l.begin and at[l.begin.hash] or 0
                        local e = l.parent and at[l.parent.hash] or (#rows + 1)
                        if b < c.from then c.from = b end
                        if e > c.to then c.to = e end
                    end
                end
                for id, c in pairs(by) do
                    if c.color < 0 then cps = cps + 1 end
                    local k = math.abs(c.color)
                    local holder = c.color < 0 or c.rank == k
                    if not holder and k <= 4 then
                        for hid, hc in pairs(by) do
                            local hholder = hc.color == -k or (hc.color == k and hc.rank == k)
                            if hid ~= id and hholder and hc.from < c.from and hc.to > c.from and #bad < 3 then
                                bad[#bad + 1] = ("seed=%d %s: lane %d took slot %d at row %d while lane %d held it to %d")
                                    :format(set.seed, st.name, id, k, c.from, hid, hc.to)
                            end
                        end
                    end
                end
            end
        end
        assert.equals(0, #bad, table.concat(bad, "\n"))
        assert.is_true(cps > 0, "no counterpart lane was born")
    end)

    it("moves no glyph and no lane id; nil and empty maps are byte-identical", function()
        local bad, cps = {}, 0
        local sets = corpus(40)
        sets[#sets + 1] = { seed = 0, items = h.dag(fix.dag) }
        sets[#sets + 1] = { seed = -1, items = h.focused(h.dag(fix.dag)) }
        for _, set in ipairs(sets) do
            local rank, cp = scatter(set.items, set.seed)
            for _, st in ipairs(STYLES) do
                for _, pol in ipairs(POLICIES) do
                    local base = columns.layout(opts(st.s, pol, rank, nil), set.items)
                    local empty = columns.layout(opts(st.s, pol, rank, {}), set.items)
                    local o = opts(st.s, pol, rank, cp)
                    local got = columns.layout(o, set.items)
                    for i = 1, #base do
                        if h.row_sig(base[i]) ~= h.row_sig(empty[i]) and #bad < 3 then
                            bad[#bad + 1] = ("seed=%d %s/%s row %d: empty map differs"):format(set.seed, st.name, pol, i)
                        end
                        if (geometry(o, base[i]) ~= geometry(o, got[i]) or ids(base[i]) ~= ids(got[i]))
                            and #bad < 3 then
                            bad[#bad + 1] = ("seed=%d %s/%s row %d: geometry/identity moved"):format(set.seed, st.name, pol, i)
                        end
                        for _, l in ipairs(got[i].parent_lanes or {}) do
                            if l.color < 0 then cps = cps + 1 end
                        end
                    end
                end
            end
        end
        assert.equals(0, #bad, table.concat(bad, "\n"))
        assert.is_true(cps > 0, "no counterpart lane was born")
    end)

    it("streaming equals one-shot with counterparts, and a map change re-lays the stream", function()
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
        for _, pol in ipairs({ "compact", "straight" }) do
            local items = h.dag(fix.dag)
            local rank, cp = scatter(items, 3)
            local o = opts(STYLES[1].s, pol, rank, cp)
            local one = columns.layout(o, items)
            local a = stream(o, o, items, 37)
            -- the first batch without the map: the fingerprint must force a rebuild
            local b = stream(opts(STYLES[1].s, pol, rank, nil), o, items, 37)
            for i = 1, #one do
                if h.row_sig(one[i]) ~= h.row_sig(a[i]) and #bad < 3 then
                    bad[#bad + 1] = ("%s carried row %d"):format(pol, i)
                end
                if h.row_sig(one[i]) ~= h.row_sig(b[i]) and #bad < 3 then
                    bad[#bad + 1] = ("%s re-mapped row %d"):format(pol, i)
                end
            end
        end
        assert.equals(0, #bad, table.concat(bad, "\n"))
    end)

    it("the footer: a seed carries -k as one more holder, never taking the reservation over", function()
        -- 2 slots, no truecolor. ox (counterpart of x, rank 1) crosses the seam and
        -- ends at root c inside the pane; x is born inside the pane and takes the
        -- reservation (slot 1); g, born after x ended, gets slot 1 only once ox ended.
        local items = h.dag({
            { "ox", { "c" } }, { "x", { "b" } }, { "b", {} }, { "g", { "w" } }, { "c", {} },
            { "hh", { "y" } }, { "w", {} }, { "y", {} },
        })
        ref(items, "x", "x")
        ref(items, "ox", "origin/x", "remote")
        local o = small({ x = 1 }, { ["origin/x"] = 1 }, 2)
        local main = columns.layout(o, items)
        assert.equals(-1, lane(main, "ox").color)
        local boundary = pane.boundary_below(main, 1)
        local seen = false
        for _, l in pairs(boundary) do if l.color == -1 then seen = true end end
        assert.is_true(seen, "the seam carries the counterpart colour")
        local node_of = {}
        for _, it in ipairs(items) do node_of[it.commit.hash] = it.commit end
        local rest = {}
        for i = 2, #items do rest[#rest + 1] = items[i] end
        local res = pane.footer(o, rest, boundary, node_of)
        for _, hash in ipairs({ "x", "g", "hh" }) do
            assert.equals(lane(main, hash).color, lane(res.rows, hash).color, hash)
        end
        assert.equals(1, lane(res.rows, "x").color)
        assert.equals(2, lane(res.rows, "g").color)
        assert.equals(1, lane(res.rows, "hh").color)
    end)

    describe("the window input (select.pin_counterpart_rank)", function()
        local refs = {
            x = { kind = "local", name = "x" },
            ["origin/x"] = { kind = "remote", name = "origin/x" },
            ["upstream/x"] = { kind = "remote", name = "upstream/x" },
            main = { kind = "local", name = "main" },
            ["origin/main"] = { kind = "remote", name = "origin/main" },
        }
        local pins = { { id = "main" }, { id = "x" }, { id = "upstream/x" } }
        it("maps each implicit counterpart to its local's rank, never an entry or an unpinned ref", function()
            local cp = selectm.pin_counterpart_rank(pins, refs, { "origin", "upstream" }, { ["origin/main"] = true })
            assert.same({ ["origin/x"] = 2 }, cp)
            assert.same({ ["origin/main"] = 1, ["origin/x"] = 2 },
                selectm.pin_counterpart_rank(pins, refs, { "origin", "upstream" }, {}))
        end)
        it("pin_upstream = false publishes an empty map", function()
            local win = require("gitloom.window")._internal
            local ctx = {
                opts = { pin_upstream = false },
                repo = { refs = refs }, remotes = { "origin" }, view_state = { unpinned = {} },
                effective_pins = function() return pins end,
            }
            assert.same({}, win.pin_counterpart(ctx))
            ctx.opts.pin_upstream = true
            assert.same({ ["origin/main"] = 1, ["origin/x"] = 2 }, win.pin_counterpart(ctx))
        end)
    end)

    describe("rendering", function()
        local saved
        before_each(function()
            saved = vim.o.termguicolors
            vim.o.termguicolors = true
            vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff, bg = 0x000000 })
            vim.api.nvim_set_hl(0, "C1", { fg = 0xc86400 })
            render.reset_dim_cache()
        end)
        after_each(function()
            vim.o.termguicolors = saved
            render.reset_dim_cache()
        end)

        local function o(extra)
            local x = small({}, nil, 2)
            for k, v in pairs(extra or {}) do x.palette[k] = v end
            return x
        end
        local function fg(group)
            return vim.api.nvim_get_hl(0, { name = group, link = false }).fg
        end

        it("slot -k is the light blend of slot k (default 0.25), cached, flat without truecolor", function()
            local g = render.slot_hl(o(), -1)
            assert.is_true(g ~= "C1")
            assert.equals(render.counterpart_hl(o(), "C1"), g)
            -- 0xc8 * 0.75 = 150, 0x64 * 0.75 = 75
            assert.equals(150 * 65536 + 75 * 256, fg(g))
            assert.equals(g, render.slot_hl(o(), -1)) -- cached
            -- the factor is configurable
            local g2 = render.slot_hl(o({ counterpart_dim = 0.5 }), -1)
            assert.equals(100 * 65536 + 50 * 256, fg(g2))
            vim.o.termguicolors = false
            assert.equals("C1", render.slot_hl(o(), -1))
        end)

        it("the cone dim composes on top: dim_hl of the counterpart group blends it again", function()
            local cpg = render.slot_hl(o(), -1)
            local d = render.dim_hl(o(), cpg)
            -- 150 * 0.55 = 82.5 → 83; 75 * 0.55 = 41.25 → 41
            assert.equals(83 * 65536 + 41 * 256, fg(d))
            -- lighter than the counterpart colour, and still distinct from the dimmed pinned lane
            assert.is_true(fg(d) ~= fg(render.dim_hl(o(), "C1")))
        end)

        it("a counterpart's label takes the light-dim lane colour", function()
            local c = { parents = { {} }, children = { {} }, message = "m",
                refs = { { kind = "remote", name = "origin/x" } } }
            local cells = { {
                connectivity = { up = true, down = true },
                lanes = { { connectivity = { up = true, down = true }, id = 1, color = -1, edges = {} } },
                has_commit = true, commit = c,
            } }
            local x = o()
            x.icons = {}
            local el = render.display_item(x, { type = "commit", commit = c, columns = cells }, {}, nil)
            local want = render.slot_hl(x, -1)
            assert.equals(want, render.get_column_chars(x, cells).highlight[1].hl)
            local hls = {}
            for _, hh in ipairs(el.line_right[1].highlight) do hls[hh.hl] = true end
            assert.is_true(hls[want], "label drawn in the counterpart colour")
        end)
    end)
end)
