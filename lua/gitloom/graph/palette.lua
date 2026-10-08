--- gitloom.graph.palette — the command palette's registry (spec §17).
---
--- Pure: one ordered list of commands and the function that turns it into the
--- picker entries for a scope. Each `action` takes the graph session (`ctx`) and
--- only calls its methods, so nothing here touches a window; window.lua's
--- `palette` helper shows the entries with `vim.ui.select` and runs the choice.

local M = {}

---@alias PaletteScope "global"|"commit"|"ref"

---@class PaletteCommand
---@field id string              stable name (`refresh`, `fetch`, `pull`); a
---                              per-remote command's entries are `<id>:<remote>`
---@field label string           what the picker shows (before the key hint); a
---                              per-remote command's is a format with one `%s`
---@field key? string            the direct key running the same command, if any
---@field scope PaletteScope     `global` now; `commit` / `ref` reserved (§17.1)
---@field per_remote? boolean    expands to one entry per remote (in `git remote`
---                              order), none while the remote list is unknown
---@field action fun(ctx: table, remote: string?) run on the graph session

--- The registry, in palette order (§17.2). `commit` / `ref` scoped entries go
--- here too when they exist; the global palette filters them out.
---@type PaletteCommand[]
M.COMMANDS = {
    { id = "refresh", label = "Refresh", key = "R", scope = "global",
        action = function(ctx) ctx:resync(false) end },
    { id = "fetch", label = "Fetch", scope = "global",
        action = function(ctx) ctx:run_remote("fetch") end },
    { id = "fetch", label = "Fetch %s", scope = "global", per_remote = true,
        action = function(ctx, remote) ctx:run_remote("fetch", remote) end },
    { id = "pull", label = "Pull", scope = "global",
        action = function(ctx) ctx:run_remote("pull") end },
}

---@class PaletteEntry
---@field id string              `refresh`, `fetch`, `fetch:origin`, `pull`, …
---@field label string           the picker text, key hint appended: `Refresh  (R)`
---@field action fun(ctx: table)

--- The picker entries for `scope` (default `global`), in registry order: only
--- the commands of that scope, each labelled with its key when it has one; a
--- `per_remote` command becomes one entry per name in `remotes` (none when
--- `remotes` is nil — the list has not arrived — or empty). Never waits on
--- anything: it is built from what the caller already has. Pure.
---@param scope PaletteScope?
---@param remotes string[]?
---@param commands PaletteCommand[]?  defaults to the registry (a test seam)
---@return PaletteEntry[]
function M.palette_entries(scope, remotes, commands)
    scope = scope or "global"
    local out = {}
    for _, c in ipairs(commands or M.COMMANDS) do
        if c.scope == scope then
            local key = c.key and ("  (%s)"):format(c.key) or ""
            if c.per_remote then
                for _, r in ipairs(remotes or {}) do
                    local action = c.action
                    out[#out + 1] = { id = c.id .. ":" .. r, label = c.label:format(r) .. key,
                        action = function(ctx) action(ctx, r) end }
                end
            else
                out[#out + 1] = { id = c.id, label = c.label .. key, action = c.action }
            end
        end
    end
    return out
end

return M
