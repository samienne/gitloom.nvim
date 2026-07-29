--- Selection & branch-mode interaction — the pure helpers behind the ref
--- selection (`h`/`l`, §2), the branch-mode cycle (§10.1), the collapse target
--- under the cursor (§10.4) and the commit-selection path walk (§13). All pure
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
--- (`origin/<name>`), so they cycle together as one branch; a tag is itself.
--- Mirrors decoration_texts' order (branch groups then tags). nil if no match.
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
    local tag = g.tags[index - #g.branches]
    return tag and { tag } or nil
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

--- Byte column (0-based) of `deco`'s first occurrence in a rendered row, or nil
--- if absent. Used to park the cursor on the selected ref (which the listview
--- pins to the right edge); message parking uses the listview column offset.
---@param line_text string
---@param deco string
---@return integer|nil
function M.ref_byte_col(line_text, deco)
    local s = line_text:find(deco, 1, true)
    return s and (s - 1) or nil
end

--- The owner ids whose collapse turns the region containing a shown commit into
--- a marker (spec §10.4): every non-anchor owner currently keeping it visible.
--- Returns nil when the commit is **mainline** (a pinned anchor reaches it, so it
--- can't be collapsed) or nothing normal keeps it visible. Used by the `<Tab>`
--- collapse toggle and the `<CR>` menu to act on the region under the cursor
--- without needing a ref.
---@param sig table<string, boolean>?  -- the commit's signature (owner id set)
---@param pinned table<string, boolean>?  -- the anchor owner ids (§10.6)
---@param effective table<string, string>  -- owner id → effective mode
---@return string[]|nil
function M.collapse_owners(sig, pinned, effective)
    if not sig then return nil end
    pinned = pinned or {}
    for pid in pairs(pinned) do
        if sig[pid] then return nil end -- on an anchor's line: not collapsible
    end
    local out = {}
    for oid in pairs(sig) do
        if not pinned[oid] and (effective[oid] or "normal") == "normal" then
            out[#out + 1] = oid
        end
    end
    return (#out > 0) and out or nil
end

-- ── Pinned branches: the ordered pin list (spec §10.6) ──────────────────────
--
-- The pinned branches are ONE ordered list, and "holds a dedicated graph column"
-- (§10.6.2) is a per-entry FLAG on it — not a second list. Two properties then
-- hold by construction instead of by discipline: `reserved` ⊆ `pinned`, and
-- **unpinning implies unreserving** (the flag leaves with its entry). Order is
-- the anchor priority; it is *meaningful only among reserved entries*, so an
-- unreserved entry's position is latent until it is reserved.
--
-- All of these are pure: they copy in and copy out, never mutating the input
-- (like `bump_recent`), so the window glue assigns the result back.

--- One entry of the pin list (spec §10.6).
---@class PinEntry
---@field id string        -- the ref-owner id (a ref name; §10)
---@field reserved boolean -- holds a dedicated graph column (§10.6.2)
---@field auto? string     -- pinned as the pair of this local branch (§6.3 pin-the-pair);
---                       -- the entry is dropped when its source leaves the list

---@param pins PinEntry[]?
---@return PinEntry[]
local function pin_copy(pins)
    local out = {}
    for i, e in ipairs(pins or {}) do
        out[i] = { id = e.id, reserved = e.reserved and true or false, auto = e.auto }
    end
    return out
end

--- Resolve the effective pin list (spec §10.6): the user's explicitly ordered
--- entries first, in their order, then the built-in default anchors that are not
--- already on it. An **unpinned** id is suppressed wherever it would come from,
--- and an entry naming a ref that no longer exists is dropped — so the list is
--- deterministic for an untouched repository and stable once edited.
---@param pins PinEntry[]?                     -- the stored, user-ordered entries
---@param unpinned table<string, boolean>?     -- ids explicitly removed (suppress defaults)
---@param defaults string[]?                   -- default anchor ids, in default order
---@param exists table<string, any>?           -- live refs by id (nil = accept every id)
---@return PinEntry[]
function M.pin_resolve(pins, unpinned, defaults, exists)
    unpinned = unpinned or {}
    local out, seen = {}, {}
    local function push(id, reserved, auto)
        if not id or seen[id] or unpinned[id] then return end
        if exists and exists[id] == nil then return end
        seen[id] = true
        out[#out + 1] = { id = id, reserved = reserved and true or false, auto = auto }
    end
    for _, e in ipairs(pins or {}) do push(e.id, e.reserved, e.auto) end
    for _, id in ipairs(defaults or {}) do push(id, false) end
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
--- what `view.owners` / `collapse_owners` consume.
---@param pins PinEntry[]?
---@return table<string, boolean>
function M.pin_ids(pins)
    local set = {}
    for _, e in ipairs(pins or {}) do set[e.id] = true end
    return set
end

--- The **reserved** ids in pin-list order (spec §10.6.2): the branches that get
--- a dedicated column, left to right, skipping the unreserved entries between
--- them. This is the whole of what the list's order means to the layout, so
--- moving an unreserved entry leaves it unchanged.
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
--- is testable without a window: the entry rows carry the priority number, the
--- `◆` marker for a reserved entry (blank otherwise — which is what makes
--- "order matters only among the reserved" visible), and the ref name; the
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

return M
