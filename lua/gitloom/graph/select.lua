--- Selection & branch-mode interaction — the pure helpers behind the ref
--- selection (`h`/`l`, §2), the branch-mode cycle (§10.1), the collapse target
--- under the cursor — a row's own owners (§10.2/§10.4) and the commit-selection path walk (§13). All pure
--- (no window state): they operate on the DisplayNode graph and ref data; the
--- window glue resolves rows / lanes / ranges. Part of the gitloom graph engine.

local git = require("gitloom.git")

local M = {}

-- The branch-mode cycle order (spec §10.1), driven by `<CR>` on a selected ref.
local MODE_CYCLE = { "normal", "collapsed", "hidden" }

--- The next mode after `m` in the cycle (nil/normal → collapsed → hidden → …).
---@param m string?
---@return string
function M.next_mode(m)
    m = m or "normal"
    for i, v in ipairs(MODE_CYCLE) do
        if v == m then return MODE_CYCLE[(i % #MODE_CYCLE) + 1] end
    end
    return "collapsed"
end

--- The owner ids (repo.refs keys, i.e. view-builder owner ids) a selected ref
--- decoration stands for. A branch group covers its local ref and each remote
--- (`origin/<name>`), so they cycle together as one branch; a tag and a
--- linked-worktree label (§3.2) are each themselves.
--- Mirrors decoration_texts' order (branch groups, tags, worktrees). nil if no match.
---@param commit { refs: Ref[] }
---@param index integer  -- 1-based decoration index (selection_state.index)
---@return string[]|nil
function M.selected_owner_ids(commit, index)
    if not index then return nil end
    local g = git.group_refs(commit.refs)
    if index <= #g.branches then
        local b = g.branches[index]
        local ids = {}
        if b.has_local then ids[#ids + 1] = b.name end
        for _, r in ipairs(b.remotes) do ids[#ids + 1] = r .. "/" .. b.name end
        return #ids > 0 and ids or nil
    end
    if index <= #g.branches + #g.tags then
        local tag = g.tags[index - #g.branches]
        return tag and { tag } or nil
    end
    -- A linked-worktree label (§3.2) is an owner like any other ref; its owner id
    -- is its name (`wt:<dir>`), so selecting it collapses/expands that worktree's
    -- branch exactly as selecting a branch label does.
    local wt = g.worktrees[index - #g.branches - #g.tags]
    return wt and { wt } or nil
end

--- Move the ref selection. `nil` is the message (the default; the message is to
--- the left, refs are pinned to the right edge); 1..count are the ref
--- decorations, left to right. `l` (dir +1) moves right onto the refs starting
--- at the first; `h` (dir -1) moves back left, returning to the message past the
--- first. Clamps at the last decoration; no wrap (spec §2). `count` is the
--- number of decorations.
---@param pos integer|nil
---@param count integer
---@param dir integer
---@return integer|nil
function M.move_selection(pos, count, dir)
    if dir > 0 then
        if pos == nil then return count >= 1 and 1 or nil end
        return math.min(count, pos + 1)
    else
        if pos == nil or pos <= 1 then return nil end
        return pos - 1
    end
end

-- ── Commit selection (range) — pure path walking (spec §13) ──────────────────
-- A selection is a **path** along one branch over the **visible projection**: an
-- ordered list of DisplayNodes from the newest (top, index 1) to the oldest
-- (bottom). `anchor` is the fixed end, `cursor` the moving one; both are always
-- endpoints, so the path is exactly `anchor..cursor`. These helpers operate only
-- on the DisplayNode graph (`.parents` first = trunk, `.children`, `.hash`), so
-- they are pure and unit-testable; the window glue resolves rows/lanes/ranges.
---@class SelectionPath
---@field path table[]                 DisplayNodes, newest-first (index 1 = top)
---@field anchor table                 the fixed endpoint
---@field cursor table                 the moving endpoint
---@field dparent table<string,integer>  per-merge chosen parent index (h/l, down)
---@field dchild table<string,integer>   per-split chosen child index (h/l, up)

--- The children of `node` to ascend into, first-parent continuation(s) first
--- (a child `ch` is on the same branch when `ch.parents[1] == node`), then the
--- rest in edge order. The default ascent (index 1) keeps the mainline; `h`/`l`
--- rotate among the others at a split (§13.3).
---
--- The §4.2 **working-tree virtual commits are ascended into like any other
--- child** (§13.2): `k` from HEAD walks up the stack HEAD -> staged -> unstaged
--- -> untracked. Nothing has to stop the walk there, because a virtual commit has
--- no children -- the ascent clamps on its own, and a virtual node can therefore
--- only ever be the path's NEWEST member. Their sentinel hashes never reach a git
--- rev: `range_endpoints` maps a virtual newer end to a tree state instead
--- (§13.5), which is where that invariant lives.
---@param node table
---@return table[]
function M.sel_ascend_children(node)
    local fp, other = {}, {}
    for _, ch in ipairs(node.children or {}) do
        if (ch.parents or {})[1] == node then
            fp[#fp + 1] = ch
        else
            other[#other + 1] = ch
        end
    end
    for _, ch in ipairs(other) do fp[#fp + 1] = ch end
    return fp
end

--- 1-based cyclic rotation of index `k` within `n` by `delta` (±1).
local function sel_rotate(k, n, delta)
    return ((k - 1 + delta) % n) + 1
end
M.sel_rotate = sel_rotate

--- Step the moving end one commit along the branch (§13.2). `dir` is "down"
--- (toward parents / older) or "up" (toward children / newer). Extends when the
--- cursor is the growing end, contracts when it is the other end (moving back
--- toward the anchor). Mutates `st`; a no-op at a tip/root (nothing to extend).
---@param st SelectionPath
---@param dir "down"|"up"
function M.sel_step(st, dir)
    local path = st.path
    local n = #path
    local at_top = path[1] == st.cursor
    local at_bottom = path[n] == st.cursor
    if dir == "down" then
        if n == 1 or at_bottom then
            local node = st.cursor
            local nxt = (node.parents or {})[st.dparent[node.hash] or 1]
            if not nxt then return end
            path[#path + 1] = nxt
            st.cursor = nxt
        else -- cursor at the top end: contract from the top
            table.remove(path, 1)
            st.cursor = path[1]
        end
    else -- "up"
        if n == 1 or at_top then
            local node = st.cursor
            local kids = M.sel_ascend_children(node)
            if #kids == 0 then return end
            local nxt = kids[math.min(st.dchild[node.hash] or 1, #kids)]
            table.insert(path, 1, nxt)
            st.cursor = nxt
        else -- cursor at the bottom end: contract from the bottom
            table.remove(path)
            st.cursor = path[#path]
        end
    end
end

--- Switch which branch the path follows at the nearest junction between the
--- cursor and the anchor, on the side the path is growing (§13.3): a **merge**
--- when growing down (rotate the parent), a **split** when growing up (rotate the
--- child). `delta` is +1 (`l`) / -1 (`h`). The path is re-derived from the
--- junction onward, preserving its length where the new branch is long enough.
--- A no-op on a linear path (no junction between the ends). Returns true when a
--- switch happened. Mutates `st`.
---@param st SelectionPath
---@param delta integer
---@return boolean
function M.sel_switch(st, delta)
    local path = st.path
    local n = #path
    if n < 2 then return false end
    local growing_down = path[n] == st.cursor and path[1] == st.anchor
    local growing_up = path[1] == st.cursor and path[n] == st.anchor
    if growing_down then
        for i = n - 1, 1, -1 do -- nearest merge above the cursor
            local node = path[i]
            local parents = node.parents or {}
            if #parents > 1 then
                local cur = 1
                for k, p in ipairs(parents) do if p == path[i + 1] then cur = k break end end
                local nk = sel_rotate(cur, #parents, delta)
                if nk == cur then return false end
                st.dparent[node.hash] = nk
                local removed = n - i
                for _ = 1, removed do table.remove(path) end
                for _ = 1, removed do -- re-extend down, default continuation
                    local tail = path[#path]
                    local nxt = (tail.parents or {})[st.dparent[tail.hash] or 1]
                    if not nxt then break end
                    path[#path + 1] = nxt
                end
                st.cursor = path[#path]
                return true
            end
        end
    elseif growing_up then
        for i = 2, n do -- nearest split below the cursor
            local node = path[i]
            local kids = M.sel_ascend_children(node)
            if #kids > 1 then
                local cur = 1
                for k, ch in ipairs(kids) do if ch == path[i - 1] then cur = k break end end
                local nk = sel_rotate(cur, #kids, delta)
                if nk == cur then return false end
                st.dchild[node.hash] = nk
                local removed = i - 1
                for _ = 1, removed do table.remove(path, 1) end
                for _ = 1, removed do -- re-extend up, default continuation
                    local head = path[1]
                    local ks = M.sel_ascend_children(head)
                    if #ks == 0 then break end
                    table.insert(path, 1, ks[math.min(st.dchild[head.hash] or 1, #ks)])
                end
                st.cursor = path[1]
                return true
            end
        end
    end
    return false
end

--- Which occurrence the `index`-th of `texts` is among the labels with the same
--- text (1 = the leftmost such). Packed marker labels can repeat (two ref-less
--- markers of one size both read `(3)`), and the cursor target search
--- (`ref_byte_col`) must skip the earlier copies.
---@param texts string[]  the labels in drawn order
---@param index integer
---@return integer
function M.label_occurrence(texts, index)
    local t, nth = texts[index], 1
    for i = 1, index - 1 do
        if texts[i] == t then nth = nth + 1 end
    end
    return nth
end

--- Byte column (0-based) of `deco`'s first occurrence in a rendered row, or nil
--- if absent. Used to park the cursor on the selected ref (which the listview
--- pins to the right edge); message parking uses the listview column offset.
--- `nth` (default 1) picks a later occurrence — for repeated labels, see
--- `label_occurrence`; past the last occurrence the last one is returned (an
--- earlier copy may be hidden in a `+N` overflow).
---@param line_text string
---@param deco string
---@param nth? integer
---@return integer|nil
function M.ref_byte_col(line_text, deco, nth)
    local found, from = nil, 1
    for _ = 1, math.max(1, nth or 1) do
        local s = line_text:find(deco, from, true)
        if not s then break end
        found, from = s, s + 1
    end
    return found and (found - 1) or nil
end

-- ── Own owners: what collapse / expand act on (spec §10.2, §10.4) ───────────

--- A commit's **own owners** (spec §10.2): the owners in `sig(c)` whose tip has the
--- same signature as `c` — `own(c) = { o ∈ sig(c) : sig(tip(o)) = sig(c) }`, the
--- owners whose tip sits in `c`'s region. Over the interned signatures
--- (`sigset.of(sig)`) the test is a handle comparison, O(|sig(c)|); a plain table
--- of sets (a test, or a caller that built its own) gets a set comparison. Sorted,
--- so callers and notices are deterministic. Empty on a stretch shared below a
--- fork (no tip in the region) and on an uncovered commit.
---@param sig table?  -- hash -> owner-id set (the `view.signatures` map)
---@param hash string  -- the commit (a `◍` head: its tip, the region's newest commit)
---@param tip_of table<string, string>  -- owner id -> its tip's hash
---@return string[]
function M.own_owners(sig, hash, tip_of)
    local members = sig and sig[hash]
    if not members then return {} end
    local S = require("gitloom.graph.sigset").of(sig)
    local out = {}
    for oid in pairs(members) do
        local th = tip_of[oid]
        local same = false
        if th == hash then
            same = true
        elseif th and S then
            same = S.handles[th] ~= nil and S.handles[th] == S.handles[hash]
        elseif th then
            local ts = sig and sig[th] ---@type table<string, boolean>?
            if ts then
                same = true
                for k in pairs(ts) do if not members[k] then same = false break end end
                if same then for k in pairs(members) do if not ts[k] then same = false break end end end
            end
        end
        if same then out[#out + 1] = oid end
    end
    table.sort(out)
    return out
end

--- The owners to set normal so the commit `hash` becomes visible (spec §10.4):
--- its **own owners** that are collapsed — the least that opens it, never a
--- collapsed branch built on top — or, when it has none (a stretch shared below a
--- fork, §10.2), every collapsed owner in its signature. Empty when a normal owner
--- already reaches it (it is visible; nothing to open). Sorted. The rule behind
--- `<Space>` on a `◍`, the palette's expand, the filter jump (§16.4), the
--- §11.7.6 reveal and the selection fold toggle (§13.4).
---@param sig table?  -- hash -> owner-id set
---@param hash string  -- the commit (a head: its tip's hash)
---@param tip_of table<string, string>  -- owner id -> tip hash
---@param effective table<string, string>  -- owner id -> effective mode
---@return string[]
function M.open_owners(sig, hash, tip_of, effective)
    local members = (sig and sig[hash]) or {}
    local function mode(oid) return effective[oid] or "normal" end
    for oid in pairs(members) do
        if mode(oid) == "normal" then return {} end
    end
    local out = {}
    for _, oid in ipairs(M.own_owners(sig, hash, tip_of)) do
        if mode(oid) == "collapsed" then out[#out + 1] = oid end
    end
    if #out == 0 then
        for oid in pairs(members) do
            if mode(oid) == "collapsed" then out[#out + 1] = oid end
        end
        table.sort(out)
    end
    return out
end

--- What `<Space>` / the palette's collapse-expand act on for a row (spec §10.4):
---  * a `◍` head (`collapsed`): `expanded` → `owners` = its own owners that are
---    collapsed, or every collapsed owner in its signature when it has no own owner
---    (a stretch shared below a fork);
---  * an open row an anchor reaches: `mainline`, with the `anchors` reaching it;
---  * any other open row: `expanded`, `owners` = its normal, non-anchor own owners
---    (possibly none) and `keepers` = the normal owners that stay — branches built
---    on top, which keep the row open after the collapse.
--- `owners`, `keepers` and `anchors` are sorted owner-id lists.
---@class ToggleTarget
---@field state "expanded"|"collapsed"|"mainline"
---@field owners string[]    what collapse / expand set (own owners, §10.2)
---@field keepers string[]   normal non-own owners that keep an open row open
---@field anchors string[]   the anchors reaching a mainline row
---@field selected? string[]     window glue: the h/l-selected ref's owner ids
---@field hide_owners? string[]  window glue: what the palette's hide acts on
---@field follow? string         window glue: the hash the cursor follows
---@field commit? table          window glue: the row's commit (a head: its tip)
---@param sig table?  -- hash -> owner-id set
---@param hash string  -- the commit (a head: its tip's hash)
---@param tip_of table<string, string>  -- owner id -> tip hash
---@param pinned table<string, boolean>?  -- the anchor owner ids (§10.6)
---@param effective table<string, string>  -- owner id -> effective mode
---@param collapsed boolean?  -- the row is a `◍` head
---@return ToggleTarget
function M.toggle_target(sig, hash, tip_of, pinned, effective, collapsed)
    pinned = pinned or {}
    local owners, keepers, anchors = {}, {}, {}
    if collapsed then
        owners = M.open_owners(sig, hash, tip_of, effective)
        return { state = "collapsed", owners = owners, keepers = keepers, anchors = anchors }
    end
    local members = (sig and sig[hash]) or {}
    local own = M.own_owners(sig, hash, tip_of)
    local function mode(oid) return effective[oid] or "normal" end
    for oid in pairs(members) do
        if pinned[oid] then anchors[#anchors + 1] = oid end
    end
    if #anchors > 0 then
        table.sort(anchors)
        return { state = "mainline", owners = owners, keepers = keepers, anchors = anchors }
    end
    local is_own = {}
    for _, oid in ipairs(own) do
        is_own[oid] = true
        if mode(oid) == "normal" then owners[#owners + 1] = oid end
    end
    for oid in pairs(members) do
        if not is_own[oid] and mode(oid) == "normal" then keepers[#keepers + 1] = oid end
    end
    table.sort(keepers)
    return { state = "expanded", owners = owners, keepers = keepers, anchors = anchors }
end

--- Name a set of owners for a notice or a palette entry (spec §10.4): the ref
--- owners by their branch / tag / worktree name — a remote branch folded into its
--- short name, so `dev` and `origin/dev` read once — and the anonymous ones (the
--- §10.2 `merge:` / `tip:` families, no ref in `refs`) as a count: `feature/z +1
--- merged`, or `2 merged` with no ref at all. "" for an empty list.
---@param ids string[]
---@param refs table<string, Ref>  -- repo.refs (ref id -> Ref)
---@return string
function M.owner_label(ids, refs)
    local names, seen, anon = {}, {}, 0
    for _, id in ipairs(ids) do
        local r = refs[id]
        if not r then
            anon = anon + 1
        else
            local n = (r.kind == "remote") and (id:match("^[^/]+/(.+)$") or id) or id
            if not seen[n] then seen[n] = true; names[#names + 1] = n end
        end
    end
    table.sort(names)
    local s = table.concat(names, ", ")
    if anon > 0 then
        s = (s == "") and (anon .. " merged") or (s .. " +" .. anon .. " merged")
    end
    return s
end

-- ── Pinned branches: the ordered pin list (spec §10.6) ──────────────────────
--
-- The pinned branches are ONE ordered list, and "holds a dedicated graph column"
-- (§10.6.2) is a per-entry FLAG on it — not a second list. Two properties then
-- hold by construction instead of by discipline: `reserved` ⊆ `pinned`, and
-- **unpinning implies unreserving** (the flag leaves with its entry). Order is
-- the anchor priority, and it matters for EVERY entry: an entry's 1-based place is
-- its **rank**, which drives lane identity (§5); among reserved entries it also
-- decides the dedicated columns (§10.6.2). A pinned local branch's implicit remote
-- counterparts are not entries — they share their local's rank (`pin_rank`).
--
-- All of these are pure: they copy in and copy out, never mutating the input
-- (like `bump_recent`), so the window glue assigns the result back.

--- One entry of the pin list (spec §10.6).
---@class PinEntry
---@field id string        -- the ref-owner id (a ref name; §10)
---@field reserved boolean -- holds a dedicated graph column (§10.6.2)

---@param pins PinEntry[]?
---@return PinEntry[]
local function pin_copy(pins)
    local out = {}
    for i, e in ipairs(pins or {}) do
        out[i] = { id = e.id, reserved = e.reserved and true or false }
    end
    return out
end

--- Resolve the effective pin list (spec §10.6): the built-in default anchors the
--- user has **not** explicitly placed come first, in default order, followed by
--- the user's explicitly ordered entries in their order. An **unpinned** id is
--- suppressed wherever it would come from, and an entry naming a ref that no
--- longer exists is dropped — so the list is deterministic for an untouched
--- repository and stable once edited. A newly pinned ref is appended to the
--- stored entries (`pin_add`), so it lands at the bottom.
---@param pins PinEntry[]?                     -- the stored, user-ordered entries
---@param unpinned table<string, boolean>?     -- ids explicitly removed (suppress defaults)
---@param defaults string[]?                   -- default anchor ids, in default order
---@param exists table<string, any>?           -- live refs by id (nil = accept every id)
---@return PinEntry[]
function M.pin_resolve(pins, unpinned, defaults, exists)
    unpinned = unpinned or {}
    local out, seen, placed = {}, {}, {}
    for _, e in ipairs(pins or {}) do placed[e.id] = true end
    local function push(id, reserved)
        if not id or seen[id] or unpinned[id] then return end
        if exists and exists[id] == nil then return end
        seen[id] = true
        out[#out + 1] = { id = id, reserved = reserved and true or false }
    end
    for _, id in ipairs(defaults or {}) do
        if not placed[id] then push(id, false) end
    end
    for _, e in ipairs(pins or {}) do push(e.id, e.reserved) end
    return out
end

--- A pinned local branch's **implicit remote counterparts** (spec §10.6): every
--- remote branch with the same short name — the remotes in `git remote` order
--- (`remotes`), then any other remote's `*/<id>` the registry holds, by name (the
--- `%` cycle's members and order, §2) — then the branch's tracked upstream when
--- its short name differs. Only refs that exist; none for a non-local ref. Pure.
---@param refs table<string, Ref>?  the repo's name → Ref registry
---@param remotes string[]?         remote names in `git remote` order
---@param id string                 the pinned ref id
---@return string[]
function M.pin_counterparts(refs, remotes, id)
    local out = {}
    if not refs then return out end
    local reg = refs ---@type table<string, Ref>
    local r = reg[id]
    if not r or r.kind ~= "local" then return out end
    local seen = { [id] = true }
    local function add(name, kind)
        local x = reg[name]
        if seen[name] or not x or (kind and x.kind ~= kind) then return end
        seen[name] = true
        out[#out + 1] = name
    end
    for _, remote in ipairs(remotes or {}) do add(remote .. "/" .. id, "remote") end
    local rest = {}
    for name, x in pairs(reg) do
        if x.kind == "remote" and not seen[name] and name:match("^[^/]+/(.+)$") == id then
            rest[#rest + 1] = name
        end
    end
    table.sort(rest)
    for _, name in ipairs(rest) do add(name, "remote") end
    if r.upstream and r.upstream.short then add(r.upstream.short) end
    return out
end

--- The **pin rank** of every effectively pinned ref (spec §5/§10.6): ref id →
--- its 1-based place in the resolved list `pins` (1 = highest priority). With
--- `counterparts` on (`pin_upstream`), a local entry's implicit remote
--- counterparts (`pin_counterparts`) take its rank, unless explicitly `unpinned`
--- or already ranked — an explicitly pinned remote keeps its own place, and a
--- counterpart shared by two locals takes the better one. With `counterparts` on,
--- the keys are exactly the effective anchor set (the focus default and the pin
--- icon). With it `false` the table holds the list's entries only — that is the
--- layout's `opts.pin_rank` (§5 identity, §5.5 pinned colours), since counterparts
--- take no rank and no pinned colour (§10.6). Pure.
---@param pins PinEntry[]?                  the resolved pin list (`pin_resolve`)
---@param refs table<string, Ref>?
---@param remotes string[]?
---@param unpinned table<string, boolean>?
---@param counterparts boolean?             false = no implicit counterparts
---@return table<string, integer>
function M.pin_rank(pins, refs, remotes, unpinned, counterparts)
    unpinned = unpinned or {}
    local rank = {}
    for i, e in ipairs(pins or {}) do
        if rank[e.id] == nil then rank[e.id] = i end
    end
    if counterparts == false then return rank end
    for i, e in ipairs(pins or {}) do
        for _, cid in ipairs(M.pin_counterparts(refs, remotes, e.id)) do
            if rank[cid] == nil and not unpinned[cid] then rank[cid] = i end
        end
    end
    return rank
end

--- The **counterpart colours** layout input (spec §5.5, `opts.pin_counterpart`):
--- every implicit remote counterpart's ref id → its local's rank — exactly the keys
--- `pin_rank` adds with counterparts on, at the rank it gives them. A ref that is
--- itself an entry (an explicitly pinned remote) is not a counterpart; an explicitly
--- unpinned one is dropped. Pure.
---@param pins PinEntry[]?
---@param refs table<string, Ref>?
---@param remotes string[]?
---@param unpinned table<string, boolean>?
---@return table<string, integer>
function M.pin_counterpart_rank(pins, refs, remotes, unpinned)
    local entries = M.pin_rank(pins, refs, remotes, unpinned, false)
    local out = {}
    for id, r in pairs(M.pin_rank(pins, refs, remotes, unpinned, true)) do
        if entries[id] == nil then out[id] = r end
    end
    return out
end

--- Move the entry at `index` by `delta` places (spec §10.6.1, `<C-j>`/`<C-k>`),
--- clamped at the ends — an out-of-range move is a no-op, so the key is safely
--- repeatable. Returns the new list and the entry's new index.
---@param pins PinEntry[]?
---@param index integer
---@param delta integer
---@return PinEntry[], integer
function M.pin_move(pins, index, delta)
    local out = pin_copy(pins)
    local target = index + delta
    if not out[index] or target < 1 or target > #out then return out, index end
    table.insert(out, target, table.remove(out, index))
    return out, target
end

--- Toggle the entry's dedicated-lane flag (spec §10.6.1, `<Space>`).
---@param pins PinEntry[]?
---@param index integer
---@return PinEntry[]
function M.pin_toggle_reserved(pins, index)
    local out = pin_copy(pins)
    if out[index] then out[index].reserved = not out[index].reserved end
    return out
end

--- Unpin the entry at `index` (spec §10.6.1, `D`). The reserve flag lives ON the
--- entry, so unpin **implies** unreserve: there is nothing left behind to clear.
---@param pins PinEntry[]?
---@param index integer
---@return PinEntry[]
function M.pin_remove(pins, index)
    local out = pin_copy(pins)
    if out[index] then table.remove(out, index) end
    return out
end

--- Append `id` to the pin list if it is not already on it (the "Pin new branch…"
--- entry and the `P` key). A newly pinned branch is **not** reserved (§10.6).
---@param pins PinEntry[]?
---@param id string
---@param reserved boolean?
---@return PinEntry[]
function M.pin_add(pins, id, reserved)
    local out = pin_copy(pins)
    for _, e in ipairs(out) do if e.id == id then return out end end
    out[#out + 1] = { id = id, reserved = reserved and true or false }
    return out
end

--- The membership set of a pin list — the anchor owner ids (§10.6), which is
--- what `view.owners` / `toggle_target` consume.
---@param pins PinEntry[]?
---@return table<string, boolean>
function M.pin_ids(pins)
    local set = {}
    for _, e in ipairs(pins or {}) do set[e.id] = true end
    return set
end

--- The **reserved** ids in pin-list order (spec §10.6.2): the branches that get
--- a dedicated column, left to right, skipping the unreserved entries between
--- them. (The order also ranks every entry for lane identity — `pin_rank`.)
---@param pins PinEntry[]?
---@return string[]
function M.reserved_order(pins)
    local out = {}
    for _, e in ipairs(pins or {}) do
        if e.reserved then out[#out + 1] = e.id end
    end
    return out
end

--- The pinned-branches dialog's buffer lines (spec §10.6.1). Pure so the layout
--- is testable without a window: the entry rows carry the priority number (every
--- entry's rank, §5), the `◆` marker for a reserved entry (blank otherwise — the
--- subsequence that also claims columns), and the ref name. Implicit remote
--- counterparts are not entries, so they have no rows. The
--- static key help runs down the right; the last selectable row adds a branch.
---
--- The closing note is deliberate: the reserve flag is recorded before the
--- layout honours it, and a control whose effect is not yet built must say so
--- rather than appear to work.
---@param pins PinEntry[]?
---@return string[] lines
---@return table<integer, integer|string> rows  -- 1-based line → entry index, or "new"
function M.pin_dialog_lines(pins)
    pins = pins or {}
    local HELP = {
        "<C-j>/<C-k>  move",
        "<Space>      toggle lane",
        "D            unpin",
        "<CR>         jump to branch",
        "q            close",
    }
    local NEW = "     + Pin new branch…"
    local TITLE = "Pinned branches"
    local LEGEND = "◆ = dedicated lane"
    local NOTE = "◆ is recorded but the layout does not hold dedicated lanes yet."

    local function width(s) return vim.fn.strdisplaywidth(s) end

    -- The left column: one row per entry, then the "pin new" row.
    local left, rows = {}, {}
    for i, e in ipairs(pins) do
        left[i] = ("  %d  %s  %s"):format(i, e.reserved and "◆" or " ", e.id)
    end
    left[#pins + 1] = NEW

    local lw = width(TITLE)
    for _, s in ipairs(left) do lw = math.max(lw, width(s)) end

    local function row(l, r)
        l = l or ""
        local pad = (" "):rep(math.max(0, lw - width(l)))
        return ((l .. pad .. "    " .. (r or "")):gsub("%s+$", ""))
    end

    local lines = { row(TITLE, LEGEND), "" }
    for i = 1, math.max(#left, #HELP) do
        lines[#lines + 1] = row(left[i], HELP[i])
        if left[i] then
            rows[#lines] = (i <= #pins) and i or "new"
        end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = NOTE
    return lines, rows
end

--- Smartcase substring test (spec §16.2): `needle` matches `haystack`
--- case-insensitively unless `needle` contains an uppercase letter, in which case
--- the match is case-sensitive (like Neovim's 'smartcase'). A plain literal
--- substring — the needle is not treated as a Lua pattern.
---@param haystack string
---@param needle string
---@return boolean
function M.smartcase_match(haystack, needle)
    if needle == "" then return true end
    if needle:match("%u") then
        return haystack:find(needle, 1, true) ~= nil -- case-sensitive
    end
    return haystack:lower():find(needle, 1, true) ~= nil
end

--- The filter-search keep-set (spec §16.3): the hashes of commits whose **subject
--- or author** matches `query` (smartcase substring, §16.2). Pure over a commit
--- list; the window glue feeds repo.order's commits and hands the result to
--- `view.project` as `keep`. The query is trimmed; a blank query matches nothing
--- (the caller drops the filter rather than contracting the whole graph).
---@param commits table[]  -- Commit-likes with { hash, message?, author? }
---@param query string
---@return table<string, boolean> keep  -- matching hashes
function M.filter_keep(commits, query)
    local keep = {}
    query = query and query:gsub("^%s+", ""):gsub("%s+$", "") or ""
    if query == "" then return keep end
    for _, c in ipairs(commits or {}) do
        if c.hash and (M.smartcase_match(c.message or "", query)
                or M.smartcase_match(c.author or "", query)) then
            keep[c.hash] = true
        end
    end
    return keep
end

-- ── Row actions + checkout (spec §10.4, §10.4.1; listed by the palette, §17) ──

---@class SelectedRef
---@field kind "local"|"remote"|"tag"|"worktree"
---@field name string    the ref's name (`foo`, `origin/foo`, `v1.0`, `wt:dir`)
---@field short? string  a remote branch's name without its remote (`foo`)
---@field upstream? Upstream  a local branch's tracking data (§6.3), for the branch sync (§17.2)
---@field counterpart? LocalCounterpart  a remote branch: the local branch of its name at
---                   another commit (§10.4.1; set by the window from the ref registry)
---@field current? boolean  a counterpart: it is the current branch (the cached decoration —
---                   labels only; what runs is decided from a fresh probe)

---@class LocalCounterpart: SelectedRef
---@field at? string  the remote branch's own commit — what its detached checkout checks out

--- The ref a selected decoration (selection_state.index) names, for checkout
--- (§10.4.1). A branch group stands for its **local** branch when it has one,
--- else its first remote. Mirrors decoration_texts' order (branch groups, tags,
--- worktrees), like `selected_owner_ids`. nil when nothing is selected. Pure.
---@param commit { refs: Ref[] }?
---@param index integer?
---@return SelectedRef?
function M.selected_ref(commit, index)
    if not commit or not index then return nil end
    local g = git.group_refs(commit.refs)
    if index <= #g.branches then
        local b = g.branches[index]
        if b.has_local then return { kind = "local", name = b.name, upstream = b.track } end
        if b.remotes[1] then
            return { kind = "remote", name = b.remotes[1] .. "/" .. b.name, short = b.name }
        end
        return { kind = "local", name = b.name } -- malformed remote: the raw name
    end
    if index <= #g.branches + #g.tags then
        local tag = g.tags[index - #g.branches]
        return tag and { kind = "tag", name = tag } or nil
    end
    local wt = g.worktrees[index - #g.branches - #g.tags]
    return wt and { kind = "worktree", name = wt } or nil
end

--- The local branch a selected **remote** branch `origin/foo` would collide with
--- (§10.4.1): the local `foo` in the repo's ref registry, when it exists at a
--- commit other than `origin/foo`'s. Returned as a local SelectedRef (its
--- tracking data, `current` when it is `head`, `at` = the remote's commit). nil
--- for any other ref, without a local `foo`, or when both are on one commit (then
--- they are one branch group, which checks out the local branch anyway). Pure.
---@param ref SelectedRef?
---@param refs table<string, Ref>?  the repo's name → Ref registry
---@param head string?  the current branch (`repo.head`); nil when detached
---@return LocalCounterpart?
function M.local_counterpart(ref, refs, head)
    if not ref or ref.kind ~= "remote" or not ref.short or not refs then return nil end
    local l, r = refs[ref.short], refs[ref.name]
    if not l or l.kind ~= "local" or not l.commit then return nil end
    local at = r and r.commit and r.commit.hash
    if at and l.commit.hash == at then return nil end
    return { kind = "local", name = l.name, upstream = l.upstream, current = head == l.name, at = at }
end

--- The one local branch `commit` carries, as a SelectedRef — what the branch
--- sync (§17.2) acts on for a collapsed head or a selected packed marker when no
--- ref is selected with h/l. nil when it carries none, or several (ambiguous —
--- the user selects one). Pure.
---@param commit { refs: Ref[] }?
---@return SelectedRef?
function M.sole_local_ref(commit)
    if not commit then return nil end
    local found
    for i, b in ipairs(git.group_refs(commit.refs).branches) do
        if b.has_local then
            if found then return nil end
            found = i
        end
    end
    return found and M.selected_ref(commit, found) or nil
end

--- The commit HEAD points at (§2/§3.2): the current branch's commit, or the
--- checked-out commit itself on a **detached** HEAD — HEAD is always an anchor
--- (§10.6), so a detached HEAD is as much something to focus as a branch. nil only
--- when there is no HEAD commit (an empty repository). The open focus, the return
--- to the graph and the context panes (§6.2) all read HEAD through this. Pure.
---@param refs table<string, Ref>?  the repo's name → Ref registry
---@return string?
function M.head_target(refs)
    local h = refs and refs["HEAD"]
    return h and h.commit and h.commit.hash or nil
end

--- Whether the pin dialog's "Pin new branch…" picker (§10.6.1) offers `item` (a
--- `ref_picker_items` entry): anything not already on the list (`on`, the pinned
--- id set), except an **attached** HEAD — its branch is the owner, so the `HEAD`
--- ref would be an inert row (§10.6). A **detached** HEAD (`head_branch` nil) is
--- an owner of its own, so after an unpin it can be pinned back here. Pure.
---@param item { name: string, kind: string }
---@param on table<string, boolean>
---@param head_branch string?  the current branch (`repo.head`); nil when detached
---@return boolean
function M.pin_candidate(item, on, head_branch)
    if on[item.name] then return false end
    return item.kind ~= "head" or head_branch == nil
end

--- The real commit a row acts on (the palette's row entries, §17; `<CR>`'s commit
--- view, §11.1): a collapsed head stands for its tip (its own `hash` is a
--- synthetic `collapsed:` id, never a rev). Pure.
---@param commit table?
---@return table?
function M.menu_target(commit)
    if commit and commit.collapsed then return commit.tip end
    return commit
end

---@class CheckoutSpec
---@field argv string[]   the git command (never forcing)
---@field label string    the menu entry, saying what will happen

--- What checking out `commit` with `ref` selected runs (§10.4.1): a local branch
--- → `git switch <name>`; a remote branch → `git switch <short>` (git's DWIM
--- creates the local tracking branch) — unless a local branch of that name sits
--- at another commit (`ref.counterpart`), when DWIM would silently switch to it:
--- then the detached checkout of the remote's commit (the palette adds the
--- explicit checkout-and-sync entry beside it); a tag, a worktree label, or no
--- ref → `git checkout --detach <hash>`. nil for a §4.2 working-tree virtual
--- commit (or no commit) — there is nothing to check out. Never forces. Pure.
---@param commit table?
---@param ref SelectedRef?
---@return CheckoutSpec?
function M.checkout_spec(commit, ref)
    local c = M.menu_target(commit)
    if not c or c.virtual or not c.hash then return nil end
    if ref and ref.kind == "local" then
        return { argv = { "git", "switch", ref.name }, label = "Checkout branch " .. ref.name }
    end
    if ref and ref.kind == "remote" and ref.counterpart then
        local h = ref.counterpart.at or c.hash
        return { argv = { "git", "checkout", "--detach", h },
            label = ("Checkout commit %s (detached)"):format(h:sub(1, 7)) }
    end
    if ref and ref.kind == "remote" then
        return { argv = { "git", "switch", ref.short },
            label = ("Checkout branch %s (from %s)"):format(ref.short, ref.name) }
    end
    return { argv = { "git", "checkout", "--detach", c.hash },
        label = ("Checkout commit %s (detached)"):format(c.hash:sub(1, 7)) }
end

---@class RefCycleMember
---@field name string   the ref's name (`dev`, `origin/dev`)
---@field kind "local"|"remote"
---@field hash string   the commit it points at

--- The local ⇄ remote cycle of the branch short name `short` (§2, `%`): the local
--- branch `short` first, then `<remote>/short` for each remote in `remotes` order
--- (`git remote`), then any other remote's `*/short` the registry holds, sorted
--- (covers a remote list that has not loaded yet). Only refs that exist and point
--- at a commit. Matched by name, never by upstream configuration; members on the
--- same commit are all included. Pure.
---@param refs table<string, Ref>?  the repo's name → Ref registry
---@param remotes string[]?  remote names in `git remote` order
---@param short string?
---@return RefCycleMember[]
function M.ref_cycle_members(refs, remotes, short)
    local out, seen = {}, {}
    if not refs or not short then return out end
    local function add(name, kind)
        local r = refs[name]
        if seen[name] or not r or r.kind ~= kind or not r.commit then return end
        seen[name] = true
        out[#out + 1] = { name = name, kind = kind, hash = r.commit.hash }
    end
    add(short, "local")
    for _, remote in ipairs(remotes or {}) do add(remote .. "/" .. short, "remote") end
    local rest = {}
    for name, r in pairs(refs) do
        if r.kind == "remote" and not seen[name] and name:match("^[^/]+/(.+)$") == short then
            rest[#rest + 1] = name
        end
    end
    table.sort(rest)
    for _, name in ipairs(rest) do add(name, "remote") end
    return out
end

--- The ref `%` starts from on a row (§2): the decoration selected with `h`/`l`
--- (`index`), else the row's first branch label — HEAD's branch first on the HEAD
--- row, as `group_refs` orders it. A branch group stands for its local branch
--- (as `selected_ref`). nil when nothing qualifies: no selection and no branch
--- label (a tag- / worktree- / detached-HEAD-only or ref-less row). A selected tag
--- or worktree is returned as is — `ref_cycle_next` refuses it. Pure.
---@param commit { refs: Ref[] }?
---@param index integer?
---@return SelectedRef?
function M.cycle_source(commit, index)
    if not commit then return nil end
    if index then return M.selected_ref(commit, index) end
    if #git.group_refs(commit.refs).branches == 0 then return nil end
    return M.selected_ref(commit, 1)
end

--- The set of commit hashes a jump can land on in the projection `display` (§2):
--- every row's commit, every hash a collapsed head's region folds in, and every
--- packed marker with its region — exactly what the window's `goto_hash` finds.
--- A hash outside it is hidden (a `hidden` branch, or filtered out). Pure.
---@param display OrderItem[]?
---@return table<string, boolean>
function M.visible_hashes(display)
    local out = {}
    for _, it in ipairs(display or {}) do
        local c = it.commit
        if c and c.hash then out[c.hash] = true end
        if c and c.collapsed then
            for _, h in ipairs(c.region or {}) do out[h] = true end
        end
        if it.type == "markers" then
            for _, m in ipairs(it.markers or {}) do
                if m.hash then out[m.hash] = true end
                for _, h in ipairs(m.region or {}) do out[h] = true end
            end
        end
    end
    return out
end

--- The ref `%` moves to from `current` (a local or remote branch name; §2): the
--- member after it in `ref_cycle_members`, wrapping round, skipping any member
--- whose commit is not in `visible` (a `visible_hashes` set; nil = all visible),
--- so the cycle steps past a hidden ref instead of sticking on it. On failure
--- returns nil and the reason: `"none"` when `current` is not a local / remote
--- branch in `refs` (a tag, a worktree, HEAD, unknown), `"alone"` (plus the short
--- name) when the cycle has no other member, `"hidden"` (plus the short name) when
--- it has others but none is visible. Pure.
---@param refs table<string, Ref>?
---@param remotes string[]?
---@param current string?
---@param visible table<string, boolean>?
---@return RefCycleMember? next
---@return RefCycleMember[]|"none"|"alone"|"hidden" members_or_reason
---@return string? short  the branch's short name
function M.ref_cycle_next(refs, remotes, current, visible)
    local r = refs and current and refs[current]
    if not r or (r.kind ~= "local" and r.kind ~= "remote") then return nil, "none" end
    local short = current --[[@as string]]
    if r.kind == "remote" then short = short:match("^[^/]+/(.+)$") or short end
    local members = M.ref_cycle_members(refs, remotes, short)
    if #members < 2 then return nil, "alone", short end
    local at = 0
    for i, m in ipairs(members) do
        if m.name == current then at = i; break end
    end
    for k = 1, #members do
        local m = members[(at + k - 1) % #members + 1]
        if m.name ~= current and (not visible or visible[m.hash]) then return m, members, short end
    end
    return nil, "hidden", short
end

return M
