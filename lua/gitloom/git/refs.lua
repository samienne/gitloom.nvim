--- Ref handling — classifying refnames, grouping them for compact display, the
--- ref-picker ordering model (§2), and the resync ref-diff / orphan-prune
--- reachability (§3.4). Pure; part of the gitloom.git data library.

local M = {}

--- Classify a full refname into a ref kind and the name to show.
--- Returns nil to skip the ref (e.g. a remote's HEAD symref).
---@param refname string
---@return string|nil kind  "local"|"remote"|"tag"
---@return string|nil name
function M.classify_ref(refname)
    local name = refname:match("^refs/heads/(.+)$")
    if name then
        return "local", name
    end
    name = refname:match("^refs/remotes/(.+)$")
    if name then
        if name:match("/HEAD$") then
            return nil -- skip the remote's default-branch symref
        end
        return "remote", name
    end
    name = refname:match("^refs/tags/(.+)$")
    if name then
        return "tag", name
    end
    return nil
end

--- Turn parsed worktree stanzas (`parse_worktrees`) into ref entries for the
--- **linked worktrees whose HEAD nothing else names** (spec §3.2). Three skips:
---
---  * the **main** worktree — its HEAD is already the `head` ref (§4.1);
---  * a **bare** worktree, or any stanza with no HEAD — nothing to point at;
---  * a HEAD commit **any existing ref already points at** (`taken`). This is the
---    general form of "don't add it if there's a matching branch": it covers a
---    worktree checked out on a branch (the branch ref labels that commit) and a
---    detached HEAD parked on a branch tip or tag alike. Emitted entries join
---    `taken` as we go, so two worktrees on the same commit yield one label.
---
--- The name is `wt:<basename>`. A `:` is invalid in a git refname, so this can
--- never collide with a real branch or tag in the name → Ref registry. Pure.
---@param entries { path: string, name: string, head: string?, bare: boolean, main: boolean }[]?
---@param taken table<string, boolean>?  -- commit hashes an existing ref points at
---@return { name: string, kind: string, hash: string }[]
function M.worktree_refs(entries, taken)
    local seen = {}
    for h in pairs(taken or {}) do seen[h] = true end
    local out = {}
    for _, e in ipairs(entries or {}) do
        if not e.main and not e.bare and e.head and not seen[e.head] then
            seen[e.head] = true
            out[#out + 1] = { name = "wt:" .. e.name, kind = "worktree", hash = e.head }
        end
    end
    return out
end

--- The divergence indicator's pieces for a tracked branch (§6.3), as
--- `{ text, kind }` segments whose concatenated `text` is `track_label` and whose
--- `kind` ("ahead"|"behind"|"gone") selects the colour. Empty for no upstream or
--- an in-sync branch (no news is good news). Pure.
---@param track Upstream?
---@return { text: string, kind: string }[]
function M.track_segments(track)
    if not track then return {} end
    if track.gone then return { { text = " gone", kind = "gone" } } end
    local a, b = track.ahead or 0, track.behind or 0
    local segs = {}
    if a > 0 then segs[#segs + 1] = { text = " ⇡" .. a, kind = "ahead" } end
    if b > 0 then segs[#segs + 1] = { text = (a > 0 and "⇣" or " ⇣") .. b, kind = "behind" } end
    return segs
end

--- The plain-text divergence indicator (§6.3) — the concatenation of
--- `track_segments`' texts, so the rendered (coloured) and plain (selection/
--- cursor) forms stay byte-identical. "" when in sync or untracked. Pure.
---@param track Upstream?
---@return string
function M.track_label(track)
    local s = ""
    for _, seg in ipairs(M.track_segments(track)) do s = s .. seg.text end
    return s
end

--- Group a commit's refs for compact display (specification.md §6). Branch
--- refs (local + remote) that share a short name collapse into one entry: the
--- name once, plus the remotes that also point here. A remote ref's name keeps
--- its `remote/` prefix (classify_ref), so the short name is the part after the
--- first path component. Tags, worktree labels (§3.2) and the HEAD marker stay
--- separate. A local branch
--- that tracks an upstream carries its `track` (the §6.3 divergence) on the group.
---
--- The three lists are the decoration order (§6): branches, tags, worktrees.
---@class RefGroup
---@field name string
---@field has_local boolean
---@field remotes string[]
---@field track? Upstream   the local branch's upstream divergence, if it tracks one
---@param refs Ref[]?
---@return { head: boolean, branches: RefGroup[], tags: string[], worktrees: string[] }
function M.group_refs(refs)
    local head = false
    local tags = {}
    local worktrees = {}
    local by_name = {} -- short name -> RefGroup
    local order = {}   -- short names, first-seen (stable, matches git's order)

    local function group(short)
        if not by_name[short] then
            by_name[short] = { name = short, has_local = false, remotes = {} }
            order[#order + 1] = short
        end
        return by_name[short]
    end

    for _, ref in ipairs(refs or {}) do
        if ref.kind == "head" then
            head = true
        elseif ref.kind == "tag" then
            tags[#tags + 1] = ref.name
        elseif ref.kind == "worktree" then
            worktrees[#worktrees + 1] = ref.name
        elseif ref.kind == "local" then
            local g = group(ref.name)
            g.has_local = true
            if ref.upstream then g.track = ref.upstream end
        elseif ref.kind == "remote" then
            -- "origin/feature/foo" -> remote "origin", short "feature/foo".
            local remote, short = ref.name:match("^([^/]+)/(.+)$")
            if short then
                table.insert(group(short).remotes, remote)
            else
                group(ref.name) -- malformed; show the raw name, no remote
            end
        end
    end

    local branches = {}
    for _, short in ipairs(order) do
        branches[#branches + 1] = by_name[short]
    end
    return { head = head, branches = branches, tags = tags, worktrees = worktrees }
end

--- Push a ref name to the front of a session most-recently-used list, dropping
--- any earlier occurrence so each name appears once (the ref-picker recency,
--- §2). Pure: returns a fresh list, newest first; the input is not mutated.
---@param list string[]?   the current MRU list, newest first
---@param name string      the ref just jumped to
---@return string[]
function M.bump_recent(list, name)
    local out = { name }
    for _, n in ipairs(list or {}) do
        if n ~= name then out[#out + 1] = n end
    end
    return out
end

-- Sort key for the ref picker's stable (non-recent) grouping: HEAD first, then
-- local branches, remotes, tags, and the linked-worktree labels (§3.2) last —
-- they are the least branch-like thing in the list.
local REF_KIND_RANK = { head = 1, ["local"] = 2, remote = 3, tag = 4, worktree = 5 }

--- Build the ordered ref-picker item list (§2). Each ref (the name → Ref
--- registry, "HEAD" included) becomes an entry carrying what the picker shows
--- and the hash to jump to. Order: refs jumped to this session first, in MRU
--- order (`recents`, newest first); the rest grouped HEAD / local / remote / tag
--- then by name. Refs without a resolved commit are skipped (nothing to jump
--- to). Each item's `text` is the picker's match string (name then subject, both
--- searchable). Pure (no I/O) so it is unit-testable via `_internal`.
---@param refs table<string, Ref>?   the repo's name → Ref registry
---@param recents string[]?          session MRU ref names, newest first
---@return { name: string, kind: string, hash: string, short: string, subject: string, recent: boolean, track?: Upstream, text: string }[]
function M.ref_picker_items(refs, recents)
    local rank = {} -- ref name -> 1-based MRU position
    for i, n in ipairs(recents or {}) do
        if not rank[n] then rank[n] = i end
    end
    local items = {}
    for name, ref in pairs(refs or {}) do
        local commit = ref and ref.commit
        if commit and commit.hash then
            local subject = (commit.message or ""):match("^[^\r\n]*") or ""
            items[#items + 1] = {
                name = name,
                kind = ref.kind,
                hash = commit.hash,
                short = commit.hash:sub(1, 8),
                subject = subject,
                recent = rank[name] ~= nil,
                track = ref.upstream, -- upstream divergence for the §6.3 indicator
                text = name .. " " .. subject, -- the picker's fuzzy-match string
            }
        end
    end
    table.sort(items, function(a, b)
        local ra, rb = rank[a.name], rank[b.name]
        if ra or rb then
            if ra and rb then return ra < rb end
            return ra ~= nil -- a recent ref sorts before a non-recent one
        end
        local ka, kb = REF_KIND_RANK[a.kind] or 9, REF_KIND_RANK[b.kind] or 9
        if ka ~= kb then return ka < kb end
        return a.name < b.name
    end)
    return items
end

--- The 1-based decoration index (into decoration_texts / the `h`/`l` selection
--- order) of the decoration that represents the ref named `name` of kind `kind`,
--- or nil if it has none. A local/remote ref maps to its branch group (keyed by
--- the short name — the part after the first path component for a remote); a tag
--- maps to its tag entry, a worktree label to its entry after the tags; HEAD has
--- no own decoration (nil). Used to pre-select a
--- picked ref on its landed row (§2). Pure; the inverse of `selected_owner_ids`.
---@param commit { refs: Ref[] }?
---@param name string
---@param kind string   -- "local" | "remote" | "tag" | "head" | "worktree"
---@return integer|nil
function M.ref_decoration_index(commit, name, kind)
    local g = M.group_refs(commit and commit.refs or {})
    if kind == "tag" then
        for i, t in ipairs(g.tags) do
            if t == name then return #g.branches + i end
        end
        return nil
    end
    if kind == "worktree" then
        for i, w in ipairs(g.worktrees) do
            if w == name then return #g.branches + #g.tags + i end
        end
        return nil
    end
    -- local / remote → a branch group keyed by the short name.
    local short = (kind == "remote") and (name:match("^[^/]+/(.+)$") or name) or name
    for i, b in ipairs(g.branches) do
        if b.name == short then return i end
    end
    return nil
end

--- Diff two ref maps (key → tip hash) for the resync (spec §3.4). Returns the
--- keys that are new, gone, or re-pointed since the last read. Pure — the window
--- glue turns the result into ref-binding updates and a prune. Unit-testable.
---@param old table<string, string>  previous key → tip hash
---@param new table<string, string>  current  key → tip hash
---@return { added: string[], removed: string[], moved: string[] }
function M.diff_ref_tips(old, new)
    local added, removed, moved = {}, {}, {}
    for k, h in pairs(new) do
        if old[k] == nil then
            added[#added + 1] = k
        elseif old[k] ~= h then
            moved[#moved + 1] = k
        end
    end
    for k in pairs(old) do
        if new[k] == nil then removed[#removed + 1] = k end
    end
    table.sort(added)
    table.sort(removed)
    table.sort(moved)
    return { added = added, removed = removed, moved = moved }
end

--- The set of commit hashes reachable from `tips` by walking parents (spec
--- §3.4). After a ref rewrite (force-push / rebase) the commits *not* in this
--- set are orphans to prune. `commits` is a hash → Commit map; each Commit's
--- `parents` may be resolved Commit objects or raw hash strings. Pure and
--- unit-testable.
---@param commits table<string, Commit>
---@param tips string[]   ref tip hashes to seed the walk
---@return table<string, boolean>  reachable hashes
function M.reachable_hashes(commits, tips)
    local seen, stack = {}, {}
    for _, h in ipairs(tips) do
        if commits[h] and not seen[h] then
            seen[h] = true
            stack[#stack + 1] = h
        end
    end
    while #stack > 0 do
        local c = commits[table.remove(stack)]
        for _, p in ipairs((c and c.parents) or {}) do
            local ph = type(p) == "table" and p.hash or p
            if commits[ph] and not seen[ph] then
                seen[ph] = true
                stack[#stack + 1] = ph
            end
        end
    end
    return seen
end

return M
