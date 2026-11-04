--- Tests for progress reporting (spec §19, `gitloom.progress`): the tracker over a
--- fake clock / timer and a recording sink — the show delay (an Op ended before it
--- reaches no provider at all), the idempotent end, `close()` sweeping live Ops
--- `cancelled`, a throwing provider leaving the caller unaffected, `false` being
--- inert; provider resolution (`"auto"` picks fidget iff it loads); the notify
--- provider's start / done rules per `own_notices` × outcome; and the fidget adapter
--- against a stubbed `fidget.progress` handle and — when fidget is in the lazy
--- install dir — the real one. The call sites in window.lua are window glue.

local progress = require("gitloom.progress")

-- A fake one-shot timer + clock: `fire()` runs every pending, uncancelled timer.
local function fake_deps(extra)
    local d = { t = 0, timers = {} }
    d.now = function() return d.t end
    d.defer = function(ms, fn)
        local tm = { ms = ms, fn = fn, cancelled = false }
        d.timers[#d.timers + 1] = tm
        return function() tm.cancelled = true end
    end
    d.fire = function()
        local ts = d.timers
        d.timers = {}
        for _, tm in ipairs(ts) do
            if not tm.cancelled then tm.fn() end
        end
    end
    d.fidget = function() return nil end
    d.notices = {}
    d.notify = function(msg, level) d.notices[#d.notices + 1] = { msg = msg, level = level } end
    for k, v in pairs(extra or {}) do d[k] = v end
    return d
end

-- A custom provider recording every call.
local function recorder()
    local r = { calls = {} }
    r.provider = {
        start = function(op)
            r.calls[#r.calls + 1] = { "start", op.title, op.message }
            return {
                report = function(m) r.calls[#r.calls + 1] = { "report", m } end,
                finish = function(o, m) r.calls[#r.calls + 1] = { "finish", o, m } end,
            }
        end,
    }
    return r
end

describe("progress tracker (§19.2/§19.4)", function()
    it("an Op ended before the delay never reaches the provider", function()
        local d, r = fake_deps(), recorder()
        local tr = progress.tracker({ provider = r.provider, delay = 300 }, d)
        local op = tr:start("Checking out main")
        op:report("x")
        op:finish("done")
        d.fire()
        assert.same({}, r.calls)
    end)

    it("arms the timer with the configured delay (default 300)", function()
        local d = fake_deps()
        progress.tracker({ provider = recorder().provider }, d):start("A")
        assert.equals(300, d.timers[1].ms)
        progress.tracker({ provider = recorder().provider, delay = 50 }, d):start("B")
        assert.equals(50, d.timers[2].ms)
    end)

    it("past the delay: start once with the latest message, then report, finish once", function()
        local d, r = fake_deps(), recorder()
        local tr = progress.tracker({ provider = r.provider }, d)
        local op = tr:start("Loading repo", { message = "refs" })
        op:report("120 commits")
        d.fire()
        op:report("sorting")
        op:finish("done")
        op:finish("failed")
        op:finish("cancelled")
        assert.same({
            { "start", "Loading repo", "120 commits" },
            { "report", "sorting" },
            { "finish", "done" },
        }, r.calls)
        assert.is_true(op.ended)
    end)

    it("delay 0 shows at once, with no timer", function()
        local d, r = fake_deps(), recorder()
        local op = progress.tracker({ provider = r.provider, delay = 0 }, d):start("Now")
        assert.equals(0, #d.timers)
        assert.same({ "start", "Now" }, r.calls[1])
        op:finish("failed", "boom")
        assert.same({ "finish", "failed", "boom" }, r.calls[2])
    end)

    it("an outcome defaults to done", function()
        local d, r = fake_deps(), recorder()
        local op = progress.tracker({ provider = r.provider, delay = 0 }, d):start("X")
        op:finish()
        assert.same({ "finish", "done" }, r.calls[2])
    end)

    it("close() ends every live Op cancelled, none twice, and later starts are inert", function()
        local d, r = fake_deps(), recorder()
        local tr = progress.tracker({ provider = r.provider }, d)
        local a = tr:start("A")
        local b = tr:start("B")
        local c = tr:start("C")
        c:finish("done") -- ended before the delay: never shown
        d.fire()         -- a and b shown
        tr:close()
        tr:close()
        a:finish("done") -- the job finishing after the close: harmless
        local finishes = 0
        for _, call in ipairs(r.calls) do
            if call[1] == "finish" then
                finishes = finishes + 1
                assert.equals("cancelled", call[2])
            end
        end
        assert.equals(2, finishes)
        assert.is_true(a.ended and b.ended)
        local late = tr:start("Late")
        d.fire()
        late:finish("done")
        assert.equals(2, finishes)
        assert.is_true(late.ended)
    end)

    it("an Op cancelled before its delay is not shown by a late timer", function()
        local d, r = fake_deps(), recorder()
        local tr = progress.tracker({ provider = r.provider }, d)
        tr:start("A")
        tr:close()
        d.fire()
        assert.same({}, r.calls)
    end)

    it("a throwing provider leaves the caller unaffected", function()
        local d = fake_deps()
        local bad_start = { start = function() error("nope") end }
        local op = progress.tracker({ provider = bad_start, delay = 0 }, d):start("A")
        assert.is_true(pcall(function() op:report("m"); op:finish("done") end))
        local bad_sink = { start = function()
            return { report = function() error("r") end, finish = function() error("f") end }
        end }
        local op2 = progress.tracker({ provider = bad_sink, delay = 0 }, d):start("B")
        assert.is_true(pcall(function() op2:report("m"); op2:finish("failed") end))
        assert.is_true(op2.ended)
    end)

    it("provider = false (and progress = false) is inert: no timer, no notice", function()
        for _, cfg in ipairs({ { provider = false }, false }) do
            local d = fake_deps()
            local op = progress.tracker(cfg, d):start("A")
            assert.equals(0, #d.timers)
            op:report("x")
            op:finish("done")
            d.fire()
            assert.same({}, d.notices)
        end
    end)

    it("normalize: nil → auto / 300, false → off, a negative delay clamps to 0", function()
        assert.same({ provider = "auto", delay = 300 }, progress.normalize(nil))
        assert.same({ provider = false, delay = 300 }, progress.normalize(false))
        assert.equals(0, progress.normalize({ delay = -5 }).delay)
        assert.equals("notify", progress.normalize({ provider = "notify" }).provider)
    end)
end)

describe("provider resolution (§19.3)", function()
    local function fake_fidget(log)
        return {
            handle = {
                create = function(msg)
                    log[#log + 1] = { "create", msg }
                    return {
                        report = function(_, props) log[#log + 1] = { "report", props.message } end,
                        finish = function() log[#log + 1] = { "finish" } end,
                        cancel = function() error("attempted to cancel non-cancellable progress") end,
                    }
                end,
            },
        }
    end

    it("auto picks fidget iff fidget.progress loads, re-checked per Op", function()
        local log, have = {}, false
        local d = fake_deps({ fidget = function() return have and fake_fidget(log) or nil end })
        local tr = progress.tracker({ provider = "auto", delay = 0 }, d)
        local a = tr:start("Loading repo")
        assert.is_false(a.fidget)
        assert.equals(1, #d.notices) -- the notify fallback's start notice
        have = true
        local b = tr:start("Loading repo")
        assert.is_true(b.fidget)
        assert.equals("create", log[1][1])
        assert.equals(1, #d.notices)
    end)

    it("fidget falls back to notify when fidget cannot load", function()
        local d = fake_deps()
        local op = progress.tracker({ provider = "fidget", delay = 0 }, d):start("Sorting by date")
        assert.is_false(op.fidget)
        assert.equals("gitloom: Sorting by date…", d.notices[1].msg)
    end)

    it("the fidget adapter: client gitloom, non-cancellable, finish() on every outcome", function()
        for _, outcome in ipairs({ "done", "failed", "cancelled" }) do
            local log = {}
            local d = fake_deps({ fidget = function() return fake_fidget(log) end })
            local tr = progress.tracker({ provider = "fidget" }, d)
            local op = tr:start("Fetching", { message = "origin", own_notices = true })
            op:report("still")
            d.fire()
            op:report("later")
            op:finish(outcome)
            local create = log[1]
            assert.equals("create", create[1])
            assert.equals("Fetching", create[2].title)
            assert.equals("still", create[2].message)
            assert.equals("gitloom", create[2].lsp_client.name)
            assert.is_false(create[2].cancellable)
            assert.same({ "report", "later" }, log[2])
            if outcome == "done" then
                assert.same({ { "finish" } }, { log[3] })
                assert.equals(3, #log)
            else
                assert.same({ "report", outcome }, log[3])
                assert.same({ "finish" }, log[4])
                assert.equals(4, #log)
            end
            assert.same({}, d.notices) -- fidget never notifies
        end
    end)
end)

describe("notify provider (§19.3)", function()
    local function run(own, outcome, show)
        local d = fake_deps()
        local tr = progress.tracker({ provider = "notify" }, d)
        local op = tr:start("Loading gitloom.nvim", { own_notices = own })
        op:report("120 commits")
        d.t = 1500
        if show then d.fire() end
        d.t = 2500
        op:finish(outcome)
        return d.notices
    end

    it("an Op without notices of its own: started, then done (N s) on success", function()
        local n = run(false, "done", true)
        assert.equals(2, #n)
        assert.equals("gitloom: Loading gitloom.nvim…", n[1].msg)
        assert.equals(vim.log.levels.INFO, n[1].level)
        assert.equals("gitloom: Loading gitloom.nvim — done (2.5 s)", n[2].msg)
    end)

    it("failed / cancelled add nothing after the start notice", function()
        for _, o in ipairs({ "failed", "cancelled" }) do
            local n = run(false, o, true)
            assert.equals(1, #n)
            assert.equals("gitloom: Loading gitloom.nvim…", n[1].msg)
        end
    end)

    it("an Op with its own notices gets neither a start nor a done notice", function()
        for _, o in ipairs({ "done", "failed", "cancelled" }) do
            assert.same({}, run(true, o, true))
        end
    end)

    it("ended before the delay: no start, and so no done", function()
        for _, own in ipairs({ true, false }) do
            assert.same({}, run(own, "done", false))
        end
    end)

    it("the running message is never notified", function()
        local d = fake_deps()
        local op = progress.tracker({ provider = "notify", delay = 0 }, d):start("Sorting by date")
        op:report("a"); op:report("b")
        assert.equals(1, #d.notices)
    end)

    -- §19.3 / §17.4: fetch / pull's live status through its own replaceable notice.
    local function notifier(ret)
        local calls = {}
        local f = function(msg, level, opts)
            calls[#calls + 1] = { msg = msg, level = level, opts = opts }
            return ret and ret(#calls) or nil
        end
        return f, calls
    end

    it("a notice passes one id, the previous handle as replace, and title gitloom", function()
        local f, calls = notifier(function(n) return { id = n } end)
        local notice = progress.notice(f)
        notice:show("gitloom: Fetching…")
        notice:show("gitloom: fetched", vim.log.levels.WARN)
        assert.equals(notice.id, calls[1].opts.id)
        assert.equals(notice.id, calls[2].opts.id)
        assert.is_nil(calls[1].opts.replace)
        assert.same({ id = 1 }, calls[2].opts.replace)
        assert.equals("gitloom", calls[2].opts.title)
        assert.equals(vim.log.levels.INFO, calls[1].level)
        assert.equals(vim.log.levels.WARN, calls[2].level)
        assert.is_true(notice.id ~= progress.notice(f).id)
    end)

    it("a replaceable notifier: the running message replaces the notice, at most once per second", function()
        local d = fake_deps()
        local f, calls = notifier(function(n) return n end)
        local notice = progress.notice(f)
        notice:show("gitloom: Fetching origin…")
        local op = progress.tracker({ provider = "notify" }, d):start("Fetching origin",
            { own_notices = true, notice = notice, message = "0:00 · waiting for the remote" })
        op:report("0:00 · waiting for the remote")
        assert.equals(1, #calls) -- before the delay: nothing
        d.t = 300
        d.fire()
        assert.equals(2, #calls)
        assert.equals("gitloom: Fetching origin 0:00 · waiting for the remote", calls[2].msg)
        assert.equals(1, calls[2].opts.replace)
        d.t = 900
        op:report("0:00 · remote: Counting objects")
        assert.equals(2, #calls) -- throttled
        d.t = 1300
        op:report("0:01 · Receiving objects: 10%")
        assert.equals(3, #calls)
        assert.equals("gitloom: Fetching origin 0:01 · Receiving objects: 10%", calls[3].msg)
        assert.same({}, d.notices) -- the provider's own notify is never used for it
        op:finish("done")
        assert.equals(3, #calls) -- the outcome notice is the caller's
    end)

    it("Neovim's built-in notify (no handle): the running message is not notified", function()
        local d = fake_deps()
        local f, calls = notifier(nil)
        local notice = progress.notice(f)
        notice:show("gitloom: Fetching…")
        local op = progress.tracker({ provider = "notify", delay = 0 }, d):start("Fetching",
            { own_notices = true, notice = notice, message = "0:00 · waiting for the remote" })
        d.t = 5000
        op:report("0:05 · Receiving objects: 10%")
        assert.equals(1, #calls)
        assert.is_nil(notice.handle)
    end)

    it("under fidget the running message is the entry's message, the notice untouched", function()
        local reported = {}
        local fp = { handle = { create = function(o)
            reported[#reported + 1] = o.message
            return { report = function(_, r) reported[#reported + 1] = r.message end, finish = function() end }
        end } }
        local d = fake_deps({ fidget = function() return fp end })
        local f, calls = notifier(function(n) return n end)
        local op = progress.tracker({ provider = "fidget", delay = 0 }, d):start("Fetching",
            { own_notices = true, notice = progress.notice(f), message = "0:00 · waiting for the remote" })
        op:report("0:01 · Receiving objects: 10%")
        assert.same({ "0:00 · waiting for the remote", "0:01 · Receiving objects: 10%" }, reported)
        assert.equals(0, #calls)
        assert.is_true(op.fidget)
    end)
end)

describe("the real fidget adapter (§19.3)", function()
    local dir = vim.g.gitloom_test_deps .. "/fidget.nvim"
    local have = vim.fn.isdirectory(dir) == 1
    if not have then
        pending("fidget.nvim not in the test deps dir")
        return
    end
    vim.opt.rtp:append(dir)

    it("creates a gitloom handle and finishes it on every outcome without raising", function()
        local fp = require("fidget.progress")
        for _, outcome in ipairs({ "done", "failed", "cancelled" }) do
            local created
            local real_create = fp.handle.create
            fp.handle.create = function(msg)
                created = real_create(msg)
                return created
            end
            local ok, err = pcall(function()
                local tr = progress.tracker({ provider = "fidget", delay = 0 })
                local op = tr:start("Fetching", { own_notices = true })
                assert.is_true(op.fidget)
                op:report("origin")
                op:finish(outcome)
            end)
            fp.handle.create = real_create
            assert.is_true(ok, tostring(err))
            assert.is_not_nil(created)
            assert.equals("gitloom", created.lsp_client.name)
            assert.is_false(created.cancellable)
            assert.is_true(created.done)
        end
    end)
end)

-- The glue paths a spec can reach without a window (§19.4): the open's projection
-- ending its Op when superseded or failed, and resync's closed-window exit.
describe("call sites end their operation (§19.4)", function()
    local window = require("gitloom.window")

    local function op_log()
        local log = {}
        return log, {
            ended = false,
            report = function() end,
            finish = function(self, outcome)
                if self.ended then return end
                self.ended = true
                log[#log + 1] = outcome
            end,
        }
    end

    -- A stub ctx whose reflow_build yields once, so a newer reflow can supersede it.
    local function stub_ctx()
        local ctx = { applied = 0 }
        ctx.reflow_build = function(_, yield) if yield then yield() end return {} end
        ctx.reflow_apply = function(c) c.applied = c.applied + 1 end
        ctx.reflow_async = window._internal.reflow_async
        ctx.shown = true
        ctx.win = function(c) return c.shown and 1000 or nil end
        return ctx
    end

    -- The host window closed (`q` hides it, §14) while the open's projection was
    -- still running across ticks. The session survives a hide, so the projection
    -- is applied to its BUFFER (the listview renders nothing without a window and
    -- the next show re-establishes the view) and the caller's `done` runs — which
    -- is what ends the open's Op. Regression: the result used to be PARKED until
    -- the next show, leaving the Op (fidget: "Loading <repo> — laying out")
    -- running forever when the graph was never shown again.
    it("reflow_async: a projection completing with the window gone still applies and completes", function()
        local ctx = stub_ctx()
        local log, op = op_log()
        local done = false
        ctx:reflow_async(function() done = true; op:finish("done") end, nil, op)
        ctx.shown = false -- `q` before the next slice
        vim.wait(200, function() return done end)
        assert.is_true(done, "the open's done never ran: its Op is left running")
        assert.equals(1, ctx.applied)
        assert.same({ "done" }, log)
        assert.is_nil(ctx.parked_reflow)
    end)

    -- The graph buffer wiped (`<C-w>q` destroys the session, §14.1) mid-projection:
    -- nothing is left to apply to, so the projection stops at its next slice and
    -- ends its Op `cancelled` — never applied into a wiped buffer, never parked.
    it("reflow_async: a projection whose graph buffer was wiped ends cancelled, never applied", function()
        local ctx = stub_ctx()
        local b = vim.api.nvim_create_buf(false, true)
        ctx.lv = { buf = b }
        local log, op = op_log()
        local done = false
        ctx:reflow_async(function() done = true end, nil, op)
        vim.api.nvim_buf_delete(b, { force = true })
        ctx.shown = false
        vim.wait(200, function() return op.ended end)
        assert.same({ "cancelled" }, log)
        assert.is_false(done)
        assert.equals(0, ctx.applied)
        assert.is_nil(ctx.parked_reflow)
    end)

    it("reflow_async: a superseded projection ends its Op cancelled, never applied", function()
        local ctx = stub_ctx()
        local log, op = op_log()
        local done = false
        ctx:reflow_async(function() done = true end, nil, op)
        ctx.reflow_gen = ctx.reflow_gen + 1 -- a newer (synchronous) reflow
        vim.wait(200, function() return op.ended end)
        assert.same({ "cancelled" }, log)
        assert.is_false(done)
        assert.equals(0, ctx.applied)
    end)

    it("reflow_async: an error ends its Op failed", function()
        local ctx = stub_ctx()
        ctx.reflow_build = function() error("boom") end
        local log, op = op_log()
        local notify = vim.notify
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.notify = function() end
        ctx:reflow_async(nil, nil, op)
        vim.notify = notify
        assert.same({ "failed" }, log)
    end)

    it("reflow_async: a completed projection leaves the Op to its caller", function()
        local ctx = stub_ctx()
        local log, op = op_log()
        local done = false
        ctx:reflow_async(function() done = true end, nil, op)
        vim.wait(200, function() return done end)
        assert.is_true(done)
        assert.same({}, log)
    end)

    it("resync: a closed graph window ends the Refresh cancelled", function()
        local d, r = fake_deps(), recorder()
        local ctx = { progress = progress.tracker({ provider = r.provider, delay = 0 }, d) }
        ctx.win = function() return nil end
        window._internal.resync(ctx)
        assert.same({ { "start", "Refreshing", "refs" }, { "finish", "cancelled" } }, r.calls)
        assert.same({}, ctx.progress.live and vim.tbl_keys(ctx.progress.live))
    end)
end)
