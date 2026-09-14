--- Cell-for-cell parity harness for the interned signature sets
--- (`gitloom.graph.sigset`): the rendered graph must be unchanged.
---
--- Both sides run in this process. One takes the interned path; the other feeds
--- `view.project` a plain table of sets built by the **reference** pass
--- (`tests.graph_helpers.reference_signatures`, a direct transcription of §10.2's
--- definition — no sharing, no memoisation), which makes `view.project` take its
--- pre-interning path. So this compares two implementations, not one with itself.
---
--- Compared per rendered **Line** (a commit's columns plus its virtual split/merge
--- rows): every column's connectivity, lane id, palette slot, node flag and
--- `own_lane_up`, every Segment's id, colour, connectivity and endpoints, and the
--- row's parent/child lanes.
---
---   nvim --headless -u tests/minimal_init.lua -c "lua require('bench.parity').main()" -c qa
---
--- NOT part of the plugin.
local h = require("tests.graph_helpers")
local view = require("gitloom.graph.view")
local columns = require("gitloom.graph.columns")
local topo = require("bench.topo")

local M = {}

local STYLES = {
    { name = "split-line", s = { merge_on_separate_line = false, split_on_separate_line = true } },
    { name = "merge-line", s = { merge_on_separate_line = true, split_on_separate_line = false } },
    { name = "mergesplit", s = { merge_on_separate_line = true, split_on_separate_line = true } },
    { name = "inline",     s = { merge_on_separate_line = false, split_on_separate_line = false } },
    { name = "inline-mos", s = { allow_merge_on_split = true } },
}
local POLICIES = { "compact", "survivors", "linear", "straight", "gutter" }

local function nlines(r) return 1 + #(r.above or {}) + (r.merge and 1 or 0) end

--- A corpus entry builds a fresh `items` list plus its ref owners each time (the
--- projection mutates nothing, but `columns.layout` attaches lanes to the rows).
---@param rows table[]
---@param tips table<string,string>?  -- ref name -> commit hash; nil = every childless commit
---@return fun(): table[], table[], table<string,boolean>
local function fixture(rows, tips)
    return function()
        local items = h.dag(rows)
        local by = {}
        for _, it in ipairs(items) do by[it.commit.hash] = it.commit end
        local ro, pinned = {}, {}
        if tips then
            for name, hash in pairs(tips) do
                local c = by[hash]
                if c then
                    c.refs = c.refs or {}
                    c.refs[#c.refs + 1] = { name = name, kind = "local" }
                    ro[#ro + 1] = { id = name, tip = c, mode = "normal" }
                end
            end
            table.sort(ro, function(a, b) return a.id < b.id end)
            if ro[1] then pinned[ro[1].id] = true end
        else
            for i, it in ipairs(items) do
                if #(it.commit.children or {}) == 0 then
                    local id = "r" .. i
                    it.commit.refs = it.commit.refs or {}
                    it.commit.refs[#it.commit.refs + 1] = { name = id, kind = "local" }
                    ro[#ro + 1] = { id = id, tip = it.commit, mode = "normal" }
                    if #ro == 1 then pinned[id] = true end
                end
            end
        end
        return items, ro, pinned
    end
end

--- Turn a generated Commit list (bench.topo) into a `h.dag`-compatible spec.
local function topo_rows(spec)
    local built = topo.build(spec)
    local rows, tips = {}, {}
    -- newest-first: the generator emits trunk tip .. root then the branches, so
    -- sort by the epoch it stamped (descending = newest first).
    local cs = {}
    for _, c in ipairs(built.commits) do cs[#cs + 1] = c end
    table.sort(cs, function(a, b) return a.cepoch > b.cepoch end)
    for _, c in ipairs(cs) do
        local ps = {}
        for _, p in ipairs(c.parents) do ps[#ps + 1] = p.hash end
        rows[#rows + 1] = { c.hash, ps }
    end
    for name, r in pairs(built.refs) do
        if r.kind ~= "head" then tips[name] = r.commit.hash end
    end
    return rows, tips
end

function M.corpus()
    local out = {}
    local lt = require("tests.large_topo")
    local ltips = { HEADbranch = lt.head, dev = lt.dev }
    for _, r in ipairs(lt.refs) do ltips[r.name] = r.commit end
    out[#out + 1] = { name = "large_topo (real --all)", make = fixture(lt.dag, ltips) }

    for _, spec in ipairs({
        { name = "merge-trunk 400 b1", trunk = 400, merge_every = 1, branch_len = 1, refs = 40 },
        { name = "merge-trunk 250 b2", trunk = 250, merge_every = 1, branch_len = 2, refs = 40 },
        { name = "sparse 1/4 N600", trunk = 480, merge_every = 4, branch_len = 1, refs = 40 },
        { name = "sparse 1/12 N600", trunk = 555, merge_every = 12, branch_len = 1, refs = 40 },
    }) do
        local rows, tips = topo_rows(spec)
        out[#out + 1] = { name = spec.name, make = fixture(rows, tips) }
    end

    for seed = 1, 60 do
        out[#out + 1] = { name = "fuzz60 " .. seed, make = fixture(h.random_dag(60, seed)) }
    end
    return out
end

--- Run the whole matrix; returns (lines compared, differing lines, first diff).
function M.run()
    local lines, diff, first = 0, 0, nil
    for _, case in ipairs(M.corpus()) do
        for _, cm in ipairs({ true, false }) do
            for _, st in ipairs(STYLES) do
                for _, pol in ipairs(POLICIES) do
                    local opts = h.big_opts(st.s)
                    opts.layout_policy = pol

                    local ai, aro, apin = case.make()
                    local ao = view.owners(ai, aro, apin, {}, cm)
                    local a = columns.layout(opts, view.project(ai, ao).items)

                    local bi, bro, bpin = case.make()
                    local bo = view.owners(bi, bro, bpin, {}, cm)
                    local b = columns.layout(opts, view.project(bi, bo,
                        h.reference_signatures(bi, bo)).items)

                    if #a ~= #b then
                        diff = diff + math.abs(#a - #b)
                        first = first or ("%s cm=%s %s/%s: %d vs %d rows")
                            :format(case.name, tostring(cm), st.name, pol, #a, #b)
                    else
                        for i = 1, #a do
                            lines = lines + nlines(a[i])
                            if h.row_sig(a[i]) ~= h.row_sig(b[i]) then
                                diff = diff + 1
                                first = first or ("%s cm=%s %s/%s row %d\n  interned: %s\n  reference: %s")
                                    :format(case.name, tostring(cm), st.name, pol, i,
                                        h.row_sig(a[i]), h.row_sig(b[i]))
                            end
                        end
                    end
                end
            end
        end
    end
    return lines, diff, first
end

function M.main()
    local lines, diff, first = M.run()
    print(("parity: %d rendered Lines compared across %d corpora x 2 projections x %d styles x %d policies — %d differing")
        :format(lines, #M.corpus(), #STYLES, #POLICIES, diff))
    if first then print("first difference:\n" .. first) end
end

return M
