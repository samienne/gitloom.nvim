-- Footer over a **sliding screen-row window** (spec §6.2). The whole class of footer
-- bugs comes from mixing three coordinate spaces: REAL buffer lines (`line('w0')`,
-- `line('w$')` — one per display item), DISPLAY indices (what `footer_seam` walks), and
-- SCREEN rows (what the user sees — real columns lines PLUS the virtual `split`/`merge`
-- fan lines). A virtual line takes a screen row but no real buffer line, so `line('w$')`
-- cannot address it, and the footer's seam/height (derived from display indices) can
-- drift from the true screen rows.
--
-- This test builds the anonymised gitloom `--all` topology, runs the FULL production
-- projection (view.owners → project → refresh_columns → pack_markers) so the display has
-- real split/merge virtual lines, then builds the exact `pane.screen_lines` screen model.
-- It slides a window bottom down EVERY screen row (columns, split AND merge) and, for
-- each, builds the footer the way production does and asserts the overlay butts the seam
-- with no gap/overlap — reproducing the virtual-line misalignment.
local pane = require("gitloom.graph.pane")
local view = require("gitloom.graph.view")
local graph = require("gitloom.graph")
local fix = require("tests.large_topo")
local h = require("tests.graph_helpers")
local refresh_columns = graph.refresh_columns
local pack_markers = graph.pack_markers

-- Project + lay out + pack exactly like production reflow, so the display carries real
-- virtual split/merge lines. Returns the display, an order-index map (hash → raw commit
-- index, for continue), the refs, pinned set and opts.
local function build()
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
    local opts = h.big_opts() -- split_on_separate_line = true → produces the virtual split lines
    local proj = view.project(items, view.owners(items, ofr(), pinned, {}, true), nil)
    refresh_columns(opts, proj.items)
    local display = pack_markers(proj.items)
    local oidx = {}
    for i, it in ipairs(items) do oidx[it.commit.hash] = i end
    return { display = display, oidx = oidx, refs = refs, pinned = pinned, opts = opts }
end

local function item_order(oidx, item)
    local c = item and item.commit
    if c then return oidx[(c.tip and c.tip.hash) or c.hash] end
    local m = item and item.markers and item.markers[1]
    if m then return oidx[(m.tip and m.tip.hash) or m.hash] end
end

-- Replicate converge_footer/build_footer: grow the requested cover until the footer
-- content fits, return the final { rows, seam, cover, fheight, terminate }. Works in
-- SCREEN rows: `bs` is the bottom visible screen row (virtual lines included).
local PANE_MAX = 12
local function build_footer(b, sm, bs)
    for cover = 1, PANE_MAX do
        local seam = pane.footer_seam(sm, bs, cover)
        if not seam then return nil, "past top" end
        local line = (seam.kind == "merge") and seam.item.merge or seam.item.columns
        if not line then return nil, "no line" end
        local boundary = pane.boundary_of(line)
        if not next(boundary) then return nil, "no lanes@" .. seam.idx end
        local seam_ord = item_order(b.oidx, seam.item)
        local extra = {}
        if seam_ord then
            for name in pairs(b.pinned) do
                local ref = b.refs[name]
                if ref and ref.commit and (b.oidx[ref.commit.hash] or 0) > seam_ord then
                    extra[#extra + 1] = ref.commit
                end
            end
        end
        local cond = pane.continue(boundary, b.pinned, extra, function(n) return b.oidx[n.hash] end)
        if #cond.items == 0 then return nil, "empty@" .. seam.idx end
        local res = pane.footer(b.opts, cond.items, boundary, cond.node_of_hash)
        if #res.rows + 1 <= seam.cover then
            local fheight = math.min(PANE_MAX, math.max(seam.cover, #res.rows + 1))
            return { rows = res.rows, seam = seam, cover = seam.cover, fheight = fheight, terminate = res.terminate }
        end
    end
    return nil, "no converge"
end

describe("pane.screen_lines — the screen-row model (§6.2)", function()
    it("the default rows_of interleaves split/columns/merge with signed virt offsets", function()
        local items = {
            { commit = { hash = "a" } },
            { commit = { hash = "b" }, split = {} },
            { commit = { hash = "c" }, merge = {} },
            { commit = { hash = "d" }, split = {}, merge = {} }, -- both on one commit
        }
        local sm = pane.screen_lines(items)
        -- a:cols(1) | b:above(2),cols(3) | c:cols(4),below(5) | d:above(6),cols(7),below(8)
        assert.equals(8, #sm.lines)
        assert.equals(1, sm.cols[1]); assert.equals(3, sm.cols[2])
        assert.equals(4, sm.cols[3]); assert.equals(7, sm.cols[4])
        local function idkv(sr) return { idx = sm.lines[sr].idx, kind = sm.lines[sr].kind, virt = sm.lines[sr].virt } end
        assert.same({ idx = 2, kind = "above", virt = -1 }, idkv(2))
        assert.same({ idx = 3, kind = "below", virt = 1 }, idkv(5))
        assert.same({ idx = 4, kind = "above", virt = -1 }, idkv(6))
        assert.same({ idx = 4, kind = "columns", virt = 0 }, idkv(7))
        assert.same({ idx = 4, kind = "below", virt = 1 }, idkv(8))
        assert.equals(items[4], sm.lines[7].item)
    end)

    it("supports MULTIPLE virtual rows above and below (count-based, not boolean)", function()
        -- Item 2 renders 2 rows above + 3 below; item 3 has a dual-mode 2-row columns block.
        local items = { { commit = { hash = "a" } }, { commit = { hash = "b" } }, { commit = { hash = "c" } } }
        local counts = { [2] = { above = 2, height = 1, below = 3 }, [3] = { above = 0, height = 2, below = 0 } }
        local sm = pane.screen_lines(items, function(it)
            local i = it.commit.hash == "a" and 1 or (it.commit.hash == "b" and 2 or 3)
            return counts[i]
        end)
        -- a:cols(1) | b: above(2,3) cols(4) below(5,6,7) | c: cols(8) cols(9)
        assert.equals(9, #sm.lines)
        assert.equals(1, sm.cols[1]); assert.equals(4, sm.cols[2]); assert.equals(8, sm.cols[3])
        -- the two above rows are farthest→nearest the columns (virt -2 then -1)
        assert.same({ idx = 2, kind = "above", virt = -2 }, { idx = sm.lines[2].idx, kind = sm.lines[2].kind, virt = sm.lines[2].virt })
        assert.same({ idx = 2, kind = "above", virt = -1 }, { idx = sm.lines[3].idx, kind = sm.lines[3].kind, virt = sm.lines[3].virt })
        -- the three below rows count up +1..+3
        assert.equals(1, sm.lines[5].virt); assert.equals(2, sm.lines[6].virt); assert.equals(3, sm.lines[7].virt)
        -- the dual-mode item's two columns rows are both virt 0
        assert.equals(0, sm.lines[8].virt); assert.equals(0, sm.lines[9].virt)
        assert.equals("columns", sm.lines[8].kind); assert.equals("columns", sm.lines[9].kind)
    end)
end)

-- A faithful window over the SCREEN model. A window is a contiguous slice of screen
-- rows `[ts, bs_true]` (ts = the top visible screen row). Crucially `ts` may be a virtual
-- **split** row of the top item — with its columns line just below — reproducing the real
-- nvim scroll where `line('w0')` names the item but its split renders ABOVE its columns.
-- We simulate the real screen frame with the window top at absolute screen row 1, so real
-- row of model row `M` = `M - ts + 1`. This lets us feed `footer_bs` the exact
-- (anchor_real, win_bottom_real) production reads from `screenpos`, and check it against
-- the independent ground truth `bs_true` — NOT against footer_seam's own algebra.
describe("footer window → bottom screen row (the virtual-lines-above-w0 bug) (§6.2)", function()
    it("the fixture actually exercises virtual lines", function()
        local b = build()
        local nsplit = 0
        for _, it in ipairs(b.display) do if it.split or it.merge then nsplit = nsplit + 1 end end
        assert.is_true(nsplit > 0, "projection produced no virtual split/merge lines")
    end)

    it("footer_bs returns the TRUE window bottom, incl. when w0's split sits above its columns", function()
        local b = build()
        local sm = pane.screen_lines(b.display)
        local total = #sm.lines
        local ndisp = #b.display
        local bad, split_top_cases, naive_wrong = {}, 0, 0
        -- Sweep every display item as the top item `w0`, with the window top `ts` landing
        -- either on w0's own columns line OR on its split row (a virtual line ABOVE the
        -- columns — the bug scenario).
        for w0 = 1, ndisp do
            local w0cols = sm.cols[w0]
            local has_split = w0cols > 1 and sm.lines[w0cols - 1].idx == w0 and sm.lines[w0cols - 1].kind == "above"
            local tops = has_split and { w0cols - 1, w0cols } or { w0cols }
            for _, ts in ipairs(tops) do
                for _, wh in ipairs({ 8, 15, 25 }) do
                    local visible = math.min(wh, total - ts + 1)
                    local bs_true = ts + visible - 1
                    if bs_true < total then -- off-screen-older content below → footer warranted
                        -- Real screen frame: window top at absolute row 1.
                        local anchor_real = w0cols - ts + 1 -- w0's columns real screen row (screenpos)
                        local win_bottom_real = visible      -- 1 + visible - 1
                        local bs = pane.footer_bs(sm, w0, anchor_real, win_bottom_real)
                        if bs ~= bs_true then
                            bad[#bad + 1] = ("w0=%d ts=%d wh=%d: footer_bs=%d, true=%d")
                                :format(w0, ts, wh, bs, bs_true)
                        end
                        -- Document the bug: the OLD formula `cols[w0] + visible - 1`
                        -- overshoots exactly when a virtual line sits above w0's columns.
                        if ts < w0cols then
                            split_top_cases = split_top_cases + 1
                            local bs_naive = w0cols + visible - 1
                            if bs_naive ~= bs_true then naive_wrong = naive_wrong + 1 end
                        end
                    end
                end
            end
        end
        assert.equals(0, #bad,
            ("%d wrong; first few:\n  "):format(#bad) .. table.concat(bad, "\n  ", 1, math.min(#bad, 15)))
        assert.is_true(split_top_cases > 0, "never exercised a split-above-columns window top")
        assert.is_true(naive_wrong > 0, "the naive cols[w0]+wh-1 formula was never wrong — bug not reproduced")
    end)

    it("with the correct bottom, the footer seam commit is FULLY VISIBLE (not covered)", function()
        local b = build()
        local sm = pane.screen_lines(b.display)
        local total = #sm.lines
        local ndisp = #b.display
        local bad = {}
        for w0 = 1, ndisp do
            local w0cols = sm.cols[w0]
            local has_split = w0cols > 1 and sm.lines[w0cols - 1].idx == w0 and sm.lines[w0cols - 1].kind == "above"
            local tops = has_split and { w0cols - 1, w0cols } or { w0cols }
            for _, ts in ipairs(tops) do
                for _, wh in ipairs({ 10, 20 }) do
                    local visible = math.min(wh, total - ts + 1)
                    local bs_true = ts + visible - 1
                    if bs_true < total then
                        local anchor_real = w0cols - ts + 1
                        local bs = pane.footer_bs(sm, w0, anchor_real, visible)
                        local f = build_footer(b, sm, bs)
                        if f then
                            -- The seam commit's block must lie entirely within the visible,
                            -- NON-overlay region: its top screen row ≥ ts (on screen) and its
                            -- bottom = overlay_top - 1 (butts the overlay, above it).
                            local seam_top = sm.cols[f.seam.idx] - (f.seam.item.split and 1 or 0)
                            local overlay_top = bs - f.fheight + 1
                            if seam_top < ts then
                                bad[#bad + 1] = ("w0=%d ts=%d wh=%d: seam %d top=%d scrolled above ts")
                                    :format(w0, ts, wh, f.seam.idx, seam_top)
                            elseif f.seam.seam_bottom >= overlay_top then
                                bad[#bad + 1] = ("w0=%d ts=%d wh=%d: seam %d bottom=%d covered by overlay(top=%d)")
                                    :format(w0, ts, wh, f.seam.idx, f.seam.seam_bottom, overlay_top)
                            end
                        end
                    end
                end
            end
        end
        assert.equals(0, #bad,
            ("%d bad; first few:\n  "):format(#bad) .. table.concat(bad, "\n  ", 1, math.min(#bad, 15)))
    end)
end)
