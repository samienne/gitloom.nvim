--- Phase 2 of the graph pipeline — rendering glyphs, colour and row content from
--- the laid-out columns (see lua/gitloom/graph/columns.lua for Phase 1). Pure
--- given its inputs (GraphOptions + the laid OrderItems): produces compose-style
--- `{ text, highlight }` rows and DisplayElements the listview draws. The window
--- glue owns the buffer; this owns the picture. Part of the gitloom graph engine.

local color = require("gitloom.graph.color")
local util = require("gitloom.util")
local git = require("gitloom.git")

local highlight_text = util.highlight_text
local compose = util.compose

local M = {}

-- The lane-id debug overlay (toggled by `i`) is per-window instance state on
-- `opts.show_lane_ids` (owned by the controller), not engine module state — the
-- renderer only reads it from the GraphOptions it is handed.

-- ── Reachability dimming + generated colours (specification.md §12.2, §5.5) ──

-- A dimmed derivative of a highlight group: resolve its fg, blend it toward
-- Normal's bg by the palette's dim factor, and cache a `GitloomDim_*` group with
-- that color. Without truecolor we cannot blend rgb, so fall back to a flat group.
local DIM_FALLBACK = "NonText"
M.DIM_FALLBACK = DIM_FALLBACK
local dim_cache = {}
-- Counterpart-variant group name → the slot group it was blended from (§5.5). Names
-- are deterministic (group + factor), so this survives a ColorScheme reset intact.
local cp_source = {}

---@param fg integer
---@param bg integer
---@param alpha number  fraction blended toward bg (0 = fg, 1 = bg)
---@return integer
local function blend_color(fg, bg, alpha)
    local function chan(f, b)
        return math.floor(f * (1 - alpha) + b * alpha + 0.5)
    end
    local fr, fg2, fb = math.floor(fg / 65536) % 256, math.floor(fg / 256) % 256, fg % 256
    local br, bg2, bb = math.floor(bg / 65536) % 256, math.floor(bg / 256) % 256, bg % 256
    return chan(fr, br) * 65536 + chan(fg2, bg2) * 256 + chan(fb, bb)
end

--- A dimmed version of `group`, blended toward the Normal background by the
--- palette's dim factor (specification.md §12.2). Cached per (group, factor);
--- the cache is cleared on ColorScheme (the derived groups are wiped by
--- `hi clear`). Returns a flat fallback group when truecolor is off.
---@param opts GraphOptions
---@param group string|nil
---@return string|nil
function M.dim_hl(opts, group)
    if not group then return nil end
    if not vim.o.termguicolors then return DIM_FALLBACK end
    local factor = (opts.palette and type(opts.palette.dim) == "number") and opts.palette.dim or 0.45
    -- A COUNTERPART lane's colour out of the cone (§12.2): not the cone dim on top of
    -- its light dim, but ITS SLOT COLOUR blended by the out-of-cone counterpart factor
    -- — `palette.counterpart_dim_out`, default `0.75 * dim` — so it reads a shade
    -- BRIGHTER than every other dimmed lane, its own pinned lane's included.
    local src_group = cp_source[group]
    if src_group then
        local out = (opts.palette and type(opts.palette.counterpart_dim_out) == "number")
            and opts.palette.counterpart_dim_out or 0.75 * factor
        return M.counterpart_hl(opts, src_group, out, "GitloomCpDim_")
    end
    local key = group .. "\x1f" .. tostring(factor)
    if dim_cache[key] then return dim_cache[key] end

    local ok_src, src = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
    local ok_norm, normal = pcall(vim.api.nvim_get_hl, 0, { name = "Normal", link = false })
    normal = (ok_norm and normal) or {}
    local fg = (ok_src and src and src.fg) or normal.fg
    if not fg then return DIM_FALLBACK end
    -- A transparent colorscheme leaves Normal without a bg; blend toward the
    -- editor's background tone so dimming still preserves hue (not a flat grey).
    local bg = normal.bg or ((vim.o.background == "light") and 0xffffff or 0x000000)

    local name = "GitloomDim_" .. group:gsub("%W", "_") .. "_" .. tostring(math.floor(factor * 100))
    pcall(vim.api.nvim_set_hl, 0, name, { fg = blend_color(fg, bg, factor) })
    dim_cache[key] = name
    return name
end

--- The **counterpart variant** of lane colour `group` (spec §5.5 "Counterpart
--- colours"): the same hue blended lightly toward the Normal background by
--- `palette.counterpart_dim` (default 0.25 — much lighter than the §12 cone dim).
--- Cached in the dim cache (so the ColorScheme reset clears it too). Without
--- truecolor it is `group` itself. Out of the cone `dim_hl` of this group does NOT
--- compose: it blends the slot colour by `counterpart_dim_out` (default
--- `0.75 * dim`), lighter than the cone dim every other lane gets (§12.2).
---
--- `factor` / `prefix` override the blend and the group-name prefix: `dim_hl` uses
--- them for the same lane OUT of the cone (§12.2), which is not a composition.
---@param opts GraphOptions
---@param group string|nil
---@param factor? number
---@param prefix? string
---@return string|nil
function M.counterpart_hl(opts, group, factor, prefix)
    if not group or not vim.o.termguicolors then return group end
    factor = factor or ((opts.palette and type(opts.palette.counterpart_dim) == "number")
        and opts.palette.counterpart_dim or 0.25)
    prefix = prefix or "GitloomCp_"
    local key = "cp:" .. prefix .. group .. ":" .. tostring(factor)
    if dim_cache[key] then return dim_cache[key] end
    local ok_src, src = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
    local ok_norm, normal = pcall(vim.api.nvim_get_hl, 0, { name = "Normal", link = false })
    normal = (ok_norm and normal) or {}
    local fg = ok_src and src and src.fg
    if not fg then return group end
    local bg = normal.bg or ((vim.o.background == "light") and 0xffffff or 0x000000)
    local name = prefix .. group:gsub("%W", "_") .. "_" .. tostring(math.floor(factor * 100))
    pcall(vim.api.nvim_set_hl, 0, name, { fg = blend_color(fg, bg, factor) })
    dim_cache[key] = name
    if prefix == "GitloomCp_" then cp_source[name] = group end
    return name
end

--- Clear the dim-group cache (the derived groups are wiped by `hi clear` on a
--- ColorScheme change); they are recreated lazily on the next render.
function M.reset_dim_cache()
    for k in pairs(dim_cache) do dim_cache[k] = nil end
end

-- Generated lane colours (specification.md §5.5): lane colour slots beyond
-- `#palette.tracks` are overflow colours generated in OKLCH. Each is realised
-- lazily into a cached `GitloomGen_*` highlight group (mirroring dim_hl), wiped
-- and recomputed on ColorScheme. The lightness/chroma anchor is derived once
-- from the curated `tracks` (so generated colours sit in the theme's key).
local gen_cache = {}      -- ordinal -> highlight group name
local gen_anchor = nil    -- { L, C, base_hue } cached anchor

---@param opts GraphOptions
---@return { L: number, C: number, base_hue: number }
local function generated_anchor(opts)
    if gen_anchor then return gen_anchor end
    local tracks = (opts.palette and opts.palette.tracks) or {}
    local explicit = opts.palette and opts.palette.anchor
    local Ls, Cs, first_h = {}, {}, nil
    for _, grp in ipairs(tracks) do
        local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = grp, link = false })
        if ok and hl and hl.fg then
            local L, C, H = color.rgb_to_oklch(hl.fg)
            Ls[#Ls + 1] = L; Cs[#Cs + 1] = C
            first_h = first_h or H
        end
    end
    local function mean(t, d)
        if #t == 0 then return d end
        local s = 0
        for _, v in ipairs(t) do s = s + v end
        return s / #t
    end
    gen_anchor = {
        L = (explicit and explicit.L) or mean(Ls, 0.72),
        C = (explicit and explicit.C) or mean(Cs, 0.12),
        base_hue = (explicit and explicit.base_hue) or first_h or 0,
    }
    return gen_anchor
end

--- Highlight group for the `ordinal`-th generated lane colour (1-based). Without
--- truecolor (where Phase 1 won't mint generated slots anyway) it degrades to a
--- curated colour so nothing renders blank.
---@param opts GraphOptions
---@param ordinal integer
---@return string|nil
local function generated_hl(opts, ordinal)
    local tracks = (opts.palette and opts.palette.tracks) or {}
    if not vim.o.termguicolors then
        return tracks[((ordinal - 1) % math.max(#tracks, 1)) + 1]
    end
    if gen_cache[ordinal] then return gen_cache[ordinal] end
    local rgb = color.generate(generated_anchor(opts), ordinal)
    local name = "GitloomGen_" .. ordinal
    pcall(vim.api.nvim_set_hl, 0, name, { fg = rgb })
    gen_cache[ordinal] = name
    return name
end

--- Clear the generated-colour caches (groups wiped by `hi clear`, and the anchor
--- may shift with the theme); recreated lazily on the next render.
function M.reset_gen_cache()
    gen_anchor = nil
    for k in pairs(gen_cache) do gen_cache[k] = nil end
end

-- ── Ref decorations (specification.md §6) ───────────────────────────────────

--- The label marks a label render is given (§6/§10.6): the **effective** pinned
--- ref ids (ref names, as `repo.refs` keys them — so the default anchors and an
--- implicit remote counterparts of a pinned local branch are in it) and the icon to
--- prefix a pinned label with, plus the **expanded** ref ids (§6 "Expanded marker":
--- effective normal while the §10.7 default is collapsed) and their icon, drawn
--- after the pin icon. Passed in by the caller so the renderer stays pure; nil = no
--- label icons.
---@class PinMarks
---@field set table<string, boolean>  pinned ref ids
---@field icon? string  the label prefix (default "⚲"; "" turns it off)
---@field expanded? table<string, boolean>  expanded ref ids (§6); nil = none
---@field expanded_icon? string  their prefix, after the pin icon (default "▾"; "" turns it off)

--- The expanded icon (§6), or "" when `marks` has none.
---@param pins PinMarks?
---@return string
local function expanded_icon(pins)
    local i = pins and pins.expanded_icon
    if i == nil then i = "▾" end
    return i
end

--- The label icons for a ref name (§6): the pin icon when it is pinned, then the
--- expanded icon when it is expanded; "" when neither.
---@param pins PinMarks?
---@param name string
---@return string
function M.name_pin(pins, name)
    if not pins then return "" end
    local out = ""
    if pins.set and pins.set[name] then out = pins.icon or "⚲" end
    if pins.expanded and pins.expanded[name] then out = out .. expanded_icon(pins) end
    return out
end

--- Whether any ref of a branch group is in `set`: its local branch or any of its
--- listed `remote/name` refs. The bare name is a ref only when a local exists (or
--- the group is a malformed remote shown raw) — a remote-only group must not be
--- marked by a same-named local branch sitting elsewhere.
---@param set table<string, boolean>?
---@param b RefGroup
---@return boolean
local function group_in(set, b)
    if not set then return false end
    if (b.has_local or #b.remotes == 0) and set[b.name] then return true end
    for _, r in ipairs(b.remotes) do
        if set[r .. "/" .. b.name] then return true end
    end
    return false
end

--- The label icons for a branch group (§6): the pin icon when any ref of it is
--- pinned, then the expanded icon when any is expanded. HEAD's group (`current`)
--- never carries either — HEAD is already singled out by its place and colour.
---@param pins PinMarks?
---@param b RefGroup
---@return string
function M.group_pin(pins, b)
    if b.current or not pins then return "" end
    local out = group_in(pins.set, b) and (pins.icon or "⚲") or ""
    if group_in(pins.expanded, b) then out = out .. expanded_icon(pins) end
    return out
end

--- The plain text of each selectable ref decoration on a commit, in selection
--- order (branch groups — the current branch's `(HEAD → name)` first — then tags,
--- then linked-worktree labels §3.2). The single source of truth so the rendered
--- text and the cursor-target search use byte-identical strings. A detached
--- HEAD's bare `HEAD` is not selectable, so it is not listed here.
---@param commit { refs: Ref[] }?   only the ref list is read
---@param head_branch? string  fallback current branch when the head ref does not name it
---@param pins? PinMarks  the effective pin set + icon (§6/§10.6); nil = no pin icons
---@return string[]
function M.decoration_texts(commit, head_branch, pins)
    local g = git.group_refs(commit and commit.refs or {}, head_branch)
    local out = {}
    for _, b in ipairs(g.branches) do
        local t = "(" .. (b.current and git.HEAD_ARROW or "") .. M.group_pin(pins, b) .. b.name
        if #b.remotes > 0 then
            t = t .. " ↑" .. table.concat(b.remotes, ",")
        end
        out[#out + 1] = t .. git.track_label(b.track) .. ")"
    end
    for _, tag in ipairs(g.tags) do
        out[#out + 1] = "[" .. M.name_pin(pins, tag) .. tag .. "]"
    end
    -- A worktree label already carries its `wt:` stem (§4.1); the braces are the
    -- kind bracket, matching ( ) for branches and [ ] for tags.
    for _, wt in ipairs(g.worktrees) do
        out[#out + 1] = "{" .. M.name_pin(pins, wt) .. wt .. "}"
    end
    return out
end

--- The labels to draw for a commit in a topology PANE (header/footer), as
--- `{ text, kind }` segments so each can be coloured by kind ("head"|"branch"|"remote"|
--- "tag"|"worktree") the same way the main view colours them (§6). HEAD's label comes
--- first: the **current branch** as `(HEAD → name)` with kind "head" (the HEAD colour),
--- or, on a **detached HEAD** (a head marker with no current branch), a bare `HEAD`.
--- The head ref's `branch` identifies the current branch; `head_branch` (= repo.head)
--- is the fallback for a ref list that does not carry it. `key` is the label's
--- `label_owner` key, so the pane can give its row's lane colour to the owner only.
---@param commit { refs: Ref[] }?
---@param head_branch string?  -- the current branch (coloured as HEAD); nil when detached
---@param pins? PinMarks  the pin set + icon (§6/§10.6); nil = no pin icons
---@return { text: string, kind: string, key: string, hl: string?, arrow: integer[]? }[]
function M.pane_labels(commit, head_branch, pins)
    local g = git.group_refs(commit and commit.refs or {}, head_branch)
    -- Per-ref colour override (§11.7.6): a tag with `hl` (a pointer mark) keeps
    -- its colour in the panes too, so the new/old labels match the main view.
    local hl_by_name = {}
    for _, r in ipairs((commit and commit.refs) or {}) do
        if r.hl and r.name then hl_by_name[r.name] = r.hl end
    end
    local out = {}
    -- Detached HEAD: no branch to colour, so show the bare HEAD marker.
    if g.head and not g.current then out[#out + 1] = { text = "HEAD", kind = "head", key = "HEAD" } end
    for _, b in ipairs(g.branches) do
        local t = "(" .. (b.current and git.HEAD_ARROW or "") .. M.group_pin(pins, b) .. b.name
        if #b.remotes > 0 then t = t .. " ↑" .. table.concat(b.remotes, ",") end
        -- The current branch takes the HEAD colour; others their own kind. `arrow`
        -- is the `HEAD → ` prefix's byte span (1-based, inclusive): it keeps the
        -- HEAD colour when the rest takes the lane colour (§6 "Label colour").
        out[#out + 1] = { text = t .. ")", kind = b.current and "head" or (b.has_local and "branch" or "remote"),
            key = "b:" .. b.name, arrow = b.current and { 2, 1 + #git.HEAD_ARROW } or nil }
    end
    for _, tag in ipairs(g.tags) do
        out[#out + 1] = { text = "[" .. M.name_pin(pins, tag) .. tag .. "]", kind = "tag", key = "t:" .. tag,
            hl = hl_by_name[tag] }
    end
    for _, wt in ipairs(g.worktrees) do
        out[#out + 1] = { text = "{" .. M.name_pin(pins, wt) .. wt .. "}", kind = "worktree", key = "w:" .. wt }
    end
    return out
end

--- The selectable units of a packed marker-group row (spec §10.4): one per
--- marker, its text being the marker's ref decoration(s) or a "(N)" count when
--- it carries no ref. Used for rendering, `h`/`l` selection, and `<CR>` expand.
--- `decos` / `keys` are the separate labels (empty for a count-only unit) and their
--- `label_owner` keys, so each label can be coloured on its own (§6 "Label colour").
---@param item OrderItem  -- a type == "markers" item
---@param pins? PinMarks  the pin set + icon (§6/§10.6); nil = no pin icons
---@return { marker: table, text: string, decos: string[], keys: string[] }[]
function M.marker_units(item, pins)
    local units = {}
    for _, m in ipairs(item.markers or {}) do
        local decos = M.decoration_texts(m, nil, pins)
        local text = (#decos > 0) and table.concat(decos, " ") or ("(" .. (m.count or 0) .. ")")
        units[#units + 1] = { marker = m, text = text, decos = decos, keys = M.decoration_keys(m) }
    end
    return units
end

-- ── Segment colour + column glyphs (specification.md §5, §12) ───────────────

--- Whether a Segment draws any highlighted edge (specification.md §12). A
--- segment-level `highlighted` boolean takes precedence when set — the context
--- panes use it (their header segments carry no per-edge `edges`, so the cone is
--- propagated onto the segment directly; §6.2 reachability emphasis).
---@param seg Segment
---@return boolean
local function seg_hl(seg)
    if seg.highlighted ~= nil then return seg.highlighted end
    for _, e in ipairs(seg.edges or {}) do
        if e.highlighted then return true end
    end
    return false
end
M.seg_hl = seg_hl

--- The palette slot a Segment renders in: with `emphasis`, a highlighted edge's
--- colour wins (so the cone colour shows); otherwise (and as the fallback) the
--- segment's own slot — so colour is pivot-independent when emphasis is off.
---@param seg Segment|nil
---@param emphasis boolean|nil
---@return integer|nil
local function seg_color(seg, emphasis)
    if not seg then return nil end
    if emphasis then
        for _, e in ipairs(seg.edges or {}) do
            if e.highlighted and e.color then return e.color end
        end
    end
    return seg.color
end

--- The "top" Segment a Column's glyph takes its colour/dim from. With
--- `emphasis`, prefers a highlighted Segment so the cone colour wins a shared
--- cell (§12.2): a highlighted vertical (down then up), then a single-sided
--- fan/branch stub, then a both-sided bus when the cell has no through-vertical
--- (a ┴/┬ fan, never a │ crossing). Without emphasis (or as fallback) it is the
--- plain §5 down-before-up order, so the picture is pivot-independent.
---
--- `own_lane_up` INVERTS that vertical preference for this one cell: take the colour
--- from the wire arriving from **above**. Set by the layout only on a node whose
--- **own** lane is the up wire while a different lane leaves below — today only the
--- `gutter` policy's licensed parent swap (§5.6). Down-before-up is a stand-in for
--- "the node's own lane", true wherever the spine is continuous; where the layout
--- deliberately broke the spine it would name the *arriving branch*, so a merge on the
--- trunk would render in the colour of the topic it merged. Flipping it keeps the
--- trunk's colour on the node and lets the topic lane simply begin below it. Every
--- other cell — every other policy — leaves the flag nil and is untouched.
---@param segs Segment[]|nil
---@param emphasis boolean|nil
---@param is_node boolean|nil
---@param own_lane_up boolean|nil
---@return Segment|nil
local function top_lane(segs, emphasis, is_node, own_lane_up)
    if not segs then return nil end
    local first, second = "down", "up"
    if own_lane_up then first, second = "up", "down" end
    if emphasis then
        for _, s in ipairs(segs) do
            if seg_hl(s) and s.connectivity[first] then return s end
        end
        for _, s in ipairs(segs) do
            if seg_hl(s) and s.connectivity[second] then return s end
        end
        for _, s in ipairs(segs) do
            local l, r = s.connectivity.left, s.connectivity.right
            if seg_hl(s) and (l or r) and not (l and r) then return s end
        end
        local has_through = false
        for _, s in ipairs(segs) do
            if s.connectivity.up and s.connectivity.down then has_through = true break end
        end
        if not has_through then
            for _, s in ipairs(segs) do
                if seg_hl(s) and s.connectivity.left and s.connectivity.right then return s end
            end
        end
    end
    for _, s in ipairs(segs) do
        if s.connectivity[first] then return s end
    end
    -- On a NODE-LESS cell, a horizontal arm/bus outranks a pure-UP stub so a fork bus
    -- keeps ONE colour: the branch's own colour begins in the row ABOVE (at the junction),
    -- not mid-bus. Without this the bus alternates between the bus colour and each
    -- up-branch's colour at the column it leaves from. A through-vertical (up+down) already
    -- won above via `down`, so a genuine crossing still keeps the passing lane's colour. A
    -- NODE cell is exempt: its glyph must read in the node's own lane, not a crossing arm.
    if not is_node then
        for _, s in ipairs(segs) do
            if s.connectivity.left or s.connectivity.right then return s end
        end
    end
    for _, s in ipairs(segs) do
        if s.connectivity[second] then return s end
    end
    return segs[1]
end
M.top_lane = top_lane

--- Resolve a palette slot (1-based, from Phase 1's free list) to its highlight
--- group: a curated slot indexes `palette.tracks`; a slot beyond the curated set
--- is a generated OKLCH colour (§5.5). A negative slot `-k` is slot `k`'s
--- counterpart variant (a remote counterpart's lane, §5.5): `counterpart_hl`.
---@param opts GraphOptions
---@param slot integer|nil
---@return string?
function M.slot_hl(opts, slot)
    if not slot then return nil end
    if slot < 0 then return M.counterpart_hl(opts, M.slot_hl(opts, -slot)) end
    local n = #opts.palette.tracks
    if slot <= n then return opts.palette.tracks[slot] end
    return generated_hl(opts, slot - n)
end

--- The lane colour a row's node is drawn in (§6 "Label colour"): the highlight
--- group `get_column_chars` gives the node glyph — the node cell's `top_lane`
--- (honouring `own_lane_up`, §5.6) through `seg_color` — WITHOUT the HEAD-node
--- override (§5.3), since a label's HEAD marker is coloured on its own. Undimmed;
--- the caller dims it with the row. `commit` picks the node on a packed marker row
--- (§10.4); nil = the row's (first) node cell. nil when the row has no node cell.
---@param opts GraphOptions
---@param columns GraphColumn[]?
---@param emphasis boolean|nil
---@param commit table?
---@return string?
function M.node_lane_hl(opts, columns, emphasis, commit)
    return M.slot_hl(opts, M.node_lane_slot(columns, emphasis, commit))
end

--- The palette slot behind `node_lane_hl` (negative `-k` for a counterpart lane,
--- §5.5) — what `label_owner` matches against the refs. nil without a node cell.
---@param columns GraphColumn[]?
---@param emphasis boolean|nil
---@param commit table?
---@return integer?
function M.node_lane_slot(columns, emphasis, commit)
    for _, track in ipairs(columns or {}) do
        if track.has_commit and (commit == nil or track.commit == commit) then
            local seg = top_lane(track.lanes, emphasis, true, track.own_lane_up)
            return seg_color(seg, emphasis)
        end
    end
    return nil
end

--- A ref's **label key** (§6 "Label colour"): which drawn label it belongs to —
--- `b:<short>` for a branch group (a local and its `↑remote,…` list are ONE label,
--- keyed by the short name exactly as `git.group_refs` groups them), `t:<name>` a
--- tag, `w:<name>` a worktree label, `HEAD` a detached HEAD's bare marker (an
--- attached head ref belongs to its branch's group).
---@param ref Ref
---@return string?
local function ref_label_key(ref)
    if ref.kind == "head" then return ref.branch and ("b:" .. ref.branch) or "HEAD" end
    if ref.kind == "local" then return "b:" .. ref.name end
    if ref.kind == "remote" then
        local short = ref.name:match("^[^/]+/(.+)$")
        return "b:" .. (short or ref.name)
    end
    if ref.kind == "tag" then return "t:" .. ref.name end
    if ref.kind == "worktree" then return "w:" .. ref.name end
    return nil
end

--- The label that **owns** a node's lane (§6 "Label colour"), as a label key
--- (`ref_label_key`): the only label on the node drawn in the lane colour.
---
---  1. The ref the lane was BORN FOR: a ref on this node whose own colour the lane
---     carries — rank `k`'s pinned colour, slot `k` (`opts.pin_rank`, only while
---     `k` is a curated slot, §5.5), or counterpart rank `k`'s colour `-k`
---     (`opts.pin_counterpart`). A pinned slot is withheld until its ref's tip and
---     only a counterpart lane carries `-k`, so matching the colour is exactly "born
---     here for it" — and needs no layout data, so the panes (which carry the main
---     view's colours) agree.
---  2. Otherwise the first label in logical order: the current branch's group, the
---     other branch groups, tags, worktrees. A detached HEAD's bare marker is never
---     an owner (it is always `palette.head`) — not even when the lane was born for
---     a pinned detached `HEAD` in step 1: that lane falls through to here, so a
---     branch on a detached HEAD reads in its lane's colour.
---
--- nil when the node has no label at all. A remote's `origin/HEAD` symref is no ref
--- (`git.classify_ref` drops it), so it can never own.
---@param opts GraphOptions
---@param commit { refs: Ref[]? }?
---@param slot integer?            the node's lane slot (`node_lane_slot`)
---@param head_branch string?      the current branch when the head ref does not name it
---@return string?
function M.label_owner(opts, commit, slot, head_branch)
    local refs = commit and commit.refs or {}
    if slot then
        local ntracks = #((opts.palette or {}).tracks or {})
        local rank, cp = opts.pin_rank, opts.pin_counterpart
        for _, ref in ipairs(refs) do
            local id = ref.kind == "head" and "HEAD" or ref.name
            if (slot > 0 and slot <= ntracks and rank and rank[id] == slot)
                or (slot < 0 and cp and cp[id] == -slot) then
                -- a detached HEAD's bare marker is always `palette.head`, so a lane
                -- born for it passes to the first other label (step 2)
                local key = ref_label_key(ref)
                if key ~= "HEAD" then return key end
            end
        end
    end
    local g = git.group_refs(refs, head_branch)
    if g.branches[1] then return "b:" .. g.branches[1].name end
    if g.tags[1] then return "t:" .. g.tags[1] end
    if g.worktrees[1] then return "w:" .. g.worktrees[1] end
    return nil
end

--- The label keys of `decoration_texts`, in the same order (§6 "Label colour").
---@param commit { refs: Ref[]? }?
---@param head_branch string?
---@return string[]
function M.decoration_keys(commit, head_branch)
    local g = git.group_refs(commit and commit.refs or {}, head_branch)
    local out = {}
    for _, b in ipairs(g.branches) do out[#out + 1] = "b:" .. b.name end
    for _, t in ipairs(g.tags) do out[#out + 1] = "t:" .. t end
    for _, w in ipairs(g.worktrees) do out[#out + 1] = "w:" .. w end
    return out
end

--- A node's lane colour and the label that owns it (§6 "Label colour"): the
--- `node_lane_hl` group plus `label_owner`'s key. Callers pass the lane colour to
--- `label_hl` for the owning label only.
---@param opts GraphOptions
---@param columns GraphColumn[]?
---@param emphasis boolean|nil
---@param commit table?        the node's commit (also picks the node on a packed row)
---@param head_branch string?
---@param pick boolean?        match the node cell by `commit` (a packed marker row)
---@return string? lane, string? owner
function M.node_label_colour(opts, columns, emphasis, commit, head_branch, pick)
    local slot = M.node_lane_slot(columns, emphasis, pick and commit or nil)
    return M.slot_hl(opts, slot), M.label_owner(opts, commit, slot, head_branch)
end

--- The highlight a ref label is drawn in (§6 "Label colour"): its node's lane
--- colour `lane` — which the caller passes for the label owning the lane only
--- (`label_owner`), nil for every other label — unless `lane_label_colors` is off
--- or the row has no node colour, then the label's per-kind palette group
--- `kind_group`.
---@param opts GraphOptions
---@param lane string?
---@param kind_group string?
---@return string?
function M.label_hl(opts, lane, kind_group)
    if opts.lane_label_colors ~= false and lane then return lane end
    return kind_group
end

--- Whether `commit` is the one HEAD points at (§5.3): it carries the `head` ref
--- (attached or detached, §3.2). Data the renderer is already handed, so a resync
--- or checkout moves the marker with no extra state.
---@param commit { refs: Ref[]? }?
---@return boolean
function M.has_head_ref(commit)
    for _, r in ipairs((commit and commit.refs) or {}) do
        if r.kind == "head" then return true end
    end
    return false
end

--- Mirror a row's cells for right-aligned rendering (specification.md §5.4).
--- Reverses the column order (so lane 1 becomes the rightmost column, nearest
--- the message) and swaps each cell's left/right connectivity. Because the
--- glyph is a pure function of connectivity (get_column_chars), the mirrored
--- glyphs (╭↔╮, ┤↔├, ╴↔╶) and the inter-lane connectors fall out automatically
--- — no glyph-swap table. Color is unaffected (it comes from each lane's
--- up/down). Returns a fresh array; the model rows are left untouched.
---@param columns GraphColumn[]
---@return GraphColumn[]
local function mirror_columns(columns)
    local out = {}
    for i = #columns, 1, -1 do
        local t = columns[i]
        local c = t.connectivity
        local m = {}
        for k, v in pairs(t) do m[k] = v end
        m.connectivity = { up = c.up, down = c.down, left = c.right, right = c.left }
        out[#out + 1] = m
    end
    return out
end

--- A vertical-only projection of a commit line's columns (spec §6.1). Every lane
--- continuing in direction `dir` — `"up"` (entering from above) or `"down"`
--- (leaving below; the dual-mode message row) — becomes a straight `│` in its own
--- colour; every other column is blank. No node and no horizontal wires, so
--- labels / the message sit cleanly to the right of the continuing graph. Each
--- synthesized Segment keeps the original's `edges` and `color` so the
--- reachability dimming (§12) and colour still apply. Fed through
--- `get_column_chars` like any row (mirroring included).
---@param columns GraphColumn[]
---@param dir? "up"|"down"   which lanes to continue (default "up")
---@return GraphColumn[]
local function passthrough_columns(columns, dir)
    dir = dir or "up"
    local out = {}
    for _, t in ipairs(columns or {}) do
        if t.connectivity and t.connectivity[dir] then
            local lanes = {}
            for _, s in ipairs(t.lanes or {}) do
                if s.connectivity and s.connectivity[dir] then
                    lanes[#lanes + 1] = {
                        connectivity = { up = true, down = true },
                        edges = s.edges,
                        color = s.color,
                    }
                end
            end
            out[#out + 1] = {
                connectivity = { up = true, down = true },
                color = t.color,
                lanes = lanes,
                has_commit = false,
            }
        else
            out[#out + 1] = { connectivity = {}, lanes = {}, has_commit = false }
        end
    end
    return out
end
M.passthrough_columns = passthrough_columns

function M.get_column_chars(opts, columns, emphasis)
    -- Right-aligned mirror: flip the cells before deriving glyphs. The graph
    -- column is then right-aligned by the listview (fix_width align = "right").
    if opts.mirror then
        columns = mirror_columns(columns)
    end

    local result = {}

    for i = 1, #columns do
        local track = columns[i]
        local next = columns[i + 1]

        -- A *crossing* is a clean through-horizontal wire passing across a
        -- vertically-continuous cell (a `│` the wire crosses). It is left whole
        -- so a passing cone wire never truncates it; only real junctions — whose
        -- arms all *turn* (no straight left↔right lane) — drop their dim arms and
        -- draw `┼`. The vertical may be one through-lane or, at a merge handoff
        -- (allow_merge_on_split), separate up/down turns sharing the column: the
        -- horizontal still passes over, so the cell stays a crossing, not a `┼`.
        local cross_h = false
        for _, s in ipairs(track.lanes or {}) do
            if s.connectivity.left and s.connectivity.right then cross_h = true end
        end
        local is_crossing = cross_h and track.connectivity.up and track.connectivity.down
        -- A kept junction (§10.4) is drawn node-less — its cell renders the fork/
        -- merge as box-drawing lanes, not a commit node — so the split topology
        -- shows without the commit's weight. Disabled by opts.junction_markers.
        -- EXCEPTION: a junction that carries **refs** shows the ◍ collapsed marker
        -- (the glyph below) rather than a bare box — a ref label must be anchored
        -- to a node, else it floats with no indication of which junction it tags
        -- (§10.4). Only a ref-less junction renders truly node-less.
        local junction_nodeless = opts.junction_markers ~= false and track.commit
            and track.commit.junction and #(track.commit.refs or {}) == 0
        local is_node = track.has_commit and not junction_nodeless

        -- The glyph's connectivity: the full cell by default, but under emphasis a
        -- real junction keeps only the arms its *highlighted* Segments draw (each
        -- Segment is one edge; build_fan), so off-cone arms gap out. A uniformly
        -- dim cell and a crossing keep their full glyph.
        ---@type Connectivity
        local c = {
            left = track.connectivity.left,
            right = track.connectivity.right,
            up = track.connectivity.up,
            down = track.connectivity.down,
        }
        if emphasis and not is_node and not is_crossing then
            local hc, any = { up = false, down = false, left = false, right = false }, false
            for _, s in ipairs(track.lanes or {}) do
                if seg_hl(s) then
                    any = true
                    local sc = s.connectivity
                    if sc.up then hc.up = true end
                    if sc.down then hc.down = true end
                    if sc.left then hc.left = true end
                    if sc.right then hc.right = true end
                end
            end
            if any then
                if opts.mirror then hc.left, hc.right = hc.right, hc.left end
                c = hc
            end
        end

        local char = " "
        -- HEAD's node (§5.3): the commit carrying the `head` ref (attached or
        -- detached — a collapsed head aggregates its region's refs, so one folding
        -- HEAD in carries it too) draws `icons.head` in the HEAD colour. A
        -- working-tree node keeps ◌ but takes the HEAD colour too (only the glyph:
        -- its lane keeps HEAD's branch colour); a ◍ marker keeps its glyph but
        -- takes the colour. `icons.head = ""` turns both off.
        local head_icon = opts.icons and opts.icons.head
        if head_icon == nil then head_icon = "●" end
        local is_head = is_node and head_icon ~= "" and not track.commit.virtual
            and M.has_head_ref(track.commit)
        local is_wt = is_node and head_icon ~= "" and track.commit.virtual ~= nil
        -- Colour (and dim state) from the Column's "top" Segment (§5): the
        -- Segment whose edge colours the glyph (a highlighted edge wins, but
        -- only with emphasis — so the picture is unchanged when it is off).
        local color_seg = top_lane(track.lanes, emphasis, is_node, track.own_lane_up)
        local track_color = seg_color(color_seg, emphasis)
        if track.override ~= nil then
            char = track.override
        elseif is_node then
            -- "⏺". A collapsed head (spec §10.3) gets its own glyph so a
            -- contracted region reads differently from a real commit. A labelled
            -- kept junction (§10.4) reuses ◍ too: it is a collapsed-mode commit, so
            -- the marker anchors its ref and signals the fold (message stays blank).
            char = track.commit.virtual and "◌" or
                (track.commit.collapsed or (track.commit.junction and opts.junction_markers ~= false)) and "◍" or
                is_head and head_icon or
                (#track.commit.parents == 0) and "◎" or
                not opts.merge_style.merge_on_separate_line and (#track.commit.parents > 1) and opts.icons.merge or
                (#track.commit.children == 0) and "◉" or "○"
            --"o"
        elseif c.left and c.right and not c.up and not c.down then
            char = "─"
            -- ═
        elseif c.left and c.up and not c.right and c.down then
            char = "┤"
            -- ╡
        elseif not c.left and c.up and c.right and c.down then
            char = "├"
        elseif c.left and c.up and c.right and not c.down then
            char = "┴"
            -- ╧
        elseif c.left and not c.up and c.right and c.down then
            char = "┬"
            -- ╤─┬
        elseif c.left and c.up and not c.right and not c.down then
            --char = "┘"
            char = "╯"
        elseif not c.left and not c.up and c.right and c.down then
            --char = "┌"
            char = "╭"
        elseif not c.left and c.up and not c.right and not c.down then
            char = "^"
        elseif c.left and not c.up and not c.right and c.down then
            --char = "┐"
            char = "╮"
        elseif not c.left and c.up and c.right and not c.down then
            char = "╰"
        elseif c.left and not c.up and not c.right and not c.down then
            char = "╴"
        elseif not c.left and not c.up and c.right and not c.down then
            char = "╶"
        elseif not c.left and c.up and not c.right and not c.down then
            char = "╵"
        elseif not c.left and not c.up and not c.right and c.down then
            char = "╷"
        elseif c.up and c.down and c.left and c.right and not is_crossing then
            char = "┼" -- a node-less junction fanning both sides (§10.4)
        elseif c.up and c.down then
            -- A real crossing (an independent through-horizontal over this
            -- vertical) stays "│"; the horizontal passes across it (it is not a
            -- junction). Only genuine 4-way junctions reach "┼" above.
            char = "│"
        elseif not c.left and not c.up and not c.right and not c.down then
            char = " " -- empty column (allowed; e.g. a gap awaiting compaction)
        else
            char = "x"
            vim.notify(vim.inspect(c))
        end

        ---@param slot integer|nil
        ---@return string?
        local get_highlight = function(slot) return M.slot_hl(opts, slot) end

        -- Reachability dimming (§12): a cell outside the cone renders its colour
        -- blended toward the background. The commit marker follows its commit
        -- (track.active, set by mark_reachable); other glyphs follow whether
        -- their colour Segment draws a highlighted edge. `emphasis` is false when
        -- the feature is off / no pivot, so everything renders lit.
        local cell_active
        if not emphasis then
            cell_active = true
        elseif track.has_commit then
            cell_active = track.active ~= false
        else
            cell_active = not color_seg or seg_hl(color_seg)
        end
        local cell_hl = get_highlight(track_color)
        if (is_head or is_wt) and track.override == nil and opts.palette.head then cell_hl = opts.palette.head end
        if not cell_active then cell_hl = M.dim_hl(opts, cell_hl) end
        result = compose({ result, highlight_text(char, cell_hl) })

        -- Connector colour: the lane its horizontal run terminates at, found by
        -- scanning past pass-through crossings/jumps — to the right normally, to
        -- the left once mirrored (cells reversed), so the scan flips direction
        -- (§5.4). Keeping this lookahead preserves colour continuity along a run.
        local function real_color(j)
            local t = columns[j]
            if not t then return nil end
            local cc = t.connectivity
            local is_cross = cc.down and cc.up and cc.left and cc.right
            local is_jump = not cc.down and not cc.up and cc.right and cc.left
            if is_cross or is_jump then return false end
            -- The connector follows the HORIZONTAL wire's own lane, not the cell's primary
            -- (vertical) lane: at a fork-bus terminus the primary is the up-branch (dev),
            -- but the bus arm arriving here is the fork source — so use the lane of the
            -- segment that actually carries the horizontal, keeping the bus one colour.
            for _, s in ipairs(t.lanes or {}) do
                if s.connectivity.left or s.connectivity.right then return s.color end
            end
            return t.color
        end
        local next_color
        local from, to, step = i + 1, #columns, 1
        if opts.mirror then from, to, step = i, 1, -1 end
        for j = from, to, step do
            local color = real_color(j)
            if color ~= false then next_color = color; break end
        end

        -- Connector dim/colour: it lights iff a *highlighted* Segment leaves this
        -- cell toward the next (visual right — which is the unmirrored "left" once
        -- mirrored reverses the cells). Its colour is that cone edge's, else the
        -- run's terminating lane (continuity).
        local conn_dir = opts.mirror and "left" or "right"
        local conn_lit, conn_color = false, next_color
        if emphasis then
            for _, s in ipairs(track.lanes or {}) do
                if s.connectivity[conn_dir] and seg_hl(s) then
                    conn_lit = true
                    for _, e in ipairs(s.edges or {}) do
                        if e.highlighted and e.color then conn_color = e.color; break end
                    end
                    break
                end
            end
        end

        if next ~= nil and (track.connectivity.right and next.connectivity.left) then
            local hl = get_highlight(conn_color)
            if emphasis and not conn_lit then hl = M.dim_hl(opts, hl) end
            result = compose({ result, highlight_text("─", hl) })
        elseif next ~= nil and (track.connectivity.right and not next.connectivity.left) then
            result = compose({ result, "╴" })
        elseif next ~= nil and (not track.connectivity.right and next.connectivity.left) then
            result = compose({ result, "╶" })
        else
            result = compose({ result, " " })
        end
    end

    -- Mirrored graphs right-align the column so lane 1 hugs the message edge and
    -- vertical wires stay column-aligned across rows (see fix_width).
    if opts.mirror then
        result.align = "right"
    end

    return result
end

--- A short one-line label for a snippet row (spec §15.3): the commit subject,
--- a collapsed head's region count, or a packed marker-group's marker count.
---@param item OrderItem
---@return string
local function snippet_label(item)
    if item.type == "markers" then
        local n = #M.marker_units(item)
        return n .. (n == 1 and " marker" or " markers")
    end
    local c = item.commit
    if not c then return "" end
    if c.collapsed then
        local n = c.count or (c.region and #c.region) or 0
        return n .. (n == 1 and " commit" or " commits")
    end
    return c.message or ""
end

--- Render a compact graph snippet (spec §15.3): the laid-out `items` in the
--- window `[focus - radius, focus + radius]` as graph glyphs + a short subject,
--- the focus row marked with a left gutter. Pure over the already-laid-out items
--- (each must carry `.columns` from columns.layout) — reused by the
--- commit-search preview to locate a commit in the graph. The graph column is
--- padded to a common width so the lanes align across rows (left-padded under
--- `opts.mirror`, which right-aligns lane 1 against the message, else
--- right-padded). Returns the compose rows and the 1-based index of the focus
--- row within them, so the caller can centre / highlight it.
---@param opts GraphOptions
---@param items OrderItem[]
---@param focus integer  -- index in `items` to centre on
---@param radius integer  -- rows kept above and below the focus
---@return table[] rows  -- compose { text, highlight }
---@return integer focus_row  -- 1-based row index of the focus within `rows`
function M.graph_snippet(opts, items, focus, radius)
    local lo = math.max(1, focus - radius)
    local hi = math.min(#items, focus + radius)

    -- Phase 2 each row's graph cells, and track the widest so they can be padded
    -- to a shared column (emphasis off — the snippet is a neutral locator).
    local graphs, maxw = {}, 0
    for i = lo, hi do
        local g = M.get_column_chars(opts, items[i].columns, false)
        graphs[i] = g
        maxw = math.max(maxw, vim.fn.strdisplaywidth(g.text))
    end

    local rows = {}
    local focus_row = 1
    for i = lo, hi do
        local g = graphs[i]
        local pad = string.rep(" ", maxw - vim.fn.strdisplaywidth(g.text))
        -- Mirror right-aligns the graph (lane 1 hugs the message edge), so pad on
        -- the left; the conventional layout pads on the right.
        local graph_cell = opts.mirror and compose({ pad, g }) or compose({ g, pad })
        local is_focus = (i == focus)
        local gutter = highlight_text(is_focus and "▸ " or "  ",
            is_focus and (opts.palette and opts.palette.selected) or "Comment")
        local subject = highlight_text(snippet_label(items[i]),
            is_focus and (opts.palette and opts.palette.selected) or nil)
        rows[#rows + 1] = compose({ gutter, graph_cell, " ", subject })
        if is_focus then focus_row = #rows end
    end

    return rows, focus_row
end

-- ── Row rendering (the listview DisplayElement) ─────────────────────────────

--- Display cells the `dual` message row's text is indented by (spec §6.1), so a
--- labelled commit's message reads as belonging to the label row above. Leading
--- spaces INSIDE the flex column: the flex column is excluded from the shared
--- column widths, so no other row moves. `place_cursor` adds it to the flex offset
--- to park on the message itself.
M.DUAL_INDENT = 2

--- Whether a commit renders as **two real buffer rows** in the current label
--- mode (spec §6.1): dual mode and the commit actually has selectable
--- decorations. The single source of truth shared by the listview's
--- `line_count` (buffer allocation) and `display_item` (the rendered rows), so
--- they never disagree.
---@param opts GraphOptions
---@param commit Commit|nil
---@return boolean
function M.dual_two_line(opts, commit)
    local is_marker = commit ~= nil
        and (commit.collapsed or (commit.junction and opts.junction_markers ~= false))
    return opts.label_mode == "dual" and commit ~= nil and not is_marker
        and #M.decoration_texts(commit) > 0
end

--- The 1-based byte range `[s, e]` of the first **smartcase substring** match of
--- `needle` in `haystack` (spec §16.2/§16.7), or nil — case-insensitive unless the
--- needle has an uppercase letter. Literal (the needle is not a Lua pattern).
---@param haystack string
---@param needle string
---@return integer? s, integer? e
local function match_span(haystack, needle)
    if not needle or needle == "" then return nil end
    local hs, nd = haystack, needle
    if not needle:match("%u") then hs, nd = haystack:lower(), needle:lower() end
    return hs:find(nd, 1, true)
end

---@param opts GraphOptions
---@param item OrderItem
---@param selection_state SelectionState
---@param cone table<Commit, boolean>|nil  the pivot's reachability cone (§12), or nil
---@param sel_cursor? table  the commit-selection moving end (§13.4), so a packed
---  marker row can mark the selected head; nil when not selecting
---@param head_branch? string  the current branch (= repo.head) — a fallback for a ref
---  list whose head ref does not name its `branch`; that branch's label is drawn first as
---  `(HEAD → name)` in the HEAD colour (§6), a detached HEAD as a bare first `HEAD`
---@param match? { query: string, current?: string }  the active filter-search (§16.7):
---  highlight the matched substring in a commit's message (`palette.search`), brighter
---  (`IncSearch`) on the current match (`current` = its hash); nil when not filtering
---@param pins? PinMarks  the effective pin set + icon: a pinned ref's label is drawn
---  with the pin icon (§6/§10.6); nil = no pin icons
---@return DisplayElement
function M.display_item(opts, item, selection_state, cone, sel_cursor, head_branch, match, pins)
    local palette = opts.palette

    -- The 1-based decoration index selected on this row, or nil. Selection is
    -- by commit identity, so it follows the commit across reflow.
    local selected = nil
    if selection_state and item.commit and selection_state.commit == item.commit then
        selected = selection_state.index
    end

    -- Reachability dimming (§12): when a cone is active and this commit is
    -- outside it, the row's non-lane fields render dimmed (the lanes dim
    -- per-cell via track.active in get_column_chars). `cone == nil` means no
    -- pivot yet, so nothing dims. `rh` is "row highlight": the field's group,
    -- or its dimmed derivative on an out-of-cone row.
    -- Emphasis is active only with a pivot (cone) and the toggle on; otherwise
    -- everything renders lit. Lane dimming reads `emphasis`; row fields read
    -- `row_active` (this commit in the cone).
    local emphasis = (opts.highlight ~= false) and (cone ~= nil)
    local row_active = (not emphasis) or (item.commit ~= nil and cone ~= nil and cone[item.commit] == true)
    -- On an out-of-cone row, dim the field's group; a field with no group (e.g.
    -- the message, palette.message = nil) dims its default `Normal` foreground so
    -- it recedes with the rest of the row rather than staying full-bright.
    local function rh(text, group)
        if row_active then return highlight_text(text, group) end
        return highlight_text(text, M.dim_hl(opts, group or "Normal"))
    end

    -- Refs (§6) as a list of right-pinned items: branch groups, then tags. Branch
    -- refs sharing a short name collapse to "(name ↑remote1,remote2)" — the name
    -- once (highlighted if a local exists, dimmed if remote-only) plus the remotes
    -- that also point here (group_refs). HEAD's label comes FIRST (§6) so the `+N`
    -- overflow never hides it: the **current branch** is drawn `(HEAD → name …)` in
    -- the HEAD colour (palette.head) instead of the branch colour ("you are here");
    -- a detached HEAD (head marker present, no current branch) a bare `HEAD`.
    -- A tracked local branch appends its upstream divergence "⇡N⇣M"/"gone" (§6.3),
    -- each token coloured by palette.track.
    -- The `selected`-th decoration (branches then tags) is drawn with
    -- palette.selected (§2). The listview packs these against the right edge
    -- with a width budget and a "+N" overflow marker.
    -- Only the label OWNING the node's lane (`owner`, a `label_owner` key) takes
    -- the lane colour `lane`; every other label its per-kind group (§6 "Label colour").
    local get_ref_items = function(commit, lane, owner)
        local function lane_for(key) return key == owner and lane or nil end
        local g = git.group_refs(commit.refs, head_branch)
        local texts = M.decoration_texts(commit, head_branch, pins) -- same order + text; shared with the cursor target
        local items = {}
        -- Per-ref colour override (§11.7.6): a tag carrying `hl` — the submodule
        -- new/old **pointer marks**, injected as refs so they pin / show in the
        -- panes / picker — renders in that colour instead of the tag default.
        local hl_by_name = {}
        for _, r in ipairs(commit.refs or {}) do
            if r.hl and r.name then hl_by_name[r.name] = r.hl end
        end
        if g.head and not g.current then
            items[#items + 1] = rh("HEAD", palette.head)
        end
        local di = 0
        for _, b in ipairs(g.branches) do
            di = di + 1
            if di == selected then
                items[#items + 1] = highlight_text(texts[di], palette.selected)
            else
                -- The owning label takes its node's lane colour (§6 "Label colour");
                -- the current branch's `HEAD → ` prefix keeps the HEAD colour.
                local blane = lane_for("b:" .. b.name)
                local name_hl = M.label_hl(opts, blane,
                    b.current and palette.head or (b.has_local and palette.branch or palette.remote))
                local segs = { rh("(", name_hl) }
                if b.current then segs[#segs + 1] = rh(git.HEAD_ARROW, palette.head) end
                segs[#segs + 1] = rh(M.group_pin(pins, b) .. b.name, name_hl)
                if #b.remotes > 0 then
                    segs[#segs + 1] = rh(" ↑" .. table.concat(b.remotes, ","), M.label_hl(opts, blane, palette.remote))
                end
                -- Upstream divergence (§6.3): each ⇡/⇣/gone token coloured by kind
                -- via palette.track; the concatenated text equals git.track_label
                -- (used by decoration_texts), so the selection target stays aligned.
                local track = palette.track or {}
                for _, seg in ipairs(git.track_segments(b.track)) do
                    segs[#segs + 1] = rh(seg.text, track[seg.kind])
                end
                segs[#segs + 1] = rh(")", name_hl)
                items[#items + 1] = compose(segs)
            end
        end
        for _, t in ipairs(g.tags) do
            di = di + 1
            if di == selected then
                items[#items + 1] = highlight_text(texts[di], palette.selected)
            else
                items[#items + 1] = rh("[" .. M.name_pin(pins, t) .. t .. "]",
                    hl_by_name[t] or M.label_hl(opts, lane_for("t:" .. t), palette.tags))
            end
        end
        -- Linked-worktree labels (§3.2) come last: they are the least branch-like
        -- entry, and putting them after the tags keeps the branch a row is really
        -- "on" nearest the graph when the width budget starts hiding labels (§6).
        for _, w in ipairs(g.worktrees) do
            di = di + 1
            if di == selected then
                items[#items + 1] = highlight_text(texts[di], palette.selected)
            else
                items[#items + 1] = rh("{" .. M.name_pin(pins, w) .. w .. "}",
                    M.label_hl(opts, lane_for("w:" .. w), palette.worktree or palette.tags))
            end
        end
        return items
    end

    local get_columns = function(columns)
        if not opts.show_lane_ids then
            return highlight_text("")
        end
        local result = "("
        for i, t in ipairs(columns) do
            result = result .. (i > 1 and ", " or "") .. (t.id or "-")
        end
        result = result .. ") "

        return highlight_text(result, "Comment")
    end

    -- The row's stacked virtual lines (§5 Line): `above` (the split fan-in, plus any
    -- `gutter` handover rows — topmost first) and `below` (the merge fan-out), as
    -- DisplayElement rows. EVERY single-row branch below must return these: the
    -- layout routes lanes through them (a `gutter` eviction/claim jogs the crossing
    -- lanes there), so dropping them cuts every lane on the row and re-births it
    -- below — and the §6.2 screen-row model counts them regardless.
    -- `ids` adds the lane-id debug prefix in the message cell (commit rows only).
    local function fan_lines(ids)
        local above = {}
        for _, line in ipairs(item.above or {}) do
            above[#above + 1] = { "", "", M.get_column_chars(opts, line, emphasis), ids and get_columns(line) or "" }
        end
        local below
        if item.merge then
            below = { { "", "", M.get_column_chars(opts, item.merge, emphasis), ids and get_columns(item.merge) or "" } }
        end
        return #above > 0 and above or nil, below
    end


    -- A packed marker-group (spec §10.4): several concurrent collapsed heads on
    -- one line — their ◍ nodes in the graph column, then each marker's ref
    -- label(s). The `h`/`l`-selected head drives the §12 cone (update_cone /
    -- mark_node_cone), so the selected branch stays lit while the siblings dim; the
    -- node glyphs follow the same cone via get_column_chars. No message. The labels
    -- go in `line_right` (left-aligned after the graph, `line_right_align`) so they
    -- get the same windowed overflow as commit refs (§6): the selected marker is
    -- kept visible with `+N` markers, instead of the row truncating with `…`.
    if item.type == "markers" then
        local graph_item = M.get_column_chars(opts, item.columns, emphasis)
        local sel = (selection_state and selection_state.commit == item) and selection_state.index or nil
        local labels = {}
        for _, u in ipairs(M.marker_units(item, pins)) do
            -- The commit-selection cursor head (§13.4) draws with palette.selected.
            -- Otherwise the h/l marker selection drives the §12 reachability cone
            -- (update_cone seeds it from the selected head), so the selected
            -- branch renders in its normal colour and the others — out of its cone
            -- — dim, exactly like selecting a normal head. (`sel` still windows the
            -- selected label into view via line_right_sel.)
            -- Each marker is its own node: the label owning THAT marker's lane takes
            -- its node colour, the others `palette.branch` (§6 "Label colour"). A
            -- count-only unit has no label to own, so it shows the lane colour.
            local lane, owner = M.node_label_colour(opts, item.columns, emphasis, u.marker, nil, true)
            local dim = emphasis and not (cone and cone[u.marker])
            local function hl_of(key)
                local g = M.label_hl(opts, (key == nil or key == owner) and lane or nil, palette.branch)
                return dim and M.dim_hl(opts, g) or g
            end
            if u.marker == sel_cursor then
                labels[#labels + 1] = highlight_text(u.text, palette.selected)
            elseif #u.decos == 0 then
                labels[#labels + 1] = highlight_text(u.text, hl_of(nil))
            else
                local segs = {}
                for i, d in ipairs(u.decos) do
                    if i > 1 then segs[#segs + 1] = " " end
                    segs[#segs + 1] = highlight_text(d, hl_of(u.keys[i]))
                end
                labels[#labels + 1] = compose(segs)
            end
        end
        return {
            line = { "", "", graph_item, "" },
            line_right = labels,
            line_right_sel = sel,
            line_right_align = "left",
        }
    end

    -- A collapsed head is a **marker** (spec §10.4): a messageless node standing
    -- for a contracted region — the ◍ node, the region's ref label(s), and a
    -- compact commit count, but no subject. Labels render inline in the flex
    -- column regardless of label_mode. Always one row (dual_two_line excludes it).
    local head = item.commit
    if head and head.collapsed then
        local graph_item = M.get_column_chars(opts, item.columns, emphasis)
        -- No date/author columns: a collapsed head stands for a whole region of
        -- commits, so the tip's lone date/author would misrepresent it. It exists
        -- only to show the region's existence and how it connects to the trunk —
        -- uncollapse for detail.
        local parts = {}
        for _, it in ipairs(get_ref_items(head, M.node_label_colour(opts, item.columns, emphasis, head, head_branch))) do
            parts[#parts + 1] = it
            parts[#parts + 1] = " "
        end
        parts[#parts + 1] = rh(("(%d)"):format(head.count or 0), "Comment")
        local above, below = fan_lines()
        return { above = above, below = below, line = { "", "", graph_item, compose(parts) } }
    end

    -- A kept junction drawn as a marker (spec §10.4): the split/merge topology
    -- only — node-less graph (get_column_chars), any refs, but no date/author/
    -- message. Keeps the split/merge fan virtual lines. opts.junction_markers off
    -- falls through to the full commit render below.
    if item.commit and item.commit.junction and opts.junction_markers ~= false then
        local graph_item = M.get_column_chars(opts, item.columns, emphasis)
        local above, below = fan_lines()
        local parts = {}
        for _, it in ipairs(get_ref_items(item.commit,
            M.node_label_colour(opts, item.columns, emphasis, item.commit, head_branch))) do
            parts[#parts + 1] = it
            parts[#parts + 1] = " "
        end
        return {
            above = above,
            below = below,
            line = { "", "", graph_item, compose(parts) },
        }
    end

    -- A working-tree virtual commit (§4.2): the ◌ node (get_column_chars) + a
    -- synthesized subject, with blank date/author columns (it carries no commit
    -- metadata). No refs and no fan of its own — it is a lone tip above HEAD — but
    -- it sits mid-graph whenever HEAD has descendants, so lanes cross its row and
    -- the layout may still give it virtual lines (a `gutter` handover, §5.6).
    -- Those carry the crossing lanes and must be drawn (fan_lines).
    if item.commit and item.commit.virtual then
        local graph_item = M.get_column_chars(opts, item.columns, emphasis)
        local above, below = fan_lines()
        return {
            above = above,
            below = below,
            line = {
                rh("", palette.date),
                rh("", palette.author),
                graph_item,
                -- The clean row reads as state, not a commit: the dimmer date colour.
                rh(git.worktree_label(item.commit),
                    item.commit.virtual == "clean" and palette.date or palette.message),
            },
        }
    end

    if item.type == "commit" then
        local label_mode = opts.label_mode or "right"
        local ids = get_columns(item.columns) -- optional lane-id debug prefix
        -- Message, with the filter-search match highlighted (§16.7): the matched
        -- substring in palette.search, brighter (IncSearch) on the current match.
        local msg_text = item.commit.message or ""
        local message
        local ms, me
        if match then ms, me = match_span(msg_text, match.query) end
        if match and ms and me then
            local hl = (match.current == item.commit.hash) and "IncSearch"
                or (palette.search or "Search")
            message = compose({
                rh(msg_text:sub(1, ms - 1), palette.message),
                highlight_text(msg_text:sub(ms, me), hl),
                rh(msg_text:sub(me + 1), palette.message),
            })
        else
            message = rh(msg_text, palette.message) or ""
        end
        local ref_items = get_ref_items(item.commit,
            M.node_label_colour(opts, item.columns, emphasis, item.commit, head_branch))

        local date_item = rh(git.format_date(item.commit.date, opts) .. " ", palette.date)
        local author_item = rh((item.commit.author or "") .. " ", palette.author)
        local graph_item = M.get_column_chars(opts, item.columns, emphasis) -- the node line

        -- Stacked virtual rows above (the split fan-in, plus any `gutter` handover
        -- rows — §5 Line, topmost first) / below (merge fan-out).
        local above, below = fan_lines(true)

        ---@type DisplayElement
        local element = { above = above, below = below }

        if M.dual_two_line(opts, item.commit) then
            -- Two real rows (§6.1): row 1 = graph (node) + labels; row 2 = the
            -- message, the graph continued downward (down-passthrough, no node),
            -- indented DUAL_INDENT cells from the graph edge (on the graph side in
            -- both orientations: mirrored, the message still follows the graph).
            local labels = {}
            for k, it in ipairs(ref_items) do
                if k > 1 then labels[#labels + 1] = " " end
                labels[#labels + 1] = it
            end
            element.lines = {
                { date_item, author_item, graph_item, compose(labels) },
                {
                    "", "",
                    M.get_column_chars(opts, passthrough_columns(item.columns, "down"), emphasis),
                    compose({ (" "):rep(M.DUAL_INDENT), ids, message }),
                },
            }
        elseif label_mode == "inline" then
            -- Labels left-aligned right after the graph, before the message.
            ---@type (DisplayItem|string)[]
            local parts = { ids }
            for _, it in ipairs(ref_items) do
                parts[#parts + 1] = it
                parts[#parts + 1] = " "
            end
            parts[#parts + 1] = message
            element.line = { date_item, author_item, graph_item, compose(parts) }
        else
            -- "right" (default) refs pinned to the right edge; "dual" commits with
            -- no labels fall here too (single row: node + message).
            element.line = { date_item, author_item, graph_item, compose({ ids, message }) }
            if label_mode ~= "dual" then
                element.line_right = ref_items
                -- The selected decoration's index *within line_right* (which may
                -- prepend a non-selectable HEAD marker), so the listview windows
                -- the right-pinned refs around it (§6). nil → leftmost-first +N.
                if selected then
                    local extra = #ref_items - #M.decoration_texts(item.commit, head_branch, pins)
                    element.line_right_sel = selected + extra
                end
            end
        end

        return element
    else
        return { line = { "", "", M.get_column_chars(opts, item.columns), "", "" } }
    end
end

--- Human-readable dump of a row's lanes, for the `K` debug float.
---@param item OrderItem
---@return string[]
function M.format_lane_info(item)
    local function short(c)
        return (c and c.hash) and c.hash:sub(1, 7) or "-"
    end
    local function sides(conn)
        local s = {}
        for _, k in ipairs({ "up", "down", "left", "right" }) do
            if conn[k] then s[#s + 1] = k:sub(1, 1) end
        end
        return table.concat(s, "")
    end

    local lines = {}
    lines[#lines + 1] = ("commit %s  %s"):format(short(item.commit), item.commit.message or "")

    local function dump(label, columns)
        if not columns then return end
        lines[#lines + 1] = label .. ":"
        for i, t in ipairs(columns) do
            local head = ("  #%d %s"):format(i, t.has_commit and "●" or "·")
            local lanes = t.lanes or {}
            if #lanes == 0 then
                lines[#lines + 1] = head .. " (no lanes)"
            end
            for j, lane in ipairs(lanes) do
                lines[#lines + 1] = ("%s id=%s [%s] parent=%s"):format(
                    j == 1 and head or string.rep(" ", #head),
                    tostring(lane.id), sides(lane.connectivity), short(lane.parent))
            end
        end
    end

    for i, line in ipairs(item.above or {}) do
        dump(("above %d/%d"):format(i, #item.above), line)
    end
    dump("commit line", item.columns)
    dump("merge (below)", item.merge)
    return lines
end

return M
