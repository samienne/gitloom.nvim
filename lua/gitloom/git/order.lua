--- Row ordering — gitloom owning the commit order itself (spec §1.1, §3.1).
---
--- `order_commits` reproduces git's `--topo-order` over the loaded set so the
--- view does not depend on `git log --graph`. Pure (no I/O); part of the
--- gitloom.git data library.

local M = {}

--- Topologically sort the row commits, child-first, reproducing **git's
--- `--topo-order`** (spec §3.1): a parent is always emitted after **all** of its
--- children (so it lands at a later row), and history is grouped by lineage
--- rather than interleaved by date — what keeps the graph's lanes tight.
---
--- The algorithm mirrors git's `sort_in_topological_order`: it is a **depth-first
--- walk over a LIFO stack**, not a date-priority sort. The ready tips (commits
--- whose in-set children are all placed) seed the stack newest-first; popping one
--- emits it and pushes each parent the instant it becomes ready, so the next pop
--- descends straight into that parent — a merge's merged-in lineage is emitted
--- right after the merge instead of being deferred. Parents are pushed in order,
--- so under the LIFO the **last parent is descended first** (git's discipline),
--- and the descent goes deep before the next tip is touched. Date (newest first,
--- hash to break ties) only orders the **independent tips** on the stack — once a
--- lineage starts it is followed by topology, not recency.
---
--- Pure (no I/O) and operates only on the given set: relationships to commits
--- *outside* `commits` (e.g. unloaded parent placeholders) are ignored, so it
--- orders the loaded rows without needing the full history. This is gitloom
--- owning the row order itself (§1.1, §3.1). Unit-testable via `_internal`.
---@param commits Commit[]  the row commits to order (each with resolved .parents/.children)
---@return Commit[]         the same commits, child-first topological order
function M.order_commits(commits)
    local in_set = {}
    for _, c in ipairs(commits) do in_set[c.hash] = c end

    -- pending[hash] = number of c's children still unemitted within the set; a
    -- commit is ready (all children placed) when it reaches 0.
    local pending = {}
    for _, c in ipairs(commits) do
        local n = 0
        for _, ch in ipairs(c.children or {}) do
            if in_set[ch.hash] then n = n + 1 end
        end
        pending[c.hash] = n
    end

    -- The stack is a plain array (push = append, pop = remove last = LIFO). Seed
    -- the ready tips **oldest committer-date first** so the newest lands on top
    -- and is popped first (git seeds newest-first then reverses the LIFO). git
    -- orders by *committer* date (`%ct`, `cepoch`); fall back to author date for
    -- synthetic commits without it. Hash breaks ties for determinism: the smaller
    -- hash ends nearer the top, so among equal-date tips it is emitted first.
    local function tip_epoch(c)
        return c.cepoch or (c.date and c.date.epoch) or 0
    end
    local stack = {}
    for _, c in ipairs(commits) do
        if pending[c.hash] == 0 then stack[#stack + 1] = c end
    end
    table.sort(stack, function(a, b)
        local ea, eb = tip_epoch(a), tip_epoch(b)
        if ea ~= eb then return ea < eb end -- ascending: oldest first (top = newest)
        return a.hash > b.hash
    end)

    local out, emitted = {}, {}
    while #stack > 0 do
        local c = stack[#stack]
        stack[#stack] = nil
        if not emitted[c.hash] then
            out[#out + 1] = c
            emitted[c.hash] = true
            -- Push parents that just became ready, in parent order — the last
            -- parent ends on top and is descended first (DFS), so a merged-in
            -- lineage stays contiguous with its merge.
            for _, p in ipairs(c.parents or {}) do
                if in_set[p.hash] and not emitted[p.hash] and pending[p.hash] > 0 then
                    pending[p.hash] = pending[p.hash] - 1
                    if pending[p.hash] == 0 then
                        stack[#stack + 1] = p
                    end
                end
            end
        end
    end

    -- Defensive: a consistent DAG emits everything, but never drop rows if the
    -- child links are inconsistent — append any stragglers newest-first.
    if #out < #commits then
        local rest = {}
        for _, c in ipairs(commits) do
            if not emitted[c.hash] then rest[#rest + 1] = c end
        end
        table.sort(rest, function(a, b)
            local ea, eb = tip_epoch(a), tip_epoch(b)
            if ea ~= eb then return ea > eb end
            return a.hash < b.hash
        end)
        for _, c in ipairs(rest) do out[#out + 1] = c end
    end

    return out
end

return M
