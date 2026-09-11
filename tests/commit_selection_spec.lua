--- Tests for the commit-selection (range) pure helpers (spec §13):
--- range_endpoints (DiffRange from the selection's real endpoints, §13.5) and the
--- path walking sel_ascend_children / sel_step / sel_switch (§13.2/§13.3).
--- These operate only on the DisplayNode graph (.parents first = trunk,
--- .children, .hash), so they need no Neovim runtime.

local internal = require("gitloom.graph")._internal
local range_endpoints = internal.range_endpoints
local sel_ascend_children = internal.sel_ascend_children
local sel_step = internal.sel_step
local sel_switch = internal.sel_switch
local format_range_detail = internal.format_range_detail

local EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

-- Build a graph of plain DisplayNode-like tables from an edge spec. `parents` maps
-- a node name to its parent names (first = trunk); children are the inverse, in
-- first-occurrence order. Returns name -> node.
local function graph(parents)
    local nodes = {}
    local function node(name)
        if not nodes[name] then nodes[name] = { hash = name, parents = {}, children = {} } end
        return nodes[name]
    end
    -- Stable order: sort the parent map keys so children lists are deterministic.
    local names = {}
    for name in pairs(parents) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local n = node(name)
        for _, pname in ipairs(parents[name]) do
            local p = node(pname)
            n.parents[#n.parents + 1] = p
            p.children[#p.children + 1] = n
        end
    end
    return nodes
end

local function hashes(path)
    local out = {}
    for _, n in ipairs(path) do out[#out + 1] = n.hash end
    return out
end

local function state(start)
    return { path = { start }, anchor = start, cursor = start, dparent = {}, dchild = {} }
end

describe("range_endpoints (§13.5)", function()
    it("a single commit is exactly commit_range (X^!)", function()
        local p1 = { hash = "P1" }
        local c = { hash = "C", parents = { p1 } }
        local r = range_endpoints(c, c)
        assert.equals("C^!", r.rev)
        assert.equals(p1, r.from)
        assert.equals(c, r.to)
    end)

    it("a span is <older>^..<newer>", function()
        local base = { hash = "BASE" }
        local newer = { hash = "NEW" }
        local older = { hash = "OLD", parents = { base } }
        local r = range_endpoints(newer, older)
        assert.equals("BASE..NEW", r.rev)
        assert.equals(base, r.from)
        assert.equals(newer, r.to)
    end)

    it("a span whose older end is a root uses the empty tree", function()
        local newer = { hash = "NEW" }
        local root = { hash = "ROOT", parents = {} }
        local r = range_endpoints(newer, root)
        assert.equals(EMPTY_TREE .. "..NEW", r.rev)
        assert.is_nil(r.from)
        assert.equals(newer, r.to)
    end)
end)

-- §4.2/§13.5: a range whose NEWER end is a working-tree virtual commit denotes a
-- TREE STATE, not a commit. Its hash is a reserved sentinel, so it must never
-- appear in `rev`, and `rev` must be a SINGLE rev -- that is what makes the diff
-- provider open the real on-disk files (LSP attaches) instead of read-only blobs.
describe("range_endpoints to the working tree (§13.5)", function()
    -- HEAD <- staged <- unstaged <- untracked, the §4.2 stack, plus a real BASE
    -- under HEAD so a span has somewhere to start from.
    local function stack()
        local base = { hash = "BASE" }
        local head = { hash = "HEADC", parents = { base } }
        local staged = { hash = "0000000000000000000000000000000000000001",
            virtual = "staged", parents = { head } }
        local unstaged = { hash = "0000000000000000000000000000000000000000",
            virtual = "unstaged", parents = { staged } }
        local untracked = { hash = "0000000000000000000000000000000000000002",
            virtual = "untracked", parents = { unstaged } }
        return base, head, staged, unstaged, untracked
    end

    it("a staged newer end is `--cached <base>` to the index", function()
        local base, head, staged = stack()
        local r = range_endpoints(staged, head)
        assert.equals("--cached BASE", r.rev)
        assert.equals(base, r.from)
        assert.equals("index", r.to)
        assert.is_nil(r.untracked)
    end)

    it("an unstaged newer end is the bare base rev, to the working tree", function()
        local base, head, _, unstaged = stack()
        local r = range_endpoints(unstaged, head)
        assert.equals("BASE", r.rev)
        assert.equals(base, r.from)
        assert.equals("worktree", r.to)
        assert.is_nil(r.untracked)
    end)

    it("an untracked newer end is the same range, flagged for the synthesized additions", function()
        local base, head, _, _, untracked = stack()
        local r = range_endpoints(untracked, head)
        assert.equals("BASE", r.rev)
        assert.equals(base, r.from)
        assert.equals("worktree", r.to)
        assert.is_true(r.untracked)
    end)

    -- The invariant, stated directly: whatever the shape, no sentinel hash is in
    -- the rev and no `..` span is emitted.
    it("never puts a sentinel hash in the rev, and never emits a span", function()
        local _, head, staged, unstaged, untracked = stack()
        for _, newer in ipairs({ staged, unstaged, untracked }) do
            local r = range_endpoints(newer, head)
            assert.is_nil(r.rev:find("0000000", 1, true))
            assert.is_nil(r.rev:find("..", 1, true))
            assert.is_true(r.to == "index" or r.to == "worktree")
        end
    end)

    -- A deeper span still bases on the OLDER end's first parent, exactly as a
    -- commit span does -- only the head becomes a tree state.
    it("bases on the older end's first parent, not on HEAD", function()
        local base = { hash = "BASE" }
        local head = { hash = "HEADC", parents = { base } }
        local older = { hash = "OLD", parents = { { hash = "OLDPARENT" } } }
        local unstaged = { hash = "0000000000000000000000000000000000000000",
            virtual = "unstaged", parents = { head } }
        assert.equals("OLDPARENT", range_endpoints(unstaged, older).rev)
    end)

    it("uses the empty tree when the older end is a root", function()
        local root = { hash = "ROOT", parents = {} }
        local unstaged = { hash = "0000000000000000000000000000000000000000",
            virtual = "unstaged", parents = { root } }
        local r = range_endpoints(unstaged, root)
        -- newer ~= older, so this is the span path with a rootless base.
        assert.equals(EMPTY_TREE, r.rev)
        assert.is_nil(r.from)
        assert.equals("worktree", r.to)
    end)

    -- Both ends inside the worktree stack: the older end's first parent is
    -- itself virtual, so the base is ITS tree state -- never its sentinel hash.
    it("resolves a virtual base to its own tree state", function()
        local _, _, staged, unstaged, untracked = stack()
        local r = range_endpoints(untracked, unstaged)
        assert.equals("", r.rev) -- the provider's own default: working tree vs index
        assert.equals("index", r.from) -- unstaged's parent is the staged node
        assert.equals("worktree", r.to)
        assert.is_true(r.untracked)
        -- and the staged node's own parent is the real HEAD commit
        local r2 = range_endpoints(untracked, staged)
        assert.equals("HEADC", r2.rev)
    end)
end)

describe("format_range_detail (§13.5)", function()
    local function texts(rows)
        local out = {}
        for _, r in ipairs(rows) do out[#out + 1] = r.text end
        return out
    end

    it("lists a single commit with a count and no range", function()
        local rows = format_range_detail({ { hash = "abcdef123", message = "Only commit" } }, {})
        assert.same({ "1 commit", "", "abcdef1  Only commit" }, texts(rows))
    end)

    it("summarises a span as oldest..newest and lists newest-first", function()
        local rows = format_range_detail({
            { hash = "1111111aaa", message = "newest" },
            { hash = "2222222bbb", message = "middle" },
            { hash = "3333333ccc", message = "oldest" },
        }, {})
        assert.same({
            "3 commits  (3333333..1111111)",
            "",
            "1111111  newest",
            "2222222  middle",
            "3333333  oldest",
        }, texts(rows))
    end)

    -- §4.2/§13.5: a working-tree node on the path has no hash and no subject, so
    -- its row is synthesized. The id cell must NOT be its sentinel hash (which
    -- would read as a real object name) and the text must be `worktree_label`'s,
    -- the same wording the graph row and the §11.8 header use.
    it("synthesizes a row for a working-tree node instead of showing its sentinel", function()
        local rows = format_range_detail({
            { hash = "0000000000000000000000000000000000000000",
                virtual = "unstaged", wt = { changed = 3 } },
            { hash = "1111111aaa", message = "newest real" },
            { hash = "3333333ccc", message = "oldest" },
        }, {})
        assert.same({
            "3 commits  (3333333..working)",
            "",
            "working  Unstaged changes · 3 files",
            "1111111  newest real",
            "3333333  oldest",
        }, texts(rows))
    end)

    it("names each working-tree state the way the graph row does", function()
        local function one(virtual, changed)
            local rows = format_range_detail({
                { hash = "0000000000000000000000000000000000000002",
                    virtual = virtual, wt = { changed = changed } },
            }, {})
            return texts(rows)[3]
        end
        assert.equals("working  Staged changes · 1 file", one("staged", 1))
        assert.equals("working  Unstaged changes · 2 files", one("unstaged", 2))
        assert.equals("working  Untracked files · 5 files", one("untracked", 5))
    end)
end)

describe("sel_ascend_children (§13.3)", function()
    it("puts first-parent children first, then the rest in edge order", function()
        -- base has children x (base is x's first parent) and m (base is m's 2nd
        -- parent). Only x continues the first-parent line.
        local g = graph({ x = { "base" }, m = { "other", "base" }, other = {}, base = {} })
        local kids = sel_ascend_children(g.base)
        assert.same({ "x", "m" }, hashes(kids))
    end)

    -- §4.2/§13.2: the working-tree nodes ARE selectable, as the newer end. They
    -- are children of HEAD, so `k` from HEAD must walk into them. Their sentinel
    -- hashes never reach a git rev because `range_endpoints` maps a virtual newer
    -- end to a tree state (§13.5) -- the walk needs no guard of its own.
    it("ascends into a working-tree virtual commit", function()
        local g = graph({ wt = { "head" }, x = { "head" }, head = {} })
        g.wt.virtual = "unstaged"
        local kids = sel_ascend_children(g.head)
        assert.same({ "wt", "x" }, hashes(kids))
    end)

    it("reaches the virtual node when it is HEAD's only child", function()
        local g = graph({ wt = { "head" }, head = {} })
        g.wt.virtual = "staged"
        assert.same({ "wt" }, hashes(sel_ascend_children(g.head)))
    end)

    -- The whole worktree stack is walkable: HEAD -> staged -> unstaged ->
    -- untracked, and the ascent clamps on its own at the top because a virtual
    -- commit has no children (§4.2). That is what makes it the path's NEWEST
    -- member by construction rather than by a rule.
    it("walks the whole worktree stack and clamps at its top", function()
        local g = graph({ untracked = { "unstaged" }, unstaged = { "staged" },
            staged = { "head" }, head = {} })
        g.staged.virtual, g.unstaged.virtual, g.untracked.virtual =
            "staged", "unstaged", "untracked"
        assert.same({ "staged" }, hashes(sel_ascend_children(g.head)))
        assert.same({ "unstaged" }, hashes(sel_ascend_children(g.staged)))
        assert.same({ "untracked" }, hashes(sel_ascend_children(g.unstaged)))
        assert.same({}, hashes(sel_ascend_children(g.untracked)))
    end)

    it("leaves an ordinary child with a commit field alone", function()
        local g = graph({ x = { "head" }, head = {} })
        g.x.commit = { hash = "x" } -- a real commit, no `virtual`
        assert.same({ "x" }, hashes(sel_ascend_children(g.head)))
    end)
end)

describe("sel_step (§13.2)", function()
    -- a -> b -> c -> d (a newest, d the root)
    local function chain()
        return graph({ a = { "b" }, b = { "c" }, c = { "d" }, d = {} })
    end

    it("extends downward along first parents and clamps at the root", function()
        local g = chain()
        local st = state(g.b)
        sel_step(st, "down")
        assert.same({ "b", "c" }, hashes(st.path))
        assert.equals(g.c, st.cursor)
        sel_step(st, "down")
        assert.same({ "b", "c", "d" }, hashes(st.path))
        sel_step(st, "down") -- d is a root: no-op
        assert.same({ "b", "c", "d" }, hashes(st.path))
        assert.equals(g.d, st.cursor)
    end)

    it("contracts from the moving end, then flips direction at the anchor", function()
        local g = chain()
        local st = { path = { g.b, g.c, g.d }, anchor = g.b, cursor = g.d, dparent = {}, dchild = {} }
        sel_step(st, "up") -- contract the bottom
        assert.same({ "b", "c" }, hashes(st.path))
        assert.equals(g.c, st.cursor)
        sel_step(st, "up") -- contract to a single commit
        assert.same({ "b" }, hashes(st.path))
        assert.equals(g.b, st.cursor)
        sel_step(st, "up") -- now grow upward (b's child is a)
        assert.same({ "a", "b" }, hashes(st.path))
        assert.equals(g.a, st.cursor)
        sel_step(st, "down") -- cursor at the top end: contract back
        assert.same({ "b" }, hashes(st.path))
        assert.equals(g.b, st.cursor)
    end)
end)

describe("sel_switch (§13.3)", function()
    -- diamond: m merges x (first parent) and y, both over base.
    local function diamond()
        return graph({ m = { "x", "y" }, x = { "base" }, y = { "base" }, base = {} })
    end

    it("rotates the parent at the nearest merge while growing down", function()
        local g = diamond()
        local st = state(g.m)
        sel_step(st, "down") -- follows x (first parent)
        sel_step(st, "down")
        assert.same({ "m", "x", "base" }, hashes(st.path))
        local switched = sel_switch(st, 1) -- rotate m's parent x -> y
        assert.is_true(switched)
        assert.same({ "m", "y", "base" }, hashes(st.path))
        assert.equals(g.base, st.cursor)
    end)

    it("rotates the child at the nearest split while growing up", function()
        local g = diamond()
        local st = state(g.base)
        sel_step(st, "up") -- ascends into x (first first-parent child)
        sel_step(st, "up")
        assert.same({ "m", "x", "base" }, hashes(st.path))
        local switched = sel_switch(st, 1) -- rotate base's child x -> y
        assert.is_true(switched)
        assert.same({ "m", "y", "base" }, hashes(st.path))
        assert.equals(g.m, st.cursor)
    end)

    it("is a no-op on a linear path", function()
        local g = graph({ a = { "b" }, b = { "c" }, c = {} })
        local st = state(g.a)
        sel_step(st, "down")
        sel_step(st, "down") -- {a,b,c}, no junction
        assert.is_false(sel_switch(st, 1))
        assert.same({ "a", "b", "c" }, hashes(st.path))
    end)
end)

--- The range view's git-failure line (§13.5). `fetch_range_diff` resolves a
--- `git_code` result rather than a bare patch string precisely so a failing
--- `git diff` cannot arrive as an empty patch; `format_git_error` is the pure
--- piece that turns that result into the one line the view shows in place of the
--- diff (and into the notification text). Guards the regression where a non-zero
--- exit was swallowed and a broken spawn rendered as "no changes in this range".
describe("format_git_error (§13.5)", function()
    local format_git_error = require("gitloom.git.format").format_git_error

    it("names the command and the exit code", function()
        assert.equals("git diff failed (exit 128)",
            format_git_error("git diff", { code = 128, out = "", err = "" }))
    end)

    it("appends git's own stderr, which is the useful part", function()
        assert.equals(
            "git diff failed (exit 128): fatal: bad object 000000000000000000000000000000000000dead",
            format_git_error("git diff", {
                code = 128,
                out = "",
                err = "fatal: bad object 000000000000000000000000000000000000dead",
            }))
    end)

    it("keeps only the first stderr line — the message is one row", function()
        assert.equals("git diff failed (exit 1): fatal: first",
            format_git_error("git diff", { code = 1, out = "", err = "fatal: first\nsecond\nthird" }))
    end)

    it("strips a trailing CR from git's stderr (Windows)", function()
        assert.equals("git diff failed (exit 128): fatal: bad object",
            format_git_error("git diff", { code = 128, out = "", err = "fatal: bad object\r\n" }))
    end)

    it("reports an unspawnable job as exit -1", function()
        assert.equals("git diff failed (exit -1)", format_git_error("git diff", nil))
        assert.equals("git diff failed (exit -1)",
            format_git_error("git diff", { code = -1, out = "", err = "" }))
    end)
end)
