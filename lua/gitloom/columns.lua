--- Phase 1 of the two-phase graph pipeline: lane layout.
---
--- Places the commit DAG's lanes (edges child -> parent) into columns and emits,
--- per rendered line, the connectivity of every Segment in every Column. It does
--- NOT pick glyphs or colours (that is Phase 2, the renderer) — it only owns lane
--- placement and the continuity invariants. The design (see ARCHITECTURE.md):
---
---   * A **Lane** is one edge child -> parent, a persistent object that lives from
---     the child's row down to the parent's row. Reusing the object across rows is
---     what makes vertical continuity hold by construction (same id up and down).
---   * A **Column** holds one or more **Segments**. A Segment is one wire of one
---     Lane in that cell, with its own connectivity {up,down,left,right}.
---   * Per-column well-formedness (validated): at most one vertical (up+down)
---     segment; at most one segment turning horizontal -> up/down (two — one up,
---     one down — only when `allow_merge_on_split`). Empty columns are allowed.
---
--- Output shape matches the legacy build_graph so Phase 2 (get_track_chars) and
--- the invariant tests consume it unchanged: rows of { tracks, parent_lanes,
--- child_lanes }, each track { connectivity, lanes (Segment[]), has_commit,
--- commit, id, begin, parent }.
local M = {}

---@param t table
local function conn(t)
    return { up = t.up or false, down = t.down or false, left = t.left or false, right = t.right or false }
end

--- The union of a cell's segments' connectivity (the legacy flat `connectivity`,
--- still handed to Phase 2 as the "no highlight" glyph and used by validation).
local function union_conn(segs)
    local u = { up = false, down = false, left = false, right = false }
    for _, s in ipairs(segs) do
        local c = s.connectivity
        u.up = u.up or c.up
        u.down = u.down or c.down
        u.left = u.left or c.left
        u.right = u.right or c.right
    end
    return u
end

--- Build the per-row lines for the inline merge style (every fan on the commit
--- line; no separate split/merge lines). Other styles are layered on later.
---@param opts table
---@param items table[]  -- { type, commit } newest-first; commit.parents/children are Commits
---@return table[] rows
function M.layout(opts, items)
    local next_id = 0
    local function new_id()
        next_id = next_id + 1
        return next_id
    end

    local rows = {}
    local active = {} -- col -> Lane flowing down into the current row

    -- A fresh line buffer: `add` appends a Segment, `draw` lays one lane across
    -- columns lo..hi with `up`/`down` at the given columns (the bus connects them).
    local function new_line()
        local cells = {}
        -- A segment drawing one or more edges with explicit connectivity/id. A
        -- multi-edge segment is the shared trunk wire at a fan hub (the single
        -- descent into a merge / ascent out of a split): it lights if *any* of its
        -- edges is in the cone, which is what keeps a non-trunk cone lane connected
        -- through the hub.
        local function add_seg(j, c, edges, id)
            cells[j] = cells[j] or {}
            cells[j][#cells[j] + 1] = {
                id = id, begin = edges[1] and edges[1].begin, parent = edges[1] and edges[1].parent,
                connectivity = conn(c), edges = edges,
            }
        end
        local function add(j, lane, c) add_seg(j, c, { lane }, lane.id) end
        local function draw(lane, lo, hi, up_col, down_col)
            for m = lo, hi do
                local c = { left = m > lo or nil, right = m < hi or nil }
                if m == up_col then c.up = true end
                if m == down_col then c.down = true end
                add(m, lane, c)
            end
        end
        return cells, draw, add_seg
    end
    -- Turn a line's cells into a Track[] (the legacy shape). `commit_col` marks
    -- which column carries the commit marker (nil on a split/merge line).
    local function assemble(cells, commit_col, C)
        local width = 0
        for j in pairs(cells) do if j > width then width = j end end
        if commit_col and commit_col > width then width = commit_col end
        local tracks = {}
        for j = 1, width do
            local segs = cells[j] or {}
            tracks[j] = {
                connectivity = union_conn(segs),
                lanes = segs,
                has_commit = commit_col ~= nil and j == commit_col,
                commit = (commit_col ~= nil and j == commit_col) and C or nil,
                id = segs[1] and segs[1].id or nil,
                begin = segs[1] and segs[1].begin or nil,
                parent = segs[1] and segs[1].parent or nil,
            }
        end
        return tracks
    end

    for _, item in ipairs(items) do
        local C = item.commit

        -- Classify the active (incoming-from-above) lanes: those terminating at C
        -- (its child edges) versus those passing through (survivors).
        local incoming, survivors = {}, {}
        for j, lane in pairs(active) do
            if lane.parent == C then
                incoming[#incoming + 1] = { col = j, lane = lane }
            else
                survivors[#survivors + 1] = { col = j, lane = lane }
            end
        end
        table.sort(incoming, function(a, b) return a.col < b.col end)
        table.sort(survivors, function(a, b) return a.col < b.col end)

        -- Outgoing lanes: one per parent. The first parent continues the commit's
        -- column, so it *reuses the track id* of the lane flowing in there (the
        -- trunk child) — a straight chain keeps one colour. A new id is minted only
        -- where a lane is genuinely born: a branch head (a tip's first parent) and
        -- every extra parent of a merge.
        local trunk_id = incoming[1] and incoming[1].lane.id
        local outgoing = {}
        for i, p in ipairs(C.parents or {}) do
            local id = (i == 1 and trunk_id) or new_id()
            outgoing[#outgoing + 1] = { lane = { id = id, begin = C, parent = p, highlighted = false } }
        end

        -- The commit sits where its leftmost child arrives, or the leftmost free
        -- column for a tip.
        local cc
        if #incoming > 0 then
            cc = incoming[1].col
        else
            cc = 1
            while active[cc] do cc = cc + 1 end
        end

        local row = {
            type = item.type or "commit",
            commit = C,
            parent_lanes = {},
            child_lanes = {},
        }
        for _, o in ipairs(outgoing) do row.parent_lanes[#row.parent_lanes + 1] = o.lane end
        for _, inc in ipairs(incoming) do row.child_lanes[#row.child_lanes + 1] = inc.lane end

        local sep_split = opts.merge_style.split_on_separate_line and #incoming > 1
        local sep_merge = opts.merge_style.merge_on_separate_line and #outgoing > 1

        -- SPLIT LINE (above): the non-trunk children converge into the commit
        -- column and terminate; the leftmost child (the trunk) continues straight
        -- down to the commit line. Survivors pass through unchanged here; the
        -- columns the converged children vacated become gaps the commit line
        -- compacts into.
        if sep_split then
            local cells, draw, add_seg = new_line()
            local trunk = incoming[1]
            -- Only the trunk arrives from directly above the commit column; the
            -- single descent into the commit is shared by every converging child,
            -- so it carries them all (lights if any child is in the cone).
            add_seg(cc, { up = true }, { trunk.lane }, trunk.lane.id)
            local descent = {}
            for _, inc in ipairs(incoming) do descent[#descent + 1] = inc.lane end
            add_seg(cc, { down = true }, descent, trunk.lane.id)
            for i = 2, #incoming do
                local inc = incoming[i]
                draw(inc.lane, math.min(inc.col, cc), math.max(inc.col, cc), inc.col, nil)
            end
            for _, s in ipairs(survivors) do draw(s.lane, s.col, s.col, s.col, s.col) end
            row.split = assemble(cells, nil, nil)
            active = { [cc] = trunk.lane }
            for _, s in ipairs(survivors) do active[s.col] = s.lane end
            incoming = { { col = cc, lane = trunk.lane } } -- only the trunk reaches the commit line
        end

        -- Row-start occupancy for the commit line. Compaction may only move a lane
        -- into a column empty *here*, never one another lane vacates on this same
        -- line — that keeps two turns out of one cell (allow_merge_on_split aside).
        local occ0 = {}
        for j in pairs(active) do occ0[j] = true end

        -- Gentle left compaction of survivors: each shifts to the leftmost
        -- row-start gap to its left (a horizontal turn), else stays. A gap freed
        -- this row is reclaimed on a later row (a ripple), so turns never collide.
        local used = { [cc] = true }
        for _, s in ipairs(survivors) do
            local k = s.col
            for c = 1, s.col - 1 do
                if not occ0[c] and not used[c] then
                    k = c; break
                end
            end
            used[k] = true
            s.out = k
        end

        -- Outgoing columns: the first parent continues at the commit column; the
        -- rest fan to fresh columns on the right (on the merge line if separate).
        -- Under allow_merge_on_split they instead reuse the columns just freed by
        -- the merge (the non-trunk children's), so an ending child lane and a
        -- starting parent lane share a cell — the sanctioned two-turn column.
        local freed = {}
        if opts.merge_style.allow_merge_on_split then
            for i = 2, #incoming do freed[#freed + 1] = incoming[i].col end
        end
        local maxcol = cc
        for _, s in ipairs(survivors) do if s.out > maxcol then maxcol = s.out end end
        for j in pairs(occ0) do if j > maxcol then maxcol = j end end
        if outgoing[1] then outgoing[1].out = cc end
        local fi, nextc = 1, maxcol + 1
        for i = 2, #outgoing do
            local k
            if fi <= #freed then
                k = freed[fi]; fi = fi + 1
            else
                while used[nextc] do nextc = nextc + 1 end
                k = nextc; nextc = nextc + 1
            end
            outgoing[i].out = k
            used[k] = true
        end

        -- COMMIT LINE.
        local cells, draw = new_line()
        for _, s in ipairs(survivors) do
            draw(s.lane, math.min(s.col, s.out), math.max(s.col, s.out), s.col, s.out)
        end
        -- Incoming children converge into the commit column (just the trunk's `up`
        -- when the split was on its own line; the whole fan-in when inline).
        for _, inc in ipairs(incoming) do
            draw(inc.lane, math.min(inc.col, cc), math.max(inc.col, cc), inc.col, nil)
        end
        -- The first parent continues straight down at the commit column. Extra
        -- parents fan out here when inline, or are deferred to the merge line.
        if outgoing[1] then draw(outgoing[1].lane, cc, cc, nil, cc) end
        if not sep_merge then
            for i = 2, #outgoing do
                local o = outgoing[i]
                draw(o.lane, math.min(o.out, cc), math.max(o.out, cc), nil, o.out)
            end
        end
        row.tracks = assemble(cells, cc, C)

        -- Advance active past the commit line.
        active = {}
        for _, s in ipairs(survivors) do active[s.out] = s.lane end
        if outgoing[1] then active[cc] = outgoing[1].lane end
        if not sep_merge then
            for i = 2, #outgoing do active[outgoing[i].out] = outgoing[i].lane end
        end

        -- MERGE LINE (below): the first parent (trunk) continues at the commit
        -- column; the extra parents fan out from it to their columns. Survivors
        -- pass through unchanged.
        if sep_merge then
            local mcells, mdraw, madd = new_line()
            for _, s in ipairs(survivors) do mdraw(s.lane, s.out, s.out, s.out, s.out) end
            -- The single ascent out of the commit is shared by every parent (they
            -- all emanate from C above), so it carries them all; only the first
            -- parent continues straight down at the commit column.
            if outgoing[1] then
                local ascent = {}
                for _, o in ipairs(outgoing) do ascent[#ascent + 1] = o.lane end
                madd(cc, { up = true }, ascent, outgoing[1].lane.id)
                madd(cc, { down = true }, { outgoing[1].lane }, outgoing[1].lane.id)
            end
            for i = 2, #outgoing do
                local o = outgoing[i]
                mdraw(o.lane, math.min(o.out, cc), math.max(o.out, cc), nil, o.out)
            end
            row.merge = assemble(mcells, nil, nil)
            for i = 2, #outgoing do active[outgoing[i].out] = outgoing[i].lane end
        end

        rows[#rows + 1] = row
    end

    return rows
end

return M
