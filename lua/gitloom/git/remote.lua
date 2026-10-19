--- gitloom.git.remote — the remote commands the command palette runs (spec §17).
---
--- Pure: builds the argv + environment for `git fetch` / `git pull`, and reads
--- their streamed output — the fetch log's line buffer, the live status and the
--- ref-update summary (§17.4); the I/O is `fetch.run_remote`, the window glue
--- (busy flag, notices, live refresh, resync) window.lua's `run_remote` helper.
--- Neither command ever forces.

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

--- The remote command `kind` runs (§17.2): `fetch` → `git fetch --progress --all`,
--- or `git fetch --progress <remote>` when `remote` is given; `pull` →
--- `git pull --ff-only --progress` (`remote` ignored — there is no per-remote
--- pull). `--progress` makes git print its phases to a non-terminal (§17.4); the
--- `label` leaves it out. nil for an unknown kind. Returns a fresh table each
--- call, so a caller cannot mutate the shared env by accident. Pure.
---@param kind string
---@param remote string?
---@return RemoteCommand?
function M.remote_command(kind, remote)
    local env = {}
    for k, v in pairs(M.REMOTE_ENV) do env[k] = v end
    if kind == "fetch" then
        if remote then
            return { kind = "fetch", argv = { "git", "fetch", "--progress", remote }, env = env,
                label = "git fetch " .. remote, running = ("gitloom: Fetching %s…"):format(remote),
                done = "gitloom: fetched " .. remote, resync_on_failure = false }
        end
        return { kind = "fetch", argv = { "git", "fetch", "--progress", "--all" }, env = env,
            label = "git fetch", running = "gitloom: Fetching…", done = "gitloom: fetched",
            resync_on_failure = false }
    elseif kind == "pull" then
        return { kind = "pull", argv = { "git", "pull", "--ff-only", "--progress" }, env = env,
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

-- ── The streamed output (§17.4): the fetch log, the live status, the summary ──

--- The fetch log's line cap (§17.4): the oldest lines are dropped past it.
M.LOG_MAX = 2000
--- Silence (ms) after which the live status says `(no output for N s)` (§17.4).
M.SILENCE_MS = 10000

---@class RemoteLogLine
---@field t number       ms since the start when the line (or its latest in-place update) arrived
---@field text string    the line, trailing whitespace trimmed
---@field stream string  "stdout" | "stderr"

---@class RemoteLog
---@field cmd string                     the command line (`git fetch --progress origin`)
---@field t0 number                      clock (ms) at the start
---@field started integer                wall time (`os.time()`) at the start
---@field lines RemoteLogLine[]          at most LOG_MAX; in-place updates collapsed
---@field partial table<string, string>  per stream: the text after its last line end
---@field open table<string, integer>    per stream: the index of its line git may still rewrite (ended by `\r`)
---@field last_t? number                 clock (ms) of the latest output; nil before any
---@field code? integer                  the exit code, once finished
---@field t_end? number                  clock (ms) at the exit

--- A fresh fetch log (§17.4) for the command line `cmd`, started at clock `t0`
--- (ms) and wall time `started` (`os.time()`). Pure.
---@param cmd string
---@param t0 number
---@param started integer
---@return RemoteLog
function M.new_log(cmd, t0, started)
    return { cmd = cmd, t0 = t0, started = started, lines = {}, partial = {}, open = {} }
end

-- Commit one segment of `stream` ended by `term` ("\r" or "\n") at `now`. A
-- segment replaces the stream's open line (one git ended with `\r`) when there is
-- one, else is appended; a `\r` ending leaves it open. An empty segment adds
-- nothing — after `\r` it is the `\n` of a `\r\n`, which closes the open line.
local function commit_segment(log, stream, seg, term, now)
    seg = seg:gsub("%s+$", "")
    if seg == "" then
        if term == "\n" then log.open[stream] = nil end
        return
    end
    local line = { t = now - log.t0, text = seg, stream = stream }
    local idx = log.open[stream]
    if idx then
        log.lines[idx] = line
    else
        log.lines[#log.lines + 1] = line
        idx = #log.lines
        if idx > M.LOG_MAX then
            table.remove(log.lines, 1)
            idx = idx - 1
            for s, i in pairs(log.open) do
                log.open[s] = i > 1 and i - 1 or nil
            end
        end
    end
    log.open[stream] = term == "\r" and idx or nil
end

--- Feed a chunk of `stream` output that arrived at clock `now` (ms) into `log`
--- (§17.4). Lines end at `\r` or `\n`; a chunk may end mid-line (the tail waits
--- for the next chunk) or carry several lines; a line ended by `\r` (git's
--- in-place progress) is replaced by the stream's next line. Pure.
---@param log RemoteLog
---@param stream string  "stdout" | "stderr"
---@param chunk string
---@param now number
function M.log_feed(log, stream, chunk, now)
    log.last_t = now
    local s = (log.partial[stream] or "") .. chunk
    local pos = 1
    while true do
        local i = s:find("[\r\n]", pos)
        if not i then break end
        commit_segment(log, stream, s:sub(pos, i - 1), s:sub(i, i), now)
        pos = i + 1
    end
    log.partial[stream] = s:sub(pos)
end

--- End `log` with the exit `code` at clock `now` (ms): an unterminated tail on
--- either stream becomes a last line. Pure.
---@param log RemoteLog
---@param code integer
---@param now number
function M.log_finish(log, code, now)
    for _, stream in ipairs({ "stderr", "stdout" }) do
        local tail = log.partial[stream]
        if tail and tail ~= "" then commit_segment(log, stream, tail, "\n", now) end
        log.partial[stream] = ""
    end
    log.code, log.t_end = code, now
end

-- `m:ss` for a duration in ms.
local function clock(ms)
    local s = math.max(0, math.floor(ms / 1000))
    return ("%d:%02d"):format(math.floor(s / 60), s % 60)
end

--- The live status (§17.4) at clock `now` (ms): `<m:ss> · <latest line>`,
--- `· waiting for the remote` before any line, and ` (no output for N s)` once
--- the latest output is more than SILENCE_MS old. The operation's progress
--- message (§19.1). Pure.
---@param log RemoteLog
---@param now number
---@return string
function M.status_text(log, now)
    local last = log.lines[#log.lines]
    local msg = clock(now - log.t0) .. " · " .. (last and last.text or "waiting for the remote")
    local quiet = now - (log.last_t or log.t0)
    if quiet > M.SILENCE_MS then
        msg = msg .. (" (no output for %d s)"):format(math.floor(quiet / 1000))
    end
    return msg
end

--- The fetch log as buffer lines (§17.4) at clock `now` (ms): the command line
--- and start time, each line prefixed `+<s>s`, then `exit <code> (<s> s)` — or
--- `running <m:ss>` while the job runs. Pure (`os.date` only formats `started`).
---@param log RemoteLog
---@param now number
---@return string[]
function M.log_lines(log, now)
    local out = { ("%s  (started %s)"):format(log.cmd, os.date("%H:%M:%S", log.started)) }
    for _, l in ipairs(log.lines) do
        out[#out + 1] = ("+%.1fs  %s"):format(l.t / 1000, l.text)
    end
    if log.code then
        out[#out + 1] = ("exit %d (%.1f s)"):format(log.code, ((log.t_end or now) - log.t0) / 1000)
    else
        out[#out + 1] = "running " .. clock(now - log.t0)
    end
    return out
end

---@class RefSummary
---@field new integer
---@field updated integer
---@field forced integer
---@field deleted integer
---@field rejected integer

-- The ref-table flag column (§17.4) → its count. `=` (up to date, `-v` only) is
-- not counted.
local FLAG_COUNT = { ["*"] = "new", [" "] = "updated", t = "updated", ["+"] = "forced",
    ["-"] = "deleted", ["!"] = "rejected" }

--- Count git's ref-update lines in a fetch / pull's stderr (§17.4) by their
--- one-character flag column, which git does not translate (the bracketed words
--- it does): ` <flag> <what> <from> -> <to>`. `From`, `remote:`, progress and
--- `Fetching <remote>` lines never match. Pure.
---@param err string?
---@return RefSummary
function M.ref_summary(err)
    local c = { new = 0, updated = 0, forced = 0, deleted = 0, rejected = 0 }
    for line in (err or ""):gmatch("[^\r\n]+") do
        local flag = line:match("^ (.) %S.- %-> %S")
        local key = flag and FLAG_COUNT[flag]
        if key then c[key] = c[key] + 1 end
    end
    return c
end

--- The success notice for `cmd` (§17.4): `cmd.done — 2 new, 5 updated, …` with
--- zero counts left out; with none, `— up to date` for a fetch and the bare
--- `cmd.done` for a pull (its fast-forward shows through the resync). Pure.
---@param cmd RemoteCommand
---@param counts RefSummary
---@return string
function M.summary_text(cmd, counts)
    local parts = {}
    for _, k in ipairs({ "new", "updated", "forced", "deleted", "rejected" }) do
        if (counts[k] or 0) > 0 then parts[#parts + 1] = ("%d %s"):format(counts[k], k) end
    end
    if #parts > 0 then return cmd.done .. " — " .. table.concat(parts, ", ") end
    return cmd.kind == "fetch" and cmd.done .. " — up to date" or cmd.done
end

return M
