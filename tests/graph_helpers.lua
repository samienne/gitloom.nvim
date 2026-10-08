--- Test helpers for the graph layout algorithm.
---
--- Provides:
---   * dag()        — build ordered, wired commit items from a compact spec
---   * default_opts — a GraphOptions table suitable for layout + rendering
---   * check()      — run build_graph + all invariants, return a list of errors
---   * random_dag() — deterministic random closed DAG for fuzzing
---
--- The invariants are deliberately written independently of the layout
--- algorithm. Two layers:
---   1. model    — commit-once / all-present (faithfulness vs. the input)
---   2. rendered — a "wires must connect" check on the actual glyph grid:
---      no unknown glyphs, no dangling left/right or up/down stubs, crossings
---      pass the horizontal wire through a vertical bar, and color (highlight)
---      stays continuous along each wire (including across crossings).

local graph = require("gitloom.graph")

local M = {}

----------------------------------------------------------------------
-- Fixtures
----------------------------------------------------------------------

--- Build ordered commit items from a compact spec.
--- Each row is `{ hash, { parent_hash, ... } }`, in display order
--- (newest first; a commit's parents must appear after it).
---@param rows table[]
---@return table[] items  -- { { type = "commit", commit = Commit }, ... }
function M.dag(rows)
    local commits = {}
    local function get(h)
        if not commits[h] then
            commits[h] = {
                hash = h,
                parents = {},
                children = {},
                refs = {},
                author = "author",
                date = "date",
                message = h,
            }
        end
        return commits[h]
    end

    local items = {}
    for _, row in ipairs(rows) do
        local h = row[1]
        local parents = row[2] or {}
        local c = get(h)
        for _, ph in ipairs(parents) do
            local p = get(ph)
            table.insert(c.parents, p)
            table.insert(p.children, c)
        end
        items[#items + 1] = { type = "commit", commit = c }
    end
    return items
end

function M.default_opts()
    return {
        merge_style = {
            allow_merge_on_split = false,
            merge_on_separate_line = false,
            split_on_separate_line = true,
        },
        icons = {},
        palette = {
            tracks = { "Hl1", "Hl2", "Hl3", "Hl4", "Hl5", "Hl6" },
        },
    }
end

--- default_opts with the merge_style fields overridden.
---@param merge_style table?
---@return table
function M.opts(merge_style)
    local o = M.default_opts()
    if merge_style then
        o.merge_style = vim.tbl_extend("force", o.merge_style, merge_style)
    end
    return o
end

--- Like opts(), but with a large palette so a lane's color is a 1:1 proxy for
--- its id (no `id % #tracks` wraparound collisions). Use this for the
--- id-continuity invariant so a silent id change can't be masked by two ids
--- mapping to the same color.
---@param merge_style table?
---@return table
function M.big_opts(merge_style)
    local o = M.opts(merge_style)
    local p = {}
    for i = 0, 63 do p[i + 1] = "C" .. i end
    o.palette.tracks = p
    return o
end

----------------------------------------------------------------------
-- Rendering to a glyph grid
----------------------------------------------------------------------

-- Split a rendered line ({ text, highlight }) into a list of cells,
-- each { ch = <codepoint>, hl = <highlight group or nil> }.
local function line_cells(result)
    local text = result.text or ""
    local hls = result.highlight or {}
    local cells = {}
    local i, n = 1, #text
    while i <= n do
        local b = text:byte(i)
        local len = (b < 0x80) and 1 or (b < 0xE0) and 2 or (b < 0xF0) and 3 or 4
        local bytepos = i - 1
        local hl = nil
        for _, h in ipairs(hls) do
            if bytepos >= h.start_pos and bytepos < h.end_pos then
                hl = h.hl
                break
            end
        end
        cells[#cells + 1] = { ch = text:sub(i, i + len - 1), hl = hl }
        i = i + len
    end
    return cells
end

--- Every rendered line of one laid-out row, in vertical display order: the
--- virtual `above` lines (topmost first — the split fan, plus the `gutter`
--- policy's handover rows; §5 Line), then the commit line, then the merge fan.
--- Each entry is `{ name, line }` so a violation can say which line it was on.
---@param row table
---@return table[]  -- { { name = string, line = GraphColumn[] } }
function M.row_lines(row)
    local out = {}
    local above = row.above or {}
    for i, l in ipairs(above) do
        out[#out + 1] = { name = (#above > 1) and ("above %d/%d"):format(i, #above) or "above", line = l }
    end
    out[#out + 1] = { name = "columns", line = row.columns }
    if row.merge then out[#out + 1] = { name = "merge", line = row.merge } end
    return out
end

--- Render layout rows into a padded 2D grid of cells, in vertical display
--- order (the virtual lines above, commit line, merge line below).
---@param opts table
---@param rows table[]  -- build_graph output
---@return table[][]
function M.render_grid(opts, rows)
    local gtc = graph._internal.get_column_chars
    local lines = {}
    for _, row in ipairs(rows) do
        for _, ln in ipairs(M.row_lines(row)) do
            lines[#lines + 1] = line_cells(gtc(opts, ln.line))
        end
    end

    local w = 0
    for _, l in ipairs(lines) do w = math.max(w, #l) end
    for _, l in ipairs(lines) do
        if opts.mirror then
            -- Mirrored graphs are right-aligned (the listview pads the graph
            -- column on the left, see fix_width), so pad on the left here too;
            -- otherwise vertical wires would misalign across rows.
            for _ = #l + 1, w do table.insert(l, 1, { ch = " ", hl = nil }) end
        else
            for i = #l + 1, w do l[i] = { ch = " ", hl = nil } end
        end
    end
    return lines
end

function M.grid_to_string(grid)
    local out = {}
    for _, row in ipairs(grid) do
        local s = {}
        for _, cell in ipairs(row) do s[#s + 1] = cell.ch end
        out[#out + 1] = table.concat(s)
    end
    return table.concat(out, "\n")
end

----------------------------------------------------------------------
-- Glyph → edge-stub table
----------------------------------------------------------------------

local STUBS = {
    ["│"] = { u = true, d = true },
    ["─"] = { l = true, r = true },
    ["├"] = { u = true, d = true, r = true },
    ["┤"] = { u = true, d = true, l = true },
    ["┼"] = { u = true, d = true, l = true, r = true },
    ["┬"] = { l = true, r = true, d = true },
    ["┴"] = { l = true, r = true, u = true },
    ["╭"] = { d = true, r = true },
    ["╮"] = { d = true, l = true },
    ["╰"] = { u = true, r = true },
    ["╯"] = { u = true, l = true },
    ["╴"] = { l = true },
    ["╶"] = { r = true },
    ["╵"] = { u = true },
    ["╷"] = { d = true },
    ["^"] = { u = true },
    [" "] = {},
}

-- Every commit marker glyph (spec §5.3). `◌` (a working-tree virtual commit,
-- §4.2) was missing: no earlier test fed a virtual commit through the checker, so
-- it read as an unknown glyph. Listing it lets any policy's layout be validated on
-- a graph that includes the working-tree nodes.
local NODES = { ["○"] = true, ["◉"] = true, ["◎"] = true, ["◍"] = true, ["◌"] = true, ["●"] = true }

----------------------------------------------------------------------
-- Invariants
----------------------------------------------------------------------

-- Faithfulness against the input: every commit laid out exactly once.
local function check_commits(rows, items)
    local errors, seen = {}, {}
    for _, row in ipairs(rows) do
        for _, t in ipairs(row.columns) do
            if t.has_commit and t.commit then
                if seen[t.commit.hash] then
                    errors[#errors + 1] = "commit appears twice: " .. t.commit.hash
                end
                seen[t.commit.hash] = true
            end
        end
    end
    for _, it in ipairs(items) do
        if not seen[it.commit.hash] then
            errors[#errors + 1] = "commit missing from layout: " .. it.commit.hash
        end
    end
    return errors
end

-- Exactly one commit per commit row (the row carries that commit's message),
-- and none on the split/merge virtual sub-lines.
local function check_one_commit_per_line(rows)
    local errors = {}
    for i, row in ipairs(rows) do
        local n = 0
        for _, t in ipairs(row.columns) do
            if t.has_commit then n = n + 1 end
        end
        if n ~= 1 then
            errors[#errors + 1] = ("row %d has %d commits on its line, expected 1"):format(i, n)
        end
        for _, ln in ipairs(M.row_lines(row)) do
            if ln.name ~= "columns" then
                for _, t in ipairs(ln.line or {}) do
                    if t.has_commit then
                        errors[#errors + 1] = ("row %d %s carries a commit"):format(i, ln.name)
                        break
                    end
                end
            end
        end
    end
    return errors
end

local SIDES = { "up", "down", "left", "right" }

local function count_sides(conn)
    local n = 0
    for _, k in ipairs(SIDES) do
        if conn[k] then n = n + 1 end
    end
    return n
end

-- Lane-model invariants (specification.md §5) on the decomposed `track.lanes`:
--   * connectivity consistency — the union of a cell's lanes' sides equals the
--     cell's connectivity.
--   * two-sided lanes — each lane is a wire with exactly two sides; one side
--     only at an endpoint (a commit, or a branch within a junction cell).
local function check_lanes(rows)
    local errors = {}
    local function err(m) errors[#errors + 1] = m end
    for ri, row in ipairs(rows) do
        for _, ln in ipairs(M.row_lines(row)) do
            for ti, t in ipairs(ln.line) do
                local lanes = t.lanes or {}

                local union = {}
                for _, lane in ipairs(lanes) do
                    for _, k in ipairs(SIDES) do
                        if lane.connectivity[k] then union[k] = true end
                    end
                end
                for _, k in ipairs(SIDES) do
                    if (t.connectivity[k] and true or false) ~= (union[k] and true or false) then
                        err(("row %d track %d: lane union mismatches connectivity at %s"):format(ri, ti, k))
                    end
                end

                for li, lane in ipairs(lanes) do
                    local n = count_sides(lane.connectivity)
                    if n > 2 then
                        err(("row %d track %d lane %d: %d sides (>2)"):format(ri, ti, li, n))
                    elseif n < 2 and not (t.has_commit or #lanes > 1) then
                        err(("row %d track %d lane %d: %d-sided but not an endpoint"):format(ri, ti, li, n))
                    end
                    -- leads somewhere: a lane heading down must have a parent
                    if lane.connectivity.down and not lane.parent then
                        err(("row %d track %d lane %d: down lane has no parent"):format(ri, ti, li))
                    end
                end
            end
        end
    end
    return errors
end

local function down_lane_id(t)
    for _, lane in ipairs(t.lanes or {}) do
        if lane.connectivity.down then return lane.id end
    end
end

local function up_lane_id(t)
    for _, lane in ipairs(t.lanes or {}) do
        if lane.connectivity.up then return lane.id end
    end
end

-- Per-lane vertical continuity on the lane *model* (not the rendered color).
-- Where a cell connects up, its up-lane's id must equal the id of the
-- down-lane in the cell directly above (same column). This is what the
-- handoff split buys: a conflated single vertical lane (up id != down id)
-- would fail here, whereas modeling the up and down segments as separate
-- lanes makes every lane continuous regardless of how it's colored.
local function check_lane_continuity(rows)
    local lines = {}
    for _, row in ipairs(rows) do
        for _, ln in ipairs(M.row_lines(row)) do lines[#lines + 1] = ln.line end
    end

    local errors = {}
    for li = 1, #lines - 1 do
        local upper, lower = lines[li], lines[li + 1]
        for i, t in ipairs(lower) do
            if t.connectivity.up and upper[i] and upper[i].connectivity.down then
                local a, b = up_lane_id(t), down_lane_id(upper[i])
                if a ~= b then
                    errors[#errors + 1] = ("line %d col %d: up-lane id %s != above down-lane id %s")
                        :format(li + 1, i, tostring(a), tostring(b))
                end
            end
        end
    end
    return errors
end

-- "Wires must connect" check on the rendered glyph grid.
-- With `skip_color`, the color-continuity checks (steps 6–7) are omitted —
-- used for styles where lane color is intentionally allowed to change (e.g.
-- the lane handoff at a merge under allow_merge_on_split).
-- `allow_floating_heads`: a collapsed `◍` head with no wires is allowed (the context
-- header draws a DISCONNECTED pinned anchor as a lone labelled head; §6.2).
local function check_grid(grid, opts, skip_color, allow_floating_heads)
    local errors = {}
    local function err(msg) errors[#errors + 1] = msg end

    local node_chars = {}
    for k in pairs(NODES) do node_chars[k] = true end
    if opts.icons and opts.icons.merge then node_chars[opts.icons.merge] = true end

    local rows = #grid
    local cols = rows > 0 and #grid[1] or 0
    local function cell(r, c)
        if r < 1 or r > rows or c < 1 or c > cols then return nil end
        return grid[r][c]
    end

    -- 1. classify cells
    for r = 1, rows do
        for c = 1, cols do
            local cl = grid[r][c]
            cl.node = node_chars[cl.ch] or false
            cl.stub = STUBS[cl.ch]
            if not cl.node and not cl.stub then
                err(("unknown glyph %q at row %d col %d"):format(cl.ch, r, c))
                cl.stub = {}
            end
            cl.stub = cl.stub or {}
        end
    end

    -- 2. crossings: a bare "│" with horizontal stubs on both sides carries a
    --    horizontal wire through it; augment so the wire passes.
    for r = 1, rows do
        for c = 1, cols do
            local cl = grid[r][c]
            if cl.ch == "│" then
                local L, R = cell(r, c - 1), cell(r, c + 1)
                if L and R and L.stub.r and R.stub.l then
                    cl.crossing = true
                    cl.stub = { u = true, d = true, l = true, r = true }
                end
            end
        end
    end

    local function wants(cl, dir) return cl.stub[dir] and not cl.node end
    local function accepts(cl, dir) return cl.stub[dir] or cl.node end

    -- 3. horizontal agreement
    for r = 1, rows do
        for c = 1, cols - 1 do
            local A, B = grid[r][c], grid[r][c + 1]
            if wants(A, "r") and not accepts(B, "l") then
                err(("dangling right at row %d col %d (%q→)"):format(r, c, A.ch))
            end
            if wants(B, "l") and not accepts(A, "r") then
                err(("dangling left at row %d col %d (→%q)"):format(r, c + 1, B.ch))
            end
        end
    end

    -- 4. vertical agreement
    for r = 1, rows - 1 do
        for c = 1, cols do
            local A, B = grid[r][c], grid[r + 1][c]
            if wants(A, "d") and not accepts(B, "u") then
                err(("dangling down at row %d col %d (%q)"):format(r, c, A.ch))
            end
            if wants(B, "u") and not accepts(A, "d") then
                err(("dangling up at row %d col %d (%q)"):format(r + 1, c, B.ch))
            end
        end
    end

    -- 5. no floating node (unless the graph is a single commit)
    local node_count = 0
    for r = 1, rows do
        for c = 1, cols do
            if grid[r][c].node then node_count = node_count + 1 end
        end
    end
    if node_count > 1 then
        for r = 1, rows do
            for c = 1, cols do
                local cl = grid[r][c]
                if cl.node then
                    local up, down = cell(r - 1, c), cell(r + 1, c)
                    local left, right = cell(r, c - 1), cell(r, c + 1)
                    -- Consecutive commits on a lane stack directly (no "│"
                    -- between them), so an adjacent node up/down is a valid
                    -- lane connection.
                    local connected = (up and (up.stub.d or up.node))
                        or (down and (down.stub.u or down.node))
                        or (left and left.stub.r) or (right and right.stub.l)
                    if not connected and not (allow_floating_heads and cl.ch == "◍") then
                        err(("floating node %q at row %d col %d"):format(cl.ch, r, c))
                    end
                end
            end
        end
    end

    if skip_color then return errors end

    -- 6. vertical color continuity along a straight lane. Restricted to
    --    "│"↔"│" (incl. crossings, which keep ch == "│"): a straight vertical
    --    run is unambiguously one lane, so its color must not change. Junction
    --    glyphs (tees/turns) are lane boundaries where color legitimately
    --    changes, so they are deliberately excluded.
    for r = 1, rows - 1 do
        for c = 1, cols do
            local A, B = grid[r][c], grid[r + 1][c]
            if A.ch == "│" and B.ch == "│" and A.hl and B.hl and A.hl ~= B.hl then
                err(("vertical color break at row %d col %d (%s→%s)"):format(r, c, A.hl, B.hl))
            end
        end
    end

    -- 7. horizontal color continuity across a crossing: the horizontal wire's
    --    id (color) must stay the same as it skips over the vertical bar.
    for r = 1, rows do
        for c = 1, cols do
            if grid[r][c].crossing then
                local L, R = cell(r, c - 1), cell(r, c + 1)
                if L and R and L.hl and R.hl and L.hl ~= R.hl then
                    err(("horizontal color changes across crossing at row %d col %d (%s|%s)")
                        :format(r, c, L.hl, R.hl))
                end
            end
        end
    end

    return errors
end

----------------------------------------------------------------------
-- Horizontal sharing (spec §5.1)
----------------------------------------------------------------------

-- A horizontal run belongs to ONE Lane — one edge child -> parent — and has a
-- DIRECTION: the way that wire travels along the Line, following the graph's own
-- top-to-bottom flow.
--
--   entry column = where the lane has `up` (it arrived from the Line above); if it
--                  has no `up` it is emanating from the commit/hub on this Line, so
--                  the entry is the far end of its run.
--   exit column  = where the lane has `down` (it continues below); if it has no
--                  `down` it terminates at the commit/hub, so the exit is the far end.
--   direction    = sign(exit - entry).
--
-- Direction is defined on the LANE's travel rather than, say, which side of the
-- node the wire is on, because what a reader follows is the edge — child down to
-- parent. Two wires crossing the same cells in opposite directions are exactly
-- what makes a run unreadable: the eye cannot tell which wire it is on, and the
-- cell renders one glyph and one colour for both.
--
-- THE RULE (§5.1): two horizontal runs may share a cell only when both belong to
-- the SAME fan of the commit on that Line — both converging children, or both
-- diverging parents. A run of one fan sharing with a run of the other, or with a
-- lane that is not incident to this commit at all, is an error. Reported with the
-- directions so a mixed-direction share (the visible defect) is distinguishable
-- from a same-direction one.
---@param line table   -- GraphColumn[]
---@return table       -- edge -> { lo, hi, from, to, dir, id }
local function horizontal_runs(line)
    local runs, order = {}, {}
    for j, cell in ipairs(line or {}) do
        for _, sg in ipairs(cell.lanes or {}) do
            local c = sg.connectivity
            for _, e in ipairs(sg.edges or {}) do
                local r = runs[e]
                if not r then
                    r = { lo = j, hi = j, id = sg.id }
                    runs[e] = r
                    order[#order + 1] = e
                end
                if j < r.lo then r.lo = j end
                if j > r.hi then r.hi = j end
                if c.up then r.up = j end
                if c.down then r.down = j end
                if c.left or c.right then r.h = true end
            end
        end
    end
    local out = {}
    for _, e in ipairs(order) do
        local r = runs[e]
        if r.h then
            local from, to
            if r.up and r.down then
                from, to = r.up, r.down
            elseif r.up then
                from = r.up
                to = (r.up == r.lo) and r.hi or r.lo
            elseif r.down then
                to = r.down
                from = (r.down == r.lo) and r.hi or r.lo
            else
                from, to = r.lo, r.hi -- defensive: a run with neither endpoint
            end
            r.from, r.to = from, to
            r.dir = (to > from) and 1 or ((to < from) and -1 or 0)
            out[#out + 1] = { edge = e, r = r }
        end
    end
    return out
end
M.horizontal_runs = horizontal_runs

--- Check §5.1 horizontal sharing over a laid-out row list.
--- `rows` are OrderItems ({ columns, split?, merge?, child_lanes, parent_lanes }).
---@param rows table[]
---@return string[] errors
local function check_horizontals(rows)
    local errors = {}
    for ri, row in ipairs(rows) do
        local inset, outset = {}, {}
        for _, l in ipairs(row.child_lanes or {}) do inset[l] = true end
        for _, l in ipairs(row.parent_lanes or {}) do outset[l] = true end
        for _, ln in ipairs(M.row_lines(row)) do
            if ln.line then
                local runs = horizontal_runs(ln.line)
                for a = 1, #runs do
                    for b = a + 1, #runs do
                        local A, B = runs[a], runs[b]
                        local overlap = math.max(A.r.lo, B.r.lo) <= math.min(A.r.hi, B.r.hi)
                        if overlap then
                            local same_fan = (inset[A.edge] and inset[B.edge])
                                or (outset[A.edge] and outset[B.edge])
                            if not same_fan then
                                local mixed = A.r.dir ~= B.r.dir
                                local function side(e)
                                    return inset[e] and "in" or (outset[e] and "out" or "OUTSIDE")
                                end
                                errors[#errors + 1] = ("row %d %s: %s horizontal share — lane %s [%d->%d, %s] and lane %s [%d->%d, %s] overlap cols %d..%d")
                                    :format(ri, ln.name,
                                        mixed and "MIXED-DIRECTION" or "cross-fan",
                                        tostring(A.r.id), A.r.from, A.r.to, side(A.edge),
                                        tostring(B.r.id), B.r.from, B.r.to, side(B.edge),
                                        math.max(A.r.lo, B.r.lo), math.min(A.r.hi, B.r.hi))
                            end
                        end
                    end
                end
            end
        end
    end
    return errors
end

----------------------------------------------------------------------
-- The spine through a node (spec §5, §5.6)
----------------------------------------------------------------------

-- A commit's node sits in ITS OWN lane's column — the column of the incoming Lane
-- its first parent continues (§5: "places each node in its own Lane's column"; §5.6
-- for the gutter: "the wire above the node and the wire below it are one Lane, one
-- id, one colour"). Observably: at the node's cell, the Segment arriving from above
-- and the Segment leaving below carry the SAME lane id.
--
-- Put the node on some *other* converging child's column and the cell's wire from
-- above belongs to a lane that ENDS here while its wire below belongs to the
-- continuing one, so a straight vertical changes colour mid-column — and the split
-- hub above it is drawn in the ending branch's colour instead of the spine's. That
-- is precisely what a reader mis-reads as "the fork is on the topic branch".
--
-- Not part of `M.check`: the four lane-column policies place a node on the LEFTMOST
-- incoming lane, a positional stand-in for its own lane that is right on a real
-- history but not always (see `place_commit`), so they carry a small residue —
-- ~5% of random DAGs, 1–2 rows per real repository. `gutter` fixes the node column
-- outright and holds this exactly, which is why it is asserted there.
--
-- TWO LICENSED EXCEPTIONS, ONE PER FAN (§5.6 gutter parent swap / split swap). `gutter`
-- may deliberately break the spine to avoid a handover, and this checker PRICES each
-- break rather than exempting the policy: a break must be shown, from the rendered rows
-- alone, to have removed two handover rows.
--
-- Both licences share L1:
--
--   L1. the break is in the GUTTER column (column 1) — the only column the policy
--       constrains.
--
-- THE MERGE SWAP (at a merge, a NON-FIRST parent takes the gutter so the branch owning
-- the next subject row is already in place):
--
--   L2. the wire leaving below is one of this commit's **non-first** parent Lanes, and
--       the wire arriving above is its **first** parent's Lane. (The first parent
--       continues the arriving Lane's identity, §5, so the up wire's id IS
--       `parent_lanes[1]`'s. Anything else is a mis-placed node, not a swap.)
--   L3. THE LICENCE IS EARNED: at the **next subject-owning row**, the node sits in
--       the gutter and the wire arriving there is that very Lane. That is observably
--       "the handover was saved" — had the swapped Lane been evicted after all, a
--       different Lane would be arriving at that node, and the row would have paid the
--       eviction and claim rows anyway on top of the break.
--
-- THE SPLIT SWAP (at a fork, the node takes the gutter from a converging child that is
-- already in it, instead of evicting the child and claiming the column back):
--
--   L2'. the wire leaving below is this commit's **first** parent's Lane (the spine is
--        intact below the node — the swap touched the other side), and the wire arriving
--        above is one of its **converging child** Lanes that the first parent does NOT
--        continue. §5 makes that test exact without knowing anything about the layout:
--        the first parent inherits the id of the child lane it continues, so "a
--        `child_lanes` entry whose id is not `parent_lanes[1]`'s" IS "a converging child
--        that is not the continuation".
--   L3'. THE LICENCE IS EARNED: this row emitted **no handover Line** — no eviction and
--        no claim row above it. A handover row plus this break is a row that paid the
--        two rows anyway, so the break bought nothing. (Reading `above` for it is the
--        same discipline as the rest: a split fan always carries the shared multi-edge
--        descent, §5; an eviction or claim row never does.)
--
-- Note the asymmetry: the merge swap's earning is on the NEXT row (it hands the gutter
-- forward), the split swap's is on ITS OWN row (it declines to hand the gutter back).
-- Neither licence lets the other's shape through: a merge swap has a non-first parent
-- below, a split swap the first parent below, and a cell with a foreign child above AND a
-- non-first parent below — the commit's own Lane on neither side — matches neither and is
-- reported.
--
-- WHAT L2' DOES NOT SEPARATE, stated because it bounds the claim: the four lane-column
-- policies place a node on the LEFTMOST arriving lane, which where that is not the
-- commit's own lane produces a break of exactly the L2' shape (foreign child above, first
-- parent below). Only the *policy* knows that column 1 is a gutter, so a checker reading
-- the rendered rows cannot tell the two apart — which is why `check_spine` is asserted for
-- `gutter` only, as it was before this licence existed. It is not a new exemption: the
-- four policies were never asserted.
--
-- Returns the errors, the number of LICENSED breaks (so a test can prove the gate fires
-- rather than passing vacuously), and a per-kind breakdown.
---@param rows table[]
---@param opts table?  -- needed to classify subject rows (§5.6); defaults to markers on
---@return string[] errors, integer licensed, table kinds  -- { merge = n, split = n }
local function check_spine(rows, opts)
    local errors = {}
    local o = opts or {}
    -- Which rows own a subject (§5.6): a collapsed head and a junction drawn as a
    -- marker do not, so they are not where the gutter changes hands.
    local subject, node, handover = {}, {}, {}
    for ri, row in ipairs(rows) do
        local C = row.commit
        subject[ri] = C ~= nil and not C.collapsed
            and not (C.junction and o.junction_markers ~= false)
        for j, cell in ipairs(row.columns or {}) do
            if cell.has_commit then
                local e = { col = j }
                for _, s in ipairs(cell.lanes or {}) do
                    if s.connectivity.up and not e.u then e.u = s.id end
                    if s.connectivity.down and not e.d then e.d = s.id end
                end
                node[ri] = e
            end
        end
        -- A HANDOVER Line above this row: a virtual Line with no shared multi-edge
        -- descent, i.e. an eviction or claim row rather than the split fan (§5/§5.6).
        for _, line in ipairs(row.above or {}) do
            local multi = false
            for _, cell in ipairs(line) do
                for _, s in ipairs(cell.lanes or {}) do
                    if #(s.edges or {}) > 1 then multi = true end
                end
            end
            if not multi then handover[ri] = true end
        end
    end

    local licensed, kinds = 0, { merge = 0, split = 0 }
    for ri, row in ipairs(rows) do
        local e = node[ri]
        if e and e.u and e.d and e.u ~= e.d then
            local why, kind
            local pl, cl = row.parent_lanes or {}, row.child_lanes or {}
            local first = pl[1] and pl[1].id
            local swapped -- is `d` a non-first parent lane? (the merge swap's shape)
            for i = 2, #pl do
                if pl[i].id == e.d then swapped = pl[i] end
            end
            local foreign -- is `u` a converging child the first parent does not continue?
            for _, l in ipairs(cl) do
                if l.id == e.u and l.id ~= first then foreign = l end
            end
            if e.col ~= 1 then
                why = "not in the gutter column"
            elseif swapped then
                kind = "merge"
                if first ~= e.u then
                    why = "the wire above is not the first parent's lane"
                else
                    local n
                    for k = ri + 1, #rows do
                        if subject[k] then n = k break end
                    end
                    if not n then
                        why = "no subject row follows, so no handover could be saved"
                    elseif not node[n] or node[n].col ~= 1 then
                        why = ("the next subject row (%d) does not put its node in the gutter"):format(n)
                    elseif node[n].u ~= e.d then
                        why = ("the swap SAVED NOTHING: the next subject row (%d) is entered by lane %s, not %s")
                            :format(n, tostring(node[n].u), tostring(e.d))
                    end
                end
            elseif foreign and first == e.d then
                kind = "split"
                if handover[ri] then
                    why = "the split swap SAVED NOTHING: this row paid a handover Line anyway"
                end
            else
                why = "neither swap: the wire below is not a non-first parent lane, and the"
                    .. " wire above is not a converging child the first parent does not continue"
            end
            if why then
                errors[#errors + 1] = ("row %d col %d (%s): unlicensed node spine change %s -> %s — %s")
                    :format(ri, e.col, tostring(row.commit and row.commit.hash),
                        tostring(e.u), tostring(e.d), why)
            else
                licensed = licensed + 1
                kinds[kind] = kinds[kind] + 1
            end
        end
    end
    return errors, licensed, kinds
end

-- Exposed so a self-test can prove the checker catches broken grids.
M.check_grid = check_grid
M.check_lane_continuity = check_lane_continuity
M.check_horizontals = check_horizontals
M.check_spine = check_spine

--- Build the layout for `items` and run every invariant.
--- Returns a flat list of error strings (empty = all good).
--- With `skip_color`, color-continuity invariants are not asserted.
---@param opts table
---@param items table[]
---@param skip_color boolean?
---@return string[] errors, table[] rows, table[][] grid
function M.check(opts, items, skip_color)
    local rows = graph._internal.build_graph(opts, items)
    local grid = M.render_grid(opts, rows)

    local errors = {}
    for _, e in ipairs(check_commits(rows, items)) do errors[#errors + 1] = e end
    for _, e in ipairs(check_one_commit_per_line(rows)) do errors[#errors + 1] = e end
    for _, e in ipairs(check_lanes(rows)) do errors[#errors + 1] = e end
    for _, e in ipairs(check_lane_continuity(rows)) do errors[#errors + 1] = e end
    for _, e in ipairs(check_grid(grid, opts, skip_color)) do errors[#errors + 1] = e end
    -- HORIZONTAL SHARING (§5.1): two runs may share cells only as arms of the same
    -- fan of the commit on that Line. Asserted for every layout policy on every
    -- merge style that gives at least one fan its own Line.
    --
    -- **Not** on the two fully-inline styles (`inline`, and `allow_merge_on_split`),
    -- where a commit's fan-in and fan-out share its commit Line by construction: the
    -- rule fires there under EVERY policy — `compact` as much as `gutter` — so it is
    -- a pre-existing property of drawing both fans on one Line, not of any policy,
    -- and fixing it is a separate decision (deliberately deferred). The gate is on
    -- the merge STYLE alone; no policy, corpus or fixture is exempt.
    local ms = opts.merge_style or {}
    if ms.split_on_separate_line or ms.merge_on_separate_line then
        for _, e in ipairs(check_horizontals(rows)) do errors[#errors + 1] = e end
    end
    return errors, rows, grid
end

--- A compact, deterministic characterization of the rendered graph: each line
--- is "<glyphs>  <colors>" (trailing blank cells trimmed), where colors are
--- the lane-color index per cell (`.` = none). Used to lock current behavior
--- of experimental styles so any change is flagged for review.
---@param opts table
---@param items table[]
---@return string
function M.snapshot(opts, items)
    local rows = graph._internal.build_graph(opts, items)
    local grid = M.render_grid(opts, rows)
    local hlcode = {}
    for i = 1, 9 do hlcode["Hl" .. i] = tostring(i) end

    local lines = {}
    for _, row in ipairs(grid) do
        local last = 0
        for c = 1, #row do
            if row[c].ch ~= " " then last = c end
        end
        local g, col = {}, {}
        for c = 1, last do
            g[#g + 1] = row[c].ch
            col[#col + 1] = row[c].hl and hlcode[row[c].hl] or "."
        end
        lines[#lines + 1] = table.concat(g) .. "  " .. table.concat(col)
    end
    return table.concat(lines, "\n")
end

----------------------------------------------------------------------
-- Fuzzing
----------------------------------------------------------------------

-- Deterministic LCG (Park–Miller) so failures reproduce by seed.
local function make_rng(seed)
    local s = seed % 2147483647
    if s <= 0 then s = s + 2147483646 end
    return function()
        s = (s * 16807) % 2147483647
        return s / 2147483647
    end
end

--- Project `items` the way an opened graph does (§10.7 first-parent focus): every
--- childless commit is a ref tip, the first of them is the pinned anchor, and
--- `collapse_merged` is on — so the result holds `◍` collapsed heads and kept
--- **junctions** as well as ordinary commits.
---
--- Why the layout matrix needs it: a raw `dag()` is all ordinary commits, and
--- `owns_subject` (§5.6) is false only for a collapsed head or a junction marker.
--- Every "non-subject row" branch in `columns.lua` — the whole reason the `gutter`
--- policy has one — is therefore UNREACHABLE on a raw DAG, however much it is
--- fuzzed. Feeding the same DAGs through the projection is what exercises them.
---@param items table[]  -- dag() output
---@return table[] display  -- projected display items, ready for columns.layout
function M.focused(items)
    local view = require("gitloom.graph.view")
    local ro, pinned = {}, {}
    for i, it in ipairs(items) do
        if #(it.commit.children or {}) == 0 then
            local id = "t" .. i
            it.commit.refs = it.commit.refs or {}
            it.commit.refs[#it.commit.refs + 1] = { name = id, kind = "local" }
            ro[#ro + 1] = { id = id, tip = it.commit, mode = "normal" }
            if #ro == 1 then pinned[id] = true end
        end
    end
    return view.project(items, view.owners(items, ro, pinned, {}, true), nil).items
end

--- A rendered Line's full cell content, as a comparable string: every column's
--- connectivity, lane id, palette slot, node flag and `own_lane_up`, plus every
--- Segment's id, colour, connectivity and endpoints. Cell-for-cell equality of
--- two layouts is equality of these.
---@param line table?
---@return string
function M.line_sig(line)
    if not line then return "-" end
    local out = {}
    for j, col in ipairs(line) do
        local c = col.connectivity or {}
        local segs = {}
        for _, sg in ipairs(col.lanes or {}) do
            local sc = sg.connectivity or {}
            segs[#segs + 1] = ("%s:%s:%s%s%s%s:%s>%s"):format(tostring(sg.id), tostring(sg.color),
                sc.up and "u" or "", sc.down and "d" or "", sc.left and "l" or "", sc.right and "r" or "",
                sg.begin and tostring(sg.begin.hash) or "-",
                sg.parent and tostring(sg.parent.hash) or "-")
        end
        out[#out + 1] = ("%d[%s%s%s%s|%s|%s|%s|%s]{%s}"):format(j,
            c.up and "u" or "", c.down and "d" or "", c.left and "l" or "", c.right and "r" or "",
            tostring(col.id), tostring(col.color), col.has_commit and "N" or "",
            col.own_lane_up and "^" or "", table.concat(segs, ","))
    end
    return table.concat(out, " ")
end

--- Every Line of one laid-out row, plus the lanes the reachability walk reads.
---@param r table  -- OrderItem
---@return string
function M.row_sig(r)
    local parts = {}
    for _, a in ipairs(r.above or {}) do parts[#parts + 1] = "A" .. M.line_sig(a) end
    parts[#parts + 1] = "C" .. M.line_sig(r.columns)
    if r.merge then parts[#parts + 1] = "M" .. M.line_sig(r.merge) end
    local pl, cl = {}, {}
    for _, l in ipairs(r.parent_lanes or {}) do pl[#pl + 1] = tostring(l.id) end
    for _, l in ipairs(r.child_lanes or {}) do cl[#cl + 1] = tostring(l.id) end
    parts[#parts + 1] = "P" .. table.concat(pl, ",") .. "/K" .. table.concat(cl, ",")
    return table.concat(parts, "\n")
end

--- The **reference** signature pass (spec §10.2), as one materialised
--- `table<string, boolean>` per commit — the shape `view.signatures` produced
--- before it was interned (gitloom.graph.sigset). Kept as an independent oracle:
--- it is a direct transcription of the definition (a commit's signature is the
--- owners tipped at it unioned with every child's, an `fp_only` owner crossing
--- only a first-parent edge), with no sharing, no memoisation and no trie.
---
--- `view.project` takes its slower path for a plain table like this, so feeding
--- one in exercises the pre-interning projection too — which is what makes a
--- comparison against it a genuine before/after, not a self-check.
---@param items table[]  -- { type, commit }, newest-first
---@param owners table[] -- { id, tip, mode?, fp_only? }
---@return table<string, table<string, boolean>>
function M.reference_signatures(items, owners)
    local tips, fp = {}, {}
    for _, o in ipairs(owners) do
        local h = o.tip.hash
        tips[h] = tips[h] or {}
        tips[h][#tips[h] + 1] = o.id
        if o.fp_only then fp[o.id] = true end
    end
    local sig = {}
    for _, it in ipairs(items) do
        local c = it.commit
        local s = {}
        for _, oid in ipairs(tips[c.hash] or {}) do s[oid] = true end
        for _, ch in ipairs(c.children or {}) do
            local cs = sig[ch.hash]
            if cs then
                local first = ch.parents and ch.parents[1] == c
                for oid in pairs(cs) do
                    if first or not fp[oid] then s[oid] = true end
                end
            end
        end
        sig[c.hash] = s
    end
    return sig
end

--- A random closed DAG of `n` commits in topo order: every non-last commit
--- has 1–2 parents drawn from later commits; the last commit is a root.
---@param n integer
---@param seed integer
---@return table[] rows  -- dag()-compatible spec
function M.random_dag(n, seed)
    local rng = make_rng(seed)
    local rows = {}
    for i = 1, n do
        local parents = {}
        if i < n then
            local p1 = i + 1 + math.floor(rng() * (n - i))
            if p1 > n then p1 = n end
            parents[1] = "c" .. p1
            if rng() < 0.30 then
                local p2 = i + 1 + math.floor(rng() * (n - i))
                if p2 > n then p2 = n end
                if p2 ~= p1 then parents[#parents + 1] = "c" .. p2 end
            end
        end
        rows[i] = { "c" .. i, parents }
    end
    return rows
end

return M
