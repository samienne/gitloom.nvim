--- The commit stream's worker hand-off (spec §3.1: "the view paints progressively").
---
--- `fetch_commits` drains its line queue `COMMIT_BATCH` at a time and reschedules
--- itself until the queue is empty. That only paints progressively if the main loop
--- actually gets to run between slices — and a `vim.schedule` self-chain does not let
--- it. A scheduled callback goes on nvim's *event* queue, which is drained to empty
--- before the loop iterates, so a worker that reschedules itself with `vim.schedule`
--- keeps the queue non-empty and nothing reaches the screen until the whole log has
--- been processed. That is why `next_tick` exists.
---
--- The observable used here is a **libuv idle handle**, which fires exactly once per
--- event-loop iteration. It discriminates the two hand-offs cleanly and, unlike
--- `SafeState`, it still fires while `vim.wait` is holding the loop — so the property
--- is testable from busted. (Measured the same way in a real main loop: a 60-step
--- `vim.schedule` chain produced 0 SafeState events, the timer chain produced 59.)

local fetch = require("gitloom.git.fetch")
local next_tick = fetch._internal.next_tick

--- Run a 20-step self-chain with the given hand-off and report how many event-loop
--- iterations happened while it ran.
---@param hand_off fun(fn: fun())
---@return integer steps, integer loop_iterations
local function chain(hand_off)
    local iterations = 0
    local idle = assert(vim.uv.new_idle())
    idle:start(function() iterations = iterations + 1 end)
    local n = 0
    local function step()
        n = n + 1
        -- a slice of real work, like one batch's parse + layout
        local a = vim.uv.hrtime()
        while (vim.uv.hrtime() - a) < 1e6 do end
        if n < 20 then hand_off(step) end
    end
    vim.schedule(step)
    vim.wait(3000, function() return n >= 20 end, 1)
    idle:stop()
    idle:close()
    return n, iterations
end

describe("stream worker hand-off (§3.1)", function()
    it("next_tick runs the callback later, never inline", function()
        local ran = false
        next_tick(function() ran = true end)
        assert.is_false(ran)
        vim.wait(1000, function() return ran end, 1)
        assert.is_true(ran)
    end)

    it("a next_tick self-chain lets the event loop iterate between slices", function()
        local steps, iterations = chain(next_tick)
        assert.equals(20, steps)
        -- one loop iteration per hand-off (19 of them), give or take scheduling
        assert.is_true(iterations >= 15,
            ("expected the loop to iterate between slices, saw %d"):format(iterations))
    end)

    it("a vim.schedule self-chain does NOT — the regression this guards", function()
        local steps, iterations = chain(vim.schedule)
        assert.equals(20, steps)
        -- the whole chain is drained inside a single pass of the event queue
        assert.is_true(iterations <= 2,
            ("expected the loop to be starved, saw %d iterations"):format(iterations))
    end)
end)
