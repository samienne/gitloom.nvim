# Test seams (`_internal`)

Scope: the test-only `_internal` tables and helper exports the specs reach into. [specification.md](../../../specification.md) and [ARCHITECTURE.md](../../../ARCHITECTURE.md) remain authoritative. Index: [../testing.md](../testing.md).

`graph._internal` (`require("gitloom.graph")._internal`) exposes, **for tests
only** (not the public API): `classify_ref`, `group_refs`, `parse_worktrees` /
`worktree_refs` (the linked-worktree HEAD refs — porcelain parse + the
`wt:<dir>` labelling and skip rules; §3.2), `bump_recent` /
`ref_picker_items` (the `<leader>b` ref-picker MRU + ordered entries; §2),
`ref_decoration_index` (picked ref → decoration index for pre-selection; §2),
`marker_units` (a packed row's selectable marker labels; §10.4),
`display_item` (the per-row renderer — exposed for the §6 ref-window integration
test), `decoration_texts`,
`move_selection`, `ref_byte_col`, `label_occurrence` (which same-text label a
selected one is; cursor parking), `parse_commit_line`, `make_line_buffer`
(the streaming-stdout line de-chunker; §3), `make_future` (the vendored promise;
exposed for `future_spec`), `order_commits` (the owned
topological row sort that replaced `git log --topo-order`; §3.1),
`diff_ref_tips` / `reachable_hashes` (the resync ref-diff + orphan-prune pure
helpers; §3.4), `parse_timestamp`,
`format_absolute`, `format_relative`, `parse_show`, `format_commit_detail`,
`wrap_message` / `message_width` (the §11.2.1 message wrap),
`format_diff`, `diffstat_files`, `format_diffstat`, `commit_range`,
`range_endpoints` / `sel_ascend_children` / `sel_step` / `sel_switch` /
`format_range_detail` (the commit-selection range + path-walking + range-view
metadata pure helpers; §13),
`parse_status` / `worktree_label` / `format_worktree_detail` (the working-tree
virtual-commit pure helpers; §3.3/§4.2/§11.8),
`reachable_cone`, `mark_reachable`, `build_graph` (Phase 1, delegates to
`columns.layout`), `get_column_chars` (Phase 2, the renderer),
`graph_snippet` (the commit-search graph snippet; §15.3),
`passthrough_columns` (the dual label mode's vertical-only branch line; §6.1),
`owners_from_refs` (refs → view-builder owners; §10), the branch-mode toggle
helpers `next_mode` / `selected_owner_ids` (§10), `pack_markers` (the
marker-packing pass; §10.4), `own_owners` / `open_owners` / `toggle_target` / `owner_label` (a row's own
owners, what `<Space>` collapses or expands, and their naming; §10.2/§10.4 —
`own_owners_spec`), the ordered-pin-list helpers `pin_resolve` /
`pin_move` / `pin_toggle_reserved` / `pin_remove` / `pin_add` / `pin_ids` /
`reserved_order` / `pin_dialog_lines` (§10.6/§10.6.1), `smartcase_match` /
`filter_keep` (the filter-search matcher + keep-set; §16.2), `ref_cycle_members` / `ref_cycle_next` / `cycle_source` / `visible_hashes` (the `%` local ⇄ remote
cycle; §2), and `selected_ref` /
`checkout_spec` (checkout; §10.4/§10.4.1 — the row entries themselves are
`require("gitloom.graph.palette").row_entries`).
`window._internal` additionally exposes `keys` (the `GRAPH_KEYS` key registry, §17.1),
`reflow_async` / `resync` (the §19.4 "always ended" glue paths, over a stub ctx),
`branch_under_cursor` / `toggle_branch` / `reflow_owners` / `pin_marks` (`<Space>`'s
target, act and notices, and the §6 expanded set, over a stub ctx; `space_toggle_spec`),
`effective_pins` / `effective_pinned`, `on_cursor_moved` / `cursor_hash_at` (`cursor_hash`; the
default selection; §2),
`pin_dialog` (the §10.6.1 dialog, a windowed smoke-test seam) and `ctx` — the live
graph session, recorded by `open_graph`. The headless smoke test reads the
projected model through `ctx` because without a UI there is no rendered text to
inspect: the listview draws through a decoration provider, so the graph buffer's
lines are all empty.
`columns.layout` is reached via
`require("gitloom.graph.columns")`; the view builder `view.project` (which takes
the §16.3 `keep` set) / `view.signatures` / `view.owners` via
`require("gitloom.graph.view")` (§10).
`tests/graph_helpers.lua` additionally exposes `reference_signatures` (the §10.2
definition transcribed with no sharing — the oracle the interned representation is
compared against) and `line_sig` / `row_sig` (a rendered Line's / row's full cell
content as a comparable string, the cell-for-cell parity dump).
`listview._internal` exposes `pack_right` (the right-pin budget packer),
`window_right` (the selection-windowed overflow packer — window + left/right `+N`
counts; §6), `refresh_columns` (the column-width packer), and
`rebuild_starts`/`item_index_at` (the buffer-line ↔ item offset map for
multi-real-line items; §6.1).
