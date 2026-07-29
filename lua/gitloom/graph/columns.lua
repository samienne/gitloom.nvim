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
--- Output shape matches the legacy build_graph so Phase 2 (get_column_chars) and
--- the invariant tests consume it unchanged: rows of { columns, parent_lanes,
--- child_lanes }, each track { connectivity, lanes (Segment[]), has_commit,
--- commit, id, color, begin, parent }. `id` is the lane's stable identity;
--- `color` is its palette slot, allocated from a recycling free list (below).
---
--- **Staged layout.** `M.layout` lays out each item with shell setup steps
--- (classify / spawn_lanes / decide_style) then a **layout strategy** — a plain
--- function that chains the grid stages in order, each called once. `layout_compact`
--- (the default) is seed_bars -> place_commit -> slide -> fan_in ->
--- compact -> fan_out -> finalize; each writes segments into a live column grid on
--- `state.g` and reads occupancy back between stages. A structural oracle
--- (`complete_check`) then verifies the emitted lines. A different strategy is a
--- different chain: `layout_seam` (a context pane's boundary row) drops `slide` and
--- swaps `compact` for `carry`, so the seam matches the seeded columns without a
--- jog. There is no generic runner — the sequence is the algorithm. See
--- ARCHITECTURE.md ("Layout as a staged pipeline").
---
--- **Layout policy** (spec §5.6). Which chain lays out an ordinary row is
--- selectable via `opts.layout_policy`: `compact` (default), `survivors` (no
--- linear slide), `linear` (no survivor compaction), `straight` (neither — which
--- IS `layout_seam`, reused verbatim), and `gutter` (lanes never move AND the lane
--- owning the current subject row is held in a fixed column). The first four are
--- chains of the stages already here and add no stage code; `gutter` adds three
--- stages (`evict_gutter`, `claim_gutter`, `place_gutter`) and generalises two
--- (`fan_in`/`fan_out`) by the trunk column `state.kt` — nil, and therefore inert,
--- under every other policy. It is also the only one that varies the *seam* chain
--- (it is its own seam; see `POLICY` below).
---
--- A row renders as `[above…] columns [merge]`: `above` is a LIST of virtual lines
--- (the split fan, plus `gutter`'s handover rows), topmost first (§5 Line).
local M = {}

--- The `gutter` policy's fixed node column (spec §5.6). Model column 1 is the
--- gutter: the **lane** that owns the current subject row lives there, so its
--- commits' nodes sit on it. Under `opts.mirror` (the default, §5.4) column 1
--- renders as the RIGHTMOST cell, i.e. immediately beside the commit message.
--- Only the lane owning the next subject row may enter it; every other lane keeps
--- out, so it never fills up with an unrelated branch.
local GUTTER = 1

--- Does this node own its row's SUBJECT? False for a collapsed head and for a kept
--- junction drawn as a marker (§10.4): the renderer blanks date/author/message for
--- both, so their row's flex column holds ref labels, not a subject. `gutter`
--- (§5.6) keys the gutter lane on subject-owning rows only, so a marker between two
--- trunk commits does not disturb it.
---@param C table?
---@param opts table
---@return boolean
local function owns_subject(C, opts)
    if not C then return false end
    if C.collapsed then return false end
    if C.junction and opts.junction_markers ~= false then return false end
    return true
end

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
---
--- `seed` (optional) pre-populates the sweep's `active` map with lanes crossing
--- in **from above** — the boundary lanes of a context pane (spec §6.2). Each
--- seeded lane keeps its column and its colour (so the pane's seam matches the
--- main view's edge), and its colour slot is reserved so the layout's own newly
--- born lanes never reuse a live seam colour. A seeded lane is an ordinary Lane
--- `{id, color, parent, begin?}`; it draws straight down until its `parent`
--- commit appears in `items` (or off the bottom edge if it never does). Seeding
--- only constrains the sweep **start**, so it pins a footer's top seam exactly;
--- a header's bottom seam needs a different mechanism (see ARCHITECTURE.md).
---@param opts table
---@param items table[]  -- { type, commit } newest-first; commit.parents/children are Commits
---@param seed table<integer, table>?  -- col -> Lane crossing in from above
---@return table[] rows
function M.layout(opts, items, seed)
    local next_id = 0
    local function new_id()
        next_id = next_id + 1
        return next_id
    end

    -- Lane colour is a **palette slot** from a recycling FIFO **free list** seeded
    -- with the curated `palette.tracks` colours (slots 1..ntracks). A born lane
    -- takes the front; an ended lane returns its slot to the back, recycled with a
    -- cooldown so it is not reused immediately. New lanes allocate *before* ended
    -- lanes return their slots, so concurrent lanes never share a colour while
    -- slots last (specification.md §5.5). Phase 2 maps a slot to a colour: <=
    -- ntracks indexes `palette.tracks`, beyond that is a generated OKLCH colour.
    --
    -- Two modes (gated by `palette.generate`, which graph.lua turns off without
    -- truecolor):
    --  * generate: keep at least `buffer` slots free for breathing room — if a
    --    take would drop below it, MINT a generated slot (id > ntracks). A
    --    generated slot is RETIRED (dropped) once the list is comfortably full
    --    again, so a calmed graph drifts back to curated colours.
    --  * no generate: on exhaustion SHARE a curated slot, reference-counted so a
    --    slot returns only when its last holder ends (never handing a live colour
    --    to a new lane).
    local ntracks = (opts.palette and opts.palette.tracks and #opts.palette.tracks) or 8
    local generate = (opts.palette and opts.palette.generate) and true or false
    local buffer = generate and (tonumber(opts.palette.buffer) or 3) or 0
    local clock = 0     -- allocation counter; drives the recycle cooldown
    local nextgen = ntracks -- last minted slot id (generated slots are > ntracks)
    local dup = 0
    local in_use = {}   -- slot -> live holders (only the no-generate share path shares)
    -- FIFO of { slot, ready }: a slot is reusable once `clock >= ready`.
    local free, qhead, qtail = {}, 1, ntracks
    for i = 1, ntracks do in_use[i] = 0; free[i] = { slot = i, ready = 0 } end
    local function fcount() return qtail - qhead + 1 end

    local function alloc_color()
        clock = clock + 1
        -- Reuse the front if it has cooled down; else mint (when generating).
        if qhead <= qtail and free[qhead].ready <= clock then
            local e = free[qhead]
            free[qhead] = nil; qhead = qhead + 1
            in_use[e.slot] = (in_use[e.slot] or 0) + 1
            return e.slot
        end
        if generate then
            nextgen = nextgen + 1
            in_use[nextgen] = 1
            return nextgen
        end
        -- No truecolor and exhausted: share the least-shared curated slot.
        local best
        for off = 0, ntracks - 1 do
            local c = ((dup + off) % ntracks) + 1
            if not best or in_use[c] < in_use[best] then best = c end
        end
        dup = best
        in_use[best] = in_use[best] + 1
        return best
    end

    local function free_color(c)
        if not c then return end
        in_use[c] = (in_use[c] or 0) - 1
        if in_use[c] > 0 then return end -- still held (a shared slot's other holder)
        -- Retire a surplus generated slot rather than recycling it, so quiet
        -- stretches drift back to the curated palette.
        if c > ntracks and fcount() >= ntracks then return end
        qtail = qtail + 1; free[qtail] = { slot = c, ready = clock + buffer }
    end

    local rows = {}
    local active = {} -- col -> Lane flowing down into the current row

    -- Seed the boundary lanes of a context pane (spec §6.2): they flow in from
    -- above in their given columns, keeping their colours. Reserve each seed
    -- colour slot — drop it from the curated free FIFO and bump its in_use — so
    -- the pane's own newly born lanes never reuse a colour live at the seam.
    if seed then
        local reserved = {}
        for col, lane in pairs(seed) do
            active[col] = lane
            reserved[lane.color] = (reserved[lane.color] or 0) + 1
        end
        local kept = {}
        for i = qhead, qtail do
            if not reserved[free[i].slot] then kept[#kept + 1] = free[i] end
        end
        free, qhead, qtail = kept, 1, #kept
        for slot, n in pairs(reserved) do
            in_use[slot] = (in_use[slot] or 0) + n
            if slot > nextgen then nextgen = slot end
        end
    end
    -- Columns a root occupied on the *previous* row. A root ends its lane with
    -- nothing below it, so reusing its column on the next row would stack an
    -- unrelated history under it and read as one continuous lane. We block the
    -- column for one row (tip placement, compaction, and fresh fan-out all skip
    -- it), which offsets the next history and breaks the line; consecutive
    -- stacked roots then simply alternate columns (spec §5.1 "root column break").
    local blocked = {}

    -- A fresh line buffer: `add` appends a Segment, `draw` lays one lane across
    -- columns lo..hi with `up`/`down` at the given columns (the bus connects them).
    local function new_line()
        local cells = {}
        -- A segment drawing one or more edges with explicit connectivity/id. A
        -- multi-edge segment is the shared trunk wire at a fan hub (the single
        -- descent into a merge / ascent out of a split): it lights if *any* of its
        -- edges is in the cone, which is what keeps a non-trunk cone lane connected
        -- through the hub.
        local function add_seg(j, c, edges, id, color)
            cells[j] = cells[j] or {}
            cells[j][#cells[j] + 1] = {
                id = id, color = color, begin = edges[1] and edges[1].begin, parent = edges[1] and edges[1].parent,
                connectivity = conn(c), edges = edges,
            }
        end
        local function add(j, lane, c) add_seg(j, c, { lane }, lane.id, lane.color) end
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
    -- Turn a line's cells into a GraphColumn[]. `commit_col` marks which column
    -- carries the commit marker (nil on a split/merge line).
    local function assemble(cells, commit_col, C)
        local width = 0
        for j in pairs(cells) do if j > width then width = j end end
        if commit_col and commit_col > width then width = commit_col end
        local columns = {}
        for j = 1, width do
            local segs = cells[j] or {}
            columns[j] = {
                connectivity = union_conn(segs),
                lanes = segs,
                has_commit = commit_col ~= nil and j == commit_col,
                commit = (commit_col ~= nil and j == commit_col) and C or nil,
                id = segs[1] and segs[1].id or nil,
                color = segs[1] and segs[1].color or nil,
                begin = segs[1] and segs[1].begin or nil,
                parent = segs[1] and segs[1].parent or nil,
            }
        end
        return columns
    end

    -- CLASSIFY (shell step): read the active lanes into incoming (terminating at C)
    -- and survivors (passing through). A pure read of `active`. `incoming_lanes` /
    -- `survivor_lanes` are the immutable sets the completeness oracle verifies
    -- against (each incoming must terminate, each survivor must carry forward).
    local function classify(state)
        local C = state.commit
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
        state.incoming, state.survivors = incoming, survivors
        local iset, sset = {}, {}
        for _, e in ipairs(incoming) do iset[e.lane] = true end
        for _, e in ipairs(survivors) do sset[e.lane] = true end
        state.incoming_lanes, state.survivor_lanes = iset, sset
    end

    -- SPAWN_LANES (shell step): mint one outgoing Lane per parent, then return the
    -- ended incoming children's colours. Pure lane lifecycle, driven by the DAG and
    -- the row order, NEVER by placement; must run before any later colour alloc so
    -- a slot freed here cannot be reused by a lane born on the same line.
    --
    -- IDENTITY (spec §5). The first parent continues the identity of the incoming
    -- lane that represents the same line of history. Two tiers, both read off the
    -- DAG and the row order — never off a column:
    --
    --  1. Prefer a lane whose child has THIS COMMIT as its FIRST parent: that
    --     child's mainline runs into here, so it is a continuation outright.
    --  2. Otherwise take any incoming lane. A merge's second-parent edge is still a
    --     continuation — it is the merged-in BRANCH, and this commit is that
    --     branch's tip carrying on downward. (Minting a fresh lane here instead
    --     would recolour every merged-in branch tip; the `m -> {a, b}` diamond is
    --     the smallest case that proves it.)
    --
    -- Within whichever tier applies, the most SENIOR wins — the smallest id. Ids are
    -- minted in row order and carried along a whole first-parent chain, so the
    -- smallest is the chain that started highest and a topic forking off a trunk is
    -- always junior to it. Only a genuine tip, with nothing arriving at all, is born.
    --
    -- This used to be "the leftmost incoming lane" — a positional proxy for "the
    -- trunk", true only while the trunk happened to sit leftmost. Where a topic lane
    -- landed left of the trunk, the merge and the whole spine below it were drawn as
    -- the topic. Choosing semantically is also what makes identity **invariant
    -- across layout policies** (§5.6): no column may reach an id or a colour.
    local function spawn_lanes(state)
        local C = state.commit
        local incoming = state.incoming
        local trunk, senior
        for _, e in ipairs(incoming) do
            local child = e.lane.begin
            if child and child.parents and child.parents[1] == C then
                if not trunk or e.lane.id < trunk.id then trunk = e.lane end
            end
            if not senior or e.lane.id < senior.id then senior = e.lane end
        end
        trunk = trunk or senior
        local outgoing = {}
        for i, p in ipairs(C.parents or {}) do
            local id, color
            if i == 1 and trunk then
                id, color = trunk.id, trunk.color
            else
                id, color = new_id(), alloc_color()
            end
            outgoing[#outgoing + 1] = { lane = { id = id, color = color, begin = C, parent = p, highlighted = false } }
        end
        -- Return the colour of every incoming lane that did not continue (all of
        -- them when nothing leaves). Ordered by lane id — row order — because
        -- `free_color` appends to a FIFO, so the ORDER of these returns decides which
        -- colour a later lane receives; taking it from columns would let placement
        -- reach colour through the back door and two policies would diverge (§5.5).
        local ended = {}
        for _, e in ipairs(incoming) do
            if e.lane ~= trunk or #outgoing == 0 then ended[#ended + 1] = e.lane end
        end
        table.sort(ended, function(a, b) return a.id < b.id end)
        for _, lane in ipairs(ended) do free_color(lane.color) end
        state.outgoing = outgoing
        state.trunk_in = trunk
    end

    -- DECIDE_STYLE (shell step): the merge-style flags for this item. A node-less
    -- junction with a *single* fan collapses inline (no separate line); with both
    -- a fork and a merge it follows merge_style like a normal commit (§10.4/§5.1).
    -- sep_split/sep_merge put a fan on its own line; fan_line = the commit line
    -- itself carries a fan (which suppresses compaction). Pure function of
    -- #incoming/#outgoing/opts/C.junction.
    --
    -- `subject` (§5.6) is the same junction test `inline_junction` makes, which is
    -- why it is derived here rather than recomputed downstream. Only the `gutter`
    -- policy reads it; it is inert for every other chain.
    local function decide_style(state)
        local C = state.commit
        local ni, no = #state.incoming, #state.outgoing
        local inline_junction = C.junction and (opts.junction_markers ~= false)
            and not (ni > 1 and no > 1)
        state.subject = owns_subject(C, opts)
        local sep_split = opts.merge_style.split_on_separate_line and ni > 1 and not inline_junction
        local sep_merge = opts.merge_style.merge_on_separate_line and no > 1 and not inline_junction
        local fan_line = (ni > 1 and not sep_split) or (no > 1 and not sep_merge)
        state.inline_junction, state.sep_split, state.sep_merge, state.fan_line =
            inline_junction, sep_split, sep_merge, fan_line
    end

    -- The grid stages build the item on a LIVE column grid stored on `state.g`
    -- ({ cells, draw, occ0, used }): each stage writes segments into it and reads
    -- occupancy back. Occupancy is two reservations. `occ0` = a vertical (a bar /
    -- node / down-going lane) sits in the column; frozen at row start so a column a
    -- lane vacates is not silently reused mid-row. `used` = a **non-shareable**
    -- horizontal occupies it (a survivor's jog, the trunk's jog into the node). A
    -- fan's own bus is NOT reserved — every lane of a fan shares the same commit's
    -- hub, so they overlap freely and only each turn-down endpoint is claimed (as a
    -- vertical). `grid_taken` = neither slot free.
    --
    -- Every stage tests occupancy through this one predicate. `place_commit` and
    -- `slide` run before any stage writes `g.used` (seed_bars creates it empty;
    -- only fan_in / compact / carry / fan_out write it, all of them later in every
    -- chain), so for them the `used` term is provably false and the predicate is
    -- exactly the `occ0 or blocked` test they used to spell out inline.
    local function grid_taken(g, c) return g.occ0[c] or g.used[c] or blocked[c] end

    -- SEED_BARS (stage): open the main line; every survivor enters from above as a
    -- straight vertical bar.
    local function seed_bars(state)
        local cells, draw = new_line()
        local g = { cells = cells, draw = draw, occ0 = {}, used = {} }
        for _, s in ipairs(state.survivors) do
            draw(s.lane, s.col, s.col, s.col, s.col)
            g.occ0[s.col] = true
        end
        state.g = g
    end

    -- PLACE_COMMIT (stage): the commit column cc0 (leftmost incoming, or the
    -- leftmost free column for a tip); reserve the incoming columns; with a separate
    -- split line reduce the fan-in to the trunk (the children's columns stay free
    -- gaps). `cc` starts at cc0; the `slide` stage may move it left.
    local function place_commit(state)
        local g, incoming = state.g, state.incoming
        local cc0
        if #incoming > 0 then
            cc0 = incoming[1].col
        else
            cc0 = 1
            while grid_taken(g, cc0) do cc0 = cc0 + 1 end
        end
        local commit_incoming = incoming
        if state.sep_split then
            commit_incoming = { { col = cc0, lane = incoming[1].lane } }
            g.occ0[cc0] = true
        else
            for _, inc in ipairs(incoming) do g.occ0[inc.col] = true end
        end
        state.cc0, state.cc, state.commit_incoming = cc0, cc0, commit_incoming
    end

    -- EVICT_GUTTER (stage, `gutter` only): the swap-OUT, on a row of its own.
    --
    -- The gutter carries the previous run's chain. When this subject row belongs to
    -- a different lane, that occupant has to leave before this row can use the
    -- column — and it must leave on a **separate row**, because a lane moving out
    -- (left-to-right) and the arriving lane moving in (right-to-left) on one row
    -- would share a horizontal run in opposite directions, which is unreadable
    -- (§5.1 horizontal sharing). So the occupant vacates on a virtual row above this
    -- commit, and `claim_gutter` turns the arriving lane in on the NEXT virtual row.
    --
    -- Exactly one lane moves here, so the row carries one horizontal in one
    -- direction. It runs FIRST in the chain, before `seed_bars` reads the survivor
    -- columns, and patches the survivor's recorded column so every later stage sees
    -- the new position. `state.above` is a LIST, so this row coexists with the claim
    -- row and with the commit's own split fan (§5 Line).
    local function evict_gutter(state)
        if not state.subject or blocked[GUTTER] then return end
        -- our own incoming lane already holds it: nothing to do
        for _, inc in ipairs(state.incoming) do
            if inc.col == GUTTER then return end
        end
        local occ
        for _, s in ipairs(state.survivors) do
            if s.col == GUTTER then occ = s end
        end
        if not occ then return end -- already free

        local taken = {}
        for _, s in ipairs(state.survivors) do taken[s.col] = true end
        for _, inc in ipairs(state.incoming) do taken[inc.col] = true end
        local f = GUTTER + 1
        while taken[f] or blocked[f] do f = f + 1 end

        local cells, draw = new_line()
        for _, s in ipairs(state.survivors) do
            if s == occ then
                draw(s.lane, GUTTER, f, GUTTER, f) -- in at the gutter, out at f
            else
                draw(s.lane, s.col, s.col, s.col, s.col)
            end
        end
        -- the incoming lanes cross this row on their way down to the commit
        for _, inc in ipairs(state.incoming) do
            draw(inc.lane, inc.col, inc.col, inc.col, inc.col)
        end
        state.above[#state.above + 1] = assemble(cells, nil, nil)
        occ.col = f
    end

    -- CLAIM_GUTTER (stage, `gutter` only): the swap-IN, on a row of its own.
    --
    -- The mirror of `evict_gutter`, and for the same reason. A lane turning INTO the
    -- gutter travels right-to-left; this commit's own fan-out travels left-to-right
    -- out of the same cell, and its fan-in converges on it. Sharing the commit Line
    -- with either lays two runs across the same cells in opposite directions — one
    -- glyph, one colour, two wires — which is exactly what makes a handover row
    -- unreadable (§5.6). So the claim gets its own virtual row, on which exactly one
    -- lane moves and nothing else turns; the commit Line below then carries only the
    -- commit's own fan.
    --
    -- WHICH lane turns in: the one whose chain this commit continues (`trunk_in`,
    -- chosen from the DAG in `spawn_lanes` — never from a column, §5). Its outgoing
    -- first parent inherits that id and colour and leaves the node straight down, so
    -- the gutter cell's wire above the node and its wire below it are one Lane and
    -- the run reads as one colour.
    --
    -- Declines when there is nothing to move: a tip (no incoming), one of this
    -- commit's OWN children already in the gutter (then the commit's fan converges
    -- there, which is a fan and legitimately shares its Line), a survivor still
    -- holding it (eviction declined, so `place_gutter` falls back off-gutter), or a
    -- root-blocked gutter (§5.1). Runs after `evict_gutter` and before `seed_bars`,
    -- patching the incoming entry's column so every later stage sees the new one.
    local function claim_gutter(state)
        if not state.subject or blocked[GUTTER] then return end
        local incoming = state.incoming
        if #incoming == 0 then return end
        for _, inc in ipairs(incoming) do
            if inc.col == GUTTER then return end
        end
        for _, s in ipairs(state.survivors) do
            if s.col == GUTTER then return end
        end
        local claimer
        for _, inc in ipairs(incoming) do
            if inc.lane == state.trunk_in then claimer = inc end
        end
        claimer = claimer or incoming[1]

        local cells, draw = new_line()
        for _, s in ipairs(state.survivors) do draw(s.lane, s.col, s.col, s.col, s.col) end
        for _, inc in ipairs(incoming) do
            if inc == claimer then
                -- in at its own column from above, out at the gutter
                draw(inc.lane, GUTTER, inc.col, inc.col, GUTTER)
            else
                draw(inc.lane, inc.col, inc.col, inc.col, inc.col)
            end
        end
        state.above[#state.above + 1] = assemble(cells, nil, nil)
        claimer.col = GUTTER
        -- `incoming` is kept sorted by column (every later stage reads incoming[1] as
        -- the leftmost); the claimer is now in column 1, so it simply moves to front.
        table.sort(incoming, function(a, b) return a.col < b.col end)
    end

    -- PLACE_GUTTER (stage): `place_commit` for the `gutter` policy (§5.6). The
    -- gutter column holds a **LANE**, not a bare node: the lane owning the current
    -- subject row lives there, so its commits' nodes sit on it and a run of commits
    -- on one lane draws a straight vertical with nodes on it and NO horizontal at
    -- all. The gutter changes hands only when the next subject row is on a
    -- different lane.
    --
    -- That handover is deliberately NOT a same-row swap, and it does not ride on a
    -- commit Line at all. Two lanes exchanging columns over one row must both turn
    -- in the gutter cell, which renders `├─┤` — indistinguishable from a fan bus,
    -- and a cell with two different lanes bending in it renders one colour for two
    -- wires (the §5.2 handoff). Putting either move on the commit Line is the same
    -- defect one step out: the move's run and the commit's own fan cross the same
    -- cells in opposite directions. So the handover decomposes into two virtual rows
    -- above the commit, each moving EXACTLY ONE lane (§5.6):
    --
    --   * `evict_gutter` — the occupant leaves the gutter for the nearest free
    --     column to its right;
    --   * `claim_gutter` — the arriving lane (this commit's own chain) turns in.
    --
    -- Each row then carries one horizontal in one direction and nothing else turns
    -- on it, so no two wires ever share a run; the commit Line carries only this
    -- commit's own fan. Only a subject row may claim the gutter, which is what
    -- guarantees it is free when the claim row runs.
    --
    -- Reserving every incoming column in `occ0` is load-bearing, not tidiness: it is
    -- how §5.1's fan-out placement rule ("a column a terminating child frees is
    -- reusable only when that stacks no two turns in one cell") is enforced. Without
    -- it a lane born on this row could take the column an incoming child just
    -- vacated, putting the child's turn and an unrelated lane's turn in one cell —
    -- the §5.2 `allow_merge_on_split` colour handoff, un-sanctioned. `place_commit`
    -- reserves the same columns for the same reason; the trunk reusing its own
    -- child's column is exempt because it keeps that lane's id and colour.
    local function place_gutter(state)
        local g, incoming, outgoing = state.g, state.incoming, state.outgoing
        state.gutter = true
        -- Read BEFORE reserving the incoming columns: `seed_bars` marks only
        -- SURVIVORS, so this is "a lane unrelated to this commit is passing through
        -- the gutter". The claim rule below is designed to make it impossible on a
        -- subject row; the node placement degrades safely if it ever happens.
        local held = g.occ0[GUTTER] and true or false
        for _, inc in ipairs(incoming) do g.occ0[inc.col] = true end

        local function free_lane_col()
            local c = GUTTER + 1
            while grid_taken(g, c) do c = c + 1 end
            return c
        end

        -- NODE. A subject row's node goes in the gutter: its own lane is normally
        -- already there (nothing is drawn), and when it is not, the fan-in turns it
        -- in. A marker or junction (§10.4) keeps its lane column — the rule keys on
        -- subject rows, so a marker between two trunk commits disturbs nothing.
        local cc
        if state.subject and not held and not blocked[GUTTER] then
            cc = GUTTER
        else
            cc = incoming[1] and incoming[1].col or free_lane_col()
        end

        -- CONTINUATION. The gutter belongs to THIS row's own chain: when the node is
        -- in the gutter its first parent continues there, full stop. No other parent
        -- may enter it — that is the whole point. Letting the parent that starts the
        -- merged-in lineage claim the gutter on the MERGE's own row looked free (the
        -- lane is born there, no wire moves) but it put the topic's lane under the
        -- merge's node, and `top_lane` colours a node from the cell's `down` segment,
        -- so the merge rendered as the topic. The handover the lineage needs happens
        -- on its own row instead (`evict_gutter`).
        if outgoing[1] then
            local kt = (cc == GUTTER) and GUTTER or cc
            g.used[kt] = true
            state.kt = kt
        end
        -- No node and nothing continuing here: hold the gutter empty rather than
        -- letting a generic fan-out grab it, so it is free when the next subject
        -- lane turns in.
        if cc ~= GUTTER then g.occ0[GUTTER] = true end

        local commit_incoming = incoming
        if state.sep_split then
            commit_incoming = { { col = cc, lane = incoming[1].lane } }
        end
        state.cc0, state.cc, state.commit_incoming = cc, cc, commit_incoming
    end

    -- SLIDE (stage): compact a *linear* commit leftward through the run of free
    -- columns, stopping at the first occupied column (never crossing a lane). A
    -- no-op on a fan line (the commit shares its line with its fan). The `layout_seam`
    -- strategy omits this stage so a pane's seam row matches the seeded columns.
    local function slide(state)
        if #state.commit_incoming ~= 1 or state.fan_line then return end
        local g, cc = state.g, state.cc
        for c = cc - 1, 1, -1 do
            if grid_taken(g, c) then break end
            cc = c
        end
        state.cc = cc
    end

    -- FAN_IN (stage): the split line above (when the style schedules one); reserve
    -- the commit's own jog so no survivor crosses it; then write the fan-in — the
    -- incoming children converge into the commit column (just the trunk when the
    -- split was separate; the whole fan-in inline, crossing survivors, sharing the
    -- bus) — and the node's first parent continues straight down. Written before the
    -- survivors compact so they see the reserved commit jog.
    local function fan_in(state)
        local g = state.g
        local incoming, survivors, outgoing = state.incoming, state.survivors, state.outgoing
        local cc0, cc, commit_incoming = state.cc0, state.cc, state.commit_incoming
        if state.sep_split then
            local trunk = incoming[1]
            local cells, draw, add_seg = new_line()
            if trunk.col == cc0 then
                -- The node sits on the trunk's own column (every policy but
                -- `gutter`): the trunk enters the hub as a bare up-stub.
                add_seg(cc0, { up = true }, { trunk.lane }, trunk.lane.id, trunk.lane.color)
            else
                -- The node column is elsewhere (the `gutter` policy, §5.6), so the
                -- trunk reaches the hub as a fan arm like every other child.
                draw(trunk.lane, math.min(trunk.col, cc0), math.max(trunk.col, cc0), trunk.col, nil)
            end
            local descent = {}
            for _, inc in ipairs(incoming) do descent[#descent + 1] = inc.lane end
            -- The shared descent is a BUNDLE of every converging edge, and its label
            -- is pinned by per-Lane continuity (§5.1): the commit Line below draws
            -- this same wire as `commit_incoming`'s up-stub, so the two must carry
            -- one id. It is not an identity choice — identity changes at the node,
            -- below this wire — so it stays the arriving trunk's, as it always was.
            add_seg(cc0, { down = true }, descent, trunk.lane.id, trunk.lane.color)
            for i = 2, #incoming do
                local inc = incoming[i]
                draw(inc.lane, math.min(inc.col, cc0), math.max(inc.col, cc0), inc.col, nil)
            end
            for _, s in ipairs(survivors) do draw(s.lane, s.col, s.col, s.col, s.col) end
            state.above[#state.above + 1] = assemble(cells, nil, nil)
        end
        for c = math.min(cc0, cc), math.max(cc0, cc) do g.used[c] = true end
        for _, inc in ipairs(commit_incoming) do
            g.draw(inc.lane, math.min(inc.col, cc), math.max(inc.col, cc), inc.col, nil)
        end
        -- The first parent leaves the node column and turns down in its own lane
        -- column `kt`. `state.kt` is set only by `place_gutter`; everywhere else the
        -- node IS its lane, so `kt == cc` and this is the classic one-cell down stub.
        -- With a separate merge Line the fan happens below, so the commit Line
        -- carries only the stub into the ascent — at the node column either way.
        if outgoing[1] then
            local dk = (state.kt and not state.sep_merge) and state.kt or cc
            g.draw(outgoing[1].lane, math.min(dk, cc), math.max(dk, cc), nil, dk)
        end
    end

    -- COMPACT (stage): each survivor slides into the run of free columns to its
    -- left, stopping at the first taken column (never crossing a lane), redrawn as a
    -- turn; its jog span is reserved in `used`. Suppressed on a fan line, where a
    -- pass-through crosses the fan vertically instead.
    --
    -- CONTRACT of the compaction slot: whatever stage occupies it (compact, carry,
    -- or a future one) MUST set `s.out` — the survivor's column after this row — for
    -- EVERY survivor, because `fan_out` reads it to advance `active`. Leave one nil
    -- and that lane silently vanishes from the next row (complete_check catches it,
    -- but only on the row after the mistake).
    local function compact(state)
        local g = state.g
        for _, s in ipairs(state.survivors) do
            local k = s.col
            if not state.fan_line then
                for c = s.col - 1, 1, -1 do
                    if grid_taken(g, c) then break end
                    k = c
                end
            end
            if k ~= s.col then
                g.cells[s.col] = nil
                g.draw(s.lane, k, s.col, s.col, k)
            end
            for c = k, s.col do g.used[c] = true end
            s.out = k
        end
    end

    -- CARRY (stage): the seam variant of `compact` — every survivor stays in its
    -- column (no leftward search) so the seam row matches the seeded boundary
    -- exactly. Used by `layout_seam`.
    local function carry(state)
        local g = state.g
        for _, s in ipairs(state.survivors) do
            s.out = s.col
            g.used[s.col] = true
        end
    end

    -- FAN_OUT (stage): the first parent continues at the commit column; each extra
    -- parent takes the leftmost free column, reusing a terminating child's freed
    -- column first when that stacks no two-turn cell (allow_merge_on_split, or a
    -- separate merge line below). Only the endpoint is claimed (the parents share
    -- the diverging bus). Inline parents draw here; a separate merge line draws them
    -- below. Then advance active/blocked for the next row.
    local function fan_out(state)
        local g = state.g
        local survivors, outgoing = state.survivors, state.outgoing
        local cc, commit_incoming, sep_merge = state.cc, state.commit_incoming, state.sep_merge
        -- The first parent's column. `state.kt` is the `gutter` policy's trunk
        -- column (§5.6), where the node is NOT on its own lane; nil everywhere else,
        -- so `kt == cc` and every expression below is the classic one.
        local kt = state.kt or cc
        local freed = {}
        if opts.merge_style.allow_merge_on_split or sep_merge then
            for i = 2, #commit_incoming do
                local c = commit_incoming[i].col
                -- `gutter` (§5.6): the gutter is entered only by the lane owning the
                -- next subject row, never by a fan-out reclaiming a freed column.
                if not (state.gutter and c == GUTTER) then freed[#freed + 1] = c end
            end
        end
        if outgoing[1] then outgoing[1].out = kt end
        local fi = 1
        for i = 2, #outgoing do
            -- `place_gutter` may have pinned this parent to the gutter already; every
            -- other policy leaves `out` unset here, so the generic placement runs.
            local k = outgoing[i].out
            if not k then
                if fi <= #freed then
                    k = freed[fi]; fi = fi + 1
                else
                    k = 1
                    while grid_taken(g, k) do k = k + 1 end
                end
                outgoing[i].out = k
                g.used[k] = true
            end
            if not sep_merge then
                g.draw(outgoing[i].lane, math.min(k, cc), math.max(k, cc), nil, k)
            end
        end

        -- MERGE LINE (below): the first parent continues at the commit column; the
        -- shared ascent carries every parent; the extra parents fan out. Survivors
        -- pass through at their compacted column.
        if sep_merge then
            local mcells, mdraw, madd = new_line()
            for _, s in ipairs(survivors) do mdraw(s.lane, s.out, s.out, s.out, s.out) end
            if outgoing[1] then
                local ascent = {}
                for _, o in ipairs(outgoing) do ascent[#ascent + 1] = o.lane end
                madd(cc, { up = true }, ascent, outgoing[1].lane.id, outgoing[1].lane.color)
                if kt == cc then
                    madd(cc, { down = true }, { outgoing[1].lane }, outgoing[1].lane.id, outgoing[1].lane.color)
                else
                    -- `gutter`: the first parent leaves the node column too, so it
                    -- fans out to `kt` like the extra parents rather than dropping
                    -- straight down out of the hub.
                    mdraw(outgoing[1].lane, math.min(kt, cc), math.max(kt, cc), nil, kt)
                end
            end
            for i = 2, #outgoing do
                local o = outgoing[i]
                mdraw(o.lane, math.min(o.out, cc), math.max(o.out, cc), nil, o.out)
            end
            state.below[#state.below + 1] = assemble(mcells, nil, nil)
        end

        -- Advance active / blocked for the next row (a root's column is blocked for
        -- one row so nothing stacks under it).
        active = {}
        for _, s in ipairs(survivors) do active[s.out] = s.lane end
        if outgoing[1] then active[kt] = outgoing[1].lane end
        for i = 2, #outgoing do active[outgoing[i].out] = outgoing[i].lane end
        blocked = {}
        if #outgoing == 0 then blocked[state.cc] = true end
    end

    -- FINALIZE (stage): assemble the main line from the grid, build the OrderItem
    -- (above/columns/merge + parent/child lanes), and discharge the ledger.
    --
    -- `above` is a LIST of virtual lines, topmost first — the order the stages
    -- appended them, which is the order they render (§5 Line). The merge style
    -- contributes at most one (the split fan); `gutter` adds its eviction and claim
    -- rows above it.
    local function finalize(state)
        local C = state.commit
        local main = assemble(state.g.cells, state.cc, C)
        local row = {
            type = state.item.type or "commit",
            commit = C,
            parent_lanes = {},
            child_lanes = {},
            above = state.above,
            columns = main,
            merge = state.below[1],
        }
        for _, o in ipairs(state.outgoing) do row.parent_lanes[#row.parent_lanes + 1] = o.lane end
        for _, inc in ipairs(state.incoming) do row.child_lanes[#row.child_lanes + 1] = inc.lane end
        state.row = row
        state.main = main
        state.outgoing_lanes = {}
        for _, o in ipairs(state.outgoing) do state.outgoing_lanes[#state.outgoing_lanes + 1] = o.lane end
    end

    -- A layout STRATEGY is just a function that chains the grid stages in order,
    -- each called once. A different strategy reorders / swaps / adds stages (or adds
    -- its own control flow, if one is ever needed) — that is the layout-strategy
    -- seam. No generic runner: the sequence is the algorithm.
    --
    -- `layout_compact` is the main view and a pane's body rows. `layout_seam` is a
    -- pane's boundary (seam) row: it omits `slide` and swaps `compact` for `carry`,
    -- so the seam's columns equal the seeded boundary exactly and the pane meets the
    -- main view without a jog. That is the footer's one layout-level special rule,
    -- expressed as a strategy rather than a per-row "is this the seam?" flag threaded
    -- through the shared stages.
    local function layout_compact(state)
        seed_bars(state)
        place_commit(state)
        slide(state)
        fan_in(state)
        compact(state)
        fan_out(state)
        finalize(state)
    end
    local function layout_survivors(state)
        seed_bars(state)
        place_commit(state)
        fan_in(state)
        compact(state)
        fan_out(state)
        finalize(state)
    end
    local function layout_linear(state)
        seed_bars(state)
        place_commit(state)
        slide(state)
        fan_in(state)
        carry(state)
        fan_out(state)
        finalize(state)
    end
    local function layout_seam(state)
        seed_bars(state)
        place_commit(state)
        fan_in(state)
        carry(state)
        fan_out(state)
        finalize(state)
    end
    -- `layout_gutter` is `layout_seam`'s chain with `place_gutter` in place of
    -- `place_commit`: no slide, no survivor compaction — a gutter graph moves no
    -- lane at all — plus the one column constraint, that the lane owning the current
    -- subject row is held in the gutter. `carry` (not `compact`) is what makes
    -- "lanes never move" true, so the seam requirement (§5.6) is met by the body
    -- chain itself and this is also the policy's seam.
    -- A context pane's SEAM row must keep every seeded lane in its seeded column
    -- (§5.6), so it can neither evict nor claim: the pane's top edge has to
    -- reproduce the main view's exactly. Everything else about the gutter applies —
    -- including `fan_in`'s "the node column is elsewhere" arm, which is reachable
    -- only from here now that the body chain claims the gutter first.
    local function layout_gutter_seam(state)
        seed_bars(state)
        place_gutter(state)
        fan_in(state)
        carry(state)
        fan_out(state)
        finalize(state)
    end
    local function layout_gutter(state)
        evict_gutter(state)
        claim_gutter(state)
        seed_bars(state)
        place_gutter(state)
        fan_in(state)
        carry(state)
        fan_out(state)
        finalize(state)
    end

    -- A layout POLICY (spec §5.6) pairs the chain for an ordinary row with the one
    -- for a seeded pane's seam row. The seam must keep every seeded lane in its
    -- column, which is exactly what the no-move chain does — so `seam` is
    -- `layout_seam` for four of the five policies; the field exists so a policy that
    -- needs a different seam can say so, and so the sweep's selection stays one
    -- expression. `straight` IS the no-move chain, so it reuses `layout_seam`
    -- verbatim rather than duplicating it: the equivalence holds by construction.
    -- `gutter` is the one policy that must NOT take `layout_seam` as its seam: that
    -- chain would put the seam row's node back on its lane, so the pane's first row
    -- would disagree with the body about where nodes live. Its body chain already
    -- satisfies the seam requirement (it moves no lane), so it is its own seam.
    ---@class LayoutPolicy
    ---@field body fun(state: table)  -- an ordinary row
    ---@field seam fun(state: table)  -- a seeded pane's boundary (seam) row
    ---@field prepass? fun(opts: table, items: table[]): any  -- a once-per-sweep pass
    ---   computing forward hints the sweep cannot (it runs top-to-bottom). Its return
    ---   value is threaded onto each row's `state.pre`, indexed by `state.index`, so
    ---   nothing is written onto the caller's `items`. NO policy uses it today —
    ---   `gutter` did (the next subject-owning commit, so a fan-out could hand the
    ---   gutter over early), but that is the very move §5.6's identity rule forbids,
    ---   and its handover rows need only what the current row already knows. Kept for
    ---   the reserved `interval` placement (§5.6), which needs lane lifespans.
    ---@type table<string, LayoutPolicy>
    local POLICY = {
        compact   = { body = layout_compact,   seam = layout_seam },
        survivors = { body = layout_survivors, seam = layout_seam },
        linear    = { body = layout_linear,    seam = layout_seam },
        straight  = { body = layout_seam,      seam = layout_seam },
        gutter    = { body = layout_gutter,    seam = layout_gutter_seam },
    }

    local function active_contains(lane)
        for _, l in pairs(active) do
            if l == lane then return true end
        end
        return false
    end

    -- Structural oracle (spec: "check that everything has been handled"): the
    -- emitted lines actually realise every obligation. Independent of the ledger
    -- flags the stages flip — it reads the output, like the test invariants — and
    -- errors on any violation.
    local function complete_check(state)
        local C = state.commit
        local hash = tostring(C.hash)
        local sections = {}
        for _, l in ipairs(state.above) do sections[#sections + 1] = l end
        if state.main then sections[#sections + 1] = state.main end
        for _, l in ipairs(state.below) do sections[#sections + 1] = l end

        local nodes, on_main, drawn = 0, false, {}
        for _, line in ipairs(sections) do
            for _, col in ipairs(line) do
                if col.has_commit then
                    nodes = nodes + 1
                    if col.commit ~= C then
                        error(("gitloom layout: commit %s node carries the wrong commit"):format(hash))
                    end
                    if line == state.main then on_main = true end
                end
                for _, seg in ipairs(col.lanes or {}) do
                    for _, e in ipairs(seg.edges or {}) do drawn[e] = true end
                end
            end
        end
        if nodes ~= 1 then
            error(("gitloom layout: commit %s placed %d times, expected 1"):format(hash, nodes))
        end
        if not on_main then
            error(("gitloom layout: commit %s node is not on the main line"):format(hash))
        end
        for lane in pairs(state.incoming_lanes) do
            if not drawn[lane] then
                error(("gitloom layout: commit %s has an undrawn incoming edge"):format(hash))
            end
            if active_contains(lane) then
                error(("gitloom layout: commit %s left an incoming edge unterminated"):format(hash))
            end
        end
        for lane in pairs(state.survivor_lanes) do
            if not drawn[lane] then
                error(("gitloom layout: commit %s has an undrawn survivor"):format(hash))
            end
            if not active_contains(lane) then
                error(("gitloom layout: commit %s dropped a survivor"):format(hash))
            end
        end
        for _, lane in ipairs(state.outgoing_lanes) do
            if not drawn[lane] then
                error(("gitloom layout: commit %s has an undrawn outgoing edge"):format(hash))
            end
            if not active_contains(lane) then
                error(("gitloom layout: commit %s did not carry an outgoing edge forward"):format(hash))
            end
        end
        if #state.outgoing_lanes ~= #(C.parents or {}) then
            error(("gitloom layout: commit %s emitted %d outgoing edges, expected %d")
                :format(hash, #state.outgoing_lanes, #(C.parents or {})))
        end
    end

    -- Lay out one item: shell setup, run the given strategy, verify, keep the row.
    local function run_item(item, index, pre, strategy)
        local state = {
            item = item, commit = item.commit, above = {}, below = {},
            index = index, pre = pre, next_subject = pre and pre[index] or nil,
        }
        classify(state)
        spawn_lanes(state)
        decide_style(state)
        strategy(state)
        complete_check(state)
        rows[#rows + 1] = state.row
    end

    -- A seeded sweep is a context pane: its first row is the seam, laid out so it
    -- meets the main view without a jog (`policy.seam`). Every other row — and the
    -- whole main view — uses the policy's body chain. An unknown or absent
    -- `layout_policy` falls back to `compact`: this comes from user config, so it
    -- must never error.
    local policy = POLICY[opts.layout_policy] or POLICY.compact
    local pre = policy.prepass and policy.prepass(opts, items) or nil
    for i, item in ipairs(items) do
        run_item(item, i, pre, (seed and i == 1) and policy.seam or policy.body)
    end

    return rows
end

return M
