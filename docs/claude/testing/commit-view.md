# Commit view, range and search tests

Scope: per-spec coverage of the commit view, commit selection (range), filter search and the search snippet. [specification.md](../../../specification.md) and [ARCHITECTURE.md](../../../ARCHITECTURE.md) remain authoritative. Index: [../testing.md](../testing.md).

- `tests/commit_view_spec.lua` — the commit view's pure pieces (spec §11):
  `parse_show` (git-show field splitting, multi-line body, empty parents),
  `format_commit_detail` (committer-differs branch, refs line, body indent),
  `format_diff` (add/delete vs `+++`/`---`, hunk + file headers, context),
  `diffstat_files` (per-file counts, `start` offsets, rename, binary),
  `format_diffstat` (summary totals, per-file rows), and `commit_range`
  (single-commit `DiffRange`: `^!`, empty-tree for roots, `from` = first parent),
  plus the **message wrap** (§11.2.1): `message_width` (the 100-cell cap),
  `wrap_message` (paragraph join + re-wrap, blank lines kept, indented / tab /
  fenced lines untouched, final-paragraph trailers and URL-only lines verbatim
  while a `Key: value` line elsewhere reflows, list items with a hanging indent
  joining aligned and lazy continuations, an overlong word left whole, display-
  width (double-width) measuring, the subject wrapped on its own),
  `format_commit_detail`'s `width` (indent counted; nil = as is), and
  `window.build_commit_rows` with a wrapped body: `meta_end`, `diff_start`, the
  diffstat `file_jumps` and the diff_start-relative context-header mapping all
  shift by exactly the body's extra lines
- `tests/commit_selection_spec.lua` — the commit-selection (range) pure helpers
  (spec §13): `range_endpoints` (single-commit `^!`, span `<older>^..<newer>`,
  empty-tree when the older end is a root, plus the **working-tree newer end**
  (§4.2/§13.5): staged → `--cached <base>`/`to=index`, unstaged → `<base>`/
  `to=worktree`, untracked → the same plus the `untracked` flag, the base still
  the older end's first parent (empty tree at a root) and a *virtual* base
  resolved to its own tree state — asserted as an invariant too: never a sentinel
  hash in the rev, never a `..` span), `sel_ascend_children` (first-parent
  children first; a §4.2 working-tree virtual commit **is** ascended into, the
  whole stack HEAD → staged → unstaged → untracked walkable and clamping at its
  top on its own, with an
  ordinary child asserted unaffected), `sel_step` (extend/contract along the branch, flip at the
  anchor, clamp at tip/root) and `sel_switch` (rotate the parent at a merge /
  child at a split, no-op on a linear path; §13.2/§13.3), and `format_range_detail`
  (the range view's metadata: `N commits  (oldest..newest)` then newest-first
  hash + subject rows, plus the **synthesized working-tree row** — a `working` id
  cell instead of the sentinel, and `worktree_label`'s text for each of the three
  states; §13.5), and `format_git_error` (the one line the range view
  shows in place of the diff when `git diff` fails: label + exit code, git's stderr
  appended but only its first line, CR-trimmed, `exit -1` for an unspawnable job)
- `tests/filter_spec.lua` — the in-graph filter-search pure core (§16):
  `smartcase_match` (case-insensitive unless the needle has an uppercase; literal
  substring, not a pattern), `filter_keep` (the keep-set from commits × query over
  subject **or** author; smartcase; blank query → empty), and `view.project`'s
  `keep` set (§16.3: a match stays a normal commit while the runs between matches
  collapse; junctions preserved; a kept match is never a node-less junction; nil
  keep = the plain collapse)
- `tests/snippet_spec.lua` — `graph_snippet` (the commit-search graph snippet,
  §15.3): the `[focus±radius]` window + reported focus row, top/bottom clamping,
  the focus-row gutter marker, the per-row subject, the shared graph-column width
  (subjects aligned), and a collapsed head labelled by its region count
