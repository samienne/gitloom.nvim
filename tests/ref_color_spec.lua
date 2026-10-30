--- Carried refs and ref colouring in the layout (spec §5 "Carried refs", "Lane
--- identity", §5.5, §4.2, §6.2, §3.1): every track carries one ref (`Lane.ref`, a
--- `RankInfo`), colour belongs to the ref's identity, and the layout's ranking input
--- is `opts.ref_rank` (`rank.input`, built here by `h.ranked`). Invariants run over
--- both corpora (raw DAGs and the `h.focused` projection, docs/claude/testing.md).
local h = require("tests.graph_helpers")
local graph = require("gitloom.graph")
local columns = require("gitloom.graph.columns")
local pane = require("gitloom.graph.pane")
local rank = require("gitloom.graph.rank")
local fix = require("tests.large_topo")

local STYLES = {
    { name = "split-line", s = { merge_on_separate_line = false, split_on_separate_line = true } },
    { name = "merge-line", s = { merge_on_separate_line = true, split_on_separate_line = false } },
    { name = "mergesplit", s = { merge_on_separate_line = true, split_on_separate_line = true } },
    { name = "inline",     s = { merge_on_separate_line = false, split_on_separate_line = false } },
}
local POLICIES = { "compact", "survivors", "linear", "straight", "gutter" }

local function opts(ms, policy)
    local o = h.big_opts(ms)
    o.layout_policy = policy
    return o
end

--- Hang a ref named `name` (default kind `local`) on the commit `hash` of `items`.
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

--- Scatter locals, remotes (`origin/<x>` on the same commit, the one above or the
--- one below — a remote at, ahead of or behind its local), remote-only branches and
--- a few pins over a fuzz DAG, deterministically. Returns the pin list.
local function scatter(items, seed)
    local pins = {}
    for i, it in ipairs(items) do
        local c = it.commit
        if (i * 7 + seed) % 4 == 0 then
            local name = "b" .. i
            table.insert(c.refs, { name = name, kind = "local" })
            local r = (i + seed) % 4
            if r < 3 then
                local at = items[math.max(1, math.min(#items, i + r - 1))].commit
                table.insert(at.refs, { name = "origin/" .. name, kind = "remote" })
            end
            if (i + seed) % 5 == 0 then pins[#pins + 1] = name end
        elseif (i * 3 + seed) % 7 == 0 then
            table.insert(c.refs, { name = "origin/r" .. i, kind = "remote" })
            table.insert(c.refs, { name = "v" .. i, kind = "tag" })
        end
    end
    return pins
end

--- Raw and focused fuzz DAGs, refs scattered before projecting (so a collapsed
--- region folds its refs, as in the window).
local function corpus(n)
    local out = {}
    for seed = 1, n do
        local items = h.dag(h.random_dag(6 + (seed % 17), seed))
        local pins = scatter(items, seed)
        if seed % 2 == 0 then items = h.focused(items) end
        out[#out + 1] = { seed = seed, items = items, pins = pins, focused = seed % 2 == 0 }
    end
    return out
end

local function key_of(info) return info and (info.ident or info) end

--- The ranked refs of commit `C` under `rr`, in label order.
local function own_refs(rr, C)
    local out = {}
    if C.virtual then
        if rr.head and rr.infos[rr.head] then out[1] = rr.infos[rr.head] end
        return out
    end
    -- A collapsed head's / kept junction's folded refs are its own too (§5).
    for _, r in ipairs(C.refs or {}) do
        if (r.kind == "local" or r.kind == "remote") and rr.infos[r.name] then out[#out + 1] = rr.infos[r.name] end
    end
    return out
end

--- Every carried-ref invariant of one layout, as a list of violations.
local function check_refs(o, rows)
    local rr = o.ref_rank
    local errs = {}
    local function err(msg) if #errs < 5 then errs[#errs + 1] = msg end end
    local tip = {}
    for i, r in ipairs(rows) do
        for _, rf in ipairs((r.commit and r.commit.refs) or {}) do
            if rr.infos[rf.name] and tip[rf.name] == nil then tip[rf.name] = i end
        end
    end
    local function better(a, b) return rank.better(a, b, tip) end
    local gen_on = {}
    for i, r in ipairs(rows) do
        local C = r.commit
        local where = ("row %d (%s)"):format(i, tostring(C and C.hash))
        local inc, out = r.child_lanes or {}, r.parent_lanes or {}
        for _, l in ipairs(inc) do if not l.ref then err(where .. ": a lane without a ref") end end
        local best_in
        for _, l in ipairs(inc) do
            if l.ref and (not best_in or better(l.ref, best_in)) then best_in = l.ref end
        end
        local sel = best_in
        local own = own_refs(rr, C)
        for _, info in ipairs(own) do if not sel or better(info, sel) then sel = info end end
        -- the selected ref: best of the arriving and own refs, else a generated one
        if sel then
            if r.selected ~= sel then err(where .. ": selected is not the best arriving/own ref") end
        elseif not (r.selected and r.selected.tier == 4) then
            err(where .. ": no source, but the selected ref is not generated")
        end
        -- first parent inherits the selected ref
        if out[1] and out[1].ref ~= r.selected then err(where .. ": first parent does not carry the selected ref") end
        if out[1] and #inc > 0 then
            local trunk
            for _, l in ipairs(inc) do if l.id == out[1].id then trunk = l end end
            if not trunk then
                err(where .. ": no arriving lane continues")
            else
                -- the continuing lane carries the best arriving ref
                if trunk.ref ~= best_in then err(where .. ": the continuing lane is not the best-ranked arriving one") end
                -- colour changes only at a commit carrying an outranking ref of its own
                if out[1].ref == trunk.ref then
                    if out[1].color ~= trunk.color then err(where .. ": one ref, but the lane changed colour") end
                else
                    local mine = false
                    for _, info in ipairs(own) do if info == out[1].ref then mine = true end end
                    if not (mine and better(out[1].ref, trunk.ref)) then
                        err(where .. ": the continuing lane changed ref without an outranking ref here")
                    end
                end
            end
            -- a track never loses rank going down
            for _, l in ipairs(inc) do
                if l.ref and better(l.ref, out[1].ref) then err(where .. ": the first parent lost rank") end
            end
        end
        -- pins first, then brightness wins (§5.1): no ranked ref competing for this
        -- commit (arriving or own) has a better pin rank than the selected ref, and
        -- among unpinned refs the selected one is never drawn dimmer — a track never
        -- steps DOWN in brightness between unpinned refs
        if r.selected and r.selected.level <= 3 then
            local sp = r.selected.pin or math.huge
            local function check(info, what)
                if not info or info.level > 3 then return end
                local ip = info.pin or math.huge
                if ip < sp then
                    err(where .. ": a worse-pinned ref (" .. r.selected.name .. ") beat a better-pinned " .. what)
                elseif ip == math.huge and sp == math.huge and info.level < r.selected.level then
                    err(where .. ": a dimmer ref (" .. r.selected.name .. ") beat a brighter " .. what)
                end
            end
            for _, l in ipairs(inc) do check(l.ref, "arriving ref") end
            for _, info in ipairs(own) do check(info, "own ref") end
        end
        -- other parents: the best ranked ref ON that parent, else its one generated ref
        for k = 2, #out do
            local p = out[k].parent
            local expect
            if p then
                -- Only tips swept so far are known (a ref not yet reached stands
                -- below); the candidates stand at the parent's unswept row.
                local rows_at = setmetatable({}, { __index = function(_, k)
                    local t = tip[k]
                    if t and t <= i then return t end
                end })
                local cands = {}
                for _, rf in ipairs(p.refs or {}) do
                    if (rf.kind == "local" or rf.kind == "remote") and rr.infos[rf.name] then
                        cands[#cands + 1] = rr.infos[rf.name]
                        rows_at[rf.name] = math.huge
                    end
                end
                for _, info in ipairs(cands) do
                    if not expect or rank.better(info, expect, rows_at) then expect = info end
                end
            end
            if expect then
                if out[k].ref ~= expect then err(where .. ": a merge edge does not carry the parent's best ref") end
            else
                if not (out[k].ref and out[k].ref.tier == 4) then
                    err(where .. ": a merge edge into a ref-less parent is not generated")
                elseif gen_on[p] and gen_on[p] ~= out[k].ref then
                    err(where .. ": two merge edges into one ref-less parent carry different generated refs")
                end
                gen_on[p] = out[k].ref
            end
        end
        -- colour is a function of the ref key, and refs alive together differ (big palette);
        -- a track draws its slot at its ref's brightness level (`rank.drawn`, §5.5
        -- "Muting": a pinned / expanded remote `-k`, a collapsed unpinned ref muted)
        local kc, ck = {}, {}
        for _, line in ipairs(h.row_lines(r)) do
            for _, col in ipairs(line.line or {}) do
                for _, s in ipairs(col.lanes or {}) do
                    local k = key_of(s.ref)
                    if k then
                        if rank.level_of(s.color) ~= rank.drawn_level(s.ref) then
                            err(where .. ": a track is not drawn at its ref's brightness level")
                        end
                        local slot = rank.slot_of(s.color)
                        if kc[k] and kc[k] ~= slot then err(where .. ": one identity in two colours") end
                        if ck[slot] and ck[slot] ~= k then err(where .. ": two refs alive together share a colour") end
                        kc[k], ck[slot] = slot, k
                    end
                end
            end
        end
        for name, c in pairs(r.ref_colors or {}) do
            local k = key_of(rr.infos[name])
            if kc[k] and kc[k] ~= c then err(where .. ": label " .. name .. " not in its identity's colour") end
            if (r.ref_levels or {})[name] ~= rank.drawn_level(rr.infos[name]) then
                err(where .. ": label " .. name .. " not at its ref's brightness level")
            end
        end
        -- every own ranked ref is labelled (a collapsed one included), and the node's
        -- level is its selected ref's
        if not C.virtual then
            for _, info in ipairs(own) do
                if not (r.ref_colors or {})[info.name] then err(where .. ": own ref " .. info.name .. " has no label colour") end
            end
        end
        if r.selected_level ~= rank.drawn_level(r.selected) then err(where .. ": selected_level is not the selected ref's") end
    end
    return errs
end

describe("carried refs (§5)", function()
    it("hold every carried-ref invariant on raw and focused fuzz, every style and policy", function()
        local bad = {}
        for _, set in ipairs(corpus(60)) do
            for _, st in ipairs(STYLES) do
                for _, pol in ipairs(POLICIES) do
                    local o = h.ranked(opts(st.s, pol), set.items, { pins = set.pins, current = "b4" })
                    local ok, rows = pcall(columns.layout, o, set.items)
                    if not ok then
                        bad[#bad + 1] = ("seed=%d %s/%s: %s"):format(set.seed, st.name, pol, tostring(rows))
                    else
                        for _, e in ipairs(check_refs(o, rows)) do
                            if #bad < 6 then
                                bad[#bad + 1] = ("seed=%d%s %s/%s: %s"):format(set.seed,
                                    set.focused and "f" or "", st.name, pol, e)
                            end
                        end
                    end
                end
            end
        end
        assert.equals(0, #bad, table.concat(bad, "\n"))
    end)

    it("keep every layout invariant, and move no glyph under the lane-column policies", function()
        local errs, moved = {}, {}
        local gtc = graph._internal.get_column_chars
        local function geometry(o, r)
            local out = {}
            for _, ln in ipairs(h.row_lines(r)) do out[#out + 1] = (gtc(o, ln.line).text:gsub("%s+$", "")) end
            return table.concat(out, "|")
        end
        for _, set in ipairs(corpus(50)) do
            for _, st in ipairs(STYLES) do
                for _, pol in ipairs(POLICIES) do
                    local o1 = h.ranked(opts(st.s, pol), set.items, { pins = set.pins })
                    local errors, r1 = h.check(o1, set.items)
                    for _, e in ipairs(errors) do
                        if #errs < 3 then errs[#errs + 1] = ("seed=%d %s/%s: %s"):format(set.seed, st.name, pol, e) end
                    end
                    if pol == "gutter" then
                        for _, e in ipairs((h.check_spine(r1, o1))) do
                            if #errs < 3 then errs[#errs + 1] = ("seed=%d %s spine: %s"):format(set.seed, st.name, e) end
                        end
                    else
                        local o0 = opts(st.s, pol)
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
    end)

    it("give identical ids, refs and colours under every policy", function()
        local function identity(rows)
            local out = {}
            for i, row in ipairs(rows) do
                local per = {}
                for _, kind in ipairs({ "child_lanes", "parent_lanes" }) do
                    for _, l in ipairs(row[kind] or {}) do
                        per[#per + 1] = ("%s|%s->%s=%s/%s/%s"):format(kind,
                            tostring(l.begin and l.begin.hash), tostring(l.parent and l.parent.hash),
                            tostring(l.id), tostring(l.color), tostring(l.ref and (l.ref.name .. (l.ref.seq or ""))))
                    end
                end
                table.sort(per)
                out[i] = table.concat(per, ",") .. "#" .. tostring(row.selected_color)
            end
            return table.concat(out, "\n")
        end
        local bad = {}
        for _, set in ipairs(corpus(40)) do
            for _, st in ipairs(STYLES) do
                local base = identity(columns.layout(h.ranked(opts(st.s, "compact"), set.items, { pins = set.pins }), set.items))
                for _, pol in ipairs({ "survivors", "linear", "straight", "gutter" }) do
                    local o = h.ranked(opts(st.s, pol), set.items, { pins = set.pins })
                    if identity(columns.layout(o, set.items)) ~= base and #bad < 3 then
                        bad[#bad + 1] = ("seed=%d %s/%s"):format(set.seed, st.name, pol)
                    end
                end
            end
        end
        assert.equals(0, #bad, table.concat(bad, "\n"))
    end)

    it("recolours the continuing lane at a better-ranked tip instead of birthing one", function()
        -- dev pinned; feature1 branches off dev's newest commit: feature1's lane arrives
        -- at dev's tip, continues straight down and is recoloured there (§5 example).
        for _, pol in ipairs(POLICIES) do
            local items = h.dag({ { "f", { "d" } }, { "d", { "x" } }, { "x", {} } })
            ref(items, "f", "feature1")
            ref(items, "d", "dev")
            local o = h.ranked(opts(STYLES[1].s, pol), items, { pins = { "dev" } })
            local rows = columns.layout(o, items)
            local above, below = row_of(rows, "f").parent_lanes[1], row_of(rows, "d").parent_lanes[1]
            assert.equals(above.id, below.id, pol .. ": one lane, continued")
            assert.equals("feature1", above.ref.name, pol)
            assert.equals("dev", below.ref.name, pol)
            assert.equals(1, below.color, pol .. ": dev's pinned slot")
            assert.is_true(above.color ~= below.color, pol .. ": recoloured at dev's tip")
            assert.equals(1, row_of(rows, "d").selected_color, pol .. ": the node takes dev's colour")
        end
    end)

    it("a pinned identity's remote outranks an expanded local: pins first (§5 Rank)", function()
        -- dev pinned, origin/dev ahead of it; feature forked from origin/dev's new
        -- commit: where the tracks meet the slightly muted origin/dev carries on, then
        -- dev from its tip.
        for _, pol in ipairs(POLICIES) do
            local items = h.dag({
                { "f", { "o1" } }, { "o2", { "o1" } }, { "o1", { "d" } }, { "d", { "r" } }, { "r", {} },
            })
            ref(items, "f", "feature")
            ref(items, "o2", "origin/dev", "remote")
            ref(items, "d", "dev")
            local o = h.ranked(opts(STYLES[1].s, pol), items, { pins = { "dev" } })
            local rows = columns.layout(o, items)
            assert.equals("origin/dev", row_of(rows, "o1").selected.name, pol)
            assert.equals(2, row_of(rows, "o1").selected_level, pol .. ": drawn slightly muted")
            assert.equals(2, rank.level_of(row_of(rows, "o2").parent_lanes[1].color), pol .. ": origin/dev slightly muted")
            assert.equals(-1, row_of(rows, "o1").parent_lanes[1].color, pol .. ": dev's slot, muted")
            assert.equals("dev", row_of(rows, "d").selected.name, pol)
            assert.equals(1, row_of(rows, "d").parent_lanes[1].color, pol .. ": dev's pinned slot, full")
        end
    end)

    it("a collapsed ref carries its track in its own colour, muted unless pinned (§5)", function()
        for _, pinned in ipairs({ false, true }) do
            local items = h.dag({ { "m1", { "m0" } }, { "x1", { "m0" } }, { "m0", { "r" } }, { "r", {} } })
            ref(items, "m1", "main")
            ref(items, "x1", "topic").collapsed = true -- a ◍ head folding `topic`
            local o = h.ranked(opts(STYLES[1].s, "compact"), items, { pins = pinned and { "topic" } or nil })
            local rows = columns.layout(o, items)
            local x = row_of(rows, "x1")
            local what = pinned and "pinned" or "unpinned"
            assert.equals("topic", x.selected.name, what)
            assert.equals(pinned and 1 or 3, x.selected_level, what)
            assert.equals(pinned and 1 or 3, rank.level_of(x.parent_lanes[1].color), what)
            assert.equals(x.selected_color, rank.slot_of(x.parent_lanes[1].color), what)
            assert.equals(x.selected_color, x.ref_colors.topic, what .. ": the label is coloured")
            assert.equals(pinned and 1 or 3, x.ref_levels.topic, what)
            -- where the tracks meet, the brighter (or, equal, the pinned) ref continues
            assert.equals(pinned and "topic" or "main", row_of(rows, "m0").selected.name, what)
        end
    end)

    it("draws a remote in its identity's colour: ahead of its local, then the local from its tip", function()
        local items = h.dag({ { "c", { "d" } }, { "d", { "e" } }, { "e", {} } })
        ref(items, "c", "origin/dev", "remote")
        ref(items, "d", "dev")
        local o = h.ranked(opts(STYLES[1].s, "compact"), items, { pins = { "dev" } })
        local rows = columns.layout(o, items)
        local c, d = row_of(rows, "c").parent_lanes[1], row_of(rows, "d").parent_lanes[1]
        assert.equals("origin/dev", c.ref.name)
        assert.is_true(c.ref.remote)
        assert.equals("dev", d.ref.name)
        assert.is_nil(d.ref.remote)
        assert.equals(-c.color, d.color, "local and remote share one hue")
        assert.is_true(c.color < 0, "the remote's track is drawn muted (§5.5)")
        assert.equals(c.id, d.id)
        -- the segments carry the ref too, for render's mute (step 3)
        local seg = row_of(rows, "c").columns[1].lanes
        local found
        for _, s in ipairs(seg) do if s.connectivity.down then found = s.ref end end
        assert.equals(c.ref, found)
    end)

    it("runs the local through a remote that is behind it", function()
        local items = h.dag({ { "d", { "c" } }, { "c", { "e" } }, { "e", {} } })
        ref(items, "d", "dev")
        ref(items, "c", "origin/dev", "remote")
        local o = h.ranked(opts(STYLES[1].s, "compact"), items, {})
        local rows = columns.layout(o, items)
        assert.equals("dev", row_of(rows, "c").parent_lanes[1].ref.name)
        assert.equals(row_of(rows, "d").parent_lanes[1].color, row_of(rows, "c").ref_colors["origin/dev"])
    end)

    it("an unpinned base branch owns its commits: the lower standing row wins", function()
        -- feature sits on top of main (both unpinned): main's colour, not feature's, runs
        -- down main's history (§5 rank rule 2).
        local items = h.dag({ { "f", { "m" } }, { "m", { "r" } }, { "r", {} } })
        ref(items, "f", "feature")
        ref(items, "m", "main")
        local rows = columns.layout(h.ranked(opts(STYLES[1].s, "compact"), items), items)
        assert.equals("main", row_of(rows, "m").parent_lanes[1].ref.name)
    end)

    it("a merge edge carries the merged commit's ref, else a generated ref shared by every merge of it", function()
        local items = h.dag({
            { "m", { "a", "x" } }, { "n", { "a", "x" } }, { "f", { "y" } }, { "o", { "a", "y" } },
            { "a", { "x" } }, { "y", { "x" } }, { "x", {} },
        })
        ref(items, "m", "master")
        ref(items, "f", "feature")
        local rows = columns.layout(h.ranked(opts(STYLES[1].s, "compact"), items, { pins = { "master" } }), items)
        local mx, nx = row_of(rows, "m").parent_lanes[2], row_of(rows, "n").parent_lanes[2]
        assert.equals(4, mx.ref.tier, "x has no ref: generated")
        assert.equals(mx.ref, nx.ref, "a later merge of x takes the same generated ref")
        assert.equals(mx.color, nx.color)
        -- `o` merges `y`, which carries no ref although `feature` sits further down its
        -- line: the edge is generated (one commit looked up, never further down).
        assert.equals(4, row_of(rows, "o").parent_lanes[2].ref.tier)
        -- ... while a merge of a commit with a ref carries it
        local items2 = h.dag({ { "m", { "a", "x" } }, { "x", { "a" } }, { "a", {} } })
        ref(items2, "m", "master")
        ref(items2, "x", "feature")
        local rows2 = columns.layout(h.ranked(opts(STYLES[1].s, "compact"), items2, { pins = { "master" } }), items2)
        assert.equals("feature", row_of(rows2, "m").parent_lanes[2].ref.name)
    end)

    it("a tag-only tip selects a generated ref; a root's ends with it", function()
        local items = h.dag({ { "t", { "r" } }, { "r", {} } })
        ref(items, "t", "v1", "tag")
        local rows = columns.layout(h.ranked(opts(STYLES[1].s, "compact"), items), items)
        assert.equals(4, rows[1].selected.tier)
        assert.equals(rows[1].selected, rows[1].parent_lanes[1].ref)
        assert.is_nil(rows[1].ref_colors.v1, "tags are not ranked and get no ref colour")
    end)
end)

describe("ref colours (§5.5)", function()
    --- A small palette, so colours recycle.
    local function small(o, n, generate, buffer)
        local p = {}
        for i = 1, n do p[i] = "C" .. i end
        o.palette.tracks = p
        o.palette.generate = generate
        o.palette.buffer = buffer or 0
        return o
    end

    it("a pinned identity owns slot k, unchanged by a pin added below it", function()
        local function items()
            local it = h.dag({
                { "a", { "m" } }, { "b", { "m" } }, { "c", { "m" } }, { "m", { "r" } }, { "r", {} },
            })
            ref(it, "a", "A")
            ref(it, "b", "B")
            ref(it, "c", "C")
            ref(it, "c", "origin/B", "remote")
            return it
        end
        for _, pol in ipairs(POLICIES) do
            for _, pins in ipairs({ { "B", "C" }, { "B", "C", "A" } }) do
                local it = items()
                local rows = columns.layout(h.ranked(opts(STYLES[1].s, pol), it, { pins = pins }), it)
                assert.equals(1, row_of(rows, "b").selected_color, pol)
                assert.equals(2, row_of(rows, "c").ref_colors.C, pol)
                assert.equals(1, row_of(rows, "c").ref_colors["origin/B"], pol .. ": B's remote in B's slot")
                if #pins == 3 then assert.equals(3, row_of(rows, "a").selected_color, pol) end
            end
            -- unpinned, `a` (the first tip) takes slot 1; with B pinned nobody else does
            local it = items()
            assert.equals(1, columns.layout(h.ranked(opts(STYLES[1].s, pol), it), it)[1].selected_color, pol)
            it = items()
            local rows = columns.layout(h.ranked(opts(STYLES[1].s, pol), it, { pins = { "B" } }), it)
            for _, r in ipairs(rows) do
                for _, l in ipairs(r.parent_lanes or {}) do
                    if rank.slot_of(l.color) == 1 then assert.equals("B", l.ref.ident, pol) end
                end
            end
        end
    end)

    it("an entry naming a tag owns nothing; a pin past the palette takes a free-list colour", function()
        local it = h.dag({ { "a", { "r" } }, { "r", {} } })
        ref(it, "a", "A")
        ref(it, "a", "v1", "tag")
        -- `v1` holds entry 1 but names no ranked ref: slot 1 stays in the free list
        local rows = columns.layout(h.ranked(opts(STYLES[1].s, "compact"), it, { pins = { "v1", "A" } }), it)
        assert.equals(2, rows[1].selected_color, "A is pin entry 2")
        local o = small(h.ranked(opts(STYLES[1].s, "compact"), it, { pins = { "x1", "x2", "A" } }), 2, false)
        rows = columns.layout(o, it)
        assert.is_true(rows[1].selected_color <= 2, "past the curated palette: an ordinary colour")
    end)

    it("an identity keeps its colour while a member is pending below, and releases it after", function()
        -- `feature` sits on dev's track (outranked at its own tip): allocated for the
        -- label. `origin/feature` is still to come further down, so the colour is held
        -- and the remote's label gets the same one; then it is released.
        local items = h.dag({
            { "d", { "f" } }, { "f", { "g" } }, { "g", { "o" } }, { "o", { "z" } }, { "z", {} },
            { "k", { "w" } }, { "w", {} },
        })
        ref(items, "d", "dev")
        ref(items, "f", "feature")
        ref(items, "o", "origin/feature", "remote")
        local o = small(h.ranked(opts(STYLES[1].s, "compact"), items, { pins = { "dev" } }), 3, false)
        local rows = columns.layout(o, items)
        local fc = row_of(rows, "f").ref_colors.feature
        assert.equals("dev", row_of(rows, "f").parent_lanes[1].ref.name)
        assert.equals(fc, row_of(rows, "o").ref_colors["origin/feature"])
        -- released at o's row (no live track, nothing pending): `k`'s generated ref may
        -- now draw from the free list again (2 slots: dev holds 1)
        assert.is_true(row_of(rows, "k").selected_color ~= 1)
    end)

    it("a member whose tip never loads holds no colour; a coming one does (§5.5)", function()
        -- `origin/feature` is a visible ranked ref whose tip is not on any loaded row.
        -- Not coming: feature's colour is released at its root and `k` reuses slot 1.
        -- Coming (the running stream will deliver it): held, so `k` mints slot 2.
        for _, coming in ipairs({ false, true }) do
            local items = h.dag({ { "f", { "fz" } }, { "fz", {} }, { "k", { "kw" } }, { "kw", {} } })
            ref(items, "f", "feature")
            local o = small(h.ranked(opts(STYLES[1].s, "compact"), items, {
                extra_refs = { ["origin/feature"] = { name = "origin/feature", kind = "remote" } },
                visible = { feature = true, ["origin/feature"] = true },
                coming = coming or nil,
            }), 1, true, 0)
            assert.is_not_nil(o.ref_rank.infos["origin/feature"])
            local rows = columns.layout(o, items)
            assert.equals(1, row_of(rows, "f").selected_color)
            assert.equals(coming and 2 or 1, row_of(rows, "k").selected_color, tostring(coming))
        end
    end)

    it("a released colour waits `buffer` allocations before it is reused", function()
        -- one curated slot, generation on, buffer 2: a1 takes 1 and releases it at its
        -- root; b1 and c1 cannot reuse it yet (cooldown) and mint; d1 takes 1 again.
        local items = h.dag({
            { "a1", { "a0" } }, { "a0", {} }, { "b1", { "b0" } }, { "b0", {} },
            { "c1", { "c0" } }, { "c0", {} }, { "d1", { "d0" } }, { "d0", {} },
        })
        local o = small(h.ranked(opts(STYLES[1].s, "compact"), items), 1, true, 2)
        local rows = columns.layout(o, items)
        assert.equals(1, row_of(rows, "a1").selected_color)
        assert.is_true(row_of(rows, "b1").selected_color > 1)
        assert.is_true(row_of(rows, "c1").selected_color > 1)
        assert.equals(1, row_of(rows, "d1").selected_color)
        -- and in general: between a slot's release and its reuse, at least `buffer`
        -- other allocations happen (fuzz, generated refs only)
        for seed = 1, 30 do
            local it = h.dag(h.random_dag(8 + seed % 10, seed))
            local oo = small(h.ranked(opts(STYLES[1].s, "compact"), it), 3, true, 2)
            local rr = columns.layout(oo, it)
            local last_seen, born, seq = {}, {}, 0
            for _, r in ipairs(rr) do
                local function seen(info, c)
                    if not born[info] then
                        seq = seq + 1
                        born[info] = seq
                        local prev = last_seen[c]
                        if prev and prev.info ~= info then
                            assert.is_true(seq - prev.seq > 2,
                                ("seed %d: slot %d reused after %d allocations"):format(seed, c, seq - prev.seq - 1))
                        end
                        last_seen[c] = { info = info, seq = seq }
                    end
                end
                seen(r.selected, r.selected_color)
                for k = 2, #(r.parent_lanes or {}) do seen(r.parent_lanes[k].ref, rank.slot_of(r.parent_lanes[k].color)) end
            end
        end
    end)
end)

describe("ref ranking input (§5 'The ranks are a layout input')", function()
    it("streaming equals one-shot, and a ranking change re-lays the stream", function()
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
        for _, st in ipairs(STYLES) do
            for _, pol in ipairs({ "compact", "straight" }) do
                local items = h.dag(fix.dag)
                local pins = scatter(items, 3)
                local o = h.ranked(opts(st.s, pol), items, { pins = pins })
                -- The stream runs under `--all` (§5.5): every ref is coming.
                local os = h.ranked(opts(st.s, pol), items, { pins = pins, coming = true })
                local one = columns.layout(o, items)
                local a = stream(os, os, items, 37)
                local b = stream(opts(st.s, pol), os, items, 37)
                for i = 1, #one do
                    if h.row_sig(one[i]) ~= h.row_sig(a[i]) and #bad < 3 then
                        bad[#bad + 1] = ("%s/%s carried row %d"):format(st.name, pol, i)
                    end
                    if h.row_sig(one[i]) ~= h.row_sig(b[i]) and #bad < 3 then
                        bad[#bad + 1] = ("%s/%s re-ranked row %d"):format(st.name, pol, i)
                    end
                end
            end
        end
        assert.equals(0, #bad, table.concat(bad, "\n"))
    end)

    it("the footer's seeded lanes carry their main-view ref and colour (§6.2)", function()
        local items = h.dag({
            { "d", { "o" } }, { "o", { "y" } }, { "y", {} }, { "f", { "z" } }, { "z", {} },
            { "g", { "w" } }, { "w", {} },
        })
        ref(items, "d", "dev")
        ref(items, "o", "old")
        ref(items, "f", "feat")
        local o = h.ranked(opts(STYLES[1].s, "compact"), items, { pins = { "dev", "feat" } })
        o.palette.tracks = { "C1", "C2", "C3" }
        local main = columns.layout(o, items)
        local boundary = pane.boundary_below(main, 1)
        local seam
        for _, lane in pairs(boundary) do seam = lane end
        assert.equals("dev", seam.ref.name)
        local node_of = {}
        for _, it in ipairs(items) do node_of[it.commit.hash] = it.commit end
        local rest = {}
        for i = 2, #items do rest[#rest + 1] = items[i] end
        local res = pane.footer(o, rest, boundary, node_of)
        -- dev continues through `old` exactly as in the main view, and every later
        -- colour matches the main view's
        assert.equals(seam.id, row_of(res.rows, "o").parent_lanes[1].id)
        assert.equals("dev", row_of(res.rows, "o").parent_lanes[1].ref.name)
        for _, hsh in ipairs({ "o", "f", "g" }) do
            assert.equals(row_of(main, hsh).parent_lanes[1].color, row_of(res.rows, hsh).parent_lanes[1].color, hsh)
        end
    end)
end)

-- §4.2 "Layout identity follows HEAD": a working-tree node carries HEAD's current
-- branch, so the ◌ lane continues into HEAD in that branch's colour; detached, the
-- stack selects a generated ref, which yields to the branch at the HEAD commit.
describe("working-tree nodes carry HEAD's branch (§4.2)", function()
    local WT = "0000000000000000000000000000000000000003"

    local function items_for(head_at, stack)
        local items = h.dag({ { "m3", { "m2" } }, { "f2", { "f1" } }, { "f1", { "m2" } },
            { "m2", { "m1" } }, { "m1", {} } })
        ref(items, "m3", "main")
        ref(items, "f2", "feature")
        ref(items, head_at, "HEAD", "head")
        local below
        for _, it in ipairs(items) do if it.commit.hash == head_at then below = it.commit end end
        for i, kind in ipairs(stack or {}) do
            local v = { hash = WT:sub(1, 39) .. i, virtual = kind, parents = { below },
                children = {}, refs = {}, wt = { changed = 0 } }
            table.insert(below.children, v)
            for k, it in ipairs(items) do
                if it.commit == below then table.insert(items, k, { type = "commit", commit = v }); break end
            end
            below = v
        end
        return items
    end

    local CASES = {
        { name = "HEAD on pinned main", head = "m3", current = "main" },
        { name = "HEAD on unpinned feature", head = "f2", current = "feature" },
    }
    for _, cs in ipairs(CASES) do
        for _, stack in ipairs({ { "clean" }, { "staged", "unstaged" } }) do
            it(("%s: the ◌ lane continues into HEAD in HEAD's colour (%s)"):format(cs.name,
                table.concat(stack, "+")), function()
                for _, pol in ipairs(POLICIES) do
                    local p_items, s_items = items_for(cs.head), items_for(cs.head, stack)
                    local plain = columns.layout(h.ranked(opts(STYLES[1].s, pol), p_items,
                        { pins = { "main" }, current = cs.current }), p_items)
                    local rows = columns.layout(h.ranked(opts(STYLES[1].s, pol), s_items,
                        { pins = { "main" }, current = cs.current }), s_items)
                    local hd = row_of(rows, cs.head).parent_lanes[1]
                    local n = 0
                    for _, r in ipairs(rows) do
                        if r.commit and r.commit.virtual then
                            n = n + 1
                            local l = r.parent_lanes[1]
                            assert.equals(hd.id, l.id, pol)
                            assert.equals(hd.color, l.color, pol)
                            assert.equals(cs.current, l.ref.name, pol)
                        end
                    end
                    assert.equals(#stack, n, pol)
                    for _, c in ipairs({ "m3", "f2", "f1", "m2", "m1" }) do
                        local a, b = row_of(plain, c), row_of(rows, c)
                        if a.parent_lanes[1] then
                            assert.equals(a.parent_lanes[1].color, b.parent_lanes[1].color, pol .. " " .. c)
                        end
                    end
                end
            end)
        end
    end

    it("detached: the stack carries a generated ref that yields at HEAD's commit", function()
        local items = items_for("m2", { "clean" })
        local rows = columns.layout(h.ranked(opts(STYLES[1].s, "compact"), items, { pins = { "main" } }), items)
        local v
        for _, r in ipairs(rows) do if r.commit.virtual then v = r end end
        assert.equals(4, v.parent_lanes[1].ref.tier)
        assert.equals("main", row_of(rows, "m2").parent_lanes[1].ref.name)
    end)
end)
