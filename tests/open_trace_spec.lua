--- The open-path phase trace (`vim.g.gitloom_open_trace`; spec §10.8, README →
--- Diagnostics). The writer is the tested seam — the call sites in window.lua are
--- window glue, like every other diagnostic's.

local util = require("gitloom.util")

local function tmpfile()
    return vim.fn.tempname() .. "-open-trace.log"
end

local function read(path)
    if vim.fn.filereadable(path) ~= 1 then return {} end
    return vim.fn.readfile(path)
end

describe("open_trace (§10.8)", function()
    local path

    before_each(function()
        path = tmpfile()
        vim.g.gitloom_open_trace = nil
    end)

    after_each(function()
        vim.g.gitloom_open_trace = nil
        pcall(vim.fn.delete, path)
    end)

    it("is inert while the global is unset", function()
        util.open_trace("open", { repo = "x" })
        util.open_trace("signatures", { ms = 1 })
        assert.equals(0, vim.fn.filereadable(path))
        assert.is_false(util.open_tracing())
    end)

    it("is inert while the global is not a string", function()
        vim.g.gitloom_open_trace = true
        util.open_trace("open", { repo = "x" })
        assert.equals(0, vim.fn.filereadable(path))
        assert.is_false(util.open_tracing())
    end)

    it("appends one record per phase, with the fields in sorted key order", function()
        vim.g.gitloom_open_trace = path
        assert.is_true(util.open_tracing())
        util.open_trace("open", { repo = "/r" })
        util.open_trace("owners", { n = 12, merges = 7, ms = 3 })
        local lines = read(path)
        assert.equals(2, #lines)
        assert.is_not_nil(lines[1]:match("^0001 %+%d+ms open repo=/r$"))
        -- sorted keys: merges, ms, n
        assert.is_not_nil(lines[2]:match("^0002 %+%d+ms owners merges=7 ms=3 n=12$"))
    end)

    it("restarts the sequence and the clock on each `open`", function()
        vim.g.gitloom_open_trace = path
        util.open_trace("open", { repo = "/a" })
        util.open_trace("done", { ms = 1 })
        util.open_trace("open", { repo = "/b" })
        util.open_trace("done", { ms = 2 })
        local lines = read(path)
        assert.equals(4, #lines)
        assert.is_not_nil(lines[3]:match("^0001 %+%d+ms open repo=/b$"))
        assert.is_not_nil(lines[4]:match("^0002 "))
    end)

    it("records every phase name the open path emits", function()
        vim.g.gitloom_open_trace = path
        local phases = { "open", "refs", "batch", "stream", "sort", "owners",
            "signatures", "project", "layout", "pack", "apply", "done" }
        for _, p in ipairs(phases) do util.open_trace(p, { ms = 0 }) end
        local lines = read(path)
        assert.equals(#phases, #lines)
        for i, p in ipairs(phases) do
            assert.is_not_nil(lines[i]:match(" " .. p .. " "), p .. " missing from the trace")
        end
    end)

    it("open_ms measures forward from an open_now reading", function()
        local t = util.open_now()
        assert.is_true(util.open_ms(t) >= 0)
    end)

    it("does not disturb the pane trace's own sequence", function()
        local pane_path = tmpfile()
        vim.g.gitloom_pane_trace = pane_path
        vim.g.gitloom_open_trace = path
        util.pane_trace("maybe", { act = "repaint" })
        util.open_trace("open", { repo = "/r" })
        util.pane_trace("maybe", { act = "rebuild" })
        local pane = read(pane_path)
        vim.g.gitloom_pane_trace = nil
        pcall(vim.fn.delete, pane_path)
        assert.equals(2, #pane)
        -- Two traces, two counters: the open trace's reset must not renumber panes.
        local a = tonumber(pane[1]:match("^(%d+) "))
        local b = tonumber(pane[2]:match("^(%d+) "))
        assert.equals(1, b - a)
    end)
end)
