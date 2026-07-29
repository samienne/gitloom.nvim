--- Reachability emphasis (specification.md §12) — the pivot's causal cone and
--- the Lane-graph walk that lights it. Pure (no window/IO): operates on the laid
--- OrderItems (Phase 1 attached each row's parent_lanes/child_lanes). Part of the
--- gitloom graph engine.

local M = {}

--- The rendered lines of an OrderItem in display order (the virtual `above` lines,
--- then the commit line, then the merge fan), skipping absent ones. A plain
--- `{item.above, item.columns, item.merge}` can't be `ipairs`-ed because a nil
--- entry truncates the list.
---@param item OrderItem|nil
---@return GraphColumn[][]
function M.item_lines(item)
    local out = {}
    if not item then return out end
    for _, l in ipairs(item.above or {}) do out[#out + 1] = l end
    if item.columns then out[#out + 1] = item.columns end
    if item.merge then out[#out + 1] = item.merge end
    return out
end

--- The pivot's causal cone (specification.md §12.1): the commit at
--- order[pivot_index] plus its ancestors (a parent-only sweep) and descendants
--- (a child-only sweep), each monotonic, restricted to commits in the visible
--- rows top..bottom (the window bound). Returns a set keyed by Commit, pivot
--- included. Pure (no view/IO).
---@param order OrderItem[]
---@param pivot_index integer
---@param top integer
---@param bottom integer
---@return table<Commit, boolean>
function M.reachable_cone(order, pivot_index, top, bottom)
    local cone = {}
    local pivot_item = order[pivot_index]
    local pivot = pivot_item and pivot_item.commit
    if not pivot then return cone end

    -- Only on-screen commits are eligible (§12.1: compute over visible rows).
    local visible = {}
    for i = top, bottom do
        local it = order[i]
        if it and it.commit then visible[it.commit] = true end
    end
    if not visible[pivot] then return cone end

    cone[pivot] = true

    -- Ancestors: a single sweep following parent links only.
    local stack = { pivot }
    while #stack > 0 do
        local c = table.remove(stack)
        for _, p in ipairs(c.parents or {}) do
            if visible[p] and not cone[p] then
                cone[p] = true
                stack[#stack + 1] = p
            end
        end
    end

    -- Descendants: a single sweep following child links only.
    stack = { pivot }
    while #stack > 0 do
        local c = table.remove(stack)
        for _, ch in ipairs(c.children or {}) do
            if visible[ch] and not cone[ch] then
                cone[ch] = true
                stack[#stack + 1] = ch
            end
        end
    end

    return cone
end

--- Mark the reachability emphasis from the pivot (specification.md §12) by
--- walking the **Lane graph**: from the pivot commit, follow `parent_lanes`
--- (ancestors) then `child_lanes` (descendants), setting `highlighted` on each
--- Lane reached and `active` on each cone commit's marker. Bounded to the
--- visible rows top..bottom. Returns the cone commit set (drives the row-field
--- dimming, §12.2). Exact: each Lane is one edge, so a sibling sharing a fan is
--- a distinct Lane and never lights. Assumes Phase 1 (columns.layout) has run,
--- so each OrderItem carries its `parent_lanes`/`child_lanes`.
---@param order OrderItem[]
---@param pivot_index integer
---@param top integer
---@param bottom integer
---@return table<Commit, boolean>
function M.mark_reachable(order, pivot_index, top, bottom)
    local item_of, visible = {}, {}
    for i = top, bottom do
        local it = order[i]
        if it and it.commit then
            item_of[it.commit] = it
            visible[it.commit] = true
        end
    end

    -- Reset: clear the highlight on every Lane *drawn* in the window (via each
    -- Segment's edges, so a pass-through lane whose endpoints are off-window is
    -- cleared too) and the incident edges of every visible commit; dim every
    -- commit marker.
    for i = top, bottom do
        local it = order[i]
        if it then
            for _, l in ipairs(it.parent_lanes or {}) do l.highlighted = false end
            for _, l in ipairs(it.child_lanes or {}) do l.highlighted = false end
            for _, line in ipairs(M.item_lines(it)) do
                for _, t in ipairs(line) do
                    for _, s in ipairs(t.lanes or {}) do
                        for _, e in ipairs(s.edges or {}) do e.highlighted = false end
                    end
                    if t.has_commit then t.active = false end
                end
            end
        end
    end

    local cone = {}
    local pivot = order[pivot_index] and order[pivot_index].commit
    if not pivot or not visible[pivot] then return cone end
    cone[pivot] = true

    -- Every parent edge of an ancestor leads to a deeper ancestor, so all of a
    -- reached commit's parent_lanes are cone edges — highlight them even when the
    -- parent is off-window (its visible stub still lights); only recurse into
    -- on-window parents. Symmetric for descendants via child_lanes.
    local stack = { pivot } -- ancestors
    while #stack > 0 do
        local it = item_of[table.remove(stack)]
        for _, lane in ipairs(it and it.parent_lanes or {}) do
            lane.highlighted = true
            if visible[lane.parent] and not cone[lane.parent] then
                cone[lane.parent] = true
                stack[#stack + 1] = lane.parent
            end
        end
    end

    stack = { pivot } -- descendants
    while #stack > 0 do
        local it = item_of[table.remove(stack)]
        for _, lane in ipairs(it and it.child_lanes or {}) do
            lane.highlighted = true
            if visible[lane.begin] and not cone[lane.begin] then
                cone[lane.begin] = true
                stack[#stack + 1] = lane.begin
            end
        end
    end

    for c in pairs(cone) do -- light the cone commits' markers
        for _, line in ipairs(M.item_lines(item_of[c])) do
            for _, t in ipairs(line) do
                if t.has_commit and t.commit == c then t.active = true end
            end
        end
    end

    return cone
end

return M
