--- Open-path projection profiler. Prices the completion pass (§10.5) —
--- sort → owners → signatures → project → layout → pack — over synthetic DAGs of
--- a chosen shape, so the cost can be read as a function of merge density and N.
---
---   nvim --headless -u tests/minimal_init.lua -c "lua require('bench.profile').main()" -c qa
---
--- NOT part of the plugin.
local topo = require("bench.topo")
local order = require("gitloom.git.order")
local view = require("gitloom.graph.view")
local graph = require("gitloom.graph")

local M = {}

local function ms(t) return string.format("%8.1f", t * 1000) end

local function now() return vim.uv.hrtime() / 1e9 end

--- Signature statistics: total entries, max size, distinct sets.
local function sigstats(sig, want_keys)
    local total, max, keys = 0, 0, {}
    local nkeys = 0
    for _, s in pairs(sig) do
        local n = 0
        for _ in pairs(s) do n = n + 1 end
        total = total + n
        if n > max then max = n end
        if want_keys then
            local ks = {}
            for k in pairs(s) do ks[#ks + 1] = k end
            table.sort(ks)
            local k = table.concat(ks, ",")
            if not keys[k] then keys[k] = true nkeys = nkeys + 1 end
        end
    end
    return total, max, nkeys
end

--- Run the completion pass once over a generated repo and report the breakdown.
---@param name string
---@param spec table  -- topo.build options
---@param o table?    -- { stats = boolean }
function M.case(name, spec, o)
    o = o or {}
    local built = topo.build(spec)
    local opts = {
        merge_style = "merge_on_separate_line",
        layout_policy = "compact",
        collapse_merged = true,
        pack_markers = true,
        palette = nil,
    }
    collectgarbage("collect")
    local mem0 = collectgarbage("count")

    local t0 = now()
    local sorted = order.order_commits(built.commits)
    local t_sort = now() - t0

    local items = {}
    for i, c in ipairs(sorted) do items[i] = { type = "commit", commit = c } end

    local ref_owners = graph.owners_from_refs(built.refs, {})
    local pinned = { HEAD = true, master = true }
    -- HEAD is skipped by owners_from_refs (it is a symref); master carries it.

    t0 = now()
    local owners = view.owners(items, ref_owners, pinned, {}, true)
    local t_owners = now() - t0

    t0 = now()
    local sig = view.signatures(items, owners, nil)
    local t_sig = now() - t0

    local sig_total, sig_max, sig_keys = 0, 0, 0
    if o.stats ~= false then sig_total, sig_max, sig_keys = sigstats(sig, o.keys) end

    t0 = now()
    local proj = view.project(items, owners, sig, nil, nil)
    local t_proj = now() - t0

    t0 = now()
    graph.refresh_columns(opts, proj.items, nil)
    local t_layout = now() - t0

    t0 = now()
    local display = graph.pack_markers(proj.items)
    local t_pack = now() - t0

    collectgarbage("collect")
    local mem1 = collectgarbage("count")

    local total = t_sort + t_owners + t_sig + t_proj + t_layout + t_pack
    print(string.format(
        "%-26s N=%-6d merges=%-6d owners=%-6d rows=%-6d disp=%-6d | sort%s owners%s sig%s proj%s layout%s pack%s = %s ms  | sigent=%-10d sigmax=%-6d sigsets=%-6d mem=%.0fMB",
        name, #built.commits, built.nmerges, #owners, #items, #display,
        ms(t_sort), ms(t_owners), ms(t_sig), ms(t_proj), ms(t_layout), ms(t_pack),
        ms(total), sig_total, sig_max, sig_keys, (mem1 - mem0) / 1024))
    return {
        name = name, n = #built.commits, merges = built.nmerges, owners = #owners,
        rows = #items, display = #display,
        sort = t_sort, ownersT = t_owners, sig = t_sig, proj = t_proj,
        layout = t_layout, pack = t_pack, total = total,
        sig_total = sig_total, sig_max = sig_max, sig_sets = sig_keys,
        mem = mem1 - mem0,
    }
end

function M.main()
    local cases = {
        -- The owner's shape: an all-merge trunk.
        { "merge-trunk 6500", { trunk = 6500, merge_every = 1, branch_len = 1, refs = 300 } },
        { "merge-trunk 3000", { trunk = 3000, merge_every = 1, branch_len = 1, refs = 300 } },
        { "merge-trunk 1500", { trunk = 1500, merge_every = 1, branch_len = 1, refs = 300 } },
        { "merge-trunk 750", { trunk = 750, merge_every = 1, branch_len = 1, refs = 300 } },
        -- Same N, low merge density.
        { "sparse 1/20 N13000", { trunk = 12350, merge_every = 20, branch_len = 1, refs = 300 } },
        { "sparse 1/8  N13000", { trunk = 11555, merge_every = 8, branch_len = 1, refs = 300 } },
        { "sparse 1/4  N13000", { trunk = 10400, merge_every = 4, branch_len = 1, refs = 300 } },
        { "sparse 1/2  N13000", { trunk = 8667, merge_every = 2, branch_len = 1, refs = 300 } },
        { "linear  N13000", { trunk = 13000, merge_every = 0, branch_len = 0, refs = 300 } },
    }
    for _, c in ipairs(cases) do M.case(c[1], c[2]) end
end

return M
