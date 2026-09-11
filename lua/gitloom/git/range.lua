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
---@field rev string       git rev-range the diff tool understands; a **single** rev
---                       (or `""`) is the working-tree form (§11.5/§13.5)
---@field from? Commit|"index"|"worktree"   base endpoint (nil for a root commit; a tree state for a virtual commit, §11.5)
---@field to Commit|"index"|"worktree"       head endpoint (a tree state for a virtual commit, §11.5)
---@field untracked? boolean  the head is the **untracked** node (§4.2): `git diff` never
---                           lists untracked files, so the in-graph patch appends the
---                           §3.3 synthesized additions. The provider ignores it — a
---                           working-tree view lists untracked files itself (§13.5).
---@param commit Commit
---@return DiffRange
function M.commit_range(commit)
    -- Working-tree virtual commits (§4.2): the endpoint is a tree state, not a
    -- commit (§11.5). Staged is the index vs HEAD; unstaged the working tree vs
    -- HEAD. The untracked node has no git-tracked counterpart, so it reuses the
    -- unstaged node's working-tree range (§11.8). The exact provider invocation
    -- (rev) is a verify-against-diffview point (spec §11.5 open).
    if commit.virtual == "staged" then
        return { rev = "--cached", from = (commit.parents or {})[1], to = "index" }
    elseif commit.virtual == "untracked" then
        return { rev = "HEAD", from = "index", to = "worktree", untracked = true }
    elseif commit.virtual == "unstaged" then
        return { rev = "HEAD", from = "index", to = "worktree" }
    end
    local parents = commit.parents or {}
    if #parents == 0 then
        return { rev = M.EMPTY_TREE .. ".." .. commit.hash, from = nil, to = commit }
    end
    return { rev = commit.hash .. "^!", from = parents[1], to = commit }
end

--- The tree state a working-tree virtual commit (§4.2) denotes as a range
--- endpoint: the staged node is the **index**, the unstaged and untracked nodes
--- are the **working tree**. `nil` for a real commit. This is the whole reason a
--- virtual endpoint never contributes a rev — its hash is a reserved sentinel,
--- not a git object (§13.5).
--- `Commit.parents` may still hold raw hash strings before resolution, so the
--- parameter is widened rather than narrowed at the call site.
---@param c Commit|string|nil
---@return "index"|"worktree"|nil
local function tree_state(c)
    if type(c) ~= "table" then return nil end
    if c.virtual == "staged" then return "index" end
    if c.virtual then return "worktree" end -- unstaged / untracked
    return nil
end

--- The base of a span: the older end's first parent (§13.5). `nil` when the older
--- end is a root (the caller substitutes the empty tree). When that parent is
--- itself a virtual commit — which happens only for a selection covering just
--- working-tree rows, since the stack is untracked → unstaged → staged → HEAD —
--- it resolves to *its* tree state rather than its sentinel hash.
---@param older Commit
---@return Commit|"index"|"worktree"|nil
local function span_base(older)
    local p = (older.parents or {})[1]
    if not p then return nil end
    return tree_state(p) or p
end

--- A `DiffRange` (§11.5) for a commit selection (§13.5): the **literal** combined
--- patch between the selection's older and newer ends. `newer`/`older` are the
--- real endpoint commits (newest and oldest selected, resolved from the display
--- nodes by the caller). A single-commit selection (`newer == older`) is exactly
--- `commit_range`. Otherwise the base is the older commit's first parent, so the
--- range is `<older>^..<newer>` — an empty-tree range when the older end is a
--- root. The merged-in side of any merge on the path is included (the open
--- first-parent-restricted variant is §13.6).
---
--- When `newer` is a **working-tree virtual commit** (§4.2 — the only end it can
--- be, since it has no children) the head of the range is a **tree state**, so
--- `rev` names a **single** rev instead of an `<a>..<b>` span: `--cached <base>`
--- to the index, `<base>` to the working tree. That is not cosmetic — a single
--- rev is what makes the diff provider open the real files on disk (LSP attaches);
--- a two-rev span builds both sides from read-only git blobs (§11.5). The sentinel
--- hash is never read, here or downstream.
---@param newer Commit
---@param older Commit
---@return DiffRange
function M.range_endpoints(newer, older)
    if newer == older or newer.hash == older.hash then
        return M.commit_range(newer)
    end
    local head = tree_state(newer)
    local base = span_base(older)
    if head then
        -- A tree-state base (both ends inside the worktree stack) has no rev of
        -- its own; the empty `rev` is the provider's own default — working tree
        -- vs index — which is exactly what that selection denotes.
        local rev = (type(base) == "table" and base.hash) or (base == nil and M.EMPTY_TREE) or ""
        if head == "index" then
            rev = (rev ~= "") and ("--cached " .. rev) or "--cached"
        end
        return { rev = rev, from = base, to = head,
            untracked = (newer.virtual == "untracked") or nil }
    end
    -- A root older end (no base), or — structurally impossible, since a virtual
    -- commit has no children so nothing real can sit above one — a tree-state
    -- base under a real head: fall back to the empty tree rather than reading a
    -- `.hash` off a string.
    if type(base) ~= "table" then
        return { rev = M.EMPTY_TREE .. ".." .. newer.hash, from = nil, to = newer }
    end
    return { rev = base.hash .. ".." .. newer.hash, from = base, to = newer }
end

return M
