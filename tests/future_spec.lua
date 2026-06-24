--- Tests for the vendored minimal promise (`make_future`, graph.lua; spec §3
--- streaming chains refs → head → commits → sort → worktree → reflow).
---
--- The key contract: a `.next` callback runs whether it is attached *before* or
--- *after* the future resolves. The already-resolved path was the bug behind the
--- "default collapse never applied" regression — a synchronously-resolved future
--- (the gitloom sort mode's `apply_sort`) dropped the callbacks chained onto it,
--- so the open-time worktree + reflow never ran.

local make_future = require("gitloom.graph")._internal.make_future

-- `.next`'s already-resolved path defers via `vim.schedule`; pump the loop so the
-- scheduled callbacks run before we assert.
local function flush()
    vim.wait(100, function() return false end)
end

describe("make_future (vendored promise; §3)", function()
    it("runs a callback attached BEFORE resolution", function()
        local f, p = make_future()
        local got
        f.next(function(v) got = v end)
        p.resolve("v")
        flush()
        assert.equals("v", got)
    end)

    it("runs a callback attached AFTER the future already resolved", function()
        local f, p = make_future()
        p.resolve("v")
        local got = "UNSET"
        f.next(function(v) got = v end)
        flush()
        assert.equals("v", got) -- regression: the callback was dropped
    end)

    it("chains values through .next on an already-resolved future", function()
        local f, p = make_future()
        p.resolve(1)
        local seen = {}
        f.next(function(v) seen[#seen + 1] = v; return v + 1 end)
            .next(function(v) seen[#seen + 1] = v end)
        flush()
        assert.same({ 1, 2 }, seen)
    end)

    it("flattens a future returned from a .next on an already-resolved future", function()
        local f, p = make_future()
        p.resolve("a")
        local got
        f.next(function()
            local inner, ip = make_future()
            vim.schedule(function() ip.resolve("inner") end)
            return inner
        end).next(function(v) got = v end)
        flush()
        assert.equals("inner", got)
    end)
end)
