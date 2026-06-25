local M = {}

M.config = {
}

function M.setup(opts)
    opts = opts or {}
    M.config = vim.tbl_extend("force", M.config, opts)
end

local window = require("gitloom.window")

vim.api.nvim_create_user_command("GitloomGraph", window.open, {})

if vim.g.loaded_gitloom then
    M.setup()
end

vim.g.loaded_gitloom = true

return M
