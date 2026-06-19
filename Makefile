TESTS_DIR := tests
INIT_FILE := tests/minimal_init.lua
LUALS ?= lua-language-server

.PHONY: test test-file lint

## Run all tests
test:
	nvim --headless -u $(INIT_FILE) -c "PlenaryBustedDirectory $(TESTS_DIR)/ {minimal_init = '$(INIT_FILE)'}"

## Run a single test file: make test-file FILE=tests/refs_spec.lua
test-file:
	nvim --headless -u $(INIT_FILE) -c "PlenaryBustedFile $(FILE)"

## Type-check with lua-language-server (uses .luarc.json). Resolves the Neovim
## runtime from `nvim` so vim.* is known; override the binary with LUALS=...
lint:
	@VIMRUNTIME="$$(nvim --headless --clean -c 'lua io.write(vim.env.VIMRUNTIME)' -c 'qa' 2>/dev/null)"; \
	export VIMRUNTIME; \
	"$(LUALS)" --check . --checklevel=Warning --logpath=.luals-log
