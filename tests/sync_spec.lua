--- Tests for the branch sync (spec §17.2): fast-forward / reset a local branch to
--- its upstream. The pure decisions in `gitloom.git.sync` (the target a selected
--- ref names, which entries each tracking state gets, the argv for the current
--- branch vs any other, the reset prompt per case, the stale check), the palette
--- row entries that reach them (`palette.row_entries`, incl. a collapsed head's
--- sole local branch), then the git side against REAL scratch repositories —
--- never this one: the `%(upstream)` refname read with the refs,
--- `fetch.sync_probe`, and the commands run through `fetch.run_checkout` exactly
--- as the window glue runs them. The window glue itself (busy flag, prompt,
--- notices, resync) is untested like the rest.

---@diagnostic disable: need-check-nil

local sync = require("gitloom.git.sync")
local fetch = require("gitloom.git.fetch")
local palette = require("gitloom.graph.palette")
local selectm = require("gitloom.graph.select")

local function up(ahead, behind, extra)
    local u = { short = "origin/main", ref = "refs/remotes/origin/main", ahead = ahead, behind = behind,
        gone = false }
    for k, v in pairs(extra or {}) do u[k] = v end
    return u
end

local function local_ref(u) return { kind = "local", name = "main", upstream = u } end

-- A target the test knows exists (sync_target's nil is asserted separately).
---@return SyncTarget
local function T(ref) return assert(sync.sync_target(ref)) end

local function ids(entries)
    local out = {}
    for _, e in ipairs(entries) do out[#out + 1] = e.id end
    return out
end

describe("sync_target / sync_offers (§17.2)", function()
    local cases = {
        { "strictly behind", up(0, 3), { ff = true, reset = true } },
        { "ahead", up(2, 0), { ff = false, reset = true } },
        { "diverged", up(2, 3), { ff = false, reset = true } },
        { "in sync", up(0, 0), { ff = false, reset = false } },
    }
    for _, c in ipairs(cases) do
        it(c[1], function()
            local t = sync.sync_target(local_ref(c[2]))
            assert.is_not_nil(t)
            assert.same(c[3], sync.sync_offers(t))
        end)
    end

    it("gone, no upstream, no refname, a remote ref, a tag, a worktree, nothing: no target", function()
        assert.is_nil(sync.sync_target(local_ref(up(0, 3, { gone = true }))))
        assert.is_nil(sync.sync_target(local_ref(nil)))
        assert.is_nil(sync.sync_target(local_ref(up(0, 3, { ref = false }))))
        assert.is_nil(sync.sync_target({ kind = "remote", name = "origin/main", short = "main", upstream = up(0, 3) }))
        assert.is_nil(sync.sync_target({ kind = "tag", name = "v1" }))
        assert.is_nil(sync.sync_target({ kind = "worktree", name = "wt:x" }))
        assert.is_nil(sync.sync_target(nil))
        assert.same({ ff = false, reset = false }, sync.sync_offers(nil))
    end)

    it("carries the branch, upstream and its full refname", function()
        assert.same({ branch = "main", upstream = "origin/main", upstream_ref = "refs/remotes/origin/main",
            ahead = 1, behind = 2 }, sync.sync_target(local_ref(up(1, 2))))
    end)
end)

describe("the reset prompt's change count (§17.2)", function()
    -- `fetch.sync_probe` counts what a `reset --hard` discards as
    -- `parse_status`'s `paths - untracked`: each changed TRACKED path once.
    local parse_status = require("gitloom.git.parse").parse_status
    local function tracked(lines)
        local st = parse_status(lines)
        return st.paths - st.untracked
    end
    it("counts each changed tracked path once; untracked never", function()
        assert.equals(0, tracked({}))
        assert.equals(0, tracked({ "" }))
        assert.equals(0, tracked({ "?? new", "?? other" }))
        -- an MM file is one path, a rename one line; a trailing CR is harmless
        assert.equals(4, tracked({ "MM both\r", " M f", "A  added", "R  old -> new", "?? u", "" }))
    end)
end)

describe("ff_command / reset_command (§17.2)", function()
    local t = T({ kind = "local", name = "feat", upstream = up(0, 1) })

    it("fast-forward: merge --ff-only for the current branch, fetch . for another", function()
        assert.same({ "git", "merge", "--ff-only", "refs/remotes/origin/main" }, sync.ff_command(t, true).argv)
        assert.same({ "git", "fetch", "--no-recurse-submodules", ".",
            "refs/remotes/origin/main:refs/heads/feat" }, sync.ff_command(t, false).argv)
    end)

    it("reset: reset --hard for the current branch, branch -f for another", function()
        assert.same({ "git", "reset", "--hard", "refs/remotes/origin/main" }, sync.reset_command(t, true).argv)
        assert.same({ "git", "branch", "-f", "feat", "refs/remotes/origin/main" }, sync.reset_command(t, false).argv)
    end)

    it("never forces a refspec and never names a remote to contact", function()
        for _, cur in ipairs({ true, false }) do
            for _, cmd in ipairs({ sync.ff_command(t, cur), sync.reset_command(t, cur) }) do
                for _, a in ipairs(cmd.argv) do
                    assert.is_nil(a:match("^%+"), a)
                    assert.is_nil(a:match("^%-%-force"), a)
                    assert.not_equal("origin", a)
                end
            end
        end
    end)
end)

describe("reset_prompt / sync_stale (§17.2)", function()
    local A, B = ("a"):rep(40), ("b"):rep(40)
    local t = T(local_ref(up(2, 3)))

    it("strictly behind and clean: the question alone", function()
        local p = { tip = A, up_tip = B, head_branch = "main", ahead = 0, behind = 3, dirty = 0 }
        assert.same({ "Reset main to origin/main (bbbbbbb)?" }, sync.reset_prompt(t, p))
        assert.equals("Reset main to origin/main (bbbbbbb)?", sync.prompt_text(sync.reset_prompt(t, p)))
    end)

    it("ahead + dirty current branch: commits, changes, the reflog line", function()
        local p = { tip = A, up_tip = B, head_branch = "main", ahead = 2, behind = 3, dirty = 3 }
        assert.same({
            "Reset main to origin/main (bbbbbbb)?",
            "discards 2 local commits",
            "discards uncommitted changes to 3 files",
            "the old tip aaaaaaa stays reachable in the reflog",
        }, sync.reset_prompt(t, p))
        assert.equals("Reset main to origin/main (bbbbbbb)? discards 2 local commits; discards uncommitted "
            .. "changes to 3 files; the old tip aaaaaaa stays reachable in the reflog",
            sync.prompt_text(sync.reset_prompt(t, p)))
    end)

    it("singular counts; a dirty tree does not count for another branch", function()
        local p = { tip = A, up_tip = B, head_branch = "other", ahead = 1, behind = 0, dirty = 5 }
        assert.same({ "Reset main to origin/main (bbbbbbb)?", "discards 1 local commit",
            "the old tip aaaaaaa stays reachable in the reflog" }, sync.reset_prompt(t, p))
        p = { tip = A, up_tip = B, head_branch = "main", ahead = 0, behind = 1, dirty = 1 }
        assert.same({ "Reset main to origin/main (bbbbbbb)?", "discards uncommitted changes to 1 file",
            "the old tip aaaaaaa stays reachable in the reflog" }, sync.reset_prompt(t, p))
    end)

    it("stale: tip, upstream tip, current branch or dirty count changed; a failed read", function()
        local before = { tip = A, up_tip = B, head_branch = "main", ahead = 2, behind = 3, dirty = 1 }
        local function with(k, v)
            local a = vim.deepcopy(before)
            a[k] = v
            return a
        end
        assert.is_nil(sync.sync_stale(t, before, vim.deepcopy(before)))
        assert.is_nil(sync.sync_stale(t, before, with("behind", 9))) -- follows from the tips
        assert.matches("main moved", sync.sync_stale(t, before, with("tip", B)))
        assert.matches("origin/main moved", sync.sync_stale(t, before, with("up_tip", A)))
        assert.matches("HEAD moved", sync.sync_stale(t, before, with("head_branch", "other")))
        assert.matches("working tree changed", sync.sync_stale(t, before, with("dirty", 2)))
        assert.matches("could not be read", sync.sync_stale(t, before, with("err", { code = 1 })))
        -- Another branch's dirty count is not read (nil) — HEAD moving between two
        -- OTHER branches does not change the command either.
        local other = with("head_branch", "x")
        other.dirty = nil
        local other2 = vim.deepcopy(other)
        other2.head_branch = "y"
        assert.is_nil(sync.sync_stale(t, other, other2))
    end)

    it("notices name the upstream tip / the old tip", function()
        local p = { tip = A, up_tip = B }
        assert.equals("gitloom: main → origin/main (bbbbbbb)", sync.ff_done(t, p))
        assert.equals("gitloom: main reset to origin/main — was aaaaaaa", sync.reset_done(t, p))
        assert.is_nil(sync.sync_unavailable(t, p))
        assert.matches("origin/main no longer exists", sync.sync_unavailable(t, { tip = A }))
        assert.matches("main no longer exists", sync.sync_unavailable(t, { up_tip = B }))
    end)
end)

describe("palette row entries for the branch sync (§17.1/§17.2)", function()
    local function commit(refs) return { hash = ("c"):rep(40), parents = {}, refs = refs } end
    local function lref(name, u) return { kind = "local", name = name, upstream = u } end

    it("a selected local branch: checkout, then the offered sync entries, then collapse/hide", function()
        local c = commit({ lref("main", up(0, 2)) })
        local row = { kind = "branch", state = "expanded", commit = c, ref = selectm.selected_ref(c, 1) }
        assert.same({ "checkout", "fast_forward", "reset_branch", "collapse", "hide" },
            ids(palette.row_entries(row, true)))
        local e = palette.row_entries(row, true)[2]
        assert.equals("Fast-forward main to origin/main", e.label)
        assert.equals("Reset main to origin/main…", palette.row_entries(row, true)[3].label)
        assert.equals("refs/remotes/origin/main", e.sync.upstream_ref)
    end)

    it("ahead / diverged → reset only; in sync / gone / no upstream → none", function()
        for _, case in ipairs({
            { up(1, 0), { "checkout", "reset_branch" } },
            { up(1, 1), { "checkout", "reset_branch" } },
            { up(0, 0), { "checkout" } },
            { up(0, 2, { gone = true }), { "checkout" } },
            { nil, { "checkout" } },
        }) do
            local c = commit({ lref("main", case[1]) })
            local row = { kind = "branch", state = "mainline", commit = c, ref = selectm.selected_ref(c, 1) }
            assert.same(case[2], ids(palette.row_entries(row, true)))
        end
    end)

    it("a remote ref or a tag selected: no sync entry", function()
        local c = commit({ { kind = "remote", name = "origin/x" }, { kind = "tag", name = "v1" } })
        for i = 1, 2 do
            local row = { kind = "branch", state = "mainline", commit = c, ref = selectm.selected_ref(c, i) }
            assert.same({ "checkout" }, ids(palette.row_entries(row, true)))
        end
    end)

    it("a commit row never gets one", function()
        local c = commit({ lref("main", up(0, 2)) })
        assert.same({}, vim.tbl_filter(function(id) return id:match("fast_forward") or id:match("reset") end,
            ids(palette.row_entries({ kind = "plain", commit = c }, true))))
    end)

    it("a collapsed head / selected marker: its sole local branch; none when ambiguous", function()
        local tip = commit({})
        local head = { collapsed = true, hash = "collapsed:x", tip = tip, refs = { lref("feat", up(0, 1)) } }
        local row = { kind = "branch", state = "collapsed", commit = tip, head = head }
        assert.same({ "checkout", "fast_forward", "reset_branch", "expand", "hide" },
            ids(palette.row_entries(row, true)))
        head.refs[2] = lref("other", up(0, 1))
        assert.same({ "checkout", "expand", "hide" }, ids(palette.row_entries(row, true)))
        local mrow = { kind = "markers", markers = { "(feat)" }, selected = 1, commit = tip,
            head = { refs = { lref("feat", up(3, 0)) } } }
        assert.same({ "checkout", "reset_branch", "expand:1", "hide:1" }, ids(palette.row_entries(mrow, true)))
        -- No marker selected: per-marker expand / hide only.
        mrow.selected, mrow.head = nil, nil
        assert.same({ "expand:1", "hide:1" }, ids(palette.row_entries(mrow, true)))
    end)
end)

describe("a remote branch with a local counterpart elsewhere (§10.4.1)", function()
    local RHASH, LHASH = ("r"):rep(40), ("l"):rep(40)
    local function fooup(ahead, behind, extra)
        local u = { short = "origin/foo", ref = "refs/remotes/origin/foo", ahead = ahead, behind = behind,
            gone = false }
        for k, v in pairs(extra or {}) do u[k] = v end
        return u
    end
    -- The palette row for `origin/foo` selected on its commit, with the repo's ref
    -- registry holding a local `foo` at LHASH tracking `u` (nil: no local foo).
    local function row_for(u, opts)
        opts = opts or {}
        local c = { hash = RHASH, parents = {}, refs = {} }
        local rref = { name = "origin/foo", kind = "remote", commit = c }
        c.refs[1] = rref
        local refs = { ["origin/foo"] = rref }
        if u ~= false then
            local lc = { hash = opts.same and RHASH or LHASH, parents = {}, refs = {} }
            refs.foo = { name = "foo", kind = "local", commit = lc, upstream = u }
        end
        local ref = selectm.selected_ref(c, 1)
        ref.counterpart = selectm.local_counterpart(ref, refs, opts.head)
        return { kind = "branch", state = "mainline", commit = c, ref = ref }
    end

    it("no local foo: the DWIM checkout as before", function()
        local es = palette.row_entries(row_for(false), true)
        assert.same({ "checkout" }, ids(es))
        assert.equals("Checkout branch foo (from origin/foo)", es[1].label)
        assert.same({ "git", "switch", "foo" }, es[1].checkout.argv)
    end)

    it("a local foo on the same commit is no counterpart", function()
        assert.is_nil(row_for(fooup(0, 0), { same = true }).ref.counterpart)
    end)

    it("strictly behind: checkout + fast-forward, then the detached checkout", function()
        local es = palette.row_entries(row_for(fooup(0, 12)), true)
        assert.same({ "checkout_ff", "checkout" }, ids(es))
        assert.equals("Checkout foo and fast-forward to origin/foo", es[1].label)
        assert.equals("foo", es[1].sync.branch)
        assert.equals("refs/remotes/origin/foo", es[1].sync.upstream_ref)
        assert.equals("Checkout commit rrrrrrr (detached)", es[2].label)
        assert.same({ "git", "checkout", "--detach", RHASH }, es[2].checkout.argv)
    end)

    it("ahead or diverged: checkout + reset (prompted), then the detached checkout", function()
        for _, u in ipairs({ fooup(2, 0), fooup(2, 5) }) do
            local es = palette.row_entries(row_for(u), true)
            assert.same({ "checkout_reset", "checkout" }, ids(es))
            assert.equals("Checkout foo and reset to origin/foo…", es[1].label)
        end
    end)

    it("not tracking origin/foo (other upstream / none): the detached checkout only", function()
        local other = fooup(0, 3, { short = "upstream/foo", ref = "refs/remotes/upstream/foo" })
        for _, u in ipairs({ other, nil }) do
            local es = palette.row_entries(row_for(u), true)
            assert.same({ "checkout" }, ids(es))
            assert.same({ "git", "checkout", "--detach", RHASH }, es[1].checkout.argv)
        end
    end)

    it("in sync / gone (defensive): the detached checkout only", function()
        for _, u in ipairs({ fooup(0, 0), fooup(0, 3, { gone = true }) }) do
            assert.same({ "checkout" }, ids(palette.row_entries(row_for(u), true)))
        end
    end)

    it("foo is the current branch: the plain §17.2 entries, then the detached checkout", function()
        local es = palette.row_entries(row_for(fooup(0, 12), { head = "foo" }), true)
        assert.same({ "fast_forward", "reset_branch", "checkout" }, ids(es))
        assert.equals("Fast-forward foo to origin/foo", es[1].label)
        assert.equals("Reset foo to origin/foo…", es[2].label)
        es = palette.row_entries(row_for(fooup(1, 2), { head = "foo" }), true)
        assert.same({ "reset_branch", "checkout" }, ids(es))
    end)

    it("the commands: fetch . then switch; switch -C; the prompt and the notes", function()
        local t = T({ kind = "local", name = "foo", upstream = fooup(0, 12) })
        local ff = sync.checkout_commands(t, false)
        assert.same({ "git", "fetch", "--no-recurse-submodules", ".",
            "refs/remotes/origin/foo:refs/heads/foo" }, ff[1].argv)
        assert.same({ "git", "switch", "foo" }, ff[2].argv)
        local rs = sync.checkout_commands(t, true)
        assert.equals(1, #rs)
        assert.same({ "git", "switch", "-C", "foo", "refs/remotes/origin/foo" }, rs[1].argv)
        for _, cmds in ipairs({ ff, rs }) do
            for _, c in ipairs(cmds) do
                for _, a in ipairs(c.argv) do
                    assert.is_true(not (a == "--force" or a == "-f" or a:match("^%+")), a)
                end
            end
        end
        local p = { tip = ("a"):rep(40), up_tip = ("d"):rep(40), head_branch = "main", ahead = 2, behind = 1 }
        assert.same({ "Check out foo and reset it to origin/foo (ddddddd)?", "discards 2 local commits",
            "the old tip aaaaaaa stays reachable in the reflog" }, sync.reset_prompt(t, p, true))
        assert.equals("fast-forwarded to origin/foo", sync.checkout_note(t, p, false))
        assert.equals("reset to origin/foo, was aaaaaaa", sync.checkout_note(t, p, true))
    end)
end)

-- ── The git side against real scratch repositories ───────────────────────────

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

local function write(path, text)
    local f = assert(io.open(path, "w"))
    f:write(text)
    f:close()
end

local function read(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local t = f:read("*a")
    f:close()
    return t
end

local function commit_file(dir, name, text, msg)
    write(dir .. "/" .. name, text)
    sh(dir, "add", "-A")
    sh(dir, "commit", "-q", "-m", msg)
    return sh(dir, "rev-parse", "HEAD")
end

-- A repository whose `origin/main` (a remote-tracking ref created locally — no
-- network, the remote URL is never contacted) is two commits ahead of `base`.
-- `main` and `feat` both track it; `main` is checked out. Returns dir + hashes.
local function scratch()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    sh(dir, "init", "-q", "-b", "main")
    sh(dir, "config", "user.email", "t@example.invalid")
    sh(dir, "config", "user.name", "T")
    sh(dir, "config", "commit.gpgsign", "false")
    sh(dir, "config", "core.autocrlf", "false")
    local base = commit_file(dir, "f", "1\n", "base")
    commit_file(dir, "f", "2\n", "up1")
    local upstream = commit_file(dir, "g", "g\n", "up2")
    sh(dir, "remote", "add", "origin", dir .. "/nonexistent.git")
    sh(dir, "update-ref", "refs/remotes/origin/main", upstream)
    sh(dir, "reset", "-q", "--hard", base)
    sh(dir, "branch", "-q", "feat", base)
    sh(dir, "branch", "-q", "-u", "origin/main", "main")
    sh(dir, "branch", "-q", "-u", "origin/main", "feat")
    return dir, base, upstream
end

local function target(branch, ahead, behind)
    return { branch = branch, upstream = "origin/main", upstream_ref = "refs/remotes/origin/main",
        ahead = ahead or 0, behind = behind or 2 }
end

local function probe(t, dir) return await(fetch.sync_probe(t, dir)) end
local function run(argv, dir) return await(fetch.run_checkout(argv, dir)) end
local function tip(dir, b) return sh(dir, "rev-parse", "refs/heads/" .. b) end

describe("branch sync against a real repository (§17.2)", function()
    local dir, base, upstream
    before_each(function() dir, base, upstream = scratch() end)
    after_each(function() vim.fn.delete(dir, "rf") end)

    it("the ref read carries the upstream's full refname + counts", function()
        fetch.set_cwd(dir)
        local res = await(fetch.fetch_ref_entries())
        fetch.set_cwd(nil)
        local by = {}
        for _, e in ipairs(res.entries) do by[e.kind .. ":" .. e.name] = e end
        local u = by["local:main"].upstream
        assert.same({ short = "origin/main", ref = "refs/remotes/origin/main", remote = "origin",
            merge = "refs/heads/main", match = true, gone = false, ahead = 0, behind = 2 }, u)
        assert.is_nil(by["remote:origin/main"].upstream)
        assert.equals(upstream, by["remote:origin/main"].hash)
    end)

    it("probe: tips, current branch, counts, dirty only for the current branch", function()
        write(dir .. "/f", "dirty\n")
        write(dir .. "/new", "untracked\n")
        local p = probe(target("main"), dir)
        assert.same({ tip = base, up_tip = upstream, head_branch = "main", ahead = 0, behind = 2, dirty = 1 }, p)
        p = probe(target("feat"), dir)
        assert.is_nil(p.dirty)
        assert.equals("main", p.head_branch)
    end)

    it("fast-forwards a branch that is not checked out, the working tree untouched", function()
        write(dir .. "/f", "dirty\n")
        local p = probe(target("feat"), dir)
        local res = run(sync.ff_command(target("feat"), p.head_branch == "feat").argv, dir)
        assert.equals(0, res.code, res.err)
        assert.equals(upstream, tip(dir, "feat"))
        assert.equals(base, tip(dir, "main"))
        assert.equals("dirty\n", read(dir .. "/f"))
        assert.is_nil(read(dir .. "/g"))
    end)

    it("fast-forwards the current branch", function()
        local res = run(sync.ff_command(target("main"), true).argv, dir)
        assert.equals(0, res.code, res.err)
        assert.equals(upstream, tip(dir, "main"))
        assert.equals("g\n", read(dir .. "/g"))
    end)

    it("refuses a diverged fast-forward, the branch unmoved (both forms)", function()
        local mine = commit_file(dir, "h", "h\n", "local")
        sh(dir, "branch", "-q", "-f", "feat", mine)
        assert.not_equal(0, run(sync.ff_command(target("main", 1), true).argv, dir).code)
        assert.equals(mine, tip(dir, "main"))
        assert.not_equal(0, run(sync.ff_command(target("feat", 1), false).argv, dir).code)
        assert.equals(mine, tip(dir, "feat"))
    end)

    it("refuses to fast-forward the current branch over a conflicting dirty file", function()
        write(dir .. "/f", "mine\n")
        local res = run(sync.ff_command(target("main"), true).argv, dir)
        assert.not_equal(0, res.code)
        assert.equals(base, tip(dir, "main"))
        assert.equals("mine\n", read(dir .. "/f"))
    end)

    it("resets the current branch (ahead + dirty), an untracked file survives", function()
        commit_file(dir, "h", "h\n", "local")
        write(dir .. "/f", "dirty\n")
        write(dir .. "/new", "untracked\n")
        local p = probe(target("main"), dir)
        assert.same({ 1, 2, 1 }, { p.ahead, p.behind, p.dirty })
        assert.equals(4, #sync.reset_prompt(target("main"), p))
        local res = run(sync.reset_command(target("main"), true).argv, dir)
        assert.equals(0, res.code, res.err)
        assert.equals(upstream, tip(dir, "main"))
        assert.equals("2\n", read(dir .. "/f"))
        assert.is_nil(read(dir .. "/h"))
        assert.equals("untracked\n", read(dir .. "/new"))
    end)

    it("resets the current branch when strictly ahead", function()
        sh(dir, "reset", "-q", "--hard", upstream)
        commit_file(dir, "h", "h\n", "local")
        local res = run(sync.reset_command(target("main", 1, 0), true).argv, dir)
        assert.equals(0, res.code, res.err)
        assert.equals(upstream, tip(dir, "main"))
    end)

    it("resets a branch that is not checked out, the working tree untouched", function()
        local mine = commit_file(dir, "h", "h\n", "local")
        sh(dir, "branch", "-q", "-f", "feat", mine)
        sh(dir, "reset", "-q", "--hard", base)
        write(dir .. "/f", "dirty\n")
        local res = run(sync.reset_command(target("feat", 1), false).argv, dir)
        assert.equals(0, res.code, res.err)
        assert.equals(upstream, tip(dir, "feat"))
        assert.equals(base, tip(dir, "main"))
        assert.equals("dirty\n", read(dir .. "/f"))
    end)

    it("refuses both for a branch checked out in a linked worktree", function()
        local wt = dir .. "-wt"
        sh(dir, "worktree", "add", "-q", wt, "feat")
        local p = probe(target("feat"), dir)
        assert.not_equal("feat", p.head_branch)
        assert.not_equal(0, run(sync.ff_command(target("feat"), false).argv, dir).code)
        assert.not_equal(0, run(sync.reset_command(target("feat"), false).argv, dir).code)
        assert.equals(base, tip(dir, "feat"))
        sh(dir, "worktree", "remove", "--force", wt)
    end)

    it("a tip moved after the prompt is stale; an unchanged state is not", function()
        local t = target("main")
        local before = probe(t, dir)
        assert.is_nil(sync.sync_stale(t, before, probe(t, dir)))
        commit_file(dir, "h", "h\n", "meanwhile")
        assert.matches("main moved", sync.sync_stale(t, before, probe(t, dir)))
        local before2 = probe(t, dir)
        write(dir .. "/f", "dirty\n")
        assert.matches("working tree changed", sync.sync_stale(t, before2, probe(t, dir)))
    end)

    -- §10.4.1: checking out `origin/main` when the local `main` sits elsewhere.
    local function steps(cmds) return await(fetch.run_steps(cmds, dir)) end
    local function head_branch() return sh(dir, "symbolic-ref", "--short", "HEAD") end

    it("checkout + fast-forward: main fast-forwarded and checked out", function()
        sh(dir, "switch", "-q", "-c", "other")
        local res = steps(sync.checkout_commands(target("main"), false))
        assert.equals(0, res.code, res.err)
        assert.equals(upstream, tip(dir, "main"))
        assert.equals("main", head_branch())
        assert.equals("g\n", read(dir .. "/g"))
    end)

    it("checkout + fast-forward refuses a diverged branch: nothing changes", function()
        local mine = commit_file(dir, "h", "h\n", "local")
        sh(dir, "switch", "-q", "-c", "other")
        local res = steps(sync.checkout_commands(target("main", 1), false))
        assert.not_equal(0, res.code)
        assert.equals(1, res.step)
        assert.equals(mine, tip(dir, "main"))
        assert.equals("other", head_branch())
    end)

    it("a switch refused after the fast-forward leaves main fast-forwarded", function()
        sh(dir, "switch", "-q", "-c", "other")
        write(dir .. "/f", "mine\n")
        local res = steps(sync.checkout_commands(target("main"), false))
        assert.not_equal(0, res.code)
        assert.equals(2, res.step)
        assert.equals("git switch", res.failed.label)
        assert.equals(upstream, tip(dir, "main"))
        assert.equals("other", head_branch())
        assert.equals("mine\n", read(dir .. "/f"))
    end)

    it("checkout + reset: a diverged main reset and checked out in one step", function()
        local mine = commit_file(dir, "h", "h\n", "local")
        sh(dir, "switch", "-q", "-c", "other", base)
        local t = target("main", 1)
        local p = probe(t, dir)
        assert.same({ 1, 2 }, { p.ahead, p.behind })
        assert.equals(3, #sync.reset_prompt(t, p, true))
        local res = steps(sync.checkout_commands(t, true))
        assert.equals(0, res.code, res.err)
        assert.equals(upstream, tip(dir, "main"))
        assert.equals("main", head_branch())
        assert.is_nil(read(dir .. "/h"))
        assert.equals("refs/remotes/origin/main", sh(dir, "rev-parse", "--symbolic-full-name", "main@{upstream}"))
        -- The old tip stays in the reflog.
        assert.matches(mine:sub(1, 7), sh(dir, "reflog", "--format=%h", "main"))
    end)

    it("checkout + reset never forces over a conflicting dirty file", function()
        local mine = commit_file(dir, "h", "h\n", "local")
        sh(dir, "switch", "-q", "-c", "other", base)
        write(dir .. "/f", "mine\n")
        local res = steps(sync.checkout_commands(target("main", 1), true))
        assert.not_equal(0, res.code)
        assert.equals(mine, tip(dir, "main"))
        assert.equals("other", head_branch())
        assert.equals("mine\n", read(dir .. "/f"))
    end)

    it("a local-branch upstream works the same way (refs/heads/<upstream>)", function()
        sh(dir, "branch", "-q", "trunk", upstream)
        sh(dir, "branch", "-q", "-u", "trunk", "feat")
        fetch.set_cwd(dir)
        local res = await(fetch.fetch_ref_entries())
        fetch.set_cwd(nil)
        local u
        for _, e in ipairs(res.entries) do if e.kind == "local" and e.name == "feat" then u = e.upstream end end
        assert.equals("refs/heads/trunk", u.ref)
        local t = T({ kind = "local", name = "feat", upstream = u })
        assert.same({ ff = true, reset = true }, sync.sync_offers(t))
        assert.equals(0, run(sync.ff_command(t, false).argv, dir).code)
        assert.equals(upstream, tip(dir, "feat"))
    end)
end)
