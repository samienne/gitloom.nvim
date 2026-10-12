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
--- stages (`evict_gutter`, `claim_gutter`, `place_gutter`) plus a `prepass`, and
--- touches the shared ones only through `state.gutter` / `state.cont` — both nil,
--- and therefore inert, under every other policy. It is also the only one that
--- varies the *seam* chain (it is its own seam; see `POLICY` below).
---
--- A row renders as `[above…] columns [merge]`: `above` is a LIST of virtual lines
--- (the split fan, plus `gutter`'s handover rows), topmost first (§5 Line).
local M = {}

--- **For tests only** — not configuration and not part of the API.
--- `handover_column = false` disables §5.6's handover column, so a test can compare
--- the `gutter` layout with and without it (the fixture's eviction column, and the
--- claim that it leaves the focused projection and every other policy untouched).
M._internal = { handover_column = true }

--- The `gutter` policy's fixed node column (spec §5.6). Model column 1 is the
--- gutter: the **lane** that owns the current subject row lives there, so its
--- commits' nodes sit on it. Under `opts.mirror` (the default, §5.4) column 1
--- renders as the RIGHTMOST cell, i.e. immediately beside the commit message.
--- Only the lane owning the next subject row may enter it; every other lane keeps
--- out, so it never fills up with an unrelated branch.
local GUTTER = 1

-- Rows swept between calls to a sweep's optional `yield` hook (the async reflow,
-- spec §10.5). A row on a wide `--all` graph is ~100 drawn cells, so this is a
-- few milliseconds of work per slice — small enough that a keypress is never
-- waiting long, large enough that the driver's overhead stays invisible.
local YIELD_ROWS = 64

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

--- A ref's id: its key in `repo.refs` (`git.add_ref`) — the ref name, except the
--- `head` ref, which is keyed `HEAD`. `opts.pin_rank` is keyed by exactly these.
---@param ref Ref
---@return string
local function ref_id(ref)
    return ref.kind == "head" and "HEAD" or ref.name
end

--- A commit's **pin rank** (spec §5 "Lane identity"): the best (smallest) rank in
--- `pin_rank` among the refs pointing at it, or nil when none of them is pinned.
--- Works on a Commit and on a projected DisplayNode alike — a node reads its
--- commit's `refs` through its metatable, and a collapsed head (§10.3) carries every
--- member's refs, so a head is ranked by the best pinned ref anywhere in its region.
--- An attached `HEAD` ref is keyed `HEAD`, which the pin list never holds while HEAD
--- is attached (§10.6), so it ranks nothing; a detached one does when pinned.
---@param commit table               a Commit or DisplayNode
---@param pin_rank table<string, integer>?  ref id → rank (1 = highest priority)
---@return integer?
function M.commit_rank(commit, pin_rank)
    if not pin_rank or not commit then return nil end
    local best
    for _, ref in ipairs(commit.refs or {}) do
        local r = pin_rank[ref_id(ref)]
        if r and (not best or r < best) then best = r end
    end
    return best
end

--- The **pinned colours** (spec §5.5): slot → rank for every rank in `pin_rank` that
--- owns a curated slot. Rank `k` owns slot `k` of `palette.tracks` — the list every
--- lane draws from — so the map is the identity on its keys; it is a set with the
--- cap applied. A rank past the curated palette (`k > ntracks`) owns nothing and its
--- lane takes a free-list colour. Pure, and a function of the ranks alone, so the
--- pinned colours never depend on a column, a row or a layout policy. The header
--- pane (§6.2) reads it too, to keep its colour de-collision off these slots.
---@param pin_rank table<string, integer>?  ref id → rank (1 = highest priority)
---@param ntracks integer                   the curated palette's size
---@return table<integer, integer>          slot → rank (empty when nothing is pinned)
function M.pinned_slots(pin_rank, ntracks)
    local out = {}
    for _, k in pairs(pin_rank or {}) do
        if type(k) == "number" and k >= 1 and k <= ntracks and k == math.floor(k) then
            out[k] = k
        end
    end
    return out
end

--- Is rank `a` strictly better than rank `b`? Smaller is better; nil (unranked) is
--- worse than every rank, so two unranked lanes tie.
---@param a integer?
---@param b integer?
---@return boolean
local function rank_better(a, b)
    return a ~= nil and (b == nil or a < b)
end

--- A lane's **counterpart rank** (§5 tier 0, §5.5 "Counterpart colours"): `k` for a
--- counterpart lane, whose colour is slot `k`'s counterpart variant `-k`; nil for any
--- other lane. Read off the colour, which every continuation (and a footer seed,
--- §6.2) carries unchanged, so it needs no field of its own.
---@param lane table
---@return integer?
local function cp_rank(lane)
    local c = lane.color
    return (c and c < 0) and -c or nil
end
M.cp_rank = cp_rank

--- Does this incoming Lane arrive as its child's FIRST-parent edge (§5 tier 1)?
---@param lane table
---@param C table  the commit it terminates at
---@return boolean
local function continues_into(lane, C)
    local child = lane.begin
    return (child and child.parents and child.parents[1] == C) and true or false
end

--- The `gutter` policy's `prepass` (spec §5.6): the two forward facts the
--- top-to-bottom sweep cannot see for itself, both pure functions of `(opts, items)`.
---
---   * `pre[i]`      — the hash of the next **subject-owning** commit BELOW row `i`
---                     (nil past the last one). `run_item` threads it onto
---                     `state.next_subject`, so a row can ask "who reads the gutter
---                     after me?".
---   * `pre.row[h]`  — each commit's row index, so "which of my parents comes first"
---                     is answerable at the merge.
---   * `pre.kids[h]` — how many **in-set** children a commit has, so "is this merge
---                     its only child?" is too. Counted over the projected item list,
---                     not `commit.children`, because a projection drops and re-points
---                     edges (§10.3) and only the in-set ones become Lanes.
---
--- Together they are exactly the parent-swap gate's three clauses (`gutter_swap`).
--- Nothing is written back onto the caller's `items`.
---@param opts table
---@param items table[]
---@return table
local function gutter_prepass(opts, items)
    local pre = { row = {}, kids = {} }
    for i, it in ipairs(items) do pre.row[it.commit.hash] = i end
    for _, it in ipairs(items) do
        for _, p in ipairs(it.commit.parents or {}) do
            if pre.row[p.hash] then pre.kids[p.hash] = (pre.kids[p.hash] or 0) + 1 end
        end
    end
    local ahead = nil
    for i = #items, 1, -1 do
        pre[i] = ahead
        if owns_subject(items[i].commit, opts) then ahead = items[i].commit.hash end
    end
    return pre
end

--- The `gutter` merge-swap GATE (spec §5.6), as a pure predicate: which outgoing entry
--- (if any) may take the gutter instead of the first parent. Extracted from
--- `gutter_swap` because the SPLIT swap has to consult it too — a commit that both forks
--- and merges can satisfy both gates, and the precedence between them is decided on the
--- eviction row, before `gutter_swap` runs (see `split_swap`). Reads nothing but the
--- lane/DAG facts already on `state`, so asking twice is free of side effects.
---
--- THREE CLAUSES AND ALL THREE ARE REQUIRED; the reasoning for each is on `gutter_swap`.
---@param state table
---@return integer? index  -- the outgoing entry that may continue in the gutter
local function merge_swap_index(state)
    if not state.subject then return nil end
    -- CLAUSE 0: not where a pinned lane is BORN (§5). There the first parent is the
    -- newborn pinned lane, and the node must read in its colour; a swap would put a
    -- non-first parent below the node and an ending lane above it — the commit's own
    -- lane on neither side. Declining also leaves the split swap free to keep a
    -- converging child in the gutter, so the birth pays no handover Line at all.
    if state.pin_birth then return nil end
    local outgoing, pre = state.outgoing, state.pre
    if not pre or #outgoing < 2 then return nil end
    local p1 = outgoing[1].lane.parent
    local r1 = p1 and pre.row[p1.hash]
    if not r1 then return nil end
    -- CLAUSE 1: the earliest-arriving parent, which for a two-parent merge is just
    -- `row(p2) < row(p1)`; an octopus merge generalises to "the earliest of them".
    local bi, br
    for i = 2, #outgoing do
        local p = outgoing[i].lane.parent
        local ri = p and pre.row[p.hash]
        if ri and (not br or ri < br) then bi, br = i, ri end
    end
    if not bi or br >= r1 then return nil end
    -- CLAUSE 2: ... and that parent is the one that owns the next subject row, so the
    -- gutter it is handed is the gutter that row was going to ask for.
    local pk = outgoing[bi].lane.parent
    if not pk or state.next_subject ~= pk.hash then return nil end
    -- CLAUSE 3: ... and that row will continue on THIS lane, which is assured exactly
    -- when this merge is its only in-set child: one arriving Lane, so it is the one
    -- continued (§5). Otherwise a senior sibling Lane wins, ours is evicted anyway, and
    -- the break buys nothing.
    if (pre.kids[pk.hash] or 0) ~= 1 then return nil end
    return bi
end

--- SPLIT_SWAP (`gutter` only, spec §5.6): the mirror of `gutter_swap` (below) at a
--- **fork**. The gutter is held by a lane that is one of THIS commit's converging
--- children but is not the one its first parent continues (§5 identity). Today's
--- layout transposes the two — an eviction row moves the occupant out, a claim row
--- turns the continuation in — for the sole purpose of putting the node over the
--- continuation's wire. Instead the node simply takes the gutter **where the occupant
--- already is**, and the continuation reaches it as an ordinary arm of the fork's own
--- fan-in. Both handover rows are then never emitted.
---
--- The split side needs **no lookahead**. The sweep runs top to bottom, so by the time
--- a fork is reached the gutter's occupant is already decided and the whole condition
--- is a fact about the current row.
---
--- THREE CLAUSES, ALL REQUIRED:
---
---  1. **The occupant is one of this commit's own incoming lanes** (`occ_incoming`), not
---     an unrelated PASS-THROUGH survivor. A survivor draws a through-vertical in the
---     gutter, so the node cannot sit over its wire: that would put two lanes' verticals
---     in the node cell and read as the commit sitting *on* an unrelated branch. It is
---     also the hard floor — `place_gutter` reads `g.occ0[GUTTER]` (which `seed_bars`
---     sets for survivors only) and falls back off-gutter, so declining the eviction
---     there would cost a node-in-gutter row rather than save two Lines.
---  2. **It is not the lane the commit continues** (`trunk_in`). If it is, no handover
---     was going to be paid at all and there is nothing to swap.
---  3. **No merge swap is also available on this row, unless the fan-in has a Line of
---     its own.** See below: on a fully inline fan-in the two swaps would consume the
---     same node cell from both sides and neither saving would be 1:1.
---
--- An incoming occupant that is not `trunk_in` means at least two lanes arrive, so this
--- row is a fork by construction — which is why this is the split-side rule.
---
--- WHAT IT COSTS depends on where the fan-in is drawn, and only one of the two costs a
--- spine break:
---
---  * **A separate split Line** (`sep_split`, the shipped style): the occupant
---    terminates on that Line as a bare up-stub and the hub descent into the node
---    carries the CONTINUATION's id (`fan_in` labels the hub from `commit_incoming`,
---    which `place_gutter` pins to the commit's own lane), so the node's wire above and
---    its wire below are one Lane. There is **no spine break at all** — the trunk simply
---    converges as a fan arm, which §5.1 permits on a fan Line. Nothing is licensed
---    because nothing is broken.
---  * **A fully inline fan-in**: the fan is on the commit Line, so the occupant's
---    up-stub IS the node cell's wire from above while the continuation arrives
---    horizontally. The node's column then carries a different Lane above than below —
---    a licensed spine break (§5.1/§5.6), priced 1:1 in the two handover rows it
---    removes on this very row. The node still reads in its own Lane's colour, because
---    a Column's colour comes from its DOWN wire by default (§5) and here the down wire
---    is the first parent — so, unlike the merge swap, no `own_lane_up` mark is needed.
---    `state.up_foreign` records this case for the finalize-time bookkeeping.
---
--- PRECEDENCE, on a commit that both forks and merges. With a separate split Line the
--- two swaps compose: they touch opposite sides of a node cell whose wire from above is
--- still the commit's own Lane, so this row pays no handover AND the next subject row
--- pays none either. With an inline fan-in they cannot: the cell would hold a foreign
--- child above and a non-first parent below, the commit's own Lane on neither side, so
--- neither break is 1:1 with a saving and the node could not even be coloured from its
--- own Lane. The **merge swap wins** there — it saves the same two rows (on the next
--- subject row instead of this one) and keeps the node's colour — so clause 3 declines
--- the split swap by consulting the merge gate directly. Measured on a 1040-commit
--- repository expanded: 69 of 85 merge swaps sit on exactly such a row, so getting the
--- precedence backwards costs about as many rows as the split swap saves.
---@param state table
---@param occ table            -- the entry holding the gutter
---@param occ_incoming boolean -- is the occupant one of this commit's converging children?
---@return boolean fired
local function split_swap(state, occ, occ_incoming)
    if not occ_incoming then return false end
    if occ.lane == state.trunk_in then return false end
    if not state.sep_split and merge_swap_index(state) then return false end
    state.split_swap = occ
    state.up_foreign = not state.sep_split
    return true
end

--- GUTTER_SWAP (`gutter` only, spec §5.6): at a merge whose node is in the gutter,
--- send a **non-first parent** down the gutter and the first parent out to the side,
--- so the branch that owns the next subject row is already in place and the handover
--- rows are not needed at all.
---
--- Writes `state.cont` — the INDEX of the outgoing entry that continues at the node
--- column. `nil` means 1 (the first parent), which is what every other policy, and
--- every un-gated `gutter` row, leaves it as; the stages read `state.cont or 1`, so
--- the un-swapped path is unchanged by construction.
---
--- THE GATE HAS THREE CLAUSES AND ALL THREE ARE REQUIRED.
---
---  1. **That parent comes first.** Its next commit is earlier in row order than the
---     first parent's — the merged-in lineage is what continues immediately below
---     this merge, so the first parent's own line resumes further down.
---  2. **That parent owns the next subject row.** `state.next_subject` — the next
---     commit that carries a message (§5.6 keys the gutter on subject rows) — IS that
---     parent.
---  3. **That parent can KEEP the gutter it is handed** — this merge is its only
---     in-set child, so the lane born here is the only Lane arriving at it and is
---     therefore the lane it continues (§5 identity, tier 2 with a single candidate).
---
--- Clause 2 is not a refinement, it is the whole gate. With clause 1 alone the gate
--- fires at **every** merge in the shipping focused view and buys nothing: §3.1's
--- lineage grouping parks the merged-in branch's `◍` collapsed head immediately after
--- its merge, so clause 1 passes — but a collapsed head owns no subject row, so it
--- never wanted the gutter and no handover is saved. Measured on a 1040-commit
--- repository focused: 62 of 62 merges fired, 62 spine breaks, and **negative**
--- savings (+117 rendered rows, crossings 116 → 209, node-in-gutter 1.000 → 0.943).
--- With clause 2 the same 62 all decline and the focused view is byte-identical to
--- the un-swapped policy.
---
--- Clause 3 is what makes the saving **provable** instead of merely likely. Clause 2
--- says the next subject row is that parent; it does not say that row will *continue*
--- on the lane we just handed it. If some other, more senior Lane also arrives there
--- (another child of that parent, laid out earlier, so a smaller id), that Lane is the
--- one it continues (§5), the swapped lane is evicted after all, and the row pays the
--- handover anyway — on top of a spine break that bought nothing, which is strictly
--- worse than not firing. "Its only in-set child is this merge" removes the contest:
--- one candidate Lane, so it wins by construction. Measured, it declines EXACTLY the
--- unearned fires and no others — 15 of 100 (a 1040-commit repository expanded),
--- 38 of 60 (fuzz), 0 of 11 (`tests/large_topo`) — leaving every surviving fire
--- earned. In a real history the merged-in tip normally has just this one child, which
--- is why the cost is small.
---
--- The price of a fire is a **licensed spine break**: the gutter cell's wire above
--- the node is the first parent's lane and its wire below is the swapped-in parent's,
--- so they are different Lanes (§5.1's per-Lane continuity still holds — they are
--- distinct Segments — but the node's column is no longer one id top to bottom). The
--- break is licensed only because the clauses make it pay for itself, 1:1, in a
--- handover it removes; `tests/graph_helpers.check_spine` re-derives that licence
--- from the rendered output and fails on any break that did not earn it.
---
--- `state.own_lane_up` says the renderer must colour this node from its **up** wire
--- (the node's own lane, §5) rather than the default `down`, so a swapped merge keeps
--- the trunk's colour on the node and the topic lane merely *begins* below it.
---
--- COMPOSING WITH THE SPLIT SWAP (a commit that both forks and merges, §10.4's
--- both-fans case). The two swaps act on opposite sides of the node cell, so they
--- compose exactly when the node's wire from ABOVE is still its own Lane — which it is
--- whenever the fan-in has a Line of its own: the hub descent carries the continuation's
--- id, so the cell reads first-parent above / non-first parent below and this gate's own
--- licence applies unchanged. Where the fan-in is inline they cannot compose, and the
--- precedence is resolved on the eviction row — `split_swap` declines by consulting
--- `merge_swap_index`, so this gate needs no counterpart test and there is exactly one
--- decision point.
---@param state table
---@param cc integer  -- the node column `place_gutter` chose
local function gutter_swap(state, cc)
    if cc ~= GUTTER then return end
    local bi = merge_swap_index(state)
    if bi then state.cont, state.own_lane_up = bi, true end
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

--- Open a layout **session** — the sweep with its state held open so it can be
--- **resumed**. `M.layout` (below) is the one-shot form: open a session, extend it
--- over the whole list, done. Streaming (spec §3.1) keeps the session and extends
--- it batch by batch instead, which is the same fold run once rather than once per
--- batch.
---
--- WHY RESUMING IS EXACT. The sweep is a strict **top-down fold**: each row's
--- output is a function of (the state after the previous row, this row's commit).
--- No stage reads a row below the current one, and the streamed order APPENDS
--- older commits at the bottom — `git log --topo-order` emits a parent only after
--- every child, so a row's `.parents`/`.children` are final the moment it is
--- appended. Hence laying out a prefix yields exactly the first rows of laying out
--- the whole list. The one exception is a policy with a `prepass`, which by
--- definition reads ahead (`gutter`, whose parent-swap gate needs the NEXT subject
--- row); a session reports that as `lookahead` and the caller must rebuild in full.
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
---@param seed table<integer, table>?  -- col -> Lane crossing in from above
---@return LayoutSession
function M.session(opts, seed)
    -- The pin ranks (§5 tier 0 / birth at a pinned tip). An empty map ranks
    -- nothing, so it is normalised to nil: the "no pins" path is one nil test.
    local pin_rank = opts.pin_rank
    if pin_rank and next(pin_rank) == nil then pin_rank = nil end
    -- The counterpart map (§5.5): implicit remote counterpart's ref id → its local's
    -- rank. Colour only — never read by identity. Normalised to nil like `pin_rank`.
    local pin_cp = opts.pin_counterpart
    if pin_cp and next(pin_cp) == nil then pin_cp = nil end
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

    -- PINNED COLOURS (§5.5). Rank `k` (k <= ntracks) owns curated slot `k`. From the
    -- start of the layout the slot is WITHHELD: out of the FIFO, `in_use` 1 (the
    -- reservation is its holder), never handed out by `alloc_color` and never shared.
    -- The pinned lane born at its tip TAKES the reservation over (`take_pin`); the slot
    -- returns to the free list through the ordinary `free_color` when that lane ends,
    -- or through `release_pin` at the tip when no lane of its own is born there.
    --   `pin_wait[k]` — slot k withheld and not yet claimed by a lane;
    --   `held[k]`     — slot k withheld OR held by its pinned lane (cleared when the
    --                   slot finally returns), which is what the share path skips.
    local pin_wait, held, nheld = {}, {}, 0
    if pin_rank then
        for k in pairs(M.pinned_slots(pin_rank, ntracks)) do
            pin_wait[k], held[k], nheld = true, true, nheld + 1
        end
        if nheld > 0 then
            local kept = {}
            for i = qhead, qtail do
                if not held[free[i].slot] then kept[#kept + 1] = free[i] end
            end
            free, qhead, qtail = kept, 1, #kept
            for k in pairs(held) do in_use[k] = 1 end
        end
    end

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
        -- No truecolor and exhausted: share the least-shared curated slot — never a
        -- pinned colour (§5.5) unless every curated slot is one, which falls back to
        -- sharing among all of them rather than failing.
        local best
        for pass = 1, 2 do
            for off = 0, ntracks - 1 do
                local c = ((dup + off) % ntracks) + 1
                if (pass == 2 or not held[c]) and (not best or in_use[c] < in_use[best]) then
                    best = c
                end
            end
            if best then break end
        end
        dup = best
        in_use[best] = in_use[best] + 1
        return best
    end

    local function free_color(c)
        if not c then return end
        -- A counterpart lane's colour `-k` is slot `k` (§5.5): one more holder of it.
        if c < 0 then c = -c end
        in_use[c] = (in_use[c] or 0) - 1
        if in_use[c] > 0 then return end -- still held (a shared slot's other holder)
        -- A pinned colour's last holder ended: the slot is an ordinary one again.
        if held[c] then held[c], nheld = nil, nheld - 1 end
        -- Retire a surplus generated slot rather than recycling it, so quiet
        -- stretches drift back to the curated palette. "Comfortably full" counts
        -- only the slots not withheld as pinned colours (§5.5).
        if c > ntracks and fcount() >= ntracks - nheld then return end
        qtail = qtail + 1; free[qtail] = { slot = c, ready = clock + buffer }
    end

    -- The colour of a lane born where rank `r` is pinned: its pinned colour while that
    -- is still withheld (the lane takes the reservation over — `in_use` stays 1), else
    -- (unranked, past the palette, or already claimed) an ordinary free-list colour.
    local function take_pin(r)
        if r and pin_wait[r] then
            pin_wait[r] = nil
            return r
        end
        return alloc_color()
    end

    -- COUNTERPART COLOURS (§5.5). A lane born unranked at an implicit remote
    -- counterpart's tip shares its local's slot `k` while that slot is still HELD
    -- (withheld, or held by the pinned lane or another counterpart lane): it is one
    -- more holder (`in_use[k] + 1`, so `free_color` returns the slot only when the
    -- last holder ends) and its colour is `-k` — slot k in its counterpart variant,
    -- the mark every copy of the colour carries. Nothing else may take a held slot.
    -- The best (smallest) such rank at the commit wins (`counterpart_at`; nil when
    -- none applies, and the caller then takes an ordinary free-list colour). That
    -- rank is also what decides a COUNTERPART BIRTH (§5, in `spawn_lanes`): a held
    -- slot is exactly when the birth has a colour to give, so no birth churns lanes
    -- for an ordinary colour.
    local function counterpart_at(C)
        if not pin_cp then return nil end
        local best
        for _, ref in ipairs(C.refs or {}) do
            local k = pin_cp[ref_id(ref)]
            if k and held[k] and (not best or k < best) then best = k end
        end
        return best
    end
    local function take_counterpart(k)
        if not k then return nil end
        in_use[k] = in_use[k] + 1
        return -k
    end

    -- Release a still-withheld pinned colour whose branch start was found without a
    -- lane of its own (§5.5): back to the free list like any returned colour.
    local function release_pin(k)
        if pin_wait[k] then
            pin_wait[k] = nil
            free_color(k)
        end
    end

    local rows = {}
    local active = {} -- col -> Lane flowing down into the current row

    -- Seed the boundary lanes of a context pane (spec §6.2): they flow in from
    -- above in their given columns, keeping their colours. Reserve each seed
    -- colour slot — drop it from the curated free FIFO and bump its in_use — so
    -- the pane's own newly born lanes never reuse a colour live at the seam.
    if seed then
        local reserved, cp = {}, {}
        for col, lane in pairs(seed) do
            active[col] = lane
            -- A counterpart seed (`-k`, §5.5) holds slot k as one more holder.
            local slot = lane.color < 0 and -lane.color or lane.color
            reserved[slot] = (reserved[slot] or 0) + 1
            if lane.color < 0 then cp[slot] = (cp[slot] or 0) + 1 end
        end
        local kept = {}
        for i = qhead, qtail do
            if not reserved[free[i].slot] then kept[#kept + 1] = free[i] end
        end
        free, qhead, qtail = kept, 1, #kept
        for slot, n in pairs(reserved) do
            -- A seed carrying a still-withheld pinned colour IS that pinned branch's
            -- lane continuing across the seam (§5.5): it takes the reservation over,
            -- so the slot is counted once and released when the seed ends.
            -- A counterpart seed never does: it is a holder in addition to the pin.
            if pin_wait[slot] and n > (cp[slot] or 0) then pin_wait[slot] = nil; n = n - 1 end
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
    -- ended incoming children's colours. Pure lane lifecycle, driven by the DAG, the
    -- row order and the pin ranks, NEVER by placement; must run before any later
    -- colour alloc so a slot freed here cannot be reused by a lane born on the same
    -- line.
    --
    -- IDENTITY (spec §5). A lane is `{ id, color, rank }`; the first parent continues
    -- the identity of one incoming lane, chosen in tiers, each deciding only between
    -- the lanes the previous one left tied — all read off the DAG, the row order and
    -- `opts.pin_rank`, never off a column:
    --
    --  0. PIN RANK — the best-ranked lane (1 is best; an unranked lane, `rank == nil`,
    --     is worse than every rank). A lane's rank is fixed where it is born (the best
    --     pinned ref at that commit, `M.commit_rank`) and carried by its continuations.
    --  1. FIRST PARENT — a lane whose child has THIS COMMIT as its FIRST parent: that
    --     child's mainline runs into here, so it is a continuation outright. A merge's
    --     second-parent edge is still a candidate — it is the merged-in BRANCH, and
    --     minting a fresh lane for it would recolour every merged-in branch tip (the
    --     `m -> {a, b}` diamond is the smallest case that proves it).
    --  2. SENIORITY — the smallest id. Ids are minted in row order and carried along a
    --     whole first-parent chain, so the smallest is the chain that started highest
    --     and a topic forking off a trunk is always junior to it.
    --
    -- BIRTH AT A PINNED TIP overrules the tiers where this commit's best rank STRICTLY
    -- beats every incoming lane's: every incoming lane ends — a merge's extra-parent
    -- edge included, since a lane's colour is fixed for life — and the pinned
    -- branch's lane is born (fresh id, its PINNED COLOUR, §5.5). An equal rank births
    -- nothing. With no `pin_rank` every rank is nil, tier 0 always ties and no commit
    -- is pinned, so this is exactly the old two-tier choice.
    --
    -- Tier 0 continues below the ranks: among UNRANKED lanes a COUNTERPART lane
    -- (colour `-k`, `cp_rank`) beats a plain one, the smaller `k` first. And BIRTH AT
    -- A COUNTERPART TIP is the same overrule one step down: at a commit with no ranked
    -- ref, carrying an implicit remote counterpart of rank `k` whose slot is still
    -- held, when `k` strictly beats every incoming lane (none ranked, none a
    -- counterpart lane of rank <= k), every incoming lane ends and a counterpart lane
    -- is born (fresh id, unranked, colour `-k`). Both births set `state.pin_birth`, so
    -- the gutter treats them alike (no claim row, no parent swap).
    --
    -- PINNED COLOURS: a lane born with rank `r` takes slot `r` while it is withheld
    -- (`take_pin`). After the ended lanes return, every rank at this commit whose slot
    -- is STILL withheld is released (`release_pin`, slot order): the branch's start is
    -- here, and it got no lane of its own — a better-ranked lane continued, a better
    -- ref on the same commit named the lane, or the commit is a root.
    --
    -- This used to be "the leftmost incoming lane" — a positional proxy for "the
    -- trunk", true only while the trunk happened to sit leftmost. Choosing
    -- semantically is also what makes identity **invariant across layout policies**
    -- (§5.6): no column may reach an id, a colour or a rank.
    local function spawn_lanes(state)
        local C = state.commit
        local incoming = state.incoming
        local trunk
        for _, e in ipairs(incoming) do
            local l = e.lane
            if not trunk then
                trunk = l
            elseif rank_better(l.rank, trunk.rank) then
                trunk = l
            elseif rank_better(trunk.rank, l.rank) then
                -- `trunk` outranks `l`: keep it.
            elseif rank_better(cp_rank(l), cp_rank(trunk)) then
                -- Tied ranks (both unranked): the better COUNTERPART lane wins (§5 tier 0).
                trunk = l
            elseif not rank_better(cp_rank(trunk), cp_rank(l)) then
                local lf, tf = continues_into(l, C), continues_into(trunk, C)
                if (lf and not tf) or (lf == tf and l.id < trunk.id) then trunk = l end
            end
        end
        local crank = pin_rank and M.commit_rank(C, pin_rank)
        local rank = trunk and trunk.rank or crank
        state.pin_birth = nil
        if crank and trunk and rank_better(crank, trunk.rank) then
            -- `trunk` holds the best incoming rank, so beating it beats them all: no
            -- incoming lane continues, and the node is where the pinned lane is born.
            trunk, rank = nil, crank
            state.pin_birth = true
        end
        -- BIRTH AT A COUNTERPART TIP (§5): no ranked ref here, its slot `k` still held,
        -- and `k` strictly beats every incoming lane — none ranked, none a counterpart
        -- lane of rank <= k. The ranked rule wins wherever a ranked ref points (`crank`).
        local ck = (not crank) and counterpart_at(C) or nil
        if ck and trunk and trunk.rank == nil and rank_better(ck, cp_rank(trunk)) then
            trunk, rank = nil, nil
            state.pin_birth = true
        end
        local outgoing = {}
        for i, p in ipairs(C.parents or {}) do
            local id, color, r
            if i == 1 and trunk then
                id, color, r = trunk.id, trunk.color, rank
            elseif i == 1 then
                -- An unranked birth at a remote counterpart's tip shares its local's
                -- slot (§5.5, colour only); otherwise the pinned / free-list colour.
                id, r = new_id(), rank
                color = (rank == nil and take_counterpart(ck)) or take_pin(rank)
            else
                -- A merge's extra-parent edge: born unranked.
                id, color = new_id(), alloc_color()
            end
            outgoing[#outgoing + 1] = { lane = { id = id, color = color, rank = r,
                begin = C, parent = p, highlighted = false } }
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
        if crank and pin_rank then
            local ks = {}
            for _, ref in ipairs(C.refs or {}) do
                local k = pin_rank[ref_id(ref)]
                if k and pin_wait[k] then ks[#ks + 1] = k end
            end
            table.sort(ks)
            for _, k in ipairs(ks) do release_pin(k) end
        end
        state.outgoing = outgoing
        state.trunk_in = trunk
        -- The incoming ENTRY carrying that lane, so a placement stage can ask "which
        -- column is this commit's own lane in?" without re-deriving identity. The
        -- entry table is what the gutter's handover rows mutate (`e.col`), so holding
        -- the reference — not the column — keeps every later stage in step.
        for _, e in ipairs(incoming) do
            if e.lane == trunk then state.trunk_entry = e end
        end
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
    -- split line reduce the fan-in to the lane the node sits on (the other children's
    -- columns stay free gaps). `cc` starts at cc0; the `slide` stage may move it left.
    --
    -- `incoming[1]` is the LEFTMOST incoming lane, which is a positional stand-in for
    -- "this commit's own lane" — the incoming lane its first parent continues
    -- (`state.trunk_entry`, chosen from the DAG in `spawn_lanes`). The two coincide
    -- wherever the trunk sits leftmost, which on a real history is nearly always: the
    -- residue is 1–2 rows per repository (0 on `tests/large_topo`) and ~5% of random
    -- DAGs. Where they differ the node lands on a *different* child's column, so the
    -- cell's wire from above belongs to a lane that ends here while its wire below
    -- belongs to the continuing one, and the spine changes colour mid-column (the §5.6
    -- defect, in the small). Putting the node on `trunk_entry` instead is the general
    -- fix, but it moves the node, and compaction ripples off the node column — 96 of
    -- 395 rendered lines on a 1040-commit repository's focused view — so it is a
    -- deliberate visual change to the default policy, not a quiet bug fix, and is left
    -- for its own decision. `place_gutter` (§5.6) does read `trunk_entry`: the gutter
    -- fixes the node column outright, so there the same choice is not a ripple.
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
    -- columns, and patches the occupant's recorded column so every later stage sees
    -- the new position. `state.above` is a LIST, so this row coexists with the claim
    -- row and with the commit's own split fan (§5 Line).
    --
    -- THE OCCUPANT IS WHOEVER IS IN THE COLUMN — a pass-through survivor, or one of
    -- this commit's OWN converging children (§5.6 says "the occupant", not "a
    -- survivor"). The second case is the common one: a run of commits on lane L puts L
    -- in the gutter, and where that run's last commit forks off a trunk, L's final edge
    -- terminates at the fork — still in the gutter, still not the lane the fork
    -- continues on.
    --
    -- That second case is now handled by the **split swap** (`split_swap`, §5.6) rather
    -- than by eviction: the node takes the gutter where the occupant already is and the
    -- continuation converges into it as an ordinary arm of the fork's own fan-in, so both
    -- handover rows are skipped. Evicting it instead was the *first* correct answer to
    -- the fork-hub colour defect (the split hub rendering in the ending branch's colour
    -- while the spine below it rendered in the trunk's), and it is no longer the only
    -- one: `fan_in` labels the hub from `commit_incoming` — the commit's own lane,
    -- wherever the placement stage put the node — so the wire above the node and the wire
    -- below it are one Lane either way. Eviction remains what a **survivor** gets, since
    -- the node may not sit over an unrelated branch's through-vertical.
    --
    -- The one occupant that needs neither eviction nor a swap is the lane the commit
    -- CONTINUES (`trunk_in`, chosen from the DAG in `spawn_lanes`): it is already where
    -- the claim row would put it.
    local function evict_gutter(state)
        if not state.subject or blocked[GUTTER] then return end
        local occ, occ_incoming
        for _, s in ipairs(state.survivors) do
            if s.col == GUTTER then occ = s end
        end
        for _, inc in ipairs(state.incoming) do
            if inc.col == GUTTER then occ, occ_incoming = inc, true end
        end
        if not occ then return end                    -- already free
        if occ.lane == state.trunk_in then return end -- the claiming lane holds it
        -- A converging child keeps the gutter and the node sits on it (§5.6 split swap),
        -- so neither this row nor the claim row is emitted at all.
        if split_swap(state, occ, occ_incoming) then return end

        local taken = {}
        for _, s in ipairs(state.survivors) do taken[s.col] = true end
        for _, inc in ipairs(state.incoming) do taken[inc.col] = true end
        local f = GUTTER + 1
        while taken[f] or blocked[f] do f = f + 1 end

        local cells, draw = new_line()
        -- Every lane crosses this row where it stands; the occupant alone turns.
        for _, list in ipairs({ state.survivors, state.incoming }) do
            for _, e in ipairs(list) do
                if e == occ then
                    draw(e.lane, GUTTER, f, GUTTER, f) -- in at the gutter, out at f
                else
                    draw(e.lane, e.col, e.col, e.col, e.col)
                end
            end
        end
        state.above[#state.above + 1] = assemble(cells, nil, nil)
        occ.col = f
        -- `incoming` is kept sorted by column (every later stage reads incoming[1] as
        -- the leftmost), so a moved child has to be resorted into place.
        if occ_incoming then
            table.sort(state.incoming, function(a, b) return a.col < b.col end)
        end
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
    -- Declines when there is nothing to move: a tip (no incoming), the claiming lane
    -- ALREADY in the gutter (the overwhelmingly common case, §5.6 — consecutive
    -- subject rows share a lane), a root-blocked gutter (§5.1), a **split swap** (the
    -- gutter deliberately stays with a converging child and the node comes to it, §5.6),
    -- or — defensively — anything still holding the column, which means `evict_gutter`
    -- declined and `place_gutter` will fall back off-gutter. The "already there" test is
    -- on the CLAIMER, not on any incoming lane: a converging child that is not this
    -- commit's continuation sitting in the gutter is a reason to evict or to swap, not a
    -- reason to skip the claim. Runs after `evict_gutter` and before `seed_bars`,
    -- patching the incoming entry's column so every later stage sees the new one.
    local function claim_gutter(state)
        if not state.subject or blocked[GUTTER] or state.split_swap then return end
        local incoming = state.incoming
        if #incoming == 0 then return end
        -- A pinned lane BORN here (§5) continues no incoming lane, so there is nothing
        -- that must turn in: every incoming lane ends at the node, converging as an arm
        -- of the fan-in. Claiming one would pay a handover Line only to end it on the
        -- node — UNLESS the fan-in shares the commit Line with a fan-out: arms running
        -- in towards the gutter and extra parents running out of it over the same cells
        -- is the §5.1 mixed-direction share the claim row exists to prevent. So skip it
        -- only when either fan has a Line of its own or nothing fans out.
        if state.pin_birth and (state.sep_split or state.sep_merge or #state.outgoing <= 1) then return end
        local claimer
        for _, inc in ipairs(incoming) do
            if inc.lane == state.trunk_in then claimer = inc end
        end
        claimer = claimer or incoming[1]
        if claimer.col == GUTTER then return end
        for _, inc in ipairs(incoming) do
            if inc.col == GUTTER then return end
        end
        for _, s in ipairs(state.survivors) do
            if s.col == GUTTER then return end
        end

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
    --
    -- THE HANDOVER COLUMN (§5.6). The lane that holds the gutter after this row is
    -- evicted before it next owns a subject row whenever its parent is not the next
    -- subject row — the prepass knows both. Left alone, a lane born meanwhile (a
    -- collapsed head, typically) takes `GUTTER + 1`, and the eviction lands beyond
    -- every such lane, crossing each of them. So `GUTTER + 1` is kept for it:
    -- `state.reserve` names the column and `state.reserve_end` the occupant's end
    -- row, and a lane placed on this row skips the column if it ends no earlier.
    -- A lane ending SOONER may still take it — it nests inside the occupant, so
    -- neither crosses the other — which is what keeps the rule free of new Lines and
    -- width. Both fields are set only when `state.next_subject` is, i.e. only under
    -- `gutter` (the one policy with a prepass), so every other policy is untouched;
    -- `state` is per row, so the reservation never outlives the row it was made on.
    local function lane_end(state, lane)
        local p = lane and lane.parent
        return (p and state.pre.row[p.hash]) or math.huge
    end
    local function reserve_handover(state, occ)
        if not state.next_subject or state.reserve or not M._internal.handover_column then return end
        if not occ or not occ.parent or occ.parent.hash == state.next_subject then return end
        state.reserve, state.reserve_end = GUTTER + 1, lane_end(state, occ)
    end
    local function skip_reserved(state, c, lane)
        if c ~= state.reserve or not lane then return false end
        return lane_end(state, lane) >= state.reserve_end
    end

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
            local L = outgoing[1] and outgoing[1].lane
            while grid_taken(g, c) or skip_reserved(state, c, L) do c = c + 1 end
            return c
        end

        -- NODE. A subject row's node goes in the gutter: its own lane is normally
        -- already there (nothing is drawn), and when it is not, either the handover rows
        -- brought it in or a **split swap** (§5.6) left a converging child there and the
        -- node comes to *it* — in which case `own.col` is elsewhere and the commit's own
        -- lane converges as a fan arm (`fan_in`'s "node column is elsewhere" arm, which
        -- is also what a pane seam row takes). A marker or junction (§10.4) keeps its
        -- lane column — the rule
        -- keys on subject rows, so a marker between two trunk commits disturbs
        -- nothing. Off the gutter the node still goes on **its own lane's column**
        -- (`trunk_entry`, §5), never on some other converging child's: that is what
        -- keeps the spine one colour through the node on a root-blocked row (§5.1) and
        -- on a pane seam row, the two cases that legitimately land here.
        local own = state.trunk_entry or incoming[1]
        -- THE HANDOVER COLUMN, for a survivor passing through the gutter.
        for _, sv in ipairs(state.survivors) do
            if sv.col == GUTTER then reserve_handover(state, sv.lane); break end
        end
        local cc
        if state.subject and not held and not blocked[GUTTER] then
            cc = GUTTER
        else
            cc = own and own.col or free_lane_col()
        end

        -- CONTINUATION. The gutter belongs to the row being read. Its first parent
        -- continues there by default and no other parent may wander in — a parent
        -- taking the gutter *opportunistically* (it is born there, so no wire moves)
        -- is what once drew a trunk merge in the merged-in topic's colour, since a
        -- node is coloured from its cell's `down` Segment.
        --
        -- `gutter_swap` (§5.6) is the ONE sanctioned exception, and it is sanctioned
        -- because it is not opportunistic: it fires only where the next subject row IS
        -- that parent, so the swap replaces a handover instead of stealing a column,
        -- and it hands the renderer `own_lane_up` so the node still shows the trunk's
        -- colour. Everywhere else the handover pays for itself on its own rows
        -- (`evict_gutter` / `claim_gutter`).
        gutter_swap(state, cc)
        -- THE HANDOVER COLUMN, when the lane holding the gutter after this row is
        -- this commit's own continuation (whichever parent `gutter_swap` chose).
        if not state.reserve and cc == GUTTER then
            local L = outgoing[state.cont or 1]
            reserve_handover(state, L and L.lane)
        end

        -- Whichever parent continues, it continues HERE, so reserve the node's own
        -- column: no other lane may lay a horizontal through it on this row.
        if outgoing[1] then g.used[cc] = true end
        -- No node and nothing continuing here: hold the gutter empty rather than
        -- letting a generic fan-out grab it, so it is free when the next subject
        -- lane turns in.
        if cc ~= GUTTER then g.occ0[GUTTER] = true end

        local commit_incoming = incoming
        if state.sep_split then
            commit_incoming = { { col = cc, lane = own.lane } }
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
            -- WHICH lane owns the hub's verticals is not fan_in's choice: it is the
            -- lane the placement stage put the node on, which it published as
            -- `commit_incoming`'s single entry (the commit Line below draws that same
            -- wire as an up-stub, and per-Lane continuity §5.1 demands one id for the
            -- two). Reading it back — rather than re-picking `incoming[1]` — is what
            -- keeps the hub, the node and the continuation below it on ONE lane, one
            -- id, one colour under EVERY policy (§5.6), including where the policy put
            -- the node somewhere `incoming[1]` is not. Every other converging child
            -- reaches the hub as an arm.
            local hub = commit_incoming[1].lane
            local hub_col
            for _, inc in ipairs(incoming) do
                if inc.lane == hub then hub_col = inc.col end
            end
            local cells, draw, add_seg = new_line()
            if hub_col == cc0 then
                -- The node sits on the hub lane's own column (every policy but a
                -- `gutter` pane seam row): it enters the hub as a bare up-stub.
                add_seg(cc0, { up = true }, { hub }, hub.id, hub.color)
            else
                -- The node column is elsewhere, and the hub lane reaches it as a fan arm
                -- like the rest. Two `gutter` rows land here (§5.6): a pane SEAM row
                -- (§6.2), which may move no lane, so it cannot bring the node's lane into
                -- the gutter; and a **split swap**, where the gutter is deliberately left
                -- to a converging child and the node placed on it. In both cases the hub
                -- LABEL is still the commit's own lane, which is what keeps the descent,
                -- the node and the continuation below on one id (§5.1) — a swapped fork
                -- therefore breaks no spine at all on this style.
                draw(hub, math.min(hub_col, cc0), math.max(hub_col, cc0), hub_col, nil)
            end
            local descent = {}
            for _, inc in ipairs(incoming) do descent[#descent + 1] = inc.lane end
            -- The shared descent is a BUNDLE of every converging edge, and its label
            -- is pinned by per-Lane continuity (§5.1): the commit Line below draws
            -- this same wire as `commit_incoming`'s up-stub, so the two must carry
            -- one id. It is not an identity choice — identity changes at the node,
            -- below this wire — so it is the arriving lane the node sits on.
            add_seg(cc0, { down = true }, descent, hub.id, hub.color)
            for _, inc in ipairs(incoming) do
                if inc.lane ~= hub then
                    draw(inc.lane, math.min(inc.col, cc0), math.max(inc.col, cc0), inc.col, nil)
                end
            end
            for _, s in ipairs(survivors) do draw(s.lane, s.col, s.col, s.col, s.col) end
            state.above[#state.above + 1] = assemble(cells, nil, nil)
        end
        for c = math.min(cc0, cc), math.max(cc0, cc) do g.used[c] = true end
        for _, inc in ipairs(commit_incoming) do
            g.draw(inc.lane, math.min(inc.col, cc), math.max(inc.col, cc), inc.col, nil)
        end
        -- The continuing parent turns down out of the node. The node always sits on
        -- its own lane's column — under `gutter` too, since `claim_gutter` brings that
        -- lane into the gutter a row earlier — so this is a one-cell down stub. With
        -- a separate merge Line the fan happens below and the commit Line carries
        -- only the stub into the ascent, at the same column either way.
        --
        -- WHICH parent continues is `state.cont` (§5.6 `gutter_swap`): the first,
        -- except at a gated swap, where the parent owning the next subject row takes
        -- the gutter instead. `nil` means 1, so every other policy is untouched.
        local cont = outgoing[state.cont or 1]
        if cont then g.draw(cont.lane, cc, cc, nil, cc) end
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
    --
    -- A FREED column is a *preference* among free columns, not a licence to ignore
    -- this row's own claims. It deliberately overrides the `occ0` reservation on an
    -- incoming column — relaxing that reservation is the whole point (§5.1 fan-out
    -- placement) — but `g.used`, a NON-SHAREABLE claim made on this row, still
    -- binds, and the node's own column is always in it: it carries the first
    -- parent's continuation, which every placement stage reserves.
    --
    -- Deriving the candidates POSITIONALLY (`commit_incoming[2..n]`) only *looked*
    -- like it respected that. It is a stand-in for "every incoming column this row
    -- has not claimed", correct exactly while the node sits on `commit_incoming[1]`
    -- — which is what `place_commit` does. `place_gutter` puts the node on the
    -- commit's OWN lane instead (§5, `state.trunk_entry`), and that can be ANY
    -- incoming entry, so the node's own column could be handed to an extra parent
    -- too: both parents then landed in one column, `active` kept only the later of
    -- the two, and `complete_check` errored that the first parent was never carried
    -- forward (`gutter` × `merge_on_separate_line` / `allow_merge_on_split`, on a
    -- non-subject row — a marker or junction, the rows no handover runs on).
    --
    -- Consulting the ledger instead of the position is what makes the reuse safe for
    -- whatever a placement stage does next, which is the general form of the bug. It
    -- is provably inert for the four lane-column policies rather than merely
    -- equivalent on a corpus: not one of their 4,382 freed reuses across the fuzz +
    -- real-repository sweep is in `used`, whereas all 82 under `gutter` are exactly
    -- the node column.
    local function fan_out(state)
        local g = state.g
        local survivors, outgoing = state.survivors, state.outgoing
        local cc, commit_incoming, sep_merge = state.cc, state.commit_incoming, state.sep_merge
        local freed = {}
        if opts.merge_style.allow_merge_on_split or sep_merge then
            for i = 2, #commit_incoming do
                local c = commit_incoming[i].col
                -- `gutter` (§5.6) additionally holds the gutter itself for the lane
                -- owning the next subject row, never a fan-out reclaiming a freed
                -- column. That hold is an `occ0` reservation — the one `freed`
                -- overrides by design — so it is stated apart from the `used` ledger,
                -- and so is the handover column beside it (`state.reserve`).
                if not g.used[c] and not (state.gutter and c == GUTTER)
                    and not (state.reserve == c) then
                    freed[#freed + 1] = c
                end
            end
        end
        -- `cont` is the INDEX of the parent that continues at the node column, so every
        -- OTHER parent is a diverging arm placed below. It is 1 for every policy and
        -- every un-gated row; `gutter_swap` (§5.6) names another, and then the first
        -- parent is the one that fans out sideways. With `cont == 1` the loop yields
        -- exactly `2..#outgoing` in order, which is why the change is inert.
        local cont = state.cont or 1
        if outgoing[cont] then outgoing[cont].out = cc end
        local fi = 1
        for i = 1, #outgoing do
          if i ~= cont then
            -- `place_gutter` may have pinned this parent to the gutter already; every
            -- other policy leaves `out` unset here, so the generic placement runs.
            local k = outgoing[i].out
            if not k then
                if fi <= #freed then
                    k = freed[fi]; fi = fi + 1
                else
                    k = 1
                    while grid_taken(g, k) or skip_reserved(state, k, outgoing[i].lane) do k = k + 1 end
                end
                outgoing[i].out = k
                g.used[k] = true
            end
            if not sep_merge then
                g.draw(outgoing[i].lane, math.min(k, cc), math.max(k, cc), nil, k)
            end
          end
        end

        -- MERGE LINE (below): the continuing parent carries on at the commit column;
        -- the shared ascent carries every parent; the other parents fan out. Survivors
        -- pass through at their compacted column. The ascent's label is pinned by
        -- per-Lane continuity (§5.1) to whatever the commit Line drew as its `down` at
        -- `cc` — the CONTINUING parent, not positionally the first.
        if sep_merge then
            local mcells, mdraw, madd = new_line()
            for _, s in ipairs(survivors) do mdraw(s.lane, s.out, s.out, s.out, s.out) end
            local lead = outgoing[cont]
            if lead then
                local ascent = {}
                for _, o in ipairs(outgoing) do ascent[#ascent + 1] = o.lane end
                madd(cc, { up = true }, ascent, lead.lane.id, lead.lane.color)
                madd(cc, { down = true }, { lead.lane }, lead.lane.id, lead.lane.color)
            end
            for i = 1, #outgoing do
                if i ~= cont then
                    local o = outgoing[i]
                    mdraw(o.lane, math.min(o.out, cc), math.max(o.out, cc), nil, o.out)
                end
            end
            state.below[#state.below + 1] = assemble(mcells, nil, nil)
        end

        -- Advance active / blocked for the next row (a root's column is blocked for
        -- one row so nothing stacks under it).
        active = {}
        for _, s in ipairs(survivors) do active[s.out] = s.lane end
        if outgoing[cont] then active[cc] = outgoing[cont].lane end
        for i = 1, #outgoing do
            if i ~= cont then active[outgoing[i].out] = outgoing[i].lane end
        end
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
        -- A licensed spine break (§5.6 `gutter_swap`): the node's OWN lane is the wire
        -- arriving from above, not the one leaving below, so the renderer must take the
        -- cell's colour from `up`. Marked on the node's Column rather than inferred by
        -- the renderer, because only the layout knows the break was deliberate — and
        -- the flag is nil everywhere else, so no other cell's colour moves.
        if state.own_lane_up and main[state.cc] then main[state.cc].own_lane_up = true end
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
    ---   value is threaded onto each row's `state.pre`, and `pre[state.index]` onto
    ---   `state.next_subject`, so nothing is written onto the caller's `items`.
    ---   `gutter` uses it (`gutter_prepass`): the parent-swap gate (§5.6) has to know
    ---   which commit owns the NEXT subject row, which is by definition below this one.
    ---   Reading it does not let a fan-out hand the gutter over *early* — the swap only
    ---   chooses which of THIS commit's parents continues in it. Also the hook the
    ---   reserved `interval` placement (§5.6) will use for lane lifespans.
    ---@type table<string, LayoutPolicy>
    local POLICY = {
        compact   = { body = layout_compact,   seam = layout_seam },
        survivors = { body = layout_survivors, seam = layout_seam },
        linear    = { body = layout_linear,    seam = layout_seam },
        straight  = { body = layout_seam,      seam = layout_seam },
        gutter    = { body = layout_gutter,    seam = layout_gutter_seam, prepass = gutter_prepass },
    }

    -- Membership in `active`, as a set built once per `complete_check` run. The
    -- oracle asks it once per incoming/survivor/outgoing lane, and a wide graph
    -- has as many survivors as columns — a linear scan per question made the
    -- check O(width^2) per row rather than O(width).
    --
    -- Worth measuring before believing: on a `--all` graph ~100 lanes wide this is
    -- 5-16% of one sweep (isolated, best of 3: 110 -> 105 ms at 1k commits,
    -- 1576 -> 1321 at 4k, 4228 -> 3924 at 16k). The quadratic term is real but it
    -- is NOT what dominates — the sweep is allocation-bound, at roughly six tables
    -- per drawn cell (the segment, its edge list, its connectivity, the column,
    -- its union connectivity, the per-cell connectivity literal). Reducing THAT is
    -- the open lead for lane-layout cost, not this.
    local live = {}
    local function refresh_live()
        for k in pairs(live) do live[k] = nil end
        for _, l in pairs(active) do live[l] = true end
    end
    local function active_contains(lane)
        return live[lane] == true
    end

    -- Structural oracle (spec: "check that everything has been handled"): the
    -- emitted lines actually realise every obligation. Independent of the ledger
    -- flags the stages flip — it reads the output, like the test invariants — and
    -- errors on any violation.
    local function complete_check(state)
        refresh_live()
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

    ---@class LayoutSession
    ---@field n integer         rows swept so far
    ---@field rows table[]      every row swept so far, in order
    ---@field lookahead boolean the policy reads rows below the current one, so it
    ---                         cannot be resumed — the caller must rebuild in full
    ---@field extend fun(items: table[], from: integer?, yield: (fun())?): table[]
    local session = { n = 0, rows = rows, lookahead = policy.prepass ~= nil }

    --- Sweep `items[from..]` onto the end of the session and return **just the rows
    --- it appended** (`session.rows` holds the whole sweep). `from` defaults to 1;
    --- it is the index into `items`, which for a streaming caller is the whole
    --- growing order, so `state.index` stays the global row number. The optional
    --- `yield` is called every `YIELD_ROWS` rows so a coroutine driver can chunk a
    --- long sweep across event-loop ticks; it is only ever called from this loop
    --- body, never across a C-call boundary.
    function session.extend(items, from, yield)
        local pre = policy.prepass and policy.prepass(opts, items) or nil
        local out, since = {}, 0
        for i = from or 1, #items do
            run_item(items[i], i, pre, (seed and session.n == 0) and policy.seam or policy.body)
            session.n = session.n + 1
            out[#out + 1] = rows[#rows]
            since = since + 1
            if yield and since % YIELD_ROWS == 0 then yield() end
        end
        return out
    end

    return session
end

--- Build the full graph layout from an ordered list of items, from scratch — the
--- reflow primitive and the entry point for tests. A session extended once.
---@param opts table
---@param items table[]  -- { type, commit } newest-first; commit.parents/children are Commits
---@param seed table<integer, table>?  -- col -> Lane crossing in from above
---@param yield (fun())?  -- chunking hook; called every YIELD_ROWS rows
---@return table[] rows
function M.layout(opts, items, seed, yield)
    return M.session(opts, seed).extend(items, 1, yield)
end

return M
