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

--- Whether a branch's configured upstream **matches** it (§6.3): the branch it
--- names on its remote (`%(upstream:remoteref)`) is the local branch's own name.
--- A local upstream (`remote = .`) never matches. Pure.
---@param name string     the local branch
---@param remote string?  `%(upstream:remotename)` (`branch.<name>.remote`)
---@param merge string?   `%(upstream:remoteref)` (`branch.<name>.merge`)
---@return boolean
function M.upstream_matches(name, remote, merge)
    return remote ~= nil and remote ~= "." and merge == "refs/heads/" .. name
end

--- Mark each local branch whose upstream does not match (§6.3) with the remotes
--- that hold a remote-tracking branch of its own name (`Upstream.same`, the
--- §6.3 warning) — read from the same ref list, no extra query. `entries` is a
--- parsed ref read (`{ name, kind, upstream? }`); a remote ref's remote is its
--- first name component, as for the `↑remote` list (group_refs), and a remote's
--- `HEAD` symref is not in the list (classify_ref drops it). Mutates the
--- upstreams in place; `same` is nil when there are none (or the upstream
--- matches). Pure otherwise.
---@param entries { name: string, kind: string, upstream?: Upstream }[]
function M.mark_same_named(entries)
    local by_branch = {} -- remote branch short name -> remotes holding it, in read order
    for _, e in ipairs(entries) do
        if e.kind == "remote" then
            local remote, short = e.name:match("^([^/]+)/(.+)$")
            if short then
                by_branch[short] = by_branch[short] or {}
                table.insert(by_branch[short], remote)
            end
        end
    end
    for _, e in ipairs(entries) do
        local up = e.upstream
        if e.kind == "local" and up then
            up.same = (not up.match) and by_branch[e.name] and vim.list_extend({}, by_branch[e.name]) or nil
        end
    end
end

--- The upstream tracking pieces of a tracked branch (§6.3), as `{ text, kind }`
--- segments whose concatenated `text` is `track_label` and whose `kind` selects
--- the colour: first the spelled-out **non-matching** upstream ` →<upstream>`
--- ("upstream", or "mismatch" when a same-named remote branch exists — `same`),
--- with `./` before a local upstream; then the divergence ("ahead"|"behind"|
--- "gone"). A matching upstream in sync, or no upstream, gives none (no news is
--- good news). `icon` is `icons.upstream` (default "→"; "" leaves the bare
--- name). Pure.
---@param track Upstream?
---@param icon string?
---@return { text: string, kind: string }[]
function M.track_segments(track, icon)
    if not track then return {} end
    local segs = {}
    if track.match == false then
        local dot = (track.remote == "." and "./" or "")
        segs[1] = { text = " " .. (icon or "→") .. dot .. track.short,
            kind = (track.same and #track.same > 0) and "mismatch" or "upstream" }
    end
    if track.gone then
        segs[#segs + 1] = { text = " gone", kind = "gone" }
        return segs
    end
    local a, b = track.ahead or 0, track.behind or 0
    if a > 0 then segs[#segs + 1] = { text = " ⇡" .. a, kind = "ahead" } end
    if b > 0 then segs[#segs + 1] = { text = (a > 0 and "⇣" or " ⇣") .. b, kind = "behind" } end
    return segs
end

--- The plain-text tracking tokens (§6.3) — the concatenation of
--- `track_segments`' texts, so the rendered (coloured) and plain (selection/
--- cursor) forms stay byte-identical. "" when in sync with a matching upstream,
--- or untracked. Pure.
---@param track Upstream?
---@param icon string?  `icons.upstream` (default "→")
---@return string
function M.track_label(track, icon)
    local s = ""
    for _, seg in ipairs(M.track_segments(track, icon)) do s = s .. seg.text end
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
--- **HEAD's label goes first** (§6): when the HEAD marker names the branch it is
--- on (`Ref.branch`, or the `head_branch` fallback for a ref list that does not
--- carry it), that branch's group is flagged `current` and moved to the front of
--- `branches` — so every consumer that walks this order (the rendered labels, the
--- `h`/`l` selection, the owner / checkout lookups) agrees on it.
---@class RefGroup
---@field name string
---@field has_local boolean
---@field remotes string[]
---@field track? Upstream   the local branch's upstream (divergence + match, §6.3), if it tracks one
---@field current? boolean  the branch HEAD is on — drawn `(HEAD → name …)`, first
---@param refs Ref[]?
---@param head_branch? string  the current branch, when the head ref does not name it
---@return { head: boolean, current: RefGroup?, branches: RefGroup[], tags: string[], worktrees: string[] }
function M.group_refs(refs, head_branch)
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
            head_branch = ref.branch or head_branch
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
    local current = head and head_branch and by_name[head_branch] or nil
    if current then
        current.current = true
        branches[1] = current
    end
    for _, short in ipairs(order) do
        if by_name[short] ~= current then branches[#branches + 1] = by_name[short] end
    end
    return { head = head, current = current, branches = branches, tags = tags, worktrees = worktrees }
end

--- The commit view's tracking entries (§11.2) before the probe: one per local
--- branch on the commit, in decoration order (`group_refs`, HEAD's branch first),
--- carrying its cached upstream. Remote-only groups, tags and worktree labels get
--- none. Pure.
---@param refs Ref[]?
---@return TrackingEntry[]
function M.tracking_entries(refs)
    local out = {}
    for _, g in ipairs(M.group_refs(refs).branches) do
        if g.has_local then out[#out + 1] = { branch = g.name, upstream = g.track } end
    end
    return out
end

--- The text HEAD's label opens with on a branch (§6): `(HEAD → name …)`.
M.HEAD_ARROW = "HEAD → "

--- What is checked out, in words (§10.4.1): `HEAD → <branch> (<short>)` on a
--- branch, `HEAD detached at <short>` otherwise (`<short>` = 7 hex chars); nil
--- when there is no HEAD commit. Pure — the post-checkout notice.
---
--- `upstream` — the branch's tracking data from the FRESH ref read (§6.3) —
--- appends the behind notice: `— 12 behind origin/foo` when strictly behind,
--- `— 3 ahead, 12 behind origin/foo` when diverged; nothing when ahead only, in
--- sync, `gone`, without an upstream, or detached.
---@param branch string?
---@param hash string?
---@param upstream Upstream?
---@return string?
function M.head_summary(branch, hash, upstream)
    if not hash then return nil end
    local short = hash:sub(1, 7)
    if not branch then return "HEAD detached at " .. short end
    local s = ("HEAD → %s (%s)"):format(branch, short)
    local u = upstream
    if u and not u.gone and (u.behind or 0) > 0 then
        if (u.ahead or 0) > 0 then
            s = s .. (" — %d ahead, %d behind %s"):format(u.ahead, u.behind, u.short)
        else
            s = s .. (" — %d behind %s"):format(u.behind, u.short)
        end
    end
    return s
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
