--- The commit-graph data model — the Commit / Ref types and the pure
--- constructors that build the repo's DAG as refs and commits stream in. No I/O
--- (the fetch layer drives these); part of the gitloom.git data library.

local M = {}

---@class Ref
---@field name string
---@field kind "local"|"remote"|"tag"|"head"
---@field commit Commit   the commit this ref points at (a direct reference)

--- A node in the commit DAG. `hash`/`parents`/`children`/`refs` exist from the
--- moment a commit is created (a ref or another commit's parent can create it as
--- a placeholder); `author`/`date`/`message` are filled in lazily when its own
--- `git log` line arrives (`loaded` then becomes true), so they are optional.
---@class Commit
---@field hash string
---@field parents Commit[]|string[]   parent hashes from `git log`, resolved to Commits
---@field children Commit[]           back-links, set as children stream in
---@field refs Ref[]
---@field author? string
---@field date? Timestamp
---@field cepoch? integer    committer date as Unix time (%ct); seeds order_commits (§3.1)
---@field message? string
---@field loaded? boolean   true once the commit's own log line has been parsed
---@field virtual? "staged"|"unstaged"|"untracked"   set on a working-tree virtual commit (§4.2)
---@field wt? { changed: integer }   working-tree changed-file count (virtual only; untracked counts untracked files)
---@field deco? string      raw `%d` ref decoration, only on submodule-view commits (§11.7)
--- View-builder fields, present only on a synthetic **collapsed head** node
--- (specification.md §10.3); a real commit leaves them nil. The head flows
--- through `OrderItem.commit`/`GraphColumn.commit` as a commit-like node.
---@field collapsed? boolean  marks a collapsed head (a contracted region)
---@field junction? boolean   a collapsed-region fork/merge kept for topology (§10.4)
---@field tip? Commit         the region's newest member (for the date/author/subject)
---@field count? integer      number of commits the head contracts
---@field region? string[]    member hashes a head contracts (for cursor-follow)
---@field signature? table<string, boolean>  owner ids reaching the region (for expand)

--- The Commit for `hash`, created as a sparse placeholder if not seen yet.
--- The placeholder is filled in when its `git log` line arrives (identity
--- preserved), so refs and parents can be resolved in any order.
---@param repo Repo
---@param hash string
---@return Commit
function M.get_or_create_commit(repo, hash)
    local commit = repo.commits[hash]
    if not commit then
        commit = { hash = hash, parents = {}, children = {}, refs = {} }
        repo.commits[hash] = commit
    end
    return commit
end

--- Resolve a ref to its target Commit and link them (direct references).
---@param repo Repo
---@param name string
---@param kind string
---@param hash string
function M.add_ref(repo, name, kind, hash)
    local commit = M.get_or_create_commit(repo, hash)
    ---@type Ref
    local ref = { name = name, kind = kind, commit = commit }
    commit.refs = commit.refs or {}
    table.insert(commit.refs, ref)
    repo.refs[ref.kind == "head" and "HEAD" or name] = ref
end

return M
