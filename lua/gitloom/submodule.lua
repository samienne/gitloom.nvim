--- Submodule change view (specification.md §11.7): the pure, git-agnostic core.
--- When a commit bumps a submodule pointer the diff shows only an opaque old/new
--- `Subproject commit <hash>` pair; this module's helpers let the commit view
--- replace that pair with a small change graph of the submodule's own history.
--- The git I/O (the gated, never-fetching queries), the layout, and the render
--- splice live in graph.lua; everything here is pure and unit-tested.
local M = {}

--- Scan a rendered unified diff for **submodule pointer changes**. git renders a
--- `160000`-mode (gitlink) change as a `diff --git` file whose hunk body is a
--- `-Subproject commit <old>` / `+Subproject commit <new>` pair. Returns one
--- entry per changed submodule with the file `path`, the `old`/`new` commit
--- hashes, and the 1-based indices (into the patch's `\n`-split lines) of the two
--- `Subproject` lines (`from_line`/`to_line` — the splice target) and the file's
--- `diff --git` line (`file_line`). A one-sided change (a submodule newly added
--- or removed, with only a `+`/`-` line) is **skipped**: there is no old↔new
--- relationship to visualize. Pure.
---@param patch string?
---@return { path: string, old: string, new: string, from_line: integer, to_line: integer, file_line: integer }[]
function M.parse_changes(patch)
    local out = {}
    local cur = nil
    for i, line in ipairs(vim.split(patch or "", "\n")) do
        local a, b = line:match("^diff %-%-git a/(.-) b/(.+)$")
        if a then
            -- A new file section: any half-seen submodule pair is abandoned.
            cur = { path = b, file_line = i }
        elseif cur then
            local old = line:match("^%-Subproject commit (%x+)")
            local new = line:match("^%+Subproject commit (%x+)")
            if old then
                cur.old, cur.from_line = old, i
            elseif new then
                cur.new, cur.to_line = new, i
                if cur.old then
                    out[#out + 1] = cur
                end
                cur = nil -- a Subproject pair closes the file; one bump per file
            end
        end
    end
    return out
end

-- ===== repository-picker discovery (spec §2.1) =============================
--
-- The picker's direct-submodule list used to come from `git submodule status`,
-- whose cost is linear in the submodule count because it opens each submodule's
-- repository in turn (~650 ms fixed + ~150 ms per submodule on the author's
-- Windows machine — ~2.0 s for nine, and the whole list was gated on it). The
-- same answer is one cheap `git ls-files --stage` plus a few filesystem stats
-- away, which is what these two pure helpers decode; the reads live in
-- git/fetch.lua.

-- Which index stage's object name is the one to report for a path, best first:
-- the resolved entry (0), else "ours" (2), else "theirs" (3), else the merge
-- base (1). A conflicted gitlink has no stage 0.
local STAGE_RANK = { ["0"] = 1, ["2"] = 2, ["3"] = 3, ["1"] = 4 }

--- Parse `git ls-files --stage` output into one entry per **direct submodule**
--- (spec §2.1) — the index's `160000`-mode **gitlink** entries, which is exactly
--- the path set `git submodule status` walks, for one cheap spawn instead of the
--- per-submodule repository opens that command performs.
---
--- Each line is `<mode> <object> <stage>\t<path>`; non-gitlink modes are
--- skipped. A path with a merge conflict appears at several stages and is
--- reported **once**, flagged `conflict`, carrying the best available object
--- name (STAGE_RANK). `sha` is the **recorded** gitlink — what the superproject
--- points at — which is what the checkout state is judged against
--- (`submodule_state`). Returns entries in index (path) order. Pure.
---@param lines string[]?  -- `git ls-files --stage` output lines
---@return { name: string, path: string, sha: string, conflict: boolean }[]
function M.parse_gitlinks(lines)
    local out, by_path, rank = {}, {}, {}
    for _, line in ipairs(lines or {}) do
        local mode, sha, stage, path = line:match("^(%d+) (%x+) (%d+)\t(.+)$")
        local r = STAGE_RANK[stage or ""]
        if mode == "160000" and r then
            local e = by_path[path]
            if not e then
                e = { name = path, path = path, sha = sha, conflict = false }
                by_path[path], rank[path] = e, r
                out[#out + 1] = e
            elseif r < rank[path] then
                e.sha, rank[path] = sha, r
            end
            if stage ~= "0" then e.conflict = true end
        end
    end
    return out
end

--- The checkout state of one direct submodule (spec §2.1), from its **recorded**
--- gitlink `sha` and what the working tree shows — the same four states
--- `git submodule status` reports, derived without running it:
---   `uninitialized` — no local repository at the path (`probe.gitdir` false):
---                     nothing to open, so the picker shows the row disabled,
---   `conflict`      — the gitlink is unmerged in the index,
---   `modified`      — checked out at a **different** commit than recorded,
---   `ok`            — checked out at the recorded commit.
--- `probe.head` is the submodule's own HEAD commit; when it is unknown (an
--- unreadable HEAD) the state cannot be `modified` and degrades to `ok`, which
--- keeps the row openable. Pure.
---@param sha string?      -- the recorded gitlink object name
---@param probe { gitdir: boolean, head: string?, conflict: boolean? }?
---@return "ok"|"modified"|"conflict"|"uninitialized"
function M.submodule_state(sha, probe)
    probe = probe or {}
    -- "Is there a repository to open?" outranks everything: it is the one
    -- distinction the picker acts on.
    if not probe.gitdir then return "uninitialized" end
    if probe.conflict then return "conflict" end
    if probe.head and sha and probe.head ~= sha then return "modified" end
    return "ok"
end

--- Classify the relationship between the old pointer `old` and the new pointer
--- `new` from their merge-base `base` (the empty string or nil when the two
--- histories are disjoint). Pure.
---
--- - `ff`        — `old` is an ancestor of `new` (`base == old`): a forward bump.
--- - `rewind`    — `new` is an ancestor of `old` (`base == new`): the pointer
---                 moved backward.
--- - `diverged`  — a merge-base exists but neither reaches the other.
--- - `unrelated` — no merge-base (disjoint histories).
---@param old string
---@param new string
---@param base string?
---@return "ff"|"rewind"|"diverged"|"unrelated"
function M.classify(old, new, base)
    if not base or base == "" then return "unrelated" end
    if base == old then return "ff" end
    if base == new then return "rewind" end
    return "diverged"
end

--- Distribute the change graph's bounded height (spec §11.7.3) between the two
--- sides. `max` is the total row budget; **one row is reserved** for the shared
--- ancestor, and the rest is split **evenly** between the new (added) and old
--- (removed) sides, the odd leftover going to the new side. Any share a side
--- cannot fill — a short side, or an empty one in a fast-forward / rewind —
--- **spills** to the other, so the side that actually changed gets the room.
--- Returns `{ new, old }`: how many commits to keep on each side (newest-first).
--- Pure.
---@param max integer       -- total row budget (incl. the shared ancestor row)
---@param n_new integer     -- commits available on the new side
---@param n_old integer     -- commits available on the old side
---@return { new: integer, old: integer }
function M.split_budget(max, n_new, n_old)
    local room = math.max((max or 0) - 1, 0) -- reserve one row for the ancestor
    local new_share = math.ceil(room / 2)    -- leftover (odd room) to the new side
    local new_keep = math.min(n_new, new_share)
    local old_keep = math.min(n_old, room - new_share)
    -- Spill the unused budget (a short/empty side) to whichever side can still use
    -- it. At most one side has surplus capacity when room is left, so order is
    -- immaterial; old first, then new.
    local remaining = room - new_keep - old_keep
    local add_old = math.min(remaining, n_old - old_keep)
    old_keep, remaining = old_keep + add_old, remaining - add_old
    new_keep = new_keep + math.min(remaining, n_new - new_keep)
    return { new = new_keep, old = old_keep }
end

--- Keep the newest `keep` commits of a **newest-first** list, reporting how many
--- were dropped. The pointer head (index 1) is always kept (for `keep >= 1`), so
--- the dropped commits are the *middle* ones between the kept newest and the
--- shared ancestor (rendered as a "+K more" marker by the caller). Pure.
---@generic T
---@param commits T[]  -- newest-first
---@param keep integer
---@return T[] kept, integer dropped
function M.truncate(commits, keep)
    keep = math.max(keep or 0, 0)
    local kept = {}
    for i = 1, math.min(keep, #commits) do kept[i] = commits[i] end
    return kept, #commits - #kept
end

return M
