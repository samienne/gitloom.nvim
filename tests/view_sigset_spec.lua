--- Interned signature sets (`gitloom.graph.sigset`) — the representation §10.2's
--- per-commit signatures are computed in.
---
--- Two things need proving, and the second is what gives the first its point:
---
---  1. **Parity** — the projection is unchanged. Compared against the
---     **reference** pass (`h.reference_signatures`, a direct transcription of the
---     §10.2 definition into one materialised set per commit, which is what
---     shipped before): the same signatures commit for commit, the same
---     projection, and the same layout cell-for-cell over every merge style x
---     every layout policy. `view.project` takes its pre-interning path for a
---     plain table of sets, so this compares two real implementations rather than
---     one against itself.
---  2. **It really is shared** — on a trunk of merges the materialised form is
---     Θ(commits × owners) entries while the interned one must stay O(commits ×
---     depth) nodes. Without that the parity above is satisfied by any correct
---     set representation, including the quadratic one being replaced.

local h = require("tests.graph_helpers")
local view = require("gitloom.graph.view")
local sigset = require("gitloom.graph.sigset")
local columns = require("gitloom.graph.columns")

local STYLES = {
    { name = "split-line", s = { merge_on_separate_line = false, split_on_separate_line = true } },
    { name = "merge-line", s = { merge_on_separate_line = true, split_on_separate_line = false } },
    { name = "mergesplit", s = { merge_on_separate_line = true, split_on_separate_line = true } },
    { name = "inline",     s = { merge_on_separate_line = false, split_on_separate_line = false } },
    { name = "inline-mos", s = { allow_merge_on_split = true } },
}
local POLICIES = { "compact", "survivors", "linear", "straight", "gutter" }

----------------------------------------------------------------------
-- Corpora
----------------------------------------------------------------------

--- A trunk of `n` commits where every one is a merge of a one-commit side branch
--- that forked from the trunk commit below it — the shape whose signatures are
--- quadratic (every merge above a trunk commit contributes an owner to it).
---@param n integer
---@return table[] rows
local function merge_trunk(n)
    local rows = {}
    for i = 1, n do
        if i < n then
            rows[#rows + 1] = { "t" .. i, { "t" .. (i + 1), "b" .. i } }
            rows[#rows + 1] = { "b" .. i, { "t" .. (i + 1) } }
        else
            rows[#rows + 1] = { "t" .. i, {} }
        end
    end
    return rows
end

--- The owner set an opened graph builds for `items` (§10.7): every childless
--- commit is a ref tip, the first is the pinned anchor, focus on.
---@param items table[]
---@return table[] owners
local function focus_owners(items)
    local ro, pinned = {}, {}
    for i, it in ipairs(items) do
        if #(it.commit.children or {}) == 0 then
            local id = "r" .. i
            it.commit.refs = it.commit.refs or {}
            it.commit.refs[#it.commit.refs + 1] = { name = id, kind = "local" }
            ro[#ro + 1] = { id = id, tip = it.commit, mode = "normal" }
            if #ro == 1 then pinned[id] = true end
        end
    end
    return view.owners(items, ro, pinned, {}, true)
end

--- A hand-built owner set with MIXED `fp_only` and every mode — the case that
--- exercises the intersection path (an fp-only owner may not cross a non-first
--- parent edge, an ordinary one may) and the full mode join.
---@param items table[]
---@return table[] owners
local function mixed_owners(items)
    local owners = {}
    local modes = { "normal", "collapsed", "hidden" }
    for i, it in ipairs(items) do
        if i % 3 == 1 then
            owners[#owners + 1] = {
                id = "o" .. i, tip = it.commit,
                mode = modes[(i % 3) + 1],
                fp_only = (i % 2) == 0,
            }
        end
    end
    return owners
end

--- The corpus every parity block runs over: named fixtures, a merge trunk at two
--- sizes, and a fuzz sweep.
---@return table[]  -- { { name, rows }, ... }
local function corpus()
    local out = {
        -- Sized to cross the trie's level boundaries: 6 merges stays inside one
        -- 32-slot leaf, 40 and 90 force two and three levels, so a node interned
        -- without its position would collide here.
        { name = "merge-trunk 6", rows = merge_trunk(6) },
        { name = "merge-trunk 40", rows = merge_trunk(40) },
        { name = "merge-trunk 90", rows = merge_trunk(90) },
        { name = "diamond", rows = {
            { "h", { "m" } },
            { "m", { "p1", "p2" } },
            { "p1", { "base" } },
            { "p2", { "base" } },
            { "base", {} },
        } },
        { name = "two tips", rows = {
            { "ta", { "base" } },
            { "tb", { "base" } },
            { "base", {} },
        } },
    }
    for seed = 1, 40 do
        out[#out + 1] = { name = "fuzz " .. seed, rows = h.random_dag(14, seed) }
    end
    return out
end

----------------------------------------------------------------------
-- Comparable dumps
----------------------------------------------------------------------

local function set_sig(s)
    local ks = {}
    for k in pairs(s or {}) do ks[#ks + 1] = k end
    table.sort(ks)
    return table.concat(ks, ",")
end

--- The whole projection as one comparable string: every node in order with its
--- flags, region and edges, plus the per-commit mode map.
local function proj_dump(p)
    local out = {}
    for i, it in ipairs(p.items) do
        local n = it.commit
        local ps, cs = {}, {}
        for _, x in ipairs(n.parents or {}) do ps[#ps + 1] = x.hash end
        for _, x in ipairs(n.children or {}) do cs[#cs + 1] = x.hash end
        out[#out + 1] = ("%d %s c=%s j=%s n=%s reg=[%s] sig=[%s] p=[%s] k=[%s]"):format(
            i, tostring(n.hash), tostring(n.collapsed), tostring(n.junction), tostring(n.count),
            table.concat(n.region or {}, "+"), set_sig(n.signature),
            table.concat(ps, ","), table.concat(cs, ","))
    end
    local modes = {}
    for hash, m in pairs(p.mode) do modes[#modes + 1] = hash .. "=" .. m end
    table.sort(modes)
    out[#out + 1] = table.concat(modes, " ")
    return table.concat(out, "\n")
end

----------------------------------------------------------------------

describe("sigset — the interned set", function()
    local owners = {}
    for i = 1, 200 do owners[i] = { id = "o" .. i } end

    it("singletons are distinct and members round-trip", function()
        local u = sigset.universe(owners)
        assert.same({ o1 = true }, u:members(u:singleton("o1")))
        assert.same({ o200 = true }, u:members(u:singleton("o200")))
        assert.is_nil(u:singleton("nope"))
        assert.same({}, u:members(nil))
    end)

    it("a set has ONE representation, whatever order it was built in", function()
        local u = sigset.universe(owners)
        local a = u:union(u:union(u:singleton("o5"), u:singleton("o70")), u:singleton("o130"))
        local b = u:union(u:singleton("o130"), u:union(u:singleton("o70"), u:singleton("o5")))
        assert.is_true(a == b, "equal sets must be the same interned node")
        local c = u:union(a, u:singleton("o6"))
        assert.is_false(a == c)
    end)

    it("union and intersect agree with plain set operations", function()
        local u = sigset.universe(owners)
        local a, b = nil, nil
        local ea, eb = {}, {}
        for i = 1, 200, 3 do
            a = u:union(a, u:singleton("o" .. i)); ea["o" .. i] = true
        end
        for i = 1, 200, 2 do
            b = u:union(b, u:singleton("o" .. i)); eb["o" .. i] = true
        end
        local eu, ei = {}, {}
        for k in pairs(ea) do eu[k] = true end
        for k in pairs(eb) do eu[k] = true; if ea[k] then ei[k] = true end end
        assert.same(eu, u:members(u:union(a, b)))
        assert.same(ei, u:members(u:intersect(a, b)))
        assert.is_nil(u:intersect(a, nil))
        assert.is_true(u:union(a, nil) == a)
    end)

    it("summary ORs the per-owner flags, memoised per node", function()
        local u = sigset.universe(owners)
        local flags, memo = {}, {}
        for i = 0, 199 do flags[i] = 0 end -- everything hidden
        flags[u.idx.o9] = 1                -- collapsed
        flags[u.idx.o40] = 3               -- normal
        local hidden = u:union(u:singleton("o1"), u:singleton("o2"))
        local collapsed = u:union(hidden, u:singleton("o9"))
        local normal = u:union(collapsed, u:singleton("o40"))
        assert.equals(0, u:summary(nil, flags, memo))
        assert.equals(0, u:summary(hidden, flags, memo))
        assert.equals(1, u:summary(collapsed, flags, memo))
        assert.equals(3, u:summary(normal, flags, memo))
    end)

    it("seal releases the scaffolding but keeps the built sets readable", function()
        local u = sigset.universe(owners)
        local a = u:union(u:singleton("o3"), u:singleton("o99"))
        local b = u:singleton("o150")
        local before = u:nodes()
        local flags, memo = {}, {}
        for i = 0, 199 do flags[i] = 1 end
        u:seal()
        assert.same({ o3 = true, o99 = true }, u:members(a))
        assert.equals(1, u:summary(a, flags, memo))
        assert.equals(before, u:nodes())
        -- Building again after the seal would mint a SECOND node for a set that
        -- already has one, breaking "equal sets are the same node".
        assert.has_error(function() u:union(a, b) end)
        assert.has_error(function() u:intersect(a, b) end)
        assert.has_error(function() u:singleton("o1") end)
    end)

    it("view.signatures hands back a sealed universe", function()
        local items = h.dag(merge_trunk(4))
        local S = sigset.of(view.signatures(items, focus_owners(items)))
        assert.is_not_nil(S)
        assert.is_true(S and S.universe.sealed or false)
    end)

    it("sigset.of finds the interned form only behind view.signatures", function()
        local items = h.dag(merge_trunk(4))
        assert.is_not_nil(sigset.of(view.signatures(items, focus_owners(items))))
        assert.is_nil(sigset.of({ abc = { x = true } }))
        assert.is_nil(sigset.of(nil))
    end)
end)

describe("view.signatures — parity with the reference pass (§10.2)", function()
    it("gives the same set for every commit, over the whole corpus", function()
        local commits, diffs = 0, {}
        for _, case in ipairs(corpus()) do
            for _, mk in ipairs({ focus_owners, mixed_owners }) do
                local items = h.dag(case.rows)
                local owners = mk(items)
                local got = view.signatures(items, owners)
                local want = h.reference_signatures(items, owners)
                for _, it in ipairs(items) do
                    local hash = it.commit.hash
                    commits = commits + 1
                    if set_sig(got[hash]) ~= set_sig(want[hash]) then
                        diffs[#diffs + 1] = ("%s %s: %s vs %s"):format(
                            case.name, hash, set_sig(got[hash]), set_sig(want[hash]))
                    end
                end
            end
        end
        assert.is_true(commits > 1500, ("thin corpus: %d commits"):format(commits))
        assert.equals(0, #diffs, table.concat(diffs, "\n"))
    end)

    it("keeps the uncovered-commit distinction: {} for in-set, nil for unknown", function()
        local items = h.dag({ { "a", { "b" } }, { "b", {} } })
        local sig = view.signatures(items, {})
        assert.same({}, sig.a)
        assert.same({}, sig.b)
        assert.is_nil(sig.nosuchhash)
    end)
end)

describe("view.project — parity with the pre-interning path (§10.2/§10.3)", function()
    it("projects identically from an interned and a materialised signature map", function()
        local diffs, cases = {}, 0
        for _, case in ipairs(corpus()) do
            for _, mk in ipairs({ focus_owners, mixed_owners }) do
                local a_items = h.dag(case.rows)
                local a_owners = mk(a_items)
                local a = view.project(a_items, a_owners) -- interned (computes its own)
                local b_items = h.dag(case.rows)
                local b_owners = mk(b_items)
                -- A plain table of sets: view.project takes its pre-interning path.
                local b = view.project(b_items, b_owners,
                    h.reference_signatures(b_items, b_owners))
                cases = cases + 1
                if proj_dump(a) ~= proj_dump(b) then
                    diffs[#diffs + 1] = ("%s\n--- interned ---\n%s\n--- reference ---\n%s"):format(
                        case.name, proj_dump(a), proj_dump(b))
                end
            end
        end
        assert.is_true(cases > 80, ("thin corpus: %d cases"):format(cases))
        assert.equals(0, #diffs, diffs[1] or "")
    end)

    it("lays out identically, cell for cell, over every style x policy", function()
        local lines, diffs = 0, {}
        for _, case in ipairs(corpus()) do
            for _, st in ipairs(STYLES) do
                for _, pol in ipairs(POLICIES) do
                    local opts = h.big_opts(st.s)
                    opts.layout_policy = pol
                    local a_items = h.dag(case.rows)
                    local a_owners = focus_owners(a_items)
                    local a = columns.layout(opts, view.project(a_items, a_owners).items)
                    local b_items = h.dag(case.rows)
                    local b_owners = focus_owners(b_items)
                    local b = columns.layout(opts, view.project(b_items, b_owners,
                        h.reference_signatures(b_items, b_owners)).items)
                    if #a ~= #b then
                        diffs[#diffs + 1] = ("%s %s/%s: %d vs %d rows"):format(
                            case.name, st.name, pol, #a, #b)
                    else
                        for i = 1, #a do
                            lines = lines + 1
                            if h.row_sig(a[i]) ~= h.row_sig(b[i]) then
                                diffs[#diffs + 1] = ("%s %s/%s row %d\n%s\n%s"):format(
                                    case.name, st.name, pol, i, h.row_sig(a[i]), h.row_sig(b[i]))
                            end
                        end
                    end
                end
            end
        end
        assert.is_true(lines > 18000, ("thin corpus: %d rows"):format(lines))
        assert.equals(0, #diffs, diffs[1] or "")
    end)
end)

describe("view.signatures — the sets are shared, not materialised (§10.2)", function()
    it("a merge trunk costs O(commits) nodes where the sets hold O(commits^2) entries", function()
        local N = 120 -- 120 trunk merges => 239 commits, ~420 owners
        local items = h.dag(merge_trunk(N))
        local owners = focus_owners(items)
        local sig = view.signatures(items, owners)
        local S = sigset.of(sig)
        assert.is_not_nil(S)

        -- What the materialised form would hold.
        local entries = 0
        local biggest = 0
        for _, it in ipairs(items) do
            local n = 0
            for _ in pairs(sig[it.commit.hash]) do n = n + 1 end
            entries = entries + n
            if n > biggest then biggest = n end
        end
        -- The quadratic really is there: the oldest trunk commit is reached by an
        -- owner per merge above it.
        assert.is_true(biggest >= N,
            ("expected a signature of >= %d owners, biggest was %d"):format(N, biggest))
        assert.is_true(entries > N * N / 4,
            ("expected > %d materialised entries, got %d"):format(N * N / 4, entries))

        -- What is actually stored. The trie is depth ceil(log32(owners)) and each
        -- added owner allocates one node per level, so the bound is linear in the
        -- commits with a small constant — nothing like `entries`.
        local nodes = S and S.universe:nodes() or 0
        assert.is_true(nodes < 8 * #items,
            ("expected < %d interned nodes, got %d"):format(8 * #items, nodes))
        assert.is_true(nodes * 8 < entries,
            ("interning bought nothing: %d nodes vs %d entries"):format(nodes, entries))
    end)

    it("indexing the map does not accumulate the materialised sets", function()
        local items = h.dag(merge_trunk(60))
        local sig = view.signatures(items, focus_owners(items))
        local hash = items[#items].commit.hash
        local a, b = sig[hash], sig[hash]
        assert.same(a, b)
        assert.is_false(rawequal(a, b), "a materialised set must not be cached on the map")
        assert.is_nil(rawget(sig, hash))
    end)
end)
