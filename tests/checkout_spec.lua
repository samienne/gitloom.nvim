--- Tests for the `<CR>` action menu and checkout (spec §10.4, §10.4.1): the pure
--- menu builder (`cr_menu` — entry order per row kind, no checkout on a §4.2
--- virtual commit), the selected-ref resolver (`selected_ref`), the per-ref-kind
--- argv (`checkout_spec` — never forcing), and `run_checkout` against a REAL
--- scratch repository: a switch that lands, and a refused one (a dirty file the
--- checkout would overwrite) reporting a non-zero code + git's stderr while
--- leaving HEAD where it was. The window glue is untested like the rest of it.

local internal = require("gitloom.graph")._internal
local cr_menu = internal.cr_menu
local checkout_spec = internal.checkout_spec
local selected_ref = internal.selected_ref

local H = ("a"):rep(40)

-- checkout_spec, asserted non-nil (and narrowed for the type checker).
---@return CheckoutSpec
local function spec_of(c, ref)
    local s = checkout_spec(c, ref)
    assert(s, "expected a checkout spec")
    return s
end

local function commit(refs, extra)
    local c = { hash = H, refs = refs or {} }
    for k, v in pairs(extra or {}) do c[k] = v end
    return c
end

local function actions(menu)
    local out = {}
    for _, e in ipairs(menu) do out[#out + 1] = e.action end
    return out
end

local function labels(menu)
    local out = {}
    for _, e in ipairs(menu) do out[#out + 1] = e.label end
    return out
end

describe("selected_ref (§10.4.1)", function()
    local refs = {
        { kind = "head", name = "HEAD" },
        { kind = "local", name = "main" },
        { kind = "remote", name = "origin/main" },
        { kind = "remote", name = "origin/feat" },
        { kind = "tag", name = "v1" },
        { kind = "worktree", name = "wt:side" },
    }

    it("resolves each decoration in decoration order", function()
        local c = commit(refs)
        assert.same({ kind = "local", name = "main" }, selected_ref(c, 1))
        assert.same({ kind = "remote", name = "origin/feat", short = "feat" }, selected_ref(c, 2))
        assert.same({ kind = "tag", name = "v1" }, selected_ref(c, 3))
        assert.same({ kind = "worktree", name = "wt:side" }, selected_ref(c, 4))
        assert.is_nil(selected_ref(c, 5))
    end)

    it("is nil with no selection", function()
        assert.is_nil(selected_ref(commit(refs), nil))
        assert.is_nil(selected_ref(nil, 1))
    end)
end)

describe("checkout_spec (§10.4.1)", function()
    it("switches to a local branch", function()
        local s = spec_of(commit(), { kind = "local", name = "feat/x" })
        assert.same({ "git", "switch", "feat/x" }, s.argv)
        assert.equals("Checkout branch feat/x", s.label)
    end)

    it("switches to a remote branch by its short name (git's DWIM)", function()
        local s = spec_of(commit(), { kind = "remote", name = "origin/foo", short = "foo" })
        assert.same({ "git", "switch", "foo" }, s.argv)
        assert.equals("Checkout branch foo (from origin/foo)", s.label)
    end)

    it("detaches for a tag, a worktree label, or no ref", function()
        for _, ref in ipairs({ { kind = "tag", name = "v1" }, { kind = "worktree", name = "wt:x" }, false }) do
            local s = spec_of(commit(), ref or nil)
            assert.same({ "git", "checkout", "--detach", H }, s.argv)
            assert.equals("Checkout commit aaaaaaa (detached)", s.label)
        end
    end)

    it("detaches at a collapsed head's TIP, never its synthetic id", function()
        local head = { collapsed = true, hash = "collapsed:x", refs = {}, tip = commit() }
        assert.same({ "git", "checkout", "--detach", H }, checkout_spec(head, nil).argv)
    end)

    it("never forces", function()
        for _, ref in ipairs({ { kind = "local", name = "a" }, { kind = "remote", name = "o/a", short = "a" }, false }) do
            for _, a in ipairs(checkout_spec(commit(), ref or nil).argv) do
                assert.is_nil(a:match("^%-%-force") or (a == "-f" and a) or a:match("^%-%-discard"))
            end
        end
    end)

    it("is nil for a working-tree virtual commit or no commit", function()
        assert.is_nil(checkout_spec(commit({}, { virtual = "staged" }), nil))
        assert.is_nil(checkout_spec(nil, nil))
    end)
end)

describe("cr_menu (§10.4)", function()
    it("plain row: examine first, then diff, then checkout", function()
        local m = cr_menu({ kind = "plain", commit = commit(), has_diff = true })
        assert.same({ "examine", "diff", "checkout" }, actions(m))
        assert.same({ "Examine commit", "Open diff", "Checkout commit aaaaaaa (detached)" }, labels(m))
    end)

    it("plain row without a diff provider: examine, checkout", function()
        assert.same({ "examine", "checkout" }, actions(cr_menu({ kind = "plain", commit = commit() })))
    end)

    it("plain virtual row: no checkout", function()
        local m = cr_menu({ kind = "plain", commit = commit({}, { virtual = "unstaged" }), has_diff = true })
        assert.same({ "examine", "diff" }, actions(m))
    end)

    it("selected expanded branch: existing order, checkout last", function()
        local m = cr_menu({ kind = "branch", state = "expanded", commit = commit(), has_diff = true,
            ref = { kind = "local", name = "main" } })
        assert.same({ "collapse", "hide", "examine", "diff", "checkout" }, actions(m))
        assert.equals("Checkout branch main", m[#m].label)
    end)

    it("collapsed head: expand, hide, examine tip, diff, checkout of the tip", function()
        local head = { collapsed = true, hash = "collapsed:x", refs = {}, tip = commit() }
        local m = cr_menu({ kind = "branch", state = "collapsed", commit = head, has_diff = true })
        assert.same({ "expand", "hide", "examine", "diff", "checkout" }, actions(m))
        assert.equals("Examine tip commit", m[3].label)
        assert.equals(H, m[3].commit.hash)
        assert.same({ "git", "checkout", "--detach", H }, m[5].checkout.argv)
    end)

    it("packed markers: expand/hide per marker; checkout only with a marker selected", function()
        local m = cr_menu({ kind = "markers", markers = { "◍ a", "◍ b" } })
        assert.same({ "expand", "hide", "expand", "hide" }, actions(m))
        assert.equals(2, m[3].marker)
        local sel = cr_menu({ kind = "markers", markers = { "◍ a", "◍ b" }, commit = commit() })
        assert.same({ "expand", "hide", "expand", "hide", "checkout" }, actions(sel))
    end)
end)

describe("run_checkout against a real repository (§10.4.1)", function()
    local fetch = require("gitloom.git.fetch")
    local repo

    local function await(future)
        local res
        future.next(function(r) res = r end)
        vim.wait(20000, function() return res ~= nil end, 20)
        return res
    end

    local function sh(...)
        local out = vim.fn.system({ "git", "-C", repo, ... })
        assert.equals(0, vim.v.shell_error, out)
        return vim.trim(out)
    end

    -- main: root <- second; branch `other` at root with a different `f`.
    before_each(function()
        if repo then return end
        repo = vim.fn.tempname()
        vim.fn.mkdir(repo, "p")
        vim.fn.system({ "git", "init", "-q", "-b", "main", repo })
        assert.equals(0, vim.v.shell_error)
        sh("config", "user.email", "t@example.invalid")
        sh("config", "user.name", "T")
        vim.fn.writefile({ "base" }, repo .. "/f")
        sh("add", "-A")
        sh("commit", "-q", "-m", "root")
        sh("branch", "other")
        vim.fn.writefile({ "second" }, repo .. "/f")
        sh("commit", "-q", "-am", "second")
    end)

    it("switches to a branch in the given root (not the cwd)", function()
        local res = await(fetch.run_checkout(checkout_spec(commit(), { kind = "local", name = "other" }).argv, repo))
        assert.equals(0, res.code, res.err)
        assert.equals("other", sh("rev-parse", "--abbrev-ref", "HEAD"))
        sh("switch", "-q", "main")
    end)

    it("detaches at a commit", function()
        local root = sh("rev-parse", "HEAD~1")
        local res = await(fetch.run_checkout(checkout_spec(commit({}, { hash = root }), nil).argv, repo))
        assert.equals(0, res.code, res.err)
        assert.equals("HEAD", sh("rev-parse", "--abbrev-ref", "HEAD"))
        assert.equals(root, sh("rev-parse", "HEAD"))
        sh("switch", "-q", "main")
    end)

    it("refuses over a conflicting dirty file: non-zero code, git's stderr, HEAD unmoved", function()
        vim.fn.writefile({ "DIRTY" }, repo .. "/f")
        local res = await(fetch.run_checkout({ "git", "switch", "other" }, repo))
        assert.is_true(res.code ~= 0)
        assert.is_true(#res.err > 0)
        assert.equals("main", sh("rev-parse", "--abbrev-ref", "HEAD"))
        assert.same({ "DIRTY" }, vim.fn.readfile(repo .. "/f"))
        local msg = require("gitloom.git").format_git_error("git switch", res)
        assert.truthy(msg:match("^git switch failed %(exit %d+%): .+"))
    end)

    it("releases the scratch repository", function()
        vim.fn.delete(repo, "rf")
        assert.equals(0, vim.fn.isdirectory(repo))
    end)
end)
