local M = {}

M.config = {
}

function M.setup(opts)
    opts = opts or {}
    M.config = vim.tbl_extend("force", M.config, opts)
end

local graph = require("gitit.graph")

vim.api.nvim_create_user_command("GititGraph", graph.open, {})

if vim.g.loaded_gitit then
    M.setup()
end

vim.g.loaded_gitit = true

return M
