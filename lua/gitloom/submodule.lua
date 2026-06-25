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
