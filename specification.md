# gitloom.nvim — Specification

This is the behavioral contract: *what* gitloom does, independent of *how*
it is implemented. Implementation details live in
[ARCHITECTURE.md](ARCHITECTURE.md).

This document is authoritative. When behavior changes, update this file
first (see [CLAUDE.md](CLAUDE.md) → Spec-First Development).

## 1. Purpose and scope

gitloom's primary goal is to be an excellent **git graph viewer**. The graph
is the product. Other git functionality is deliberately out of scope, except
where it falls naturally *out of* the graph (e.g. acting on the commit under
the cursor) or is delegated to an existing plugin (e.g. opening a diff in
diffview).

### 1.1 Own the model

gitloom does **not** wrap `git log --graph`. It reads commit and ref data
from git and builds the commit DAG, the row ordering, and the lane layout
itself, in memory. Owning the model is a hard requirement, not an
implementation detail: the planned view features — collapsing, pinning,
toggling branch visibility, and reflowing (§10) — are only possible if
gitloom controls ordering and layout rather than delegating them to git.

Today the view is read-only and shows a single fixed projection of the graph.
The view-transformation features in §10 are the direction this is built
toward; the current non-graph surface (window, streaming fetch, rendering)
exists primarily to exercise and validate the graph algorithm.

## 2. Entry point

- `:GitloomGraph` opens the graph for the repository at Neovim's current
  working directory.
- The window is a floating window. `q` closes it; `m` cycles the merge/split
  rendering style (§5.2) so the styles can be compared at a glance; `M` toggles
  graph mirroring (§5.4); `B` cycles the **ref label mode** (§6.1) so the ref
  placements can be compared at a glance. `<Tab>` is the quick **collapse ⇄
  expand toggle** for the branch under the cursor (§10.4): it collapses an
  expanded branch or expands a marker, in place, and the cursor follows so
  repeated `<Tab>` flips it open/closed. `<CR>` opens an **action menu** for the
  row (§10.4) — examine the commit, open its diff, collapse / expand / hide the
  branch — most-relevant action first.
  `D` opens that commit's diff in an external diff viewer via the configured
  provider (§11.5; a no-op on a collapsed head). Two debug
  aids: `K` opens a float with the full lane breakdown for the commit under
  the cursor, and `i` toggles the per-lane id column before the message (a
debug aid, hidden by default). `d` toggles the date column between absolute and
relative (§6). `H` toggles reachability highlighting (§12) off and on. `c`
toggles the first-parent focus (§10.7) — collapse every non-mainline branch, or
show the full graph. `p` toggles **marker packing** (§10.4) — merge concurrent
collapsed heads onto shared lines, or one per line.
  `?` opens a float listing all keybindings. The footer shows live status
  (the active merge mode and ref label mode, a `N collapsed, M hidden` summary
  when any branch modes are set, and `(mirrored)` when mirroring is on).
- **Navigation.** Navigation is line-by-line (`j`/`k`, arrows, etc. move whole
  rows), with `cursorline` marking the current row (§7). The cursor is parked at
  the **commit message** rather than left at column 0. `h`/`l` move a selection
  across the current row's ref decorations — the branch groups then tags (§6);
  the selected decoration is highlighted (`palette.selected`) **and the cursor
  moves onto it**. The message is the default position (the cursor parks there);
  since refs are pinned to the right edge, `l` moves **right** onto the refs
  (starting at the first) and `h` moves **left** back toward the message.
  Selection clamps at the last ref and resets to the message when the cursor
  moves to another row. In the **dual** label mode (§6.1) the refs sit on the
  commit's first row (with the node) and the message on its second row, both real
  lines the cursor occupies normally: landing on a labelled commit's first row
  **pre-selects the first** ref (so `h`/`l` refine an already-active selection),
  and the cursor sits physically on the selected ref. This selection is the
  substrate for the planned
  per-branch actions (collapse / hide / pin, §10); it has no effect yet. The
  row under the cursor also defines a **pivot** whose reachable history
  (ancestors and descendants) is emphasised while everything else dims (§12).
- The view opens immediately and is populated asynchronously as git output
  arrives; the window must not block on git completing.

## 3. Data source

Two independent queries, joined by commit hash.

### 3.1 Commits

Commits are read via `git log` with:

- `--topo-order` — topological ordering (children before parents).
- `--parents` — full parent hash list per commit.
- a refspec, default `--all`.

Each commit carries: hash, parent hashes, author, author date, subject. The
author date is read as a Unix epoch (`%at`) plus its tz offset (from `%ai`) and
parsed into a structured `Timestamp` (§4), not kept as text. Refs are **not**
taken from `--decorate`; they come from §3.2.

### 3.2 Refs

Refs are read via `git for-each-ref` over `refs/heads`, `refs/remotes`, and
`refs/tags`, yielding for each ref its refname, target hash, and — for
annotated tags — the dereferenced commit hash. The current branch is read via
`git symbolic-ref` (HEAD). Each ref is resolved to the `Commit` it points at
by hash (§4.1).

Using a dedicated, structured query rather than parsing `git log --decorate`
makes ref discovery robust and makes remote branches and annotated tags
first-class (the decorate field conflated them and dropped remotes).

## 4. Data model

```
Commit    = { hash, parents: Commit[], children: Commit[], refs: Ref[],
              author, date: Timestamp, message }
Ref       = { name, kind, commit: Commit }
Timestamp = { epoch, offset, raw }
```

- `Commit.date` is a parsed `Timestamp`, not a string: `epoch` is the author
  date as Unix time (UTC), `offset` is the author's tz offset in seconds (so
  the author's local wall-clock is `epoch + offset`), and `raw` keeps the
  original `%ai` text. Formatting happens at render time (§6).
- `Ref.kind` is one of `local`, `remote`, `tag`, `head`.
- `Ref.commit` is the `Commit` the ref points at — a **direct reference, not a
  hash**. `Commit.refs` lists the refs pointing at it (the inverse). A
  name → `Ref` registry is kept on the repository.
- Commits are identity-stable: a commit referenced as a parent (or by a ref)
  before it is seen in the log is the *same* object once its own log line
  arrives.
- Every hash reference resolves to a `Commit`: parent hashes and ref targets
  become `Commit` references once resolved. A target not in the fetched range
  still exists as a (sparse) `Commit` placeholder so the graph and refs stay
  connected, filled in when (if) its log line arrives.
- Child links are the inverse of parent links.

### 4.1 Ref resolution

Each ref is classified by its refname and resolved to its target commit:

| refname                          | kind     | name shown            |
|----------------------------------|----------|-----------------------|
| `refs/heads/<name>`              | `local`  | `<name>`              |
| `refs/remotes/<remote>/<name>`   | `remote` | `<remote>/<name>`     |
| `refs/tags/<name>`               | `tag`    | `<name>` (annotated tags resolved to their commit via the dereferenced hash) |
| HEAD (symbolic)                  | `head`   | marks the current branch's commit; a detached HEAD is not marked (current limitation) |

`refs/remotes/<remote>/HEAD` (the remote's default-branch symref) is skipped.
The target hash is looked up in the commit table; a missing target yields a
sparse `Commit` placeholder (as above).

## 5. Graph layout

The layout is the visual projection of the commit graph. Its vocabulary, from
the model outward:

- **Commit** — a node in the DAG (§4).
- **Lane** — one drawn **edge, child → parent**:

  ```
  Lane = { id, color, begin: Commit, end: Commit, highlighted: bool }
  ```

  `begin` is the child (above), `end` the parent (below); `id` is the lane's
  stable identity (born once, never reused); `color` is its palette slot, which
  drives the rendered colour (kept continuous along a first-parent chain, so a
  line of history reads as one colour); `highlighted` marks it for the
  reachability emphasis (§12). There is one Lane per parent/child edge. Colours
  are drawn from a recycling **free list** (§5.5), so concurrent lanes get
  distinct colours. *(A future **Route** — a contiguous run of Lanes forming a
  path — is not modelled yet.)*
- **OrderItem** — the visual unit for one Commit: its order position, the Commit
  it shows, the Lanes incident to it (`parent_lanes` out to its parents,
  `child_lanes` in from its children), and its rendered **Lines**. This is the
  commit ↔ visual bridge.
- **Line** — one rendered row: a sequence of **Columns**. An OrderItem has a
  *commit line* and, per the merge style (§5.2), an optional *split line* (above)
  and/or *merge line* (below). Exactly one Commit's node sits on the commit line;
  the split/merge lines carry only wires.
- **Column** — one cell of a Line: the **Segments** through it, plus the Commit
  node when one sits here. (`GraphColumn` in the code.)
- **Segment** — a single wire within a Column: its `connectivity`
  {up, down, left, right} and the **Lane(s)** it carries. Each drawn edge gets
  its own Segment — one per Column normally, two where wires cross. The one
  exception is the single descent into a merge (or ascent out of a split) on a
  separate split/merge line: that wire is shared by every converging/diverging
  edge, so it is one **multi-edge** Segment, highlighted when *any* of them is —
  which keeps a non-trunk cone lane connected through the hub (§12).

The graph is walked top to bottom (newest heads on top, roots at the bottom), so
a Lane's `begin` (child) is always already placed when its `end` (parent) is
reached. A Column's rendered **glyph** is a function of the union of its
Segments' connectivity; its **colour** is one carried Lane's `color`, chosen by
a "top" strategy that prefers a highlighted Lane (§12). A commit's first parent
continues in the commit's column and **reuses the incoming lane's `id` and
`color`**, so a straight first-parent chain reads as one colour; a fresh `id`
and a free-list `color` (§5.5) are taken only where a lane is born — a branch
head, or a merge's second-and-later parent.

### 5.1 Invariants

- **One commit per Line.** Exactly one Commit's node is placed on a commit line;
  the virtual split/merge lines carry none. *Exception:* a **packed marker line**
  (§10.4) carries several markers' nodes — messageless collapsed heads merged
  onto one line — each in its own lane column.
- **Two-sided Segments.** Each Segment touches exactly two of its Column's sides
  (a wire enters and exits) — one side only at an endpoint (a Lane's `begin` or
  `end`). This forces crossings (`─│─`) and tees to be modelled as *separate*
  Segments, not one over-connected wire.
- **Every Lane is an edge.** A Lane has both a `begin` (child) and an `end`
  (parent), both placed Commits (or the fetched-range boundary). Its Segments run
  from `begin`'s line down to `end`'s line; no Lane fizzles into nothing.
- **Edge attribution.** Each Segment carries the actual Lane(s) it draws — the
  edge `(begin, end)` — so two wires that share a Column or cross stay distinct
  by edge identity. The shared descent/ascent Segment at a separate split/merge
  hub carries the set of edges converging/diverging there.
- **Per-Lane continuity.** A Segment of Lane L with `down` on one Line meets a
  Segment of the *same* Lane L with `up` in the same Column on the next Line.
- **Root column break.** A root (a commit with no parents) ends its lane with
  nothing below it. The column it occupies is **not reused** by any vertical wire
  or commit node on the immediately following Line, so an independent history
  beneath a root is offset into another column instead of stacking under it (which
  would read as one continuous lane). A horizontal wire may still cross that
  column on the next Line (a crossing, not a continuation).
- **Colour comes from a carried Lane.** A Column's colour is the `color` slot of
  one Lane on one of its Segments (§5.5).
- **Connectivity consistency.** The glyph's wired sides equal the union of the
  Column's Segments' connectivity (every wired side has a Segment providing it).
- Merges (commit with >1 parent) fan out `parent_lanes`; splits (>1 child) fan in
  `child_lanes`.
- **Compact column reuse.** A fanned-out parent lane (a merge's extra parent)
  takes the **leftmost column that has been free since before its Line** — an
  interior gap an earlier branch vacated — rather than always opening a new
  rightmost column. So a staircase of sequential feature-branch merges stays a
  bounded width instead of growing one column wider per merge. A column a
  *terminating* child frees is reusable by an outgoing parent only when that does
  not place two turns in one cell: when the fan-out is on a **separate merge Line**
  below (the child already ended on the commit Line above, so the column is simply
  free) or under `allow_merge_on_split` (the sanctioned inline two-turn cell, §5.2).
  Otherwise — an inline fan-out sharing the commit Line with the fan-in — the
  freed column is left for the next Line to reclaim, so two adjacent merges may
  alternate columns by one. Reusing the column on a separate merge Line is what
  keeps that style from leaving an empty-column gap that bounces a right-aligned
  (mirrored, §5.4) graph.
- **Commit compaction.** A *linear* commit (reached by a single child-lane) slides
  into the leftmost column free since row start, its incoming lane turning into the
  new column. So a branch born one column out — an inline merge-on-split that had
  to fan past a freed cell — compacts next to the trunk after a single jog rather
  than running stranded beside an empty column for its whole length. The slide
  reserves its column before survivor compaction, so a survivor keeps any nearer
  gap; the lone jog is a turn, not a straight run, so id-continuity holds.

Edge attribution (`begin`/`end` per Lane, and a Segment's edge set) is the model
contract that makes the §12 reachability emphasis exact and the planned §10 view
work and lane navigation possible. The handoff split (an incoming child-lane and
an outgoing parent-lane sharing a column) remains two distinct Lanes.

### 5.2 Merge style

`merge_style` selects where merges and splits are drawn:

- `split_on_separate_line` — when set and a commit has >1 child, the fan-in
  is drawn on a virtual line **above** the commit row.
- `merge_on_separate_line` — when set and a commit has >1 parent, the fan-out
  is drawn on a virtual line **below** the commit row.
- `allow_merge_on_split` — permits placing a merge onto a split lane when
  merges are folded onto the commit line. In this mode an incoming child-lane
  and an outgoing parent-lane can share a column (a "lane handoff"): the cell's
  `up` segment and `down` segment belong to *different* lanes. The **model**
  represents these faithfully as two separate lanes (so per-lane continuity
  holds); the **rendered** glyph is a single cell that can only show one
  color, so its color is best-effort and may read as continuous across the
  handoff. The model is the contract here, not the coloring.

When a separate line is not used, the merge/split is folded onto the commit
row itself.

### 5.3 Glyphs

Lanes render as box-drawing characters derived from connectivity
(`│ ├ ┤ ┬ ┴ ┼ ╭ ╮ ╯ ╰ ─` and the terminal half-segments; `┼` only as a
node-less junction, §10.4). Commit markers:

| Marker | Meaning |
|--------|---------|
| `◎`    | root commit (no parents) |
| `◉`    | tip commit (no children) |
| `○`    | ordinary commit |
| `◍`    | collapsed head (a contracted region, §10.3) |
| merge icon | merge commit when merges are folded onto the line and `icons.merge` is set |

### 5.4 Mirroring

By default the graph is **mirrored**: the cell sequence of each row is reversed
and each cell's `left`/`right` connectivity is swapped before glyphs are
derived, so the graph reads right-to-left with lane 1 at the **right** edge of
the graph column, nearest the commit message. The graph column is right-aligned
(padded on the left) so vertical wires stay column-aligned across rows of
differing lane counts. Setting `mirror = false` (§8) renders it the
conventional way, left-to-right with lane 1 at the left.

Mirroring is purely a rendering transform: the commit ordering, the lane
layout, and the lane model (ids, `child`/`parent`, per-lane continuity) are
unchanged — only the projection to glyphs is flipped. Because the glyph is a
pure function of connectivity (§5), the mirrored glyphs (`╭`↔`╮`, `┤`↔`├`,
`╴`↔`╶`) and the inter-lane connectors fall out of the model with no separate
glyph-swap table, and color (lane color slot) is preserved. All §5.1 invariants
hold on the mirrored output.

### 5.5 Lane colouring (the free list)

A lane's colour is a **palette slot** drawn from a recycling **free list**,
seeded with the curated `palette.tracks` colours (§8). A born lane takes a slot
from the front; an ended lane returns its slot to the back (FIFO), so a colour is
not reused immediately. Allocation happens **before** the same line's ended lanes
return their slots, so concurrent lanes always have distinct colours.

**Breathing room.** A returned colour is held out of reuse for the next
`palette.buffer` allocations (§8); if no colour is free *and* cooled down when a
lane is born, a colour is **generated** instead. This guarantees at least
`buffer` other colours are drawn before any colour repeats — a history that ends
is never immediately followed by a new one in the same colour. Curated colours
are used first (they start available), so generation only begins once branching
outpaces the cooled-down curated colours.

**Generation.** Overflow colours are generated in **OKLCH**, rotating hue by the
golden angle (~137.5°) at a lightness/chroma **anchored to the theme** (derived
from `palette.tracks`/`Normal`, or set explicitly, §8), so they stay in the
theme's key while staying perceptually separated at any count. Generated colours
recycle like curated ones but are **retired** (dropped, not returned) once the
list is comfortably full again — so a graph that quiets down drifts back to the
curated palette, and only sustained branching shows generated colours. **Curated
colours are never retired.**

Generation requires truecolor. Without `termguicolors`, nothing is generated: the
curated palette is **shared** on exhaustion (a slot reused, reference-counted so
it returns only when its last holder ends; a lane is never recoloured, since that
would break its colour continuity).

A first-parent continuation keeps the trunk's slot (one colour per first-parent
chain, §5); only a branch head or a merge's extra parent allocates.

## 6. Row content

A commit row displays, left to right:

1. author date — formatted from the `Timestamp` (§4) either as an **absolute**
   author-local time (via the configurable `date_format`, default
   `%Y-%m-%d %H:%M`) or as a **relative** age (e.g. `3 days ago`). The
   `date_mode` selects which; `d` toggles it live.
2. author name
3. graph lanes (glyphs)
4. commit subject (the message)
5. ref decorations — placed by the **label mode** (§6.1); by default pinned to
   the **right edge** of the row

The date, author, and graph are width-aligned across visible rows. To avoid the
aligned widths **bouncing** as different-length values scroll past, a column can
be *sticky* — it only grows, never shrinks: the **author** column is sticky with
a cap (max 25, longer names truncate), and under mirroring (§5.4) the **graph**
column is sticky too (its right-aligned content would otherwise shift as the lane
width changes). The message and refs share the remaining width **per row** (not as
a fixed aligned column, so navigation stays line-by-line): in the default mode the
refs are right-aligned at the window edge and the message fills the gap, truncated
with `…` when it does not fit.

**Ref decorations** — a `HEAD` marker on the current branch, then branch
groups, then tags as `[name]`. Branch refs (local + remote) that share a
**short name** collapse into one group: the name is shown once, followed by the
remotes that also point at this commit, as `(name ↑remote1,remote2)`. The name
is highlighted when a local branch exists and dimmed when the group is
remote-only. A local branch with no matching remotes is just `(name)`. This
keeps the common case (a branch plus its remote-tracking copies all at one
commit) from repeating the name per remote.

**Ref width budget.** The refs use the row's free width: they may take
everything the message does not need — its natural width, but never reserving
more than `message_min` (§8). So refs fill empty space when the message is
short, while a long message still keeps at least `message_min` columns
(truncated with `…`). Ref labels are shown in order (leftmost first) until the
budget is reached; labels that do not fit collapse into a trailing `+N` overflow
marker. Each field is colored by its `palette` highlight group; lanes are
colored by a palette slot allocated from a recycling free list (§5.5).

The `h`/`l` selection (§2) cycles all of a row's ref decorations. One collapsed
into the `+N` overflow can still be selected, but until it is visible it is not
highlighted and the cursor falls back to the message (revisited with the §10
actions).

### 6.1 Ref label modes

How a row's ref decorations are *placed* is selected by `label_mode` (§8) and
cycled live with `B` (the footer shows the active mode). The grouping and the
selectable order (HEAD marker, branch groups, then tags) are identical in every
mode — only the placement differs:

- **`right`** *(default)* — refs are pinned to the **right edge** of the commit
  line and the message fills the gap, with the width budget and `+N` overflow
  above. This is the layout the rest of §6 describes.
- **`inline`** — refs are rendered **left-aligned immediately after the graph,
  before the message**, on the commit line (branch first, then the subject).
- **`dual`** — a labelled commit is drawn on **two real rows**: the **first row**
  carries the graph (with the commit's node) and the **ref labels** left-aligned
  after it; the **second row**, directly below, carries the commit **message**,
  with the graph's lanes continued downward as vertical wires (the same lane
  layout, with **no node placed** on that row). Only commits that actually have
  ref decorations get the second row; a commit without labels stays a single row
  (node + message, as in `right` without the right-pin). Both rows are real buffer
  lines and belong to the same commit: navigation (§2) treats them as two rows of
  one commit — `<CR>`/`D` act on that commit from either row, and reachability
  (§12) dims both together. The cursor parks on the **labels** on the first row
  (landing on a labelled commit pre-selects the first label, so `h`/`l` refine it)
  and on the **message** on the second row. The two rows stack with the §5.2
  split/merge virtual lines as: split line (fan-in), label row, message row, merge
  line (fan-out).

In every mode an out-of-cone row dims its refs with the rest of the row (§12),
and a selected ref is drawn with `palette.selected`. The **context panes** (§6.2)
render every row topology-only, the same render style as markers (§10.4).

### 6.2 Context panes (header / footer)

The graph window may carry two **context panes** — a **header** above the main
viewport and a **footer** below it — that summarise the topology *off-screen* in
each direction so the main branches stay in view while scrolling. They are
**read-only**: no cursor, no selection, no navigation; they are a map, not a
surface to act on.

**One projection, three viewports.** The header, main view, and footer are three
windows onto a **single** laid-out projection (§10), not three independent
layouts. The header renders the rows *above* the main viewport's top line, the
footer the rows *below* its bottom line (down to and including the **root
commit(s)**). Because it is one lane sweep, lanes are continuous across both
boundaries by construction — the main view's top row *is* the header's bottom
row.

A pane has **height 0** (is hidden) whenever there is no off-screen topology in
its direction: the header vanishes when scrolled to the top of the graph, the
footer when scrolled to the bottom (the roots are then already on-screen). This
falls out of the sizing rule below (`G = 0` at the extreme).

**What they show.** Panes render **topology-only** (§10.4): graph glyphs and ref
labels only — no date, author, or message. Off-screen topology is folded onto
the **pinned anchors** (§10.6): an anchor's line is drawn; everything else is
contracted.

**Boundary lane-continuity (invariant).** Every lane crossing a viewport
boundary **must** connect to something in the pane — no lane dangles at the edge.
A region that *touches* the boundary is therefore never folded away; its crossing
lane is preserved and terminated explicitly. This is the "wires must connect"
grid invariant (§5.1) lifted to the window edge.

**Non-anchor termination.** How a crossing non-anchor lane ends is the tunable
part (expected to need iteration), but the choice is binary:

- **merges into an anchor** — if its commits are reachable from a pinned owner
  (their signature, §10.2, contains an anchor), the lane is drawn up to the
  junction where it joins the anchor, then folded into the anchor's lane;
- **terminated minimally** — otherwise it is **capped at the boundary row** (an
  up/down arrow glyph with the branch name, e.g. `↑ feature/x`), costing no extra
  pane rows.

**Sizing.** Panes are **content-driven within a cap**, computed so the size is
stable (no scroll-induced bounce, §6 sticky principle):

- **Header.** Height is a pure function of the scroll offset `S` (the main view's
  top line): `H = clamp(G(S), 0, header_max)`, where `G(S)` is the folded row
  count of the prefix above `S`. There is no feedback loop (the top line is set
  by scrolling, not by `H`). To avoid the main view's height twitching as `G(S)`
  changes, `H` **grows immediately but shrinks only on settle** (debounced), the
  same anti-bounce rule as sticky columns. When the fold exceeds `header_max`, the
  surplus collapses into a trailing **`+N above`** overflow indicator.
- **Footer.** The footer anchors to the main view's *bottom* line, which floats
  with the main height, so its size is a mild fixed point; it is resolved by
  reserving a **fixed** footer height (the footer is small — roots plus a few
  anchor tails) or, if made dynamic, by monotone iteration to `footer_max`.

**Asynchronous update.** Pane content is recomputed **off the main render path**:
a scroll or view-state change schedules a debounced pane rebuild that must
**never block or slow the main view**. The main view scrolls and renders
immediately; the panes catch up (a brief stale pane is acceptable, a stalled main
view is not). The boundary lanes the main view already drew are the source of
truth a pane rebuild must match.

Panes are configurable (on/off, `header_max`, `footer_max`); when off the graph
is the single viewport as today. (Config wiring shares the §8 "known gap" — the
options are specified here, not yet read by the command.)

## 7. Rendering behavior

- Rendering is **viewport-driven**: only rows within the visible range are
  laid out and drawn. Scrolling triggers layout of newly visible rows.
- The view updates incrementally as commits stream in.
- The buffer is non-modifiable to the user (`nofile`, read-only).
- The window uses `cursorline` as the current-row indicator and keeps the
  cursor parked at the commit message (or, when a ref is selected, on that ref);
  see §2.
- The pivot's reachability cone is emphasised by dimming everything outside it
  (§12); the cone is recomputed over the visible rows on row change and scroll
  (debounced — see §12).

## 8. Configuration

`GraphOptions` (see [README.md](README.md) for the full default table):

```
GraphOptions = { win, palette, merge_style, icons, branches, mirror, highlight,
                 date_format, date_mode, message_min, label_mode, diff }
MergeStyle   = { allow_merge_on_split, merge_on_separate_line, split_on_separate_line }
Diff         = { open: fun(range: DiffRange), label: string }
DiffRange    = { rev: string, from: Commit?, to: Commit }
```

- `win` — floating-window geometry (snacks.win).
- `palette` — highlight group per field, plus a `tracks` list whose entries are
  the curated lane colours, the seed of the recycling free list (§5.5). Lane
  colouring is tuned by `buffer`, the minimum free-list length — the number of
  other colours drawn before a released colour can repeat (default `3`);
  `generate`, whether overflow colours are generated in OKLCH when the curated
  ones run low (default `true`, automatically disabled without truecolor); and
  `anchor`, the lightness/chroma the generated colours are built on (default
  `nil` = derived from `tracks`/`Normal`; §5.5).
  Includes `selected`, the highlight for the `h`/`l`-selected ref decoration
  (§2; default `Visual`); `diff`, a sub-table of highlight groups for the
  commit view's diff: `add`, `delete`, `hunk`, `header` (defaults `DiffAdd`,
  `DiffDelete`, `Title`, `Comment`; §11.3); and `action`, the highlight for the
  commit view's diff action label (default `Special`; §11.5); and `dim`, the
  blend factor (`0`–`1`) toward the window background used to de-emphasise
  out-of-cone rows and lanes (§12; default `0.45`; higher is more muted). On
  terminals without true colour, dimming falls back to a flat `NonText`
  highlight instead.
- `highlight` — whether reachability dimming (§12) starts enabled. **Default
  true.** Toggle live with `H`.
- `branches` — ref argument(s) for `git log` (default `--all`).
- `mirror` — render the graph mirrored with lane 1 at the right edge of the
  graph column, nearest the message (§5.4). **Default true.** Set false for the
  conventional left-to-right layout. Purely a rendering transform; ordering and
  lane layout are unchanged. Toggle live with `M`.
- `date_format` — `os.date` format string for absolute dates (default
  `%Y-%m-%d %H:%M`), rendered in the author's local time.
- `date_mode` — `absolute` (default) or `relative`; selects the initial date
  rendering (§6). Toggle live with `d`.
- `message_min` — the minimum width always kept for the message (default `24`);
  the right-pinned refs use the rest of the free width, with overflow becoming
  `+N` (§6).
- `label_mode` — where ref decorations are placed: `"right"` (default), `"inline"`,
  or `"dual"` (§6.1). Cycle live with `B`.
- `diff` — the external diff provider (§11.5): `open` is a function called with a
  `DiffRange` to open the diff (default opens diffview), and `label` is the
  commit view's action-label text (default `▶ Open diff (diffview)`). Override
  `open`/`label` to use a different diff plugin; set `open` to `nil`/`false` to
  disable the integration (no action label, `D` is a no-op).

### Known gap: setup() wiring

`require("gitloom").setup(opts)` stores `opts` in the module config, but the
`:GitloomGraph` command currently invokes the graph with built-in defaults
and does **not** read that stored config. Forwarding `setup()` config to the
command is unimplemented. Until then, the documented defaults always apply to
`:GitloomGraph`. (Programmatic callers may pass options directly to the graph
open function.)

## 9. Non-goals

**Permanently** out of scope: repository mutation of any kind (no checkout,
commit, rebase, reset). gitloom is a viewer.

Acting on the commit under the cursor is reasonable where it arises naturally
from the graph, and the **commit view** (§11) is the first realization of it: a
read-only detail view of the selected commit, including its diff. Integration
with external diff plugins is realized through a pluggable provider (§11.5,
default diffview) rather than gitloom rendering its own rich diff. These are
secondary to the graph itself and must not compromise the model-ownership
principle (§1.1).

## 10. View model and transformations

> Status: **specified contract; implementation in progress.** The graph is a
> *projection* of the immutable commit model under a **view state**. Changing
> the view state reflows the projection.

### 10.1 Branch modes

Each **owner** has a mode. An owner is one of:

- a **ref** (its tip commit);
- an **anonymous merge-parent** — each *non-first* parent of a merge, identified
  by `(merge-hash, parent-index)`, so merged-in work that has no ref of its own
  can still be collapsed/expanded (and so the first-parent default, §10.7, has
  something to attach to);
Under the first-parent focus (§10.7) **every** owner is *first-parent-only*
(§10.2) — it covers only its tip's first-parent line. The **trunk owner** (the
current branch, HEAD) is just the one that defaults to normal, so HEAD's mainline
stays in full.

Modes:

- **normal** — the owner's commits are shown in full.
- **collapsed** — the owner's commits are contracted to a single *collapsed
  head* row.
- **hidden** — the owner's commits are removed from the view.

Modes are independent: any owner may take any mode. The UI may restrict the
choices it offers; the model does not.

### 10.2 Attribution — the reachability signature

For each commit `c`, its **signature** `sig(c)` is the set of owners that can
reach `c`. Reachability is **first-parent-only** under the first-parent focus
(§10.7): an owner reaches `c` only along *first-parent* edges from its tip, so it
covers its tip's mainline but stops at every merge instead of descending the
merged-in side. This is what attributes a commit to the branch it is actually
*on*, not to every branch whose history merged through it — so collapsing or
expanding one branch never drags in the earlier branches it merged past. (With
focus off there is no trunk and every owner is full-reach — any parent edge — but
the projection is then the identity, so it does not matter.) Signatures are
monotone along the DAG: an ancestor's signature is a superset of its
descendants'. Commits therefore partition into **regions** — maximal connected
runs of equal signature — whose boundaries fall exactly at junctions where an
owner joins or leaves.

A region's display mode is the **join** over the owners in its signature:

- empty signature (reached by **no** owner) → **normal**; only owners can hide,
  so an uncovered commit stays visible
- some owner, but no non-hidden one (all hidden) → **hidden**
- any **normal** owner in the signature → **normal**
- otherwise (all collapsed) → **collapsed**

Intended consequences:

- A commit reachable from only one owner B follows B's mode.
- A commit shared by a hidden owner and a retained one stays visible — hidden
  owners never force removal of a commit a retained owner still reaches.
- A combined region below a junction is normal if *either* side is normal, and
  collapsed only if *all* its owners are collapsed; hidden owners don't vote.

### 10.3 Contraction — collapse preserves shape, hide removes

Only a **linear run** of collapsed commits contracts to a single collapsed-head
row. A collapsed commit that is a **junction** — a fork (two or more *visible*,
i.e. non-hidden, children) or a merge (two or more visible parents) — is **never
collapsed away**: it stays its own visible row, so the branching is intact. (A
signature boundary, where owners meet, is likewise a region boundary.) Hiding
all-but-one of a junction's branches demotes it to a linear commit that may then
collapse.

The projection therefore has the **same branch topology as the commit graph**:
every fork and merge of the visible commits survives, with only the linear
stretches between them contracted to heads. Edges crossing a collapsed region's
boundary re-point to its head, so a head is never left floating.

Hiding removes a region's rows outright and, unlike collapse, does **not**
preserve shape. An edge from a hidden region into a retained commit is dropped
(a phantom indicator is an open question, §10.8).

### 10.4 Markers and packing

A **marker** is a messageless node: it shows topology, not content. There are
two kinds:

- a **collapsed head** (§10.3) — the `◍` node, the region's ref label(s), and a
  compact collapsed indicator (a commit count). It carries **no message, date, or
  author**: a head stands for a whole region of commits, so any single value
  would misrepresent it. It exists only to show that the region exists and how it
  connects to the trunk — uncollapse for detail;
- a **kept junction** (§10.3) — a fork/merge inside collapsed branches whose
  commit is just a split point. It renders **node-less**: the cell draws the
  fork/merge as box-drawing lanes (`├ ┬ ┼ …`) instead of a node, with no
  message — so the split topology shows without the commit's visual weight. Any
  refs on it are still shown. Controlled by the `junction_markers` option
  (default on); off renders those junctions as full commits.

**Topology-only rendering.** A marker's row shows *topology, not content* —
graph glyphs and ref labels only, no date, author, or message. This is a
**render style**, not a mode: it is how collapsed heads and kept junctions
already draw, and the context panes (§6) render **every** row this way (branch
names only). Any row may be rendered topology-only without changing its place in
the model.

**Packing.** Because markers carry no message, several may share one physical
line. A maximal run of consecutive markers that are **mutually concurrent** (none
an ancestor of another) and whose lanes stay continuous is **packed** onto one
line: each marker keeps its own lane column and its edges, so branch topology is
unchanged, and the line lists the union of their ref labels. This is the one
exception to "one commit per line" (§5.1). Message-bearing commit rows never pack
(a Phase A limit; the general adaptive case is §10.8).

Packing is **on by default**, toggled live with `p` and via a config option;
with it off, every marker occupies its own line.

**Interaction.** Collapse/expand acts on the **region under the cursor**, found
through each commit's signature (§10.2) — not through a ref — so it works for any
collapsed region, including ref-less ones (first-parent-merged, squashed). A
commit the trunk reaches (the mainline) is not collapsible.

- `<Tab>` — the quick **collapse ⇄ expand toggle**: collapse the expanded branch
  under the cursor (set its non-trunk owners collapsed), or expand the marker
  under the cursor (set its owners normal). Two-state — *hidden* is not in this
  cycle, so the toggled thing never vanishes from under the cursor. After the
  reflow the cursor is repositioned onto the resulting node (the new marker, or
  the expanded region's tip), so repeated `<Tab>` flips it open/closed in place.
- `<CR>` — an **action menu** for the row: every applicable action, most-relevant
  first (examine commit, open diff, collapse, expand, **hide**). This is where
  hidden and full mode control live, and it is the overflow-proof way to reach
  any marker on a packed line even when not all labels fit.

On a packed line, `h`/`l` selects among the markers (all of them, regardless of
which labels fit); `<Tab>` and the menu act on the selected marker. Reachability
emphasis (§12) follows the selection, or is neutral when none is selected.

### 10.5 Reflow

Any view-state change recomputes the projection from scratch (not appended) and
is **stable**: regions unaffected by the change keep their relative order and
do not visually churn. Row order is derived from the existing topological order
by dropping hidden rows and contracting each collapsed region to its tip's
position — so ordering ownership (§1.1) is *not* a prerequisite for this
feature.

### 10.6 Pinned branches (anchors)

**Pin** is a per-owner flag, **orthogonal to mode** (§10.1): it marks an owner
as an *anchor* — a branch the view is organised around — without itself
deciding how much of that branch to draw. (This supersedes the earlier
"pinning forces normal" rule: an anchor still obeys its mode, so it may be
collapsed or hidden.)

The pinned set **generalises the trunk** of the first-parent focus (§10.7).
Today HEAD is the single distinguished owner the rest of the graph folds
toward; pinning lets the user name *several* anchors — e.g. `master`, `dev`, a
release branch, a few personal branches. **HEAD (the current branch) is pinned
by default, along with the common trunks `master` / `main` / `dev` when they
exist**; the user may pin or unpin any ref.

Anchors drive two things:

- **The focus default (§10.7).** Pinned owners default **normal**; every other
  owner defaults **collapsed**. So naming the anchors *is* choosing what stays
  in full. The trunk-only case is exactly one anchor. As in §10.7 this is a
  recomputed default, not a seed — explicit per-owner overrides win.
- **The context panes (§6).** The header/footer summarise off-screen topology
  *folded onto the anchors*: a non-anchor lane crossing the viewport boundary
  is drawn only until it merges into an anchor, and otherwise terminated
  minimally. The boundary lane-continuity invariant and pane sizing are
  specified in §6.

Pin is part of the view state; changing it reflows the projection (§10.5).

### 10.7 First-parent default

By default the graph opens **focused on the current branch**: HEAD's
first-parent mainline is shown in full and everything else — branches merged
into it *and* divergent branches — is collapsed. This is a per-owner **default
mode**, not a one-off seed: each reflow recomputes it, and `view state` holds
only the user's explicit overrides on top.

Under focus **every owner is first-parent-only** (§10.2) — each covers only its
own tip's first-parent line. The defaults are:

- the **pinned owners** (HEAD pinned by default, §10.6) → **normal**; a pinned
  owner's first-parent line is the mainline (plus the history shared below
  merge-bases), so those stay visible;
- **every other owner** (unpinned refs, and the anonymous merge-parents) →
  **collapsed**.

The trunk-only case (HEAD the sole anchor) is the default; "trunk" below reads
as "the pinned set" once more than one ref is pinned (§10.6).

Because the trunk is first-parent-only, it does not reach a merged-in branch, so
that branch's only owners are collapsed → it collapses, **even when a ref points
at it** (the ref defaults collapsed too). And because *every* owner is
first-parent-only, a branch is attributed to the commits on its own first-parent
line — so a feature ref does not reach the earlier features its history merged
through, and collapsing/expanding one branch (§10.4) affects only that branch
(branches genuinely built on top of one another are the exception — they share a
first-parent line and move together). A commit reachable only via collapsed
owners collapses; the shared mainline stays normal (the §10.2 join). The result
is "current branch in full, every other branch a `◍` head."

The user's explicit toggles (§10.4) override the default per owner, so any
collapsed branch can be expanded and any branch hidden.

This behavior is controlled by the **`collapse_merged`** option (default on) and
can be toggled live; with it off, every owner defaults **normal** (the plain
full graph) and no trunk/anonymous owners are introduced. When HEAD is absent
(detached or a bare checkout) there is no trunk, so the graph also falls back to
all-normal.

### 10.8 Open / deferred

- **Adaptive layout** — Phase A packs only *consecutive* concurrent markers, so
  in a first-parent focus view (where each merged head sits between mainline
  commits, not next to other heads) packing rarely fires. Making it effective
  needs **reordering**: cluster concurrent markers into a band within their valid
  topological range (a merged head's range is its merge … its fork), then pack.
  Beyond that: *packing* junction markers (they already render node-less, §10.4,
  but don't yet share lines), and letting markers ride on message-bearing lines
  when they fit, toward a fully adaptive density (greedy row packing). Deferred.
- **Hidden connectivity** — phantom indicator vs. vanish.
- **Scale** — unbounded reads in large repositories; the loading strategy
  (limits, lazy/streamed loading, on-demand reachability) must keep reflow
  responsive.
- **Toggle UX** — `<CR>` on a selected ref cycles its mode and `<CR>` on a head
  expands it (implemented); a picker for setting many at once is still future.
- **Context panes** — header/footer windows showing off-screen topology folded
  onto the pinned anchors (§10.6), with lanes continuous across the viewport
  boundary. To be specified in §6. Pane recomputation must be **asynchronous /
  debounced** and must never block or slow the main view's scroll and render.
- **Stronger-than-collapse fold** — contracting a non-anchor branch onto its
  boundary commit (the merge, or for squash-merged work the fork point) as a
  label + count with no head row or lane, a level between collapse and hide.
  Open refinement.

## 11. Commit view

Pressing `<CR>` on a commit row opens the **commit view**: a separate read-only
floating window showing the full details of that one commit. `q` closes it. Like
the graph, it is a viewer — it never mutates the repository (§9).

### 11.1 Data source

The commit view's data is fetched **on demand** when it is opened — a single
`git show -s` for the selected commit's hash — *not* taken from the streaming
graph model. The graph model (§3, §4) deliberately carries only what the graph
needs (author, author date, subject); the richer per-commit detail (email,
committer, full message body) is read only when a commit is actually opened, so
the streaming path stays lean. The refs shown are the row's existing decorations
(§6), reused from the model rather than re-queried.

The diff is fetched the same way, on demand, by a second `git show --format= -p`
for the commit, chained after the metadata fetch; the view renders once both
arrive.

### 11.2 Content

The first line is the **diff action label** (§11.5) — when a diff provider is
configured — and the cursor is parked on it when the view opens, so `<CR>`
(open the commit view) then `<CR>` (on the focused label) opens the diff. Below
it the view shows, in order:

1. the full commit hash;
2. the ref decorations on the commit (the same compact groups as §6), when any;
3. the **author** — name, email, and date;
4. the **committer** — name, email, and date — shown **only when it differs**
   from the author (the common case where they match is omitted to reduce
   noise);
5. the parent commits (abbreviated hashes), when any;
6. the full commit message — subject and body — indented;
7. the **diffstat** — the list of changed files with per-file insertion /
   deletion counts (§11.4) — shown between the message and the diff;
8. the commit's diff (the patch), shown below the diffstat.

The author and committer dates are shown as `git show` renders them
(`--date=iso`); the structured `Timestamp` formatting of §6 applies to the graph
date column, not here.

### 11.3 Diff

The commit view shows the commit's diff below the diffstat (§11.4). Highlighting is
**line-level** (matching git's default and lazygit/tig): each patch line is
colored by its role — added, removed, hunk header (`@@ … @@`), and file header
(`diff --git`, `index`, `---`/`+++`, mode/rename/new-file lines); context lines
are uncolored. The highlight groups come from `palette.diff` (§8), using
always-defined UI groups by default, applied as extmarks — the view does **not**
switch the buffer to `filetype=diff`, so the custom metadata header above stays
unaffected. Language-aware (intra-line) syntax highlighting of the diff content
is a possible future enhancement. While the diff is scrolled, a **context
header** keeps the current file and hunk visible at the top of the view (§11.6).

A **submodule** bump (a `160000`-mode hunk whose body is two `Subproject commit`
lines) is intercepted and, when the conditions of §11.7 are met, augmented with a
small change graph in place of — or above — the two raw hashes.

### 11.4 Changed-files list (diffstat)

Between the message and the diff, the commit view shows a **diffstat**: a
summary line (`N files changed, X insertions(+), Y deletions(-)`) followed by one
line per changed file — the path, its insertion/deletion counts, and a colored
`+`/`-` bar (the `+` segment in `palette.diff.add`, the `-` in
`palette.diff.delete`; §8). Renames are shown as `old => new`; a binary file
shows `Bin` instead of counts.

The diffstat is **derived from the same patch** that §11.3 renders — not a
separate query — so the file list, the counts, and each file's location in the
diff all come from one source.

Pressing `<CR>` on a changed-file line **jumps** the cursor to that file's
section in the diff below (scrolling it to the top of the view). This makes the
diffstat a table of contents for the diff. The jump is recorded in the
jumplist, so `<C-o>` / `<C-i>` move back to the diffstat and forward to the diff
section as usual. When `<C-o>` would step back *out* of the commit view (its
next jump target is another buffer, or there is none left), it **closes the
commit view** instead of leaving its buffer — so `<C-o>` backs all the way out.
`<CR>` elsewhere in the view does nothing.

### 11.5 External diff

gitloom does not render a rich (side-by-side, syntax-highlighted) diff itself;
it **delegates** to an external diff plugin through a pluggable provider
(§8 `diff`). The provider operates on a **range**, not a single commit, so
richer commit selections on the graph can reuse it later (commit-vs-commit,
commit-vs-working-tree, a tag range, …); a single commit is just one way to
construct a range.

A `DiffRange` is `{ rev, from?, to }`: `rev` is a git rev-range the diff tool
understands (e.g. `<hash>^!` for a commit's own changes, `<a>..<b>` for a span,
or an empty-tree range for a root commit), and `from`/`to` are the structured
endpoint commits (`from` is `nil` for a root). The provider's `open(range)` is
called to display it; the default opener runs diffview on `range.rev` and, when
diffview is not installed, reports that instead of erroring. Overriding `open`
(and `label`) switches to another diff plugin — diffview is therefore an
**optional dependency**, not required.

Two entry points construct a single-commit range (`<hash>^!`, or an empty-tree
range for a root) and call the provider:

- the graph's `D` key, on the commit under the cursor (§2);
- the commit view's **action label** — the first line, where the cursor parks on
  open (§11.2) — activated with `<CR>`.

The action label text is `diff.label` (default `▶ Open diff (diffview)`),
highlighted with `palette.action`. When no provider is configured (`diff.open`
is unset) the label is omitted and `D` is a no-op.

Planned: graph-side range selection (building on the §2 selection substrate and
§10 view work) to pick two commits and feed the same provider.

### 11.6 Diff context header

While scrolling the diff (§11.3), the commit view shows a **context header**: a
small borderless overlay pinned to the top of the view naming the location the
top of the **viewport** currently sits inside — independent of the cursor. It
carries up to **two lines**:

1. the **file** — the path from the governing `diff --git` / `+++` header;
2. the **hunk** — the governing `@@ … @@ <section>` line.

The **effective top** is the first diff row that remains visible *below* the
overlay — i.e. the window's top line advanced past the overlay's own height, so
the header never merely repeats a line it is covering. "Governing" means the
nearest file / hunk header at or above that effective top.

Each line appears **only when its real header has scrolled above** the effective
top; while a file's `diff --git` line or a hunk's `@@` line is still on screen
below the overlay, that line is omitted. So between a file header and its first
`@@`, only the file line shows; with neither scrolled off, the overlay is empty
(zero height) and invisible. The header is likewise absent while the viewport
top is still in the metadata / diffstat region (§11.2/§11.4) — it exists only
over the diff proper.

The two lines reuse the §11.3 diff highlight groups — the file line as a
`header`, the hunk line as a `hunk` (`palette.diff`, §8). The overlay never
takes focus and never mutates the buffer; like the graph context panes (§6.2)
it is pure decoration recomputed as the window scrolls.

### 11.7 Submodule change view

A commit that bumps a submodule pointer changes only an opaque value: the diff
(§11.3) carries the change as a `160000`-mode hunk whose body is the old and new
`Subproject commit <hash>` lines. Two hashes say *that* the submodule moved but
nothing about *how*. When the submodule's history is available locally, gitloom
replaces (or augments) that pair with a **small change graph** — the same
graph model (§4, §5) applied to the submodule's own repository — visualizing the
relationship between the old commit `A` and the new commit `B`.

This is a graph-viewer feature, not general submodule support: gitloom reads the
already-checked-out submodule and **never fetches**. It is strictly read-only
(§9) and renders inline in the commit view's diff region.

#### 11.7.1 Availability — the gate

The change graph is shown **only when all** of the following hold; otherwise the
view falls back to the two raw `Subproject commit` hashes (§11.3), with a
one-line reason where useful:

- the hunk is a submodule change (`160000` mode, a `Subproject commit` pair);
- the submodule is **checked out** — its path (from the diff header) resolves to
  a working git repository;
- **both** `A` and `B` are **present** in that repository (resolve as commits).

No fetching is attempted to satisfy the last two. A missing checkout or a missing
commit is an expected, non-error state — the raw hashes remain, annotated
(e.g. "submodule not checked out", "commits not present locally").

#### 11.7.2 Classification — the relationship

When the gate passes, the old/new pair is classified by their relationship in the
submodule's DAG, computed from the **merge-base** of `A` and `B`:

- **Fast-forward** (`A` is an ancestor of `B`) — the common case, a forward bump.
  The graph shows the range `A..B` — the commits the bump brings in — condensed
  (§11.7.3), labelled `+N` (N commits ahead).
- **Rewind** (`B` is an ancestor of `A`) — the pointer moved backward. Same as
  fast-forward over `B..A`, labelled `−N`.
- **Diverged** (a merge-base exists but neither reaches the other) — there is no
  single line between them. The graph is **glanceable only**: the fork-point
  (the merge-base) and the two tips `A`/`B`, with the ahead/behind counts
  (`+X / −Y`). The two divergent paths are **not** drawn — the point is to show
  *that* and *where* they split, not to read either side commit-by-commit.
- **Unrelated** (no merge-base — disjoint histories) — falls back to the raw
  hashes (§11.7.1), noting the histories are unrelated.

Direction is intrinsic: `A` is always the old pointer and `B` the new, so a
fast-forward and a rewind are distinguished by which one is the ancestor, not by
any heuristic.

#### 11.7.3 What is shown — bound, decorate, mark, truncate

For a fast-forward or rewind the change graph is the commits the bump moved
through, run through the existing graph pipeline (§4, §5):

1. **Bound — first-parent.** The graph follows the moving tip's **first-parent**
   line down to the fork point (`git log --first-parent base..tip`), and includes
   the fork point itself as the bottom anchor. This is the same first-parent
   focus the main graph uses (§10.7): a merge on this mainline stays a single node
   (its subject still shown) but the **merged-in side branch is not pulled in** —
   so the change graph never sprouts a lane that "comes from nowhere" because the
   range boundary cut a side branch's root off. The full-merge traversal
   (`base..tip` with every parent) is a possible later option (§11.7.5).
2. **Decorate.** The commits carry the submodule repository's **own ref
   decorations** (§6) where refs actually point — gathered the stable way (refs
   *pointing at* a commit, via git's own `%d` decoration), **never** by walking
   forward toward children (an unstable, child-derived direction). gitloom does
   **not** guess a "current branch" for the range; meaningful tips appear only
   because a ref genuinely lands on them.
3. **Mark the pointers.** The **old** and **new** pointer commits (`A` and `B`)
   are labelled in the graph, so it is clear which row the submodule moved *from*
   and *to*. For a fast-forward the new pointer is the tip (top) and the old
   pointer the bottom anchor; for a rewind they swap.
4. **Truncate.** The commits are newest-first; when there are more than fit, only
   the **newest** are kept — plus the bottom anchor (the old/new pointer at the
   fork point, never elided) — with a "+K more" indicator for the commits dropped
   between. The commits are *not* condensed: collapsing the linear stretches away
   would hide the very commits the bump introduced; the point here is to show
   them. The diverged case (§11.7.2) is inherently already minimal — the two tips
   and the fork point only.

The **detail level** of a kept commit — topology-only (graph + ref labels, like
the panes) versus showing the subject — is an open point expected to iterate
(§11.7.5); the structure above (gate, classification, bound/decorate/mark/
truncate) is the stable contract.

#### 11.7.4 Fetching and rendering

The submodule queries are **on demand and asynchronous**, like the rest of the
commit view (§11.1). The diff first renders with the raw `Subproject commit`
hashes; when the submodule data resolves, the change graph **replaces them in
place** (progressive enhancement), so a large or slow submodule never blocks the
diff. The queries fire **only** for an actual `160000` hunk that passes the gate
(§11.7.1); a commit that touches no submodule does no extra work. A commit
bumping several submodules gets one change graph per submodule.

#### 11.7.5 Open points

- **Detail level** (§11.7.3): the fast-forward / rewind range currently shows the
  first-parent lane graph with per-commit subjects; a topology-only or condensed
  rendering (collapsing the linear stretches between junctions) is a likely
  configurable refinement, defaulting conservatively.
- **Full-merge traversal** (§11.7.3): an option to walk *all* parents
  (`base..tip` instead of `--first-parent`) so merged-in side branches show — at
  the cost of lanes that dangle where the range boundary cuts a side branch off.
  Deferred; first-parent is the cleaner default.
- **Named divergence**: when no ref points at `B`, a stable "B is on `X`, N
  behind its tip" line (from refs *containing* `B`, when exactly one) could name
  the new pointer's home — deferred, fragile when several branches contain it.
- **Nested submodules** are out of scope for the first cut.

## 12. Reachability emphasis

The row under the cursor defines a **pivot** commit. gitloom continuously
de-emphasises everything not causally related to the pivot, so the pivot's
history and what descends from it stand out.

### 12.1 The causal cone

The pivot's **cone** is computed by walking the **Lane graph** (§5) from the
pivot in two monotonic sweeps:

- **ancestors** — follow `parent_lanes` (each leads to a parent), recursing;
- **descendants** — follow `child_lanes` (each leads to a child), recursing.

Every Lane reached is set `highlighted`, and the commits it connects (`begin`,
`end`) form the cone. Because each Lane is one edge, the walk is exact: at a
shared fan, the pivot's edge is a distinct Lane from a sibling's, so only the
pivot's edges light. Each sweep never reverses direction, so the cone is exactly
the commits causally related to the pivot — not the whole connected component.

The walk stays within the **currently visible rows**. Because rows are in
topological order (a parent is always at a later row than its child), restricting
to the contiguous viewport loses nothing about relationships *between* on-screen
commits — it only clips the *recursion* at the viewport edges. A cone Lane whose
far endpoint is off-screen is still highlighted (its on-screen stub lights); the
walk simply does not recurse past it.

### 12.2 Dimming

Content **outside** the cone is rendered **dimmed**; the cone keeps full colour:

- a commit **row** — its date, author, message, refs, and commit marker — dims
  when that commit is not in the cone (not a `begin`/`end` of any highlighted
  Lane);
- a **Segment** dims unless a Lane it carries is highlighted. Because a Segment
  carries the exact edge(s) it draws (§5.1), a cone wire stays lit through every
  split and merge it passes — including the shared descent/ascent Segment at a
  separate split/merge hub, lit when one of *its* converging edges is in the cone
  — while an unrelated bar it crosses stays dim.

A Column's glyph is the union of the connectivity of its **highlighted**
Segments (or of all of them when none is highlighted), so at a junction the arms
leading only to out-of-cone edges drop to a small gap while the cone arms stay
connected; a vertical crossing is left whole. The glyph takes the colour of a
highlighted Lane it carries when one is present (so the cone colour wins a shared
cell), else the §5 default.

Dimming preserves colour identity rather than flattening to one grey: each
field's / Lane's own highlight colour is blended toward the window background by
`palette.dim` (§8), so a dimmed Lane keeps its hue and stays individually
recognisable. On terminals without true colour, dimming falls back to a single
flat highlight group (`NonText`).

The emphasis is **on by default** and follows the cursor; it is recomputed when
the cursor moves to a new row and when the view scrolls (the window-bounded cone
tracks the visible rows). Those recomputes are **debounced** — only the last,
once the cursor settles, walks the cone — so fast `j`/`k` navigation stays
responsive. `H` toggles it off and on live (and `highlight`
configures the initial state, §8) — when off, the whole graph renders at full
colour, **identical regardless of the cursor row** (highlight state never affects
colour while it is off).

Planned: lane-anchored navigation — selecting a Lane (`h`/`l`) and stepping
along it commit-to-commit (`j`/`k`) via its `begin`/`end`, with splits and
merges stepping in visual order — building on this Lane model and the §2
selection substrate.
