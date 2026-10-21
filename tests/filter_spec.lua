--- Tests for the in-graph filter-search pure core (spec §16): the smartcase
--- substring matcher and keep-set builder (`smartcase_match` / `filter_keep`,
--- §16.2), and `view.project`'s `keep` set (§16.3) — matches stay normal commits
--- while the runs between them collapse, junctions preserved.

local graph = require("gitloom.graph")
local view = require("gitloom.graph.view")
local helpers = require("tests.graph_helpers")

local smartcase_match = graph._internal.smartcase_match
local filter_keep = graph._internal.filter_keep
local filter_state = graph._internal.filter_state

describe("smartcase_match (§16.2)", function()
    it("is case-insensitive for an all-lowercase needle", function()
        assert.is_true(smartcase_match("Fix the Bug", "bug"))
        assert.is_true(smartcase_match("FIX", "fix"))
    end)

    it("is case-sensitive when the needle has an uppercase letter", function()
        assert.is_true(smartcase_match("Fix the Bug", "Bug"))
        assert.is_false(smartcase_match("fix the bug", "Bug"))
    end)

    it("matches a literal substring, not a Lua pattern", function()
        assert.is_true(smartcase_match("rev a.b.c", "a.b.c"))
        assert.is_false(smartcase_match("rev axbxc", "a.b.c")) -- '.' is literal here
    end)

    it("an empty needle matches anything", function()
        assert.is_true(smartcase_match("whatever", ""))
    end)
end)

describe("filter_keep (§16.2/§16.3)", function()
    local commits = {
        { hash = "h1", message = "Fix login bug", author = "Alice" },
        { hash = "h2", message = "Add logout",    author = "Bob" },
        { hash = "h3", message = "Refactor auth", author = "alice smith" },
    }

    it("keeps commits whose subject matches", function()
        local keep = filter_keep(commits, "log")
        assert.is_true(keep.h1) -- "login"
        assert.is_true(keep.h2) -- "logout"
        assert.is_nil(keep.h3)
    end)

    it("keeps commits whose author matches", function()
        local keep = filter_keep(commits, "alice")
        assert.is_true(keep.h1) -- author Alice (smartcase)
        assert.is_true(keep.h3) -- author "alice smith"
        assert.is_nil(keep.h2)
    end)

    it("honours smartcase on the author", function()
        local keep = filter_keep(commits, "Alice")
        assert.is_true(keep.h1)  -- "Alice"
        assert.is_nil(keep.h3)   -- "alice smith" — uppercase needle, case-sensitive
    end)

    it("a blank or whitespace query matches nothing (caller drops the filter)", function()
        assert.same({}, filter_keep(commits, ""))
        assert.same({}, filter_keep(commits, "   "))
    end)

    it("trims surrounding whitespace from the query", function()
        local keep = filter_keep(commits, "  auth  ")
        assert.is_true(keep.h3)
    end)
end)

describe("filter_state (§16.4)", function()
    local commits = {
        { hash = "h1", message = "Fix login bug", author = "Alice" },
        { hash = "h2", message = "Add logout",    author = "Bob" },
    }

    -- Regression: `/` previewed the empty seed query as a real filter that
    -- matched nothing, contracting the whole graph before anything was typed.
    it("an empty or blank query is no filter (the graph is left unfiltered)", function()
        assert.is_nil(filter_state(commits, ""))
        assert.is_nil(filter_state(commits, "   "))
        assert.is_nil(filter_state(commits, nil))
    end)

    it("a non-blank query is the trimmed query and its keep set", function()
        local f = assert(filter_state(commits, "  log "))
        assert.equals("log", f.query)
        assert.same({ h1 = true, h2 = true }, f.keep)
    end)
end)

--- An all-collapsed owner over the whole chain, plus a keep set, is how the filter
--- projects (spec §16.3). Build owners pointing the single owner's tip at the
--- newest commit so every commit is collapsed-by-default.
local function project_filtered(rows, tip, keep)
    local items = helpers.dag(rows)
    local by_hash = {}
    for _, it in ipairs(items) do by_hash[it.commit.hash] = it.commit end
    local owners = { { id = "o", tip = by_hash[tip], mode = "collapsed" } }
    return view.project(items, owners, nil, keep), by_hash
end

describe("view.project — filter keep set (§16.3)", function()
    -- A linear chain A→B→C→D→E (newest→oldest); message == hash.
    local CHAIN = {
        { "A", { "B" } },
        { "B", { "C" } },
        { "C", { "D" } },
        { "D", { "E" } },
        { "E", {} },
    }

    local function nodes_by_hash(proj)
        local m = {}
        for _, n in ipairs(proj.nodes) do m[n.hash] = n end
        return m
    end

    it("keeps a matching commit as a normal node, collapsing the runs around it", function()
        local proj = project_filtered(CHAIN, "A", { C = true })
        local nodes = nodes_by_hash(proj)
        -- C is its own normal node (not collapsed, not a node-less junction).
        assert.is_not_nil(nodes.C)
        assert.is_false(nodes.C.collapsed)
        assert.is_false(nodes.C.junction)
        -- A and B are not their own nodes — they contracted into a head.
        assert.is_nil(nodes.A)
        assert.is_nil(nodes.B)
        -- Two collapsed heads: the {A,B} run above and the {D,E} run below.
        local heads = 0
        for _, n in ipairs(proj.nodes) do if n.collapsed then heads = heads + 1 end end
        assert.equals(2, heads)
    end)

    it("with no matches collapses the whole linear chain to one head", function()
        local proj = project_filtered(CHAIN, "A", {})
        local heads, reals = 0, 0
        for _, n in ipairs(proj.nodes) do
            if n.collapsed then heads = heads + 1 else reals = reals + 1 end
        end
        assert.equals(1, heads) -- one contracted run
        assert.equals(0, reals)
    end)

    it("keeps every match in a multi-match chain as its own node", function()
        local proj = project_filtered(CHAIN, "A", { B = true, D = true })
        local nodes = nodes_by_hash(proj)
        assert.is_false(nodes.B.collapsed)
        assert.is_false(nodes.D.collapsed)
        -- A (above B), C (between B and D), and E (below D) collapse: 3 heads.
        local heads = 0
        for _, n in ipairs(proj.nodes) do if n.collapsed then heads = heads + 1 end end
        assert.equals(3, heads)
    end)

    it("a nil keep set is the plain collapse (no matches kept)", function()
        local proj = project_filtered(CHAIN, "A", nil)
        for _, n in ipairs(proj.nodes) do
            -- nothing but the single contracted head
            assert.is_true(n.collapsed)
        end
    end)
end)
