--- gitloom.git.sync — the branch sync (spec §17.2): fast-forward a local branch
--- to its upstream, or reset it to its upstream. The pure decisions.
---
--- Which entries a selected branch gets (from the tracking counts cached with
--- the refs, §6.3 — no git spawn), the argv per case (the current branch vs any
--- other), the reset confirmation's text, the stale-state check run right before
--- a reset, and the notices. No I/O: `fetch.sync_probe` reads the fresh state,
--- `fetch.run_checkout` runs the argv, window.lua's `branch_sync` helper prompts,
--- notifies and resyncs. Nothing here ever forces, fetches from a remote, merges,
--- rebases or commits.

local M = {}

---@class SyncTarget  a local branch tracking an upstream, as the palette saw it (§17.2)
---@field branch string        the local branch (`main`)
---@field upstream string      the upstream's short name (`origin/main`)
---@field upstream_ref string  its full refname (`refs/remotes/origin/main`)
---@field ahead integer        the cached counts (§6.3) — decide visibility only
---@field behind integer

---@class SyncProbe  the repository read afresh (`fetch.sync_probe`)
---@field tip? string          the branch's commit (nil: the branch is gone)
---@field up_tip? string       the upstream's commit (nil: the upstream is gone)
---@field head_branch? string  the branch HEAD is attached to; nil when detached
---@field ahead? integer       `<upstream>..<branch>` — commits a reset discards
---@field behind? integer
---@field dirty? integer       the current branch only: changed tracked paths (each once)
---@field err? table           a failed read's `{ code, out, err }`

---@class SyncCommand
---@field argv string[]  the git command (never forcing)
---@field label string   the command, for an error line (`git merge --ff-only`)

--- The sync target a selected ref names (§17.2): a **local** branch with an
--- upstream that is not `gone` and whose full refname is known. nil otherwise —
--- a remote branch, a tag, a worktree label, no upstream. Pure.
---@param ref SelectedRef?
---@return SyncTarget?
function M.sync_target(ref)
    if not ref or ref.kind ~= "local" then return nil end
    local up = ref.upstream
    if not up or up.gone or not up.ref or up.ref == "" then return nil end
    return { branch = ref.name, upstream = up.short, upstream_ref = up.ref,
        ahead = up.ahead or 0, behind = up.behind or 0 }
end

--- Which sync entries a target gets (§17.2), from its cached counts alone:
--- fast-forward when strictly behind, reset when behind, ahead or diverged.
--- Both false in sync (and for no target). Pure.
---@param t SyncTarget?
---@return { ff: boolean, reset: boolean }
function M.sync_offers(t)
    if not t then return { ff = false, reset = false } end
    return { ff = t.behind > 0 and t.ahead == 0, reset = t.behind > 0 or t.ahead > 0 }
end

--- The palette labels (§17.2).
---@param t SyncTarget
---@return string ff, string reset
function M.sync_labels(t)
    return ("Fast-forward %s to %s"):format(t.branch, t.upstream),
        ("Reset %s to %s…"):format(t.branch, t.upstream)
end

--- What a fast-forward runs (§17.2). `current` — the branch is the one HEAD is
--- attached to, read afresh by the probe (never the cached decoration: a stale
--- "current" would move whatever branch HEAD is on now). The current branch:
--- `git merge --ff-only <upstream ref>` (git refuses to overwrite uncommitted
--- changes); any other: `git fetch . <upstream ref>:refs/heads/<b>` — no `+`, so
--- git refuses a non-fast-forward, and refuses a branch checked out in another
--- worktree. Pure.
---@param t SyncTarget
---@param current boolean
---@return SyncCommand
function M.ff_command(t, current)
    if current then
        return { argv = { "git", "merge", "--ff-only", t.upstream_ref }, label = "git merge --ff-only" }
    end
    return { argv = { "git", "fetch", "--no-recurse-submodules", ".",
        t.upstream_ref .. ":refs/heads/" .. t.branch }, label = "git fetch ." }
end

--- What a reset runs (§17.2). The current branch: `git reset --hard <upstream
--- ref>` (untracked files untouched); any other: `git branch -f <b> <upstream
--- ref>` (git refuses it for a branch checked out in another worktree). Pure.
---@param t SyncTarget
---@param current boolean
---@return SyncCommand
function M.reset_command(t, current)
    if current then
        return { argv = { "git", "reset", "--hard", t.upstream_ref }, label = "git reset --hard" }
    end
    return { argv = { "git", "branch", "-f", t.branch, t.upstream_ref }, label = "git branch -f" }
end

---@param n integer
---@param word string
---@return string
local function plural(n, word)
    return ("%d %s%s"):format(n, word, n == 1 and "" or "s")
end

--- The reset confirmation's lines (§17.2) from the fresh probe: the question,
--- then what is lost — the local commits (when ahead), the uncommitted changes
--- (the current branch only, when dirty) and where the old tip stays reachable.
--- Nothing lost ⇒ the question alone. Pure.
---@param t SyncTarget
---@param p SyncProbe
---@return string[]
function M.reset_prompt(t, p)
    local lines = { ("Reset %s to %s (%s)?"):format(t.branch, t.upstream, (p.up_tip or "?"):sub(1, 7)) }
    local current = p.head_branch == t.branch
    if (p.ahead or 0) > 0 then
        lines[#lines + 1] = ("discards %s"):format(plural(p.ahead, "local commit"))
    end
    if current and (p.dirty or 0) > 0 then
        lines[#lines + 1] = ("discards uncommitted changes to %s"):format(plural(p.dirty, "file"))
    end
    if #lines > 1 then
        lines[#lines + 1] = ("the old tip %s stays reachable in the reflog"):format((p.tip or "?"):sub(1, 7))
    end
    return lines
end

--- The prompt lines as the one string a `vim.ui.select` prompt takes: the
--- question, then the losses after it separated by `; `. Pure.
---@param lines string[]
---@return string
function M.prompt_text(lines)
    if #lines <= 1 then return lines[1] or "" end
    return lines[1] .. " " .. table.concat(lines, "; ", 2)
end

--- Why a reset must not run (§17.2): the state re-read right before running
--- (`after`) differs from what the prompt showed (`before`) — the branch tip,
--- the upstream tip, which branch is current, or the dirty count — or the
--- re-read failed. nil when it may run. Pure.
---@param t SyncTarget
---@param before SyncProbe
---@param after SyncProbe
---@return string?
function M.sync_stale(t, before, after)
    local what
    if after.err then
        what = "the repository could not be read"
    elseif after.tip ~= before.tip then
        what = t.branch .. " moved"
    elseif after.up_tip ~= before.up_tip then
        what = t.upstream .. " moved"
    elseif (after.head_branch == t.branch) ~= (before.head_branch == t.branch) then
        what = "HEAD moved"
    elseif (after.dirty or 0) ~= (before.dirty or 0) then
        what = "the working tree changed"
    end
    return what and ("gitloom: reset of %s cancelled — %s since the prompt"):format(t.branch, what) or nil
end

--- Why a sync cannot start from the fresh probe (§17.2): the branch or its
--- upstream no longer resolves. nil when it can. Pure.
---@param t SyncTarget
---@param p SyncProbe
---@return string?
function M.sync_unavailable(t, p)
    if not p.tip then return ("gitloom: %s no longer exists"):format(t.branch) end
    if not p.up_tip then return ("gitloom: %s no longer exists"):format(t.upstream) end
    return nil
end

--- The success notices (§17.2): `main → origin/main (abc1234)` after a
--- fast-forward, `main reset to origin/main — was abc1234` after a reset. Pure.
---@param t SyncTarget
---@param p SyncProbe  the probe taken before running
---@return string
function M.ff_done(t, p)
    return ("gitloom: %s → %s (%s)"):format(t.branch, t.upstream, (p.up_tip or "?"):sub(1, 7))
end

---@param t SyncTarget
---@param p SyncProbe
---@return string
function M.reset_done(t, p)
    return ("gitloom: %s reset to %s — was %s"):format(t.branch, t.upstream, (p.tip or "?"):sub(1, 7))
end

return M
