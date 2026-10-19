-- Progress reporting (spec §19): long-running operations — the open, `R`, fetch /
-- pull, checkout, examine / Return, the branch sync, a `rev` sort, a diff load —
-- reported through a pluggable **provider**: fidget.nvim when it loads, else
-- `vim.notify`, or a caller's own `{ start = fn }`.
--
-- A **tracker** (one per graph session) hands out **Ops**. An Op is shown only once
-- it has run for `delay` ms (§19.2): before that it only records its latest
-- message, and one that ends sooner never reaches a provider at all. Ending is
-- idempotent (the first `finish` wins), and `tracker:close()` ends every live Op
-- `cancelled` — the session-teardown backstop (§19.4).
--
-- The core is pure over injected dependencies (`deps`: the clock, a one-shot
-- timer, `notify` and the fidget loader), so the delay / end / provider rules are
-- tested with fakes. fidget is never required at load time — only through
-- `pcall(require, "fidget.progress")` when an Op starts — and every provider call
-- is `pcall`ed: a broken provider costs that Op its display, never the operation.
-- No dependency on loomworks.

local M = {}

--- The default show delay (ms, §19.2).
M.DELAY = 300

---@alias ProgressOutcome "done"|"failed"|"cancelled"

---@class ProgressStart
---@field title string
---@field message? string
---@field own_notices? boolean  the operation emits its own start / outcome notices (§19.3)
---@field t0? number            clock (ms) when the operation started — not when it was shown
---@field notice? ProgressNotice  the operation's own replaceable notice: the notify
---                             provider shows the running message through it (§19.3)

---@class ProgressSink
---@field report fun(message?: string)
---@field finish fun(outcome: ProgressOutcome, message?: string)

---@class ProgressProvider
---@field start fun(op: ProgressStart): ProgressSink?

---@class ProgressConfig
---@field provider? "auto"|"fidget"|"notify"|false|ProgressProvider  default "auto"
---@field delay? integer  ms before an operation is shown (default 300; 0 = at once)

---@class ProgressDeps
---@field now? fun(): number                              the clock, in ms
---@field defer? fun(ms: integer, fn: fun()): fun()       a one-shot timer; returns its cancel
---@field notify? fun(msg: string, level?: integer)
---@field fidget? fun(): table?                           loads `fidget.progress`, nil when absent

local function now_ms()
    return vim.uv.hrtime() / 1e6
end

-- A one-shot `vim.uv` timer whose callback runs on the main loop. The returned
-- cancel is safe after the timer fired (a fired Op then finds itself ended, or
-- shows — `show` checks).
local function defer(ms, fn)
    local t = vim.uv.new_timer()
    if not t then return function() end end
    t:start(ms, 0, function()
        if not t:is_closing() then t:close() end
        vim.schedule(fn)
    end)
    return function()
        if not t:is_closing() then
            t:stop()
            t:close()
        end
    end
end

local function load_fidget()
    local ok, fp = pcall(require, "fidget.progress")
    if ok and type(fp) == "table" and fp.handle then return fp end
    return nil
end

---@class ProgressNotice
---@field id string          the `id` every show passes (snacks.notifier replaces by it)
---@field handle any         what `vim.notify` returned for the last show; nil = it cannot replace
---@field shown boolean      shown at least once
---@field show fun(self: ProgressNotice, msg: string, level?: integer)

local notice_seq = 0

--- An operation's own **replaceable notice** (§19.3, fetch / pull): every `show`
--- passes the same `id` (snacks.notifier), the previous show's return as
--- `replace` (nvim-notify) and `title = "gitloom"`. Neovim's built-in
--- `vim.notify` ignores the options and returns nothing, so `handle` stays nil —
--- the sign the notifier cannot replace, and the notify provider then never
--- shows the running message through it. `notify` defaults to the CURRENT
--- `vim.notify` at each show.
---@param notify? fun(msg: string, level?: integer, opts?: table): any
---@return ProgressNotice
function M.notice(notify)
    notice_seq = notice_seq + 1
    return {
        id = "gitloom.progress." .. notice_seq, handle = nil, shown = false,
        show = function(self, msg, level)
            local f = notify or vim.notify
            local ok, h = pcall(f, msg, level or vim.log.levels.INFO,
                { id = self.id, replace = self.handle, title = "gitloom" })
            self.shown = true
            self.handle = ok and h or nil
        end,
    }
end

--- How often (ms) the notify provider may replace a live notice (§19.3).
M.NOTICE_INTERVAL = 1000

--- The `notify` provider (§19.3): a start notice only for an Op without notices of
--- its own, a `done (N s)` end only after that start notice was shown, nothing for
--- `failed` / `cancelled` (every failure already notifies at ERROR) and nothing for
--- the running message (notices are a log, not a live display) — except an Op
--- with its own replaceable `notice` that has been shown and can replace: its
--- running message replaces that notice as `gitloom: <title> <message>`, at most
--- once per NOTICE_INTERVAL.
---@param deps ProgressDeps
---@return ProgressProvider
function M.notify_provider(deps)
    local notify = deps.notify or vim.notify
    local now = deps.now or now_ms
    return {
        start = function(op)
            local shown = false
            if not op.own_notices then
                notify(("gitloom: %s…"):format(op.title), vim.log.levels.INFO)
                shown = true
            end
            local notice, last = op.notice, nil
            local function live(message)
                if not (message and notice and notice.handle ~= nil) then return end
                local t = now()
                if last and t - last < M.NOTICE_INTERVAL then return end
                last = t
                notice:show(("gitloom: %s %s"):format(op.title, message))
            end
            live(op.message)
            return {
                report = live,
                finish = function(outcome)
                    if outcome ~= "done" or not shown then return end
                    local secs = (now() - (op.t0 or now())) / 1000
                    notify(("gitloom: %s — done (%.1f s)"):format(op.title, secs), vim.log.levels.INFO)
                end,
            }
        end,
    }
end

--- The `fidget` provider (§19.3) over a loaded `fidget.progress` module: one
--- non-cancellable handle per Op, grouped under the client name `gitloom`. Every
--- end goes through `handle:finish()` — never `cancel()`, which raises on a
--- non-cancellable handle — after naming a `failed` / `cancelled` outcome.
---@param fp table  the `fidget.progress` module
---@return ProgressProvider
function M.fidget_provider(fp)
    return {
        start = function(op)
            local handle = fp.handle.create({
                title = op.title,
                message = op.message,
                lsp_client = { name = "gitloom" },
                cancellable = false,
            })
            return {
                report = function(message)
                    if message then handle:report({ message = message }) end
                end,
                finish = function(outcome)
                    if outcome ~= "done" then handle:report({ message = outcome }) end
                    handle:finish()
                end,
            }
        end,
    }
end

--- Normalise the `progress` option (§19.5): `false` = `{ provider = false }`,
--- nil = the defaults.
---@param cfg ProgressConfig|false|nil
---@return ProgressConfig
function M.normalize(cfg)
    if cfg == false then return { provider = false, delay = M.DELAY } end
    cfg = type(cfg) == "table" and cfg or {}
    local provider = cfg.provider
    if provider == nil then provider = "auto" end
    local delay = tonumber(cfg.delay) or M.DELAY
    return { provider = provider, delay = math.max(0, delay) }
end

---@class ProgressOp
---@field title string
---@field message? string
---@field own_notices boolean
---@field notice? ProgressNotice  the operation's own replaceable notice (§19.3), handed to the provider
---@field fidget boolean   the resolved provider is fidget (§19.3: drop fetch / pull's own start notice)
---@field ended boolean
---@field report fun(self: ProgressOp, message?: string)
---@field finish fun(self: ProgressOp, outcome?: ProgressOutcome, message?: string)

--- An Op that reports nothing and is already ended: what `progress = false`, a
--- closed tracker or a caller without a tracker gets. Safe to report / finish.
---@return ProgressOp
function M.null_op()
    return {
        title = "", own_notices = false, fidget = false, ended = true,
        report = function() end, finish = function() end,
    }
end

---@class ProgressTracker
---@field cfg ProgressConfig
---@field live table<ProgressOp, boolean>
---@field closed boolean
---@field start fun(self: ProgressTracker, title: string, opts?: { message?: string, own_notices?: boolean, notice?: ProgressNotice }): ProgressOp
---@field close fun(self: ProgressTracker)

--- One tracker per graph session (§19.4).
---@param cfg ProgressConfig|false|nil  the `progress` option
---@param deps? ProgressDeps           injected for tests; production uses vim.uv / vim.notify / fidget
---@return ProgressTracker
function M.tracker(cfg, deps)
    deps = deps or {}
    local now = deps.now or now_ms
    local timer = deps.defer or defer
    local fidget = deps.fidget or load_fidget
    local tr = { cfg = M.normalize(cfg), live = {}, closed = false }

    -- Resolve the provider once per Op (§19.3: "auto" re-checks fidget each time,
    -- so a lazily loaded fidget is picked up). Returns the provider and whether it
    -- is fidget.
    local function resolve()
        local p = tr.cfg.provider
        if p == false then return nil, false end
        if type(p) == "table" then return p, false end
        if p == "auto" or p == "fidget" then
            local okf, fp = pcall(fidget)
            if okf and fp then return M.fidget_provider(fp), true end
        end
        return M.notify_provider(deps), false
    end

    function tr:start(title, opts)
        opts = opts or {}
        if self.closed then return M.null_op() end
        local provider, is_fidget = resolve()
        if not provider then return M.null_op() end
        local sink, cancel
        local op = {
            title = title, message = opts.message, own_notices = opts.own_notices == true, notice = opts.notice,
            fidget = is_fidget, ended = false, t0 = now(),
        }
        local function show()
            if op.ended or sink then return end
            local ok, s = pcall(provider.start, {
                title = op.title, message = op.message, own_notices = op.own_notices, t0 = op.t0,
                notice = op.notice,
            })
            sink = ok and type(s) == "table" and s or false
        end
        function op.report(o, message)
            if o.ended then return end
            o.message = message
            if sink and sink.report then pcall(sink.report, message) end
        end
        function op.finish(o, outcome, message)
            if o.ended then return end
            o.ended = true
            tr.live[o] = nil
            if cancel then pcall(cancel) end
            if sink and sink.finish then pcall(sink.finish, outcome or "done", message) end
        end
        self.live[op] = true
        if self.cfg.delay <= 0 then
            show()
        else
            cancel = timer(self.cfg.delay, show)
        end
        return op
    end

    function tr:close()
        self.closed = true
        local ops = {}
        for op in pairs(self.live) do ops[#ops + 1] = op end
        for _, op in ipairs(ops) do op:finish("cancelled") end
    end

    return tr
end

return M
