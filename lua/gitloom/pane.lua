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

return M
