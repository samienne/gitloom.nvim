--- gitloom.git.examine — Checkout & examine (spec §10.4.2): the pure decisions.
---
--- What an examine runs (the plan, from the selection's ends, the dirty counts,
--- HEAD and any examine already active), the stash message, what Return runs, and
--- finding a stash by SHA. No I/O: `fetch.examine_probe` / `examine_run` /
--- `examine_return` run the plans, window.lua's `examine` helpers prompt, notify,
--- open the provider and keep the per-repository state.

local range = require("gitloom.git.range")

local M = {}

---@class ExamineHead
---@field branch? string   the branch HEAD is on; nil when detached
---@field hash string      HEAD's commit

---@class ExamineState
---@field orig string            the branch to return to, or a hash when `detached`
---@field detached boolean       `orig` is a hash (HEAD was detached when the examine began)
---@field stash? string          the examine's stash commit SHA; nil for a clean tree
---@field stash_message? string  that stash's message, for the "stash kept" notice
---@field examined string        the commit checked out now

---@class ExamineStash
---@field argv string[]    `git stash push -u -m <message>`
---@field message string
---@field count integer    the changes it stashes (the prompt's N)

---@class ExaminePlan
---@field kind "open"|"checkout"|"refuse"
---@field range? DiffRange       open / checkout: the single-rev range to open (§10.4.2)
---@field reason? string         refuse: the notice
---@field checkout? string[]     checkout: `git checkout --detach <newer>`
---@field stash? ExamineStash    checkout: stash first (asks the user)
---@field state? ExamineState    checkout: the state to record on success (`stash`
---                              is filled in by the runner once the push lands)

--- The number of changes a `parse_status` result holds — the prompt's N: the
--- changed PATHS, each counted once (`st.paths`), never the per-state sum, which
--- counts a staged + unstaged file twice. The sum is only the fallback for a
--- status table without `paths`.
---@param st { staged?: integer, unstaged?: integer, untracked?: integer, paths?: integer }?
---@return integer
function M.dirty_count(st)
    st = st or {}
    if st.paths then return st.paths end
    return (st.staged or 0) + (st.unstaged or 0) + (st.untracked or 0)
end

--- The message an examine's stash carries (§10.4.2):
--- `gitloom: examine <short> (from <branch or short hash>)`. Pure.
---@param examined string   the hash being examined
---@param head ExamineHead
---@return string
function M.examine_stash_message(examined, head)
    return ("gitloom: examine %s (from %s)"):format(examined:sub(1, 7),
        head.branch or head.hash:sub(1, 7))
end

--- Whether examining with `newer` as the newer end needs a checkout (§10.4.2):
--- not for a §4.2 working-tree node, nor for HEAD's own commit (`head_hash`,
--- attached or detached) — the working tree already is the newer end, so the
--- palette offers **Examine** rather than Checkout & examine. Pure.
---@param newer Commit?
---@param head_hash string?  HEAD's commit (nil when unknown)
---@return boolean
function M.needs_checkout(newer, head_hash)
    if not newer or newer.virtual then return false end
    return not (head_hash ~= nil and newer.hash == head_hash)
end

--- What Checkout & examine of `newer`..`older` does (§10.4.2). `p.newer` /
--- `p.older` are the selection's real ends (the same commit for one commit);
--- `p.status` the `parse_status` counts; `p.head` HEAD now; `p.state` the
--- examine already active in this repository, if any; `p.root` the repository.
---
---  * the newer end is a §4.2 working-tree node → `open` its existing
---    working-tree range: nothing to check out;
---  * the newer end is HEAD's commit (`p.head.hash`) → `open`
---    `range.examine_range` (Examine): no checkout, no stash, no state — a dirty
---    tree is examined as it is and an active examine is left untouched;
---  * an examine is active and the tree is dirty → `refuse` (Return first — never
---    a second stash, so never a chain);
---  * otherwise `checkout --detach <newer>`, stashing first when dirty (and no
---    examine is active), then open `range.examine_range`. An active examine's
---    `orig` and stash are kept; only `examined` moves. Pure.
---@param p { newer: Commit, older: Commit, status?: table, head?: ExamineHead, state?: ExamineState, root?: string }
---@return ExaminePlan
function M.examine_plan(p)
    local newer, older = p.newer, p.older
    if newer.virtual then
        return { kind = "open", range = range.range_endpoints(newer, older, p.root) }
    end
    if not M.needs_checkout(newer, p.head and p.head.hash) then
        return { kind = "open", range = range.examine_range(newer, older, p.root) }
    end
    local n = M.dirty_count(p.status)
    local st = p.state
    if st and n > 0 then
        return { kind = "refuse", reason = ("gitloom: an examine is active and the working tree has "
            .. "%d change%s — %s first"):format(n, n == 1 and "" or "s", M.return_plan(st).label) }
    end
    local state
    if st then
        state = { orig = st.orig, detached = st.detached, stash = st.stash,
            stash_message = st.stash_message, examined = newer.hash }
    else
        local head = p.head
        if not head then return { kind = "refuse", reason = "gitloom: cannot read HEAD" } end
        state = { orig = head.branch or head.hash, detached = head.branch == nil,
            examined = newer.hash }
    end
    local stash
    if not st and n > 0 then
        local msg = M.examine_stash_message(newer.hash, p.head --[[@as ExamineHead]])
        stash = { argv = { "git", "stash", "push", "-u", "-m", msg }, message = msg, count = n }
        state.stash_message = msg
    end
    return { kind = "checkout", checkout = { "git", "checkout", "--detach", newer.hash },
        stash = stash, state = state, range = range.examine_range(newer, older, p.root) }
end

---@class ReturnPlan
---@field label string       the palette entry: `Return to <orig>`
---@field switch string[]    `git switch <branch>`, or `git checkout --detach <hash>`
---@field apply? string[]    `git stash apply --index <sha>` when a stash was recorded
---@field apply_plain? string[]  `git stash apply <sha>` — the fallback when git refuses `--index`
---@field stash? string      that stash's SHA
---@field stash_message? string

--- What Return (§10.4.2) runs for an examine `state`. Pure.
---@param state ExamineState
---@return ReturnPlan
function M.return_plan(state)
    local name = state.detached and state.orig:sub(1, 7) or state.orig
    return {
        label = "Return to " .. name,
        switch = state.detached and { "git", "checkout", "--detach", state.orig }
            or { "git", "switch", state.orig },
        apply = state.stash and { "git", "stash", "apply", "--index", state.stash } or nil,
        apply_plain = state.stash and { "git", "stash", "apply", state.stash } or nil,
        stash = state.stash,
        stash_message = state.stash_message,
    }
end

--- Whether a failed `git stash apply --index` (§10.4.2) was git refusing to
--- restore the INDEX — "conflicts in index. Try without --index." (capitalised by
--- older git). git checks the staged patch with `git apply --cached`, atomically,
--- before it touches the index, the working tree or the untracked files, so that
--- refusal — and only that one — leaves everything as it was and licenses the
--- plain `git stash apply` fallback. The caller runs the `--index` apply under
--- `LC_ALL=C` so the message is git's untranslated one. Pure.
---@param res { code: integer, out: string, err: string }?
---@return boolean
function M.index_refused(res)
    if not res or res.code == 0 or res.code == -1 then return false end
    local text = ((res.err or "") .. "\n" .. (res.out or "")):lower()
    return text:find("conflicts in index", 1, true) ~= nil
end

--- The current `stash@{n}` index of the stash whose commit is `sha`, from
--- `git stash list --format=%H` output; nil when it is not there. The stash is
--- shared by every worktree and session, so a position is only ever re-derived
--- from the SHA right before it is used. Pure.
---@param list_out string?
---@param sha string
---@return integer?
function M.stash_index(list_out, sha)
    local i = 0
    for line in (list_out or ""):gmatch("[^\r\n]+") do
        if line:match("^%s*(.-)%s*$") == sha then return i end
        i = i + 1
    end
    return nil
end

return M
