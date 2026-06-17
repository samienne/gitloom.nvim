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
                refs = { branches = {}, tags = {}, symbols = {}, raw = {} },
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

--- Render layout rows into a padded 2D grid of cells, in vertical display
--- order (split line above, commit line, merge line below).
---@param opts table
---@param rows table[]  -- build_graph output
---@return table[][]
function M.render_grid(opts, rows)
    local gtc = graph._internal.get_track_chars
    local lines = {}
    for _, row in ipairs(rows) do
        if row.split then lines[#lines + 1] = line_cells(gtc(opts, row.split)) end
        lines[#lines + 1] = line_cells(gtc(opts, row.tracks))
        if row.merge then lines[#lines + 1] = line_cells(gtc(opts, row.merge)) end
    end

    local w = 0
    for _, l in ipairs(lines) do w = math.max(w, #l) end
    for _, l in ipairs(lines) do
        for i = #l + 1, w do l[i] = { ch = " ", hl = nil } end
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

local NODES = { ["○"] = true, ["◉"] = true, ["◎"] = true }

----------------------------------------------------------------------
-- Invariants
----------------------------------------------------------------------

-- Faithfulness against the input: every commit laid out exactly once.
local function check_commits(rows, items)
    local errors, seen = {}, {}
    for _, row in ipairs(rows) do
        for _, t in ipairs(row.tracks) do
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
        for _, t in ipairs(row.tracks) do
            if t.has_commit then n = n + 1 end
        end
        if n ~= 1 then
            errors[#errors + 1] = ("row %d has %d commits on its line, expected 1"):format(i, n)
        end
        for _, sub in ipairs({ row.split, row.merge }) do
            for _, t in ipairs(sub or {}) do
                if t.has_commit then
                    errors[#errors + 1] = ("row %d sub-line carries a commit"):format(i)
                    break
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
        for _, lst in ipairs({ row.tracks, row.split or {}, row.merge or {} }) do
            for ti, t in ipairs(lst) do
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
        if row.split then lines[#lines + 1] = row.split end
        lines[#lines + 1] = row.tracks
        if row.merge then lines[#lines + 1] = row.merge end
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
local function check_grid(grid, opts, skip_color)
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
                    if not connected then
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

-- Exposed so a self-test can prove the checker catches broken grids.
M.check_grid = check_grid
M.check_lane_continuity = check_lane_continuity

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
