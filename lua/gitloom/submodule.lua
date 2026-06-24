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

--- Link a flat, **newest-first** list of parsed commits (each with `parents` as
--- hash strings) into layout-ready OrderItems for `columns.layout`. Resolves each
--- in-list parent hash to its Commit object and sets the child back-link; a
--- parent hash **not** in the list (the bounded cone's boundary — e.g. the
--- merge-base's own parents) is dropped from `parents`, so that commit reads as a
--- root. Order is preserved. Mutates the commits in place (resolving `parents`,
--- populating `children`) and returns `{ type = "commit", commit }` items. Pure.
---@param commits Commit[]  -- newest-first; `parents` are hash strings
---@return table[]  -- OrderItems for columns.layout
function M.link(commits)
    local by_hash = {}
    for _, c in ipairs(commits) do
        c.children = c.children or {}
        by_hash[c.hash] = c
    end
    for _, c in ipairs(commits) do
        local resolved = {}
        for _, ph in ipairs(c.parents or {}) do
            local p = by_hash[ph]
            if p then
                resolved[#resolved + 1] = p
                p.children[#p.children + 1] = c
            end
        end
        c.parents = resolved
    end
    local items = {}
    for _, c in ipairs(commits) do
        items[#items + 1] = { type = "commit", commit = c }
    end
    return items
end

return M
