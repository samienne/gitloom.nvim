--- Tests for gitloom's owned row ordering and the resync pure helpers
--- (specification.md §3.1 / §3.4).
---
--- `order_commits` is the topological sort that replaced `git log --topo-order`:
--- it is tested by **properties** (topological validity is the hard invariant),
--- plus the clustering bias (first-parent chains stay contiguous), the
--- author-date tiebreak among independent tips, determinism, and that it orders
--- only the given set (relationships to out-of-set commits are ignored).
---
--- `diff_ref_tips` and `reachable_hashes` are the resync (§3.4) pure pieces:
--- the ref add/remove/move classification, and the orphan-prune reachability.

local internal = require("gitloom.graph")._internal
local order_commits = internal.order_commits
local diff_ref_tips = internal.diff_ref_tips
local reachable_hashes = internal.reachable_hashes

-- Build a wired commit set from a compact spec. Each entry is
-- `{ "<hash>", { "<parent>", ... }, epoch }`. Parents referenced but not listed
-- as their own entry are created as **out-of-set** commits (no entry in the
-- returned list) so the "orders only the given set" property is testable.
-- Returns the in-set commit list (spec order) and the hash -> Commit map.
local function build(spec)
    local by = {}
    local function get(h)
        if not by[h] then
            by[h] = { hash = h, parents = {}, children = {}, refs = {} }
        end
        return by[h]
    end
    for _, s in ipairs(spec) do
        get(s[1]).date = { epoch = s[3] or 0 }
    end
    for _, s in ipairs(spec) do
        local c = get(s[1])
        for _, ph in ipairs(s[2] or {}) do
            local p = get(ph)
            table.insert(c.parents, p)
            table.insert(p.children, c)
        end
    end
    local list = {}
    for _, s in ipairs(spec) do list[#list + 1] = by[s[1]] end
    return list, by
end

-- Index of each commit hash in an ordered list.
local function index_of(ordered)
    local at = {}
    for i, c in ipairs(ordered) do at[c.hash] = i end
    return at
end

-- Assert child-before-parent for every in-set edge (the §3.1/§5 invariant).
local function assert_topological(commits, ordered)
    assert.equals(#commits, #ordered) -- nothing dropped or duplicated
    local seen = {}
    for _, c in ipairs(ordered) do
        assert.is_nil(seen[c.hash]) -- each commit exactly once
        seen[c.hash] = true
    end
    local in_set = {}
    for _, c in ipairs(commits) do in_set[c.hash] = true end
    local at = index_of(ordered)
    for _, c in ipairs(commits) do
        for _, p in ipairs(c.parents) do
            if in_set[p.hash] then
                assert.is_true(at[c.hash] < at[p.hash],
                    ("child %s must precede parent %s"):format(c.hash, p.hash))
            end
        end
    end
end

local function hashes(ordered)
    local out = {}
    for i, c in ipairs(ordered) do out[i] = c.hash end
    return out
end

describe("order_commits — topological validity (§3.1)", function()
    it("orders a linear chain child-first", function()
        local commits = build({
            { "c1", { "c2" }, 40 },
            { "c2", { "c3" }, 30 },
            { "c3", { "c4" }, 20 },
            { "c4", {}, 10 },
        })
        local ordered = order_commits(commits)
        assert_topological(commits, ordered)
        assert.same({ "c1", "c2", "c3", "c4" }, hashes(ordered))
    end)

    it("emits a merge before either parent, and the root last", function()
        -- m -> {a, b} -> base
        local commits = build({
            { "m", { "a", "b" }, 100 },
            { "a", { "base" }, 90 },
            { "b", { "base" }, 80 },
            { "base", {}, 10 },
        })
        local ordered = order_commits(commits)
        assert_topological(commits, ordered)
        assert.equals("m", ordered[1].hash)
        assert.equals("base", ordered[#ordered].hash)
    end)

    it("returns the same Commit objects (identity preserved)", function()
        local commits, by = build({
            { "c1", { "c2" }, 20 },
            { "c2", {}, 10 },
        })
        local ordered = order_commits(commits)
        assert.equals(by["c1"], ordered[1])
        assert.equals(by["c2"], ordered[2])
    end)

    it("handles empty and single-commit inputs", function()
        assert.same({}, order_commits({}))
        local one = build({ { "solo", {}, 5 } })
        assert.same({ "solo" }, hashes(order_commits(one)))
    end)
end)

describe("order_commits — clustering (§3.1 'continue the line of history')", function()
    it("keeps a merged-in side branch contiguous (first-parent chains cluster)", function()
        -- mainline m -> p1 -> base; feature f1 -> f2 -> base, merged at m.
        --   m   (merge, first parent p1, second parent f1)
        --   p1  (mainline)
        --   f1  (feature tip)
        --   f2  (feature)
        --   base (root)
        local commits = build({
            { "m", { "p1", "f1" }, 100 },
            { "p1", { "base" }, 90 },
            { "f1", { "f2" }, 80 },
            { "f2", { "base" }, 70 },
            { "base", {}, 10 },
        })
        local ordered = order_commits(commits)
        assert_topological(commits, ordered)
        local at = index_of(ordered)
        -- The mainline (m, p1) descends first as a block.
        assert.equals(1, at["m"])
        assert.equals(2, at["p1"])
        -- The feature commits stay adjacent (contiguous block, not interleaved).
        assert.equals(1, math.abs(at["f1"] - at["f2"]))
        -- base (shared root) comes after both branches.
        assert.equals(#ordered, at["base"])
    end)
end)

describe("order_commits — tiebreak + determinism (§3.1)", function()
    it("orders independent tips newest author-date first", function()
        local commits = build({
            { "older", {}, 100 },
            { "newer", {}, 200 },
        })
        assert.same({ "newer", "older" }, hashes(order_commits(commits)))
    end)

    it("breaks an equal-date tie by hash, deterministically", function()
        local commits = build({
            { "bbb", {}, 100 },
            { "aaa", {}, 100 },
        })
        local first = order_commits(commits)
        assert.same({ "aaa", "bbb" }, hashes(first))
        -- Same input -> identical output (no Math.random / hash-iteration order).
        assert.same(hashes(first), hashes(order_commits(commits)))
    end)
end)

describe("order_commits — orders only the given set (§3.1)", function()
    it("ignores parents outside the set (no extra rows)", function()
        -- c2's parent "c3" is referenced but never listed, so it is out of set.
        local commits = build({
            { "c1", { "c2" }, 20 },
            { "c2", { "c3" }, 10 },
        })
        local ordered = order_commits(commits)
        assert.same({ "c1", "c2" }, hashes(ordered))
    end)

    it("treats a commit with only out-of-set children as a ready tip", function()
        local _, by = build({
            { "child", { "parent" }, 20 },
            { "parent", {}, 10 },
        })
        -- Order just `parent`: its child is out of set, so it is a lone tip.
        local ordered = order_commits({ by["parent"] })
        assert.same({ "parent" }, hashes(ordered))
    end)
end)

describe("diff_ref_tips — ref add/remove/move (§3.4)", function()
    it("classifies added, removed, and moved refs", function()
        local old = { main = "h1", topic = "h2", gone = "h3" }
        local new = { main = "h1", topic = "h2x", added = "h4" }
        local d = diff_ref_tips(old, new)
        assert.same({ "added" }, d.added)
        assert.same({ "gone" }, d.removed)
        assert.same({ "topic" }, d.moved)
    end)

    it("reports nothing when the ref set is unchanged", function()
        local m = { main = "h1", dev = "h2" }
        local d = diff_ref_tips(m, { main = "h1", dev = "h2" })
        assert.same({}, d.added)
        assert.same({}, d.removed)
        assert.same({}, d.moved)
    end)
end)

describe("reachable_hashes — orphan prune reachability (§3.4)", function()
    it("collects everything reachable from the tips, excluding orphans", function()
        -- head -> mid -> root ; orphan -> root (orphan unreachable from head).
        local _, by = build({
            { "head", { "mid" }, 30 },
            { "mid", { "root" }, 20 },
            { "root", {}, 10 },
            { "orphan", { "root" }, 25 },
        })
        local seen = reachable_hashes(by, { "head" })
        assert.is_true(seen["head"])
        assert.is_true(seen["mid"])
        assert.is_true(seen["root"])
        assert.is_nil(seen["orphan"])
    end)

    it("unions reachability across multiple tips", function()
        local _, by = build({
            { "a", { "root" }, 30 },
            { "b", { "root" }, 20 },
            { "root", {}, 10 },
        })
        local seen = reachable_hashes(by, { "a", "b" })
        assert.is_true(seen["a"])
        assert.is_true(seen["b"])
        assert.is_true(seen["root"])
    end)

    it("walks parents given as raw hash strings", function()
        -- Pre-link shape: parents are hash strings, not Commit objects.
        local commits = {
            head = { hash = "head", parents = { "root" } },
            root = { hash = "root", parents = {} },
        }
        local seen = reachable_hashes(commits, { "head" })
        assert.is_true(seen["head"])
        assert.is_true(seen["root"])
    end)
end)
