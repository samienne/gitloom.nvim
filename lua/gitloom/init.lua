local M = {}

M.config = {
}

function M.setup(opts)
    opts = opts or {}
    M.config = vim.tbl_extend("force", M.config, opts)
end

local graph = require("gitloom.graph")

vim.api.nvim_create_user_command("GitloomGraph", graph.open, {})

if vim.g.loaded_gitloom then
    M.setup()
end

vim.g.loaded_gitloom = true

return M
