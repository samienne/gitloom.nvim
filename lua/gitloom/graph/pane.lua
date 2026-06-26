--- Context panes (spec §6.2): the pure layout core for the header/footer windows
--- that summarise off-screen topology folded onto the pinned anchors (§10.6).
---
--- Both panes are **focused rebuilds** — they reconstruct a small sub-DAG of just
--- the lanes crossing the cutoff (plus the pinned anchors), never the whole graph:
---   * **Footer** (`continue` → `condense` → `footer`): continues each boundary
---     lane **down** its first-parent chain to a root, condenses, and lays it out
---     with `columns.layout` seeded at the **seam** so the two meet without a jog.
---   * **Header** (`continue_up` → `condense(up)` → `header`): continues each
---     boundary lane **up** (the mirror) to where it merges into a pinned anchor (a
---     node-less junction) or ends at its own `◍` head; pinned anchors are drawn as
---     labelled spines. It is laid out by a bespoke **bottom-up grid builder**
---     (`header`) that starts from the boundary (so the seam matches by
---     construction) and walks up — no `columns.layout`, no transpose.
---
--- This module is git-agnostic and window-agnostic — it consumes already-projected
--- OrderItems and a boundary map and returns rows, so it is unit-testable without
--- snacks. Window placement, sizing, and the async rebuild live in graph.lua.
local M = {}

local columns = require("gitloom.graph.columns")

-- Chunking support for the async pane build (window.lua): `continue`/`continue_up`/
-- `condense` walk a commit's first-parent chain to a root/tip, which is O(history
-- depth) and can be large. When the caller passes a `yield` function, these
-- helpers call it once per `YIELD_EVERY` units of work so a coroutine driver can
-- suspend the walk between event-loop ticks (and cancel it if the view moves).
-- Pure/synchronous callers (the unit tests) pass no `yield`, so behaviour is
-- unchanged. `yield` is only ever called from loop *bodies*, never across a
-- C-call boundary (e.g. a `table.sort` comparator), so it is safe under LuaJIT
-- coroutines.
local YIELD_EVERY = 2048
--- A monotonic work counter that calls `yield` every `YIELD_EVERY` steps.
---@param yield (fun())?
---@return fun()  -- call once per unit of work
local function chunker(yield)
    local n = 0
    return function()
        if not yield then return end
        n = n + 1
        if n % YIELD_EVERY == 0 then yield() end
    end
end

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
--- hashes; a spliced node maps to the next kept node toward the kept end (the
--- **root** down, the **tip** up), so a seam lane running through the run
--- terminates at the right node.
--- `anchor_names` (optional): only refs whose name is in this set count as
--- markers — non-anchor refs (tags, unpinned branches) on intermediate commits
--- are ignored, so a run carrying only those still splices away. When omitted,
--- any ref keeps a node.
---
--- `up` flips the kept ends for the **header**: a footer condenses toward the
--- **root** (keep roots, splice bare tips); a header condenses toward the **tip**
--- (keep tips, splice the bare seam-adjacent nodes whose real parent is below the
--- seam). So `transparent` and the `node_of` follow-direction swap.
---@param nodes table[]  -- DisplayNodes, newest-first
---@param anchor_names table<string, boolean>?  -- ref names that count as markers
---@param up boolean?  -- header orientation (keep tips, splice seam pass-throughs)
---@param yield (fun())?  -- chunking hook; called every YIELD_EVERY units of work
---@return table  -- { items = OrderItem[], node_of_hash = table<string, table> }
function M.condense(nodes, anchor_names, up, yield)
    local step = chunker(yield)
    -- Refs on a node that count as markers (anchor refs, or all when unfiltered). The
    -- HEAD marker (kind == "head") is ALWAYS kept: the pinned set is keyed by the BRANCH
    -- name HEAD points at (repo.head), not "HEAD", so filtering by anchor_names alone
    -- would drop HEAD and leave only the branch sharing its commit — the header must show
    -- HEAD, not just that branch.
    local function marker_refs(n)
        if not anchor_names then return n.refs or {} end
        local out = {}
        for _, r in ipairs(n.refs or {}) do
            if (r.name and anchor_names[r.name]) or r.kind == "head" then out[#out + 1] = r end
        end
        return out
    end
    -- TRANSPARENT (spliced) nodes, by **fixpoint**. A node with no anchor marker
    -- splices when — counting only the DISTINCT SURVIVING nodes it connects to (skipping
    -- other spliced runs) — it is a pure pass-through: not a kept **endpoint** (the
    -- header keeps a tip with no child; the footer keeps a root with no parent) and not
    -- a true fork/merge (≥2 distinct survivors on a side). Splicing one node can make a
    -- **reconverging** neighbour linear too — a diamond with a linear side (a fork whose
    -- two branches immediately rejoin) leaves a "false junction" of effective degree 1 —
    -- so iterate until stable. Otherwise that node is kept but renders as a contentless
    -- all-vertical row. (Original-degree splicing missed this — it never cascaded.)
    local transp = {}
    -- The distinct **terminals** reached from `n` along `field`, following spliced runs:
    -- the first surviving node on each path, or — if a path dead-ends among spliced
    -- nodes (a lane heading off to the seam) — that dead-end node. Counting terminals
    -- (not just surviving nodes) is what distinguishes a real merge of two distinct seam
    -- lanes (2 terminals → a junction) from a **bubble** whose two sides reconverge to
    -- the same node (1 terminal → splice it away).
    local function reach(n, field)
        local seen, out, walked = {}, {}, {}
        local function walk(m)
            if walked[m] then return end
            walked[m] = true
            local nbrs = m[field] or {}
            if #nbrs == 0 then -- dead end among spliced nodes: m is the terminal
                if not seen[m] then seen[m] = true; out[#out + 1] = m end
                return
            end
            for _, x in ipairs(nbrs) do
                if transp[x] then walk(x)
                elseif not seen[x] then seen[x] = true; out[#out + 1] = x end
            end
        end
        for _, x in ipairs(n[field] or {}) do
            if transp[x] then walk(x)
            elseif not seen[x] then seen[x] = true; out[#out + 1] = x end
        end
        return out
    end
    local changed = true
    while changed do
        changed = false
        for _, n in ipairs(nodes) do
            step()
            if not transp[n] and #marker_refs(n) == 0 then
                local kc, kp = #reach(n, "children"), #reach(n, "parents")
                -- Kept endpoints: the header keeps a tip (no child), the footer a root
                -- (no parent). A true junction has ≥2 distinct terminals on a side.
                local keep = (up and kc == 0) or (not up and kp == 0) or kc >= 2 or kp >= 2
                if not keep then transp[n] = true; changed = true end
            end
        end
    end
    -- The next kept node along a chain of transparent nodes, via `field`
    -- ("parents" toward the root, "children" toward the seam/tip).
    local function follow(start, field)
        local cur = start
        while cur and transp[cur] do cur = cur[field][1] end
        return cur
    end

    -- A copy per kept node (inherits the original's fields via metatable).
    local copy = {}
    for _, n in ipairs(nodes) do
        step()
        if not transp[n] then
            copy[n] = setmetatable({
                hash = n.hash, parents = {}, children = {},
                refs = marker_refs(n), region = n.region, tip = n.tip,
            }, { __index = n })
        end
    end

    -- Re-point edges among kept nodes, jumping over spliced runs (dedup).
    for _, n in ipairs(nodes) do
        step()
        local c = copy[n]
        if c then
            local pseen, cseen = {}, {}
            for _, p in ipairs(n.parents) do
                local k = transp[p] and follow(p, "parents") or p
                if k and copy[k] and not pseen[k] then
                    pseen[k] = true; c.parents[#c.parents + 1] = copy[k]
                end
            end
            for _, ch in ipairs(n.children) do
                local k = transp[ch] and follow(ch, "children") or ch
                if k and copy[k] and not cseen[k] then
                    cseen[k] = true; c.children[#c.children + 1] = copy[k]
                end
            end
        end
    end

    -- Rendering role per kept node, from its anchor refs and its **terminal** degree:
    -- an anchor-ref head is a `◍` marker; a fork/merge reaching ≥2 distinct terminals on
    -- a side is a node-less junction; otherwise a plain node. Terminals (not the
    -- re-pointed kept degree) are used because a junction's branches may run off to the
    -- **seam** — distinct boundary lanes with no kept node of their own — which still
    -- make it a real merge (`M.header` wires those lanes in from the boundary).
    for _, n in ipairs(nodes) do
        local c = copy[n]
        if c then
            if #c.refs > 0 then
                c.collapsed, c.junction = true, false
            elseif #reach(n, "parents") >= 2 or #reach(n, "children") >= 2 then
                c.collapsed, c.junction = false, true
            else
                c.collapsed, c.junction = false, false
            end
        end
    end

    -- node_of: kept nodes map their own hashes; a spliced node maps to the next
    -- kept node toward the kept end — the **root** (down) or the **tip** (up).
    local toward = up and "children" or "parents"
    local node_of = {}
    local function map_to(n, target)
        if not target then return end
        node_of[n.hash] = target
        for _, h in ipairs(n.region or {}) do node_of[h] = target end
    end
    for _, n in ipairs(nodes) do
        step()
        if copy[n] then
            map_to(n, copy[n])
        else
            local k = follow(n[toward][1], toward)
            map_to(n, k and copy[k])
        end
    end

    local items = {}
    for _, n in ipairs(nodes) do
        if copy[n] then items[#items + 1] = { type = "commit", commit = copy[n] } end
    end
    return { items = items, node_of_hash = node_of }
end

--- Build the **active sub-DAG** for a footer (spec §6.2): starting from the lanes
--- crossing the seam (`boundary`), follow each lane's **first-parent chain**
--- downward to its root, and condense it. This shows *only* the existing lanes
--- continuing — they converge at the commits where they meet (junctions that the
--- active lanes actually participate in) and every one reaches a root, so no lane
--- is ever left dangling. No non-active branch is introduced (a merge's
--- second parent is never followed). `anchor_names` selects which refs are
--- markers. `extra` is additional entry commits to walk too — the pinned-ref tips
--- that sit below the cutoff but aren't on an active lane (a divergent pinned
--- branch), so they appear as markers and descend to where they join. `order_of`
--- (optional, commit → index, newest = smaller) sorts the result newest-first, so
--- multiple independent entries still lay out in a valid topological order.
--- Returns `{ items, node_of_hash }` like `condense`.
---@param boundary table<integer, table>  -- col → lane { parent = Commit, ... }
---@param anchor_names table<string, boolean>?
---@param extra table[]?  -- extra entry Commits (pinned tips below the cutoff)
---@param order_of (fun(node: table): integer|nil)?
---@param yield (fun())?  -- chunking hook; called every YIELD_EVERY units of work
---@return table
function M.continue(boundary, anchor_names, extra, order_of, yield)
    local step = chunker(yield)
    local inset, fp_child = {}, {} -- hash → Commit ; hash → in-set first-parent children
    local queue = {}
    local function push(c) if c and not inset[c.hash] then inset[c.hash] = c; queue[#queue + 1] = c end end
    for _, lane in pairs(boundary) do push(lane.parent) end
    for _, c in ipairs(extra or {}) do push(c) end
    -- BFS down first-parents. A commit is discovered (queued) after the children
    -- that reach it, so `queue` is children-before-parents (newest-first) — the
    -- order columns.layout/condense expect.
    local qi = 1
    while qi <= #queue do
        step()
        local c = queue[qi]; qi = qi + 1
        local p = c.parents and c.parents[1]
        if p then
            fp_child[p.hash] = fp_child[p.hash] or {}
            fp_child[p.hash][#fp_child[p.hash] + 1] = c
            push(p)
        end
    end

    -- DisplayNode per in-set commit, edges = first-parent only (converging where
    -- chains meet). Inherits commit fields via metatable.
    local node = {}
    for _, c in ipairs(queue) do
        step()
        node[c.hash] = setmetatable({ hash = c.hash, refs = c.refs, parents = {}, children = {} },
            { __index = c })
    end
    for _, c in ipairs(queue) do
        step()
        local n = node[c.hash]
        local p = c.parents and c.parents[1]
        if p and inset[p.hash] then n.parents[1] = node[p.hash] end
        for _, ch in ipairs(fp_child[c.hash] or {}) do n.children[#n.children + 1] = node[ch.hash] end
    end
    local nodes = {}
    for _, c in ipairs(queue) do nodes[#nodes + 1] = node[c.hash] end
    -- With several independent entries the BFS order isn't globally
    -- children-before-parents; sort newest-first so condense/columns.layout see a
    -- valid topological order.
    if order_of then
        -- NB: never yield inside a table.sort comparator — it runs under a C frame
        -- and yielding across it errors. The walk above is already chunked.
        table.sort(nodes, function(a, b) return (order_of(a) or 0) < (order_of(b) or 0) end)
    end
    return M.condense(nodes, anchor_names, nil, yield)
end

--- Cap a pane's rows to `max` (spec §6.2). A **header** (`keep_first` on) runs
--- tip→seam (seam at the **bottom**): keep the seam-continuous **bottom** `max` rows
--- and elide the far **tips** into a `+N above` marker. Keeping a contiguous
--- seam-adjacent slice preserves lane **continuity** — every lane runs unbroken from
--- the seam up to the cap, where it exits into the `+N` marker (one clean boundary).
--- (Eliding the *middle* instead — to keep both the tips and the seam — would tear
--- every lane in two at the gap: no head, no junction, a dangling stub. That is the
--- continuity bug this avoids.) A **footer** (`keep_first` off) runs seam→root (seam
--- at the top): it keeps the seam-nearest rows and the final **root** (it is small
--- and the root anchors it). Returns the kept rows and the number elided.
--- A capped **header** also reports the **names of the pinned anchors it elided** (the
--- tips it dropped), so the `+N above` marker can name them — the off-screen anchors stay
--- visible-by-name even when the header can't draw their ◍ heads (spec §6.2). Order is
--- newest-first (top of the elided slice), de-duplicated.
---@param rows table[]
---@param max integer
---@param keep_first boolean?  -- header orientation (seam at the bottom)
---@return table[] kept, integer elided, string[] elided_anchors
function M.cap(rows, max, keep_first)
    if #rows <= max then return rows, 0, {} end
    local out, names, seen = {}, {}, {}
    if keep_first then
        -- The contiguous bottom slice ending at the seam — continuous by construction.
        for i = 1, max do out[i] = rows[#rows - max + i] end
        -- The elided TOP rows are the far tips; surface any pinned anchor labels there.
        -- One name per anchor row, preferring the HEAD marker over a branch that merely
        -- shares the commit (so the anchor reads as HEAD, not e.g. the branch it points at).
        for i = 1, #rows - max do
            local r = rows[i]
            if r.pinned and r.commit and r.commit.refs then
                local pick
                for _, rf in ipairs(r.commit.refs) do
                    if rf.kind == "head" then pick = rf.name; break end
                end
                pick = pick or (r.commit.refs[1] and r.commit.refs[1].name)
                if pick and not seen[pick] then seen[pick] = true; names[#names + 1] = pick end
            end
        end
    else
        for i = 1, max - 1 do out[i] = rows[i] end
        out[max] = rows[#rows] -- the root, always
    end
    return out, #rows - max, names
end

--- The header **seam** (spec §6.2): which rendered line is the cutoff for an overlay
--- that should cover at least `cover` screen rows, given the display `items` and the
--- top visible one (`top`, whose split line is scrolled off above the viewport).
---
--- A commit renders as a block of `[split?] columns [merge?]` screen rows. The overlay
--- covers **whole commit blocks** — it never splits a commit across the seam — so the
--- cutoff rounds **up** to the top of the first commit whose block lies entirely below
--- the covered region. A covered commit's trailing **merge** line is part of it, so it
--- is covered too (the "+1 padding" a naive screen-row cutoff left dangling, reading
--- the covered commit's columns line instead of the visible row below it).
---
--- Pure — no `screenpos` — so the cutoff is **unit-testable** (the live glue only
--- supplies `top` via `line('w0')` and the per-item height). `height_of(item)` gives a
--- commit's columns rows (default 1; the dual label mode is 2).
---@param items table[]            -- the display OrderItems (with `.split`/`.merge`)
---@param top integer              -- index of the top visible item (its split is off-screen)
---@param cover integer            -- the overlay's requested screen-row budget
---@param height_of (fun(item: table): integer)?  -- a commit's columns rows (default 1)
---@return table?  -- { item, kind = "split"|"columns", idx, cover } or nil past the end
function M.header_seam(items, top, cover, height_of)
    height_of = height_of or function() return 1 end
    local row = 0
    for i = top, #items do
        if row >= cover then
            local it = items[i]
            return {
                item = it,
                kind = (i > top and it.split) and "split" or "columns",
                idx = i,
                cover = row, -- whole commit blocks covered (≥ the requested budget)
            }
        end
        local it = items[i]
        row = row + ((i > top and it.split) and 1 or 0) + height_of(it) + (it.merge and 1 or 0)
    end
    return nil
end

--- Every lane crossing one edge of a single rendered line (a commit's columns
--- line, or a split/merge fan line), as `col → Lane`. This is the seam primitive:
--- a pane seeds with the lanes of whichever rendered line sits at the cutoff —
--- including a split/merge virtual line, which has no buffer line of its own.
--- The default reads the **bottom** edge (lanes flowing *down* — for a footer
--- below the view); `up` reads the **top** edge (lanes flowing *up* — for a
--- header above it).
---@param line table[]|nil  -- a rendered line (GraphColumn[])
---@param up boolean?  -- read the top (up) edge instead of the bottom
---@return table<integer, table>  -- col → { id, color, parent, begin }
function M.boundary_of(line, up)
    local dir = up and "up" or "down"
    local out = {}
    for col, cell in ipairs(line or {}) do
        for _, s in ipairs(cell.lanes or {}) do
            if s.connectivity[dir] then
                -- `edges` is a *live* reference to the source segment's edges, so a
                -- pane repaint can read the crossing lane's current cone state
                -- (`highlighted`, set by the main view's reachability walk) without
                -- rebuilding the pane (spec §6.2 reachability emphasis).
                out[col] = { id = s.id, color = s.color, parent = s.parent,
                    begin = s.begin, highlighted = false, edges = s.edges }
            end
        end
    end
    return out
end

--- The seam map at the **bottom** edge of a laid-out row: every lane flowing
--- *down* out of it. The last rendered line is its merge fan if any, else its
--- columns line.
---@param rows table[]  -- laid-out rows from columns.layout
---@param i integer     -- 1-based row index (the main view's last visible row)
---@return table<integer, table>  -- col → { id, color, parent, begin }
function M.boundary_below(rows, i)
    local row = rows[i]
    if not row then return {} end
    return M.boundary_of(row.merge or row.columns)
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

--- The in-cone node set for a pane, propagated from its in-cone seam-crossing
--- lanes over the pane's **own** condensed graph (spec §6.2 reachability
--- emphasis). The cone is monotone (every parent of an in-cone commit is in-cone,
--- every child of an in-cone commit is in-cone; §12.1), so cone membership inside
--- a pane is exactly the directed reachability from the in-cone crossing lanes'
--- entry nodes: **down** (`.parents`) for the footer — everything below an in-cone
--- crossing lane is a pivot-ancestor — and **up** (`.children`) for the header —
--- everything above is a pivot-descendant. A confluence joining an out-of-cone
--- lane is in-cone from the join on (the meeting node is a parent/child of an
--- in-cone node), which the walk captures for free. `O(pane)`: the condensed
--- nodes only link to one another, so the walk stays within the small pane and
--- never touches the off-screen graph.
---@param seeds table[]            -- entry nodes (in-cone crossing lanes' pane nodes)
---@param dir "down"|"up"          -- footer follows .parents, header .children
---@return table<string, boolean>  -- set of in-cone node hashes
function M.mark_pane_cone(seeds, dir)
    local field = (dir == "up") and "children" or "parents"
    local incone, stack = {}, {}
    for _, n in ipairs(seeds or {}) do
        if n and n.hash and not incone[n.hash] then
            incone[n.hash] = true
            stack[#stack + 1] = n
        end
    end
    while #stack > 0 do
        local n = table.remove(stack)
        for _, m in ipairs(n[field] or {}) do
            if m and m.hash and not incone[m.hash] then
                incone[m.hash] = true
                stack[#stack + 1] = m
            end
        end
    end
    return incone
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

--- Build the **minimal connecting sub-DAG** for the header (spec §6.2): the smallest
--- graph that shows how the **pinned anchors** relate to each other and to the lanes
--- **crossing the cutoff** (the "seeds"). A lane is drawn only where it connects two
--- such endpoints; an unrelated crossing lane terminates immediately at the seam with
--- a head, so no irrelevant branch heads leak in. Up-only (toward children/newer) over
--- the **display** DAG (the projected DisplayNodes the main view shows — so the header
--- summarises exactly what is on screen, and `order_of` is always defined), bounded
--- above the seam by `order_of < seam_idx`.
---
--- **Tracked-lane induce** (spec §6.2). The **tracked** lanes are the lanes crossing
--- the seam plus the pinned anchors' own lanes (by **lane id** — the stable rendered
--- identity from the main graph, since the projected first-parent is unreliable). From
--- each seed (a boundary `begin` or a pinned tip) walk **up** via `children`, keeping a
--- child iff it is on a tracked lane: the lane's own continuation (same id) or a
--- merge/split with another seam lane or an anchor. A fork onto an *untracked* feature
--- branch's lane is dropped, so the header never fans into the merge/fork plumbing of
--- every branch that touched the trunk off-screen. **Merges** fall out where two
--- followed lanes reach the same node — that is the only kept junction (≥2 tracked
--- lanes meet), drawn node-less by `condense`/`M.header`.
---
--- **Invariant:** every seed `begin` is inducted directly, so no seam lane is ever
--- dropped and the header's bottom row always matches the main view's top edge. The
--- induced node's restricted children/parents drive `condense`'s role: ≥2 kept children
--- → junction, 1 → collapse (spliced away), 0 → head. Then `condense(up)`.
---@param boundary table<integer, table>  -- col → lane with `.begin` (DisplayNode) and `.id`
---@param tips table[]  -- pinned anchor tip DisplayNodes above the seam
---@param anchor_names table<string, boolean>?
---@param order_of (fun(node: table): integer|nil)?  -- node → index (newer = smaller)
---@param seam_idx integer  -- only nodes with a smaller index are above the seam
---@param yield (fun())?  -- chunking hook; called every YIELD_EVERY units of work
---@param lane_of (fun(node: table): table?)?  -- node → its main-view lane { id, color } (§6.2)
---@return table
function M.continue_up(boundary, tips, anchor_names, order_of, seam_idx, yield, lane_of)
    local step = chunker(yield)
    local function above(n)
        -- Working-tree virtual commits (§4.2) are the live state, not topology, so
        -- they never appear in a context pane (§6.2): treat a virtual node as
        -- not-above so the up-walk stops before it and the header's highest head is
        -- the topmost REAL commit (typically HEAD).
        if not n or n.virtual then return false end
        local i = order_of and order_of(n)
        return i ~= nil and i < seam_idx
    end
    local function pos_of(n) return (order_of and order_of(n)) or 0 end

    -- Seeds — each boundary column (a crossing lane) and each pinned anchor tip, each
    -- a DISTINCT seed id (two columns of a fork seam are different lanes). A seed is
    -- inducted directly, so it is eligible even on the seam row; only its children are
    -- gated by `above`. Skip a crossing lane born on a virtual commit (§4.2).
    local seeds = {}
    local seed_floor = {} -- hash → true (a seed begin/tip is eligible even at seam_idx)
    for col, lane in pairs(boundary) do
        if lane.begin and not lane.begin.virtual then
            seeds[#seeds + 1] = { id = "c" .. tostring(col), node = lane.begin }
            seed_floor[lane.begin.hash] = true
        end
    end
    for ti, t in ipairs(tips) do
        seeds[#seeds + 1] = { id = "t" .. tostring(ti), node = t, pinned = true }
        seed_floor[t.hash] = true
    end
    local function in_region(n) return n and (seed_floor[n.hash] or above(n)) end

    -- The **tracked** lane ids: the lanes crossing the seam plus the pinned anchors' own
    -- lanes (by **lane id** — the stable rendered identity from the main graph, since the
    -- projected first-parent is unreliable; spec §6.2). A child is kept only if it is on a
    -- tracked lane, so the header never follows an untracked feature branch's lane — only
    -- the anchors' spines and the merges/splits BETWEEN tracked lanes survive.
    local function lane_id(n) local l = lane_of and lane_of(n); return l and l.id end
    local tracked = {}
    for _, lane in pairs(boundary) do if lane.id ~= nil then tracked[lane.id] = true end end
    for _, t in ipairs(tips) do local id = lane_id(t); if id ~= nil then tracked[id] = true end end

    -- Pass 1 — confluence: walk UP from each seed, recording the set of seed ids reaching
    -- each node. ≥2 distinct ⇒ a **confluence** — where ≥2 tracked lanes converge.
    local reach = {}
    for _, s in ipairs(seeds) do
        reach[s.node.hash] = reach[s.node.hash] or {}; reach[s.node.hash][s.id] = true
        local seen, stack = { [s.node.hash] = true }, { s.node }
        while #stack > 0 do
            step()
            local c = stack[#stack]; stack[#stack] = nil
            for _, ch in ipairs(c.children or {}) do
                if above(ch) then
                    local r = reach[ch.hash]; if not r then r = {}; reach[ch.hash] = r end
                    r[s.id] = true
                    if not seen[ch.hash] then seen[ch.hash] = true; stack[#stack + 1] = ch end
                end
            end
        end
    end
    local function is_confluence(hash)
        local r, n = reach[hash], 0
        if not r then return false end
        for _ in pairs(r) do n = n + 1; if n >= 2 then return true end end
        return false
    end

    -- Pass 2 — useful: a node is useful iff going UP it leads to a confluence or a pinned
    -- anchor. Walk DOWN (via parents) from every confluence and pinned tip, marking the
    -- above-seam ancestors. An isolated crossing lane (leads to neither) is NOT useful, so
    -- it caps at the seam with a head instead of being drawn up to its own feature tip.
    local useful, stack2 = {}, {}
    local function mark_useful(n) if n and not useful[n.hash] then useful[n.hash] = true; stack2[#stack2 + 1] = n end end
    for _, s in ipairs(seeds) do
        if s.pinned then mark_useful(s.node) end
        local seen, stack = { [s.node.hash] = true }, { s.node }
        while #stack > 0 do
            step()
            local c = stack[#stack]; stack[#stack] = nil
            if is_confluence(c.hash) then mark_useful(c) end
            for _, ch in ipairs(c.children or {}) do
                if above(ch) and not seen[ch.hash] then seen[ch.hash] = true; stack[#stack + 1] = ch end
            end
        end
    end
    while #stack2 > 0 do
        step()
        local c = stack2[#stack2]; stack2[#stack2] = nil
        -- Propagate useful DOWN only through a **tracked** node: a parent p is useful
        -- only if it can reach the confluence/anchor going up via a tracked child (here
        -- `c`). Otherwise p would be "useful" via an untracked path the induce can't
        -- follow, and would cap as a stray head mid-graph.
        local lc = lane_id(c)
        if lc ~= nil and tracked[lc] then
            for _, p in ipairs(c.parents or {}) do if in_region(p) then mark_useful(p) end end
        end
    end

    -- Pass 3 — induce: from each seed walk UP, keeping a child iff it is on a tracked lane
    -- AND useful. Tracked drops the feature plumbing; useful caps an isolated lane. Merges
    -- fall out where two followed lanes reach one node (condense renders the junction; the
    -- seam-parent sentinel below keeps a merge whose parents cross the cutoff a junction).
    local inducted, stack3 = {}, {}
    local function induct(n) if not inducted[n.hash] then inducted[n.hash] = n; stack3[#stack3 + 1] = n end end
    for _, s in ipairs(seeds) do induct(s.node) end
    while #stack3 > 0 do
        step()
        local c = stack3[#stack3]; stack3[#stack3] = nil
        for _, ch in ipairs(c.children or {}) do
            if above(ch) and useful[ch.hash] then
                local id = lane_id(ch)
                if id ~= nil and tracked[id] then induct(ch) end
            end
        end
    end

    -- Connect each pinned anchor DOWN its first-parent spine to the already-inducted
    -- part (the trunk / the seam), so a **divergent or unmerged** anchor — whose lane
    -- does not cross the seam and whose up-walk reaches no spine (its tip is ahead of the
    -- trunk) — is not left as a floating labelled head. Induct for *edges only* (do NOT
    -- re-walk up, or the up-walk pulls in every fork off the spine), stopping on meeting
    -- the inducted set or the seam (a parent at/below the cutoff → a seam sentinel below).
    for _, s in ipairs(seeds) do
        if s.pinned then
            local c = s.node
            while c do
                local p = c.parents and c.parents[1]
                if not (p and above(p)) then break end
                local met = inducted[p.hash]
                inducted[p.hash] = inducted[p.hash] or p
                if met then break end
                c = p
            end
        end
    end

    -- Build DisplayNodes with edges restricted to the inducted set (children
    -- first-parent-first, for colour-pivot continuity in M.header).
    local node = {}
    local function ensure(n)
        local m = node[n.hash]
        if not m then
            m = setmetatable({ hash = n.hash, refs = n.refs, parents = {}, children = {} },
                { __index = n })
            node[n.hash] = m
        end
        return m
    end
    for _, c in pairs(inducted) do ensure(c) end
    for _, c in pairs(inducted) do
        step()
        local m = node[c.hash]
        local kids = {}
        for _, ch in ipairs(c.children or {}) do
            if inducted[ch.hash] then kids[#kids + 1] = ch end
        end
        table.sort(kids, function(a, b)
            local af = (a.parents and a.parents[1] == c) and 0 or 1
            local bf = (b.parents and b.parents[1] == c) and 0 or 1
            if af ~= bf then return af < bf end
            return pos_of(a) < pos_of(b)
        end)
        for _, ch in ipairs(kids) do m.children[#m.children + 1] = node[ch.hash] end
        for _, p in ipairs(c.parents or {}) do
            if inducted[p.hash] then
                m.parents[#m.parents + 1] = node[p.hash]
            elseif not above(p) then
                -- A SEAM parent (it crosses the cutoff, so it has no kept node of its own).
                -- Keep a UNIQUE per-edge sentinel terminal so `condense` still counts this
                -- node as a junction where ≥2 boundary lanes converge — e.g. a merge sitting
                -- just above the cutoff whose two parents both cross the seam. A per-edge
                -- sentinel (NOT the shared parent node) keeps two distinct crossing lanes
                -- that happen to share a below-cutoff parent counting as TWO terminals.
                -- Without it the node looks linear (its parents are gone), gets spliced, and
                -- the whole connection up to the pinned anchors is dropped. Re-pointing
                -- discards the sentinel (no kept copy); M.header wires the lane in from the
                -- boundary.
                m.parents[#m.parents + 1] = { seam = true }
            end
        end
    end

    -- Every seed is inducted, so this is a safety net: a seed with no inducted
    -- node (e.g. one whose lane reaches nothing tracked) still ends at the seam as a
    -- childless node — a bare ◍ head — so no crossing lane is dropped.
    for _, s in ipairs(seeds) do
        if not node[s.node.hash] then ensure(s.node) end
    end

    -- Newest-first (children before parents — the topo order condense wants).
    local nodes = {}
    for _, m in pairs(node) do nodes[#nodes + 1] = m end
    -- NB: never yield inside a table.sort comparator (C-frame); the walks above
    -- are already chunked.
    table.sort(nodes, function(a, b) return pos_of(a) < pos_of(b) end)
    return M.condense(nodes, anchor_names, true, yield)
end

--- Connectivity literal → a full `{up,down,left,right}` table (Phase-2 cell shape).
local function conn(t)
    return { up = t.up or false, down = t.down or false, left = t.left or false, right = t.right or false }
end

--- The segment a NODE (◍/junction) sits on — its own **vertical** lane, preferred
--- over a passing horizontal arm (a merge arm crossing the column), so the node is
--- coloured by its branch, not by a lane that merely turns through it. Falls back to
--- the first segment.
local function node_seg(segs)
    local best
    for _, s in ipairs(segs) do
        local c = s.connectivity
        if (c.up or c.down) and not (c.left or c.right) then return s end
        best = best or s
    end
    return best
end

--- The union of a cell's segments' connectivity (the flat glyph connectivity).
local function union(segs)
    local u = { up = false, down = false, left = false, right = false }
    for _, s in ipairs(segs) do
        local c = s.connectivity
        u.up = u.up or c.up; u.down = u.down or c.down
        u.left = u.left or c.left; u.right = u.right or c.right
    end
    return u
end

--- Turn a `col → Segment[]` line into a `GraphColumn[]` (the shape Phase 2 /
--- `get_column_chars` consumes). The vertical/passing segment is added **first** so
--- the renderer colours a crossing cell by the bar (vertical colour continuity).
---@param cells table<integer, table[]>
---@param width integer
---@param node_col integer?
---@param node_commit table?
---@return table[]
local function assemble(cells, width, node_col, node_commit)
    local out = {}
    for j = 1, width do
        local segs = cells[j] or {}
        -- A cell is coloured by the lane running THROUGH it vertically, not by a
        -- horizontal arm that merely turns into it — so a lane keeps its own colour
        -- across corners and crossings (the fork arm into dev's column was colouring
        -- dev's corner in the parent's colour).
        local prim = node_seg(segs)
        out[j] = {
            connectivity = union(segs),
            lanes = segs,
            has_commit = node_col == j,
            commit = (node_col == j) and node_commit or nil,
            id = prim and prim.id or nil,
            color = prim and prim.color or nil,
        }
    end
    return out
end

--- Vertically overlay a group of header rows (each `{ columns = GraphColumn[] }`,
--- top-to-bottom) into one `GraphColumn[]`, or `nil` if any column is incompatible
--- (≥2 nodes, ≥2 distinct lane ids, or an overlapping column carrying a turn). Same
--- rule as graph.lua's `pack_markers`: `up` from the topmost occupant, `down` from
--- the bottom one, horizontals only from a sole occupant. Used to pack several bare
--- `◍` heads onto one line — a `◍` tip wins its column over a passing bar of the
--- same lane (the lane simply ends one row lower, which a summary tolerates).
---@param group table[]  -- rows { columns = GraphColumn[] }, top-to-bottom
---@return table[]|nil
local function overlay_rows(group)
    local width = 0
    for _, r in ipairs(group) do if #r.columns > width then width = #r.columns end end
    local cols = {}
    for c = 1, width do
        local occ, node_cell, lane_id, seg = {}, nil, nil, nil
        for _, r in ipairs(group) do
            local cell = r.columns[c]
            if cell and (cell.has_commit or (cell.lanes and #cell.lanes > 0)) then
                occ[#occ + 1] = cell
                if cell.has_commit then
                    if node_cell then return nil end
                    node_cell = cell
                end
                for _, s in ipairs(cell.lanes or {}) do
                    seg = seg or s
                    if lane_id == nil then lane_id = s.id elseif lane_id ~= s.id then return nil end
                end
            end
        end
        local has_h = false
        for _, cell in ipairs(occ) do
            local cc = cell.connectivity
            if cc and (cc.left or cc.right) then has_h = true end
        end
        if #occ >= 2 and has_h then return nil end
        local cn = { up = false, down = false, left = false, right = false }
        if #occ >= 1 then
            cn.up = occ[1].connectivity.up or false
            cn.down = occ[#occ].connectivity.down or false
            if #occ == 1 then
                cn.left = occ[1].connectivity.left or false
                cn.right = occ[1].connectivity.right or false
            end
        end
        local lanes = {}
        if seg then
            lanes[1] = { id = seg.id, color = seg.color, connectivity = cn,
                edges = seg.edges, begin = seg.begin, parent = seg.parent, cone = seg.cone }
        end
        cols[c] = {
            connectivity = cn, lanes = lanes,
            has_commit = node_cell ~= nil,
            commit = node_cell and node_cell.commit or nil,
            id = seg and seg.id or nil, color = seg and seg.color or nil,
        }
    end
    return cols
end

--- Pack consecutive **unpinned head** rows (`row.commit` set, `row.pinned` false)
--- onto as few lines as possible (§6.2): only the pinned anchors keep their own
--- line, every other `◍` head compacts. Pinned-anchor rows and node-less junction
--- rows (`commit == nil`) break a run and are never merged.
---@param rows table[]
---@return table[]
local function pack_heads(rows)
    local out, i = {}, 1
    while i <= #rows do
        if rows[i].commit == nil or rows[i].pinned then
            out[#out + 1] = rows[i]; i = i + 1
        else
            local group, merged, j = { rows[i] }, rows[i].columns, i + 1
            while j <= #rows and rows[j].commit ~= nil and not rows[j].pinned do
                local cand = vim.list_extend({}, group)
                cand[#cand + 1] = rows[j]
                local m = overlay_rows(cand)
                if not m then break end
                group, merged, j = cand, m, j + 1
            end
            out[#out + 1] = (#group == 1) and rows[i] or { columns = merged, commit = nil }
            i = j
        end
    end
    return out
end

--- Build the **header** pane above the main view (spec §6.2) by a bespoke
--- **bottom-up grid sweep** (the direct-grid algorithm) over the focused condensed
--- sub-DAG from `continue_up`. No `columns.layout`, no transpose.
---
--- The header's seam is its **bottom** edge: it is seeded directly from `boundary`
--- (each column's lane ascends toward `node_of[lane.begin.hash]`), so the bottom
--- row IS the main view's top edge by construction — every boundary lane continues.
--- The sweep then processes the condensed nodes **nearest-seam first**, emitting one
--- line per node:
---   * every still-active lane is carried up as a vertical bar (continuity);
---   * a **head** (no up-children) places a `◍` and ends its lane (labelled when the
---     node is a pinned anchor, bare otherwise);
---   * a **junction** (merge/fork) draws a node-less 3-way crossing, converging the
---     arriving columns into one (merge) and/or fanning to fresh columns (fork);
---   * a **linear** anchor marker continues straight up.
--- Lines are collected bottom-up then reversed so the tip is on top.
---@param items table[]  -- condensed OrderItems from continue_up, newest-first
---@param boundary table<integer, table>  -- col → lane { id, color, begin }
---@param node_of table<string, table>?  -- hash → condensed node (continue_up's node_of_hash)
---@param lane_of (fun(node: table): table?)?  -- node → its branch's main-view { id, color }
---@param col_of (fun(node: table): integer?)?  -- node → its main-view column (left-right order)
---@return table  -- { rows = table[] }
function M.header(items, boundary, node_of, lane_of, col_of)
    node_of = node_of or {}
    -- The main-view lane id/colour for a node's branch, so each branch keeps its OWN
    -- distinct colour (matching the graph). Falls back to a given default.
    local function lane(node, def)
        local l = lane_of and lane_of(node)
        if l then return l.id, l.color end
        return def and def.id, def and def.color
    end

    -- Header-local lane identity. The main view RECYCLES lane ids/colours (a slot is
    -- reused once a lane ends), but the header can show those recycled lanes
    -- CONCURRENTLY — so two distinct branches must not collapse onto one id/colour (the
    -- "pinned branches both id 1" bug, and the lane that terminates twice). A fork child
    -- therefore gets a **fresh unique id** (above every boundary id, so no lane id ever
    -- repeats → no double termination) and a colour **de-collided** against the lanes
    -- alive beside it — preferring its main-view colour when that is still free, so the
    -- header keeps matching the graph wherever it can.
    local maxid = 0
    for _, l in pairs(boundary) do if type(l.id) == "number" and l.id > maxid then maxid = l.id end end
    -- The crossing/seam lane ids (must keep their boundary colour to the seam). Above-seam
    -- lanes (fork children / merge continuations) carry their own main-view ids now, so the
    -- distinction is set membership, not an id threshold.
    local boundary_set = {}
    for _, l in pairs(boundary) do if l.id ~= nil then boundary_set[l.id] = true end end
    -- A fresh (fork-child) id must clearly be NEW: above every id that appears in the
    -- header — the boundary lanes AND every node's main-view lane — so it never
    -- numerically coincides with an existing main-view lane id (which reads as the branch
    -- "reusing" an id). Fresh ids then grow monotonically from there.
    for _, it in ipairs(items) do
        local lid = lane(it.commit)
        if type(lid) == "number" and lid > maxid then maxid = lid end
    end
    local function fresh_id() maxid = maxid + 1; return maxid end
    -- A header lane PREFERS its main-view lane id, so a branch keeps the SAME id as the
    -- graph (the header is a faithful continuation, not a relabelling). A fresh
    -- (monotonic, above-everything) id is used only on a genuine collision — the main view
    -- recycled that id onto a lane already alive in the header, so the two must differ
    -- (the "both id 1" / double-termination bug). Seeded with the boundary ids, which the
    -- pivots keep.
    local used_ids = {}
    for _, l in pairs(boundary) do if l.id ~= nil then used_ids[l.id] = true end end
    local function pick_id(mvid)
        local id
        if type(mvid) == "number" and not used_ids[mvid] then id = mvid else id = fresh_id() end
        used_ids[id] = true
        return id
    end
    local function free_color(used, prefer)
        if prefer and not used[prefer] then return prefer end
        local c = 1
        while used[c] do c = c + 1 end
        return c
    end

    -- Sweep position per condensed node (newest-first index; larger = nearer seam).
    local pos = {}
    for i, it in ipairs(items) do pos[it.commit] = i end

    -- active columns: col → { id, color, node } — the lane in this column ascends
    -- toward `node`. Seeded from the boundary so the bottom edge matches the seam.
    local active = {}
    for col, l in pairs(boundary) do
        local n = l.begin and node_of[l.begin.hash]
        if n then active[col] = { id = l.id, color = l.color, node = n } end
    end

    -- Condensed nodes, nearest-seam first.
    local order = {}
    for _, it in ipairs(items) do order[#order + 1] = it.commit end
    table.sort(order, function(a, b) return (pos[a] or 0) > (pos[b] or 0) end)

    -- Columns are **never reused** (a vacated lane can't be confused with a live one →
    -- no vertical colour break). `used_cols` is every column that has EVER held a lane;
    -- a fork child takes the nearest free column to its OWN main-view column, so the
    -- header's left-right order matches the graph without reusing a column.
    local maxcol = 0
    local used_cols = {}
    for c in pairs(active) do used_cols[c] = true; if c > maxcol then maxcol = c end end
    local function free_col(want)
        want = (type(want) == "number" and want >= 1) and want or (maxcol + 1)
        if not used_cols[want] then return want end
        for d = 1, 512 do
            if want - d >= 1 and not used_cols[want - d] then return want - d end
            if not used_cols[want + d] then return want + d end
        end
        return want
    end

    local lines = {} -- { columns, commit }, bottom-up

    for _, N in ipairs(order) do
        local arriving = {}
        for col, a in pairs(active) do if a.node == N then arriving[#arriving + 1] = col end end
        if #arriving > 0 then
            table.sort(arriving)
            local pivot = arriving[1]
            local plane = active[pivot] -- the surviving lane (continues up from pivot)
            local upkids = {}
            for _, c in ipairs(N.children or {}) do upkids[#upkids + 1] = c end
            -- The pivot (upkids[1]) inherits the surviving lane's id/colour, so it must be
            -- the child that ACTUALLY carries that lane in the main view (its lane_of id
            -- equals the boundary lane's). The condensed first-parent order can diverge
            -- from main-view lane continuity — a fork where the crossing lane really
            -- belongs to a sibling — and then the seam lane would jump to the wrong branch
            -- (the seam colour/id would not match the graph). Match by lane id; fall back
            -- to the existing order when nothing matches (e.g. a merge, where the pivot's
            -- colour switches at the junction anyway).
            if #upkids > 1 and plane and plane.id ~= nil then
                for k = 2, #upkids do
                    if lane(upkids[k]) == plane.id then
                        upkids[1], upkids[k] = upkids[k], upkids[1]
                        break
                    end
                end
            end
            local is_head = #upkids == 0
            local pinned = N.refs and #N.refs > 0

            local arr_set = {}
            for _, c in ipairs(arriving) do arr_set[c] = true end

            -- Up columns: the pivot continues straight (its surviving lane's id/colour,
            -- so the column's vertical colour never breaks); each extra fork child is
            -- placed at its OWN main-view column when free, so the header's left-right
            -- order MATCHES THE GRAPH (no bottom-up swap) — never reusing a column. Each
            -- keeps its branch's MAIN-VIEW id+colour (de-collided only on a genuine clash),
            -- so a branch's id is the same in the header as in the graph.
            local upcols, upid, upcolor = {}, {}, {}
            if not is_head then
                upcols[1] = pivot
                local mv1, c1col = lane(upkids[1], plane)
                -- The surviving lane CONTINUES AS ITSELF when the pivot child is the mainline
                -- continuation — recognised by main-view lane (mv1 == plane.id) OR
                -- TOPOLOGICALLY (it is N's first-parent child). The topological test is what
                -- keeps a COLLAPSED continuation connected: a collapsed branch on the trunk
                -- whose tip's main-view lane was recycled to a different id still has the merge
                -- N as its first parent, so it IS the trunk continuing. Without it the lane
                -- switches to a fresh id at the merge — the trunk "terminates" and HEAD gets a
                -- brand-new id (the merge-at-cutoff bug). Only a genuine FAN-OUT (N is not this
                -- child's first parent and the lanes differ) switches.
                local first_parent = upkids[1].parents and upkids[1].parents[1] == N
                if mv1 == plane.id or (first_parent and upkids[1].collapsed) then
                    upid[1], upcolor[1] = plane.id, plane.color
                else
                    upid[1], upcolor[1] = pick_id(mv1), c1col or plane.color
                end
                for k = 2, #upkids do
                    local mvid, pref = lane(upkids[k], plane)
                    local col = free_col(col_of and col_of(upkids[k]))
                    used_cols[col] = true
                    if col > maxcol then maxcol = col end
                    upcols[k] = col
                    upid[k] = pick_id(mvid)
                    upcolor[k] = pref
                end
            end

            local width = pivot
            for c in pairs(active) do if c > width then width = c end end
            for _, c in ipairs(upcols) do if c > width then width = c end end

            local cells = {}
            -- `cone` tags each segment with the node whose cone-membership governs
            -- its dimming (spec §6.2): the lane's lower (older/parent) endpoint, so a
            -- header segment lights iff that node is in the pivot's descendant cone.
            -- Every segment incident to this row's pivot has parent N (arms into N,
            -- the fork fan out of N, N's own verticals), so N.hash is the default; a
            -- passing bar carries its own lane's node instead.
            local function add(col, c, id, color, cone)
                cells[col] = cells[col] or {}
                cells[col][#cells[col] + 1] =
                    { id = id, color = color, connectivity = conn(c), cone = cone or N.hash }
            end
            -- A lane's horizontal arm from `from` to `to`, `down` at `from`, in the
            -- lane's OWN colour (so a crossed passing bar stays its own colour and the
            -- arm stays uniform — the wires-connect colour checks).
            local function arm(from, to, id, color, downcol, upcol)
                local lo, hi = math.min(from, to), math.max(from, to)
                for m = lo, hi do
                    add(m, {
                        left = m > lo or nil, right = m < hi or nil,
                        down = (m == downcol) or nil, up = (m == upcol) or nil,
                    }, id, color)
                end
            end

            -- 1. Passing lanes (active, not arriving) — vertical bars FIRST, so a
            --    crossing cell is coloured by the bar (vertical colour continuity).
            for col = 1, width do
                local a = active[col]
                if a and not arr_set[col] then
                    add(col, { up = true, down = true }, a.id, a.color, a.node and a.node.hash)
                end
            end
            -- 2. Each arriving non-pivot lane turns into the pivot, keeping its OWN
            --    id/colour on the `down` arm (so the seam matches the main view).
            for _, c in ipairs(arriving) do
                if c ~= pivot then
                    local a = active[c]
                    arm(c, pivot, a.id, a.color, c, nil)
                end
            end
            -- 3. The fork fan. Each FORK CHILD's arm is drawn in the CHILD's OWN colour
            --    (from the pivot to its column), so a diverging branch line reads as THAT
            --    branch — its colour runs unbroken from the seam-side arm up its bar, not
            --    the trunk's colour. Arms are drawn FARTHEST-FIRST so a shared inner
            --    segment takes the NEARER child's colour (each segment reads as the child
            --    at its outer end). The pivot's own vertical (the trunk continuing down to
            --    the seam and up to its child) keeps the pivot colour.
            if not is_head then
                if arr_set[pivot] then add(pivot, { down = true }, plane.id, plane.color) end
                local forks = {}
                for k = 2, #upcols do forks[#forks + 1] = k end
                table.sort(forks, function(a, b)
                    return math.abs(upcols[a] - pivot) > math.abs(upcols[b] - pivot)
                end)
                for _, k in ipairs(forks) do
                    local c = upcols[k]
                    local lo, hi = math.min(pivot, c), math.max(pivot, c)
                    for m = lo, hi do
                        add(m, { left = m > lo or nil, right = m < hi or nil }, upid[k], upcolor[k])
                    end
                end
                for k, col in ipairs(upcols) do add(col, { up = true }, upid[k], upcolor[k]) end
            elseif arr_set[pivot] then
                -- head: terminate the lane. The down arm connects to the seam below,
                -- so it MUST keep the boundary id/colour (the seam never switches) —
                -- a dead-end head has no above-segment to switch into.
                add(pivot, { down = true }, plane.id, plane.color)
            end

            -- 4. The node glyph: a `◍` head/anchor marker at the pivot; a junction is
            --    node-less (the crossing itself is the join).
            local node_col, node_commit
            if is_head or pinned then
                node_col = pivot
                node_commit = { hash = N.hash, collapsed = true,
                    parents = N.parents, children = N.children, refs = pinned and N.refs or {} }
            end

            lines[#lines + 1] = {
                columns = assemble(cells, width, node_col, node_commit),
                commit = node_commit,
                pinned = pinned,
            }

            -- 5. Advance the active front (each up-child in its own branch colour).
            for _, c in ipairs(arriving) do active[c] = nil end
            for k, col in ipairs(upcols) do
                active[col] = { id = upid[k], color = upcolor[k], node = upkids[k] }
            end
        elseif N.refs and #N.refs > 0 then
            -- A DISCONNECTED pinned anchor: its lane does not reach the cutoff (the lanes
            -- crossing the seam lead elsewhere — e.g. up into a collapsed branch — so none
            -- arrives at this node). A pinned anchor is ALWAYS visible (§6.2), so draw it as
            -- a lone labelled ◍ head. It has NO wires, so it needs no reserved column — it
            -- only must not sit directly above a NODE or an up-going lane (which would read
            -- as a connected lane). Pick the lowest such column so the header stays compact
            -- next to the lane structure rather than floating off to the side.
            local below = lines[#lines]
            local function blocked(c)
                local cell = below and below.columns and below.columns[c]
                if not cell then return false end
                if cell.has_commit then return true end
                for _, s in ipairs(cell.lanes or {}) do
                    if s.connectivity and s.connectivity.up then return true end
                end
                return false
            end
            local col = 1
            while blocked(col) do col = col + 1 end
            if col > maxcol then maxcol = col end
            local mvid, color = lane(N)
            local cells = { [col] = { { id = pick_id(mvid), color = color or 1,
                connectivity = conn({}), cone = N.hash } } }
            local node_commit = { hash = N.hash, collapsed = true,
                parents = N.parents, children = N.children, refs = N.refs }
            lines[#lines + 1] = {
                columns = assemble(cells, col, col, node_commit),
                commit = node_commit,
                pinned = true,
            }
        end
    end

    -- Bottom-up → newest-first (tip on top).
    local rows = {}
    for i = #lines, 1, -1 do rows[#rows + 1] = lines[i] end

    -- Global colour de-collision (interval colouring). Each unique lane id spans a set
    -- of rows; the main view RECYCLES colours, so two ids alive on the same row can
    -- arrive here sharing one. Assign each id a colour distinct from every id it shares
    -- a row with, preferring its own (main-view) colour so the header still matches the
    -- graph wherever there is no clash. One colour per id keeps a lane's colour
    -- vertically continuous by construction.
    do
        local id_rows, pref, order_ids, seen = {}, {}, {}, {}
        for _, r in ipairs(rows) do
            for _, cell in ipairs(r.columns or {}) do
                for _, s in ipairs(cell.lanes or {}) do
                    if s.id ~= nil then
                        id_rows[s.id] = id_rows[s.id] or {}
                        if pref[s.id] == nil then pref[s.id] = s.color end
                        if not seen[s.id] then seen[s.id] = true; order_ids[#order_ids + 1] = s.id end
                    end
                end
            end
        end
        local head_id = {} -- ids that terminate at a ◍ head (a node cell that does not
                           -- continue up: a down-head, or a lone disconnected anchor with
                           -- no wires at all)
        for ri, r in ipairs(rows) do
            for _, cell in ipairs(r.columns or {}) do
                for _, s in ipairs(cell.lanes or {}) do
                    if s.id ~= nil then
                        id_rows[s.id][ri] = true
                        local cc = s.connectivity or {}
                        if cell.has_commit and not cc.up and not cc.left and not cc.right then
                            head_id[s.id] = true
                            -- A head reads as ITS OWN branch (the tip) colour — but ONLY
                            -- for above-seam lanes (fork children and merge continuations).
                            -- A crossing/seam lane keeps its boundary colour all the way to
                            -- the seam and must NOT be switched (the seam-never-switches
                            -- rule); being a straight lane its colour already equals its
                            -- head's.
                            if s.id ~= nil and not boundary_set[s.id] then
                                local _, hc = lane(cell.commit)
                                if hc then pref[s.id] = hc end
                            end
                        end
                    end
                end
            end
        end
        -- Assign HEADS first, then ascending by id. Heads (the ◍ — the branches the
        -- summary is about, including the pinned anchors) claim their own main-view
        -- colour FIRST and keep it, so a head never drifts from its graph colour just
        -- because a passing lane recycled that colour. Low ids (boundary/crossing lanes)
        -- come next, so their colour is stable across cutoffs too; fork children
        -- de-collide around everyone.
        table.sort(order_ids, function(a, b)
            local ha, hb = head_id[a] and 0 or 1, head_id[b] and 0 or 1
            if ha ~= hb then return ha < hb end
            return a < b
        end)
        local final = {}
        for _, id in ipairs(order_ids) do
            local used = {}
            for oid, c in pairs(final) do
                local overlap = false
                for ri in pairs(id_rows[id]) do if id_rows[oid][ri] then overlap = true; break end end
                -- Two HEADS must differ even when not concurrent: each is a distinct
                -- branch tip, so it must read as a distinct colour (no HEAD/dev clash).
                if overlap or (head_id[id] and head_id[oid]) then used[c] = true end
            end
            final[id] = free_color(used, pref[id])
        end
        for _, r in ipairs(rows) do
            for _, cell in ipairs(r.columns or {}) do
                for _, s in ipairs(cell.lanes or {}) do
                    if s.id ~= nil and final[s.id] then s.color = final[s.id] end
                end
                -- Re-pick the cell's primary colour after recolouring: the lane running
                -- through it vertically, so a turn keeps its own lane's colour.
                local prim = node_seg(cell.lanes or {})
                if prim then cell.color = prim.color; cell.id = prim.id end
            end
        end
    end

    return { rows = pack_heads(rows) }
end

return M
