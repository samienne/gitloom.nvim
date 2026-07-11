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
--- **Staged driver (in progress).** `M.layout` runs each item through a list of
--- `stage(state) -> state` steps until an obligation ledger (commit placed; every
--- incoming, outgoing, and survivor lane handled) is empty; a pass that makes no
--- progress errors (the loop guard), and a structural oracle then verifies the
--- emitted lines realise the ledger. Today the list is one `legacy_place` stage
--- carrying the whole algorithm; it is peeled apart over time. See ARCHITECTURE.md
--- ("Layout as a staged pipeline").
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

    -- The first row is a context pane's **seam** when seeding (spec §6.2): its
    -- columns must equal the seeded ones exactly so the pane meets the main view
    -- without a jog, so no compaction runs on it. (Without a seed it is just the
    -- newest row, compacted normally.)
    local first_row = true

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

    -- CLASSIFY (shell stage): read the active lanes into incoming/survivors and
    -- seed this item's obligation ledger. A pure read of `active`.
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
        local led = { commit_placed = false, incoming = {}, survivors = {}, outgoing = {} }
        local iset, sset = {}, {}
        for _, e in ipairs(incoming) do led.incoming[e.lane] = true; iset[e.lane] = true end
        for _, e in ipairs(survivors) do led.survivors[e.lane] = true; sset[e.lane] = true end
        for i = 1, #(C.parents or {}) do led.outgoing[i] = true end
        state.ledger, state.incoming_lanes, state.survivor_lanes = led, iset, sset
    end

    -- SPAWN_LANES (shell step): mint one outgoing Lane per parent — the first
    -- parent reuses the trunk child's id + colour (a straight chain keeps one
    -- colour), every other lane is born with a fresh id + free-list slot — then
    -- return the ended incoming children's colours. Pure lane lifecycle, driven
    -- by the DAG, never by placement; must run before any later colour alloc so
    -- a slot freed here cannot be reused by a lane born on the same line.
    local function spawn_lanes(state)
        local C = state.commit
        local incoming = state.incoming
        local trunk_id = incoming[1] and incoming[1].lane.id
        local trunk_color = incoming[1] and incoming[1].lane.color
        local outgoing = {}
        for i, p in ipairs(C.parents or {}) do
            local id = (i == 1 and trunk_id) or new_id()
            local color = (i == 1 and trunk_color) or alloc_color()
            outgoing[#outgoing + 1] = { lane = { id = id, color = color, begin = C, parent = p, highlighted = false } }
        end
        for i = 2, #incoming do free_color(incoming[i].lane.color) end
        if #incoming > 0 and #outgoing == 0 then free_color(incoming[1].lane.color) end
        state.outgoing = outgoing
    end

    -- LEGACY_PLACE (stage): the entire current per-item placement + emission,
    -- wrapped as a single stage. It is peeled apart incrementally into the
    -- smaller stages described in ARCHITECTURE.md ("Layout as a staged
    -- pipeline"); until then it discharges the whole ledger in one pass.
    local function legacy_place(state)
        local item = state.item
        local C = state.commit
        local incoming, survivors = state.incoming, state.survivors
        local outgoing = state.outgoing

        -- The commit sits where its leftmost child arrives, or the leftmost free
        -- column for a tip.
        local cc
        if #incoming > 0 then
            cc = incoming[1].col
        else
            cc = 1
            while active[cc] or blocked[cc] do cc = cc + 1 end
        end

        local row = {
            type = item.type or "commit",
            commit = C,
            parent_lanes = {},
            child_lanes = {},
        }
        for _, o in ipairs(outgoing) do row.parent_lanes[#row.parent_lanes + 1] = o.lane end
        for _, inc in ipairs(incoming) do row.child_lanes[#row.child_lanes + 1] = inc.lane end

        -- A node-less junction (spec §10.4) carries no message, so a *single* fan
        -- needs no separate line — render it inline so the join is one row, not a
        -- fan line plus an empty lane row. The exception is a junction that is
        -- **both** a fork (≥2 children) and a merge (≥2 parents): collapsing both
        -- funnels onto one Line would lay two independent fans across it, which
        -- §5.1 forbids (two separated lanes share a horizontal only at a *single*
        -- fan). So it follows `merge_style` like a normal commit — its fan-in goes
        -- to a split Line above — keeping the two funnels on separate Lines.
        local inline_junction = C.junction and (opts.junction_markers ~= false)
            and not (#incoming > 1 and #outgoing > 1)
        local sep_split = opts.merge_style.split_on_separate_line and #incoming > 1 and not inline_junction
        local sep_merge = opts.merge_style.merge_on_separate_line and #outgoing > 1 and not inline_junction

        -- Does the commit Line itself carry a fan? An *inline* split (≥2 children
        -- converging) or merge (≥2 parents diverging) shares the commit Line with
        -- the survivors. On such a Line a pass-through lane must cross the fan
        -- **vertically** — never compact horizontally along it — since two
        -- separated lanes may share a horizontal only at a fan they belong to. So
        -- all compaction (the linear-commit slide and the survivor shift) is
        -- suppressed on a fan Line; only the fan's own lanes draw the horizontal.
        local fan_line = (#incoming > 1 and not sep_split)
            or (#outgoing > 1 and not sep_merge)

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
            add_seg(cc, { up = true }, { trunk.lane }, trunk.lane.id, trunk.lane.color)
            local descent = {}
            for _, inc in ipairs(incoming) do descent[#descent + 1] = inc.lane end
            add_seg(cc, { down = true }, descent, trunk.lane.id, trunk.lane.color)
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

        -- A compaction jog must not **cross** another lane: once two lanes have
        -- separated they never re-share a horizontal except at a commit's own fan
        -- (the split/merge funnel). So a lane compacts left only through a run of
        -- columns free since row start, stopping at the first occupied column —
        -- never reaching past it into a farther gap (which would lay its horizontal
        -- across the occupant). `used` tracks the columns each placed lane's wire
        -- spans this row, so a later lane neither lands on nor jogs across them.

        -- Compact a *linear* commit (reached by a single child-lane) leftward: the
        -- incoming lane turns into the nearest reachable column and continues there.
        -- A branch born one column out otherwise stays stranded next to an empty
        -- column for its whole length (the gap that bounces a mirrored graph). The
        -- lane's single jog is a turn, not a straight run, so id-continuity holds.
        -- Suppressed on a fan Line: the trunk's jog must not run along the merge
        -- fan it shares the Line with.
        if #incoming == 1 and not (first_row and seed) and not fan_line then
            for c = cc - 1, 1, -1 do
                if occ0[c] or blocked[c] then break end
                cc = c
            end
        end

        -- Reserve the commit's horizontal extent (its incoming jog span) before the
        -- survivors compact, so none of them jogs across it.
        local used = {}
        do
            local a = (incoming[1] and incoming[1].col) or cc
            for c = math.min(a, cc), math.max(a, cc) do used[c] = true end
        end

        -- Gentle left compaction of survivors: each shifts into the clear run of
        -- gaps immediately to its left (a horizontal turn), else stays put. It stops
        -- at the first occupied/used column rather than crossing it. A gap behind an
        -- occupied lane is reclaimed on a later row once that lane moves (a ripple).
        -- Suppressed on a fan Line: a pass-through lane crosses the fan vertically,
        -- it does not compact along it.
        for _, s in ipairs(survivors) do
            local k = s.col
            if not (first_row and seed) and not fan_line then
                for c = s.col - 1, 1, -1 do
                    if occ0[c] or used[c] or blocked[c] then break end
                    k = c
                end
            end
            for c = k, s.col do used[c] = true end -- reserve the whole jog span
            s.out = k
        end

        -- Outgoing columns: the first parent continues at the commit column; each
        -- extra parent takes the leftmost column free *since before this row* — an
        -- interior gap an earlier branch vacated — so a staircase of sequential
        -- merges stays narrow instead of growing a fresh rightmost column every
        -- time. A gap is "free since before this row" = not occupied at row start
        -- (`occ0`) and not taken by a survivor/earlier parent (`used`); skipping
        -- `occ0` is what keeps a column a *terminating child* frees on THIS row out
        -- of reach — reusing that is the same-row two-turn handoff, gated behind
        -- allow_merge_on_split, which lists those columns in `freed` to take first.
        -- A terminating child's column is reusable by an outgoing parent when the
        -- reuse does not put two turns in one cell: under allow_merge_on_split (the
        -- sanctioned inline two-turn cell), or whenever the fan-out lands on a
        -- *separate* merge line below — there the child already ended on the commit
        -- line above, so the column is genuinely free and the parent just starts
        -- fresh in it (no same-cell handoff). Reusing it keeps the merge compact
        -- instead of leaving the freed column an empty gap (the bounce under a
        -- right-aligned mirror, where varying width shifts the whole graph).
        local freed = {}
        if opts.merge_style.allow_merge_on_split or sep_merge then
            for i = 2, #incoming do freed[#freed + 1] = incoming[i].col end
        end
        if outgoing[1] then outgoing[1].out = cc end
        local fi = 1
        for i = 2, #outgoing do
            local k
            if fi <= #freed then
                k = freed[fi]; fi = fi + 1
            else
                k = 1
                while occ0[k] or used[k] or blocked[k] do k = k + 1 end
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
        row.columns = assemble(cells, cc, C)

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
                madd(cc, { up = true }, ascent, outgoing[1].lane.id, outgoing[1].lane.color)
                madd(cc, { down = true }, { outgoing[1].lane }, outgoing[1].lane.id, outgoing[1].lane.color)
            end
            for i = 2, #outgoing do
                local o = outgoing[i]
                mdraw(o.lane, math.min(o.out, cc), math.max(o.out, cc), nil, o.out)
            end
            row.merge = assemble(mcells, nil, nil)
            for i = 2, #outgoing do active[outgoing[i].out] = outgoing[i].lane end
        end

        -- Block this commit's column for the next row iff it is a root (no
        -- parents continue out of it), so nothing stacks under it.
        blocked = {}
        if #outgoing == 0 then blocked[cc] = true end

        first_row = false

        -- Record the emitted sections and the born outgoing lanes, then mark
        -- every obligation discharged: this single stage handled the whole item.
        state.main = row.columns
        state.above = row.split and { row.split } or {}
        state.below = row.merge and { row.merge } or {}
        state.row = row
        state.outgoing_lanes = {}
        for _, o in ipairs(outgoing) do
            state.outgoing_lanes[#state.outgoing_lanes + 1] = o.lane
        end
        state.ledger.commit_placed = true
        state.ledger.incoming, state.ledger.survivors, state.ledger.outgoing = {}, {}, {}
    end

    -- The stage list. Today a single stage; peeled apart over time.
    local stages = { legacy_place }

    local function active_contains(lane)
        for _, l in pairs(active) do
            if l == lane then return true end
        end
        return false
    end

    local function open_count(led)
        local n = led.commit_placed and 0 or 1
        for _ in pairs(led.incoming) do n = n + 1 end
        for _ in pairs(led.survivors) do n = n + 1 end
        for _ in pairs(led.outgoing) do n = n + 1 end
        return n
    end

    local function line_count(state)
        return #state.above + (state.main and 1 or 0) + #state.below
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

    -- Driver: run the stage list until the ledger is empty. Loop guard — a full
    -- pass that discharges no obligation AND appends no line means the item cannot
    -- be completed, so error rather than spin. Then the oracle verifies the
    -- emitted lines realise the obligations.
    local function run_item(item)
        local state = { item = item, commit = item.commit, above = {}, below = {} }
        classify(state)
        spawn_lanes(state)
        local hash = tostring(state.commit.hash)
        local budget = #state.incoming + #state.survivors
            + #(state.commit.parents or {}) + 8
        local passes = 0
        while open_count(state.ledger) > 0 do
            local before_open = open_count(state.ledger)
            local before_lines = line_count(state)
            for _, stage in ipairs(stages) do stage(state) end
            passes = passes + 1
            if open_count(state.ledger) >= before_open and line_count(state) == before_lines then
                error(("gitloom layout: commit %s could not be fully handled"):format(hash))
            end
            if passes > budget then
                error(("gitloom layout: commit %s exceeded the layout pass budget"):format(hash))
            end
        end
        complete_check(state)
        rows[#rows + 1] = state.row
    end

    for _, item in ipairs(items) do
        run_item(item)
    end

    return rows
end

return M
