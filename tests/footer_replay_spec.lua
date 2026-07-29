--- Replay a large real-world repository topology (anonymised — synthetic ids only;
--- see tests/large_topo.lua) through the FULL footer pipeline at EVERY cutoff, and —
--- crucially — for EVERY rendered line the production seam picker can land on
--- (a commit's `columns` line OR its virtual `split`/`merge` fan lines). This is the
--- footer counterpart of header_replay_spec: it feeds the footer the SAME realistic
--- projected boundaries the live view produces, so a footer that mishandles a
--- virtual-line seam (the class of bug the header's pure `header_seam` fixed) is caught
--- here instead of only in production.
---
--- For each (cutoff, seam line) it asserts:
---   • seam match — the footer's TOP row reproduces the seam line's down-lanes in the
---     SAME column with the SAME id (so the footer butts against the main view with no
---     jog — the discontinuity symptom);
---   • no dangle — an uncapped footer strands NO crossing lane (empty `terminate`);
---   • id-continuity — a lane's id is unbroken down every rendered row.
local pane = require("gitloom.graph.pane")
local columns = require("gitloom.graph.columns")
local view = require("gitloom.graph.view")
local fix = require("tests.large_topo")
local h = require("tests.graph_helpers")

-- Build the projected display + main layout ONCE (cutoff-independent), like the
-- header replay. Returns the display, the main layout, a hash→order index, the
-- pinned set, the refs, and opts.
local function build(policy)
    local items = h.dag(fix.dag)
    local byhash = {}
    for _, it in ipairs(items) do byhash[it.commit.hash] = it.commit end
    local refs = {
        enne = { name = "enne", kind = "local", commit = byhash[fix.head] },
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
    local pinned = { enne = true, dev = true }
    local proj = view.project(items, view.owners(items, ofr(), pinned, {}, true), nil)
    local display = proj.items
    local opts = h.big_opts()
    opts.layout_policy = policy
    local main = columns.layout(opts, display)
    -- hash → order index (for continue's order_of and the `extra` pinned tips).
    local idx = {}
    for i, it in ipairs(display) do
        local c = it.commit
        if c then
            idx[(c.tip and c.tip.hash) or c.hash] = i
            if c.tip then idx[c.tip.hash] = i end
            for _, rh in ipairs(c.region or {}) do idx[rh] = i end
        end
    end
    return { display = display, main = main, refs = refs, pinned = pinned, opts = opts, idx = idx }
end

-- Flatten a footer row's rendered lines top-to-bottom (above..., columns, merge).
local function lines_of(rows)
    local out = {}
    for _, r in ipairs(rows) do
        for _, ln in ipairs(h.row_lines(r)) do out[#out + 1] = ln.line end
    end
    return out
end

-- Vertical id-continuity: a cell's up-lane id must equal the down-lane id directly
-- above it. Returns a problem string or nil.
local function continuity_problem(rows, ctx)
    local lines = lines_of(rows)
    local function up_id(c) for _, s in ipairs(c.lanes or {}) do if s.connectivity.up then return s.id end end end
    local function down_id(c) for _, s in ipairs(c.lanes or {}) do if s.connectivity.down then return s.id end end end
    for i = 1, #lines - 1 do
        for col, cell in ipairs(lines[i + 1]) do
            local above = lines[i][col]
            if cell.connectivity.up and above and above.connectivity.down then
                local u, d = up_id(cell), down_id(above)
                if u ~= d then
                    return ("%s: id discontinuity at line %d col %d (%s over %s)"):format(
                        ctx, i + 1, col, tostring(u), tostring(d))
                end
            end
        end
    end
end

-- Build the footer for one seam line and check the invariants; append problems.
local function check_seam(b, seam_line, ctx, bad)
    local boundary = pane.boundary_of(seam_line)
    if not next(boundary) then return end
    -- pinned tips below the cutoff (like build_footer's `extra`)
    local seam_idx
    for _, lane in pairs(boundary) do
        if lane.begin then seam_idx = b.idx[lane.begin.hash]; break end
    end
    local extra = {}
    if seam_idx then
        for name in pairs(b.pinned) do
            local ref = b.refs[name]
            if ref and ref.commit and (b.idx[ref.commit.hash] or 0) > seam_idx then
                extra[#extra + 1] = ref.commit
            end
        end
    end
    local cond = pane.continue(boundary, b.pinned, extra, function(n) return b.idx[n.hash] end)
    if #cond.items == 0 then return end
    local res = pane.footer(b.opts, cond.items, boundary, cond.node_of_hash)

    -- 1. seam match — every seam down-lane appears at footer row 1, same column, up, same id.
    local top = res.rows[1] and res.rows[1].columns or {}
    for col, lane in pairs(boundary) do
        local cell = top[col]
        local found
        for _, s in ipairs(cell and cell.lanes or {}) do
            if s.connectivity.up and s.id == lane.id then found = true end
        end
        if not found then
            bad[#bad + 1] = ("%s: seam lane id %s missing at row 1 col %d (footer top row does not match the seam)")
                :format(ctx, tostring(lane.id), col)
        end
    end
    -- 2. no dangle
    if next(res.terminate) ~= nil then
        bad[#bad + 1] = ctx .. ": a crossing lane stranded at the seam (non-empty terminate)"
    end
    -- 3. id-continuity
    local cp = continuity_problem(res.rows, ctx)
    if cp then bad[#bad + 1] = cp end
end

-- The footer threads ONE shared `opts` into both `columns.layout` (the main view)
-- and `pane.footer` (the seeded pane), so it picks the layout policy (§5.6) up for
-- free. The seam CONTRACT is policy-independent — every seeded lane keeps its
-- seeded column — even though the chain that satisfies it is not always the same
-- one: four policies share `layout_seam`, while `gutter` is its own seam (that
-- chain moves no lane either, and it is the only one that also keeps the seam row's
-- node in the gutter, so the pane's first row agrees with its body). So the whole
-- replay must hold, at every cutoff, under every policy.
for _, policy in ipairs({ "compact", "survivors", "linear", "straight", "gutter" }) do
describe("large real-world footer replay [" .. policy .. "] (§6.2)", function()
    it("every seam line — columns AND virtual split/merge — lays out with no strand/jog", function()
        local b = build(policy)
        local bad = {}
        for si = 1, #b.display - 1 do
            local row = b.main[si]
            local hash = row.columns and row.columns[1] -- just for context labelling
            -- Each rendered line of the block is a candidate seam the live picker can land on.
            check_seam(b, row.columns, ("si=%d columns"):format(si), bad)
            if row.merge then check_seam(b, row.merge, ("si=%d merge"):format(si), bad) end
            for k, l in ipairs(row.above or {}) do
                check_seam(b, l, ("si=%d above%d"):format(si, k), bad)
            end
        end
        assert.equals(0, #bad,
            "footer replay problems:\n  " .. table.concat(bad, "\n  ", 1, math.min(#bad, 15)))
    end)
end)
end
