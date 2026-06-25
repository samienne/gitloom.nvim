--- Tests for gitloom.navstack — the pure view-stack math (spec §14.3): browser-
--- history push/back/forward with forward-tail truncation, plus the breadcrumb
--- back-trail. Window/snacks-free, so it runs headless without snacks.

local navstack = require("gitloom.navstack")

-- A frame here is just a labelled handle; navstack treats it as opaque.
local function frame(name) return { kind = name } end
local function names(frames)
    local out = {}
    for i, f in ipairs(frames) do out[i] = f.kind end
    return out
end

describe("navstack (§14.3)", function()
    it("new seeds the root frame as the current one", function()
        local s = navstack.new(frame("graph"))
        assert.same({ "graph" }, names(s.frames))
        assert.equals(1, s.idx)
        assert.equals("graph", navstack.current(s).kind)
    end)

    it("push appends and makes the pushed frame current", function()
        local s = navstack.new(frame("graph"))
        local dropped = navstack.push(s, frame("commit"))
        assert.same({ "graph", "commit" }, names(s.frames))
        assert.equals(2, s.idx)
        assert.equals("commit", navstack.current(s).kind)
        assert.same({}, dropped) -- nothing ahead to drop
    end)

    it("back steps toward the root, clamping there", function()
        local s = navstack.new(frame("graph"))
        navstack.push(s, frame("commit"))
        assert.equals("graph", navstack.back(s).kind)
        assert.equals(1, s.idx)
        assert.is_nil(navstack.back(s)) -- already at root: no move
        assert.equals(1, s.idx)
    end)

    it("forward steps toward the tip, clamping there", function()
        local s = navstack.new(frame("graph"))
        navstack.push(s, frame("commit"))
        navstack.back(s)
        assert.equals("commit", navstack.forward(s).kind)
        assert.equals(2, s.idx)
        assert.is_nil(navstack.forward(s)) -- already at tip: no move
        assert.equals(2, s.idx)
    end)

    it("back then forward returns to the same tip frame", function()
        local s = navstack.new(frame("graph"))
        navstack.push(s, frame("commit"))
        local tip = navstack.current(s)
        navstack.back(s)
        assert.equals(tip, navstack.forward(s))
    end)

    it("push after back truncates the forward tail and reports it dropped", function()
        local s = navstack.new(frame("graph"))
        navstack.push(s, frame("commit"))     -- graph, commit
        navstack.push(s, frame("filtered"))   -- graph, commit, filtered
        navstack.back(s)                       -- back to commit (idx 2)
        local dropped = navstack.push(s, frame("other")) -- branch: drop "filtered"
        assert.same({ "graph", "commit", "other" }, names(s.frames))
        assert.equals(3, s.idx)
        assert.same({ "filtered" }, names(dropped))
    end)

    it("push from the root after going all the way back drops the whole tail", function()
        local s = navstack.new(frame("graph"))
        navstack.push(s, frame("a"))
        navstack.push(s, frame("b"))
        navstack.back(s); navstack.back(s) -- at root
        local dropped = navstack.push(s, frame("c"))
        assert.same({ "graph", "c" }, names(s.frames))
        assert.equals(2, s.idx)
        -- both a and b dropped (order is tip-first, unimportant — assert as a set)
        local set = {}
        for _, f in ipairs(dropped) do set[f.kind] = true end
        assert.same({ a = true, b = true }, set)
    end)

    it("crumbs is the back-trail (root → current), hiding the forward tail", function()
        local s = navstack.new(frame("graph"))
        navstack.push(s, frame("commit"))
        navstack.push(s, frame("filtered"))
        navstack.back(s) -- current is "commit"; "filtered" is ahead (hidden)
        assert.same({ "graph", "commit" },
            navstack.crumbs(s, function(f) return f.kind end))
    end)
end)
