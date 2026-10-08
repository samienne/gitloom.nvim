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
---@field own_lane_up? boolean  this node's OWN lane is the wire above, not the one
---   below, so its colour comes from `up` — a licensed spine break (§5.6 gutter swap)

---@class OrderItem
---@field type "commit"|"merge"|"split"|"markers"
---@field commit? Commit
---@field markers? Commit[]  the packed marker DisplayNodes on a "markers" row (§10.4)
---@field columns GraphColumn[]
---@field above? GraphColumn[][]  the virtual lines above the commit line, topmost
---   first: the §5.2 split fan, plus the `gutter` policy's handover rows (§5 Line)
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
--- entry point for tests. `yield` (optional) chunks a long sweep across
--- event-loop ticks (spec §10.5).
---@param opts GraphOptions
---@param items OrderItem[]   ordered items, each carrying a wired `.commit`
---@param yield (fun())?
---@return OrderItem[]
local function build_graph(opts, items, yield)
    -- Phase 1 of the two-phase pipeline (see lua/gitloom/graph/columns.lua): lane
    -- layout into columns with per-segment connectivity, validated for continuity.
    -- Phase 2 (get_column_chars) renders glyphs/colour from the segments.
    return columns.layout(opts, items, nil, yield)
end
M.build_graph = build_graph

--- Copy one freshly-swept row's lines/lanes onto the OrderItem the view holds.
---@param item OrderItem
---@param r OrderItem
local function adopt_row(item, r)
    item.columns = r.columns
    item.above = r.above
    item.merge = r.merge
    item.parent_lanes = r.parent_lanes
    item.child_lanes = r.child_lanes
end

--- Re-run Phase 1 over the whole order and copy the fresh lines/lanes back into
--- the existing OrderItems (the view holds references to them). This is the
--- from-scratch form — `extend_columns` is the streaming one. `yield` (optional)
--- chunks the sweep across event-loop ticks.
---@param opts GraphOptions
---@param order OrderItem[]
---@param yield (fun())?
local function refresh_columns(opts, order, yield)
    local rebuilt = columns.layout(opts, order, nil, yield)
    for i = 1, #order do adopt_row(order[i], rebuilt[i]) end
end
M.refresh_columns = refresh_columns

--- The layout-relevant part of `opts`, as a comparable string. A streaming
--- session may only be continued while these hold still; anything that changes
--- them (`m`, `C`, a palette change) goes through a reflow anyway, so this is a
--- safety net rather than a hot path.
---@param opts GraphOptions
---@return string
local function layout_fingerprint(opts)
    local ms = opts.merge_style or {}
    local p = opts.palette or {}
    return table.concat({
        tostring(opts.layout_policy), tostring(opts.junction_markers),
        tostring(ms.allow_merge_on_split), tostring(ms.merge_on_separate_line),
        tostring(ms.split_on_separate_line),
        tostring(p.tracks and #p.tracks or 0), tostring(p.generate), tostring(p.buffer),
    }, "")
end

--- **Streaming** Phase 1 (spec §3.1): lay out the rows appended at `start_pos`
--- by CONTINUING the sweep that laid out the rows above them, instead of redoing
--- the whole order for every batch. The sweep is a strict top-down fold and the
--- stream only ever appends *below*, so continuing is exact (see
--- `columns.session`) — and it turns the stream's total layout cost from
--- O(N²/batch) into one sweep.
---
--- `stream` is the opaque state to pass back on the next batch; pass nil to start
--- one. The session is dropped and the order rebuilt in full whenever it cannot
--- be continued: a different layout fingerprint, a rewound/reordered `order`, or
--- a policy that reads ahead (`gutter`). So the fast path is an optimisation and
--- the slow path is always available, never a correctness cliff.
---@param opts GraphOptions
---@param order OrderItem[]
---@param start_pos integer  first appended row (1-based)
---@param stream table?      previous return value
---@return table stream
local function extend_columns(opts, order, start_pos, stream)
    local fp = layout_fingerprint(opts)
    if not (stream and stream.session and stream.fp == fp and stream.n == start_pos - 1) then
        local session = columns.session(opts)
        if session.lookahead then
            -- The policy needs the whole list up front; today's full rebuild is the
            -- only correct answer (and `gutter` is never the streaming default).
            refresh_columns(opts, order)
            return { fp = fp, n = #order, session = nil }
        end
        stream = { fp = fp, n = 0, session = session }
        start_pos = 1
    end
    local fresh = stream.session.extend(order, start_pos)
    for k = 1, #fresh do adopt_row(order[start_pos + k - 1], fresh[k]) end
    stream.n = #order
    return stream
end
M.extend_columns = extend_columns

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
        -- No virtual lines at all: a marker row is one screen row, so packing it
        -- with its neighbours cannot swallow a fan or a handover row.
        return it.commit ~= nil and it.commit.collapsed
            and #(it.above or {}) == 0 and it.merge == nil
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
--- its current mode. An **attached** `HEAD` marker (one naming its `branch`) is
--- skipped — it is a symref onto a branch already present as its own owner. A
--- **detached** HEAD is an owner of its own, id `HEAD` (§10.1/§10.6): it is what
--- keeps the checked-out commit a pinnable anchor when no branch names it, and
--- the id survives a resync because HEAD is re-bound, not renamed. The owner id
--- is the ref's table key (its name), so a mode keyed by that name survives reflow.
---@param refs table<string, Ref>
---@param modes table<string, string>  -- ref name → "normal"|"collapsed"|"hidden"
---@return table[]  -- { id, tip = Commit, mode }
local function owners_from_refs(refs, modes)
    local out = {}
    for name, ref in pairs(refs) do
        if ref.commit and not (ref.kind == "head" and ref.branch) then
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
    parse_worktrees = git.parse_worktrees,
    worktree_refs = git.worktree_refs,
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
    marker_units = render.marker_units,
    display_item = render.display_item,
    get_column_chars = render.get_column_chars,
    graph_snippet = render.graph_snippet,
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
    selected_ref = selectm.selected_ref,
    checkout_spec = selectm.checkout_spec,
    pin_resolve = selectm.pin_resolve,
    pin_move = selectm.pin_move,
    pin_toggle_reserved = selectm.pin_toggle_reserved,
    pin_remove = selectm.pin_remove,
    pin_add = selectm.pin_add,
    pin_ids = selectm.pin_ids,
    reserved_order = selectm.reserved_order,
    pin_dialog_lines = selectm.pin_dialog_lines,
    smartcase_match = selectm.smartcase_match,
    filter_keep = selectm.filter_keep,
    -- gitloom.graph.reach
    reachable_cone = reach.reachable_cone,
    mark_reachable = reach.mark_reachable,
    -- this module (layout orchestration)
    build_graph = build_graph,
    owners_from_refs = owners_from_refs,
    pack_markers = pack_markers,
}

return M
