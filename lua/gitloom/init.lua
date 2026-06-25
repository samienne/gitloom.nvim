local M = {}

M.config = {
}

function M.setup(opts)
    opts = opts or {}
    M.config = vim.tbl_extend("force", M.config, opts)
end

local window = require("gitloom.window")

-- Forward the stored setup() config to the graph so :GitloomGraph honours it
-- (spec §8). Read at invocation time so a later setup() still applies. M.open
-- merges it over the built-in defaults. An optional argument targets a specific
-- repository root (a submodule or the main module, §2.1); with none it uses
-- Neovim's cwd.
vim.api.nvim_create_user_command("GitloomGraph", function(cmd)
    local folder = cmd.fargs[1]
    window.open(folder, M.config)
end, { nargs = "?", complete = "dir" })

if vim.g.loaded_gitloom then
    M.setup()
end

vim.g.loaded_gitloom = true

return M
