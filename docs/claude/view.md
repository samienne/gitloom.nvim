# View and selection notes

Scope: the view builder (§10) and what feeds it: signatures, owner coverage, pins and the pin dialog, marker packing, HEAD as an anchor, label modes, multi-real-line items, and commit selection. [specification.md](../../specification.md) and [ARCHITECTURE.md](../../ARCHITECTURE.md) remain authoritative; this file is implementation detail for working on the code. Index: [CLAUDE.md](../../CLAUDE.md).

## Implementation notes

- **Branch modes — the view builder** (`view.lua`, spec §10): a pure
  pre-Phase-1 stage projecting the immutable commit DAG + a view state (per-ref
  `normal`/`collapsed`/`hidden`) into an **OrderItem graph** of DisplayNodes that
  `columns.layout` lays out unchanged. `view.project` computes each commit's
  reachability **signature**, partitions into equal-signature regions, joins to a
  display mode, contracts each **linear** collapsed run to one `◍` head while
  keeping junctions (a fork, or a merge that still has a visible child, stays a
  real node so branch topology survives; a **merge tip** — a collapsed merge with
  no visible child — folds into a `◍` head since it is the branch's tip, §10.3),
  drops hidden commits, and re-points
  edges. graph.lua keeps
  `repo.order` (raw, 1:1 with commits) as the projection input and `repo.display`
  (the projection) as what the listview renders and `order_at`/`mark_reachable`
  index; `reflow()` rebuilds it and swaps via `controller.set_items`. With
  all-normal modes the projection is the identity, so `repo.display == repo.order`
  and streaming keeps its fast incremental path. `<Space>` and the palette's row
  entries set a branch's mode; signatures are cached across mode toggles (§10.5).
- **First-parent focus** (`opts.collapse_merged`, default on; spec §10.7, toggled
  by `c`): `view.owners(items, ref_owners, pinned, modes, cm)` builds the owner
  set so **every** owner is **first-parent-only** (`fp_only`) — each covers only
  its tip's first-parent line. The **pinned anchors** (`pinned`, a set of ref
  ids; §10.6) default normal; every other ref and every non-first merge parent
  (an anonymous `merge:<hash>:<i>` owner) defaults collapsed — so the graph opens
  with the anchors' mainline in full and every other branch a `◍` head.
  `view.signatures` honours `fp_only` (propagate only through `parents[1]`).
  **All owners** being fp-only (not just the anchors) is what makes a branch
  attributed to *its own* commits, so collapsing/expanding one branch doesn't
  drag in the earlier branches its history merged through (spec §10.2). It is a
  recomputed default, not a seed: `view_state.modes` holds only explicit user
  mode overrides, `view_state.effective` the resolved mode per owner (drives the
  `<Space>` toggle's starting point and the footer `focus` indicator). The
  stream-completion handler calls `reflow()` so the default applies on open.
- **Signatures are interned, not materialised** (`graph/sigset.lua`, §10.2): the
  cost of the projection tracks a repository's **merge density**, not its size. An
  `fp_only` owner flows down its tip's first-parent chain, and a merged-in branch's
  first-parent chain **rejoins the trunk** at its fork point — so on a trunk of
  merges every merge above a commit contributes an owner to it and one materialised
  `table<string,boolean>` per commit costs Θ(commits × owners). Measured on a
  12,999-commit / 6,499-merge repository (6,800 owners): **22.1M entries, 813 MB,
  847 ms** for `signatures` alone, against 13,000 entries for a linear history of
  the same length. `sigset` is a **hash-consed 32-way bitwise trie** over dense
  owner indices — adding an owner allocates O(depth) nodes and shares the rest —
  giving 40,579 nodes, 98 ms, and the whole completion pass 1219 → 374 ms
  (814 → 97 MB). Two consequences the projection consumes directly: a set has ONE
  representation (interned on level+base+contents), so "same region" is `a == b`
  instead of a sorted-and-concatenated `sig_key` per commit; and the mode join
  memoises **per node** (`summary`) instead of per commit. The pass ends by
  **sealing** the universe (releasing the hash-cons table + the memos — nothing
  builds sets after it), halving what the §10.5 cache retains, 18.3 → 9.7 MB; a
  sealed universe raises rather than minting a second node for an existing set.
  `view.signatures` still
  returns a `hash -> { [owner id] = true }` table — indexing it materialises that
  one commit's set — so a head's stored `signature` and the §11.7.6 reveal are
  unchanged (the own-owner rule, `select.own_owners`, compares the interned
  handles via `sigset.of` instead: own(c) = owners whose tip shares c's handle,
  §10.2 — what `<Space>`, the palette, the filter jump and the reveal act on); it is deliberately NOT cached per hash (caching
  would let the cursor re-accumulate the footprint) and `pairs()` over the MAP
  enumerates nothing, so any test that iterated it must iterate the items instead
  or it passes vacuously. `view.project` still accepts a plain table of sets and
  takes an equivalent slower path — which is what the parity tests compare against.
- **Total owner coverage** (spec §3.2/§10.2): §3.1 streams `git log --all`, which
  in a repo with **linked worktrees** walks *every worktree's HEAD* — while §3.2's
  ref query reads only `refs/heads`/`refs/remotes`/`refs/tags`. The commit set was
  therefore a strict superset of the ref-reachable set, and those extra commits
  got an **empty signature** → `mode_of`'s "uncovered ⇒ normal" → a run of fully
  expanded rows in a focused view with no `◍` and nothing to pack. Worse, `R`'s
  `prune_to_reachable` deleted exactly those commits, so the open path and the
  resync disagreed. Two changes close it, and both are needed:
  1. **`worktree` refs** — `fetch_refs`/`fetch_ref_entries` chain
     `read_worktree_refs` (`git worktree list --porcelain` → the pure
     `parse.parse_worktrees` → the pure `refs.worktree_refs`), giving each linked
     worktree HEAD *nothing else names* a ref `wt:<basename>`. Skips: the main
     worktree (already the `head` ref), bare/headless, and **any commit an existing
     ref already points at** — the general form of "not if a branch matches", which
     also catches a detached HEAD parked on a tip. `:` is invalid in a refname, so
     `wt:` can never collide in `repo.refs`. A non-zero exit degrades to `{}`.
     Being in `repo.refs` is what makes them owners, pinnable, picker/pane
     entries, and — crucially — resync-reconciled instead of pruned.
  2. **`tip:<hash>` owners** — `view.owners` mints an anonymous fp-only, collapsed
     owner for every in-set commit with **no in-set child** that no ref owns, so
     coverage is total *by construction* whatever else `--all` drags in
     (`refs/original/*` is deliberately not filtered). **§4.2 virtual commits are
     excluded** (`c.virtual`): they are childless by construction and must stay
     visible — they are the case the empty-signature rule exists for.
  Anonymous owners are dropped from pinning structurally, not by a name test:
  `h_pin` filters on `repo.refs[oid]`, which `merge:`/`tip:` ids never satisfy.
- **Pin axis** (spec §10.6, toggled by `P`, managed by `L`): pin is the **anchor**
  set the focus default folds toward — it *generalises the trunk* (one anchor → a
  set). It is stored as **one ordered list**, `view_state.pins` (`PinEntry` =
  `{ id }`, priority order; a stray `reserved` field from an older version is
  dropped) plus `view_state.unpinned` (ids explicitly
  removed, which suppress the HEAD / `master` / `main` / `dev` / seeded-mark
  defaults; HEAD is its branch when attached, the `HEAD` ref itself when detached).
  `ctx:effective_pins()` resolves it (pure core `select.pin_resolve`: unplaced
  defaults — trunks, seeds, HEAD's anchor last — then the stored entries) into
  exactly the dialog's rows. **A pin covers the identity** (§10.6): the other
  members of a pinned entry's identity (`rank.pair` — its local, upstream, same-named
  remotes) are NOT entries but anchors through it. `ctx:effective_pinned()` is
  `select.pin_anchors(pins, pairing, unpinned)` — entries plus identity members,
  minus a member explicitly unpinned — and is what `view.owners` /
  `select.toggle_target` / the pin icon consume. `ctx:pin_rank()` is
  `select.pin_rank(pins)` (entries only, 1 = highest), published as `opts.pin_rank`
  solely for the header: it gets `columns.pinned_slots(pane_opts.pin_rank, #tracks)`
  as `pane.header`'s `avoid`, so its colour de-collision never hands out a pinned
  slot. The **layout** ranks by `opts.ref_rank` (`rank.input`: pairing, pin list,
  current branch, visible and collapsed refs, and while streaming the refspec's
  start set — spec §5 "The ranks are a layout input"), published by
  `GRAPH_HELPERS.sync_ref_rank(ctx, visible, collapsed)`: `ctx:sync_pin_rank()`
  calls it at the top of every `reflow_build` and before the open stream (every pin
  change reflows, so that is the refresh), and `reflow_build` calls it again with
  the projection's **visible** refs — every ref on a node, those folded into a `◍`
  head or kept junction included and also marked **collapsed** (brightness level 3
  unless pinned); under the filter (§16.3) folded refs count as filtered out —
  before laying out. Pinned identities' colours, carried refs and the brightness
  levels are layout matters — see layout.md "Colour session".
  Pinning changes only the default *mode* and the ranks, not `fp_only` or the
  owner tips, so it does **not** invalidate the signature cache
  (like a mode toggle). `P` uses `branch_under_cursor`, pins only real refs (drops
  anonymous merge owners), appends to the list, reflows, and repositions the
  cursor. Anchors are the foundation for the context panes (spec §6.2).
- **The pinned-branches dialog** (spec §10.6.1, `L`): **pinning claims no
  column** (up to four are pinned by default; the former dedicated-lane flag was
  dropped). Every entry's place is its identity's pin rank (§5, `rank.better`'s
  first key, before the brightness level). The other members
  of a pinned identity have no rows; `P` on one records an explicit unpin of just
  that ref. `L` opens a `float_zindex` float rendered
  by the pure `select.pin_dialog_lines` (lines + a line → entry-index row map);
  its buffer-local keys are `<C-j>`/`<C-k>`/`D`/`<CR>`/`q`; each edit writes
  `view_state.pins`, reflows, and restores the graph cursor by hash like `P`.
  `<CR>` and "Pin new branch…" reuse the `<leader>b` picker pieces extracted as
  `ctx:ref_picker_format` / `ctx:jump_to_ref`.
  **NB:** these helpers are `GRAPH_HELPERS` fields rather than module locals
  because window.lua is at LuaJIT's **200-local chunk limit** (a second ceiling
  beyond the 60-upvalue one); new window helpers must go into the tables.
- **Marker packing** (`opts.pack_markers`, default on; spec §10.4, toggled by
  `p`): a **marker** is a messageless node (today a collapsed head — `◍` + ref
  labels + count, no subject). `pack_markers` is a post-Phase-1 pass run in
  `reflow` after layout: it merges adjacent overlay-compatible marker rows into
  one **marker-group** OrderItem (`type == "markers"`, holding the marker
  DisplayNodes + merged columns) — multiple `◍` on one line, the one exception to
  "one commit per line" (§5.1). Overlay-compatible = each column has ≤1 node and
  ≤1 lane id and no horizontal overlap; compaction makes only safe merges
  compatible. On a packed line `h`/`l` selects a marker (`marker_units`); the
  listview stays 1-item-per-line (a group is one item). The marker labels render
  via `line_right` with `line_right_align = "left"` (left-aligned after the graph)
  so they get the windowed `+N` overflow (§6) around the selected marker instead of
  truncating the row with `…`. Selecting a marker drives the §12 reachability
  cone (not a flat `palette.selected` repaint): `update_cone` seeds it from the
  selected head via `mark_node_cone` (walking the DisplayNode `.parents`/
  `.children` and lighting each lane via its shared edge object by `node_loc`, like
  `mark_path`), so the selected branch (its `◍` node, label, and lane) stays its
  normal colour and the sibling heads/branches on the row dim — exactly like
  moving onto a normal head (§12). `h`/`l` calls `update_cone` before the redraw so
  the dimming follows the selection; no selection ⇒ the line is neutral (all lit).
- **HEAD is always an anchor, labelled first** (spec §6/§10.6): the `head` Ref
  carries `branch` (nil when detached). `owners_from_refs` makes a DETACHED HEAD
  an owner with id `HEAD` (re-bound, not renamed, by resync — so pins and mode
  overrides on it follow the checkout); `effective_pins` defaults it in and drops
  a `HEAD` entry while attached. `git.group_refs` moves the current branch's group
  to the front (`current = true`), so `decoration_texts` / `display_item` /
  `pane_labels` draw `(HEAD → x …)` first and `selected_ref` / `selected_owner_ids`
  / `ref_byte_col` agree on index 1 without any change of their own.
- **Ref label modes** (`opts.label_mode`, cycled by `B`; spec §6.1) are a
  placement choice in `display_item`: `right` puts refs in `line_right`
  (right-pinned, default), `inline` composes them into the flex column before the
  message, `dual` draws a labelled commit on **two real buffer lines** — row 1 is
  the graph (node) + labels, row 2 is the message with the graph continued
  downward via `passthrough_columns(item.columns, "down")` (no node). A `dual`
  commit with no labels stays one line. `dual_two_line(opts, commit)` is the
  single predicate shared by the listview's `line_count` (buffer allocation) and
  `display_item` (rendered rows) so they never disagree.
- **Multi-real-line items**: `repo.order` stays 1:1 with commits; the listview
  maps a *buffer line* to its order index via a prefix-sum offset
  (`rebuild_starts`/`item_index_at`, exposed as `controller.item_at`/`item_start`).
  graph.lua's `order_at(line)` is the only boundary translation (used by the
  keymaps, cursor parking, and the cone viewport, which converts `w0`/`w$` to
  order indices). `DisplayElement.lines` (a list of real rows) generalises `line`;
  `above`/`below` are stacked virtual rows attached to the first/last real line.
  Both dual rows open the flex column with the pair bracket
  (`render.dual_prefix`, §6.1); `place_cursor` adds its byte length
  (`render.dual_prefix_bytes` on row 2) so the cursor parks on the labels /
  message, not the multibyte glyph.
  `B` calls `controller.relayout()` (resize the buffer + rebuild the map) because
  it changes per-item line counts; `m`/`M`/`d`/`H`/`i` stay on `refresh()`.
  This is the deferred "real branch line" alternative, now built; the cursor sits
  physically on the labels, and `CursorMoved` pre-selects the first label when it
  lands on a labelled commit's first row.
- **Commit selection (range)** (specification.md §13; toggled by `V`): a modal
  selection that is a **path along one branch** over the visible projection
  (`repo.display`), not a contiguous row block. State lives in `sel` (in `M.open`):
  `path` (DisplayNodes newest-first), `anchor`/`cursor` (the two ends — always
  endpoints, so the path is exactly `anchor..cursor`), and `dparent`/`dchild` (the
  branch chosen at each junction for `h`/`l`). The walk is pure
  (`sel_step`/`sel_switch`/`sel_ascend_children`) over the DisplayNode graph
  (`.parents` first = trunk, `.children`); the window glue resolves rows
  (`goto_hash`), lane/marker emphasis (`mark_path`, reusing the §12 dimming via
  `view_state.cone`), the cursor-on-lane parking, and the range (`selection_range`
  → `range_endpoints` → the **literal** `<older>^..<newer>` `DiffRange` — or, when
  the newer end is a §4.2 working-tree node, a **single-rev** `DiffRange` to a
  tree state, see below). `j`/`k`
  and `<C-d>`/`<C-u>` are bound to walk while active and **fall through to the
  builtin motions** (fed without remap) when inactive; `h`/`l` switch branch while
  active (else the §2 ref selection). `<CR>` opens the **range commit view**
  (§13.5): `open_commit_view(opts, nil, { range, commits, title })` — the same
  view generalised with a `range` arg, listing the selected commits
  (`selection_commits` → `format_range_detail`) and rendering the combined range
  diff (`fetch_range_diff`, shaped from the endpoints — `git diff <base> <to>`,
  `git diff <base>`, or `git diff --cached <base>`) through the existing
  diffstat/diff/context-header pipeline; its action label and `D` open the range
  in the external provider. A `reflow()` recreates DisplayNodes, so it drops any live selection
  (stale references). Navigation walks the DisplayNode edges directly, so it
  passes *through* collapsed heads (including packed ones); a `node_loc` index
  (hash → {item, col}, built with `display_index`) lets `mark_path` light a head's
  lane (the Lane object is shared with the child's row via `seg.edges`) and marker
  even when packed, and `display_item` draws the selected head with
  `palette.selected` and dims the other heads on the shared line (§13.4).
  `selection_toggle` (`<Tab>` while selecting) folds/unfolds the cursor's head in
  place: it captures the path **by member hash** (a head expands to its whole
  region so the unfolded branch stays selected/lit — the diff range is unchanged),
  applies the mode + reflow, re-resolves against a fresh hash→node map (region
  members → their head, dedup consecutive), keeps the anchor on its end and the
  cursor on the toggled end, and restores the saved scroll (`winsaveview`/
  `winrestview` topline) so the view holds.
  Selection isn't started *on* a packed-marker line. The pure helpers are tested;
  the window glue is not (like the other window glue).
- **A selection may end at the working tree** (spec §4.2/§13.2/§13.5): the three
  §4.2 virtual nodes are selectable endpoints, as the **newer** end only. That is
  structural, not a rule — they have no children, so ascending into one ends there
  and it can only ever be the path's newest member; `sel_ascend_children` and
  `enter_selection` therefore carry **no** virtual special case at all (both
  guards added 2026-09-08 were reworked away, not merely deleted). The invariant
  they existed for — *a sentinel hash must never reach a git rev* — is enforced in
  exactly two places instead: `range_endpoints` maps a virtual newer end to a
  **tree state** (`to = "index"|"worktree"`) and emits a **single** rev
  (`--cached <base>` / `<base>`), never an `<a>..<b>` span; and `fetch_range_diff`
  builds its argv from the endpoints' *shape*, asking only a **table** endpoint
  for its `.hash`. Single-rev is the whole point: verified against diffview's own
  `GitAdapter:parse_revs`, a lone rev resolves the right side to `RevType.LOCAL`
  — the real file on disk, so LSP attaches — while `<a>..<b>` gives `COMMIT` blobs
  and `--cached` gives `STAGE` (the index has no on-disk path either; inherent,
  not a defect). The base stays the older end's first parent, run through the same
  tree-state map when *that* parent is virtual (a worktree-only selection), so the
  degenerate `untracked..unstaged` span is `from = "index"`, `rev = ""` — the
  provider's own working-tree-vs-index default. The **untracked** endpoint carries
  `untracked = true` and gets the §3.3 synthesized additions appended to the
  *in-graph* patch only (`git diff <base>` never lists untracked files; without
  them the untracked endpoint would render byte-identically to the unstaged one,
  making the selection invisible) — the external provider needs nothing, since a
  working-tree view lists untracked files itself. `selection_range` /
  `real_newest` / `selection_commits` are unchanged: they still hand over the
  virtual `Commit` and let the range builder decide what it denotes.
  `format_range_detail` synthesizes its row (`working` in the id cell, never the
  sentinel; `worktree_label`'s text).
