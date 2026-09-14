--- Synthetic commit-DAG generator for the open-path profiler (`bench/profile.lua`).
--- NOT part of the plugin: it builds Commit graphs of a chosen *shape* so the
--- projection pipeline can be priced as a function of merge density and N,
--- independently of any real repository.
local M = {}

--- Build a trunk of `trunk` commits where every `merge_every`-th one merges in a
--- side branch of `branch_len` commits, and hand out `refs` branch refs across
--- the side-branch tips (plus HEAD/master on the trunk tip).
---
--- The merged branch forks from the trunk commit immediately below its merge, so
--- its first-parent chain rejoins the trunk — the shape that makes a
--- first-parent-only owner (§10.7) flow onto the trunk and down to the root.
---@param o { trunk:integer, merge_every:integer, branch_len:integer, refs:integer }
---@return { commits:table[], refs:table<string,table>, nmerges:integer }
function M.build(o)
    local trunk, every = o.trunk, o.merge_every
    local blen, nrefs = o.branch_len, o.refs
    local all = {}
    local epoch = 1000000
    local function mk(hash)
        local c = { hash = hash, parents = {}, children = {}, refs = {},
            author = "a", message = hash, cepoch = epoch, loaded = true }
        epoch = epoch - 1
        all[#all + 1] = c
        return c
    end
    -- t[1] = tip (newest), t[trunk] = root.
    local t = {}
    for i = 1, trunk do t[i] = mk(string.format("t%06d", i)) end
    local function link(child, parent)
        child.parents[#child.parents + 1] = parent
        parent.children[#parent.children + 1] = child
    end
    for i = 1, trunk - 1 do link(t[i], t[i + 1]) end
    local btips = {}
    if every > 0 and blen > 0 then
        for i = 1, trunk - 1, every do
            local b = {}
            for j = 1, blen do b[j] = mk(string.format("b%06d_%02d", i, j)) end
            for j = 1, blen - 1 do link(b[j], b[j + 1]) end
            link(b[blen], t[i + 1]) -- forks off the trunk just below the merge
            link(t[i], b[1])        -- the merge's second parent
            btips[#btips + 1] = b[1]
        end
    end
    local refs = {}
    local head = { name = "HEAD", kind = "head", commit = t[1] }
    refs["HEAD"] = head
    t[1].refs[#t[1].refs + 1] = head
    local master = { name = "master", kind = "local", commit = t[1] }
    refs["master"] = master
    t[1].refs[#t[1].refs + 1] = master
    -- Spread the branch refs over the side-branch tips (newest first).
    local step = math.max(1, math.floor(#btips / math.max(1, nrefs)))
    local made = 0
    for k = 1, #btips, step do
        if made >= nrefs then break end
        made = made + 1
        local name = string.format("topic/%04d", made)
        local r = { name = name, kind = "local", commit = btips[k] }
        refs[name] = r
        btips[k].refs[#btips[k].refs + 1] = r
    end
    return { commits = all, refs = refs, nmerges = #btips }
end

return M
