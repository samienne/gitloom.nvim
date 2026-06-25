--- git I/O — the async commands that read the repository: refs, the commit
--- stream, the resync's bounded fetch, the rev-list sort orders, the working-tree
--- state/diffs, the on-demand commit detail/diff/range patches, and the submodule
--- change graph. Each returns a `Future` (util.make_future) over `vim.fn.jobstart`
--- run in Neovim's cwd. The one Neovim-coupled corner of gitloom.git; everything
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
local EMPTY_TREE = range.EMPTY_TREE

local M = {}

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

--- Read all refs via `git for-each-ref` and resolve each to its commit.
--- Output line: "<objectname> <refname> [<*objectname>]" — the dereferenced
--- hash is present (and used) for annotated tags.
---@param repo Repo
function M.fetch_refs(repo)
    local future, promise = make_future()

    vim.fn.jobstart(
        { "git", "for-each-ref", "--format=%(objectname) %(refname) %(*objectname)",
            "refs/heads", "refs/remotes", "refs/tags" },
        {
            stdout_buffered = true,
            on_stdout = function(_, lines)
                for _, line in ipairs(lines) do
                    if line ~= "" then
                        local parts = vim.split(line, " ")
                        local hash, refname, deref = parts[1], parts[2], parts[3]
                        local kind, name = classify_ref(refname or "")
                        if kind and name and hash then
                            local target = (deref and deref ~= "") and deref or hash
                            add_ref(repo, name, kind, target)
                        end
                    end
                end
            end,
            on_exit = function()
                promise.resolve()
            end,
        })

    return future
end

--- Mark the current branch's commit with a `head` ref (skipped when detached).
---@param repo Repo
function M.fetch_head(repo)
    local future, promise = make_future()

    vim.fn.jobstart(
        { "git", "symbolic-ref", "--short", "--quiet", "HEAD" },
        {
            stdout_buffered = true,
            on_stdout = function(_, lines)
                local name = lines[1]
                if name and name ~= "" then
                    repo.head = name
                    local localref = repo.refs[name]
                    if localref then
                        add_ref(repo, "HEAD", "head", localref.commit.hash)
                    end
                end
            end,
            on_exit = function()
                promise.resolve()
            end,
        })

    return future
end

--- Read the current ref set **without mutating the model** — the resync (§3.4)
--- needs the fresh refs to diff against `repo.refs` (added / removed / moved)
--- before applying changes. Resolves to `{ entries, head }`: `entries` is a list
--- of `{ name, kind, hash }` (annotated tags dereferenced like fetch_refs),
--- `head` the current branch name (nil when detached).
---@return Future
function M.fetch_ref_entries()
    local future, promise = make_future()
    local entries = {}

    vim.fn.jobstart(
        { "git", "for-each-ref", "--format=%(objectname) %(refname) %(*objectname)",
            "refs/heads", "refs/remotes", "refs/tags" },
        {
            stdout_buffered = true,
            on_stdout = function(_, lines)
                for _, line in ipairs(lines) do
                    if line ~= "" then
                        local parts = vim.split(line, " ")
                        local hash, refname, deref = parts[1], parts[2], parts[3]
                        local kind, name = classify_ref(refname or "")
                        if kind and name and hash then
                            local target = (deref and deref ~= "") and deref or hash
                            entries[#entries + 1] = { name = name, kind = kind, hash = target }
                        end
                    end
                end
            end,
            on_exit = function()
                -- Chain HEAD's symbolic-ref so the head binding can be reconciled
                -- in the same pass.
                local head = nil
                vim.fn.jobstart({ "git", "symbolic-ref", "--short", "--quiet", "HEAD" }, {
                    stdout_buffered = true,
                    on_stdout = function(_, l)
                        if l[1] and l[1] ~= "" then head = l[1] end
                    end,
                    on_exit = function()
                        promise.resolve({ entries = entries, head = head })
                    end,
                })
            end,
        })

    return future
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
    local command = { "git", "log", "--topo-order", "--parents", unpack(branch),
        "--pretty=format:" .. COMMIT_LOG_FMT }
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
            -- the loop, then continue.
            scheduled = true
            vim.schedule(process_batch)
        elseif stream_done then
            promise.resolve()
        end
    end

    local function schedule_drain()
        if not scheduled then
            scheduled = true
            vim.schedule(process_batch)
        end
    end

    local function enqueue(lines)
        for _, line in ipairs(lines) do
            qtail = qtail + 1
            queue[qtail] = line
        end
    end

    vim.fn.jobstart(
        command,
        {
            on_stdout = function(_, data)
                enqueue(linebuf.feed(data))
                if qhead <= qtail then
                    schedule_drain()
                end
            end,
            on_exit = function()
                local last = linebuf.flush()
                if last ~= "" then
                    enqueue({ last })
                end
                stream_done = true
                if qhead > qtail then
                    -- Nothing left to process — resolve now; otherwise the
                    -- worker resolves once it drains.
                    promise.resolve()
                else
                    schedule_drain()
                end
            end,
        })

    return future
end

--- Fetch the commits newly reachable since the last read — the resync's bounded
--- query (§3.4): `git log --parents <new tips> --not <old tips>` returns exactly
--- the commits reachable from the current ref tips but not from the previous
--- ones (usually a handful after a fetch / commit). Buffered (the set is small)
--- and resolves to a list of parsed `Commit`s; their already-present parents are
--- linked back into the model by the caller (`integrate_commit`). With no new
--- tips it resolves empty; with no old tips it omits `--not` (fetches all
--- reachable, the cold-start case the stream normally covers).
---@param new_tips string[]  current ref tip hashes (positive refs)
---@param old_tips string[]  previous ref tip hashes (negative refs)
---@return Future
function M.fetch_new_commits(new_tips, old_tips)
    local future, promise = make_future()
    if #new_tips == 0 then
        promise.resolve({})
        return future
    end

    local command = { "git", "log", "--parents", "--pretty=format:" .. COMMIT_LOG_FMT }
    for _, h in ipairs(new_tips) do command[#command + 1] = h end
    if #old_tips > 0 then
        command[#command + 1] = "--not"
        for _, h in ipairs(old_tips) do command[#command + 1] = h end
    end

    local commits = {}
    vim.fn.jobstart(command, {
        stdout_buffered = true,
        on_stdout = function(_, lines)
            for _, line in ipairs(lines) do
                if line ~= "" then
                    local c = parse_commit_line(line)
                    if c then commits[#commits + 1] = c end
                end
            end
        end,
        on_exit = function()
            promise.resolve(commits)
        end,
    })

    return future
end

--- Ask git for an exact commit order — the `rev`-based sort modes (spec §3.1).
--- `git rev-list <flag> <refspec>` lists hashes newest-first in git's chosen
--- order (same convention as the row order). Buffered; resolves to the hash list.
---@param branch string[]  the refspec (e.g. { "--all" } or branch names)
---@param flag string      the order flag (`--topo-order` / `--date-order` / …)
---@return Future
function M.fetch_rev_order(branch, flag)
    local future, promise = make_future()
    local command = { "git", "rev-list", flag, unpack(branch) }
    local hashes = {}
    vim.fn.jobstart(command, {
        stdout_buffered = true,
        on_stdout = function(_, lines)
            for _, line in ipairs(lines) do
                if line ~= "" then hashes[#hashes + 1] = line end
            end
        end,
        on_exit = function()
            promise.resolve(hashes)
        end,
    })
    return future
end

--- Run a git command and resolve the future with its stdout as a list of
--- non-empty lines. A small sibling of fetch_commit_diff for the short
--- working-tree queries (§3.3); runs in Neovim's cwd like the rest.
---@param args string[]
---@return Future
local function git_lines(args)
    local future, promise = make_future()
    local out = {}
    vim.fn.jobstart(vim.list_extend({ "git" }, args), {
        stdout_buffered = true,
        on_stdout = function(_, lines)
            for _, l in ipairs(lines) do
                if l ~= "" then out[#out + 1] = l end
            end
        end,
        on_exit = function() promise.resolve(out) end,
    })
    return future
end

--- Run a git command and resolve the future with its full stdout as one string
--- (the patch). Used for the working-tree diffs (§3.3); mirrors
--- fetch_commit_diff but for an arbitrary git argv.
---@param args string[]
---@return Future
local function git_string(args)
    local future, promise = make_future()
    local out = {}
    vim.fn.jobstart(vim.list_extend({ "git" }, args), {
        stdout_buffered = true,
        on_stdout = function(_, lines)
            for _, l in ipairs(lines) do out[#out + 1] = l end
        end,
        on_exit = function() promise.resolve(table.concat(out, "\n")) end,
    })
    return future
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
            -- collect stdout regardless (on_exit ignores the code).
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
    local future, promise = make_future()
    local out = {}

    vim.fn.jobstart(
        { "git", "show", "-s", "--date=iso",
            "--format=%H%x1f%an%x1f%ae%x1f%ad%x1f%cn%x1f%ce%x1f%cd%x1f%P%x1f%B", hash },
        {
            stdout_buffered = true,
            on_stdout = function(_, lines)
                for _, l in ipairs(lines) do
                    out[#out + 1] = l
                end
            end,
            on_exit = function()
                promise.resolve(table.concat(out, "\n"))
            end,
        })

    return future
end

--- Fetch a commit's diff via `git show --format= -p` (specification.md §11.3).
--- Buffered; resolves the raw patch string. On-demand only, chained after
--- fetch_commit_detail by the commit view.
---@param hash string
function M.fetch_commit_diff(hash)
    local future, promise = make_future()
    local out = {}

    vim.fn.jobstart(
        { "git", "show", "--format=", "-p", hash },
        {
            stdout_buffered = true,
            on_stdout = function(_, lines)
                for _, l in ipairs(lines) do
                    out[#out + 1] = l
                end
            end,
            on_exit = function()
                promise.resolve(table.concat(out, "\n"))
            end,
        })

    return future
end

--- Fetch the **combined** patch for a `DiffRange` (spec §13.5): `git diff
--- <base> <to>`, where `base` is the range's `from` (its older end's first
--- parent) or the empty tree for a root. Buffered; resolves the patch as a
--- single string. Used by the range commit view; mirrors fetch_commit_diff.
---@param range_arg DiffRange
function M.fetch_range_diff(range_arg)
    local future, promise = make_future()
    local out = {}
    local base = (range_arg.from and range_arg.from.hash) or EMPTY_TREE

    vim.fn.jobstart(
        { "git", "diff", base, range_arg.to.hash },
        {
            stdout_buffered = true,
            on_stdout = function(_, lines)
                for _, l in ipairs(lines) do
                    out[#out + 1] = l
                end
            end,
            on_exit = function()
                promise.resolve(table.concat(out, "\n"))
            end,
        })

    return future
end

--- Run a git command and resolve `{ code, out }` (stdout joined with newlines).
--- A thin future over `jobstart` for the submodule change view (§11.7). The
--- submodule is addressed with `git -C <path>` by the caller rather than
--- jobstart's `cwd`, so a missing checkout fails the command (nonzero exit)
--- instead of throwing on an invalid working directory. Resolves `{ code = -1 }`
--- if the job cannot be spawned.
---@param args string[]
---@return table  -- future resolving { code: integer, out: string }
local function git_code(args)
    local future, promise = make_future()
    local out = {}
    local ok, jid = pcall(vim.fn.jobstart, args, {
        stdout_buffered = true,
        on_stdout = function(_, lines)
            for _, l in ipairs(lines) do out[#out + 1] = l end
        end,
        on_exit = function(_, code)
            promise.resolve({ code = code, out = table.concat(out, "\n") })
        end,
    })
    if not ok or jid <= 0 then
        vim.schedule(function() promise.resolve({ code = -1, out = "" }) end)
    end
    return future
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
    -- `git -C <submodule path> …` (path is relative to Neovim's cwd, where the
    -- job runs), so an absent checkout simply errors rather than throwing.
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
