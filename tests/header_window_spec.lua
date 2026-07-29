-- Header over a **sliding screen-row window** (spec §6.2) — the upward mirror of
-- tests/footer_window_spec.lua. The header's top-edge seam had the SAME class of bug as
-- the footer's bottom: it mixed real buffer lines (`line('w0')` — one per display item),
-- display indices (what the old `header_seam` walked) and SCREEN rows (what the user sees:
-- real columns lines PLUS the virtual `split`/`merge` fan rows). A virtual line takes a
-- screen row but no real buffer line, so `line('w0')` cannot address a split fan rendered
-- ABOVE its columns — and the header's seam (derived from `w0disp`) drifted by that partial
-- row, so the overlay's bottom seam didn't butt the main view's first visible line.
--
-- This builds the anonymised gitloom `--all` topology, runs the FULL production projection
-- (view.owners → project → refresh_columns → pack_markers) so the display has real
-- split/merge virtual lines, then builds `pane.screen_lines`. It slides the window TOP down
-- every screen row (columns AND split), and for each asserts the cursor-anchored
-- `pane.header_ts` names the true top (incl. a split-above-columns top) and the
-- `pane.header_seam` it implies rounds to a whole commit block that is fully visible.
local pane = require("gitloom.graph.pane")
local view = require("gitloom.graph.view")
local graph = require("gitloom.graph")
local fix = require("tests.large_topo")
local h = require("tests.graph_helpers")
local refresh_columns = graph.refresh_columns
local pack_markers = graph.pack_markers

-- Project + lay out + pack exactly like production reflow, so the display carries real
-- virtual split/merge lines. (Identical to footer_window_spec's build; the two window
-- sweeps mirror each other around the same fixture.)
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
    return { display = display }
end

describe("header window → top screen row (the virtual-split-above-w0 bug) (§6.2)", function()
    it("the fixture actually exercises virtual lines", function()
        local b = build()
        local nvirt = 0
        for _, it in ipairs(b.display) do
            if #(it.above or {}) > 0 or it.merge then nvirt = nvirt + 1 end
        end
        assert.is_true(nvirt > 0, "projection produced no virtual split/merge lines")
    end)

    it("header_ts returns the TRUE window top, incl. when w0's split sits above its columns", function()
        local b = build()
        local sm = pane.screen_lines(b.display)
        local total = #sm.lines
        local ndisp = #b.display
        local bad, split_top_cases, naive_wrong = {}, 0, 0
        -- Sweep every display item as the top item `w0`, with the window top `ts` landing
        -- either on w0's own columns line OR on its split row (a virtual line ABOVE the
        -- columns — the bug scenario, where `line('w0')` still names w0 but its split renders
        -- above its columns).
        for w0 = 1, ndisp do
            local w0cols = sm.cols[w0]
            local has_split = w0cols > 1 and sm.lines[w0cols - 1].idx == w0 and sm.lines[w0cols - 1].kind == "above"
            local tops = has_split and { w0cols - 1, w0cols } or { w0cols }
            for _, ts in ipairs(tops) do
                for _, wh in ipairs({ 8, 15, 25 }) do
                    local visible = math.min(wh, total - ts + 1)
                    if ts > 1 then -- off-screen-NEWER content above → header warranted
                        -- Real screen frame: window top at absolute row 1, so w0's columns
                        -- renders at real screen row `w0cols - ts + 1` (what screenpos returns).
                        local anchor_real = w0cols - ts + 1
                        local got = pane.header_ts(sm, w0, anchor_real)
                        if got ~= ts then
                            bad[#bad + 1] = ("w0=%d ts=%d wh=%d: header_ts=%d, true=%d")
                                :format(w0, ts, wh, got, ts)
                        end
                        -- Document the bug: the OLD assumption `ts = cols[w0]` overshoots
                        -- exactly when a virtual split line sits above w0's columns.
                        if ts < w0cols then
                            split_top_cases = split_top_cases + 1
                            if w0cols ~= ts then naive_wrong = naive_wrong + 1 end
                        end
                    end
                end
            end
        end
        assert.equals(0, #bad,
            ("%d wrong; first few:\n  "):format(#bad) .. table.concat(bad, "\n  ", 1, math.min(#bad, 15)))
        assert.is_true(split_top_cases > 0, "never exercised a split-above-columns window top")
        assert.is_true(naive_wrong > 0, "the naive cols[w0] top formula was never wrong — bug not reproduced")
    end)

    it("with the correct top, the header seam commit is FULLY VISIBLE (whole block, not covered)", function()
        local b = build()
        local sm = pane.screen_lines(b.display)
        local total = #sm.lines
        local ndisp = #b.display
        local bad, checked = {}, 0
        for w0 = 1, ndisp do
            local w0cols = sm.cols[w0]
            local has_split = w0cols > 1 and sm.lines[w0cols - 1].idx == w0 and sm.lines[w0cols - 1].kind == "above"
            local tops = has_split and { w0cols - 1, w0cols } or { w0cols }
            for _, ts in ipairs(tops) do
                if ts > 1 then
                    for _, wh in ipairs({ 10, 20 }) do
                        local visible = math.min(wh, total - ts + 1)
                        local bs_true = ts + visible - 1
                        local anchor_real = w0cols - ts + 1
                        local got = pane.header_ts(sm, w0, anchor_real)
                        for cover = 1, math.min(6, visible - 1) do
                            local seam = pane.header_seam(sm, got, cover)
                            if seam then
                                checked = checked + 1
                                -- The overlay covers the top `seam.cover` rows [ts, seam_top-1];
                                -- the seam commit's first rendered line is `seam_top`.
                                if got ~= ts then
                                    bad[#bad + 1] = ("w0=%d ts=%d: header_ts=%d ≠ true top")
                                        :format(w0, ts, got)
                                    -- 1) whole block: the row just above the seam ENDS a commit block
                                    --    (never a partial commit covered by the overlay).
                                elseif sm.lines[seam.seam_top - 1].idx == sm.lines[seam.seam_top].idx then
                                    bad[#bad + 1] = ("w0=%d ts=%d cover=%d: overlay bottom mid-block at %d")
                                        :format(w0, ts, cover, seam.seam_top - 1)
                                    -- 2) the overlay starts exactly at the window top.
                                elseif seam.cover ~= seam.seam_top - ts then
                                    bad[#bad + 1] = ("w0=%d ts=%d cover=%d: cover %d ≠ seam_top(%d)-ts")
                                        :format(w0, ts, cover, seam.cover, seam.seam_top)
                                    -- 3) the seam commit is on-screen (not scrolled off below).
                                elseif seam.seam_top > bs_true then
                                    bad[#bad + 1] = ("w0=%d ts=%d cover=%d: seam %d below window bottom %d")
                                        :format(w0, ts, cover, seam.seam_top, bs_true)
                                end
                            end
                        end
                    end
                end
            end
        end
        assert.equals(0, #bad,
            ("%d bad; first few:\n  "):format(#bad) .. table.concat(bad, "\n  ", 1, math.min(#bad, 15)))
        assert.is_true(checked > 0, "no header seams were checked")
    end)
end)
