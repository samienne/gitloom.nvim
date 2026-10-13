--- Replay a large real-world repository topology (anonymised — synthetic ids only, no
--- hashes/names/messages; see tests/large_topo.lua) through the full header pipeline at
--- EVERY cutoff, and verify the pinned anchors HEAD and dev keep their graph lane id
--- throughout — they must never terminate into a fresh synthetic id when a merge sits at
--- the cutoff (the merge-at-cutoff anchor-severing bug, where a pinned anchor was severed
--- onto a fresh lane id instead of staying on its crossing lane).
local h = require("tests.graph_helpers")
local pane = require("gitloom.graph.pane")
local columns = require("gitloom.graph.columns")
local view = require("gitloom.graph.view")
local fix = require("tests.large_topo")

-- Build the projected display + lane maps ONCE (the projection is cutoff-independent).
local function build(policy, small, cp)
    local items = h.dag(fix.dag)
    local byhash = {}
    for _, it in ipairs(items) do byhash[it.commit.hash] = it.commit end
    local refs = {
        enne = { name = "enne", kind = "local", commit = byhash[fix.head] }, -- HEAD's branch
        HEAD = { name = "HEAD", kind = "head", commit = byhash[fix.head] },
        dev = { name = "dev", kind = "local", commit = byhash[fix.dev] },
    }
    if cp then
        -- dev's remote counterpart a few first-parent commits below HEAD's branch tip
        -- (the LumeScene shape): a counterpart birth (§5/§5.5) ends enne's lane there.
        local c = byhash[fix.head]
        for _ = 1, 3 do
            local p = c.parents and c.parents[1]
            p = type(p) == "table" and p or byhash[p]
            if p then c = p end
        end
        refs["origin/dev"] = { name = "origin/dev", kind = "remote", commit = c }
    end
    for _, r in ipairs(fix.refs) do
        if byhash[r.commit] and not refs[r.name] then
            refs[r.name] = { name = r.name, kind = "local", commit = byhash[r.commit] }
        end
    end
    for name, r in pairs(refs) do
        local c = r.commit; c.refs = c.refs or {}; c.refs[#c.refs + 1] = { name = name, kind = r.kind }
    end
    local function ofr()
        local out = {}
        for name, r in pairs(refs) do
            if r.kind ~= "head" and r.commit then out[#out + 1] = { id = name, tip = r.commit, mode = "normal" } end
        end
        return out
    end
    local pinned = { enne = true, dev = true } -- HEAD's branch + dev, like effective_pinned
    if cp then pinned["origin/dev"] = true end -- a counterpart is an anchor too (§10.6)
    local proj = view.project(items, view.owners(items, ofr(), pinned, {}, true), nil)
    local display = proj.items
    local opts = h.big_opts()
    if small then
        -- A 6-colour palette (generated colours on): the main view recycles colours
        -- heavily, which is what the header's de-collision must not over-react to.
        opts.palette.tracks = { "T1", "T2", "T3", "T4", "T5", "T6" }
        opts.palette.generate = true
        opts.palette.buffer = 3
    end
    opts.layout_policy = policy
    -- The pinned anchors' lane ranks, as `ctx:sync_pin_rank` publishes them (the
    -- default order: trunks first, HEAD's anchor last; §10.6). Without them §5 tier 2
    -- (the NEWEST lane) may end an anchor's lane at a junction below its tip, and the
    -- lane crossing a cutoff there is legitimately another one — the production
    -- graph never lays an anchor out unranked.
    opts.pin_rank = { dev = 1, enne = 2 }
    if cp then opts.pin_counterpart = { ["origin/dev"] = 1 } end
    local main = columns.layout(opts, display)
    local didx, lane_main, node_col, edge = {}, {}, {}, {}
    for i, it in ipairs(display) do
        local c = it.commit
        local pl = main[i].parent_lanes
        for _, l in ipairs(pl or {}) do edge[l.begin.hash .. ">" .. l.parent.hash] = { id = l.id, color = l.color } end
        local function reg(x) didx[x] = i; if pl and pl[1] then lane_main[x] = { id = pl[1].id, color = pl[1].color } end end
        if c then
            reg((c.tip and c.tip.hash) or c.hash)
            if c.tip then reg(c.tip.hash) end
            for _, rh in ipairs(c.region or {}) do reg(rh) end
        end
        for j, cell in ipairs(main[i].columns or {}) do
            if cell.has_commit and cell.commit then node_col[cell.commit.hash] = j end
        end
    end
    local function order_of(n) return n and didx[(n.tip and n.tip.hash) or n.hash] end
    -- With `p`, the lane of the EDGE n → p, as window.lua's lane_of (§6.2 Colour).
    local function lane_of(n, p)
        if not n then return nil end
        return (p and edge[n.hash .. ">" .. p.hash]) or lane_main[(n.tip and n.tip.hash) or n.hash]
    end
    local function col_of(n) return n and node_col[(n.tip and n.tip.hash) or n.hash] end
    local function dnode_of(hash)
        for _, it in ipairs(display) do
            local c = it.commit
            if c then
                if c.hash == hash or (c.tip and c.tip.hash == hash) then return c end
                for _, rh in ipairs(c.region or {}) do if rh == hash then return c end end
            end
        end
    end
    return { display = display, main = main, refs = refs, pinned = pinned, opts = opts, didx = didx,
        order_of = order_of, lane_of = lane_of, col_of = col_of, dnode_of = dnode_of }
end

-- Build the header at cutoff `si` and return the rendered lane id of each named anchor.
local function header_anchor_ids(ctx, si)
    local line = (ctx.main[si].above or {})[1] or ctx.main[si].columns
    local boundary = pane.boundary_of(line, true)
    if not next(boundary) then return {} end
    local tips = {}
    for name in pairs(ctx.pinned) do
        local r = ctx.refs[name]
        local dn = r and r.commit and ctx.dnode_of(r.commit.hash)
        if dn and (ctx.order_of(dn) or math.huge) < si then tips[#tips + 1] = dn end
    end
    local cond = pane.continue_up(boundary, tips, ctx.pinned, ctx.order_of, si, nil, ctx.lane_of)
    local res = pane.header(cond.items, boundary, cond.node_of_hash, ctx.lane_of, ctx.col_of)
    local ids = {}
    for _, r in ipairs(res.rows) do
        for _, cell in ipairs(r.columns or {}) do
            if cell.has_commit and cell.commit and cell.commit.refs then
                for _, rf in ipairs(cell.commit.refs) do
                    if (rf.name == "HEAD" or rf.name == "dev") and ids[rf.name] == nil then
                        ids[rf.name] = cell.id
                    end
                end
            end
        end
    end
    return ids
end

-- The header does NOT lay itself out with `columns.layout` (it is the direct
-- seam-up grid), but the MAIN view it takes its cutoffs and lane ids from does —
-- so the layout policy (§5.6) still changes its input. The anchor-severing
-- invariant must hold whichever policy laid the main graph out.
--
-- `gutter` gets a DIFFERENT oracle, and the reason is worth stating because it is a
-- property of that policy rather than a weakening. `spawn_lanes` gives a commit's
-- first parent the id and colour of its **leftmost incoming** lane (§5), so at a
-- commit with several children *which child's colour continues* is decided by column
-- order — and `gutter` deliberately changes column order, keeping the branch being
-- read in the fixed column (§5.6). The chain reaching an anchor's tip is therefore
-- not always the same lane id that crosses a given cutoff, so "the anchor's tip lane
-- id" stops being the right oracle there. What must still hold — and is what this
-- test was written to catch — is that the header never INVENTS a lane: the id it
-- renders must be one that genuinely exists in the main view, not a fresh synthetic
-- one minted because the anchor's lane was severed.
local LOOSE_ORACLE = { gutter = true }

--- Every lane id present anywhere in the main view.
local function main_ids(ctx)
    local ids = {}
    for _, row in ipairs(ctx.main) do
        for _, ln in ipairs(h.row_lines(row)) do
            do
                for _, cell in ipairs(ln.line) do
                    for _, sg in ipairs(cell.lanes or {}) do ids[sg.id] = true end
                end
            end
        end
    end
    return ids
end

for _, policy in ipairs({ "compact", "survivors", "linear", "straight", "gutter" }) do
describe("large real-world header replay [" .. policy .. "] (§6.2)", function()
    it("keeps HEAD and dev on a real graph lane id at every cutoff (no fresh-id severing)", function()
        local ctx = build(policy)
        local head_lane = ctx.lane_of(ctx.dnode_of(fix.head))
        local dev_lane = ctx.lane_of(ctx.dnode_of(fix.dev))
        if not head_lane then error("HEAD must have a main-view lane") end
        local loose = LOOSE_ORACLE[policy]
        local real = loose and main_ids(ctx) or nil
        local function ok(id, lane)
            if loose then return real[id] == true end
            return lane == nil or id == lane.id
        end
        local bad = {}
        for si = 2, #ctx.display do
            local ids = header_anchor_ids(ctx, si)
            -- A pinned anchor that appears must render on a real graph lane id — never a
            -- fresh synthetic id (which means its lane was severed at a merge/cutoff).
            if ids.HEAD ~= nil and not ok(ids.HEAD, head_lane) then
                bad[#bad + 1] = ("si=%d HEAD id=%s (graph %s)"):format(si, tostring(ids.HEAD), tostring(head_lane.id))
            end
            if ids.dev ~= nil and not ok(ids.dev, dev_lane) then
                bad[#bad + 1] = ("si=%d dev id=%s (graph %s)")
                    :format(si, tostring(ids.dev), tostring(dev_lane and dev_lane.id))
            end
        end
        assert.equals(0, #bad,
            "anchors severed onto a fresh id at:\n  " .. table.concat(bad, "\n  ", 1, math.min(#bad, 12)))
    end)
end)
end

-- §6.2 Colour over the whole real topology: every header lane is drawn in the colour
-- the main view gives that lane id, and every node in its main-view node colour. With
-- a palette large enough that no two lanes the header shows together share a colour,
-- nothing is ever de-collided, so the expected count is exactly 0. Guards three bugs:
-- heads never alive together recoloured apart, a fork child reached through a merge's
-- second parent coloured by its first-parent lane, and that wrong colour then moved.
local render = require("gitloom.graph.render")
local function colour_mismatches(ctx)
    local idcol = {}
    for _, row in ipairs(ctx.main) do
        for _, l in ipairs(row.parent_lanes or {}) do idcol[l.id] = l.color end
    end
    local segs, nodes, where = 0, 0, {}
    for si = 2, #ctx.display do
        local line = (ctx.main[si].above or {})[1] or ctx.main[si].columns
        local boundary = pane.boundary_of(line, true)
        if next(boundary) then
            local tips = {}
            for name in pairs(ctx.pinned) do
                local r = ctx.refs[name]
                local dn = r and r.commit and ctx.dnode_of(r.commit.hash)
                if dn and (ctx.order_of(dn) or math.huge) < si then tips[#tips + 1] = dn end
            end
            local cond = pane.continue_up(boundary, tips, ctx.pinned, ctx.order_of, si, nil, ctx.lane_of)
            local avoid = columns.pinned_slots(ctx.opts.pin_rank, #ctx.opts.palette.tracks)
            local res = pane.header(cond.items, boundary, cond.node_of_hash, ctx.lane_of, ctx.col_of, avoid)
            for _, r in ipairs(res.rows) do
                for _, cell in ipairs(r.columns or {}) do
                    for _, sg in ipairs(cell.lanes or {}) do
                        if idcol[sg.id] ~= nil and idcol[sg.id] ~= sg.color then
                            segs = segs + 1; where[#where + 1] = ("si=%d seg id=%s"):format(si, tostring(sg.id))
                        end
                    end
                    if cell.has_commit and cell.commit then
                        local i = ctx.didx[(cell.commit.tip and cell.commit.tip.hash) or cell.commit.hash]
                        local ms = i and render.node_lane_slot(ctx.main[i].columns, nil, nil)
                        if ms ~= nil and ms ~= render.node_lane_slot(r.columns, nil, cell.commit) then
                            nodes = nodes + 1; where[#where + 1] = ("si=%d node %s"):format(si, cell.commit.hash)
                        end
                    end
                end
            end
        end
    end
    return segs, nodes, where
end

describe("large real-world header replay — colours follow the main view (§6.2 Colour)", function()
    for _, cfg in ipairs({ { "compact" }, { "survivors" }, { "linear" }, { "straight" }, { "gutter" },
        { "compact", true }, { "compact", false, true }, { "gutter", false, true },
        { "compact", true, true } }) do
        local policy, small, cp = cfg[1], cfg[2], cfg[3]
        it(("[%s%s%s] no header lane or node off its main-view colour"):format(policy,
                small and ", 6 colours" or "", cp and ", counterpart birth" or ""),
            function()
                local segs, nodes, where = colour_mismatches(build(policy, small, cp))
                assert.equals(0, segs, table.concat(where, "\n  ", 1, math.min(#where, 12)))
                -- Under `gutter` a head reached ONLY through a merge's second parent
                -- draws that edge's lane, while the main view colours its node by its
                -- first-parent lane (not drawn in the header): node colour then differs.
                if policy ~= "gutter" then
                    assert.equals(0, nodes, table.concat(where, "\n  ", 1, math.min(#where, 12)))
                end
            end)
    end
end)
