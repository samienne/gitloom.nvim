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
local function build(policy)
    local items = h.dag(fix.dag)
    local byhash = {}
    for _, it in ipairs(items) do byhash[it.commit.hash] = it.commit end
    local refs = {
        enne = { name = "enne", kind = "local", commit = byhash[fix.head] }, -- HEAD's branch
        HEAD = { name = "HEAD", kind = "head", commit = byhash[fix.head] },
        dev = { name = "dev", kind = "local", commit = byhash[fix.dev] },
    }
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
    local proj = view.project(items, view.owners(items, ofr(), pinned, {}, true), nil)
    local display = proj.items
    local opts = h.big_opts()
    opts.layout_policy = policy
    local main = columns.layout(opts, display)
    local didx, lane_main, node_col = {}, {}, {}
    for i, it in ipairs(display) do
        local c = it.commit
        local pl = main[i].parent_lanes
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
    local function lane_of(n) return n and lane_main[(n.tip and n.tip.hash) or n.hash] end
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
    return { display = display, main = main, refs = refs, pinned = pinned, opts = opts,
        order_of = order_of, lane_of = lane_of, col_of = col_of, dnode_of = dnode_of }
end

-- Build the header at cutoff `si` and return the rendered lane id of each named anchor.
local function header_anchor_ids(ctx, si)
    local line = ctx.main[si].split or ctx.main[si].columns
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
for _, policy in ipairs({ "compact", "survivors", "linear", "straight", "gutter" }) do
describe("large real-world header replay [" .. policy .. "] (§6.2)", function()
    it("keeps HEAD and dev on their graph lane id at every cutoff (no fresh-id severing)", function()
        local ctx = build(policy)
        local head_lane = ctx.lane_of(ctx.dnode_of(fix.head))
        local dev_lane = ctx.lane_of(ctx.dnode_of(fix.dev))
        assert.is_not_nil(head_lane, "HEAD must have a main-view lane")
        local bad = {}
        for si = 2, #ctx.display do
            local ids = header_anchor_ids(ctx, si)
            -- A pinned anchor that appears must render on its OWN graph lane id — never a
            -- fresh synthetic id (which means its lane was severed at a merge/cutoff).
            if ids.HEAD ~= nil and head_lane and ids.HEAD ~= head_lane.id then
                bad[#bad + 1] = ("si=%d HEAD id=%s (graph %s)"):format(si, tostring(ids.HEAD), tostring(head_lane.id))
            end
            if ids.dev ~= nil and dev_lane and ids.dev ~= dev_lane.id then
                bad[#bad + 1] = ("si=%d dev id=%s (graph %s)"):format(si, tostring(ids.dev), tostring(dev_lane.id))
            end
        end
        assert.equals(0, #bad,
            "anchors severed onto a fresh id at:\n  " .. table.concat(bad, "\n  ", 1, math.min(#bad, 12)))
    end)
end)
end
