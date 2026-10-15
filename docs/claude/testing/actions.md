# Palette and git-action tests

Scope: per-spec coverage of the command palette, checkout, branch sync and checkout & examine. [specification.md](../../../specification.md) and [ARCHITECTURE.md](../../../ARCHITECTURE.md) remain authoritative. Index: [../testing.md](../testing.md).

- `tests/palette_spec.lua` — the command palette (§17): `palette.palette_entries`
  as ONE ordered list — the context first (the row's entries, or the `selection`
  entries **instead** while selecting: Open diff `(D)` + Checkout & examine
  selection, only with a provider), then the globals (Return first, only while an
  examine is active; Fetch / per-remote Fetch / Pull — no Refresh command, `R` is a
  key; remotes nil / {} / a list giving no / no / one `fetch:<remote>` entry
  each; **Reset view settings** last among the globals in every context, §18.5);
  no examine entry; a row entry carries an `op`, a registry entry an
  `action` (bound to ctx + remote); scope + `when` filtering and function labels
  on a custom registry; then the **key entries** over a FAKE registry (§17.1):
  `row_context` (commit / branch / markers, a packed line with a marker selected
  → branch), the per-context sets (commit: no `P`/`<Space>`; branch: no commit
  diff / examine; marker selected: only that marker's checkout / expand / hide;
  no marker: per-marker expand / hide + global keys; selection: `V`, `D` once),
  groups refs → view → select → other, hints derived from the registry key, a key
  already shown never repeated (so no duplicate `R`), ungrouped / handler-less
  keys never listed, a key entry running its handler; `help_lines` (grouped,
  ungrouped last, aliases joined, aligned, a newly added fake key picked up with
  its `help` text); and the REAL `GRAPH_KEYS` (`window._internal.keys`):
  well-formed (a desc each, known groups / contexts, no lhs bound twice), motions
  and plumbing ungrouped, `R` once, every key in the help, `<Space>` offered on a
  branch row only where it toggles (not on a `mainline` row; once on expanded /
  collapsed, as the row entry; on a selected packed marker); `remote.remote_command` (`git fetch --all`, `git fetch <remote>`,
  `git pull --ff-only`, `GIT_TERMINAL_PROMPT=0` in a fresh env table, pull's
  resync-on-failure, never forcing), `remote.parse_remotes` (blank lines, CR), `remote.failure_text`
  (the `fatal:`/`error:` line first, stderr as is, stdout fallback), and
  against REAL scratch repositories (a bare remote + two clones + a second bare
  remote): `fetch_remotes` order, fetch --all moving `origin/main`, a per-remote
  fetch moving only that remote's ref, pull fast-forwarding a strictly-behind
  branch, a diverged pull refused with HEAD unmoved, pull with
  no upstream failing with a code + stderr (HEAD unmoved), and the env reaching
  the job (a `!echo` alias prints `$GIT_TERMINAL_PROMPT`)
- `tests/checkout_spec.lua` — the palette's row entries + checkout (incl. the
  leading `(HEAD → x)` label resolving to branch `x`)
  (§10.4/§10.4.1): `palette.row_entries` order per row kind, scoped to the
  context (§17.1) (plain = commit → diff `(D)`, checkout, checkout & examine —
  **no examine**, `<CR>` is examine now; a selected branch / collapsed head →
  checkout of the branch / the tip, then collapse|expand `(<Space>)`, hide —
  **no** commit diff and **no** checkout & examine; a mainline branch → its
  checkout only; packed markers with none selected → per-marker expand/hide
  (`expand:<i>`/`hide:<i>`), no checkout; one selected → ONLY its checkout,
  `expand:<i>`, `hide:<i>`; diff and checkout & examine only with a provider; no
  checkout of either kind on a §4.2 virtual commit; no row → nothing), `selected_ref` (decoration index → local /
  remote-only / tag / worktree ref, a branch group preferring its local branch),
  `checkout_spec` (the argv per ref kind — `git switch <name>`, `git switch
  <short>` for a remote, `git checkout --detach <hash>` otherwise, a collapsed
  head detaching at its tip — and never a force flag), and `run_checkout` against
  a REAL scratch repository passed as the root (not the cwd): a branch switch and
  a detach land, and a switch over a conflicting dirty file is refused with a
  non-zero code + stderr, HEAD and the file untouched
- `tests/sync_spec.lua` — the branch sync (§17.2). Pure (`gitloom.git.sync`):
  `sync_target` / `sync_offers` per tracking state (behind → ff + reset; ahead /
  diverged → reset; in sync / gone / no upstream / no refname / a remote ref / a
  tag / a worktree → none), the reset prompt's change count
  (`parse_status`'s `paths - untracked`: each changed TRACKED path once — `MM` and
  a rename count 1, `??` never), `ff_command` / `reset_command`
  for the current branch vs another (never a `+` refspec, `--force` or a remote
  name), `reset_prompt` / `prompt_text` per case (nothing lost → the question
  alone; commits / uncommitted lines; singular counts; another branch's dirty
  tree not mentioned), `sync_stale` (tip / upstream tip / current branch / dirty
  count / a failed read), the notices; and `palette.row_entries` reaching it (a
  selected local branch, a remote ref / tag / commit row getting none, a
  collapsed head's or selected marker's SOLE local branch, none when ambiguous).
  Plus a **remote ref with a local counterpart elsewhere** (§10.4.1):
  `select.local_counterpart` (none without a local namesake or on one commit) and
  the entries it yields — behind → `checkout_ff`, ahead / diverged →
  `checkout_reset`, a non-tracking / in-sync / gone local → detached only, a
  current local → the plain `fast_forward` / `reset_branch`, always followed by
  the detached checkout of the remote's commit — plus `checkout_commands` (never
  forcing), the `switching` reset prompt and `checkout_note`.
  Then against REAL scratch repositories (`origin/main` a locally created
  remote-tracking ref — no network): the ref read carrying `upstream.ref`,
  `fetch.sync_probe`, a non-current fast-forward leaving the files untouched, a
  current one, a diverged ff refused (both forms, branch unmoved), a ff over a
  conflicting dirty file refused, reset of the current branch (ahead + dirty — an
  untracked file survives; strictly ahead), of another branch, both refused for a
  branch checked out in a linked worktree, the stale-tip / dirty abort decision,
  and a LOCAL-branch upstream (`refs/heads/<x>`); and the §10.4.1 checkout +
  sync through `fetch.run_steps`: ff + switch lands HEAD on the branch at the
  upstream, a diverged ff refused at step 1 (nothing moved), a switch refused at
  step 2 leaving the branch fast-forwarded, `switch -C` resetting a diverged
  branch and checking it out (upstream kept, old tip in the reflog), and refusing
  over a conflicting dirty file. The window glue is untested
- `tests/examine_spec.lua` — Checkout & examine (§10.4.2). Pure:
  `range.examine_range` (ONE rev — the older end's first parent — `to =
  "worktree"`, `-C<root> <base>` as diffview args; a root older end → the empty
  tree; a raw-hash parent; a working-tree newer end → exactly `range_endpoints`),
  `examine_stash_message` (branch vs detached origin), `dirty_count` (the prompt's
  N = changed PATHS, each once: an `MM` file and a rename count 1, so N is not the
  per-state sum), `examine_plan` over clean /
  dirty × single / range × a working-tree newer end (`open`, no checkout, no
  stash) × a newer end AT HEAD — **Examine**, attached or detached (`open`
  `examine_range`, no checkout / stash / state, dirty or not, an active examine
  left untouched; `needs_checkout`) × an examine already active (clean: `orig` + stash kept, only `examined`
  moves, the active state not mutated; dirty: `refuse` "Return to … first" — no
  stash chain), unknown HEAD refused, never forcing; `return_plan` (branch → `git
  switch`, detached → `git checkout --detach`, apply `--index` by SHA + the plain
  fallback argv only with a stash, the label); `index_refused` (only git's
  "conflicts in index" refusal, either capitalisation, licenses the fallback — not
  a merge conflict, a local change in the way, a success or a spawn failure);
  `stash_index` (by SHA, CRLF-safe, nil when absent); the palette entries
  that reach it (HEAD's row → `Examine <short>` op `examine`, another row or an
  unknown head → Checkout & examine, none without a provider, Return still listed;
  the selection entry `Examine selection` for a HEAD / working-tree newer end).
  Then the git side against REAL scratch repositories
  (`fetch.examine_probe` / `examine_run` / `examine_return`): the probe's branch /
  detached / counts (a staged-only + an `MM` + an untracked file → N = 3); Examine
  of HEAD's commit on a dirty tree (attached and detached) → `open`, nothing
  stashed, HEAD and the edits untouched; dirty → stash (`stash@{0}`, the message) → detached checkout
  → clean tree, then Return → branch, edits AND untracked files restored, stash
  dropped; **the index round-trips** (a staged edit comes back staged, an unstaged
  one unstaged, an untracked file restored; one file with BOTH a staged and an
  unstaged edit keeps both); the **`--index` fallback** (a staged line-1 edit while
  `main` moved line 3: git refuses `--index`, the plain apply merges, the changes
  are back unstaged, `unstaged` flagged, stash dropped — and when the plain apply
  conflicts too the stash is KEPT); clean → no stash, Return switches back; a second examine keeps orig +
  stash and a dirty one is refused; a conflicting apply KEEPS the stash (HEAD back
  on the branch); a failed switch stops before the apply; a checkout failing after
  the stash re-applies it (clean → dropped); and drop-by-SHA leaves another
  session's stashes — one below AND one pushed on top meanwhile — alone. Plus,
  with diffview in the lazy dir (`pending` otherwise), the single-rev open's right
  side is `RevType.LOCAL` and the left `COMMIT`
