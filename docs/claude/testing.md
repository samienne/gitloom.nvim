# Testing notes

Scope: how the suite is organised and the general testing approach; per-spec coverage lives in `docs/claude/testing/`. [specification.md](../../specification.md) and [ARCHITECTURE.md](../../ARCHITECTURE.md) remain authoritative. Index: [CLAUDE.md](../../CLAUDE.md).

## Commands

Tests use plenary.busted.

- `make test` — run every spec in `tests/`
- `make test-file FILE=tests/<name>_spec.lua` — run one spec
- `make lint` — type-check with lua-language-server (`--check`, using
  `.luarc.json`). Resolves the Neovim runtime from `nvim` so `vim.*` is known;
  `tests/types/luassert.lua` is a `---@meta` stub for the busted `assert`
  matchers. Override the binary with `LUALS=...`. Part of the pre-merge
  checklist — keep it at zero problems.
- `tests/minimal_init.lua` sets up the runtime path (plugin + plenary from
  the lazy.nvim install dir) and disables swap/shada.

## Coverage by file

Shared fixtures: `tests/graph_helpers.lua` (with `graph_layout_spec`, see layout.md) and `tests/large_topo.lua` (the real-world topology, see panes.md / layout.md). `tests/window_internal_spec.lua` is described inside the `pin_spec` entry (refs.md); `tests/pane_scroll_gate_spec` in [window.md](window.md) (context panes).

| File | Specs |
|---|---|
| [layout.md](testing/layout.md) | `columns_spec`, `graph_layout_spec`, `graph_mirror_spec`, `pin_rank_spec`, `counterpart_color_spec`, `stream_layout_spec`, `view_spec`, `view_sigset_spec`, `reachability_spec` |
| [panes.md](testing/panes.md) | `pane_spec`, `header_replay_spec`, `footer_replay_spec`, `screen_window_spec`, `footer_bottom_spec`, `footer_window_spec`, `header_window_spec` |
| [refs.md](testing/refs.md) | `refs_spec`, `head_marker_spec`, `label_color_spec`, `ref_picker_spec`, `ref_cycle_spec`, `selection_spec`, `ref_window_spec`, `label_mode_spec`, `listview_spec`, `pin_spec`, `detached_head_spec` |
| [git-io.md](testing/git-io.md) | `commit_spec`, `stream_complete_spec`, `stream_tick_spec`, `git_debug_spec`, `repo_picker_spec`, `fetch_spec`, `ordering_spec`, `worktree_spec`, `diff_provider_spec` |
| [actions.md](testing/actions.md) | `palette_spec`, `checkout_spec`, `sync_spec`, `examine_spec` |
| [commit-view.md](testing/commit-view.md) | `commit_view_spec`, `commit_selection_spec`, `filter_spec`, `snippet_spec` |
| [infra.md](testing/infra.md) | `persist_spec`, `progress_spec`, `open_trace_spec`, `future_spec`, `color_spec`, `gitloom_spec` |
| [seams.md](testing/seams.md) | the `_internal` test seams (`graph`, `window`, `listview`, `graph_helpers`) |

## Layout testing approach

The lane algorithm is tested by feeding artificial commit DAGs through
`build_graph` and asserting properties, not by comparing to fixed rendered
output. The deliberate choice (see chat history / specification.md §10): the
plugin will support multiple visualizations, so golden snapshots would be a
maintenance treadmill. Two layers, both in `graph_helpers.lua`:

- **Model** — every input commit is laid out exactly once (faithfulness vs.
  the input DAG, which is the oracle — not a re-derivation of the layout).
- **Rendered grid** — a "wires must connect" check on the actual glyph grid:
  no unknown glyphs, no dangling left/right or up/down stubs, crossings pass
  the horizontal wire through a vertical bar, and lane color stays continuous
  (including across crossings).

Both layers run over **two corpora**: raw `dag()` items, and the same DAGs through
`h.focused` — the §10.7 first-parent projection an opened graph actually lays out.
The second is not redundant. `owns_subject` (§5.6) is false only for a collapsed
head or a junction marker, and a raw DAG has neither, so *every* non-subject-row
path in `columns.lua` is unreachable on raw fuzz however long it runs. Any new
layout invariant should be asserted on both.

Color/id-continuity is the **id-continuity** invariant: a lane's id must not
silently change along a straight `│` run (a "lane handoff"). Tests use
`big_opts` (a 64-entry palette) so color is a 1:1 proxy for the *concurrent*
lane id — the colour free list (spec §5.5) only recycles a slot once a lane
ends, so two lanes alive at the same time always differ in colour as long as the
palette outnumbers the live lanes; `big_opts` guarantees that for the test DAGs,
so a handoff can't be masked. The four stable styles pass this exactly across
fuzzing; only `allow_merge_on_split` fails it (column reuse at a merge — see
known gaps), which is why that style asserts structural-only invariants plus the
characterization snapshot.

Invariants must be **sound** (never flag correct output) before being strict.
Glyph-level color/continuity is subtle because junction glyphs (`├ ┤ ┬ ┴`,
turns) are lane *boundaries* where color legitimately changes — only enforce
continuity where it unambiguously holds (straight `│↔│` runs, and across
crossings). A `checker self-test` block feeds deliberately broken grids to
prove the checker still has teeth; keep it passing.

Still uncovered: the listview widget's rendering (needs snacks in the test
runtime). Its pure helpers are testable — `snacks.win` loads lazily (only
`create_win` errors without it), so `listview._internal.pack_right` is covered.
