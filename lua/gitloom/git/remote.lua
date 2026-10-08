--- gitloom.git.remote — the remote commands the command palette runs (spec §17).
---
--- Pure: builds the argv + environment for `git fetch` / `git pull`; the I/O is
--- `fetch.run_remote`, the window glue (busy flag, notices, resync) window.lua's
--- `run_remote` helper. Neither command ever forces.

local M = {}

--- The environment every remote command runs with (§17.3): a credential prompt
--- fails instead of hanging the invisible background job. Credential helpers
--- still run — only git's own terminal prompt is suppressed.
M.REMOTE_ENV = { GIT_TERMINAL_PROMPT = "0" }

---@class RemoteCommand
---@field kind "fetch"|"pull"
---@field argv string[]                the git command line (never forcing)
---@field env table<string, string>    extra environment for the job (§17.3)
---@field label string                 the command, for an error line (`git fetch origin`)
---@field running string               the notice while it runs (`Fetching…`)
---@field done string                  the success notice
---@field resync_on_failure boolean    pull: its fetch half may have moved remote-tracking refs

--- The remote command `kind` runs (§17.2): `fetch` → `git fetch --all`, or
--- `git fetch <remote>` when `remote` is given; `pull` → `git pull --ff-only`
--- (`remote` ignored — there is no per-remote pull). nil for an unknown kind.
--- Returns a fresh table each call, so a caller cannot mutate the shared env by
--- accident. Pure.
---@param kind string
---@param remote string?
---@return RemoteCommand?
function M.remote_command(kind, remote)
    local env = {}
    for k, v in pairs(M.REMOTE_ENV) do env[k] = v end
    if kind == "fetch" then
        if remote then
            return { kind = "fetch", argv = { "git", "fetch", remote }, env = env,
                label = "git fetch " .. remote, running = ("gitloom: Fetching %s…"):format(remote),
                done = "gitloom: fetched " .. remote, resync_on_failure = false }
        end
        return { kind = "fetch", argv = { "git", "fetch", "--all" }, env = env,
            label = "git fetch", running = "gitloom: Fetching…", done = "gitloom: fetched",
            resync_on_failure = false }
    elseif kind == "pull" then
        return { kind = "pull", argv = { "git", "pull", "--ff-only" }, env = env,
            label = "git pull", running = "gitloom: Pulling…", done = "gitloom: pulled",
            resync_on_failure = true }
    end
    return nil
end

--- The remote names from `git remote` output (§17.1): one name per line, in
--- git's order; blank lines skipped, a trailing CR and surrounding whitespace
--- trimmed. Pure.
---@param out string?
---@return string[]
function M.parse_remotes(out)
    local names = {}
    for line in (out or ""):gmatch("[^\n]+") do
        -- %s covers the trailing CR (git for Windows' output).
        local name = line:match("^%s*(.-)%s*$")
        if name ~= "" then names[#names + 1] = name end
    end
    return names
end

--- The text to report for a failed remote command (§17.3), for
--- `format_git_error` (which shows its first line). A fetch / pull writes its
--- progress (`From <url>`) and `hint:` advice to stderr ahead of the actual
--- error, so the first `fatal:` / `error:` line is moved to the front when there
--- is one; otherwise stderr as is, or stdout when stderr is empty. Pure.
---@param out string?
---@param err string?
---@return string
function M.failure_text(out, err)
    err = err or ""
    if err == "" then return out or "" end
    for line in err:gmatch("[^\r\n]+") do
        if line:match("^fatal:") or line:match("^error:") then return line .. "\n" .. err end
    end
    return err
end

return M
