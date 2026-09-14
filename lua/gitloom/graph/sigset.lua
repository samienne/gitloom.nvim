--- Interned persistent owner sets — the representation behind §10.2's per-commit
--- **signatures**.
---
--- Why this exists. A signature is the set of owners whose tip reaches a commit,
--- and under the first-parent focus (§10.7) an owner is minted per non-first
--- merge parent. An fp-only owner flows down its tip's first-parent chain, and a
--- merged-in branch's first-parent chain *rejoins the trunk* at its fork point —
--- so every merge above a trunk commit contributes an owner to it. On a trunk of
--- merges the signature of the k-th commit therefore has ~k members, and storing
--- one materialised `table<string, boolean>` per commit costs Θ(commits × owners)
--- entries: 22.1 million of them (813 MB) on a 13,000-commit repository with
--- 6,500 merges, and ~850 ms just to build.
---
--- The sets are extremely *shareable*, though: walking down the trunk each one is
--- its predecessor plus a single owner. So they are represented as a **hash-consed
--- 32-way bitwise trie** over dense owner indices — a persistent set where adding
--- an owner allocates O(depth) nodes and shares everything else. Two properties
--- follow, and both are what the projection needs:
---
--- * **Equality is pointer equality.** A node is interned on (level, base,
---   contents), so a set has exactly one representation and `a == b` decides
---   whether two commits are in the same region (§10.2) in O(1) — replacing the
---   sorted-and-concatenated `sig_key` string.
--- * **Folds memoise.** The display-mode join (§10.2) is an OR over the set, so
---   `summary` is computed once per *node* rather than once per commit — O(nodes)
---   instead of O(commits × owners).
---
--- Membership is materialised on demand (`members`), for the few commits that
--- actually need the owner ids: a collapsed head's stored signature and whatever
--- the cursor is on.
---
--- Layout. Owner ids are numbered 0..n-1. A **leaf** holds a 32-bit mask for
--- indices `[base, base+31]`; a node at level L has 32 slots, slot `s` holding
--- the indices whose bits `[5L, 5L+4]` are `s`. `top` is the smallest level whose
--- span covers every index, so the depth is `ceil(log32(n))` — 3 levels for up to
--- 32,768 owners.

local bit = require("bit")
local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift

local M = {}

local BITS, ARITY = 5, 32

--- One interned node. A leaf carries `m` (its mask); an internal node carries its
--- children in the integer slots `[0, 31]`.
---@class SigNode
---@field id integer      serial, for the intern key of the node above it
---@field lvl integer     0 = leaf
---@field base integer    the lowest owner index this node covers
---@field m? integer      leaf only: the 32-bit membership mask

--- A set is a `SigNode` or `nil` (the empty set).
---@alias SigHandle SigNode?

---@class SigUniverse
---@field idx table<string, integer>   owner id -> dense index
---@field names table<integer, string> the inverse
---@field n integer                    owner count
---@field top integer                  top trie level
---@field intern table<string, SigNode>        the hash-cons table, keyed by (base, level, contents)
---@field count integer                        nodes interned so far (and the next node's serial)
---@field umemo table<SigNode, table>          union results, keyed by the operand pair
---@field imemo table<SigNode, table>          intersection results, likewise
---@field single table<integer, SigNode|false> one-element sets, by owner index
---@field span table<integer, integer>         indices a level-L node covers
---@field step table<integer, integer>         indices one of its slots covers
---@field uscratch table<integer, table>       per-level child buffer for `union`
---@field iscratch table<integer, table>       per-level child buffer for `intersect`
---@field sealed? boolean                      construction finished; see `seal`
local U = {}
U.__index = U

--- Number the owners and size the trie. Duplicate ids collapse onto one index
--- (a signature is a set of ids, so that is the existing semantics).
---@param owners table[]  -- { { id, ... }, ... }
---@return SigUniverse
function M.universe(owners)
    local idx, names, n = {}, {}, 0
    for _, o in ipairs(owners or {}) do
        if idx[o.id] == nil then
            idx[o.id] = n
            names[n] = o.id
            n = n + 1
        end
    end
    local top, span = 0, ARITY
    while span < n do top = top + 1; span = span * ARITY end
    -- span[L] = indices one level-L node covers; step[L] = indices one of its slots covers.
    local spans, steps, uscratch, iscratch = {}, {}, {}, {}
    spans[0], steps[0] = ARITY, 1
    uscratch[0], iscratch[0] = {}, {}
    for l = 1, top do
        spans[l], steps[l] = spans[l - 1] * ARITY, steps[l - 1] * ARITY
        uscratch[l], iscratch[l] = {}, {}
    end
    return setmetatable({
        idx = idx, names = names, n = n, top = top,
        intern = {}, count = 0,
        umemo = {}, imemo = {}, single = {},
        span = spans, step = steps, uscratch = uscratch, iscratch = iscratch,
    }, U)
end

--- Intern a leaf. The mask alone is not an identity — the same mask at a
--- different base is a different set — so the key carries the base.
---@param u SigUniverse
---@param base integer
---@param mask integer
---@return SigHandle
local function leaf(u, base, mask)
    if mask == 0 then return nil end
    local k = base .. "L" .. mask
    local got = u.intern[k]
    if got then return got end
    u.count = u.count + 1
    local nd = { id = u.count, lvl = 0, base = base, m = mask }
    u.intern[k] = nd
    return nd
end

-- Scratch for the intern key, so building one allocates no table. `inode` never
-- recurses, so a single module-level buffer is safe.
local KEY = {}

--- Intern an internal node from `kids` (slots 0..31; the table is only read).
---@param u SigUniverse
---@param lvl integer
---@param base integer
---@param kids table
---@return SigHandle
local function inode(u, lvl, base, kids)
    local any = false
    for s = 0, ARITY - 1 do
        local c = kids[s]
        KEY[s + 1] = c and c.id or 0
        if c then any = true end
    end
    if not any then return nil end
    local k = base .. "N" .. lvl .. ":" .. table.concat(KEY, ",", 1, ARITY)
    local got = u.intern[k]
    if got then return got end
    u.count = u.count + 1
    local nd = { id = u.count, lvl = lvl, base = base }
    for s = 0, ARITY - 1 do nd[s] = kids[s] end
    u.intern[k] = nd
    return nd
end

--- The one-element set for an owner id (nil when the id is not in the universe).
---@param oid string
---@return SigHandle
function U:singleton(oid)
    if self.sealed then error("sigset: the universe is sealed", 2) end
    local i = self.idx[oid]
    if i == nil then return nil end
    local got = self.single[i]
    if got ~= nil then return got or nil end
    local nd = leaf(self, i - (i % ARITY), lshift(1, band(i, ARITY - 1)))
    for l = 1, self.top do
        local kids = {}
        kids[band(rshift(i, BITS * l), ARITY - 1)] = nd
        nd = inode(self, l, i - (i % self.span[l]), kids)
    end
    self.single[i] = nd or false
    return nd
end

---@param a SigHandle
---@param b SigHandle
---@param lvl integer
---@param base integer
---@return SigHandle
function U:_union(a, b, lvl, base)
    if a == nil then return b end
    if b == nil then return a end
    if a == b then return a end
    local ma = self.umemo[a]
    if ma then
        local r = ma[b]
        if r ~= nil then return r or nil end
    else
        ma = {}
        self.umemo[a] = ma
    end
    local out
    if lvl == 0 then
        out = leaf(self, base, bor(a.m, b.m))
    else
        local kids, step = self.uscratch[lvl], self.step[lvl]
        for s = 0, ARITY - 1 do
            kids[s] = self:_union(a[s], b[s], lvl - 1, base + s * step)
        end
        out = inode(self, lvl, base, kids)
    end
    ma[b] = out or false
    return out
end

--- Set union. Memoised on the operand pair, so the dominant case — a big set
--- plus one owner, repeated down a trunk — costs O(depth) per step.
---@param a SigHandle
---@param b SigHandle
---@return SigHandle
function U:union(a, b)
    if a == nil then return b end
    if b == nil then return a end
    if a == b then return a end
    if self.sealed then error("sigset: the universe is sealed", 2) end
    return self:_union(a, b, self.top, 0)
end

---@param a SigHandle
---@param b SigHandle
---@param lvl integer
---@param base integer
---@return SigHandle
function U:_intersect(a, b, lvl, base)
    if a == nil or b == nil then return nil end
    if a == b then return a end
    local ma = self.imemo[a]
    if ma then
        local r = ma[b]
        if r ~= nil then return r or nil end
    else
        ma = {}
        self.imemo[a] = ma
    end
    local out
    if lvl == 0 then
        out = leaf(self, base, band(a.m, b.m))
    else
        local kids, step = self.iscratch[lvl], self.step[lvl]
        for s = 0, ARITY - 1 do
            kids[s] = self:_intersect(a[s], b[s], lvl - 1, base + s * step)
        end
        out = inode(self, lvl, base, kids)
    end
    ma[b] = out or false
    return out
end

--- Set intersection (§10.2's mixed `fp_only` filter: an owner may only cross a
--- non-first-parent edge when it is not first-parent-only).
---@param a SigHandle
---@param b SigHandle
---@return SigHandle
function U:intersect(a, b)
    if a == nil or b == nil then return nil end
    if a == b then return a end
    if self.sealed then error("sigset: the universe is sealed", 2) end
    return self:_intersect(a, b, self.top, 0)
end

---@param nd SigNode
---@param out table<string, boolean>
function U:_members(nd, out)
    local m = nd.m
    if m then
        local base, names = nd.base, self.names
        for b = 0, ARITY - 1 do
            if band(m, lshift(1, b)) ~= 0 then
                local nm = names[base + b]
                if nm then out[nm] = true end
            end
        end
    else
        for s = 0, ARITY - 1 do
            local c = nd[s]
            if c then self:_members(c, out) end
        end
    end
end

--- Materialise a set as `{ [owner id] = true }` — the shape every consumer of a
--- signature outside the projection expects. O(size); called only for the commits
--- that actually need their owner ids.
---@param h SigHandle
---@return table<string, boolean>
function U:members(h)
    local out = {}
    if h then self:_members(h, out) end
    return out
end

--- The display-mode join (§10.2) as a 2-bit summary, memoised per node: bit 0 is
--- "some owner is not hidden", bit 1 "some owner is normal". `flags` maps an
--- owner index to its own summary (0 hidden, 1 collapsed, 3 normal), so the
--- possible values are 0, 1 and 3 and `s >= 2` means normal.
---@param h SigHandle
---@param flags table<integer, integer>
---@param memo table<SigNode, integer>
---@return integer
function U:summary(h, flags, memo)
    if h == nil then return 0 end
    local got = memo[h]
    if got then return got end
    local s = 0
    local m = h.m
    if m then
        local base = h.base
        for b = 0, ARITY - 1 do
            if band(m, lshift(1, b)) ~= 0 then
                s = bor(s, flags[base + b] or 3)
            end
        end
    else
        for k = 0, ARITY - 1 do
            local c = h[k]
            if c then s = bor(s, self:summary(c, flags, memo)) end
        end
    end
    memo[h] = s
    return s
end

--- The number of interned nodes — the structure's real size, for diagnostics.
---@return integer
function U:nodes()
    return self.count
end

--- Drop the construction-time scaffolding: the hash-cons table, the operation
--- memos and the per-level buffers. The built sets are reachable from the caller's
--- handles and answer `members` / `summary` on their own, but the scaffolding is
--- retained for the life of the signature cache (§10.5) otherwise — on a
--- merge-heavy trunk that is one intern key per node and one memo table per commit.
---
--- A sealed universe can no longer build sets, and says so rather than silently
--- minting a second node for a set that already has one (which would break the
--- "equal sets are the same node" invariant everything downstream rests on).
function U:seal()
    self.sealed = true
    self.intern, self.umemo, self.imemo = {}, {}, {}
    self.single, self.uscratch, self.iscratch = {}, {}, {}
end

-- The metatable field the projection reads a signature map's interned form back
-- out of. Not a string key on the map itself, so it can never collide with a hash.
local SIGSET = "__gitloom_sigset"

--- Wrap a hash -> handle map as the `sig` table `view.signatures` returns: indexing
--- it by a commit hash yields a plain `{ [owner id] = true }` table, exactly as
--- before, materialised on the spot.
---
--- Two deliberate differences from a plain table of sets. The value is **built per
--- access** rather than cached, so walking the cursor over a merge-heavy trunk
--- cannot re-accumulate the Θ(commits × owners) footprint this representation
--- exists to avoid; and `pairs(sig)` does not enumerate the commits (nothing in
--- gitloom iterates it — every consumer indexes a known hash). Use `handles` for
--- the interned form.
---@param u SigUniverse
---@param handles table<string, SigNode|false>  -- false = a covered commit with an empty signature
---@return table<string, table<string, boolean>>
function M.view(u, handles)
    return setmetatable({}, {
        __index = function(_, hash)
            local h = handles[hash]
            if h == nil then return nil end
            return u:members(h or nil)
        end,
        [SIGSET] = { universe = u, handles = handles },
    })
end

--- The interned form behind a `sig` table, or nil if it is a plain table of sets
--- (a caller that built one itself — the projection then takes its own slower but
--- equivalent path).
---@param sig table?
---@return { universe: SigUniverse, handles: table<string, SigNode|false> }?
function M.of(sig)
    local mt = type(sig) == "table" and getmetatable(sig) or nil
    return mt and mt[SIGSET] or nil
end

return M
