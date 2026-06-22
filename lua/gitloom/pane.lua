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

--- Partition a boundary map into the lanes that **continue** into the pane (their
--- parent commit is present among `pane_items`) and those that **terminate** at
--- the seam (the rest — non-anchor branches folded out of the pane). Identity is
--- by the parent's hash; an anchor lane's parent is a real commit present in the
--- anchors-only projection, so anchors continue and folded branches terminate.
---@param boundary table<integer, table>
---@param pane_items table[]  -- { type, commit } of the pane's projection
---@return table<integer, table> continue, table<integer, table> terminate
function M.split_boundary(boundary, pane_items)
    local present = {}
    for _, it in ipairs(pane_items) do present[it.commit.hash] = true end
    local cont, term = {}, {}
    for col, lane in pairs(boundary) do
        if lane.parent and present[lane.parent.hash] then
            cont[col] = lane
        else
            term[col] = lane
        end
    end
    return cont, term
end

--- Build the **footer** pane below the main view (spec §6.2). `pane_items` is the
--- anchors-only projection of the off-screen-older commits (newest-first, ending
--- at the roots); `boundary` is the main view's bottom seam (`boundary_below`).
--- The seam is the footer's **top** = its sweep start, so the continuing lanes
--- seed `columns.layout` directly and the seam matches exactly.
---
--- Returns `{ rows, terminate }`: the laid-out pane rows and the seam map of
--- lanes that do not continue (to be rendered as arrow-caps — the terminator
--- glyphs are Phase 2 / still to wire, §6.2).
---@param opts table
---@param pane_items table[]
---@param boundary table<integer, table>
---@return table  -- { rows = table[], terminate = table<integer, table> }
function M.footer(opts, pane_items, boundary)
    local cont, term = M.split_boundary(boundary, pane_items)
    return { rows = columns.layout(opts, pane_items, cont), terminate = term }
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
