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
  branch-mode toggle helpers `next_mode` / `selected_owner_ids` / `toggle_target`
  (§10/§10.4), the **expanded marker** label text (§6; `icons.expanded`), and the **linked-worktree refs** (§3.2/§4.1): `parse_worktrees`
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
- `tests/label_color_spec.lua` — every ranked ref's label takes **its own ref's
  colour** (§6 "Label colour"), through the real `display_item` with the row's
  `ref_colors` / `ref_levels`: a branch group's bracket and name in the local's
  colour, each `↑remote` in its own slightly muted colour, a tag in its node's
  colour **as drawn** (at the selected ref's level); a label keeps its own colour on
  another ref's track (no lane owner); a remotes-only group in its first remote's
  colour; a ref without a colour on its row per-kind; a collapsed `◍` head's labels
  in their identity colour at their level; a packed marker row's labels in identity
  colour and a tag in its own marker's node colour (a count-only unit in its node's
  colour); the **lumeeditor shape** through a real `columns.layout` (every policy:
  `origin/dev` and its node muted dev, the remote-only label keeping its own
  colour); the attached label's `HEAD → ` prefix and a detached `HEAD` in
  `palette.head`, the h/l-selected label `palette.selected`, a pointer mark its
  `hl`; `lane_label_colors = false` → per-kind everywhere (tags included) with
  tracks still coloured; panes: `pane_labels`' `arrow` span and each group's
  colouring members and `↑remote` spans. Plus **muted remotes** (§5.5, §12.2):
  `slot_hl(-k)` the `remote_mute` blend of slot k (default 0.25, cached, flat without
  truecolor), `counterpart_dim` as its alias (the new name winning), out of the cone
  the `remote_mute_out` blend (default `0.75 * dim`) brighter than every dimmed
  colour, a remote's label and node muted in the cone / brighter-dimmed out of it, a
  local's label out of the cone the plain dim. **Three brightness levels**: levels
  1/2/3 draw distinct groups (full, `remote_mute` 0.25, `collapsed_mute` 0.45);
  `collapsed_mute` replaces `remote_mute`, is configurable, `0` turns it off and a
  junk value falls back to the default; out of the cone level 3 blends its slot colour by `collapsed_mute_out`
  (default 0.45, the level of a level-1 colour out of the cone, configurable, junk falls back; no stacking); in the cone with the
  highlight on levels 2 and 3 both blend by `highlight_mute` (default 0.1,
  configurable, junk falls back) while the highlight off keeps 0.25 / 0.45; a `◍` head's label dims by that composed
  blend. **Remote-only marker** (`icons.remote`): `rank.input`'s `remote_only` lists
  exactly the remote-only identities' members; `⇣` on a remote-only group, never on
  a paired remote or a local group; order pin, expanded, remote, name; `""` off;
  drawn in the label's colour; in pane labels (the `↑remote` spans shifted) and on
  packed marker units. The pane window glue (`render_pane`) is untested
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
  node or junctions — each vertical coloured by its lane slot); plus the **pair
  bracket** through the real `display_item`, mirrored and not: `┬` directly before
  row 1's labels and `└` directly before row 2's message, the fixed columns untouched, the glyph
  in `palette.pair` and dimmed out of the cone, `pair = false` a same-width blank,
  a custom `dual_bracket` (and `{ "┬ ", "└ " }` restoring the gap), `dual_prefix_bytes` (the row-2 cursor byte offset), the
  §16 match highlight shifted with it, a labelless dual commit byte-identical to
  `right` and `right`/`inline` unprefixed
- `tests/listview_spec.lua` — the multi-real-line bookkeeping (spec §6.1 dual):
  the buffer-line ↔ item offset map (`rebuild_starts`/`item_index_at`: mixed line
  counts, clamping, the incremental append path) and a windowed smoke test (snacks
  stubbed with a real window) that an item renders the right number of real buffer
  lines and that `relayout` grows the buffer when a mode switch makes a commit two
  rows, and that `set_items` swaps the whole list and re-lays the buffer (the
  reflow-swap primitive; §10.5), and that `set_items` / `refresh` / `relayout`
  with the host window gone (closed / hidden) re-lay the buffer and render
  nothing (the `Invalid 'win'` regression)
- `tests/own_owners_spec.lua` — a row's own owners (§10.2) over real interned
  signatures and plain sets (`select.own_owners`), the `<Space>` target
  (`select.toggle_target`: multi-ref fold, a branch on top kept, `◍` expand of own
  owners only, the shared-stretch fallback, mainline), first-parent-only reach
  through `view.project`, and `select.owner_label`.
- `tests/space_toggle_spec.lua` — `<Space>` through the window glue over a stub
  ctx (`window._internal.branch_under_cursor` / `toggle_branch`): owners acted on,
  the `still open via …` / mainline notices, the palette's named entries, and the
  §6 expanded set from `reflow_owners` / `pin_marks`.
- `tests/pin_spec.lua` — the ordered pin list (§10.6) + the dialog (§10.6.1):
  `pin_resolve` (the unplaced defaults first — HEAD's anchor last among them —
  then the stored entries, a new pin at the bottom; unpinned suppressed,
  stale refs dropped, entries `{ id }` alone — a stray legacy `reserved` field not
  carried), `pin_move` (clamped at both ends, reports the new index), `pin_remove`,
  `pin_add` (appends at the bottom, idempotent), `pin_ids`, and `pin_dialog_lines`
  (numbering with no dedicated-lane marker, the key help without a `<Space>`
  toggle, the add row, the row map, the aligned help column). Plus a **windowed
  smoke** block driving the real dialog in a real float over a stub ctx
  (open/`<C-j>`/`D`/`q`, and `<Space>` unbound — it edits nothing and does not
  reflow) — the keymaps, re-render and focus handoff, which the pure tests cannot
  reach.
  Plus **a pin covers the identity** (§10.6): `pin_rank` (entries only, by place)
  and `pin_anchors` (pinning a local anchors its paired remotes and a differently
  named upstream; pinning a paired remote anchors the whole identity, local
  included; a remote-only branch every remote of its short name; an explicit unpin
  drops one member, never an entry; a tag entry anchors itself only), `pin_owner`
  / `pin_normalize` (a remote with a local recorded as the local, one entry per
  identity at its first place) and dialog lines without identity-member rows.
  `tests/window_internal_spec.lua` covers `effective_pins`/`effective_pinned`/
  `pin_rank`/`sync_pin_rank` (default order with HEAD's anchor last, entries
  `{ id }` alone, a pinned identity's remotes anchors but not entries and never
  rows, dropped with the identity's last entry or by an explicit unpin, the removed
  `pin_upstream` ignored, the ranks published on `opts` + `pane_opts`, a legacy
  stored `origin/feature` pin read as `feature`, pinning `origin/dev` with a local
  `dev` giving one entry with `dev` level 1 / `origin/dev` level 2 and a pinned
  remote-only branch level 1, and a detached HEAD pinning the `HEAD` ref last /
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
