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
---@field match? boolean       the upstream names the branch's own name (§6.3); false = it does not
---@field same? string[]       a non-matching upstream: the remotes holding a same-named branch

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
        ahead = up.ahead or 0, behind = up.behind or 0, match = up.match, same = up.same }
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

--- The labels of a remote branch's checkout when its local counterpart tracks it
--- from another commit (§10.4.1): `Checkout foo and fast-forward to origin/foo`
--- (strictly behind) / `Checkout foo and reset to origin/foo…` (ahead / diverged).
---@param t SyncTarget
---@return string ff, string reset
function M.checkout_labels(t)
    return ("Checkout %s and fast-forward to %s"):format(t.branch, t.upstream),
        ("Checkout %s and reset to %s…"):format(t.branch, t.upstream)
end

--- What those entries run when the branch is NOT the current one (the probe
--- decides; the current branch takes `ff_command` / `reset_command` instead,
--- §10.4.1). Fast-forward: `ff_command(t, false)` (`git fetch . <up>:refs/heads/<b>`,
--- no `+`), then `git switch <b>`. Reset: `git switch -C <b> <upstream ref>` —
--- reset and switch in one atomic step; it carries uncommitted changes or git
--- refuses, and git refuses a branch checked out in another worktree. Run in
--- order, stopping at the first failure (`fetch.run_steps`). Pure.
---@param t SyncTarget
---@param reset boolean
---@return SyncCommand[]
function M.checkout_commands(t, reset)
    if reset then
        return { { argv = { "git", "switch", "-C", t.branch, t.upstream_ref }, label = "git switch -C" } }
    end
    return { M.ff_command(t, false), { argv = { "git", "switch", t.branch }, label = "git switch" } }
end

--- The note the follow-HEAD notice appends after such a checkout (§10.4.1):
--- `fast-forwarded to origin/foo` / `reset to origin/foo, was abc1234`. Pure.
---@param t SyncTarget
---@param p SyncProbe  the probe taken before running
---@param reset boolean
---@return string
function M.checkout_note(t, p, reset)
    if reset then return ("reset to %s, was %s"):format(t.upstream, (p.tip or "?"):sub(1, 7)) end
    return ("fast-forwarded to %s"):format(t.upstream)
end

---@param n integer
---@param word string
---@return string
local function plural(n, word)
    return ("%d %s%s"):format(n, word, n == 1 and "" or "s")
end

--- The reset confirmation's lines (§17.2) from the fresh probe: the question,
--- then what is lost — the local commits (when ahead), the uncommitted changes
--- (the current branch only, when dirty) — then, for a non-matching upstream
--- (§6.3), that it is not the branch's same-named one, and last where the old
--- tip stays reachable (only when something is lost). Nothing lost and a
--- matching upstream ⇒ the question alone. `switching` — the §10.4.1 checkout and
--- reset of a branch that is not the current one — asks `Check out <b> and reset
--- it to <upstream> (<short>)?` instead (its uncommitted changes are carried over
--- by `git switch -C`, or git refuses: never a loss). Pure.
---@param t SyncTarget
---@param p SyncProbe
---@param switching boolean?
---@return string[]
function M.reset_prompt(t, p, switching)
    local q = switching and "Check out %s and reset it to %s (%s)?" or "Reset %s to %s (%s)?"
    local lines = { q:format(t.branch, t.upstream, (p.up_tip or "?"):sub(1, 7)) }
    local current = p.head_branch == t.branch
    if (p.ahead or 0) > 0 then
        lines[#lines + 1] = ("discards %s"):format(plural(p.ahead, "local commit"))
    end
    if current and (p.dirty or 0) > 0 then
        lines[#lines + 1] = ("discards uncommitted changes to %s"):format(plural(p.dirty, "file"))
    end
    local lost = #lines > 1
    -- A differently named upstream is the likeliest wrong reset target (§17.2):
    -- say so even when nothing is lost, pointing at the Track entry if any.
    if t.match == false then
        local line = ("%s is not %s's same-named branch"):format(t.upstream, t.branch)
        local r = t.same and t.same[1]
        if r then
            local other = r .. "/" .. t.branch
            line = ("%s (%s exists — see Track %s)"):format(line, other, other)
        end
        lines[#lines + 1] = line
    end
    if lost then
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

-- ── Upstream: Track / Set upstream… / Unset upstream (§17.2) ─────────────────

---@class UpstreamChoice  a remote-tracking branch offered as an upstream (§17.2)
---@field name string      its short name (`origin/foo`)
---@field ref string       its full refname (`refs/remotes/origin/foo`) — what runs
---@field current boolean  it is the branch's upstream now (choosing it runs nothing)
---@field same boolean     it is the branch's own name on its remote
---@field remote? string   its remote (only while `upstream_offers` sorts)

---@class UpstreamTarget  the local branch whose tracking the upstream entries change
---@field branch string        the local branch (`foo`)
---@field upstream? Upstream   its tracking now (nil: none) — the done-notice names it
---@field only? string         the remote-branch exception (§17.2): the selected `origin/foo`,
---                            the one Track offered
---@field choices? UpstreamChoice[]  the Set picker's items (`upstream_offers`)

---@class UpstreamOffers
---@field track UpstreamChoice[]    the Track entries, in `git remote` order
---@field first boolean             the label warns (§6.3 mismatch): Track goes before the sync entries
---@field choices UpstreamChoice[]  Set upstream…'s picker: same-named first, then by name
---@field unset boolean             the branch has an upstream (`gone` included)

--- The branch the upstream entries act on (§17.2) — the sync's choice: a
--- selected **local** branch, tracking or not; a selected remote branch
--- `origin/foo` whose local `foo` sits elsewhere (`ref.counterpart`, §10.4.1)
--- offers `foo`'s, with `only` = `origin/foo`. nil otherwise. Pure.
---@param ref SelectedRef?
---@return UpstreamTarget?
function M.upstream_target(ref)
    if not ref then return nil end
    if ref.kind == "local" then return { branch = ref.name, upstream = ref.upstream } end
    local cp = ref.kind == "remote" and ref.counterpart or nil
    if cp and cp.kind == "local" then return { branch = cp.name, upstream = cp.upstream, only = ref.name } end
    return nil
end

--- The remote a remote-tracking branch's short name belongs to: the longest
--- known remote it starts with, else its first component. Pure.
---@param name string
---@param remotes string[]?
---@return string? remote, string? branch
local function split_remote(name, remotes)
    local best
    for _, r in ipairs(remotes or {}) do
        if name:sub(1, #r + 1) == r .. "/" and (not best or #r > #best) then best = r end
    end
    if best then return best, name:sub(#best + 2) end
    return name:match("^([^/]+)/(.+)$")
end

--- Which upstream entries a target gets (§17.2), from the cached refs and
--- remotes only (no git spawn). `refs` is the repo's name → Ref registry; its
--- remote-tracking branches (never a remote's `HEAD` symref) are the Set
--- picker's items and the Track candidates. Track: the upstream does not match
--- (§6.3) or there is none, one per remote holding `<r>/<branch>`, in `remotes`
--- order (remotes not in the list after, by name); in the remote-branch
--- exception only the selected one. Pure.
---@param t UpstreamTarget?
---@param refs table<string, Ref>?
---@param remotes string[]?
---@return UpstreamOffers
function M.upstream_offers(t, refs, remotes)
    local out = { track = {}, first = false, choices = {}, unset = false }
    if not t then return out end
    local up = t.upstream
    local rank = {}
    for i, r in ipairs(remotes or {}) do rank[r] = i end
    local current = up and up.ref
    for name, ref in pairs(refs or {}) do
        if ref.kind == "remote" and not name:match("/HEAD$") then
            local r, b = split_remote(name, remotes)
            local full = "refs/remotes/" .. name
            out.choices[#out.choices + 1] = { name = name, ref = full, current = full == current,
                same = b == t.branch, remote = r }
        end
    end
    table.sort(out.choices, function(a, b)
        if a.same ~= b.same then return a.same end
        return a.name < b.name
    end)
    if not (up and up.match) then
        for _, c in ipairs(out.choices) do
            if c.same and (not t.only or c.name == t.only) then out.track[#out.track + 1] = c end
        end
        table.sort(out.track, function(a, b)
            local ra, rb = rank[a.remote] or math.huge, rank[b.remote] or math.huge
            if ra ~= rb then return ra < rb end
            return a.name < b.name
        end)
    end
    for _, c in ipairs(out.choices) do c.remote = nil end
    out.first = #out.track > 0 and up ~= nil and up.same ~= nil and #up.same > 0
    out.unset = up ~= nil
    return out
end

--- The palette labels (§17.2). Pure.
---@param t UpstreamTarget
---@param c? UpstreamChoice  Track's branch
---@return string track, string set, string unset
function M.upstream_labels(t, c)
    return ("Track %s"):format(c and c.name or "?"), ("Set upstream of %s…"):format(t.branch),
        ("Unset upstream of %s"):format(t.branch)
end

--- A Set picker item's text: the branch, `(current)` on the upstream now. Pure.
---@param c UpstreamChoice
---@return string
function M.upstream_choice_label(c)
    return c.current and (c.name .. " (current)") or c.name
end

--- What Track / Set run (§17.2): `git branch --set-upstream-to=<full ref> <b>` —
--- only `branch.<b>.remote` / `merge` change. Pure.
---@param branch string
---@param full string
---@return SyncCommand
function M.set_upstream_command(branch, full)
    return { argv = { "git", "branch", "--set-upstream-to=" .. full, branch },
        label = "git branch --set-upstream-to" }
end

--- What Unset runs (§17.2): `git branch --unset-upstream <b>`. Pure.
---@param branch string
---@return SyncCommand
function M.unset_upstream_command(branch)
    return { argv = { "git", "branch", "--unset-upstream", branch }, label = "git branch --unset-upstream" }
end

--- The success notices (§17.2), naming the previous upstream so the change is
--- one palette step to undo: `foo now tracks origin/foo (was origin/dev)` /
--- `(had no upstream)`, and `foo no longer tracks origin/dev`. Pure.
---@param branch string
---@param name string      the new upstream's short name
---@param prev Upstream?   the upstream before
---@return string
function M.set_upstream_done(branch, name, prev)
    local was = prev and ("was " .. prev.short) or "had no upstream"
    return ("gitloom: %s now tracks %s (%s)"):format(branch, name, was)
end

---@param branch string
---@param prev Upstream?
---@return string
function M.unset_upstream_done(branch, prev)
    return ("gitloom: %s no longer tracks %s"):format(branch, prev and prev.short or "anything")
end

return M
