--- Ranked refs and identities (spec §5 "Ranked refs and identities") — the pure
--- pairing of branches into **identities** (one hue each) and the **total order**
--- of ranked and generated refs that the layout's carried refs obey. Two steps:
---
--- 1. `pair(refs, opts)` reads the repository's refs and upstream configuration
---    (no view state) and groups every local / remote-tracking branch into an
---    identity.
--- 2. `infos(pairing, opts)` takes the view's side — which refs are visible, the
---    resolved pin list, the current branch — and precomputes one static `RankInfo`
---    per ranked ref. `compare(a, b, rows)` then orders two infos given the tip rows
---    known so far: the only row-dependent rule is the standing row, read at
---    compare time, so the layout can compare top to bottom as rows arrive (a
---    comparison happens at or below both tips, spec §5). `generated(seq)` is the
---    info of the `seq`-th generated ref.
---
--- All pure; part of the gitloom graph engine.

local M = {}

---@class RankRef
---@field name string
---@field kind string                  "local"|"remote"|… (only local/remote are ranked)
---@field upstream? { short?: string } the configured upstream (§6.3), local branches only

---@class Identity
---@field key string           unique: the local's name, or "remote:<short>" for a remote-only one
---@field name string          the tie-break name (§5 rank rule 4): the local's or the shared short name
---@field local_name? string   the identity's local branch (nil = remote-only)
---@field upstream? string     the local's configured upstream, when it is a member
---@field members string[]     ref names: the local first, then remotes by name

---@class IdentityPairing
---@field identities Identity[]          in key order
---@field of table<string, Identity>     ref name → its identity

---@class RankInfo
---@field name string          the ref name ("" for a generated ref)
---@field tier integer         1 pinned, 2 unpinned with a visible local, 3 remote-only, 4 generated
---@field pin? integer         tier 1: the identity's pin rank
---@field ident? string        the identity's key (nil for a generated ref)
---@field ident_name? string   the identity's tie-break name
---@field current? boolean     the identity holds the current branch
---@field is_local? boolean    the identity's local branch itself
---@field remote? boolean      a remote-tracking branch (drawn muted, spec §5.5)
---@field local_name? string   a remote's visible local, whose tip row it may stand at
---@field upstream? boolean    this remote is its local's configured upstream
---@field remote_idx? integer  this remote's place in `git remote` order (unknown remotes last)
---@field seq? integer         tier 4: creation order

--- Split a remote ref name into its remote and short name, preferring the longest
--- known remote prefix (remote names may contain `/`), else the first segment.
---@param name string
---@param remotes string[]
---@return string remote, string short
local function split_remote(name, remotes)
    local best
    for _, r in ipairs(remotes) do
        if name:sub(1, #r + 1) == r .. "/" and #name > #r + 1 and (not best or #r > #best) then
            best = r
        end
    end
    if best then return best, name:sub(#best + 2) end
    local r, s = name:match("^([^/]+)/(.+)$")
    return r or "", s or name
end
M._split_remote = split_remote

--- Iterate a ref collection given as an array or a name → Ref map.
---@param refs RankRef[]|table<string, RankRef>
---@return RankRef[]
local function ref_list(refs)
    local out = {}
    for _, r in pairs(refs or {}) do
        if type(r) == "table" and r.name then out[#out + 1] = r end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

--- Pair the repository's branches into identities (spec §5): a local branch, its
--- configured upstream when that is a remote-tracking branch, and every remote
--- branch of its short name. A remote claimed by several locals (only possible
--- through upstream configuration) goes to the same-named local, else to the
--- claiming local first in pin-list order, then by name. Remotes of one short name
--- that no local claims form one remote-only identity. Tags, `HEAD`, worktree
--- labels and `<remote>/HEAD` symrefs take no part.
---@param refs RankRef[]|table<string, RankRef>   every ref of the repository
---@param opts? { remotes?: string[], pins?: PinEntry[] }
---@return IdentityPairing
function M.pair(refs, opts)
    opts = opts or {}
    local remotes = opts.remotes or {}
    local list = ref_list(refs)
    local locals, remote_refs = {}, {} ---@type table<string, RankRef>, RankRef[]
    for _, r in ipairs(list) do
        if r.kind == "local" then
            locals[r.name] = r
        elseif r.kind == "remote" and not r.name:match("/HEAD$") then
            remote_refs[#remote_refs + 1] = r
        end
    end
    -- A local's own place in the pin list (its best entry), for claim ties.
    local pin_of = {}
    for i, e in ipairs(opts.pins or {}) do
        if pin_of[e.id] == nil then pin_of[e.id] = i end
    end
    -- Upstream claims: remote ref name → claiming local names.
    local claims = {}
    for _, l in pairs(locals) do
        local up = l.upstream and l.upstream.short
        if up then
            claims[up] = claims[up] or {}
            table.insert(claims[up], l.name)
        end
    end

    local by_key, of = {}, {}
    local function ident(key, name, local_name)
        local id = by_key[key]
        if not id then
            id = { key = key, name = name, local_name = local_name, members = {} }
            by_key[key] = id
            if local_name then id.members[1] = local_name; of[local_name] = id end
        end
        return id
    end
    for name in pairs(locals) do ident(name, name, name) end

    for _, r in ipairs(remote_refs) do
        local _, short = split_remote(r.name, remotes)
        local owner
        if locals[short] then
            owner = short
        elseif claims[r.name] then
            local c = claims[r.name]
            table.sort(c, function(a, b)
                local pa, pb = pin_of[a] or math.huge, pin_of[b] or math.huge
                if pa ~= pb then return pa < pb end
                return a < b
            end)
            owner = c[1]
        end
        local id = owner and ident(owner, owner, owner) or ident("remote:" .. short, short, nil)
        id.members[#id.members + 1] = r.name
        of[r.name] = id
        if owner then
            local up = locals[owner].upstream
            if up and up.short == r.name then id.upstream = r.name end
        end
    end

    local identities = {}
    for _, id in pairs(by_key) do identities[#identities + 1] = id end
    table.sort(identities, function(a, b) return a.key < b.key end)
    return { identities = identities, of = of }
end

--- Precompute the static rank info of every **ranked** ref (spec §5): the visible
--- local and remote-tracking branches of `pairing`. The caller excludes refs that
--- are filtered out, hidden or folded into a collapsed owner by leaving them out of
--- `visible` (nil = every paired ref is visible). An identity's pin rank is the
--- best index among the `pins` entries naming any of its refs (visible or not); an
--- identity whose local is not visible ranks as remote-only.
---@param pairing IdentityPairing
---@param opts? { visible?: table<string, boolean>, pins?: PinEntry[], current?: string, remotes?: string[] }
---@return table<string, RankInfo>   ref name → info (only visible ranked refs)
function M.infos(pairing, opts)
    opts = opts or {}
    local visible = opts.visible
    local function vis(name) return visible == nil or visible[name] == true end
    local remotes = opts.remotes or {}
    local remote_pos = {}
    for i, r in ipairs(remotes) do if remote_pos[r] == nil then remote_pos[r] = i end end
    local pin = {}
    for i, e in ipairs(opts.pins or {}) do
        local id = pairing.of[e.id]
        if id and pin[id.key] == nil then pin[id.key] = i end
    end
    local current_id = opts.current and pairing.of[opts.current]

    local out = {}
    for _, id in ipairs(pairing.identities) do
        local local_vis = id.local_name and vis(id.local_name) and id.local_name or nil
        local tier = pin[id.key] and 1 or (local_vis and 2 or 3)
        for _, name in ipairs(id.members) do
            if vis(name) then
                local is_local = name == id.local_name
                local info = {
                    name = name, tier = tier, pin = pin[id.key], ident = id.key,
                    ident_name = id.name, current = current_id == id, is_local = is_local,
                }
                if not is_local then
                    local remote = split_remote(name, remotes)
                    info.remote = true
                    info.local_name = local_vis
                    info.upstream = id.upstream == name
                    info.remote_idx = remote_pos[remote] or (#remotes + 1)
                end
                out[name] = info
            end
        end
    end
    return out
end

---@class RefRankInput
---@field infos table<string, RankInfo>  ref name → info, the visible ranked refs (`infos`)
---@field slots table<string, integer>   identity key → its pin rank: pinned identities
---                                      only, visible or not (§5.5 pinned colours; the
---                                      layout applies the curated-palette cap)
---@field head? string                   the current branch (a §4.2 working-tree node's ref)
---@field key string                     the whole input as a comparable string, for the
---                                      layout fingerprint (§3.1 / §10.5)

--- The layout's ranking input (spec §5 "The ranks are a layout input"): the pairing
--- of `refs`, the rank infos of the visible ranked refs, the pinned identities' slots
--- and the current branch, plus a fingerprint `key` of all of it.
---@param refs RankRef[]|table<string, RankRef>
---@param opts? { remotes?: string[], pins?: PinEntry[], visible?: table<string, boolean>, current?: string }
---@return RefRankInput
function M.input(refs, opts)
    opts = opts or {}
    local pairing = M.pair(refs, { remotes = opts.remotes, pins = opts.pins })
    local infos = M.infos(pairing, opts)
    local slots = {}
    for i, e in ipairs(opts.pins or {}) do
        local id = pairing.of[e.id]
        if id and slots[id.key] == nil then slots[id.key] = i end
    end
    local parts = { "head=" .. tostring(opts.current) }
    local names = {}
    for name in pairs(infos) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local i = infos[name]
        parts[#parts + 1] = table.concat({ name, i.tier, tostring(i.pin), i.ident, tostring(i.current),
            tostring(i.local_name), tostring(i.upstream), tostring(i.remote_idx) }, ",")
    end
    local keys = {}
    for k, v in pairs(slots) do keys[#keys + 1] = k .. "=" .. v end
    table.sort(keys)
    parts[#parts + 1] = table.concat(keys, ",")
    return { infos = infos, slots = slots, head = opts.current, key = table.concat(parts, ";") }
end

--- The rank info of the `seq`-th generated ref (spec §5): below every ranked ref,
--- the one created first winning.
---@param seq integer
---@return RankInfo
function M.generated(seq)
    return { name = "", tier = 4, seq = seq }
end

--- A ref's **standing row** (spec §5 rank rule 2): its tip's row, except that a
--- remote whose visible local's tip is at or above its own stands at the local's
--- row. `rows` maps ref name → tip row (rows grow downward); an unknown row reads
--- as -1 (above everything), though the layout only compares placed tips.
---@param info RankInfo
---@param rows table<string, integer>
---@return integer
function M.standing_row(info, rows)
    local own = rows[info.name] or -1
    if info.local_name then
        local l = rows[info.local_name]
        if l and l <= own then return l end
    end
    return own
end

--- Order two members of one identity (spec §5 rank rule 3): the local first, then
--- remotes by standing row (lower wins), the configured upstream, `git remote`
--- order, name.
---@return boolean
local function member_better(a, b, rows)
    if a.is_local ~= b.is_local then return a.is_local == true end
    local sa, sb = M.standing_row(a, rows), M.standing_row(b, rows)
    if sa ~= sb then return sa > sb end
    if (a.upstream or false) ~= (b.upstream or false) then return a.upstream == true end
    if (a.remote_idx or 0) ~= (b.remote_idx or 0) then return (a.remote_idx or 0) < (b.remote_idx or 0) end
    return a.name < b.name
end

--- Whether `a` ranks strictly better than `b` (spec §5 "Rank"): identity tier
--- (pinned by pin rank, unpinned with a visible local, remote-only, generated);
--- within the unpinned tiers the lower standing row; within one identity the local
--- first, then its remotes (`member_better`); between identities on one row the
--- current branch's identity, then name; generated refs by creation order. A total
--- order (false for `a == b`), usable as a `table.sort` comparator.
---@param a RankInfo
---@param b RankInfo
---@param rows table<string, integer>   ref name → tip row
---@return boolean
function M.better(a, b, rows)
    if a == b then return false end
    if a.tier ~= b.tier then return a.tier < b.tier end
    if a.tier == 4 then return (a.seq or 0) < (b.seq or 0) end
    if a.ident == b.ident then return member_better(a, b, rows) end
    if a.tier == 1 then
        if a.pin ~= b.pin then return a.pin < b.pin end
    else
        local sa, sb = M.standing_row(a, rows), M.standing_row(b, rows)
        if sa ~= sb then return sa > sb end
        if (a.current or false) ~= (b.current or false) then return a.current == true end
    end
    if a.ident_name ~= b.ident_name then return a.ident_name < b.ident_name end
    return a.ident < b.ident
end

--- The ref names of `infos`, best first (`better`) — the whole order at once, for
--- when every tip row is known (and for tests).
---@param infos table<string, RankInfo>
---@param rows table<string, integer>
---@return string[]
function M.order(infos, rows)
    local list = {}
    for _, info in pairs(infos) do list[#list + 1] = info end
    table.sort(list, function(a, b) return M.better(a, b, rows) end)
    local out = {}
    for i, info in ipairs(list) do out[i] = info.name end
    return out
end

return M
