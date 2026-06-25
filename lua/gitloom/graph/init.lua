--- gitloom.graph — the graph engine.
---
--- A pure pipeline turning the commit DAG into renderable rows: the view builder
--- (view.lua, §10) projects modes into an OrderItem graph, Phase 1 (columns.lua)
--- lays lanes into columns, Phase 2 (render.lua) draws glyphs/colour, reach.lua
--- computes the §12 emphasis, and select.lua walks selections. This module is the
--- engine's entry point: it owns the layout-orchestration glue (build_graph,
--- refresh_columns, pack_markers, owners_from_refs) and re-exports the pure
--- surface for tests (`_internal`). No window/buffer coupling — the controller
--- (gitloom.window) drives this.

local git = require("gitloom.git")
local util = require("gitloom.util")
local columns = require("gitloom.graph.columns")
local render = require("gitloom.graph.render")
local selectm = require("gitloom.graph.select")
local reach = require("gitloom.graph.reach")

local M = {}

-- ── Engine data-model types (specification.md §4, §5) ───────────────────────

---@class Connectivity
---@field up boolean
---@field down boolean
---@field left boolean
---@field right boolean

--- A **Lane** is one drawn edge, child -> parent (specification.md §5). `begin`
--- is the child (above), `parent` the parent/end (below); `id` drives colour;
--- `highlighted` marks it for the reachability emphasis (§12). One Lane per
--- parent/child edge, shared by every Segment that draws it.
---@class Lane
---@field id integer|nil
---@field color integer|nil   palette slot (1-based) from the free list; drives colour
---@field begin Commit
---@field parent Commit
---@field highlighted boolean

--- A **Segment** is one wire within a `GraphColumn`: its connectivity plus the
--- Lane(s) it draws (a list — usually one, but a shared fan bus carries the set
--- of edges routing through it).
---@class Segment
---@field id integer|nil
---@field color integer|nil   palette slot of the Lane(s) this wire draws
---@field connectivity Connectivity
---@field begin? Commit
---@field parent? Commit
---@field edges? Lane[]   the edge(s) this wire draws (§5)
---@field highlighted? boolean  segment-level cone state — overrides `edges` when set; the context panes use it (§6.2)
---@field cone? string  hash of the node whose cone-membership governs this segment's dimming in a header pane (§6.2)

---@class GraphColumn
---@field id integer|nil
---@field color integer|nil   palette slot for the cell's glyph colour
---@field connectivity Connectivity
---@field has_commit boolean
---@field commit? Commit
---@field begin? Commit   the child end of this wire's edge (lane begin); §5
---@field parent? Commit  the parent end of this wire's edge (lane end); §5
---@field override? string
---@field lanes? Segment[]  per-wire decomposition of the cell (Segments; §5)
---@field active? boolean  commit-marker emphasis state, set by mark_reachable (§12)

---@class OrderItem
---@field type "commit"|"merge"|"split"|"markers"
---@field commit? Commit
---@field markers? Commit[]  the packed marker DisplayNodes on a "markers" row (§10.4)
---@field columns GraphColumn[]
---@field split? GraphColumn[]
---@field merge? GraphColumn[]
---@field parent_lanes? Lane[]  edges out to this commit's parents (§5)
---@field child_lanes? Lane[]   edges in from this commit's children (§5)

--- Tracks the current ref selection (specification.md §2). Held by commit
--- identity so it survives reflow; `index` is 1-based into the row's selectable
--- decorations (branch groups then tags), or nil for no selection.
--- `commit` is the selection anchor: a Commit on a normal row, or the OrderItem
--- itself on a packed marker-group row (§10.4). `index` is 1-based into the row's
--- selectable units (ref decorations, or markers in a group), or nil.
---@class SelectionState
---@field commit Commit|OrderItem|nil
---@field index integer|nil

-- ── Layout orchestration ────────────────────────────────────────────────────

--- Build the full graph layout from an ordered list of items, from scratch.
--- Pure and deterministic (fresh lane-id sequence each call). Returns new row
--- tables (does not mutate the inputs). This is the reflow primitive and the
--- entry point for tests.
---@param opts GraphOptions
---@param items OrderItem[]   ordered items, each carrying a wired `.commit`
---@return OrderItem[]
local function build_graph(opts, items)
    -- Phase 1 of the two-phase pipeline (see lua/gitloom/graph/columns.lua): lane
    -- layout into columns with per-segment connectivity, validated for continuity.
    -- Phase 2 (get_column_chars) renders glyphs/colour from the segments.
    return columns.layout(opts, items)
end
M.build_graph = build_graph

--- Re-run Phase 1 over the whole order and copy the fresh lines/lanes back into
--- the existing OrderItems (the view holds references to them). `start_pos` is
--- ignored — the lane layout (with compaction) is global, so a partial relayout
--- would be incorrect; a full rebuild is simplest and cheap enough here.
---@param opts GraphOptions
---@param order OrderItem[]
local function refresh_columns(opts, order, _start_pos)
    local rebuilt = columns.layout(opts, order)
    for i = 1, #order do
        local r = rebuilt[i]
        order[i].columns = r.columns
        order[i].split = r.split
        order[i].merge = r.merge
        order[i].parent_lanes = r.parent_lanes
        order[i].child_lanes = r.child_lanes
    end
end
M.refresh_columns = refresh_columns

--- Pack adjacent **marker** rows (collapsed heads, spec §10.4) that overlay
--- cleanly into one *marker-group* row, so concurrent collapsed branches share a
--- line. Conservative: across the group a column may hold at most one node and
--- one lane id, and any overlapping (≥2-row) column must be horizontal-free —
--- anything else ends the group. Compaction already makes only the safe merges
--- compatible (a turn between two rows breaks vertical continuity). The packed
--- grid is validated by the same wires-connect checker the layout uses.
---@param items OrderItem[]
---@return OrderItem[]
local function pack_markers(items)
    local function is_marker(it)
        return it.commit ~= nil and it.commit.collapsed and it.split == nil and it.merge == nil
    end

    -- Overlay group rows into one columns array; nil if any column is incompatible.
    local function overlay(group)
        local width = 0
        for _, it in ipairs(group) do
            if #it.columns > width then width = #it.columns end
        end
        local cols = {}
        for c = 1, width do
            local node_cell, lane_id, occ, has_h, seg = nil, nil, 0, false, nil
            for _, it in ipairs(group) do
                local cell = it.columns[c]
                if cell and (cell.has_commit or (cell.lanes and #cell.lanes > 0)) then
                    occ = occ + 1
                    if cell.has_commit then
                        if node_cell then return nil end -- two nodes in one column
                        node_cell = cell
                    end
                    for _, s in ipairs(cell.lanes or {}) do
                        seg = seg or s
                        if lane_id == nil then
                            lane_id = s.id
                        elseif lane_id ~= s.id then
                            return nil -- two distinct lanes in one column
                        end
                    end
                    local cc = cell.connectivity
                    if cc and (cc.left or cc.right) then has_h = true end
                end
            end
            if occ >= 2 and has_h then return nil end -- overlapping content + a turn
            -- up from the topmost row, down from the bottom row; horizontals only
            -- from a sole occupant (rejected above when overlapping).
            local top, bot = group[1].columns[c], group[#group].columns[c]
            local conn = {
                up = (top and top.connectivity and top.connectivity.up) or false,
                down = (bot and bot.connectivity and bot.connectivity.down) or false,
                left = false,
                right = false,
            }
            if occ == 1 then
                for _, it in ipairs(group) do
                    local cell = it.columns[c]
                    if cell and (cell.has_commit or (cell.lanes and #cell.lanes > 0)) then
                        conn.left = cell.connectivity.left or false
                        conn.right = cell.connectivity.right or false
                    end
                end
            end
            local lanes = {}
            if seg then
                lanes[1] = {
                    id = seg.id, color = seg.color, begin = seg.begin, parent = seg.parent,
                    connectivity = conn, edges = seg.edges,
                }
            end
            cols[c] = {
                connectivity = conn,
                lanes = lanes,
                has_commit = node_cell ~= nil,
                commit = node_cell and node_cell.commit or nil,
                id = seg and seg.id or nil,
                color = seg and seg.color or nil,
                begin = seg and seg.begin or nil,
                parent = seg and seg.parent or nil,
            }
        end
        return cols
    end

    local out = {}
    local i = 1
    while i <= #items do
        if is_marker(items[i]) then
            local group, merged, j = { items[i] }, items[i].columns, i + 1
            while j <= #items and is_marker(items[j]) do
                local cand = vim.list_extend({}, group)
                cand[#cand + 1] = items[j]
                local m = overlay(cand)
                if not m then break end
                group, merged, j = cand, m, j + 1
            end
            if #group == 1 then
                out[#out + 1] = items[i]
            else
                local markers = {}
                for _, g in ipairs(group) do markers[#markers + 1] = g.commit end
                ---@type OrderItem
                out[#out + 1] = { type = "markers", markers = markers, columns = merged }
            end
            i = j
        else
            out[#out + 1] = items[i]
            i = i + 1
        end
    end
    return out
end
M.pack_markers = pack_markers

--- Owners for the view builder (specification.md §10): one per ref, carrying
--- its current mode. The `HEAD` marker is skipped — it is a symref onto a branch
--- already present as its own owner, not an independent branch. The owner id is
--- the ref's table key (its name), so a mode keyed by that name survives reflow.
---@param refs table<string, Ref>
---@param modes table<string, string>  -- ref name → "normal"|"collapsed"|"hidden"
---@return table[]  -- { id, tip = Commit, mode }
local function owners_from_refs(refs, modes)
    local out = {}
    for name, ref in pairs(refs) do
        if ref.kind ~= "head" and ref.commit then
            out[#out + 1] = { id = name, tip = ref.commit, mode = modes[name] or "normal" }
        end
    end
    return out
end
M.owners_from_refs = owners_from_refs

-- ── Test seam (pure functions only; not the public API) ─────────────────────
-- Re-exports the engine + data-library pure surface so the existing specs keep
-- driving them through `require("gitloom.graph")._internal`.
M._internal = {
    -- gitloom.git (model / parse / format / refs / range / order / date)
    classify_ref = git.classify_ref,
    group_refs = git.group_refs,
    track_segments = git.track_segments,
    track_label = git.track_label,
    bump_recent = git.bump_recent,
    ref_picker_items = git.ref_picker_items,
    ref_decoration_index = git.ref_decoration_index,
    parse_commit_line = git.parse_commit_line,
    make_line_buffer = git.make_line_buffer,
    order_commits = git.order_commits,
    diff_ref_tips = git.diff_ref_tips,
    reachable_hashes = git.reachable_hashes,
    parse_timestamp = git.parse_timestamp,
    format_absolute = git.format_absolute,
    format_relative = git.format_relative,
    parse_show = git.parse_show,
    format_commit_detail = git.format_commit_detail,
    format_diff = git.format_diff,
    diffstat_files = git.diffstat_files,
    diff_contexts = git.diff_contexts,
    format_diffstat = git.format_diffstat,
    commit_range = git.commit_range,
    range_endpoints = git.range_endpoints,
    format_range_detail = git.format_range_detail,
    parse_status = git.parse_status,
    worktree_label = git.worktree_label,
    format_worktree_detail = git.format_worktree_detail,
    -- gitloom.util
    make_future = util.make_future,
    -- gitloom.graph.render (Phase 2)
    decoration_texts = render.decoration_texts,
    pane_labels = render.pane_labels,
    display_item = render.display_item,
    get_column_chars = render.get_column_chars,
    top_lane = render.top_lane,
    passthrough_columns = render.passthrough_columns,
    -- gitloom.graph.select
    move_selection = selectm.move_selection,
    ref_byte_col = selectm.ref_byte_col,
    sel_ascend_children = selectm.sel_ascend_children,
    sel_step = selectm.sel_step,
    sel_switch = selectm.sel_switch,
    next_mode = selectm.next_mode,
    selected_owner_ids = selectm.selected_owner_ids,
    collapse_owners = selectm.collapse_owners,
    -- gitloom.graph.reach
    reachable_cone = reach.reachable_cone,
    mark_reachable = reach.mark_reachable,
    -- this module (layout orchestration)
    build_graph = build_graph,
    owners_from_refs = owners_from_refs,
    pack_markers = pack_markers,
}

return M
