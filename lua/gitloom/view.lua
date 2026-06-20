--- The view builder (specification.md §10): a pure transform from the immutable
--- commit DAG + a view state to an **OrderItem graph** — an ordered list of
--- **DisplayNodes** plus their re-pointed parent/child edges — that Phase 1
--- (`columns.layout`) lays out unchanged. A DisplayNode is either a real commit
--- (visible region) or a synthetic **collapsed head** standing for a whole
--- collapsed region. See ARCHITECTURE.md ("OrderItem graphs as derived
--- projections").
---
--- The model (spec §10.2): each commit's **signature** is the set of owners
--- (v1: refs) whose tip reaches it; signatures are monotone (a parent's is a
--- superset of its child's), so equal-signature commits form connected
--- **regions**. A region's display mode is the **join** over its owners — any
--- normal owner ⇒ normal, all collapsed ⇒ collapsed, all hidden (and at least
--- one owner) ⇒ hidden. Collapsing contracts a region to one head and keeps the
--- junctions; hiding removes it.
local M = {}

--- A `DisplayNode` — what `columns.layout` consumes as an `item.commit`. It
--- quacks like a Commit (real nodes inherit the underlying commit's fields via
--- metatable; `parents`/`children` are the *projected* edges, not the raw DAG).
---@class DisplayNode
---@field hash string                 stable identity ("collapsed:<root>" for a head)
---@field parents DisplayNode[]       projected parent edges (first = trunk)
---@field children DisplayNode[]      projected child edges
---@field collapsed boolean           true for a collapsed head
---@field commit? Commit              the underlying commit (nil for a head)
---@field refs Ref[]                  refs on this node (aggregated for a head)
---@field region? string[]            member hashes (head only)
---@field count? integer              number of contracted commits (head only)
---@field tip? Commit                 newest member, for the label/subject (head only)
---@field signature? table<string,boolean>  the owners reaching the region (head only)

--- Owner ids of a signature set, sorted — a stable region key.
---@param set table<string, boolean>
---@return string
local function sig_key(set)
    local ks = {}
    for k in pairs(set) do ks[#ks + 1] = k end
    table.sort(ks)
    return table.concat(ks, ",")
end

--- Per-commit signature: the set of owner ids whose tip reaches the commit
--- (modes ignored here — hidden owners still define regions). Computed in one
--- newest-first pass: a commit's signature is the owners tipped at it unioned
--- with every child's signature (a child is newer, so already computed).
---
--- A **first-parent-only** owner (`o.fp_only`, the trunk; §10.1/§10.2) flows
--- from a child down only to that child's *first* parent, so it covers its
--- tip's first-parent mainline and stops at every merge rather than descending
--- the merged-in side. Ordinary owners flow to every parent (full reachability).
---@param items table[]  -- { type, commit }, newest-first, DAG-wired
---@param owners table[] -- { id, tip = Commit, mode?, fp_only? }
---@return table<string, table<string, boolean>>  -- hash -> owner-id set
function M.signatures(items, owners)
    local tips = {} -- hash -> { owner id, ... }
    local fp = {}   -- owner id -> true if first-parent-only
    for _, o in ipairs(owners) do
        local h = o.tip.hash
        tips[h] = tips[h] or {}
        tips[h][#tips[h] + 1] = o.id
        if o.fp_only then fp[o.id] = true end
    end
    local sig = {}
    for _, it in ipairs(items) do
        local c = it.commit
        local s = {}
        for _, oid in ipairs(tips[c.hash] or {}) do s[oid] = true end
        for _, ch in ipairs(c.children or {}) do
            local cs = sig[ch.hash]
            if cs then
                -- c is on ch's first-parent edge iff it is ch.parents[1].
                local first = ch.parents and ch.parents[1] == c
                for oid in pairs(cs) do
                    if first or not fp[oid] then s[oid] = true end
                end
            end
        end
        sig[c.hash] = s
    end
    return sig
end

--- Build the full owner set for a projection under the first-parent default
--- (spec §10.7). `ref_owners` are `{id, tip}` per ref; `trunk_id` is the id of
--- the current branch's ref (HEAD), or nil if there is none.
---
--- With `collapse_merged` off (or no trunk) every owner defaults **normal** and
--- no trunk/anonymous owners are added — the plain full graph. With it on: the
--- trunk owner becomes **first-parent-only + normal** (it covers only HEAD's
--- mainline), and every other ref **and** every non-first merge parent (an
--- anonymous owner, keyed `merge:<hash>:<i>`) defaults **collapsed** — so the
--- mainline shows in full and everything else collapses (§10.7). `modes`
--- overrides the default per owner id.
---@param items table[]
---@param ref_owners table[]  -- { {id, tip}, ... }
---@param trunk_id string|nil
---@param modes table<string, string>?
---@param collapse_merged boolean
---@return table[]  -- { {id, tip, mode, fp_only}, ... }
function M.owners(items, ref_owners, trunk_id, modes, collapse_merged)
    modes = modes or {}
    local on = collapse_merged and trunk_id ~= nil
    local out = {}
    for _, o in ipairs(ref_owners) do
        local default, fp = "normal", false
        if on and o.id ~= trunk_id then default = "collapsed" end
        if on and o.id == trunk_id then fp = true end
        out[#out + 1] = { id = o.id, tip = o.tip, mode = modes[o.id] or default, fp_only = fp }
    end
    if on then
        for _, it in ipairs(items) do
            local ps = it.commit.parents or {}
            for i = 2, #ps do
                local id = "merge:" .. it.commit.hash .. ":" .. i
                out[#out + 1] = { id = id, tip = ps[i], mode = modes[id] or "collapsed", fp_only = false }
            end
        end
    end
    return out
end

--- The display-mode join for one commit's signature (spec §10.2). A commit
--- reached by *no* owner is treated as visible (normal) — only owners can hide.
---@param full_sig table<string, boolean>
---@param owner_mode table<string, string>
---@return "normal"|"collapsed"|"hidden"
local function mode_of(full_sig, owner_mode)
    if next(full_sig) == nil then return "normal" end -- uncovered ⇒ visible
    local any_nonhidden, any_normal = false, false
    for oid in pairs(full_sig) do
        local m = owner_mode[oid] or "normal"
        if m ~= "hidden" then
            any_nonhidden = true
            if m == "normal" then any_normal = true end
        end
    end
    if not any_nonhidden then return "hidden" end
    if any_normal then return "normal" end
    return "collapsed"
end

--- Project the commit DAG under a view state into an OrderItem graph.
---
--- `sig` (the per-commit signatures) may be passed in precomputed: it depends
--- only on the DAG and the owner *tips*, not on modes, so a caller reflowing
--- after a mode change can reuse a cached one and skip the O(N·owners) pass
--- (the caching split, ARCHITECTURE.md / spec §10.5). Omit it to compute fresh.
---@param items table[]  -- { type, commit }, newest-first, DAG-wired (repo.order)
---@param owners table[] -- { id, tip = Commit, mode? = "normal"|"collapsed"|"hidden" }
---@param sig table<string, table<string, boolean>>?  -- precomputed signatures
---@return table  -- { items = OrderItem[], nodes = DisplayNode[], sig, mode, node_of_hash }
function M.project(items, owners, sig)
    owners = owners or {}
    local owner_mode = {}
    for _, o in ipairs(owners) do owner_mode[o.id] = o.mode or "normal" end

    local idx = {} -- hash -> position in items (newest-first; smaller = newer)
    for i, it in ipairs(items) do idx[it.commit.hash] = i end

    sig = sig or M.signatures(items, owners)

    local mode = {}
    for _, it in ipairs(items) do
        local h = it.commit.hash
        mode[h] = mode_of(sig[h], owner_mode)
    end

    -- Union-find over collapsed commits: merge adjacent same-signature ones so
    -- each connected collapsed region becomes one head. Different signatures
    -- stay distinct heads (the junctions between them stay visible, spec §10.3).
    local uf = {}
    local function find(h)
        local root = h
        while uf[root] ~= root do root = uf[root] end
        while uf[h] ~= root do
            uf[h], h = root, uf[h]
        end
        return root
    end
    for _, it in ipairs(items) do
        local h = it.commit.hash
        if mode[h] == "collapsed" then uf[h] = h end
    end
    for _, it in ipairs(items) do
        local c = it.commit
        if mode[c.hash] == "collapsed" then
            local sk = sig_key(sig[c.hash])
            for _, p in ipairs(c.parents or {}) do
                if mode[p.hash] == "collapsed" and sig_key(sig[p.hash]) == sk then
                    local ra, rb = find(c.hash), find(p.hash)
                    if ra ~= rb then uf[ra] = rb end
                end
            end
        end
    end

    -- Build the DisplayNodes. Newest-first iteration means the first member of a
    -- region is its newest (the tip).
    local nodes = {}
    local node_of_hash = {} -- hash -> DisplayNode (head for collapsed members)
    local head_of_root = {}
    for _, it in ipairs(items) do
        local c = it.commit
        local h = c.hash
        local m = mode[h]
        if m == "normal" then
            local dn = setmetatable(
                { commit = c, collapsed = false, parents = {}, children = {} },
                { __index = c })
            nodes[#nodes + 1] = dn
            node_of_hash[h] = dn
        elseif m == "collapsed" then
            local root = find(h)
            local head = head_of_root[root]
            if not head then
                head = {
                    collapsed = true,
                    hash = "collapsed:" .. root,
                    parents = {}, children = {},
                    region = {}, refs = {}, count = 0,
                    tip = c, -- newest member (first seen)
                    signature = sig[h],
                }
                head_of_root[root] = head
                nodes[#nodes + 1] = head
            end
            head.region[#head.region + 1] = h
            head.count = head.count + 1
            for _, r in ipairs(c.refs or {}) do head.refs[#head.refs + 1] = r end
            node_of_hash[h] = head
        end
        -- hidden: no node
    end

    -- Re-point edges through the node map: drop edges to hidden commits and
    -- self-edges inside a contracted region; keep first-occurrence order.
    local pseen, cseen = {}, {}
    for _, it in ipairs(items) do
        local c = it.commit
        local n = node_of_hash[c.hash]
        if n then
            pseen[n] = pseen[n] or {}
            for _, p in ipairs(c.parents or {}) do
                local pn = node_of_hash[p.hash]
                if pn and pn ~= n then
                    if not pseen[n][pn] then
                        pseen[n][pn] = true
                        n.parents[#n.parents + 1] = pn
                    end
                    cseen[pn] = cseen[pn] or {}
                    if not cseen[pn][n] then
                        cseen[pn][n] = true
                        pn.children[#pn.children + 1] = n
                    end
                end
            end
        end
    end

    -- Newest-first topological order, stable by the newest source commit's
    -- position. Kahn over the DisplayNode DAG: a node is emitted once all its
    -- children are, so children precede parents (the order columns.layout
    -- expects). Contracting a monotone-signature DAG stays acyclic, so every
    -- node is emitted.
    local function order_key(n)
        return n.collapsed and idx[n.tip.hash] or idx[n.commit.hash]
    end
    local heap = {}
    local function hpush(n)
        heap[#heap + 1] = n
        local i = #heap
        while i > 1 do
            local p = math.floor(i / 2)
            if order_key(heap[p]) <= order_key(heap[i]) then break end
            heap[p], heap[i] = heap[i], heap[p]
            i = p
        end
    end
    local function hpop()
        local top = heap[1]
        local last = heap[#heap]
        heap[#heap] = nil
        if #heap > 0 then
            heap[1] = last
            local i, n = 1, #heap
            while true do
                local l, r, s = 2 * i, 2 * i + 1, i
                if l <= n and order_key(heap[l]) < order_key(heap[s]) then s = l end
                if r <= n and order_key(heap[r]) < order_key(heap[s]) then s = r end
                if s == i then break end
                heap[s], heap[i] = heap[i], heap[s]
                i = s
            end
        end
        return top
    end

    local pending = {}
    for _, n in ipairs(nodes) do
        pending[n] = #n.children
        if pending[n] == 0 then hpush(n) end
    end
    local ordered = {}
    while #heap > 0 do
        local n = hpop()
        ordered[#ordered + 1] = { type = "commit", commit = n }
        for _, p in ipairs(n.parents) do
            pending[p] = pending[p] - 1
            if pending[p] == 0 then hpush(p) end
        end
    end

    return {
        items = ordered,
        nodes = nodes,
        node_of_hash = node_of_hash,
        sig = sig,
        mode = mode,
    }
end

return M
