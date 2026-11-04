TESTS_DIR := tests
INIT_FILE := tests/minimal_init.lua
LUALS ?= lua-language-server
# Wall-clock budget (ms) for the WHOLE `make test` run. PlenaryBustedDirectory
# starts every spec file at once and joins them all against ONE deadline whose
# default is 50 s; a file still running at the deadline prints nothing and fails
# the run with no failing test named. The git-heavy specs (examine_spec,
# sync_spec: hundreds of real `git` spawns) finish last, at 45-49 s on a loaded
# machine — so the default flaked. This is a hang guard, not a speed target.
TEST_TIMEOUT ?= 300000

.PHONY: test test-file lint smoke smoke-refjump

## Run all tests
test:
	nvim --headless -u $(INIT_FILE) -c "PlenaryBustedDirectory $(TESTS_DIR)/ {minimal_init = '$(INIT_FILE)', timeout = $(TEST_TIMEOUT)}"

## Headless window smoke-test (drives the real graph; needs snacks in the
## test deps dir, see tests/minimal_init.lua). Separate from `test` — it is
## not a busted spec and needs a real repo + async waits. Exits non-zero on failure.
smoke:
	nvim --headless -u $(INIT_FILE) -c "lua require('tests.smoke.graph_smoke').run()"

## Headless smoke-test for the <leader>b ref-picker jump vs. the context panes
## (spec §2/§6.2): drives the REAL snacks picker in a real window and asserts
## both overlays survive the jump. Steps run from vim.defer_fn, NOT vim.wait, so
## nvim returns to its main loop and WinScrolled actually fires (see the file).
## GL_REPO=<path> targets another (larger) repository and GL_NEXT=<n> picks how
## far down the picker to confirm — sweep both; the defaults are a weak stress.
smoke-refjump:
	nvim --headless -u $(INIT_FILE) -c "lua require('tests.smoke.ref_jump_smoke').run()"

## Run a single test file: make test-file FILE=tests/refs_spec.lua
## Runs the spec in this nvim exactly as `make test` runs each spec in its child
## (`--noplugin -u $(INIT_FILE)` + `plenary.busted.run`), which exits with the
## spec's status. Not `PlenaryBustedFile`: it takes no options, so it imposed
## plenary's 50 s deadline (the git-heavy specs failed it with no test named)
## and started the child WITHOUT $(INIT_FILE) — loading the user's own config.
test-file:
	nvim --headless --noplugin -u $(INIT_FILE) -c "lua require('plenary.busted').run('$(FILE)')"

## Type-check with lua-language-server (uses .luarc.json). Resolves the Neovim
## runtime from `nvim` so vim.* is known; override the binary with LUALS=...
lint:
	@VIMRUNTIME="$$(nvim --headless --clean -c 'lua io.write(vim.env.VIMRUNTIME)' -c 'qa' 2>/dev/null)"; \
	export VIMRUNTIME; \
	"$(LUALS)" --check . --checklevel=Warning --logpath=.luals-log
