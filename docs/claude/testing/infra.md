# Infrastructure tests

Scope: per-spec coverage of persistence, progress, the open trace, the vendored future, colour, and the public surface. [specification.md](../../../specification.md) and [ARCHITECTURE.md](../../../ARCHITECTURE.md) remain authoritative. Index: [../testing.md](../testing.md).

- `tests/persist_spec.lua` — the persisted view state (`gitloom.persist`, §18):
  `config_values` (setup() value else built-in, normalised; a partial merge style
  resolved over the built-in), `overlay` (a stored value wins only while its
  `base` equals today's configuration-resolved value; a wrong-typed / value-less
  entry is ignored), `set_pref` (stores `{ value, base }`, prunes other stale
  entries), `pins_for_save` (only the leading run of unreserved defaults still in
  default order dropped — a default moved below an explicit entry, or reserved,
  is kept with its place; order and reserve flags kept), `set_repo` / `repo_state` (per-root round trip, junk
  sanitised, an empty state removes the entry); and against a scratch file: round
  trip, rename-over-existing leaving no temp files, **two writers with different
  keys both surviving** (re-read before write), a corrupt / non-object file ignored
  with ONE warning and replaced by the next write, `persist = false` neither
  reading nor writing, and Reset clearing the global preferences + only the given
  repository. `tests/minimal_init.lua` redirects the module to a temp file for
  every test run, so no test touches the real `stdpath("state")/gitloom.json`; the
  smoke test (`make smoke`) checks the toggles' saves, `save_pins` and the live
  reset end to end
- `tests/progress_spec.lua` — progress reporting (`gitloom.progress`, §19): the
  tracker over a fake clock / timer and a recording provider — an Op ended before
  the show delay reaches no provider at all (default delay 300; `0` shows at once,
  no timer), one past it calls `start` once with the LATEST message then `report`,
  and `finish` exactly once however many ends (outcome defaulting to `done`);
  `close()` ends every live Op `cancelled`, none twice, a timer firing after it
  shows nothing and later starts are inert; a throwing `start` / sink leaves the
  caller unaffected; `provider = false` / `progress = false` arm no timer and
  notify nothing; `normalize`. Provider resolution: `"auto"` picks fidget iff
  `fidget.progress` loads, re-checked per Op (`op.fidget`, which drops fetch /
  pull's own start notice), `"fidget"` falling back to notify. The fidget adapter
  over a stubbed handle (client `gitloom`, `cancellable = false`, `finish()` on
  every outcome after naming `failed` / `cancelled`, never `cancel()`) and the REAL
  fidget from the lazy dir (`pending` when absent). The notify provider: a start
  notice + `done (N s)` only for an Op without notices of its own, nothing more for
  `failed` / `cancelled`, nothing at all when it ended before the delay, the running
  message never notified. Plus the glue paths reachable without a window
  (`window._internal.reflow_async` superseded → `cancelled`, erroring → `failed`,
  completing → left to the caller, completing with the window HIDDEN → still
  applied and `done` run (so the open's Op ends; the result is never parked —
  the regression where a parked open spun on "laying out" forever), the graph
  buffer wiped mid-projection → `cancelled`, never applied; `resync`'s
  closed-window exit → `cancelled`)
- `tests/open_trace_spec.lua` — the open-path phase trace
  (`vim.g.gitloom_open_trace`, §10.8): inert unset and inert for a non-string,
  one `NNNN +Mms event k=v …` record per call with the fields in sorted key order,
  every phase name the open path emits, the `open` record restarting the clock and
  the sequence, and — the regression the shared writer risks — that the pane trace
  keeps its own counter across an open trace's reset
- `tests/future_spec.lua` — the vendored promise `make_future`: a `.next` callback
  runs whether attached before **or after** the future resolves, values chain, and
  a returned future flattens. Guards the regression where a synchronously-resolved
  future (the gitloom sort mode's `apply_sort`) dropped its chained callbacks, so
  the open-time worktree + reflow (the §10.7 default collapse) never ran
- `tests/color_spec.lua` — `gitloom.color`: sRGB↔OKLab/OKLCH round-trips, known
  conversions, and `generate` (golden-angle hues distinct and in-gamut)
- `tests/gitloom_spec.lua` — public surface (setup, command registration)
