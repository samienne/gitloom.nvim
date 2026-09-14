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
local sigset = require("gitloom.graph.sigset")

local M = {}

--- A `DisplayNode` — what `columns.layout` consumes as an `item.commit`. It
--- quacks like a Commit (real nodes inherit the underlying commit's fields via
--- metatable; `parents`/`children` are the *projected* edges, not the raw DAG).
---@class DisplayNode
---@field hash string                 stable identity ("collapsed:<root>" for a head)
---@field parents DisplayNode[]       projected parent edges (first = trunk)
---@field children DisplayNode[]      projected child edges
---@field collapsed boolean           true for a collapsed head
---@field junction? boolean           a collapsed-region fork/merge kept for topology (§10.4)
---@field commit? Commit              the underlying commit (nil for a head)
---@field refs Ref[]                  refs on this node (aggregated for a head)
---@field region? string[]            member hashes (head only)
---@field count? integer              number of contracted commits (head only)
---@field tip? Commit                 newest member, for the label/subject (head only)
---@field signature? table<string,boolean>  the owners reaching the region (head only)

-- Chunking support for the async reflow (spec §10.5, window.lua `reflow_async`).
-- `signatures` and `project` are O(commits x owners) passes over the whole
-- repository; when the caller passes a `yield`, they call it once per
-- `YIELD_EVERY` commits so a coroutine driver can suspend between event-loop
-- ticks and the editor stays live while a large graph is projected. Synchronous
-- callers (every test, every keypress-driven reflow on a small repo) pass no
-- `yield`, so the output and the code path are unchanged.
--
-- `yield` is only ever called from a loop *body*, never across a C-call boundary
-- (a `table.sort` comparator, a metamethod), so it is safe under LuaJIT
-- coroutines. The same discipline as pane.lua's chunker.
local YIELD_EVERY = 2048
---@param yield (fun())?
---@return fun()  -- call once per unit of work
local function chunker(yield)
    if not yield then return function() end end
    local n = 0
    return function()
        n = n + 1
        if n % YIELD_EVERY == 0 then yield() end
    end
end

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
---
--- The sets are **interned persistent sets** (gitloom.graph.sigset), not one
--- materialised table per commit: on a trunk of merges every merge above a commit
--- contributes an owner to it, so materialising them costs Θ(commits × owners).
--- Indexing the returned table by a commit hash still yields a plain
--- `{ [owner id] = true }` table — see `sigset.view` for the two differences
--- (built per access, and `pairs` over the *map* does not enumerate commits).
---@param items table[]  -- { type, commit }, newest-first, DAG-wired
---@param owners table[] -- { id, tip = Commit, mode?, fp_only? }
---@param yield (fun())?  -- chunking hook; called every YIELD_EVERY commits
---@return table<string, table<string, boolean>>  -- hash -> owner-id set
function M.signatures(items, owners, yield)
    local U = sigset.universe(owners)
    local tips = {} -- hash -> the set of owners tipped there
    -- `fp_only` is uniform in practice (§10.7 turns focus on for every owner at
    -- once), so the two uniform cases are the fast paths and only a mixed owner
    -- set pays the per-edge intersection against `nonfp`.
    local any_fp, all_fp = false, #owners > 0
    for _, o in ipairs(owners) do
        local h = o.tip.hash
        tips[h] = U:union(tips[h], U:singleton(o.id))
        if o.fp_only then any_fp = true else all_fp = false end
    end
    local nonfp = nil
    if any_fp and not all_fp then
        for _, o in ipairs(owners) do
            if not o.fp_only then nonfp = U:union(nonfp, U:singleton(o.id)) end
        end
    end
    local handles = {}
    local tick = chunker(yield)
    for _, it in ipairs(items) do
        tick()
        local c = it.commit
        local s = tips[c.hash]
        for _, ch in ipairs(c.children or {}) do
            local cs = handles[ch.hash]
            if cs then
                -- c is on ch's first-parent edge iff it is ch.parents[1].
                if (ch.parents and ch.parents[1] == c) or not any_fp then
                    s = U:union(s, cs)
                elseif not all_fp then
                    s = U:union(s, U:intersect(cs, nonfp))
                end
            end
        end
        handles[c.hash] = s or false
    end
    return sigset.view(U, handles)
end

--- Build the full owner set for a projection under the first-parent default
--- (spec §10.7). `ref_owners` are `{id, tip}` per ref; `pinned` is the set of
--- **anchor** owner ids (spec §10.6) — the refs the view is organised around.
--- The single-anchor `{ [HEAD] = true }` is the trunk default; an empty/nil set
--- means no anchors.
---
--- With `collapse_merged` off (or no anchor) every owner defaults **normal** and
--- no anonymous owners are added — the plain full graph. With it on:
--- **every** owner is **first-parent-only** — each covers only its own tip's
--- first-parent line, so a branch is attributed to the commits actually *on* it,
--- not every branch its history merged through (this is what keeps collapsing or
--- expanding one branch from dragging in the earlier branches it merged past).
--- The **pinned anchors** default **normal**; every other ref and every
--- non-first merge parent (an anonymous owner, keyed `merge:<hash>:<i>`) defaults
--- **collapsed** — so the anchors show in full and everything else collapses
--- (§10.6/§10.7). `modes` overrides the default per owner id.
---
--- **Owner coverage is total** (§10.2). Two anonymous families close it, and both
--- are needed: a `merge:<hash>:<i>` owner per non-first merge parent (a path that
--- leaves a mainline at a merge is picked up on the other side), and a
--- `tip:<hash>` owner per **uncovered tip** — an in-set commit with no in-set
--- child that no ref owner is tipped at. The tip family is the backstop for
--- §3.1's commit set not being guaranteed to equal the ref-reachable set: `--all`
--- walks namespaces the ref query does not, and without it those commits get an
--- empty signature and fall through `mode_of`'s uncovered-⇒-normal rule as a run
--- of fully expanded rows in an otherwise focused view. §4.2's working-tree
--- virtual commits are childless by construction and must stay visible, so they
--- are excluded — they are the case that rule exists for.
---@param items table[]
---@param ref_owners table[]  -- { {id, tip}, ... }
---@param pinned table<string, boolean>|nil  -- anchor owner ids (HEAD by default)
---@param modes table<string, string>?
---@param collapse_merged boolean
---@return table[]  -- { {id, tip, mode, fp_only}, ... }
function M.owners(items, ref_owners, pinned, modes, collapse_merged)
    modes = modes or {}
    pinned = pinned or {}
    local on = collapse_merged and next(pinned) ~= nil
    local out = {}
    local ref_tips = {} -- hashes a ref owner is tipped at
    for _, o in ipairs(ref_owners) do
        -- Under focus every owner is first-parent-only (see above); a pinned
        -- anchor is normal, every other ref collapsed by default.
        local default = (on and not pinned[o.id]) and "collapsed" or "normal"
        out[#out + 1] = { id = o.id, tip = o.tip, mode = modes[o.id] or default, fp_only = on }
        ref_tips[o.tip.hash] = true
    end
    if on then
        local in_set = {}
        for _, it in ipairs(items) do in_set[it.commit.hash] = true end
        for _, it in ipairs(items) do
            local c = it.commit
            local ps = c.parents or {}
            for i = 2, #ps do
                local id = "merge:" .. c.hash .. ":" .. i
                out[#out + 1] = { id = id, tip = ps[i], mode = modes[id] or "collapsed", fp_only = true }
            end
            if not ref_tips[c.hash] and not c.virtual then
                local covered = false
                for _, ch in ipairs(c.children or {}) do
                    if in_set[ch.hash] then covered = true break end
                end
                if not covered then
                    local id = "tip:" .. c.hash
                    out[#out + 1] = { id = id, tip = c, mode = modes[id] or "collapsed", fp_only = true }
                end
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
---
--- `keep` (the filter-search match set, spec §16.3) is an optional set of commit
--- hashes that must **never** contract into a collapsed head — they stay their
--- own visible nodes even under collapsed owners, exactly like junctions. The
--- filter passes all-collapsed owners plus the matching hashes here, so a match
--- mid-run splits the collapsed run above and below it (§16.3). Omit for no filter.
---@param items table[]  -- { type, commit }, newest-first, DAG-wired (repo.order)
---@param owners table[] -- { id, tip = Commit, mode? = "normal"|"collapsed"|"hidden" }
---@param sig table<string, table<string, boolean>>?  -- precomputed signatures
---@param keep table<string, boolean>?  -- hashes never contracted (§16.3)
---@param yield (fun())?  -- chunking hook; called every YIELD_EVERY commits
---@return table  -- { items = OrderItem[], nodes = DisplayNode[], sig, mode, node_of_hash }
function M.project(items, owners, sig, keep, yield)
    owners = owners or {}
    local tick = chunker(yield)

    local idx = {} -- hash -> position in items (newest-first; smaller = newer)
    for i, it in ipairs(items) do idx[it.commit.hash] = i end

    sig = sig or M.signatures(items, owners, yield)

    -- The two things the projection asks a signature for: its display mode, and a
    -- **region key** — a value equal for exactly the commits with the same owner
    -- set. Over the interned representation both are O(1)-ish (the key IS the
    -- set's one node, the join memoises per node); a caller that handed us a plain
    -- table of sets gets the equivalent, slower answers.
    local S = sigset.of(sig)
    local mode_at, region_at
    if S then
        local U, handles = S.universe, S.handles
        local flags = {} -- owner index -> 0 hidden, 1 collapsed, 3 normal
        for i = 0, U.n - 1 do flags[i] = 3 end
        for _, o in ipairs(owners) do
            local i = U.idx[o.id]
            if i then
                local m = o.mode or "normal"
                flags[i] = (m == "hidden") and 0 or ((m == "normal") and 3 or 1)
            end
        end
        local memo = {}
        mode_at = function(h)
            local nd = handles[h]
            if not nd then return "normal" end -- uncovered ⇒ visible
            local s = U:summary(nd, flags, memo)
            if s == 0 then return "hidden" end
            return (s >= 2) and "normal" or "collapsed"
        end
        region_at = function(h) return handles[h] end
    else
        local owner_mode = {}
        for _, o in ipairs(owners) do owner_mode[o.id] = o.mode or "normal" end
        local keys = {}
        mode_at = function(h) return mode_of(sig[h] or {}, owner_mode) end
        region_at = function(h)
            local k = keys[h]
            if k == nil then
                k = sig_key(sig[h] or {})
                keys[h] = k
            end
            return k
        end
    end

    local mode = {}
    for _, it in ipairs(items) do
        tick()
        mode[it.commit.hash] = mode_at(it.commit.hash)
    end

    -- A collapsed fork/merge is a **kept junction** — it stays its own visible,
    -- node-less row so the visible branching is preserved (spec §10.3) and is
    -- excluded from head-membership — with one exception: a **merge tip**, a
    -- merge (≥2 visible parents) with **no visible child**. A head is anchored by
    -- its tip (its newest member), and a merge tip is exactly that — the end of
    -- the branch, carrying its ref, with nothing above it — so it folds into a ◍
    -- head like a linear run (§10.3). A fork root (≥2 visible children, no visible
    -- parent) is not a tip and stays a kept junction. Same-signature union (below)
    -- keeps the contraction within one collapsed region, so no *visible*
    -- fork/merge is ever absorbed. "Visible" = not hidden, so hiding all-but-one
    -- branch demotes a junction back to a linear commit that may collapse.
    local function visible(h) return mode[h] ~= "hidden" end
    local function nvis(list)
        local n = 0
        for _, x in ipairs(list or {}) do if visible(x.hash) then n = n + 1 end end
        return n
    end
    local function is_kept_junction(c)
        local nc, np = nvis(c.children), nvis(c.parents)
        if nc < 2 and np < 2 then return false end -- not a fork/merge
        return nc >= 1 -- a merge tip (no visible child) folds into a head; else kept
    end
    -- A collapsed commit contracts into a head unless it is a kept junction
    -- (above) or a **filter match** (§16.3 `keep`): a kept commit never contracts,
    -- so a match stays a visible node splitting the collapsed run above and below it.
    local function is_head_member(c)
        return mode[c.hash] == "collapsed" and not is_kept_junction(c)
            and not (keep and keep[c.hash])
    end

    -- Union-find over head-members: merge adjacent same-signature ones so each
    -- connected linear collapsed run becomes one head. The union naturally stops
    -- at junctions (excluded) and at signature boundaries.
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
        if is_head_member(it.commit) then uf[it.commit.hash] = it.commit.hash end
    end
    for _, it in ipairs(items) do
        tick()
        local c = it.commit
        if is_head_member(c) then
            local sk = region_at(c.hash)
            for _, p in ipairs(c.parents or {}) do
                if is_head_member(p) and region_at(p.hash) == sk then
                    local ra, rb = find(c.hash), find(p.hash)
                    if ra ~= rb then uf[ra] = rb end
                end
            end
        end
    end

    -- Build the DisplayNodes. Newest-first iteration means the first member of a
    -- region is its newest (the tip).
    local nodes = {}
    local node_of_hash = {} -- hash -> DisplayNode (head for head-members)
    local head_of_root = {}
    for _, it in ipairs(items) do
        tick()
        local c = it.commit
        local h = c.hash
        if mode[h] == "hidden" then
            -- dropped: no node
        elseif is_head_member(c) then
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
        else
            -- A normal commit, a collapsed **kept junction** (§10.3, rendered
            -- node-less — every *collapsed* commit reaching here is one, since head
            -- members incl. merge tips were handled above), or a **filter match**
            -- (§16.3). A match is always shown as a real commit (its message),
            -- never a node-less junction even when it is itself a fork/merge — so
            -- the junction flag excludes kept matches.
            local dn = setmetatable(
                { commit = c, collapsed = false,
                    junction = (mode[h] == "collapsed") and not (keep and keep[h]),
                    parents = {}, children = {} },
                { __index = c })
            nodes[#nodes + 1] = dn
            node_of_hash[h] = dn
        end
    end

    -- Re-point edges through the node map: drop edges to hidden commits and
    -- self-edges inside a contracted region; keep first-occurrence order.
    local pseen, cseen = {}, {}
    for _, it in ipairs(items) do
        tick()
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
        tick()
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
