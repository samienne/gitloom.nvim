--- Tests for the palette's upstream entries (spec §17.2 "Upstream"): Track
--- `<r>/<b>`, Set upstream of `<b>`… and Unset upstream of `<b>`. The pure
--- decisions in `gitloom.git.sync` (the target branch, which entries a tracking
--- state gets and in what order, the Set picker's items, the argv, the notices,
--- the reset prompt's mismatch line), the palette row entries that reach them,
--- then the commands against a REAL scratch repository — never this one — run
--- through `fetch.run_checkout` exactly as the window glue runs them, including
--- the ERROR line of a refused upstream. The window glue itself is untested.

---@diagnostic disable: need-check-nil

local sync = require("gitloom.git.sync")
local fetch = require("gitloom.git.fetch")
local git = require("gitloom.git")
local palette = require("gitloom.graph.palette")
local selectm = require("gitloom.graph.select")

local function ids(entries)
    local out = {}
    for _, e in ipairs(entries) do out[#out + 1] = e.id end
    return out
end

local function names(list)
    local out = {}
    for _, c in ipairs(list) do out[#out + 1] = c.name end
    return out
end

-- An Upstream as the ref read builds it (refs.mark_same_named sets `same`).
local function up(short, extra)
    local remote, branch = short:match("^([^/]+)/(.+)$")
    local u = { short = short, ref = "refs/remotes/" .. short, ahead = 0, behind = 0, gone = false,
        remote = remote, merge = "refs/heads/" .. branch }
    for k, v in pairs(extra or {}) do u[k] = v end
    return u
end

-- A ref registry holding the given remote-tracking branches (+ a remote HEAD symref,
-- which is never offered).
local function registry(remote_names, extra)
    local refs = { ["origin/HEAD"] = { name = "origin/HEAD", kind = "remote" } }
    for _, n in ipairs(remote_names) do refs[n] = { name = n, kind = "remote" } end
    for k, v in pairs(extra or {}) do refs[k] = v end
    return refs
end

local REMOTES = { "origin", "upstream" }

describe("upstream_target / upstream_offers (§17.2)", function()
    local refs = registry({ "upstream/foo", "origin/dev", "origin/foo", "origin/zed" })

    it("any local branch is a target; a tag / plain remote / worktree is not", function()
        assert.same({ branch = "foo" }, sync.upstream_target({ kind = "local", name = "foo" }))
        assert.is_nil(sync.upstream_target({ kind = "tag", name = "v1" }))
        assert.is_nil(sync.upstream_target({ kind = "remote", name = "origin/foo", short = "foo" }))
        assert.is_nil(sync.upstream_target({ kind = "worktree", name = "wt:x" }))
        assert.is_nil(sync.upstream_target(nil))
    end)

    it("a remote branch with a local counterpart: the local's, Track limited to the selected one", function()
        local u = up("origin/dev", { match = false, same = { "origin", "upstream" } })
        local t = sync.upstream_target({ kind = "remote", name = "upstream/foo", short = "foo",
            counterpart = { kind = "local", name = "foo", upstream = u } })
        assert.same({ branch = "foo", upstream = u, only = "upstream/foo" }, t)
        assert.same({ "upstream/foo" }, names(sync.upstream_offers(t, refs, REMOTES).track))
    end)

    it("non-matching upstream with same-named remotes: Track each, in git remote order, first", function()
        local t = { branch = "foo", upstream = up("origin/dev", { match = false, same = { "upstream", "origin" } }) }
        local o = sync.upstream_offers(t, refs, REMOTES)
        assert.same({ "origin/foo", "upstream/foo" }, names(o.track))
        assert.equals("refs/remotes/origin/foo", o.track[1].ref)
        assert.is_true(o.first)
        assert.is_true(o.unset)
    end)

    it("no upstream but a same-named branch: Track, not first (nothing warns); no Unset", function()
        local o = sync.upstream_offers({ branch = "foo" }, refs, REMOTES)
        assert.same({ "origin/foo", "upstream/foo" }, names(o.track))
        assert.is_false(o.first)
        assert.is_false(o.unset)
    end)

    it("a matching upstream never gets Track (gone included); gone still gets Unset", function()
        for _, u in ipairs({ up("origin/foo", { match = true }), up("upstream/foo", { match = true }),
            up("origin/foo", { match = true, gone = true }) }) do
            local o = sync.upstream_offers({ branch = "foo", upstream = u }, refs, REMOTES)
            assert.same({}, o.track)
            assert.is_false(o.first)
            assert.is_true(o.unset)
        end
    end)

    it("non-matching, no same-named branch anywhere: no Track", function()
        local o = sync.upstream_offers({ branch = "bar", upstream = up("origin/dev", { match = false }) },
            refs, REMOTES)
        assert.same({}, o.track)
        assert.is_false(o.first)
    end)

    it("the Set picker: remote-tracking only, same-named first then by name, current marked", function()
        local t = { branch = "foo", upstream = up("origin/dev", { match = false, same = { "origin" } }) }
        local o = sync.upstream_offers(t, registry({ "upstream/foo", "origin/dev", "origin/foo", "origin/zed" },
            { foo = { name = "foo", kind = "local" }, v1 = { name = "v1", kind = "tag" } }), REMOTES)
        assert.same({ "origin/foo", "upstream/foo", "origin/dev", "origin/zed" }, names(o.choices))
        local labels = vim.tbl_map(sync.upstream_choice_label, o.choices)
        assert.same({ "origin/foo", "upstream/foo", "origin/dev (current)", "origin/zed" }, labels)
        for _, c in ipairs(o.choices) do assert.is_nil(c.remote) end
    end)

    it("remotes not yet read: Track still offered, by name", function()
        local o = sync.upstream_offers({ branch = "foo" }, refs, nil)
        assert.same({ "origin/foo", "upstream/foo" }, names(o.track))
    end)
end)

describe("palette row entries for the upstream (§17.1/§17.2)", function()
    local function commit(rs) return { hash = ("c"):rep(40), parents = {}, refs = rs } end
    local function lref(name, u) return { kind = "local", name = name, upstream = u } end
    local function row(c, i)
        return { kind = "branch", state = "mainline", commit = c, ref = selectm.selected_ref(c, i or 1) }
    end
    local refs = registry({ "origin/dev", "origin/enne/standard-effect" })

    it("a warning label: Track first, ahead of Reset; then Set / Unset", function()
        local u = up("origin/dev", { match = false, same = { "origin" }, ahead = 1, behind = 3 })
        local es = palette.row_entries(row(commit({ lref("enne/standard-effect", u) })), true, nil, refs, REMOTES)
        assert.same({ "checkout", "track:origin/enne/standard-effect", "reset_branch", "set_upstream",
            "unset_upstream" }, ids(es))
        assert.equals("Track origin/enne/standard-effect", es[2].label)
        assert.equals("Set upstream of enne/standard-effect…", es[4].label)
        assert.equals("Unset upstream of enne/standard-effect", es[5].label)
        assert.equals("origin/enne/standard-effect", es[2].choice.name)
        assert.equals(2, #es[4].upstream.choices)
    end)

    it("no upstream: Track after (no sync), then Set; no Unset", function()
        local es = palette.row_entries(row(commit({ lref("enne/standard-effect") })), true, nil, refs, REMOTES)
        assert.same({ "checkout", "track:origin/enne/standard-effect", "set_upstream" }, ids(es))
    end)

    it("matching upstream: Set / Unset after the sync entries only", function()
        local u = up("origin/dev", { match = true, behind = 2 })
        local es = palette.row_entries(row(commit({ lref("dev", u) })), true, nil, refs, REMOTES)
        assert.same({ "checkout", "fast_forward", "reset_branch", "set_upstream", "unset_upstream" }, ids(es))
    end)

    it("a tag, a remote without counterpart, a commit row: none; no registry: none", function()
        local c = commit({ { kind = "remote", name = "origin/x" }, { kind = "tag", name = "v1" } })
        for i = 1, 2 do assert.same({ "checkout" }, ids(palette.row_entries(row(c, i), true, nil, refs))) end
        local lc = commit({ lref("dev", up("origin/dev", { match = true })) })
        assert.same({}, vim.tbl_filter(function(id) return id:match("upstream") end,
            ids(palette.row_entries({ kind = "plain", commit = lc }, true, nil, refs))))
        assert.same({ "checkout" }, ids(palette.row_entries(row(lc), true)))
    end)

    it("a selected packed marker: its sole local branch's", function()
        local tip = commit({})
        local mrow = { kind = "markers", markers = { "(foo)" }, selected = 1, commit = tip,
            head = { refs = { lref("foo") } } }
        assert.same({ "checkout", "set_upstream", "expand:1", "hide:1" },
            ids(palette.row_entries(mrow, true, nil, refs, REMOTES)))
    end)

    it("palette_entries passes the registry and remotes through", function()
        local c = commit({ lref("enne/standard-effect") })
        local es = palette.palette_entries({ row = row(c), refs = refs, remotes = REMOTES, commands = {} })
        assert.same({ "checkout", "track:origin/enne/standard-effect", "set_upstream" }, ids(es))
    end)
end)

describe("upstream commands, notices and the reset prompt (§17.2)", function()
    it("argv: --set-upstream-to=<full ref> <b> / --unset-upstream <b>, never forcing", function()
        assert.same({ "git", "branch", "--set-upstream-to=refs/remotes/origin/foo", "foo" },
            sync.set_upstream_command("foo", "refs/remotes/origin/foo").argv)
        assert.same({ "git", "branch", "--unset-upstream", "foo" }, sync.unset_upstream_command("foo").argv)
    end)

    it("the notices name the previous upstream", function()
        assert.equals("gitloom: foo now tracks origin/foo (was origin/dev)",
            sync.set_upstream_done("foo", "origin/foo", up("origin/dev")))
        assert.equals("gitloom: foo now tracks origin/foo (had no upstream)",
            sync.set_upstream_done("foo", "origin/foo", nil))
        assert.equals("gitloom: foo no longer tracks origin/dev", sync.unset_upstream_done("foo", up("origin/dev")))
    end)

    it("the reset prompt warns of a non-matching upstream, before the reflog line", function()
        local u = up("origin/dev", { match = false, same = { "origin" }, ahead = 2, behind = 1 })
        local t = assert(sync.sync_target({ kind = "local", name = "enne/standard-effect", upstream = u }))
        local p = { tip = ("a"):rep(40), up_tip = ("d"):rep(40), head_branch = "main", ahead = 2, behind = 1 }
        assert.same({ "Reset enne/standard-effect to origin/dev (ddddddd)?", "discards 2 local commits",
            "origin/dev is not enne/standard-effect's same-named branch (origin/enne/standard-effect exists"
                .. " — see Track origin/enne/standard-effect)",
            "the old tip aaaaaaa stays reachable in the reflog" }, sync.reset_prompt(t, p))
        -- Nothing lost: the question and the warning, no reflog line; no same-named: no pointer.
        t.same = nil
        assert.same({ "Reset enne/standard-effect to origin/dev (ddddddd)?",
            "origin/dev is not enne/standard-effect's same-named branch" },
            sync.reset_prompt(t, { tip = p.tip, up_tip = p.up_tip, ahead = 0, behind = 1 }))
        -- A matching upstream: unchanged.
        t.match = true
        assert.same({ "Reset enne/standard-effect to origin/dev (ddddddd)?" },
            sync.reset_prompt(t, { tip = p.tip, up_tip = p.up_tip, ahead = 0, behind = 1 }))
    end)
end)

-- ── Against a real scratch repository ────────────────────────────────────────

---@return any
local function await(future)
    local res, done = nil, false
    future.next(function(r) res = r; done = true end)
    vim.wait(20000, function() return done end, 20)
    assert(done, "future never resolved")
    return res
end

local function sh(dir, ...)
    local out = vim.fn.system({ "git", "-C", dir, ... })
    assert(vim.v.shell_error == 0, "git failed: " .. out)
    return (out:gsub("%s+$", ""))
end

local function config(dir, key)
    local out = vim.fn.system({ "git", "-C", dir, "config", "--get", key })
    return vim.v.shell_error == 0 and (out:gsub("%s+$", "")) or nil
end

describe("upstream commands against a real repository (§17.2)", function()
    local dir
    before_each(function()
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        sh(dir, "init", "-q", "-b", "main")
        sh(dir, "config", "user.email", "t@example.invalid")
        sh(dir, "config", "user.name", "T")
        sh(dir, "config", "commit.gpgsign", "false")
        sh(dir, "commit", "-q", "--allow-empty", "-m", "base")
        local h = sh(dir, "rev-parse", "HEAD")
        sh(dir, "remote", "add", "origin", dir .. "/nonexistent.git")
        sh(dir, "update-ref", "refs/remotes/origin/dev", h)
        sh(dir, "update-ref", "refs/remotes/origin/foo", h)
        sh(dir, "branch", "-q", "foo", h)
        sh(dir, "branch", "-q", "-u", "origin/dev", "foo")
    end)
    after_each(function() vim.fn.delete(dir, "rf") end)

    it("the ref read marks the mismatch; Track sets the same-named upstream; Unset clears it", function()
        fetch.set_cwd(dir)
        local res = await(fetch.fetch_ref_entries())
        fetch.set_cwd(nil)
        local u
        for _, e in ipairs(res.entries) do if e.kind == "local" and e.name == "foo" then u = e.upstream end end
        assert.is_false(u.match)
        assert.same({ "origin" }, u.same)

        local cmd = sync.set_upstream_command("foo", "refs/remotes/origin/foo")
        assert.equals(0, await(fetch.run_checkout(cmd.argv, dir)).code)
        assert.equals("origin", config(dir, "branch.foo.remote"))
        assert.equals("refs/heads/foo", config(dir, "branch.foo.merge"))

        assert.equals(0, await(fetch.run_checkout(sync.unset_upstream_command("foo").argv, dir)).code)
        assert.is_nil(config(dir, "branch.foo.remote"))
        assert.is_nil(config(dir, "branch.foo.merge"))
    end)

    it("a vanished ref fails with git's fatal line, the config untouched", function()
        local cmd = sync.set_upstream_command("foo", "refs/remotes/origin/gone")
        local res = await(fetch.run_checkout(cmd.argv, dir))
        assert.is_true(res.code ~= 0)
        local line = git.format_git_error(cmd.label, { code = res.code, err = git.failure_text(res.out, res.err) })
        assert.truthy(line:match("does not exist"), line)
        assert.is_nil(line:find("\n"), line)
        assert.equals("refs/heads/dev", config(dir, "branch.foo.merge"))
    end)
end)
