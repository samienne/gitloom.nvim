--- git I/O — the async commands that read the repository: refs, the commit
--- stream, the resync's bounded fetch, the rev-list sort orders, the working-tree
--- state/diffs, the on-demand commit detail/diff/range patches, and the submodule
--- change graph. Each returns a `Future` (util.make_future) over `vim.system`
--- run in the **active repository root** (`M.set_cwd`, spec §2.1 — defaulting to
--- Neovim's cwd until a graph sets it), so the graph can target a submodule or
--- the main module. The one Neovim-coupled corner of gitloom.git; everything
--- else in the library is pure. Parsing/model construction is delegated to the
--- pure submodules.

local util = require("gitloom.util")
local parse = require("gitloom.git.parse")
local model = require("gitloom.git.model")
local refs = require("gitloom.git.refs")
local range = require("gitloom.git.range")
local submodule = require("gitloom.submodule")

local make_future = util.make_future
local trim_ws = util.trim_ws
local parse_commit_line = parse.parse_commit_line
local make_line_buffer = parse.make_line_buffer
local parse_status = parse.parse_status
local get_or_create_commit = model.get_or_create_commit
local add_ref = model.add_ref
local classify_ref = refs.classify_ref
local parse_worktrees = parse.parse_worktrees
local worktree_refs = refs.worktree_refs
local EMPTY_TREE = range.EMPTY_TREE

local M = {}

-- The active **repository root** every git query runs in (spec §2.1). Setting it
-- lets the graph target a submodule or the main module instead of implicitly
-- following Neovim's cwd. `nil` (the default until a graph sets it) means "run
-- in Neovim's cwd", preserving the original behaviour. The graph sets this via
-- M.set_cwd when it opens; the window keys its per-session view state by the
-- same root.
local active_cwd = nil

--- Set the repository root all subsequent git queries run in (spec §2.1). Pass
--- `nil` to fall back to Neovim's cwd.
---@param path string?
function M.set_cwd(path)
    active_cwd = path
end

-- ===== spawn diagnostics (`vim.g.gitloom_git_debug`) ========================
--
-- Windows' `CreateProcess` ceiling on the command line, measured against
-- `vim.fn.jobstart` by bisection on nvim 0.11.6 AND 0.12.5 (identical), and
-- holding unchanged for `vim.system`, which every spawn now uses (the same
-- `uv_spawn` + `exepath` substitution; re-checked in tests/git_debug_spec.lua): the
-- final command line — the *quoted* resolved argv[0] plus each quoted argument,
-- space-separated — may be at most this many characters. One more and the spawn
-- fails with `ERROR_FILENAME_EXCED_RANGE`, which libuv translates to
-- `UV_ENAMETOOLONG` and Neovim reports as
--   E903: Process failed to start: name too long: "<resolved exe>"
--
-- It is the ONLY spawn input that produces that error: a deep/UNC/short cwd, a
-- 300 KB environment, 5000 environment variables, a 200 KB `$PATH` and a bare
-- vs. absolute argv[0] were each varied independently and moved the threshold by
-- exactly zero (libuv even short-path-shortens a cwd past MAX_PATH before
-- calling CreateProcess). Note Neovim resolves a bare argv[0] to its `exepath`
-- before spawning, so the *resolved* path is what is charged, not `"git"`.
local WIN_CMDLINE_MAX = 32766

--- The number of characters one argv element occupies on the Windows command
--- line, mirroring libuv's `quote_cmd_arg`: an empty argument becomes `""`; an
--- argument with no space/tab/quote is emitted verbatim; anything else is
--- wrapped in quotes, with embedded quotes escaped and the backslash run before
--- a quote (or before the closing quote) doubled.
---@param arg string
---@return integer
local function quoted_len(arg)
    if arg == "" then return 2 end
    if not arg:find('[ \t"]') then return #arg end
    local n, i, len = 2, 1, #arg
    while i <= len do
        local b = 0
        while arg:sub(i + b, i + b) == "\\" do b = b + 1 end
        i = i + b
        if i > len then
            n = n + 2 * b -- trailing backslashes, doubled before the closing quote
        elseif arg:sub(i, i) == '"' then
            n = n + 2 * b + 2 -- doubled backslashes, then \"
            i = i + 1
        else
            n = n + b + 1
            i = i + 1
        end
    end
    return n
end

--- The length of the Windows command line `argv` produces, i.e. what is charged
--- against WIN_CMDLINE_MAX. `argv[1]` must ALREADY be the resolved executable
--- path (Neovim substitutes `exepath(argv[1])` before spawning).
---@param argv string[]
---@return integer
local function cmdline_len(argv)
    local n = 0
    for i, a in ipairs(argv) do
        n = n + (i > 1 and 1 or 0) + quoted_len(a)
    end
    return n
end

-- Records written this Neovim session, so a dump can be read as a sequence.
local spawn_seq = 0

--- Format one spawn as a human-readable debug record (see `debug_log`).
--- Pure — takes everything it reports.
---@param r { argv: string[], exe: string, cwd: string?, site: string?, seq: integer, ok: boolean, id: any }
---@return string
local function spawn_record(r)
    local argv = r.argv or {}
    local resolved = {}
    for i, a in ipairs(argv) do resolved[i] = a end
    resolved[1] = r.exe ~= "" and r.exe or resolved[1]
    local len = cmdline_len(resolved)
    local out = {
        ("=== gitloom git spawn #%d  %s"):format(r.seq or 0, os.date("%Y-%m-%d %H:%M:%S")),
        ("    site    = %s"):format(r.site or "?"),
        ("    cwd     = %s"):format(r.cwd or "(neovim cwd)"),
        ("    exe     = %s   (argv[1] = %s)"):format(r.exe or "?", tostring(argv[1])),
        ("    argc = %d"):format(#argv),
        ("    cmdline = %d of %d chars"):format(len, WIN_CMDLINE_MAX),
    }
    if len > WIN_CMDLINE_MAX then
        out[#out + 1] = ("    ** command line EXCEEDS the Windows limit by %d chars **")
            :format(len - WIN_CMDLINE_MAX)
    end
    if r.ok then
        out[#out + 1] = ("    result  = pid %s"):format(tostring(r.id))
    else
        out[#out + 1] = ("    result  = SPAWN FAILED: %s"):format(tostring(r.id))
    end
    out[#out + 1] = "    argv:"
    for i, a in ipairs(argv) do
        out[#out + 1] = ("      [%03d] |%s|"):format(i, a)
    end
    return table.concat(out, "\n") .. "\n\n"
end

--- Append one spawn record to `vim.g.gitloom_git_debug` (a file path). A no-op —
--- and free of any work at all — when the global is not a string. Diagnostics
--- only: never let it break a fetch, so every step is guarded.
---@param cmd string[]
---@param cwd string?
---@param ok boolean       -- did the spawn return without throwing?
---@param id any           -- the pid / job id, or the error the spawn threw
---@param site string?     -- the fetch.lua/window.lua call chain that issued it
local function debug_log(cmd, cwd, ok, id, site)
    local path = vim.g.gitloom_git_debug
    if type(path) ~= "string" then return end
    spawn_seq = spawn_seq + 1
    pcall(function()
        local exe = cmd[1] or ""
        if not exe:find("[/\\]") then exe = vim.fn.exepath(exe) end
        local rec = spawn_record({
            argv = cmd, exe = exe, cwd = cwd, site = site,
            seq = spawn_seq, ok = ok, id = id,
        })
        local fh = io.open(path, "a")
        if fh then
            fh:write(rec)
            fh:close()
        end
    end)
end

--- The fetch.lua → caller chain that issued a spawn, so a record names its call
--- site. Only walked when the debug hook is armed.
---@return string
local function call_site()
    local parts = {}
    for lvl = 3, 7 do
        local i = debug.getinfo(lvl, "Sln")
        if not i then break end
        local src = (i.short_src or "?"):gsub(".*[/\\]", "")
        parts[#parts + 1] = ("%s:%d%s"):format(src, i.currentline or 0,
            i.name and ("(" .. i.name .. ")") or "")
    end
    return table.concat(parts, " <- ")
end

-- Hand control back to the main loop **and let it go idle**, so nvim redraws
-- before the next slice of work (spec §3.1: "the view paints progressively").
--
-- `vim.schedule` is NOT enough, and that is the whole reason this exists. A
-- scheduled callback lands on the main loop's *event* queue, which nvim drains to
-- empty before it returns to the point where it flushes the screen — so a worker
-- that reschedules itself keeps the queue non-empty and the screen never updates
-- until the queue finally runs dry. Measured on 0.12.5 with a 60-step chain of
-- 8 ms slices: `vim.schedule` produced **0** SafeState events (nvim's idle point,
-- where the redraw happens) across the whole chain, a 0 ms timer produced 59.
--
-- A 0 ms `uv` timer fires on the next loop iteration instead, which is a real
-- return to the top of the loop: the screen updates and a keypress is seen.
---@param fn fun()
local function next_tick(fn)
    local t = assert(vim.uv.new_timer())
    t:start(0, 0, function()
        t:stop()
        t:close()
        vim.schedule(fn)
    end)
end

-- THE one place gitloom starts a git process: `vim.system` (luv pipes), pinned
-- to the active repository root, with the `vim.g.gitloom_git_debug` record.
-- Every git command goes through here — the commit stream directly, every
-- buffered query through `run` below — so a single setter (`M.set_cwd`)
-- retargets the whole I/O layer.
--
-- Why `vim.system` and never `jobstart`: a `jobstart` job LOSES its unread
-- output when the process exits while the main loop is behind on draining it.
-- Neovim stops reading the pipe under backpressure, git still writes everything
-- and exits 0, and `on_exit` arrives without the rest (measured on 0.12.5 /
-- Windows: a 20 ms batch handler dropped over half of a 496-commit log, the last
-- record cut mid-line -- see tests/stream_complete_spec.lua). `vim.system` reads
-- in luv callbacks, which never stop reading, and calls `on_exit` only after
-- stdout AND stderr have hit EOF, so its result is always the whole output.
--
-- It only fills in `cwd` (when unset): with `active_cwd` nil the field stays nil
-- and the process observes Neovim's cwd, as before. `o.env` is merged over
-- Neovim's environment (vim.system's default, as jobstart's `env` was); a string
-- `o.stdin` is written and then closed. As with `vim.system` itself, the
-- callbacks (a function `o.stdout`, and `on_exit`) run in a FAST context — `run`
-- is the main-loop wrapper. On Windows Neovim substitutes `exepath(argv[1])`
-- before spawning exactly as jobstart did, and both go through libuv's
-- `uv_spawn`, so the WIN_CMDLINE_MAX model holds unchanged (re-measured against
-- vim.system in tests/git_debug_spec.lua).
--
-- When `vim.g.gitloom_git_debug` names a file, every spawn is appended to it
-- (full argv, resolved cwd + exe, command-line length vs. the Windows ceiling,
-- the pid or the failure). A spawn failure (no git, a missing cwd, an overlong
-- command line — `ENAMETOOLONG`) re-raises vim.system's error with
-- `error(msg, 0)` whether or not the hook is armed; with the global unset the
-- hook costs one type check.
---@param cmd string[]
---@param o vim.SystemOpts
---@param on_exit fun(out: vim.SystemCompleted)
---@return vim.SystemObj
local function spawn(cmd, o, on_exit)
    o.cwd = o.cwd or active_cwd
    local armed = type(vim.g.gitloom_git_debug) == "string"
    local site = armed and call_site() or nil
    local ok, obj = pcall(vim.system, cmd, o, on_exit)
    if armed then debug_log(cmd, o.cwd, ok, ok and obj.pid or obj, site) end
    if not ok then error(obj, 0) end
    return obj
end

--- Run a git command to completion and resolve a future with its WHOLE output,
--- `{ code, out, err }` (raw strings — CRs kept, nothing trimmed) **on the main
--- loop**: the exit callback hops there with `vim.schedule` before resolving, so
--- a `.next` may touch any Neovim state. `o.cwd` overrides the active root for
--- this one command, `o.env` adds variables, `o.stdin` is written then closed.
--- A spawn failure raises (see `spawn`).
---@param cmd string[]
---@param o { cwd?: string, env?: table<string, string>, stdin?: string }?
---@return Future  -- resolving { code: integer, out: string, err: string }
local function run(cmd, o)
    o = o or {}
    local future, promise = make_future()
    spawn(cmd, { cwd = o.cwd, env = o.env, stdin = o.stdin }, function(res)
        vim.schedule(function()
            promise.resolve({ code = res.code, out = res.stdout or "", err = res.stderr or "" })
        end)
    end)
    return future
end

--- A buffered output string as the line list `jobstart`'s `stdout_buffered`
--- delivered (and the callers were written against): split on `\n` only (a CR
--- stays on its line), the last element the text after the final newline —
--- `""` when the output ends with one, `{ "" }` for no output at all.
---@param s string
---@return string[]
local function lines_of(s)
    return vim.split(s, "\n", { plain = true })
end

-- Test seam for the spawn diagnostics (not the public API; see CLAUDE.md).
M._internal = {
    WIN_CMDLINE_MAX = WIN_CMDLINE_MAX,
    quoted_len = quoted_len,
    cmdline_len = cmdline_len,
    spawn_record = spawn_record,
    debug_log = debug_log,
    next_tick = next_tick,
    spawn = spawn,
    run = run,
}

-- The `%x1f`-delimited `git log` pretty-format shared by the initial stream and
-- the resync's bounded fetch: %H %P %an %at %ai %ct %s (author epoch + iso feed
-- the Timestamp §4; committer epoch %ct seeds the sort §3.1); %s last (single
-- line). Parsed by parse_commit_line.
local COMMIT_LOG_FMT = "%H%x1f%P%x1f%an%x1f%at%x1f%ai%x1f%ct%x1f%s"

-- Commits parsed per scheduled worker turn. The stdout handler only enqueues
-- raw lines; a `vim.schedule`d worker drains the queue this many at a time and
-- yields back to the event loop between batches, so the UI stays responsive and
-- redraws as commits stream in (one `on_batch` => one layout + one insert).
local COMMIT_BATCH = 256

-- The null device git's `--no-index` understands cross-platform as the empty
-- side, so an untracked file renders as a whole-file addition (§3.3).
local NULL_DEVICE = "/dev/null"
-- Cap on untracked files synthesized into the untracked node's diff, so a huge
-- untracked tree never floods the commit view (§3.3 / spec open point).
local UNTRACKED_DIFF_CAP = 100

-- The `git log` format the submodule view parses: the same fields as the main
-- stream (COMMIT_LOG_FMT, so parse_commit_line handles it — including the `%ct`
-- committer epoch at field 6, without which the subject shifts and is lost) plus
-- a trailing `%d` decoration field (field 8, read by parse_log below).
local SUBMODULE_LOG_FMT = "%H%x1f%P%x1f%an%x1f%at%x1f%ai%x1f%ct%x1f%s%x1f%d"

-- `git for-each-ref` format shared by the initial ref read and the resync (§3.2,
-- §6.3). Space-separated like the original (for-each-ref does NOT interpret a
-- `%x1f` hex escape — it would print it literally). The first four atoms never
-- contain a space (object name, refname, annotated-tag deref, upstream short
-- name), so `%(upstream:track)` — the one field with spaces ("ahead N, behind M")
-- — is placed **last** and parsed as everything from field 5 on. The upstream
-- atoms populate only for a local branch that tracks an upstream.
local REF_FMT =
    "%(objectname) %(refname) %(*objectname) %(upstream:short) %(upstream:track,nobracket)"

-- Parse one REF_FMT line into `{ kind, name, hash, upstream? }`, or nil to skip
-- (classify_ref returns nil — a remote HEAD symref, etc.). The upstream is set
-- only when a tracked branch reports an `%(upstream:short)`; `track` is empty when
-- in sync, "gone" when the upstream was deleted, else "ahead N" / "behind M" /
-- "ahead N, behind M" (§6.3).
---@param line string
---@return { kind: string, name: string, hash: string, upstream?: Upstream }?
local function parse_ref_line(line)
    local parts = vim.split(line, " ")
    local hash, refname, deref, up_short = parts[1], parts[2], parts[3], parts[4]
    local track = table.concat(parts, " ", 5) -- field 5..end (may hold spaces); "" if none
    local kind, name = classify_ref(refname or "")
    if not (kind and name and hash) then return nil end
    local target = (deref and deref ~= "") and deref or hash
    local upstream = nil
    if up_short and up_short ~= "" then
        if track == "gone" then
            upstream = { short = up_short, ahead = 0, behind = 0, gone = true }
        else
            upstream = {
                short = up_short,
                gone = false,
                ahead = tonumber((track or ""):match("ahead (%d+)")) or 0,
                behind = tonumber((track or ""):match("behind (%d+)")) or 0,
            }
        end
    end
    return { kind = kind, name = name, hash = target, upstream = upstream }
end

--- Read the linked worktrees' HEADs as refs (spec §3.2). `taken` is the set of
--- commit hashes the refs already read point at — the skip-if-already-referenced
--- rule lives in the pure `refs.worktree_refs`; this only supplies the I/O.
--- Resolves to a list of `{ name = "wt:<dir>", kind = "worktree", hash }`, empty
--- when the repository has no linked worktrees (or `git worktree` fails — an old
--- git or a plain checkout must degrade to today's behaviour, not error).
---@param taken table<string, boolean>
---@return Future
local function read_worktree_refs(taken)
    return run({ "git", "worktree", "list", "--porcelain" }).next(function(res)
        if res.code ~= 0 then return {} end
        local lines = {}
        for _, line in ipairs(lines_of(res.out)) do lines[#lines + 1] = trim_ws(line) end
        return worktree_refs(parse_worktrees(lines), taken)
    end)
end

--- Read all refs via `git for-each-ref` and resolve each to its commit. Local
--- branches that track an upstream carry their divergence (§6.3); annotated tags
--- are dereferenced to the commit. The linked worktrees' HEADs are then read and
--- added as `worktree` refs (§3.2) — chained after, since the skip rule needs to
--- know which commits the real refs already name.
---@param repo Repo
function M.fetch_refs(repo)
    local taken = {}
    return run({ "git", "for-each-ref", "--format=" .. REF_FMT,
        "refs/heads", "refs/remotes", "refs/tags" }).next(function(res)
        for _, line in ipairs(lines_of(res.out)) do
            if line ~= "" then
                local r = parse_ref_line(line)
                if r then
                    add_ref(repo, r.name, r.kind, r.hash, r.upstream)
                    taken[r.hash] = true
                end
            end
        end
        return read_worktree_refs(taken).next(function(wts)
            for _, w in ipairs(wts) do add_ref(repo, w.name, w.kind, w.hash) end
        end)
    end)
end

--- Mark HEAD's commit with a `head` ref. On a branch (`symbolic-ref` resolves)
--- that branch's tip is marked and `repo.head` set; on a **detached HEAD** the
--- checked-out commit is marked directly (`rev-parse HEAD`) with `repo.head` left
--- nil, so the graph still shows where HEAD is (§3.2).
---@param repo Repo
function M.fetch_head(repo)
    return run({ "git", "symbolic-ref", "--short", "--quiet", "HEAD" }).next(function(res)
        local name = lines_of(res.out)[1]
        if name and name ~= "" then
            repo.head = name
            local localref = repo.refs[name]
            if localref then
                add_ref(repo, "HEAD", "head", localref.commit.hash)
            end
        end
        if repo.head then return end
        -- Detached HEAD: no branch name. Mark the checked-out commit.
        return run({ "git", "rev-parse", "HEAD" }).next(function(rp)
            local hash = lines_of(rp.out)[1]
            if hash and hash ~= "" then
                add_ref(repo, "HEAD", "head", hash)
            end
        end)
    end)
end

--- Read the current ref set **without mutating the model** — the resync (§3.4)
--- needs the fresh refs to diff against `repo.refs` (added / removed / moved)
--- before applying changes. Resolves to `{ entries, head }`: `entries` is a list
--- of `{ name, kind, hash, upstream? }` (annotated tags dereferenced, upstream
--- tracking captured like fetch_refs so `R` refreshes the §6.3 indicator), `head`
--- the current branch name (nil when detached), and `detached` the checked-out
--- commit hash when detached (so the resync can still mark HEAD; nil on a branch).
---
--- The linked worktrees' HEADs are included as `worktree` entries (§3.2), so the
--- resync reconciles them exactly like branch tips. This is load-bearing rather
--- than cosmetic: the orphan prune keeps only what a ref reaches, so omitting
--- them here would make the first `R` silently delete every commit a linked
--- worktree has checked out (§3.4).
---@return Future
function M.fetch_ref_entries()
    local entries = {}
    local taken = {}

    local function first_line(res)
        local l = lines_of(res.out)[1]
        return (l and l ~= "") and l or nil
    end
    local function finish(res)
        return read_worktree_refs(taken).next(function(wts)
            for _, w in ipairs(wts) do entries[#entries + 1] = w end
            return res
        end)
    end

    return run({ "git", "for-each-ref", "--format=" .. REF_FMT,
        "refs/heads", "refs/remotes", "refs/tags" }).next(function(res)
        for _, line in ipairs(lines_of(res.out)) do
            if line ~= "" then
                local r = parse_ref_line(line)
                if r then
                    entries[#entries + 1] =
                        { name = r.name, kind = r.kind, hash = r.hash, upstream = r.upstream }
                    taken[r.hash] = true
                end
            end
        end
        -- Chain HEAD's symbolic-ref so the head binding can be reconciled in the
        -- same pass. When detached (no branch), chain `rev-parse HEAD` so the
        -- checked-out commit can still be marked (§3.2).
        return run({ "git", "symbolic-ref", "--short", "--quiet", "HEAD" }).next(function(sr)
            local head = first_line(sr)
            if head then
                return finish({ entries = entries, head = head })
            end
            return run({ "git", "rev-parse", "HEAD" }).next(function(rp)
                return finish({ entries = entries, head = nil, detached = first_line(rp) })
            end)
        end)
    end)
end

--- Stream `git log` and hand commits to `opts.on_batch` in batches as they
--- arrive. The window is already open; this fills it incrementally rather than
--- blocking until the whole log is read (so a large repo paints progressively).
---
--- The stdout handler stays light — it stitches partial lines and enqueues raw
--- text only. A scheduled worker does the per-commit work (`parse_commit_line` +
--- `on_batch`), `COMMIT_BATCH` at a time, rescheduling itself until drained so a
--- big log never stalls the event loop in one callback. The returned future
--- resolves once the stream has closed *and* the queue is fully drained.
---@param opts { branch?: string|string[], count?: integer, on_batch?: fun(commits: Commit[]) }
function M.fetch_commits(opts)
    opts = opts or {}

    local future, promise = make_future()

    if opts.branch and type(opts.branch) ~= "table" then
        opts.branch = { opts.branch --[[@as string]] }
    end
    local branch = opts.branch --[[@as string[] ]] or {}

    -- Refs come from fetch_refs (§3.2), so no --decorate here. %at (epoch) +
    -- %ai (carries the tz offset) feed the structured Timestamp (§4).
    -- Stream in git's `--topo-order` (spec §3.1): a valid topological base for
    -- progressive painting, the verbatim order of the `git` sort mode, and the
    -- input the `gitloom` sort mode re-clusters on top of. The active sort mode
    -- (applied at completion) decides the final row order.
    -- The refspec is appended by hand rather than with `unpack(branch)`: LuaJIT
    -- caps how many values unpack may return, and this list is the caller's
    -- (`opts.branches`, default the single `--all`), so its length is not ours
    -- to assume.
    local command = { "git", "log", "--topo-order", "--parents" }
    for _, b in ipairs(branch) do command[#command + 1] = b end
    command[#command + 1] = "--pretty=format:" .. COMMIT_LOG_FMT
    if opts.count then
        table.insert(command, "-n")
        table.insert(command, tostring(opts.count))
    end

    local linebuf = make_line_buffer()
    -- Raw-line queue drained by the worker. An explicit head/tail avoids the
    -- O(n) `table.remove(_, 1)` and the `#queue` ambiguity that niled holes
    -- would create.
    local queue = {}
    local qhead, qtail = 1, 0
    local scheduled = false
    local stream_done = false

    local function process_batch()
        scheduled = false
        local commits = {}
        local stop = math.min(qhead + COMMIT_BATCH - 1, qtail)
        for i = qhead, stop do
            local commit = parse_commit_line(queue[i])
            if commit then
                commits[#commits + 1] = commit
            end
            queue[i] = nil
        end
        qhead = stop + 1

        if #commits > 0 and opts.on_batch then
            opts.on_batch(commits)
        end

        if qhead <= qtail then
            -- More queued (incl. lines that arrived while we worked): yield to
            -- the loop, then continue. NOT `vim.schedule` — see next_tick.
            scheduled = true
            next_tick(process_batch)
        elseif stream_done then
            promise.resolve()
        end
    end

    local function schedule_drain()
        if not scheduled then
            scheduled = true
            next_tick(process_batch)
        end
    end

    local function enqueue(lines)
        for _, line in ipairs(lines) do
            qtail = qtail + 1
            queue[qtail] = line
        end
    end

    -- Streamed through `spawn` (vim.system), never `jobstart`: see there for
    -- the truncated-stream regression. Both callbacks are FAST-context; they
    -- only stitch + enqueue (next_tick is a uv timer, safe here), and the
    -- completion hops onto the main loop before resolving the future.
    spawn(
        command,
        {
            stdout = function(_, data)
                if not data then return end -- EOF; on_exit follows
                enqueue(linebuf.feed(vim.split(data, "\n", { plain = true })))
                if qhead <= qtail then
                    schedule_drain()
                end
            end,
        },
        function()
            vim.schedule(function()
                local last = linebuf.flush()
                if last ~= "" then
                    enqueue({ last })
                end
                stream_done = true
                if qhead > qtail then
                    -- Nothing left to process — resolve now; otherwise the
                    -- worker resolves once it drains.
                    if not scheduled then promise.resolve() end
                else
                    schedule_drain()
                end
            end)
        end)

    return future
end

--- Build the resync query (§3.4) — the argv plus the revision list it walks.
--- Pure and exposed so the **argv bound** is testable: the revision list scales
--- with the repository's ref count, and an argv is a hard-capped resource (on
--- Windows the whole command line must fit 32767 characters *including* the
--- resolved executable path, and libuv rejects an overlong one with
--- `UV_ENAMETOOLONG` — surfacing as nvim's `E903 … name too long: <git.exe>`).
--- So the revisions go on **stdin** (`git log --stdin`, a rev-list option `git
--- log` shares: one revision per line, `^<hash>` excluding) instead of on the
--- command line, which removes the bound rather than raising it.
---@param new_tips string[]  current ref tip hashes (positive revisions)
---@param old_tips string[]  previous ref tip hashes (negative revisions)
---@return string[] argv   -- constant size, whatever the tip counts
---@return string stdin    -- the newline-terminated revision list
function M.new_commits_query(new_tips, old_tips)
    local argv = { "git", "log", "--parents", "--pretty=format:" .. COMMIT_LOG_FMT, "--stdin" }
    -- One revision per line: a bare hash includes it, `^<hash>` excludes it —
    -- exactly what `<new tips> --not <old tips>` meant on the command line.
    local revs = {}
    for _, h in ipairs(new_tips) do revs[#revs + 1] = h end
    for _, h in ipairs(old_tips) do revs[#revs + 1] = "^" .. h end
    if #revs == 0 then return argv, "" end
    return argv, table.concat(revs, "\n") .. "\n"
end

--- Fetch the commits newly reachable since the last read — the resync's bounded
--- query (§3.4): `git log --parents --stdin` fed `<new tips>` and `^<old tips>`
--- returns exactly the commits reachable from the current ref tips but not from
--- the previous ones (usually a handful after a fetch / commit). Buffered (the
--- set is small) and resolves to a list of parsed `Commit`s; their already-present
--- parents are linked back into the model by the caller (`integrate_commit`).
--- With no new tips it resolves empty; with no old tips no `^` line is written
--- (fetches all reachable, the cold-start case the stream normally covers).
---@param new_tips string[]  current ref tip hashes (positive refs)
---@param old_tips string[]  previous ref tip hashes (negative refs)
---@return Future
function M.fetch_new_commits(new_tips, old_tips)
    local future, promise = make_future()
    if #new_tips == 0 then
        promise.resolve({})
        return future
    end

    local command, revs = M.new_commits_query(new_tips, old_tips)

    -- The revision list rides stdin: `run` writes it and then **closes stdin** —
    -- `--stdin` reads until EOF, so a missed close would wedge the resync forever
    -- with no error to show for it. A failed spawn resolves empty rather than
    -- leaving the resync hanging (as a failed `jobstart` did).
    local ok, job = pcall(run, command, { stdin = revs })
    if not ok then
        vim.schedule(function() promise.resolve({}) end)
        return future
    end
    return job.next(function(res)
        local commits = {}
        for _, line in ipairs(lines_of(res.out)) do
            if line ~= "" then
                local c = parse_commit_line(line)
                if c then commits[#commits + 1] = c end
            end
        end
        return commits
    end)
end

--- Ask git for an exact commit order — the `rev`-based sort modes (spec §3.1).
--- `git rev-list <flag> <refspec>` lists hashes newest-first in git's chosen
--- order (same convention as the row order). Buffered; resolves to the hash list.
---@param branch string[]  the refspec (e.g. { "--all" } or branch names)
---@param flag string      the order flag (`--topo-order` / `--date-order` / …)
---@return Future
function M.fetch_rev_order(branch, flag)
    -- Appended by hand, not `unpack(branch)` — see fetch_commits: the refspec is
    -- the caller's list and LuaJIT caps unpack's return count.
    local command = { "git", "rev-list", flag }
    for _, b in ipairs(branch) do command[#command + 1] = b end
    return run(command).next(function(res)
        local hashes = {}
        for _, line in ipairs(lines_of(res.out)) do
            if line ~= "" then hashes[#hashes + 1] = line end
        end
        return hashes
    end)
end

--- Run a git command and resolve the future with its stdout as a list of
--- non-empty lines. A small sibling of fetch_commit_diff for the short
--- working-tree queries (§3.3); runs in the active repository root like the
--- rest, unless an explicit `cwd` is given (the repository picker, §2.1, queries
--- a specific repo without disturbing the active root).
---@param args string[]
---@param cwd string?  -- explicit working directory; nil = the active root
---@return Future
local function git_lines(args, cwd)
    return run(vim.list_extend({ "git" }, args), { cwd = cwd }).next(function(res)
        local out = {}
        for _, l in ipairs(lines_of(res.out)) do
            if l ~= "" then out[#out + 1] = l end
        end
        return out
    end)
end

--- Run a git command and resolve the future with its full stdout as one string
--- (the patch). Used for the working-tree diffs (§3.3); mirrors
--- fetch_commit_diff but for an arbitrary git argv.
---@param args string[]
---@return Future
local function git_string(args)
    return run(vim.list_extend({ "git" }, args)).next(function(res) return res.out end)
end

-- ===== the repository picker (spec §2.1) ===================================
--
-- The picker's cost is **process spawns**, not git's work: on the author's
-- Windows machine a trivial `git` spawn is ~30 ms warm and was measured at
-- ~225 ms on a slower one, and the old flow paid one spawn to discover the
-- submodules plus **two per repository** to summarize it. Worse, the discovery
-- spawn was `git submodule status`, which opens every submodule's repository
-- in turn: ~650 ms of fixed cost plus ~150 ms *per submodule* here (~2.0 s for
-- nine), so the list was gated on a cost linear in the submodule count.
--
-- So discovery reads the index's gitlinks (`git ls-files --stage`, ONE spawn
-- whatever the submodule count — the same path set `submodule status` walks,
-- see submodule.parse_gitlinks) and answers "is it checked out / at which
-- commit" from the **filesystem**, and a summary reads its branch from `HEAD`
-- and spends its single remaining spawn on `git log -1`. Total: 1 + N spawns
-- instead of 1 + 2N, with the linear-in-N git work gone entirely.

-- The `git log -1` format one picker-row summary needs (spec §2.1): short hash,
-- subject, and `%D` — the ref decoration, whose `HEAD -> <branch>` names the
-- current branch, so the branch needs no second spawn. Parsed by
-- parse.parse_summary.
local SUMMARY_LOG_FMT = "%h%x1f%s%x1f%D"

--- Read a repository's first line of `path` (a short plumbing file), or nil when
--- it cannot be read. Never throws — a missing/locked file is a normal answer.
---@param path string
---@return string?
local function read_first(path)
    local ok, lines = pcall(vim.fn.readfile, path, "", 1)
    return (ok and lines[1]) or nil
end

--- The **git directory** of the repository whose work tree is `root`, or nil
--- when there is none (an uninitialized submodule). A checked-out submodule
--- normally has a `.git` *file* pointing into the superproject's
--- `.git/modules/…`, usually by a relative path — resolved here against `root`.
--- Filesystem only; no spawn.
---@param root string
---@return string?
local function git_dir(root)
    local dot = root .. "/.git"
    local st = vim.uv.fs_stat(dot)
    if not st then return nil end
    if st.type == "directory" then return dot end
    if st.type ~= "file" then return nil end
    local p = parse.parse_gitdir(read_first(dot))
    if not p then return nil end
    p = p:gsub("\\", "/")
    -- A drive-letter or root-anchored gitdir is absolute; anything else is
    -- relative to the submodule's work tree.
    if p:match("^%a:") or p:match("^/") then return p end
    return root .. "/" .. p
end

--- HEAD's short branch name and commit for the repository at `root`, read
--- straight off the filesystem (spec §2.1) — **no spawn at all**. `branch` is
--- empty on a detached HEAD; `hash` is nil when it cannot be resolved (an unborn
--- branch, or a ref this simple reader cannot follow). Returns nil only when
--- `root` is not a checked-out repository at all, so `head_info(root) ~= nil` is
--- exactly the picker's "there is a local repository to open" test.
---@param root string
---@return { branch: string, hash: string? }?
local function head_info(root)
    local dir = git_dir(root)
    if not dir then return nil end
    local h = parse.parse_head(read_first(dir .. "/HEAD"))
    if h.hash then return { branch = "", hash = h.hash } end -- detached
    if not h.ref then return { branch = "" } end
    local loose = read_first(dir .. "/" .. h.ref)
    local hash = loose and loose:match("^(%x+)") or nil
    if not hash then
        -- No loose ref file: the branch is packed (or unborn).
        local ok, packed = pcall(vim.fn.readfile, dir .. "/packed-refs")
        hash = ok and parse.packed_ref(packed, h.ref) or nil
    end
    return { branch = h.branch, hash = hash }
end

--- List the direct submodules of the repository at `cwd` (the repository
--- picker, spec §2.1). **One** spawn, whatever the submodule count: the index's
--- `160000` gitlinks come from `git ls-files --stage` run in `cwd` explicitly —
--- the picker is an entry point that must query the cwd's repo without
--- disturbing any open graph's active root — and each entry's checkout state is
--- then read off the filesystem (`submodule.submodule_state`) rather than by
--- opening its repository. Resolves `{ name, path, sha, state, checked_out }`
--- per submodule (empty when the repo has none); `sha` is the **recorded**
--- gitlink.
---@param cwd string
---@return Future
function M.fetch_submodules(cwd)
    return run({ "git", "ls-files", "--stage" }, { cwd = cwd }).next(function(res)
        -- Filter first: the index of a large repository is mostly ordinary
        -- files, and only the gitlinks are worth keeping.
        local gitlinks = {}
        for _, l in ipairs(lines_of(res.out)) do
            if l:sub(1, 6) == "160000" then gitlinks[#gitlinks + 1] = l end
        end
        local out = {}
        for _, e in ipairs(submodule.parse_gitlinks(gitlinks)) do
            local head = head_info(cwd .. "/" .. e.path)
            local state = submodule.submodule_state(e.sha, {
                gitdir = head ~= nil,
                head = head and head.hash or nil,
                conflict = e.conflict,
            })
            out[#out + 1] = {
                name = e.name,
                path = e.path,
                sha = e.sha,
                state = state,
                checked_out = state ~= "uninitialized",
            }
        end
        return out
    end)
end

--- A one-line summary of the repository at `cwd` for a picker row (spec §2.1):
--- the current branch (empty on a detached HEAD), the HEAD short hash, and its
--- subject. **One** spawn: the branch is read from `HEAD` on the filesystem
--- (`head_info`, free) and only the short hash + subject need `git log -1`,
--- whose `%D` decoration is the fallback branch for a repository layout the file
--- read cannot follow. Resolves `{ branch, short, subject }`; an empty repo (no
--- HEAD commit) resolves its branch with empty hash/subject.
---@param cwd string
---@return Future
function M.fetch_repo_summary(cwd)
    local head = head_info(cwd)
    return git_lines({ "log", "-1", "--format=" .. SUMMARY_LOG_FMT }, cwd)
        .next(function(ll)
            local s = parse.parse_summary(ll[1])
            local branch = head and head.branch or ""
            if branch == "" then branch = s.branch end
            return { branch = branch, short = s.short, subject = s.subject }
        end)
end

--- Read HEAD's hash and the dirty-state counts (spec §3.3). Resolves
--- `{ head_hash, status }`; `head_hash` is nil on an unborn branch (no HEAD),
--- which skips the virtual commits.
---@return Future
function M.fetch_worktree_state()
    return git_lines({ "rev-parse", "HEAD" }).next(function(rl)
        local head_hash = rl[1]
        return git_lines({ "status", "--porcelain" }).next(function(slines)
            return { head_hash = head_hash, status = parse_status(slines) }
        end)
    end)
end

--- Synthesize the untracked files' additions as a patch (spec §3.3): each
--- untracked file (respecting `.gitignore`) is diffed against the null device
--- via `git diff --no-index`, so it renders as a whole-file addition through the
--- existing diff pipeline. Capped at UNTRACKED_DIFF_CAP files. Chained
--- sequentially so a dirty tree's untracked set produces one concatenated patch.
---@return Future
local function fetch_untracked_diff()
    local future, promise = make_future()
    git_lines({ "ls-files", "--others", "--exclude-standard" }).next(function(files)
        local parts = {}
        local i = 0
        local function step()
            i = i + 1
            if i > #files or i > UNTRACKED_DIFF_CAP then
                promise.resolve(table.concat(parts, "\n"))
                return
            end
            -- `git diff --no-index` exits non-zero when the files differ; we
            -- collect stdout regardless (git_string ignores the code).
            git_string({ "diff", "--no-index", "--", NULL_DEVICE, files[i] }).next(function(p)
                if p and p ~= "" then parts[#parts + 1] = p end
                step()
            end)
        end
        step()
    end)
    return future
end

--- The patch for a working-tree virtual commit (spec §3.3 / §11.8). Staged is
--- the index vs HEAD (`git diff --cached`); unstaged is the **tracked** working
--- tree vs the index (`git diff`); untracked is the synthesized additions for the
--- untracked files. On demand, like the rest of the commit view.
---@param kind "staged"|"unstaged"|"untracked"
---@return Future
function M.fetch_worktree_diff(kind)
    if kind == "staged" then
        return git_string({ "diff", "--cached" })
    elseif kind == "untracked" then
        return fetch_untracked_diff()
    end
    return git_string({ "diff" })
end

--- Fetch one commit's full detail via `git show -s` (specification.md §11.1).
--- Buffered; resolves the raw `%x1f`-delimited output as a single string (the
--- body `%B` is last so its newlines survive). On-demand only — not part of the
--- graph stream.
---@param hash string
function M.fetch_commit_detail(hash)
    return run({ "git", "show", "-s", "--date=iso",
        "--format=%H%x1f%an%x1f%ae%x1f%ad%x1f%cn%x1f%ce%x1f%cd%x1f%P%x1f%B", hash })
        .next(function(res) return res.out end)
end

--- Fetch a commit's diff via `git show --format= -p` (specification.md §11.3).
--- Buffered; resolves the raw patch string. On-demand only, chained after
--- fetch_commit_detail by the commit view.
---@param hash string
function M.fetch_commit_diff(hash)
    return run({ "git", "show", "--format=", "-p", hash })
        .next(function(res) return res.out end)
end

--- Run a git command and resolve `{ code, out, err }` (stdout raw, stderr
--- whitespace-trimmed). A thin future over `run` for the submodule change view
--- (§11.7) and the range diff (§13.5). The submodule is addressed with
--- `git -C <path>` by the caller (the path is relative to the active repository
--- root, §2.1) rather than the process's own `cwd`, so a missing checkout fails
--- the command (nonzero exit) instead of throwing on an invalid working
--- directory. Resolves `{ code = -1, err = <the spawn error> }` if the process
--- cannot be spawned.
--- `cwd` overrides the active root for this one command (checkout, §10.4.1,
--- runs in the graph's own `repo.root`). `env` adds variables to the process's
--- environment (merged over Neovim's; the palette's fetch / pull, §17.3).
---@param args string[]
---@param cwd string?
---@param env table<string, string>?
---@return table  -- future resolving { code: integer, out: string, err: string }
local function git_code(args, cwd, env)
    local ok, job = pcall(run, args, { cwd = cwd, env = env })
    if not ok then
        local future, promise = make_future()
        vim.schedule(function()
            promise.resolve({ code = -1, out = "", err = tostring(job) })
        end)
        return future
    end
    return job.next(function(res)
        return { code = res.code, out = res.out, err = trim_ws(res.err) }
    end)
end

--- Run a checkout command (`checkout_spec`'s argv, §10.4.1) in the repository
--- `root` — the graph's `repo.root`, which may be a submodule, never implicitly
--- Neovim's cwd. Resolves `{ code, out, err }`; the caller reports a non-zero
--- code with git's stderr and changes nothing. The argv never forces.
---@param argv string[]
---@param root string?
---@return table  -- future resolving { code: integer, out: string, err: string }
function M.run_checkout(argv, root)
    return git_code(argv, root)
end

--- Run a palette remote command (`remote_command`'s argv + env, §17.3) in the
--- repository `root` — the graph's `repo.root`, never implicitly Neovim's cwd —
--- with `env` (`GIT_TERMINAL_PROMPT=0`) added to the job's environment. Resolves
--- `{ code, out, err }`. The argv never forces.
---@param argv string[]
---@param root string?
---@param env table<string, string>?
---@return table  -- future resolving { code: integer, out: string, err: string }
function M.run_remote(argv, root, env)
    return git_code(argv, root, env)
end

--- The repository's remote names, in `git remote` order (§17.1) — local and
--- fast, no network. Runs in `root` (the graph's `repo.root`). Resolves the
--- `parse_remotes` list, or nil when git fails (the caller keeps what it had).
---@param root string?
---@return table  -- future resolving string[]?
function M.fetch_remotes(root)
    return git_code({ "git", "remote" }, root).next(function(res)
        if res.code ~= 0 then return nil end
        return require("gitloom.git.remote").parse_remotes(res.out)
    end)
end

--- Fetch the **combined** patch for a `DiffRange` (spec §13.5): `git diff
--- <base> <to>`, where `base` is the range's `from` (its older end's first
--- parent) or the empty tree for a root. Buffered; used by the range commit view.
---
--- Unlike `fetch_commit_diff` it resolves `git_code`'s `{ code, out, err }`
--- rather than a bare patch string, because this is the one diff whose arguments
--- are *derived* — `from` is the older end's parent, `to` the newer end — so a
--- bad endpoint is a live possibility. Swallowing the exit code made such a
--- failure indistinguishable from "this range has no changes": the range view
--- rendered its commit list with no patch and no error. The caller reports a
--- non-zero code instead of showing an empty diff.
--- An endpoint that is a **tree state** (`"index"` / `"worktree"`, §4.2/§13.5)
--- contributes a flag or nothing at all, never a rev: the working-tree virtual
--- commits carry reserved sentinel hashes, so this is where the invariant "a
--- sentinel hash never reaches a git rev" is kept on the I/O side — only a *table*
--- endpoint is ever asked for its `.hash`. An **untracked** newer end additionally
--- appends the §3.3 synthesized additions, which `git diff` never lists.
---@param range_arg DiffRange
---@return table  -- future resolving { code: integer, out: string, err: string }
function M.fetch_range_diff(range_arg)
    local from, to = range_arg.from, range_arg.to
    local args = { "git", "diff" }
    if to == "index" then args[#args + 1] = "--cached" end
    -- The base. A Commit contributes its hash; a root (`nil`) the empty tree; the
    -- `"index"` tree state contributes nothing, which is `git diff`'s own default
    -- (working tree vs index). `"worktree"` as a base is degenerate (a range from
    -- the working tree to itself) and likewise contributes nothing.
    if type(from) == "table" then
        args[#args + 1] = from.hash
    elseif from == nil then
        args[#args + 1] = EMPTY_TREE
    end
    if type(to) == "table" then args[#args + 1] = to.hash end
    local diff = git_code(args)
    if range_arg.untracked then
        return diff.next(function(res)
            if res.code ~= 0 then return res end
            return fetch_untracked_diff().next(function(extra)
                if extra and extra ~= "" then
                    res.out = (res.out ~= "" and (res.out .. "\n") or "") .. extra
                end
                return res
            end)
        end)
    end
    return diff
end

--- Fetch the change graph for one parsed submodule bump (spec §11.7), gated and
--- asynchronous — it **never fetches**. Resolves a result table consumed by
--- `submodule_block`:
---   `{ path, available, reason? }`                              -- gate failed
---   `{ path, available, class, ahead, behind, base,
---      new_commits, old_commits, base_commit }`                 -- ff/rewind/diverged
--- The two sides are the first-parent lines `base..new` (added, `new_commits`,
--- newest-first with `B` first) and `base..old` (removed, `old_commits`, with `A`
--- first); a degenerate fast-forward/rewind leaves one list empty (the merge-base
--- *is* that pointer). `base_commit` is the shared ancestor the two lines meet at.
---@param opts GraphOptions
---@param change { path: string, old: string, new: string }
---@return table  -- a future
function M.fetch_submodule_graph(opts, change)
    local p, old, new = change.path, change.old, change.new
    -- `git -C <submodule path> …` (path is relative to the active repository
    -- root, §2.1, where the job runs), so an absent checkout simply errors
    -- rather than throwing.
    local function gc(args)
        local full = { "git", "-C", p }
        for _, a in ipairs(args) do full[#full + 1] = a end
        return git_code(full)
    end
    local function parse_log(out)
        local commits = {}
        for _, line in ipairs(vim.split(out or "", "\n")) do
            if line ~= "" then
                local c = parse_commit_line(line)
                if c then
                    c.deco = trim_ws((vim.split(line, "\x1f"))[8] or "")
                    commits[#commits + 1] = c
                end
            end
        end
        return commits
    end
    local function one(hash) -- future of a single Commit (nil if absent)
        return gc({ "log", "-1", "--format=" .. SUBMODULE_LOG_FMT, hash }).next(function(r)
            return parse_log(r.out)[1]
        end)
    end

    -- Presence gate (§11.7.1): both commits must resolve in the checked-out
    -- submodule. We never fetch to satisfy this.
    return gc({ "cat-file", "-e", old .. "^{commit}" }).next(function(r1)
        return gc({ "cat-file", "-e", new .. "^{commit}" }).next(function(r2)
            if r1.code ~= 0 or r2.code ~= 0 then
                return gc({ "rev-parse", "--git-dir" }).next(function(rp)
                    return {
                        path = p, available = false,
                        reason = (rp.code ~= 0) and "submodule not checked out"
                            or "commits not present locally",
                    }
                end)
            end
            -- Classify by merge-base, then fetch per class (§11.7.2).
            return gc({ "merge-base", old, new }).next(function(rb)
                local base = (rb.code == 0) and trim_ws(rb.out) or ""
                local class = submodule.classify(old, new, base)
                if class == "unrelated" then
                    return { path = p, available = false, reason = "unrelated histories" }
                end
                -- Both sides (§11.7.3): the first-parent line each pointer adds
                -- over the merge-base. `--first-parent` keeps a mainline merge a
                -- single node without dragging its side branch in (no lane "from
                -- nowhere" at the range boundary — the §10.7 focus). A degenerate
                -- fast-forward (base == old) / rewind (base == new) leaves one
                -- range empty, so that side's list comes back empty.
                local function side(tip)
                    return gc({ "log", "--first-parent",
                        "--format=" .. SUBMODULE_LOG_FMT, base .. ".." .. tip })
                        .next(function(rl) return parse_log(rl.out) end)
                end
                -- ahead/behind are the *total* commit counts (merges included) for
                -- the header `+N` / `−N`; the drawn rows are the first-parent lines.
                return gc({ "rev-list", "--count", base .. ".." .. new }).next(function(ra)
                    return gc({ "rev-list", "--count", base .. ".." .. old }).next(function(rbh)
                        return side(new).next(function(new_commits)
                            return side(old).next(function(old_commits)
                                return one(base).next(function(bc)
                                    return {
                                        path = p, available = true, class = class, base = base,
                                        ahead = tonumber(trim_ws(ra.out)) or 0,
                                        behind = tonumber(trim_ws(rbh.out)) or 0,
                                        new_commits = new_commits, old_commits = old_commits,
                                        base_commit = bc,
                                    }
                                end)
                            end)
                        end)
                    end)
                end)
            end)
        end)
    end)
end

return M
