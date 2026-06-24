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
end)

describe("sel_ascend_children (§13.3)", function()
    it("puts first-parent children first, then the rest in edge order", function()
        -- base has children x (base is x's first parent) and m (base is m's 2nd
        -- parent). Only x continues the first-parent line.
        local g = graph({ x = { "base" }, m = { "other", "base" }, other = {}, base = {} })
        local kids = sel_ascend_children(g.base)
        assert.same({ "x", "m" }, hashes(kids))
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
