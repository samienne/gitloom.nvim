--- Diff ranges — building the DiffRange a diff provider understands, for a
--- single commit (§11.5) or a commit selection span (§13.5). Pure; part of the
--- gitloom.git data library.

local M = {}

-- git's well-known empty-tree hash, used as the base for a root commit's diff.
M.EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

--- The DiffRange for a single commit's own changes (specification.md §11.5).
--- `rev` is `<hash>^!` (the commit vs its first parent), or an empty-tree range
--- for a root commit (no parents) so it still diffs. `from`/`to` are the
--- structured endpoints. The first range constructor for the diff provider;
--- graph range-selection will add more. Pure; exposed for testing.
---@class DiffRange
---@field rev string       git rev-range the diff tool understands
---@field from? Commit|"index"|"worktree"   base endpoint (nil for a root commit; a tree state for a virtual commit, §11.5)
---@field to Commit|"index"|"worktree"       head endpoint (a tree state for a virtual commit, §11.5)
---@param commit Commit
---@return DiffRange
function M.commit_range(commit)
    -- Working-tree virtual commits (§4.2): the endpoint is a tree state, not a
    -- commit (§11.5). Staged is the index vs HEAD; unstaged the working tree vs
    -- HEAD. The exact provider invocation (rev) is a verify-against-diffview
    -- point (spec §11.5 open).
    if commit.virtual == "staged" then
        return { rev = "--cached", from = (commit.parents or {})[1], to = "index" }
    elseif commit.virtual == "unstaged" then
        return { rev = "HEAD", from = "index", to = "worktree" }
    end
    local parents = commit.parents or {}
    if #parents == 0 then
        return { rev = M.EMPTY_TREE .. ".." .. commit.hash, from = nil, to = commit }
    end
    return { rev = commit.hash .. "^!", from = parents[1], to = commit }
end

--- A `DiffRange` (§11.5) for a commit selection (§13.5): the **literal** combined
--- patch between the selection's older and newer ends. `newer`/`older` are the
--- real endpoint commits (newest and oldest selected, resolved from the display
--- nodes by the caller). A single-commit selection (`newer == older`) is exactly
--- `commit_range`. Otherwise the base is the older commit's first parent, so the
--- range is `<older>^..<newer>` — an empty-tree range when the older end is a
--- root. The merged-in side of any merge on the path is included (the open
--- first-parent-restricted variant is §13.6).
---@param newer Commit
---@param older Commit
---@return DiffRange
function M.range_endpoints(newer, older)
    if newer == older or newer.hash == older.hash then
        return M.commit_range(newer)
    end
    local base = (older.parents or {})[1]
    if not base then
        return { rev = M.EMPTY_TREE .. ".." .. newer.hash, from = nil, to = newer }
    end
    return { rev = base.hash .. ".." .. newer.hash, from = base, to = newer }
end

return M
