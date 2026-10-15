# Refs, labels and selection tests

Scope: per-spec coverage of ref classification and labels, HEAD, the ref picker / cycle, h/l selection, label modes, the listview, pins and the pin dialog. [specification.md](../../../specification.md) and [ARCHITECTURE.md](../../../ARCHITECTURE.md) remain authoritative. Index: [../testing.md](../testing.md).

- `tests/refs_spec.lua` — `classify_ref`, `group_refs` (compact ref display,
  incl. carrying a tracked local branch's upstream onto its group; §6.3, and
  moving the branch HEAD is on — the head ref's `branch`, else the fallback — to
  the FRONT flagged `current`; none when detached), `head_summary` (the
  post-checkout notice, incl. §10.4.1's behind suffix — strictly behind /
  diverged only, never ahead-only / gone / detached), `decoration_texts` / `pane_labels` drawing it first as
  `(HEAD → name …)` (§6),
  `track_segments` / `track_label` (the upstream divergence indicator's coloured
  segments + byte-identical plain label: ahead/behind/diverged/gone/in-sync),
  `decoration_texts` + `ref_picker_items` upstream threading (§6.3),
  `owners_from_refs` (view-builder owners per ref; an attached HEAD skipped, a
  detached HEAD an owner with id `HEAD`; §10/§10.6), the
  branch-mode toggle helpers `next_mode` / `selected_owner_ids` / `collapse_owners`
  (§10/§10.4), and the **linked-worktree refs** (§3.2/§4.1): `parse_worktrees`
  (the `git worktree list --porcelain` stanza parser — main-vs-linked, bare,
  detached *derived* from a HEAD with no branch, basename from either path
  separator), `worktree_refs` (the `wt:<dir>` labels + all three skips: the main
  worktree, bare/headless, and **any commit an existing ref already points at** —
  which subsumes "checked out on a branch"; two worktrees on one commit yield one
  label; the caller's `taken` set is not mutated), and the new kind flowing
  through `group_refs` (its own `worktrees` bucket) / `decoration_texts` +
  `pane_labels` (`{wt:<dir>}`, after the tags) / `ref_decoration_index` /
  `selected_owner_ids` / `owners_from_refs`; plus the **pin icon** (§6/§10.6):
  `decoration_texts` / `pane_labels` / `marker_units` given a `PinMarks` prefix a
  pinned ref's label inside its bracket (branch group via its local or any listed
  remote ref, tag, worktree), never HEAD's label (attached or detached), and
  `icon = ""` turns it off
- `tests/head_marker_spec.lua` — HEAD's node marker (§5.3) through the real
  `get_column_chars`: `●` in `palette.head` for the commit carrying the `head` ref
  (attached / detached), overriding tip / root / the merge icon; a §4.2 virtual
  node keeps `◌`; a collapsed head holding HEAD keeps `◍` in the HEAD colour; an
  out-of-cone HEAD node dims; `icons.head` honoured and `""` turns it off; and a
  laid-out graph marks exactly HEAD's row, mirrored or not
- `tests/label_color_spec.lua` — the label OWNING a node's lane takes its lane
  colour, every other label its per-kind group (§6 "Label colour", §12.2), through
  the real `display_item`: a plain row's first label (branch group incl. `↑remote`)
  equals the node glyph's `get_column_chars` colour while its tag is per-kind;
  ownership (`label_owner`): a counterpart lane `-k` born here belongs to the
  counterpart's group even when another remote branch is listed first, a pinned
  lane to its pinned ref's group, a pinned colour whose ref is elsewhere / a pin
  past the palette fall back to the first label, a lane born for a pinned
  detached HEAD going to the first OTHER label (branch group, else tag; the bare
  `HEAD` stays `palette.head` and never owns — with no other label none does; the
  pane path's `label_owner` likewise), a packed marker's
  labels each coloured on their own, a collapsed head's owner; `origin/HEAD` is
  no label (`classify_ref`); the **lumeeditor shape** through a real
  `columns.layout` (`compact` + `gutter`: pinned `dev` at X, `origin/dev` +
  `origin/leppanen/validation` on its child Y, an unlabelled Z above — Y's node is
  `-1` and only `(dev ↑origin)` takes it); `pane_labels`' `key`s; a `gutter` `own_lane_up` node colours them from the up wire (unflagged:
  the down wire); a collapsed `◍` head; each marker of a packed row its OWN node
  colour; the attached label's `HEAD → ` prefix and a detached `HEAD` keep
  `palette.head`, the h/l-selected label `palette.selected`, a pointer mark its
  `hl`; out of cone the label is `dim_hl` of the lane colour (a packed marker per
  marker), in cone / no pivot undimmed; `lane_label_colors = false` restores the
  per-kind groups everywhere. Panes: `pane_labels`'s `arrow` span and `node_lane_hl` on a
  header-style (segment-level `highlighted`) row matching the glyph. The pane
  window glue (`render_pane`) is untested
- `tests/ref_picker_spec.lua` — the ref-picker pure pieces (spec §2, `<leader>b`):
  `bump_recent` (the session MRU list — newest first, deduped, input not mutated),
  `ref_picker_items` (name → Ref registry → ordered picker entries: session-
  recent first in MRU order then grouped HEAD / local / remote / tag by name,
  commitless refs skipped, fields the picker shows incl. the match `text`), and
  `ref_decoration_index` (picked ref → its decoration index for pre-selection:
  local/remote → branch group by short name, tag → after the branches, HEAD/absent
  → nil)
- `tests/ref_cycle_spec.lua` — the `%` local ⇄ remote branch cycle (spec §2):
  `ref_cycle_members` (local first, then remotes in `git remote` order, then any
  unlisted remote by name — the fallback before `ctx.remotes` loads; only existing
  refs; same-commit members included), `ref_cycle_next` (the step + wrap-around,
  starting from a remote, a remote-only branch, `alone` with the short name for no
  counterpart, `none` for a tag / worktree / HEAD / unknown ref; stepping past a
  member whose commit is not in the `visible` set — wrapping round, `hidden` with
  the short name when no other member is visible), `visible_hashes` (the jumpable
  set: row commits, collapsed regions, packed markers + their regions — what
  `goto_hash` finds) and `cycle_source`
  (the h/l-selected decoration, else the first branch label with HEAD's first; nil
  on a tag- / worktree- / detached-HEAD-only or ref-less row). The window glue —
  the jump and the `ctx.ref_cycle_last` grouped-member memory — is untested.
  `tests/palette_spec.lua` asserts the real registry offers `%` in the commit and
  branch contexts (not markers / selection)
- `tests/selection_spec.lua` — `move_selection`, `decoration_texts`,
  `ref_byte_col` (h/l ref selection + cursor parking), `pack_right`
  (the right-pinned ref width budget), `window_right` (the selection-windowed
  overflow, §6: a contiguous window around the selected ref with separate
  left/right `+N` markers; greedy right-then-left growth; the selected item always
  shown even when it alone overflows; sel clamping; empty), and `refresh_columns`
  width aggregation from `below` and from every stacked `above`/`below` row (§6.1);
  plus `label_occurrence` + `ref_byte_col`'s `nth` (repeated marker labels such
  as `(3)`, for cursor parking), and **mirroring keeps the logical label order**
  (§5.4): `display_item`'s labels in logical order under `mirror` in `inline` /
  `dual` / `right` mode, a selected index unchanged
- `tests/ref_window_spec.lua` — the windowed right-ref overflow **end to end** (§6),
  incl. HEAD's label staying visible ahead of the `+N` (attached `(HEAD → x)` and a
  detached bare `HEAD`):
  gitloom's `display_item` (setting `line_right` + `line_right_sel`) feeding the
  listview's `build_line` windowing, rendered into a stubbed window — default shows
  whole labels + a trailing `+N` (overflow hidden), selecting the overflowed ref
  scrolls it fully into view with the cursor target (`ref_byte_col`) resolving to
  it, and a single over-long selected ref truncates cleanly with `…` within the
  window (never spilling past the edge); the **pin icon** is part of the drawn label
  (windowed into view when selected, found by `ref_byte_col`, never on HEAD's
  label); plus the **packed marker row** (§10.4):
  its labels left-align after the graph (`line_right_align = "left"`) but window the
  same way around the selected marker (`+N` overflow, selected scrolled into view)
- `tests/label_mode_spec.lua` — the dual label mode's continuation graph
  (spec §6.1): `passthrough_columns` in both directions (`up` keeps lanes
  entering from above, `down` keeps lanes leaving below — the message row;
  a crossing keeps only its through-vertical; edge objects shared so §12 dimming
  still applies) and its rendering via `get_column_chars` (only `│`/blanks — no
  node or junctions — each vertical coloured by its lane slot); plus the **message
  row indent** through the real `display_item`, mirrored and not: row 2's message
  `DUAL_INDENT` (2) cells past an unlabelled commit's, row 1 and the fixed columns
  untouched, the §16 match highlight shifted with it, a labelless dual commit
  byte-identical to `right` and `right`/`inline` unindented
- `tests/listview_spec.lua` — the multi-real-line bookkeeping (spec §6.1 dual):
  the buffer-line ↔ item offset map (`rebuild_starts`/`item_index_at`: mixed line
  counts, clamping, the incremental append path) and a windowed smoke test (snacks
  stubbed with a real window) that an item renders the right number of real buffer
  lines and that `relayout` grows the buffer when a mode switch makes a commit two
  rows, and that `set_items` swaps the whole list and re-lays the buffer (the
  reflow-swap primitive; §10.5), and that `set_items` / `refresh` / `relayout`
  with the host window gone (closed / hidden) re-lay the buffer and render
  nothing (the `Invalid 'win'` regression)
- `tests/pin_spec.lua` — the ordered pin list (§10.6) + the dialog (§10.6.1):
  `pin_resolve` (the unplaced defaults first — HEAD's anchor last among them —
  then the stored entries, a new pin at the bottom; unpinned suppressed,
  stale refs dropped, defaults never reserved), `pin_move` (clamped at both ends,
  reports the new index, carries the flag), `pin_toggle_reserved`, `pin_remove`
  (**unpin implies unreserve** — re-adding comes back unreserved), `pin_add`
  (idempotent), `pin_ids`, `reserved_order` (reserved-only, in list order — the
  order's meaning for *columns*; for lane identity every entry's place is its
  rank, `pin_rank`), and `pin_dialog_lines` (numbering, `◆` on reserved
  rows only, the key help, the add row, the row map, the aligned help column, the
  "not honoured yet" note). Plus a **windowed smoke** block driving the real
  dialog in a real float over a stub ctx (open/`<Space>`/`<C-j>`/`D`/`q`) — the
  keymaps, re-render and focus handoff, which the pure tests cannot reach.
  Plus the **implicit remote counterparts** (§10.6): `pin_counterparts` (same
  short name in `git remote` order, unlisted remotes by name, then a differently
  named upstream; none for a remote / tag) and `pin_rank` (with counterparts on
  — the anchor set: rank = place, a counterpart sharing its local's, an explicitly
  unpinned counterpart excluded, an explicitly pinned remote keeping its own; with
  them off — the layout's `opts.pin_rank`, entries only) and dialog lines without
  counterpart rows.
  `tests/window_internal_spec.lua` covers `effective_pins`/`effective_pinned`/
  `pin_rank`/`sync_pin_rank` (default order with HEAD's anchor last, nothing
  reserved by default, counterparts implicit anchors but NOT in the layout's rank
  map (§5.5: no rank, no pinned colour) and never rows,
  dropped with their local or by an explicit unpin, the ranks published on
  `opts` + `pane_opts`, and a detached HEAD pinning the `HEAD` ref last /
  unpinnable / dropped once attached), and `reconcile_refs` stamping
  the head ref's `branch` (nil when detached); plus the **default selection**
  (§2/§5.4) over a stub ctx in a scratch window: `on_cursor_moved` pre-selects
  the first marker on a packed line and the first label on a dual-mode label row
  — mirrored or not — leaves other rows / modes on the message, and
  `cursor_hash` with no marker selected yields the first marker's tip.
- `tests/detached_head_spec.lua` — a detached HEAD is an anchor everywhere a pinned
  ref matters (§2/§6.2/§10.6.1): `select.head_target` (the open / return focus —
  HEAD's commit attached or detached, nil only without a HEAD commit),
  `pane.decline` (the panes' hide reason — off / no HEAD commit / no display, never
  for a detached HEAD) and `select.pin_candidate` (the dialog's "Pin new branch…"
  list — a detached `HEAD` offered, an attached one never, pinned refs skipped).
  The callers are window glue, not unit-tested
