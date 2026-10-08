--- Tests for the command palette (spec §17): the pure registry → entries builder
--- (`palette.palette_entries` — order, key-suffixed labels, scope filtering, the
--- per-remote Fetch expansion for remotes = nil / {} / a list), the remote argv +
--- env builder (`remote.remote_command` — fetch --all, fetch <remote>, pull
--- --ff-only, GIT_TERMINAL_PROMPT=0, never forcing), the `git remote` parse
--- (`remote.parse_remotes`), the failure text (`remote.failure_text`), and
--- `run_remote` / `fetch_remotes` against REAL scratch repositories: a bare
--- "remote" + two clones, so a fetch moves a remote-tracking ref, a per-remote
--- fetch moves only its own remote's refs, a pull fast-forwards a strictly-behind
--- branch, a diverged pull is refused (even with `pull.rebase=true`) leaving HEAD
--- unmoved, a pull with no upstream fails with a non-zero code + git's stderr,
--- and the env reaches the job. The window glue
--- (busy flag, notices, resync) is untested like the rest of it.

local palette = require("gitloom.graph.palette")
local remote = require("gitloom.git.remote")
local fetch = require("gitloom.git.fetch")

-- remote_command, asserted non-nil (and narrowed for the type checker).
---@param kind string
---@param r string?
---@return RemoteCommand
local function cmd(kind, r)
    local c = remote.remote_command(kind, r)
    assert(c, "expected a remote command")
    return c
end

local function ids(entries)
    local out = {}
    for _, e in ipairs(entries) do out[#out + 1] = e.id end
    return out
end

local function labels(entries)
    local out = {}
    for _, e in ipairs(entries) do out[#out + 1] = e.label end
    return out
end

describe("palette_entries (§17.1)", function()
    it("lists Refresh, Fetch, Pull in order, the key shown after the label", function()
        local e = palette.palette_entries("global")
        assert.same({ "refresh", "fetch", "pull" }, ids(e))
        assert.same({ "Refresh  (R)", "Fetch", "Pull" }, labels(e))
    end)

    it("defaults to the global scope", function()
        assert.same(ids(palette.palette_entries("global")), ids(palette.palette_entries()))
    end)

    it("has no per-remote entries while the remote list is unknown or empty", function()
        assert.same({ "refresh", "fetch", "pull" }, ids(palette.palette_entries("global", nil)))
        assert.same({ "refresh", "fetch", "pull" }, ids(palette.palette_entries("global", {})))
    end)

    it("expands Fetch <remote> per remote, in git remote order, before Pull", function()
        local e = palette.palette_entries("global", { "origin", "upstream" })
        assert.same({ "refresh", "fetch", "fetch:origin", "fetch:upstream", "pull" }, ids(e))
        assert.same({ "Refresh  (R)", "Fetch", "Fetch origin", "Fetch upstream", "Pull" }, labels(e))
    end)

    it("binds each action to the session (and a per-remote one to its remote)", function()
        local calls = {}
        local ctx = {
            resync = function(_, silent) calls[#calls + 1] = { "resync", silent } end,
            run_remote = function(_, kind, r) calls[#calls + 1] = { kind, r } end,
        }
        for _, e in ipairs(palette.palette_entries("global", { "origin" })) do e.action(ctx) end
        assert.same({ { "resync", false }, { "fetch" }, { "fetch", "origin" }, { "pull" } }, calls)
    end)

    it("excludes non-global entries from the global palette", function()
        local noop = function() end
        local cmds = {
            { id = "a", label = "A", scope = "global", action = noop },
            { id = "b", label = "B", key = "x", scope = "commit", action = noop },
            { id = "c", label = "C", scope = "ref", action = noop },
            { id = "d", label = "D %s", scope = "ref", per_remote = true, action = noop },
        }
        assert.same({ "a" }, ids(palette.palette_entries("global", { "o" }, cmds)))
        assert.same({ "B  (x)" }, labels(palette.palette_entries("commit", { "o" }, cmds)))
        assert.same({ "c", "d:o" }, ids(palette.palette_entries("ref", { "o" }, cmds)))
    end)
end)

describe("remote_command (§17.2/§17.3)", function()
    it("fetch is git fetch --all", function()
        local c = cmd("fetch")
        assert.same({ "git", "fetch", "--all" }, c.argv)
        assert.is_false(c.resync_on_failure)
    end)

    it("a per-remote fetch is git fetch <remote>", function()
        local c = cmd("fetch", "upstream")
        assert.same({ "git", "fetch", "upstream" }, c.argv)
        assert.equals("git fetch upstream", c.label)
        assert.is_false(c.resync_on_failure)
    end)

    it("pull is git pull --ff-only, resyncing even on failure", function()
        local c = cmd("pull")
        assert.same({ "git", "pull", "--ff-only" }, c.argv)
        assert.is_true(c.resync_on_failure)
        -- No per-remote pull: the remote is ignored.
        assert.same({ "git", "pull", "--ff-only" }, cmd("pull", "origin").argv)
    end)

    it("sets GIT_TERMINAL_PROMPT=0 on every command, in a fresh table", function()
        local a, b = cmd("fetch"), cmd("pull")
        assert.same({ GIT_TERMINAL_PROMPT = "0" }, a.env)
        assert.same({ GIT_TERMINAL_PROMPT = "0" }, b.env)
        assert.same({ GIT_TERMINAL_PROMPT = "0" }, cmd("fetch", "o").env)
        a.env.X = "1"
        assert.is_nil(cmd("fetch").env.X)
        assert.is_nil(remote.REMOTE_ENV.X)
    end)

    it("never forces", function()
        for _, c in ipairs({ cmd("fetch"), cmd("fetch", "o"),
            cmd("pull") }) do
            for _, a in ipairs(c.argv) do
                assert.falsy(a:match("^%-%-force") or a == "-f")
            end
        end
    end)

    it("is nil for an unknown kind", function()
        assert.is_nil(remote.remote_command("push"))
    end)
end)

describe("parse_remotes (§17.1)", function()
    it("one name per line, in order; blank lines skipped; CR trimmed", function()
        assert.same({ "origin", "upstream" }, remote.parse_remotes("origin\nupstream\n"))
        assert.same({ "origin", "upstream" }, remote.parse_remotes("origin\r\n\r\n\nupstream\r\n"))
        assert.same({}, remote.parse_remotes(""))
        assert.same({}, remote.parse_remotes(nil))
    end)
end)

describe("failure_text (§17.3)", function()
    it("puts git's fatal:/error: line ahead of the progress and hints", function()
        local err = "From /x/r\n   a..b  main -> origin/main\nhint: Diverging\r\nfatal: Not possible to fast-forward, aborting.\n"
        local t = remote.failure_text("", err)
        assert.equals("fatal: Not possible to fast-forward, aborting.", t:match("^[^\n]*"))
        assert.equals("error: x", remote.failure_text(nil, "warning: w\nerror: x\n"):match("^[^\n]*"))
    end)

    it("keeps stderr as is without one, and falls back to stdout when stderr is empty", function()
        assert.equals("There is no tracking information\n", remote.failure_text("o", "There is no tracking information\n"))
        assert.equals("CONFLICT (content)\n", remote.failure_text("CONFLICT (content)\n", ""))
        assert.equals("", remote.failure_text(nil, nil))
    end)
end)

describe("run_remote against real repositories (§17.3)", function()
    local base, bare, bare2, a, b

    -- Resolve a future (asserting it did); `any` — a `{ code, out, err }` or a list.
    ---@return any
    local function await(future)
        local res, done = nil, false
        future.next(function(r) res, done = r, true end)
        vim.wait(30000, function() return done end, 20)
        assert.is_true(done, "timed out")
        return res
    end

    local function sh(dir, ...)
        local out = vim.fn.system({ "git", "-C", dir, ... })
        assert.equals(0, vim.v.shell_error, out)
        return vim.trim(out)
    end

    local function commit(dir, file, text, msg)
        vim.fn.writefile({ text }, dir .. "/" .. file)
        sh(dir, "add", "-A")
        sh(dir, "commit", "-q", "-m", msg)
    end

    local function ident(dir)
        sh(dir, "config", "user.email", "t@example.invalid")
        sh(dir, "config", "user.name", "T")
    end

    -- bare (remote) <- clones a, b; a second bare `other` as b's second remote.
    before_each(function()
        if base then return end
        base = vim.fn.tempname()
        bare, bare2, a, b = base .. "/remote.git", base .. "/other.git", base .. "/a", base .. "/b"
        vim.fn.mkdir(base, "p")
        for _, d in ipairs({ bare, bare2 }) do
            vim.fn.system({ "git", "init", "-q", "--bare", "-b", "main", d })
            assert.equals(0, vim.v.shell_error)
        end
        vim.fn.system({ "git", "clone", "-q", bare, a })
        assert.equals(0, vim.v.shell_error)
        ident(a)
        commit(a, "f", "root", "root")
        sh(a, "push", "-q", "-u", "origin", "main")
        sh(a, "remote", "add", "other", bare2)
        sh(a, "push", "-q", "other", "main")
        vim.fn.system({ "git", "clone", "-q", bare, b })
        assert.equals(0, vim.v.shell_error)
        ident(b)
        sh(b, "remote", "add", "other", bare2)
        sh(b, "fetch", "-q", "other")
    end)

    it("lists the remotes in git remote order", function()
        assert.same({ "origin", "other" }, await(fetch.fetch_remotes(b)))
    end)

    it("fetch --all moves the remote-tracking ref, in the given root", function()
        commit(a, "f", "second", "second")
        sh(a, "push", "-q", "origin", "main")
        local pushed = sh(a, "rev-parse", "HEAD")
        assert.is_true(pushed ~= sh(b, "rev-parse", "origin/main"))
        local c = cmd("fetch")
        local res = await(fetch.run_remote(c.argv, b, c.env))
        assert.equals(0, res.code, res.err)
        assert.equals(pushed, sh(b, "rev-parse", "origin/main"))
    end)

    it("a per-remote fetch moves only that remote's tracking refs", function()
        commit(a, "g", "x", "to other")
        sh(a, "push", "-q", "other", "main")
        commit(a, "h", "y", "to origin")
        sh(a, "push", "-q", "origin", "main")
        local origin_before = sh(b, "rev-parse", "origin/main")
        local c = cmd("fetch", "other")
        local res = await(fetch.run_remote(c.argv, b, c.env))
        assert.equals(0, res.code, res.err)
        assert.equals(sh(a, "rev-parse", "HEAD~1"), sh(b, "rev-parse", "other/main"))
        assert.equals(origin_before, sh(b, "rev-parse", "origin/main"))
    end)

    it("pull fast-forwards a branch strictly behind its upstream", function()
        commit(a, "i", "upstream", "upstream change")
        sh(a, "push", "-q", "origin", "main")
        local c = cmd("pull")
        local res = await(fetch.run_remote(c.argv, b, c.env))
        assert.equals(0, res.code, res.err)
        assert.equals(sh(a, "rev-parse", "HEAD"), sh(b, "rev-parse", "HEAD"))
        -- A fast-forward: no merge commit was created.
        assert.equals(2, #vim.split(sh(b, "rev-list", "--parents", "-n", "1", "HEAD"), " "))
    end)

    it("pull on a diverged branch is refused, even with pull.rebase=true: HEAD unmoved", function()
        commit(a, "k", "upstream", "upstream again")
        sh(a, "push", "-q", "origin", "main")
        commit(b, "j", "local", "local change")
        -- --ff-only on the command line must beat a configured rebase.
        sh(b, "config", "pull.rebase", "true")
        local before = sh(b, "rev-parse", "HEAD")
        local c = cmd("pull")
        local res = await(fetch.run_remote(c.argv, b, c.env))
        sh(b, "config", "--unset", "pull.rebase")
        assert.is_true(0 ~= res.code)
        assert.truthy(res.err ~= "")
        assert.truthy(remote.failure_text(res.out, res.err):match("^fatal:"), res.err)
        assert.equals(before, sh(b, "rev-parse", "HEAD"))
        -- The fetch half still moved the remote-tracking ref (why a failed pull resyncs).
        assert.equals(sh(a, "rev-parse", "HEAD"), sh(b, "rev-parse", "origin/main"))
    end)

    it("pull on a branch with no upstream fails: non-zero code + git's stderr", function()
        sh(b, "switch", "-q", "-c", "lonely")
        local before = sh(b, "rev-parse", "HEAD")
        local c = cmd("pull")
        local res = await(fetch.run_remote(c.argv, b, c.env))
        assert.is_true(0 ~= res.code)
        assert.truthy(res.err ~= "")
        assert.equals(before, sh(b, "rev-parse", "HEAD"))
        sh(b, "switch", "-q", "main")
    end)

    it("passes the env (GIT_TERMINAL_PROMPT=0) through to the job", function()
        -- A shell alias echoes the variable from inside the spawned git.
        local argv = { "git", "-c", "alias.envp=!echo \"[$GIT_TERMINAL_PROMPT]\"", "envp" }
        local res = await(fetch.run_remote(argv, b, cmd("fetch").env))
        assert.equals(0, res.code, res.err)
        assert.equals("[0]", vim.trim(res.out))
    end)
end)
