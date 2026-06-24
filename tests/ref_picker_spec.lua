--- Tests for the ref-picker pure pieces (spec §2, `<leader>b`): `bump_recent`
--- (the session MRU list) and `ref_picker_items` (refs → ordered picker entries,
--- recent-first then grouped HEAD / local / remote / tag).

local internal = require("gitloom.graph")._internal
local bump_recent = internal.bump_recent
local ref_picker_items = internal.ref_picker_items
local ref_decoration_index = internal.ref_decoration_index

-- A minimal Ref: name + kind + a commit carrying the hash/message the picker
-- reads. (The real Ref.commit is a Commit object; only these fields matter here.)
local function ref(name, kind, hash, message)
    return { name = name, kind = kind, commit = { hash = hash, message = message } }
end

-- name -> Ref registry (like repo.refs).
local function registry(...)
    local refs = {}
    for _, r in ipairs({ ... }) do refs[r.name] = r end
    return refs
end

-- The names of an item list, in order — the only thing ordering tests assert on.
local function names(items)
    local out = {}
    for _, it in ipairs(items) do out[#out + 1] = it.name end
    return out
end

describe("bump_recent", function()
    it("pushes a new name to the front, keeping the rest in order", function()
        assert.same({ "b", "a" }, bump_recent({ "a" }, "b"))
        assert.same({ "c", "b", "a" }, bump_recent({ "b", "a" }, "c"))
    end)

    it("treats a nil list as empty", function()
        assert.same({ "a" }, bump_recent(nil, "a"))
    end)

    it("de-duplicates: a re-selected name moves to the front, appears once", function()
        assert.same({ "a", "c", "b" }, bump_recent({ "c", "a", "b" }, "a"))
        assert.same({ "b", "a" }, bump_recent({ "b", "a" }, "b"))
    end)

    it("does not mutate the input list", function()
        local list = { "a", "b" }
        bump_recent(list, "c")
        assert.same({ "a", "b" }, list)
    end)
end)

describe("ref_picker_items", function()
    it("builds an entry per ref with the fields the picker shows", function()
        local refs = registry(ref("master", "local", "deadbeefcafe1234", "Fix the bug\nbody"))
        local items = ref_picker_items(refs, {})
        assert.equals(1, #items)
        local it = items[1]
        assert.equals("master", it.name)
        assert.equals("local", it.kind)
        assert.equals("deadbeefcafe1234", it.hash)
        assert.equals("deadbeef", it.short) -- first 8 of the hash
        assert.equals("Fix the bug", it.subject) -- first line only
        assert.is_false(it.recent)
    end)

    it("skips refs with no resolved commit (nothing to jump to)", function()
        local refs = registry(ref("master", "local", "aaaa1111", "x"))
        refs["dangling"] = { name = "dangling", kind = "local", commit = nil }
        refs["sparse"] = { name = "sparse", kind = "local", commit = {} } -- no hash
        assert.same({ "master" }, names(ref_picker_items(refs, {})))
    end)

    it("orders the non-recent refs HEAD, local, remote, tag, then by name", function()
        local refs = registry(
            ref("v1.0", "tag", "t1", "tag"),
            ref("origin/master", "remote", "r1", "remote"),
            ref("zeta", "local", "l2", "local z"),
            ref("alpha", "local", "l1", "local a"),
            ref("HEAD", "head", "h1", "head"))
        assert.same(
            { "HEAD", "alpha", "zeta", "origin/master", "v1.0" },
            names(ref_picker_items(refs, {})))
    end)

    it("surfaces session-recent refs first, in MRU order, then the rest", function()
        local refs = registry(
            ref("HEAD", "head", "h1", "h"),
            ref("alpha", "local", "l1", "a"),
            ref("beta", "local", "l2", "b"),
            ref("v1.0", "tag", "t1", "t"))
        -- beta jumped to most recently, then v1.0.
        local items = ref_picker_items(refs, { "beta", "v1.0" })
        assert.same({ "beta", "v1.0", "HEAD", "alpha" }, names(items))
    end)

    it("flags recent entries via the `recent` field", function()
        local refs = registry(
            ref("HEAD", "head", "h1", "h"),
            ref("beta", "local", "l2", "b"))
        local items = ref_picker_items(refs, { "beta" })
        local flag = {}
        for _, it in ipairs(items) do flag[it.name] = it.recent end
        assert.is_true(flag["beta"])
        assert.is_false(flag["HEAD"])
    end)

    it("handles a nil recents list (all non-recent)", function()
        local refs = registry(ref("HEAD", "head", "h1", "h"), ref("alpha", "local", "l1", "a"))
        assert.same({ "HEAD", "alpha" }, names(ref_picker_items(refs, nil)))
    end)

    it("is empty for an empty registry", function()
        assert.same({}, ref_picker_items({}, {}))
        assert.same({}, ref_picker_items(nil, nil))
    end)
end)

describe("ref_decoration_index", function()
    -- A commit whose refs decoration_texts order is:
    --   1 (master ↑origin)  2 (feature/x)  3 [v1.0]   (HEAD has no decoration)
    local commit = {
        refs = {
            { kind = "local", name = "master" },
            { kind = "remote", name = "origin/master" },
            { kind = "local", name = "feature/x" },
            { kind = "tag", name = "v1.0" },
            { kind = "head", name = "HEAD" },
        },
    }

    it("maps a local branch to its branch-group index", function()
        assert.equals(1, ref_decoration_index(commit, "master", "local"))
        assert.equals(2, ref_decoration_index(commit, "feature/x", "local"))
    end)

    it("maps a remote ref to the shared branch group (short name)", function()
        assert.equals(1, ref_decoration_index(commit, "origin/master", "remote"))
    end)

    it("maps a tag to its index after the branch groups", function()
        assert.equals(3, ref_decoration_index(commit, "v1.0", "tag"))
    end)

    it("returns nil for HEAD (no own decoration)", function()
        assert.is_nil(ref_decoration_index(commit, "HEAD", "head"))
    end)

    it("returns nil for a ref the commit does not carry", function()
        assert.is_nil(ref_decoration_index(commit, "nope", "local"))
        assert.is_nil(ref_decoration_index({ refs = {} }, "master", "local"))
        assert.is_nil(ref_decoration_index(nil, "master", "local"))
    end)
end)
