local M = {}

M.config = {
}

local window = require("gitloom.window")

-- Default normal-mode mapping for the repository picker (spec §2.1). Installed by
-- setup() — where `mapleader` is already set, unlike plugin-load time — so the
-- `<leader>` resolves to the user's leader. Set `pick_key = false` in setup opts
-- to disable, or a string to remap.
local DEFAULT_PICK_KEY = "<leader>wG"

function M.setup(opts)
    opts = opts or {}
    M.config = vim.tbl_extend("force", M.config, opts)

    -- Install (or re-install) the picker keymap from config. `pick_key`:
    -- nil/unset → the default; a string → that LHS; false → no default mapping.
    local key = M.config.pick_key
    if key == nil then key = DEFAULT_PICK_KEY end
    if key then
        vim.keymap.set("n", key, function() window.pick(M.config) end,
            { desc = "Gitloom: pick repository / submodule" })
    end
end

-- Forward the stored setup() config to the graph so :GitloomGraph honours it
-- (spec §8). Read at invocation time so a later setup() still applies. M.open
-- merges it over the built-in defaults. An optional argument targets a specific
-- repository root (a submodule or the main module, §2.1); with none it uses
-- Neovim's cwd.
vim.api.nvim_create_user_command("GitloomGraph", function(cmd)
    local folder = cmd.fargs[1]
    window.open(folder, M.config)
end, { nargs = "?", complete = "dir" })

-- Repository picker (§2.1): choose the main module or a submodule, then open the
-- graph for it. setup() also binds this to <leader>wG by default (configurable
-- via pick_key). Forwards the stored setup() config so the opened graph honours it.
vim.api.nvim_create_user_command("GitloomPick", function()
    window.pick(M.config)
end, {})

if vim.g.loaded_gitloom then
    M.setup()
end

vim.g.loaded_gitloom = true

return M
