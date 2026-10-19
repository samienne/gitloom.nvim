--- Tests for the command palette (spec §17): the pure entries builder
--- (`palette.palette_entries` — ONE ordered list, the context first (the row's
--- entries, or the §13 selection's instead while selecting) then the global
--- commands, key-suffixed labels, no examine entry, Return only while an examine
--- is active, the per-remote Fetch expansion for remotes = nil / {} / a list,
--- registry conditions; no Refresh command — R is a key), the **key entries**
--- (§17.1: the context classification, per-context sets for commit / branch /
--- marker-selected / packed / selection, groups refs → view → select → other,
--- hints from the registry key, a key already shown not repeated, ungrouped and
--- handler-less keys never listed) and the generated `?` help (`help_lines`:
--- grouped, aliases joined, a newly added fake key picked up) over a FAKE
--- registry, plus the real `GRAPH_KEYS` checked for well-formedness, the remote argv +
--- env builder (`remote.remote_command` — fetch --progress --all, fetch --progress <remote>, pull
--- --ff-only, GIT_TERMINAL_PROMPT=0, never forcing), the `git remote` parse
--- (`remote.parse_remotes`), the failure text (`remote.failure_text`), and
--- `run_remote` / `fetch_remotes` against REAL scratch repositories: a bare
--- "remote" + two clones, so a fetch moves a remote-tracking ref, a per-remote
--- fetch moves only its own remote's refs, a pull fast-forwards a strictly-behind
--- branch, a diverged pull is refused (even with `pull.rebase=true`) leaving HEAD
--- unmoved, a pull with no upstream fails with a non-zero code + git's stderr,
--- and the env reaches the job. §17.4: the streamed `run_remote`, the pure fetch
--- log / live status / ref summary, the `Show fetch log` entry, and the window
--- glue (`window._internal.run_remote` / `show_remote_log` over a stub ctx: log,
--- summary notice, busy refusal, resync, the live log float).

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
    local H = ("a"):rep(40)
    local plain = { kind = "plain", commit = { hash = H, refs = {} } }

    it("lists Fetch, Pull in order (the resync is the R key's entry, not a command)", function()
        local e = palette.palette_entries({})
        assert.same({ "fetch", "pull", "reset_view" }, ids(e))
        assert.same({ "Fetch", "Pull", "Reset view settings…" }, labels(e))
        assert.same(ids(e), ids(palette.palette_entries()))
        for _, c in ipairs(palette.COMMANDS) do assert.is_true(c.id ~= "refresh") end
    end)

    it("lists Show fetch log after Pull only once a fetch / pull has run (§17.4)", function()
        assert.same({ "fetch", "pull", "reset_view" }, ids(palette.palette_entries({ remote_log = false })))
        local e = palette.palette_entries({ remote_log = true, remotes = { "origin" } })
        assert.same({ "fetch", "fetch:origin", "pull", "remote_log", "reset_view" }, ids(e))
        assert.equals("Show fetch log", e[4].label)
        assert.is_nil(e[4].key)
        local called = false
        e[4].action({ show_remote_log = function() called = true end })
        assert.is_true(called)
    end)

    it("has no per-remote entries while the remote list is unknown or empty", function()
        assert.same({ "fetch", "pull", "reset_view" }, ids(palette.palette_entries({ remotes = nil })))
        assert.same({ "fetch", "pull", "reset_view" }, ids(palette.palette_entries({ remotes = {} })))
    end)

    it("expands Fetch <remote> per remote, in git remote order, before Pull", function()
        local e = palette.palette_entries({ remotes = { "origin", "upstream" } })
        assert.same({ "fetch", "fetch:origin", "fetch:upstream", "pull", "reset_view" }, ids(e))
        assert.same({ "Fetch", "Fetch origin", "Fetch upstream", "Pull", "Reset view settings…" }, labels(e))
    end)

    it("puts the row's entries FIRST, then the global commands; no examine entry", function()
        local e = palette.palette_entries({ row = plain, has_diff = true, remotes = { "origin" } })
        assert.same({ "diff", "checkout", "checkout_examine", "fetch", "fetch:origin", "pull", "reset_view" }, ids(e))
        assert.equals("Open diff  (D)", e[1].label)
        for _, x in ipairs(e) do assert.is_true(x.id ~= "examine") end
    end)

    it("while selecting, the selection's entries replace the row's", function()
        local e = palette.palette_entries({ row = plain, selection = true, has_diff = true })
        assert.same({ "selection_diff", "examine_selection", "fetch", "pull", "reset_view" }, ids(e))
        assert.same({ "Open diff  (D)", "Checkout & examine selection" }, { e[1].label, e[2].label })
        -- Without a diff provider the selection has no entries of its own.
        assert.same({ "fetch", "pull", "reset_view" }, ids(palette.palette_entries({ row = plain, selection = true })))
    end)

    it("lists Return first among the globals, only while an examine is active", function()
        local st = { orig = "main", detached = false, examined = H }
        local e = palette.palette_entries({ row = plain, examine = st })
        assert.same({ "checkout", "return", "fetch", "pull", "reset_view" }, ids(e))
        assert.equals("Return to main", e[2].label)
        assert.same({ "checkout", "fetch", "pull", "reset_view" }, ids(palette.palette_entries({ row = plain })))
    end)

    it("binds each action to the session (and a per-remote one to its remote)", function()
        local calls = {}
        local ctx = {
            run_remote = function(_, kind, r) calls[#calls + 1] = { kind, r } end,
            reset_view = function() calls[#calls + 1] = { "reset" } end,
        }
        for _, e in ipairs(palette.palette_entries({ remotes = { "origin" } })) do e.action(ctx) end
        assert.same({ { "fetch" }, { "fetch", "origin" }, { "pull" }, { "reset" } }, calls)
    end)

    it("lists Reset view settings last among the globals, in every context (§18.5)", function()
        for _, info in ipairs({ {}, { row = plain, has_diff = true }, { row = plain, selection = true, has_diff = true },
            { row = plain, examine = { orig = "main", examined = H } }, { remotes = { "origin" } } }) do
            local e = palette.palette_entries(info)
            assert.equals("reset_view", e[#e].id)
            assert.equals("Reset view settings…", e[#e].label)
        end
    end)

    it("row entries carry an op (run by the window), registry entries an action", function()
        for _, e in ipairs(palette.palette_entries({ row = plain, has_diff = true })) do
            assert.is_true((e.op ~= nil) ~= (e.action ~= nil))
        end
    end)

    it("filters the registry by scope and condition", function()
        local noop = function() end
        local cmds = {
            { id = "a", label = "A", scope = "global", action = noop },
            { id = "b", label = "B", key = "x", scope = "selection", action = noop },
            { id = "c", label = function(st) return "C " .. st.examine.orig end, scope = "global",
                when = function(st) return st.examine ~= nil end, action = noop },
            { id = "d", label = "D %s", scope = "selection", per_remote = true, action = noop },
        }
        assert.same({ "a" }, ids(palette.palette_entries({ remotes = { "o" }, commands = cmds })))
        assert.same({ "b", "d:o", "a" },
            ids(palette.palette_entries({ selection = true, remotes = { "o" }, commands = cmds })))
        assert.same({ "B  (x)", "D o", "A" },
            labels(palette.palette_entries({ selection = true, remotes = { "o" }, commands = cmds })))
        assert.same({ "A", "C x" },
            labels(palette.palette_entries({ examine = { orig = "x", detached = false, examined = "h" }, commands = cmds })))
    end)
end)

-- A fake key registry (the test seam: the real `GRAPH_KEYS` is never mutated).
-- Out of group order on purpose, so the grouping is what orders the palette.
local calls
local function fake_keys()
    calls = {}
    local function run(name) return function() calls[#calls + 1] = name end end
    return {
        { key = "m", run = run("m"), group = "view", desc = "Cycle style" },
        { key = "<leader>b", run = run("refpick"), group = "refs", desc = "Jump to branch / ref…" },
        { key = "P", run = run("pin"), group = "refs", contexts = { "branch" }, desc = "Pin / unpin branch" },
        { key = "<Space>", run = run("space"), group = "refs", contexts = { "branch" }, desc = "Collapse / expand" },
        { key = "R", run = run("resync"), group = "other", desc = "Refresh: resync with the repository" },
        { key = "D", run = run("diff"), group = "select", contexts = { "commit", "selection" },
            when = function(st) return st.has_diff == true end, desc = "Open diff" },
        { key = "V", run = run("select"), group = "select", contexts = { "commit", "selection" },
            desc = "Start / exit commit selection" },
        { key = "K", run = run("lane"), group = "other", contexts = { "commit", "branch" }, desc = "Lane breakdown" },
        { key = { "<C-Space>", "<C-@>" }, run = run("palette"), desc = "Command palette" },
        { key = "j", run = run("j"), desc = "Next row" },
        { key = { "<C-o>", "<C-i>" }, desc = "Back / forward" },
        { key = "x", group = "view", desc = "Unbound (no handler)" },
    }
end

describe("palette key entries (§17.1)", function()
    local H = ("a"):rep(40)
    local function c() return { hash = H, refs = {} } end
    local plain = { kind = "plain", commit = c() }
    local branch = { kind = "branch", state = "expanded", commit = c(), ref = { kind = "local", name = "main" } }
    local head = { kind = "branch", state = "collapsed",
        commit = { collapsed = true, hash = "collapsed:x", refs = {}, tip = c() } }
    local packed = { kind = "markers", markers = { "◍ a", "◍ b", "◍ c" } }
    local packed_sel = { kind = "markers", markers = { "◍ a", "◍ b", "◍ c" }, selected = 2, commit = c() }

    local function entries(info)
        info.keys = fake_keys()
        return palette.palette_entries(info)
    end

    it("classifies the context from the row", function()
        assert.equals("commit", palette.row_context(plain))
        assert.equals("branch", palette.row_context(branch))
        assert.equals("branch", palette.row_context(head))
        assert.equals("markers", palette.row_context(packed))
        assert.equals("branch", palette.row_context(packed_sel))
        assert.is_nil(palette.row_context(nil))
    end)

    it("commit: commit actions, globals, then grouped keys refs → view → select → other", function()
        local e = entries({ row = plain, has_diff = true })
        assert.same({ "diff", "checkout", "checkout_examine", "fetch", "pull", "reset_view",
            "key:<leader>b", "key:m", "key:V", "key:R", "key:K" }, ids(e))
        -- No branch actions; D is shown once, on Open diff.
        for _, x in ipairs(e) do
            assert.is_true(x.id ~= "key:P" and x.id ~= "key:<Space>" and x.id ~= "key:D")
        end
    end)

    it("key hints come from the registry key", function()
        local e = entries({ row = plain, has_diff = true })
        local by = {}
        for _, x in ipairs(e) do by[x.id] = x.label end
        assert.equals("Jump to branch / ref…  (<leader>b)", by["key:<leader>b"])
        assert.equals("Refresh: resync with the repository  (R)", by["key:R"])
        assert.equals("Open diff  (D)", by["diff"])
    end)

    it("commit without a diff provider: D's condition fails, so no D at all", function()
        local e = entries({ row = plain })
        assert.same({ "checkout", "fetch", "pull", "reset_view", "key:<leader>b", "key:m", "key:V", "key:R", "key:K" }, ids(e))
    end)

    it("branch: the branch's actions + branch keys; no commit diff / examine", function()
        local e = entries({ row = branch, has_diff = true })
        assert.same({ "checkout", "collapse", "hide", "fetch", "pull", "reset_view",
            "key:<leader>b", "key:P", "key:m", "key:R", "key:K" }, ids(e))
        assert.equals("Checkout branch main", e[1].label)
        assert.equals("Collapse branch  (<Space>)", e[2].label) -- <Space> not repeated as a key
    end)

    it("collapsed head: checkout of its tip, expand, hide", function()
        local e = entries({ row = head, has_diff = true })
        assert.same({ "checkout", "expand", "hide" }, { e[1].id, e[2].id, e[3].id })
        assert.same({ "git", "checkout", "--detach", H }, e[1].checkout.argv)
    end)

    it("packed line, a marker selected: only THAT marker's actions + branch keys", function()
        local e = entries({ row = packed_sel, has_diff = true })
        assert.same({ "checkout", "expand:2", "hide:2", "fetch", "pull", "reset_view",
            "key:<leader>b", "key:P", "key:<Space>", "key:m", "key:R", "key:K" }, ids(e))
        assert.same({ "Expand ◍ b", "Hide ◍ b" }, { e[2].label, e[3].label })
    end)

    it("packed line, no marker selected: expand / hide per marker, global keys only", function()
        local e = entries({ row = packed, has_diff = true })
        assert.same({ "expand:1", "hide:1", "expand:2", "hide:2", "expand:3", "hide:3", "fetch", "pull", "reset_view",
            "key:<leader>b", "key:m", "key:R" }, ids(e))
    end)

    it("selection: the selection's entries + selection keys (V exits), D once", function()
        local e = entries({ row = plain, selection = true, has_diff = true })
        assert.same({ "selection_diff", "examine_selection", "fetch", "pull", "reset_view",
            "key:<leader>b", "key:m", "key:V", "key:R" }, ids(e))
    end)

    it("never lists an ungrouped or handler-less key; no duplicate R", function()
        for _, info in ipairs({ { row = plain, has_diff = true }, { row = branch }, { row = packed },
            { row = packed_sel }, { selection = true, has_diff = true }, {} }) do
            local seen = {}
            for _, x in ipairs(entries(info)) do
                assert.is_true(x.id ~= "key:<C-Space>" and x.id ~= "key:j" and x.id ~= "key:<C-o>"
                    and x.id ~= "key:x", x.id)
                assert.is_nil(seen[x.label], x.label)
                seen[x.label] = true
                if x.key then assert.is_nil(seen["k:" .. x.key], x.key); seen["k:" .. x.key] = true end
            end
        end
    end)

    it("no keys without a registry (the default snapshot)", function()
        assert.same({ "expand:1", "hide:1", "expand:2", "hide:2", "expand:3", "hide:3", "fetch", "pull", "reset_view" },
            ids(palette.palette_entries({ row = packed })))
    end)

    it("a key entry runs its handler on the session", function()
        local e = entries({ row = branch })
        for _, x in ipairs(e) do
            if x.id == "key:P" or x.id == "key:R" then x.action({}) end
        end
        assert.same({ "pin", "resync" }, calls)
    end)
end)

describe("help_lines (§2, generated from the key registry)", function()
    it("lists every key, grouped, the ungrouped ones last, aliases joined", function()
        local lines = palette.help_lines(fake_keys())
        assert.equals("gitloom keys", lines[1])
        local text = table.concat(lines, "\n")
        local order = { "Branches, refs & search", "<leader>b", "View", "  m ", "Commit & selection",
            "Other", "  R ", "Motion & misc", "<C-Space> / <C-@>", "<C-o> / <C-i>" }
        local pos = 0
        for _, needle in ipairs(order) do
            local at = text:find(needle, pos + 1, true)
            assert.is_not_nil(at, needle)
            pos = at --[[@as integer]]
        end
        -- a handler-less key is still listed (bound elsewhere); every key appears
        for _, k in ipairs(fake_keys()) do
            assert.is_not_nil(text:find(k.desc, 1, true), k.desc)
        end
    end)

    it("picks up a newly added key, and prefers the longer help text", function()
        local keys = fake_keys()
        keys[#keys + 1] = { key = "Z", run = function() end, group = "view", desc = "Zoom",
            help = "Zoom the graph (a fake key)" }
        local text = table.concat(palette.help_lines(keys), "\n")
        assert.is_not_nil(text:find("Z%s+Zoom the graph %(a fake key%)"))
        assert.is_nil(text:find("  Zoom\n", 1, true))
    end)

    it("aligns the description column", function()
        local lines = palette.help_lines(fake_keys())
        local col
        for _, l in ipairs(lines) do
            if l:sub(1, 2) == "  " then
                local lhs_end = l:find("  %S", 3) -- the gap before the description
                local c = vim.fn.strdisplaywidth(l:sub(1, lhs_end))
                col = col or c
                assert.equals(col, c, l)
            end
        end
    end)
end)

describe("the real key registry (window.lua GRAPH_KEYS, §17.1)", function()
    local keys = require("gitloom.window")._internal.keys
    local groups = { refs = true, view = true, select = true, other = true }
    local contexts = { commit = true, branch = true, markers = true, selection = true }

    it("is well-formed: a desc each, known groups / contexts, no lhs bound twice", function()
        local seen = {}
        for _, k in ipairs(keys) do
            assert.is_true(type(k.desc) == "string" and k.desc ~= "", vim.inspect(k.key))
            if k.group then assert.is_true(groups[k.group], k.group) end
            for _, c in ipairs(k.contexts or {}) do assert.is_true(contexts[c], c) end
            for _, lhs in ipairs(palette.lhs_of(k)) do
                assert.is_nil(seen[lhs], lhs)
                seen[lhs] = true
            end
        end
        for _, lhs in ipairs({ "R", "?", "<C-Space>", "<C-@>", "V", "D", "P", "<leader>b", "%", "j", "q" }) do
            assert.is_true(seen[lhs], lhs)
        end
    end)

    it("keeps motions and plumbing out of the palette, and lists R once", function()
        for _, lhs in ipairs({ "j", "k", "h", "l", "<C-d>", "<C-u>", "n", "N", "o", "<Esc>", "q",
            "<C-w>q", "<C-Space>", "<C-@>", "<leader>wD", "<C-o>" }) do
            for _, k in ipairs(keys) do
                if palette.lhs_of(k)[1] == lhs or vim.tbl_contains(palette.lhs_of(k), lhs) then
                    assert.is_nil(k.group, lhs)
                end
            end
        end
        local n = 0
        for _, e in ipairs(palette.palette_entries({ keys = keys })) do
            if e.key == "R" then n = n + 1 end
        end
        assert.equals(1, n)
    end)

    it("offers <Space> on a branch row only where it toggles something", function()
        local H = ("a"):rep(40)
        local function spaces(state)
            local n = 0
            local row = { kind = "branch", state = state, commit = { hash = H, refs = {} } }
            for _, e in ipairs(palette.palette_entries({ keys = keys, row = row })) do
                if e.key == "<Space>" then n = n + 1 end
            end
            return n
        end
        -- mainline: pressing it does nothing, so it is not offered at all
        assert.equals(0, spaces("mainline"))
        -- expanded / collapsed: offered once, as the row's collapse / expand entry
        assert.equals(1, spaces("expanded"))
        assert.equals(1, spaces("collapsed"))
        -- a packed line with a marker selected (no state) still toggles the marker
        local packed = { kind = "markers", markers = { "a", "b" }, selected = 1,
            commit = { hash = H, refs = {} } }
        local n = 0
        for _, e in ipairs(palette.palette_entries({ keys = keys, row = packed })) do
            if e.key == "<Space>" then n = n + 1 end
        end
        assert.equals(1, n)
    end)

    it("offers % (the local / remote cycle) in the commit and branch contexts only", function()
        local H = ("a"):rep(40)
        local function cycles(row)
            local n = 0
            for _, e in ipairs(palette.palette_entries({ keys = keys, row = row })) do
                if e.key == "%" then n = n + 1 end
            end
            return n
        end
        local plain = { kind = "plain", commit = { hash = H, refs = {} } }
        local branch = { kind = "branch", state = "expanded", commit = { hash = H, refs = {} } }
        local packed = { kind = "markers", markers = { "a", "b" }, commit = { hash = H, refs = {} } }
        assert.equals("commit", palette.row_context(plain))
        assert.equals("branch", palette.row_context(branch))
        assert.equals(1, cycles(plain))
        assert.equals(1, cycles(branch))
        assert.equals(0, cycles(packed)) -- markers context, no marker selected
        local n = 0
        for _, e in ipairs(palette.palette_entries({ keys = keys, selection = true })) do
            if e.key == "%" then n = n + 1 end
        end
        assert.equals(0, n)
    end)

    it("the help lists every bound key", function()
        local text = table.concat(palette.help_lines(keys), "\n")
        for _, k in ipairs(keys) do
            assert.is_not_nil(text:find(table.concat(palette.lhs_of(k), " / "), 1, true), k.desc)
        end
    end)
end)

describe("remote_command (§17.2/§17.3)", function()
    it("fetch is git fetch --progress --all", function()
        local c = cmd("fetch")
        assert.same({ "git", "fetch", "--progress", "--all" }, c.argv)
        assert.is_false(c.resync_on_failure)
    end)

    it("a per-remote fetch is git fetch --progress <remote>", function()
        local c = cmd("fetch", "upstream")
        assert.same({ "git", "fetch", "--progress", "upstream" }, c.argv)
        assert.equals("git fetch upstream", c.label)
        assert.is_false(c.resync_on_failure)
    end)

    it("pull is git pull --ff-only --progress, resyncing even on failure", function()
        local c = cmd("pull")
        assert.same({ "git", "pull", "--ff-only", "--progress" }, c.argv)
        assert.is_true(c.resync_on_failure)
        -- No per-remote pull: the remote is ignored.
        assert.same({ "git", "pull", "--ff-only", "--progress" }, cmd("pull", "origin").argv)
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

    -- §17.4: the streamed runner.
    it("streams the output before resolving, and still resolves the whole of it", function()
        commit(a, "f", "streamed", "streamed")
        sh(a, "switch", "-q", "-c", "topic")
        commit(a, "g", "topic", "topic")
        sh(a, "push", "-q", "origin", "main", "topic")
        sh(a, "switch", "-q", "main")
        local c = cmd("fetch", "origin")
        local chunks, resolved = {}, false
        local future = fetch.run_remote(c.argv, b, c.env, function(stream, data)
            assert.is_false(resolved, "a chunk after the future resolved")
            chunks[#chunks + 1] = { stream, data }
        end)
        local res = await(future.next(function(r)
            resolved = true
            return r
        end))
        assert.equals(0, res.code, res.err)
        assert.truthy(#chunks > 0)
        local err = {}
        for _, ch in ipairs(chunks) do
            if ch[1] == "stderr" then err[#err + 1] = ch[2] end
        end
        assert.equals((table.concat(err):gsub("%s+$", "")), res.err)
        -- The ref table survives (flag column intact): main updated, topic new.
        local s = remote.ref_summary(res.err)
        assert.equals(1, s.new)
        assert.equals(1, s.updated)
        assert.equals("gitloom: fetched origin — 1 new, 1 updated", remote.summary_text(c, s))
        -- And it reads back through the log the window keeps.
        local log = remote.new_log("git fetch", 0, 0)
        for i, ch in ipairs(chunks) do remote.log_feed(log, ch[1], ch[2], i) end
        remote.log_finish(log, res.code, #chunks + 1)
        local seen = false
        for _, l in ipairs(log.lines) do
            if l.text:match("^ %* %[.-%]%s+topic%s+%->") then seen = true end
        end
        assert.is_true(seen)
    end)

    it("a streamed fetch with nothing new is up to date", function()
        local c = cmd("fetch", "other")
        local res = await(fetch.run_remote(c.argv, b, c.env, function() end))
        assert.equals(0, res.code, res.err)
        assert.equals("gitloom: fetched other — up to date", remote.summary_text(c, remote.ref_summary(res.err)))
    end)

    it("--all reports both remotes' ref updates", function()
        commit(a, "f", "both", "both")
        sh(a, "push", "-q", "origin", "main")
        sh(a, "push", "-q", "other", "main")
        local c = cmd("fetch")
        local res = await(fetch.run_remote(c.argv, b, c.env, function() end))
        assert.equals(0, res.code, res.err)
        assert.equals(2, remote.ref_summary(res.err).updated)
    end)

    it("a failing streamed fetch still reports git's fatal: line first", function()
        local argv = { "git", "fetch", "--progress", "no-such-remote" }
        local res = await(fetch.run_remote(argv, b, cmd("fetch").env, function() end))
        assert.is_true(res.code ~= 0)
        local text = remote.failure_text(res.out, res.err)
        assert.truthy(text:match("^fatal:") or text:match("^error:"), text)
    end)

    -- The window glue over a stub ctx (window._internal): the log, the summary
    -- notice, the resync, the busy guard and the live log buffer.
    it("run_remote keeps the log, notifies the summary, resyncs; the log float follows it", function()
        local w = require("gitloom.window")._internal
        local notices = {}
        local orig = vim.notify
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.notify = function(msg, level) notices[#notices + 1] = { msg = msg, level = level } end
        local ok, err = pcall(function()
            local resynced = 0
            local ctx = {
                repo = { root = b },
                progress = require("gitloom.progress").tracker({ provider = "notify", delay = 0 }),
                resync = function() resynced = resynced + 1 end,
                win = function() return nil end,
                run_remote = w.run_remote, show_remote_log = w.show_remote_log,
                refresh_remote_log = w.refresh_remote_log,
            }
            commit(a, "f", "glue", "glue")
            sh(a, "push", "-q", "origin", "main")
            ctx:run_remote("fetch", "origin")
            assert.equals("git fetch origin", ctx.remote_busy)
            ctx:run_remote("pull") -- refused while busy
            vim.wait(30000, function() return ctx.remote_busy == nil end, 20)
            assert.is_nil(ctx.remote_busy, "timed out")
            local log = ctx.remote_log
            assert.equals("git fetch --progress origin", log.cmd)
            assert.equals(0, log.code)
            assert.equals(1, resynced)
            assert.same({
                { msg = "gitloom: Fetching origin…", level = vim.log.levels.INFO },
                { msg = "gitloom: git fetch origin is still running", level = vim.log.levels.WARN },
                { msg = "gitloom: fetched origin — 1 updated", level = vim.log.levels.INFO },
            }, notices)
            -- The log float: the command, git's lines, the exit line; q closes it.
            ctx:show_remote_log()
            local buf = ctx.remote_log_buf
            assert.truthy(buf and vim.api.nvim_buf_is_valid(buf))
            local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            assert.truthy(lines[1]:match("^git fetch %-%-progress origin  %(started "))
            assert.truthy(lines[#lines]:match("^exit 0 %("))
            assert.is_false(vim.bo[buf].modifiable)
            -- A second run re-renders the open log live, to its end.
            ctx:run_remote("fetch", "origin")
            vim.wait(30000, function() return ctx.remote_busy == nil end, 20)
            assert.equals("gitloom: fetched origin — up to date", notices[#notices].msg)
            assert.is_true(ctx.remote_log ~= log)
            lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            assert.truthy(lines[#lines]:match("^exit 0 %("))
            assert.equals(#lines, vim.api.nvim_win_get_cursor(0)[1])
            vim.api.nvim_feedkeys("q", "x", false)
            assert.is_false(vim.api.nvim_buf_is_valid(buf))
            assert.is_nil(ctx.remote_log_buf)
            ctx.progress:close()
        end)
        vim.notify = orig
        assert(ok, err)
    end)

    it("a spawn failure resolves code -1 when streaming", function()
        local res = await(fetch.run_remote({ "git", "status" }, base .. "/missing-dir", nil, function() end))
        assert.equals(-1, res.code)
        assert.truthy(res.err ~= "")
    end)
end)

describe("the fetch log (§17.4)", function()
    local function texts(log)
        local out = {}
        for _, l in ipairs(log.lines) do out[#out + 1] = l.text end
        return out
    end

    it("a \\r progress update replaces the previous one in place", function()
        local log = remote.new_log("git fetch", 0, 0)
        remote.log_feed(log, "stderr", "Receiving objects:  10% (1/10)   \r", 1)
        remote.log_feed(log, "stderr", "Receiving objects:  50% (5/10)   \r", 2)
        assert.same({ "Receiving objects:  50% (5/10)" }, texts(log))
        remote.log_feed(log, "stderr", "Receiving objects: 100% (10/10), done.\n", 3)
        remote.log_feed(log, "stderr", "Resolving deltas: 100% (2/2), done.\n", 4)
        assert.same({ "Receiving objects: 100% (10/10), done.", "Resolving deltas: 100% (2/2), done." },
            texts(log))
    end)

    it("two updates in one chunk keep only the latest", function()
        local log = remote.new_log("git fetch", 0, 0)
        remote.log_feed(log, "stderr", "remote: Counting objects:   2% (80/3966)  \rremote: Counting objects:   3% (119/3966)  \r", 1)
        assert.same({ "remote: Counting objects:   3% (119/3966)" }, texts(log))
    end)

    it("reassembles a line split across chunks at any point", function()
        local whole = "From ../remote\r\n * [new branch]      topic      -> origin/topic\r\n"
        for cut = 1, #whole - 1 do
            local log = remote.new_log("git fetch", 0, 0)
            remote.log_feed(log, "stderr", whole:sub(1, cut), 1)
            remote.log_feed(log, "stderr", whole:sub(cut + 1), 2)
            assert.same({ "From ../remote", " * [new branch]      topic      -> origin/topic" }, texts(log),
                "cut at " .. cut)
        end
    end)

    it("\\r\\n is one line end, and a closed line is never replaced", function()
        local log = remote.new_log("git fetch", 0, 0)
        remote.log_feed(log, "stderr", "a\r\nb\r\n", 1)
        remote.log_feed(log, "stderr", "c\r", 2)
        assert.same({ "a", "b", "c" }, texts(log))
    end)

    it("keeps the streams apart and flushes an unterminated tail at the end", function()
        local log = remote.new_log("git pull", 0, 0)
        remote.log_feed(log, "stderr", "Receiving 10%\r", 1)
        remote.log_feed(log, "stdout", "Updating a..b\n", 2)
        remote.log_feed(log, "stderr", "Receiving 90%\r", 3)
        remote.log_feed(log, "stdout", "Fast-forward", 4)
        remote.log_finish(log, 0, 5)
        assert.same({ "Receiving 90%", "Updating a..b", "Fast-forward" }, texts(log))
        assert.equals(0, log.code)
    end)

    it("caps the log at LOG_MAX lines, dropping the oldest", function()
        local log = remote.new_log("git fetch", 0, 0)
        local parts = {}
        for i = 1, remote.LOG_MAX + 5 do parts[#parts + 1] = "line " .. i .. "\n" end
        remote.log_feed(log, "stderr", table.concat(parts), 1)
        assert.equals(remote.LOG_MAX, #log.lines)
        assert.equals("line 6", log.lines[1].text)
        -- An open (\r) line still updates in place after the cap shifted it.
        remote.log_feed(log, "stderr", "p 1\r", 2)
        remote.log_feed(log, "stderr", "p 2\r", 3)
        assert.equals(remote.LOG_MAX, #log.lines)
        assert.equals("p 2", log.lines[#log.lines].text)
    end)

    it("renders the command, +seconds lines and the exit / running footer", function()
        local log = remote.new_log("git fetch --progress origin", 1000, 0)
        remote.log_feed(log, "stderr", "From x\n", 13300)
        local running = remote.log_lines(log, 73000)
        assert.truthy(running[1]:match("^git fetch %-%-progress origin  %(started %d%d:%d%d:%d%d%)$"))
        assert.equals("+12.3s  From x", running[2])
        assert.equals("running 1:12", running[3])
        remote.log_finish(log, 1, 5500)
        assert.equals("exit 1 (4.5 s)", remote.log_lines(log, 99999)[3])
    end)
end)

describe("the live status (§17.4)", function()
    it("waits for the remote before any output", function()
        local log = remote.new_log("git fetch", 0, 0)
        assert.equals("0:00 · waiting for the remote", remote.status_text(log, 0))
        assert.equals("0:09 · waiting for the remote", remote.status_text(log, 9999))
    end)

    it("shows the elapsed m:ss and the latest line", function()
        local log = remote.new_log("git fetch", 0, 0)
        remote.log_feed(log, "stderr", "Receiving objects:  43% (1234/2870), 3.1 MiB | 1.2 MiB/s\r", 40000)
        assert.equals("0:42 · Receiving objects:  43% (1234/2870), 3.1 MiB | 1.2 MiB/s",
            remote.status_text(log, 42000))
        assert.equals("1:05 · Receiving objects:  43% (1234/2870), 3.1 MiB | 1.2 MiB/s (no output for 25 s)",
            remote.status_text(log, 65000))
    end)

    it("says how long the remote has been silent past 10 s, even before any line", function()
        local log = remote.new_log("git fetch", 0, 0)
        assert.equals("0:10 · waiting for the remote", remote.status_text(log, 10000))
        assert.equals("0:12 · waiting for the remote (no output for 12 s)", remote.status_text(log, 12000))
    end)
end)

describe("the ref summary (§17.4)", function()
    local err = table.concat({
        "remote: Enumerating objects: 5, done.",
        "Receiving objects: 100% (3/3), done.",
        "Fetching origin",
        "From ../remote",
        " * [new branch]      topic      -> origin/topic",
        " * [new tag]         v1         -> v1",
        "   abc1234..def5678  main       -> origin/main",
        " + 1111111...2222222 wip        -> origin/wip  (forced update)",
        " - [deleted]         (none)     -> origin/gone",
        " t [tag update]      v0         -> v0",
        " ! [rejected]        x          -> origin/x  (non-fast-forward)",
        " = [up to date]      y          -> origin/y",
        " (refs/remotes/origin/HEAD has become dangling)",
    }, "\r\n")

    it("counts by the flag column only", function()
        assert.same({ new = 2, updated = 2, forced = 1, deleted = 1, rejected = 1 }, remote.ref_summary(err))
    end)

    it("counts a translated bracket word the same (the flag is not translated)", function()
        local s = remote.ref_summary(" * [neuer Branch]    topic      -> origin/topic\n")
        assert.equals(1, s.new)
    end)

    it("formats the counts, zero counts left out", function()
        local s = { new = 2, updated = 5, forced = 1, deleted = 0, rejected = 0 }
        assert.equals("gitloom: fetched origin — 2 new, 5 updated, 1 forced",
            remote.summary_text(cmd("fetch", "origin"), s))
        assert.equals("gitloom: pulled — 2 new, 5 updated, 1 forced", remote.summary_text(cmd("pull"), s))
    end)

    it("nothing reported: a fetch is up to date, a pull plain", function()
        local none = remote.ref_summary("From ../remote\n")
        assert.equals("gitloom: fetched — up to date", remote.summary_text(cmd("fetch"), none))
        assert.equals("gitloom: pulled", remote.summary_text(cmd("pull"), none))
    end)
end)
