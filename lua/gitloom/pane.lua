--- Context panes (spec §6.2): the pure layout core for the header/footer windows
--- that summarise off-screen topology folded onto the pinned anchors (§10.6).
---
--- A pane is laid out by `columns.layout` over its own **anchors-only**
--- projection (built by `view.project` with the anchor owner set, *no* user mode
--- overrides — see ARCHITECTURE.md "Context panes"), seeded at the **seam** with
--- the main view's boundary lanes so the two meet without a jog. This module is
--- git-agnostic and window-agnostic — it consumes already-projected OrderItems
--- and a boundary map and returns laid-out rows, so it is unit-testable without
--- snacks. Window placement, sizing, and the async rebuild live in graph.lua.
local M = {}

local columns = require("gitloom.columns")

--- Contract an anchor-only projection (heads + junctions, from `view.project`
--- with the anchors collapsed) into the **condensed graph** (spec §6.2): the only
--- nodes kept are **ref heads, junctions (fork/merge), tips and roots**; every
--- pure linear pass-through (a ref-less collapsed head with exactly one parent and
--- one child) is **spliced out**, its lane becoming a direct edge. So the pane is
--- a small "navigate between ref heads and junctions" graph that lays out compact
--- (one row per kept node, linear runs cost zero rows) and can be cached and
--- re-sliced per scroll instead of reprojected.
---
--- `node_of_hash` maps **every** original commit hash — including a spliced run's
--- members — to the condensed node that represents it: a kept node maps its own
--- hashes; a spliced node maps to the next kept node toward the **root** (so a
--- seam lane descending through the run terminates at the right node).
--- `anchor_names` (optional): only refs whose name is in this set count as
--- markers — non-anchor refs (tags, unpinned branches) on intermediate commits
--- are ignored, so a run carrying only those still splices away. When omitted,
--- any ref keeps a node.
---@param nodes table[]  -- DisplayNodes (projection .nodes), newest-first
---@param anchor_names table<string, boolean>?  -- ref names that count as markers
---@return table  -- { items = OrderItem[], node_of_hash = table<string, table> }
function M.condense(nodes, anchor_names)
    -- Refs on a node that count as markers (anchor refs, or all when unfiltered).
    local function marker_refs(n)
        if not anchor_names then return n.refs or {} end
        local out = {}
        for _, r in ipairs(n.refs or {}) do
            if r.name and anchor_names[r.name] then out[#out + 1] = r end
        end
        return out
    end
    -- A node splices away when it is a **pure linear pass-through with no anchor
    -- marker**: exactly one parent and one child. This is purely topological, so
    -- it contracts the *whole* commit graph — every lane's linear stretch becomes
    -- one edge, while every real fork/merge (≥2 edges, where a branch connects to
    -- the trunk), root, tip, and anchor-ref head is kept.
    local function transparent(n)
        return #marker_refs(n) == 0 and #n.parents == 1 and #n.children == 1
    end
    -- The next kept node along a chain of transparent nodes, via `field`
    -- ("parents" toward the root, "children" toward the seam).
    local function follow(start, field)
        local cur = start
        while cur and transparent(cur) do cur = cur[field][1] end
        return cur
    end

    -- A copy per kept node (inherits the original's fields via metatable).
    local copy = {}
    for _, n in ipairs(nodes) do
        if not transparent(n) then
            copy[n] = setmetatable({
                hash = n.hash, parents = {}, children = {},
                refs = marker_refs(n), region = n.region, tip = n.tip,
            }, { __index = n })
        end
    end

    -- Re-point edges among kept nodes, jumping over spliced runs (dedup).
    for _, n in ipairs(nodes) do
        local c = copy[n]
        if c then
            local pseen, cseen = {}, {}
            for _, p in ipairs(n.parents) do
                local k = transparent(p) and follow(p, "parents") or p
                if k and copy[k] and not pseen[k] then
                    pseen[k] = true; c.parents[#c.parents + 1] = copy[k]
                end
            end
            for _, ch in ipairs(n.children) do
                local k = transparent(ch) and follow(ch, "children") or ch
                if k and copy[k] and not cseen[k] then
                    cseen[k] = true; c.children[#c.children + 1] = copy[k]
                end
            end
        end
    end

    -- Rendering role per kept node, from its anchor refs and its (projected)
    -- degree: an anchor-ref head is a `◍` marker; a fork/merge is a node-less
    -- junction (just the join glyph); a root or tip is a real node.
    for _, n in ipairs(nodes) do
        local c = copy[n]
        if c then
            if #c.refs > 0 then
                c.collapsed, c.junction = true, false
            elseif #c.parents >= 2 or #c.children >= 2 then
                c.collapsed, c.junction = false, true
            else
                c.collapsed, c.junction = false, false
            end
        end
    end

    -- node_of: kept nodes map their own hashes; a spliced node maps to the next
    -- kept node toward the root.
    local node_of = {}
    local function map_to(n, target)
        if not target then return end
        node_of[n.hash] = target
        for _, h in ipairs(n.region or {}) do node_of[h] = target end
    end
    for _, n in ipairs(nodes) do
        if copy[n] then
            map_to(n, copy[n])
        else
            local k = follow(n.parents[1], "parents")
            map_to(n, k and copy[k])
        end
    end

    local items = {}
    for _, n in ipairs(nodes) do
        if copy[n] then items[#items + 1] = { type = "commit", commit = copy[n] } end
    end
    return { items = items, node_of_hash = node_of }
end

--- Cap a footer's rows to `max` while **always keeping the root** (the last row).
--- Rows are newest-first (seam at the top, root at the bottom): keep the
--- seam-nearest `max-1` rows and the final root row. (When over the cap the
--- middle is elided — a deliberate gap — so the root stays visible, §6.2.)
---@param rows table[]
---@param max integer
---@return table[]
function M.cap(rows, max)
    if #rows <= max then return rows end
    local out = {}
    for i = 1, max - 1 do out[i] = rows[i] end
    out[max] = rows[#rows] -- the root, always
    return out
end

--- The seam map at the **bottom** edge of a laid-out row: every lane flowing
--- *down* out of it, as `col → Lane`. This is what a **footer** below row `i`
--- must seed with so its top seam matches the main view's edge.
---@param rows table[]  -- laid-out rows from columns.layout
---@param i integer     -- 1-based row index (the main view's last visible row)
---@return table<integer, table>  -- col → { id, color, parent, begin }
function M.boundary_below(rows, i)
    local row = rows[i]
    if not row then return {} end
    local line = row.merge or row.columns -- the last rendered line of the row
    local out = {}
    for col, cell in ipairs(line) do
        for _, s in ipairs(cell.lanes or {}) do
            if s.connectivity.down then
                out[col] = { id = s.id, color = s.color, parent = s.parent,
                    begin = s.begin, highlighted = false }
            end
        end
    end
    return out
end

--- The seam map at the **top** edge of a laid-out row: every lane flowing *up*
--- out of it, as `col → Lane`. The main view's top edge (row `i` = its first
--- visible row); a **header** above it must terminate at this map.
---@param rows table[]
---@param i integer
---@return table<integer, table>
function M.boundary_above(rows, i)
    local row = rows[i]
    if not row then return {} end
    local line = row.split or row.columns -- the first rendered line of the row
    local out = {}
    for col, cell in ipairs(line) do
        for _, s in ipairs(cell.lanes or {}) do
            if s.connectivity.up then
                out[col] = { id = s.id, color = s.color, parent = s.parent,
                    begin = s.begin, highlighted = false }
            end
        end
    end
    return out
end

--- Partition a boundary map into the lanes that **continue** into the pane and
--- those that **terminate** at the seam. A lane continues iff its parent commit
--- maps to a pane node via `node_of` (the projection's `node_of_hash`, which maps
--- every non-hidden commit hash — including a collapsed head's members — to the
--- node that represents it). So an anchor lane (its parent is in the pane, real
--- or inside a collapsed lane) continues; a hidden/folded branch terminates.
---@param boundary table<integer, table>
---@param node_of table<string, table>  -- commit hash → pane DisplayNode
---@return table<integer, table> continue, table<integer, table> terminate
function M.split_boundary(boundary, node_of)
    local cont, term = {}, {}
    for col, lane in pairs(boundary) do
        if lane.parent and node_of[lane.parent.hash] then
            cont[col] = lane
        else
            term[col] = lane
        end
    end
    return cont, term
end

--- Build the **footer** pane below the main view (spec §6.2). `pane_items` is the
--- pane projection of the off-screen-older commits (newest-first, ending at the
--- roots); `boundary` is the main view's bottom seam (`boundary_below`);
--- `node_of` is the projection's `node_of_hash`. The seam is the footer's **top**
--- = its sweep start, so each continuing lane seeds `columns.layout` — its parent
--- **translated** through `node_of` to the pane node that represents it (a real
--- commit, or the collapsed lane it was folded into) so the seed terminates at
--- the right place and the seam matches exactly.
---
--- Returns `{ rows, terminate }`: the laid-out pane rows and the seam map of
--- lanes that do not continue (to be rendered as arrow-caps — the terminator
--- glyphs are Phase 2 / still to wire, §6.2).
---@param opts table
---@param pane_items table[]
---@param boundary table<integer, table>
---@param node_of table<string, table>
---@return table  -- { rows = table[], terminate = table<integer, table> }
function M.footer(opts, pane_items, boundary, node_of)
    -- A lane only seeds if its target node is in THIS slice; one that maps to a
    -- node outside the slice would never terminate and would run off the bottom,
    -- so it terminates at the seam instead.
    local present = {}
    for _, it in ipairs(pane_items) do present[it.commit] = true end
    local seed, term = {}, {}
    for col, lane in pairs(boundary) do
        local target = lane.parent and node_of[lane.parent.hash]
        if target and present[target] then
            seed[col] = { id = lane.id, color = lane.color, begin = lane.begin,
                parent = target, highlighted = false }
        else
            term[col] = lane
        end
    end
    return { rows = columns.layout(opts, pane_items, seed), terminate = term }
end

--- Transpose: shallow proxy items whose parent/child edges are **swapped** and
--- restricted to the item set (a proxy `__index`es the original for refs/flags).
--- Laying the transpose out newest-first is laying the original out oldest-first,
--- which is how the header sweeps its seam (its sweep end) first. Returns the
--- proxy items (in input order) and an original-hash → proxy map.
---@param items table[]
---@return table[] titems, table<string, table> proxy
local function transpose(items)
    local inset, proxy = {}, {}
    for _, it in ipairs(items) do inset[it.commit.hash] = true end
    for _, it in ipairs(items) do
        local c = it.commit
        proxy[c.hash] = setmetatable({ hash = c.hash, parents = {}, children = {} }, { __index = c })
    end
    for _, it in ipairs(items) do
        local c, p = it.commit, proxy[it.commit.hash]
        for _, ch in ipairs(c.children or {}) do
            if inset[ch.hash] then p.parents[#p.parents + 1] = proxy[ch.hash] end
        end
        for _, pa in ipairs(c.parents or {}) do
            if inset[pa.hash] then p.children[#p.children + 1] = proxy[pa.hash] end
        end
    end
    local titems = {}
    for _, it in ipairs(items) do
        titems[#titems + 1] = { type = it.type, commit = proxy[it.commit.hash] }
    end
    return titems, proxy
end

local function flip_conn(c)
    return { up = c.down, down = c.up, left = c.left, right = c.right }
end

--- Vertical mirror of one rendered line: swap up↔down on every segment and the
--- cell union, keeping columns and node fields.
local function flip_line(line)
    if not line then return nil end
    local out = {}
    for i, cell in ipairs(line) do
        local segs = {}
        for _, s in ipairs(cell.lanes or {}) do
            local ns = {}
            for k, v in pairs(s) do ns[k] = v end
            ns.connectivity = flip_conn(s.connectivity)
            segs[#segs + 1] = ns
        end
        local nc = {}
        for k, v in pairs(cell) do nc[k] = v end
        nc.connectivity = flip_conn(cell.connectivity)
        nc.lanes = segs
        out[i] = nc
    end
    return out
end

--- Flip a laid-out sweep vertically: reverse the rows and, per row, swap up↔down,
--- swap the split (above) and merge (below) lines, and swap parent/child lanes.
--- Turns the transposed seam-first sweep back into header display order (tip at
--- top, seam at bottom).
---@param rows table[]
---@return table[]
local function flip(rows)
    local out = {}
    for i = #rows, 1, -1 do
        local r = rows[i]
        out[#out + 1] = {
            type = r.type,
            commit = r.commit,
            columns = flip_line(r.columns),
            split = flip_line(r.merge), -- below → above
            merge = flip_line(r.split), -- above → below
            parent_lanes = r.child_lanes,
            child_lanes = r.parent_lanes,
        }
    end
    return out
end

--- Build the **header** pane above the main view (spec §6.2). `header_items` is
--- the anchors-only projection of the off-screen-newer commits (newest-first, the
--- tips at the front); `boundary` is the main view's top seam (`boundary_above`).
---
--- The header's seam is its sweep **end**, which a start-seed cannot pin, so the
--- sweep is run **transposed and seam-first**: reverse to oldest-first, swap the
--- edges, seed the seam (now the start), lay out, then `flip` back to display
--- order. A continuing lane terminates (in transposed terms) at its **child** —
--- the in-header commit it ascends to. Returns `{ rows, terminate }` like footer.
---@param opts table
---@param header_items table[]
---@param boundary table<integer, table>
---@return table  -- { rows = table[], terminate = table<integer, table> }
function M.header(opts, header_items, boundary)
    -- A header lane continues iff its child (the lane's `begin`, the commit it
    -- ascends to) is present; the rest terminate at the seam.
    local present = {}
    for _, it in ipairs(header_items) do present[it.commit.hash] = true end
    local cont, term = {}, {}
    for col, lane in pairs(boundary) do
        if lane.begin and present[lane.begin.hash] then cont[col] = lane else term[col] = lane end
    end

    local rev = {}
    for i = #header_items, 1, -1 do rev[#rev + 1] = header_items[i] end
    local titems, proxy = transpose(rev)

    -- In transposed terms a continuing lane terminates at its child's proxy.
    local seed = {}
    for col, lane in pairs(cont) do
        seed[col] = { id = lane.id, color = lane.color, begin = lane.parent,
            parent = proxy[lane.begin.hash], highlighted = false }
    end

    return { rows = flip(columns.layout(opts, titems, seed)), terminate = term }
end

return M
