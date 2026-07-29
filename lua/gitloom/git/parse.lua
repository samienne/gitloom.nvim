--- git output parsers — turning raw `git log` / `git show` / `git diff` /
--- `git status` text into structured data. Pure (no I/O); the fetch layer feeds
--- these. Part of the gitloom.git data library.

local date = require("gitloom.git.date")

local M = {}

--- Parse one `git log` line. Fields are `%x1f`-separated:
--- hash, parent hashes, author, author epoch (%at), iso date (%ai), committer
--- epoch (%ct), subject. The committer epoch (`cepoch`) is what `order_commits`
--- seeds tips by, to match git's `--topo-order` (which orders by committer date;
--- §3.1). Refs are NOT here — they come from `fetch_refs` (§3.2); a fresh commit
--- starts with an empty refs list.
function M.parse_commit_line(line)
    local fields = vim.split(line, "\x1f")

    local hash = fields[1]
    local parents = vim.split(fields[2] or "", " ")
    local author = fields[3]
    local d = date.parse_timestamp(fields[4], fields[5])
    local cepoch = tonumber(fields[6])
    local subject = fields[7]

    if not hash then
        return
    end

    local new_parents = {}
    for _, p in ipairs(parents) do
        if p ~= "" then
            table.insert(new_parents, p)
        end
    end

    return {
        hash = hash,
        parents = new_parents,
        children = {},
        author = author,
        date = d,
        cepoch = cepoch,
        message = subject,
        loaded = true,
        refs = {},
    }
end

--- Stateful line de-chunker for an **unbuffered** `jobstart` stdout stream.
--- Neovim delivers stdout as lists of strings split on "\n": the first element
--- continues the previous chunk's trailing (partial) line, and the last element
--- is itself partial — continued in the next chunk (`:help channel-lines`).
--- `feed(data)` returns the complete lines contained in this chunk; `flush()`
--- returns the final held line at EOF (git's last line has no trailing newline).
--- Pure (no I/O) so it is unit-testable via `_internal`.
---@class LineBuffer
---@field feed fun(data: string[]): string[]
---@field flush fun(): string

---@return LineBuffer
function M.make_line_buffer()
    local pending = ""
    return {
        feed = function(data)
            local out = {}
            if #data == 0 then
                return out
            end
            -- Stitch the held partial onto this chunk's first element; hold the
            -- new trailing partial back for the next chunk.
            data[1] = pending .. data[1]
            pending = data[#data]
            for i = 1, #data - 1 do
                out[#out + 1] = data[i]
            end
            return out
        end,
        flush = function()
            local last = pending
            pending = ""
            return last
        end,
    }
end

--- Parse the `fetch_commit_detail` output into a CommitDetail. Fields are
--- `%x1f`-separated; the body (`%B`) is last so its embedded newlines stay in
--- the final field. Pure; exposed for testing.
---@class CommitDetail
---@field hash string
---@field author_name string
---@field author_email string
---@field author_date string
---@field committer_name string
---@field committer_email string
---@field committer_date string
---@field parents string[]   parent hashes
---@field body string        full message (subject + body), trailing space trimmed
---@param output string?
---@return CommitDetail
function M.parse_show(output)
    local fields = vim.split(output or "", "\x1f")
    local parents = {}
    for _, p in ipairs(vim.split(fields[8] or "", " ")) do
        if p ~= "" then
            parents[#parents + 1] = p
        end
    end
    return {
        hash = fields[1] or "",
        author_name = fields[2] or "",
        author_email = fields[3] or "",
        author_date = fields[4] or "",
        committer_name = fields[5] or "",
        committer_email = fields[6] or "",
        committer_date = fields[7] or "",
        parents = parents,
        body = (fields[9] or ""):gsub("%s+$", ""),
    }
end

-- Line prefixes that mark a diff's file-header lines (checked before +/- so the
-- "+++"/"---" file markers don't read as added/removed content).
local DIFF_HEADER_PREFIXES = {
    "diff --git", "index ", "--- ", "+++ ", "old mode", "new mode",
    "deleted file", "new file", "similarity index", "dissimilarity index",
    "rename ", "copy ", "Binary files",
}

--- Classify one patch line by role: "header", "hunk", "add", "delete", or nil
--- (a context line). Pure.
---@param line string
---@return string|nil
function M.diff_line_role(line)
    for _, p in ipairs(DIFF_HEADER_PREFIXES) do
        if line:sub(1, #p) == p then
            return "header"
        end
    end
    if line:sub(1, 2) == "@@" then
        return "hunk"
    end
    local c = line:sub(1, 1)
    if c == "+" then
        return "add"
    elseif c == "-" then
        return "delete"
    end
    return nil
end

--- Parse a patch into a per-file diffstat (specification.md §11.4). Each entry
--- carries the display path, insertion/deletion counts, a binary flag, and
--- `start` — the 1-based index (into the patch's split lines) of that file's
--- `diff --git` line, used as the jump target. Renames (a/ != b/) show as
--- "old => new". Pure; exposed for testing.
---@param patch string?
---@return { path: string, added: integer, removed: integer, binary: boolean, start: integer }[]
function M.diffstat_files(patch)
    local files = {}
    local cur = nil
    for i, line in ipairs(vim.split(patch or "", "\n")) do
        local a, b = line:match("^diff %-%-git a/(.-) b/(.+)$")
        if a then
            cur = { a = a, b = b, added = 0, removed = 0, binary = false, start = i }
            files[#files + 1] = cur
        elseif cur then
            if line:sub(1, 13) == "Binary files " then
                cur.binary = true
            elseif line:sub(1, 3) ~= "+++" and line:sub(1, 1) == "+" then
                cur.added = cur.added + 1
            elseif line:sub(1, 3) ~= "---" and line:sub(1, 1) == "-" then
                cur.removed = cur.removed + 1
            end
        end
    end
    for _, f in ipairs(files) do
        f.path = (f.a ~= f.b) and (f.a .. " => " .. f.b) or f.b
        f.a, f.b = nil, nil
    end
    return files
end

--- Precompute the diff context-header data (specification.md §11.6): for each
--- 1-based line of the rendered patch, the **governing** file and hunk header —
--- the nearest `diff --git` and `@@ … @@` line at or above it — together with the
--- patch-line index where each begins. The window glue (`update_ctx`) compares
--- those begin-indices against the viewport's effective top to decide whether a
--- header has scrolled off and should stick. The file is shown as its display
--- path, with renames as "old => new" (matching the diffstat). A line before any
--- `diff --git` (or a hunk before its file's first `@@`) yields a nil field, so
--- the overlay simply omits it. Pure; exposed for testing.
---@param patch string?
---@return { file?: string, file_line?: integer, hunk?: string, hunk_line?: integer }[]
function M.diff_contexts(patch)
    local ctx = {}
    if not patch or patch == "" then return ctx end
    local file, file_line, hunk, hunk_line = nil, nil, nil, nil
    for i, line in ipairs(vim.split(patch or "", "\n")) do
        local a, b = line:match("^diff %-%-git a/(.-) b/(.+)$")
        if a then
            file = (a ~= b) and (a .. " => " .. b) or b
            file_line = i
            hunk, hunk_line = nil, nil
        elseif line:sub(1, 2) == "@@" then
            hunk = line
            hunk_line = i
        end
        ctx[i] = { file = file, file_line = file_line, hunk = hunk, hunk_line = hunk_line }
    end
    return ctx
end

--- Count the staged / unstaged / untracked files from `git status --porcelain`
--- output (spec §3.3). Each porcelain line is `XY <path>`: X is the index
--- (staged) status, Y the working-tree (unstaged) status; `??` is untracked.
--- The three counts seed the three working-tree virtual commits (§4.2). Pure;
--- exposed for testing.
---@param lines string[]
---@return { staged: integer, unstaged: integer, untracked: integer }
function M.parse_status(lines)
    local st = { staged = 0, unstaged = 0, untracked = 0 }
    for _, line in ipairs(lines or {}) do
        if #line >= 2 then
            if line:sub(1, 2) == "??" then
                st.untracked = st.untracked + 1
            else
                local x, y = line:sub(1, 1), line:sub(2, 2)
                if x ~= " " and x ~= "?" then st.staged = st.staged + 1 end
                if y ~= " " and y ~= "?" then st.unstaged = st.unstaged + 1 end
            end
        end
    end
    return st
end

--- Parse `git worktree list --porcelain` (spec §3.2). The porcelain form is
--- stanzas separated by a blank line, each opening with `worktree <path>` and
--- then carrying label-only or `label value` attributes:
---
---     worktree /repo            worktree /repo/wt/feature      worktree /repo/bare
---     HEAD <sha>                HEAD <sha>                     bare
---     branch refs/heads/master  detached
---
--- The **first** stanza is the main worktree; the rest are linked worktrees. A
--- bare stanza has no HEAD. `branch` and `detached` are mutually exclusive, so
--- `detached` is derived (a HEAD with no branch) rather than trusted on its own —
--- older git wrote the attribute inconsistently and the derivation is total.
--- `name` is the path's basename (the §4.1 label stem), taken from either
--- separator so a Windows path parses the same as a POSIX one. Pure; exposed for
--- testing.
---@param lines string[]
---@return { path: string, name: string, head: string?, branch: string?, detached: boolean, bare: boolean, main: boolean }[]
function M.parse_worktrees(lines)
    local out, cur = {}, nil
    local function flush()
        if cur then
            cur.detached = cur.head ~= nil and cur.branch == nil
            cur.main = #out == 0
            out[#out + 1] = cur
        end
        cur = nil
    end
    for _, line in ipairs(lines or {}) do
        local path = line:match("^worktree (.+)$")
        if path then
            flush()
            cur = { path = path, name = path:match("([^/\\]+)$") or path, bare = false }
        elseif cur then
            local head = line:match("^HEAD (%x+)$")
            local branch = line:match("^branch (.+)$")
            if head then
                cur.head = head
            elseif branch then
                cur.branch = branch
            elseif line == "bare" then
                cur.bare = true
            end
        end
    end
    flush()
    return out
end

return M
