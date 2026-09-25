-- The external diff provider targets the graph's repository root (spec §2.1,
-- §11.5), not Neovim's cwd.
--
-- gitloom runs every git query in the graph's repository root (`repo.root`),
-- which differs from Neovim's cwd whenever the graph was opened on a submodule,
-- via the repository picker, on an explicit folder, or as a drilled-in
-- submodule frame (§11.7.6). diffview, left to itself, resolves its repository
-- from the current buffer / cwd — so it looked the graph's commit up in the
-- WRONG repository and failed with `Failed to parse rev '<hash>^!'!`. The fix:
-- a `DiffRange` carries the repository it belongs to (`root`), and the default
-- provider hands it to diffview as `-C<root>`.
--
-- Three layers: the pure range builders stamp `root`; the pure argv builder
-- (`diffview_args`) turns a range into diffview's argument list; and — when
-- diffview is installed alongside plenary — the real provider is driven against
-- the real diffview with cwd in one repository and the graph in another.

---@diagnostic disable: missing-fields, need-check-nil

local git = require("gitloom.git")
local range = require("gitloom.git.range")
local window = require("gitloom.window")

local ROOT = "C:/some where/repo"

-- Minimal Commit shapes: only the fields the builders read.
local function commit(hash, parents, virtual)
    return { hash = hash, parents = parents or {}, virtual = virtual }
end

describe("DiffRange carries the repository root (§11.5)", function()
    local p = commit("p1")
    local c = commit("c1", { p })

    it("commit_range stamps root on a real commit, a root commit and every virtual node", function()
        assert.equals(ROOT, git.commit_range(c, ROOT).root)
        assert.equals(ROOT, git.commit_range(commit("r0"), ROOT).root)
        for _, v in ipairs({ "staged", "unstaged", "untracked" }) do
            assert.equals(ROOT, git.commit_range(commit("v-" .. v, { c }, v), ROOT).root)
        end
    end)

    it("leaves root nil when none is given (the range is otherwise unchanged)", function()
        local with, without = git.commit_range(c, ROOT), git.commit_range(c)
        assert.is_nil(without.root)
        assert.equals(without.rev, with.rev)
        assert.equals(without.from, with.from)
        assert.equals(without.to, with.to)
    end)

    it("range_endpoints stamps root on every shape: single, span, root span, working tree", function()
        local g = commit("g1", { c })
        local root_commit = commit("r0")
        local top = commit("t1", { root_commit })
        local staged = commit("s", { g }, "staged")
        local unstaged = commit("u", { staged }, "unstaged")
        assert.equals(ROOT, git.range_endpoints(c, c, ROOT).root)          -- single
        assert.equals(ROOT, git.range_endpoints(g, c, ROOT).root)          -- span
        assert.equals(ROOT, git.range_endpoints(top, root_commit, ROOT).root) -- empty-tree base
        assert.equals(ROOT, git.range_endpoints(staged, c, ROOT).root)     -- --cached <base>
        assert.equals(ROOT, git.range_endpoints(unstaged, c, ROOT).root)   -- <base>
        assert.equals(ROOT, git.range_endpoints(unstaged, staged, ROOT).root) -- worktree-only
        assert.is_nil(git.range_endpoints(g, c).root)
    end)
end)

describe("diffview_args (the default provider's argv, §11.5)", function()
    it("leads with -C<root> and passes a single-commit rev as one argument", function()
        assert.same({ "-C" .. ROOT, "abc^!" },
            range.diffview_args({ rev = "abc^!", to = {}, root = ROOT }))
    end)

    it("keeps a root with spaces as ONE argument (no Ex-command-line splitting)", function()
        local args = range.diffview_args({ rev = "a..b", to = {}, root = "C:/a b/c d" })
        assert.same({ "-CC:/a b/c d", "a..b" }, args)
    end)

    it("splits the working-tree `--cached <base>` form into flag + rev", function()
        assert.same({ "-C" .. ROOT, "--cached", "abc" },
            range.diffview_args({ rev = "--cached abc", to = "index", root = ROOT }))
        assert.same({ "-C" .. ROOT, "--cached" },
            range.diffview_args({ rev = "--cached", to = "index", root = ROOT }))
    end)

    it("an empty rev (worktree vs index) yields only the -C flag", function()
        assert.same({ "-C" .. ROOT }, range.diffview_args({ rev = "", to = "worktree", root = ROOT }))
    end)

    it("omits -C when the range has no root (diffview falls back to cwd, as before)", function()
        assert.same({ "abc^!" }, range.diffview_args({ rev = "abc^!", to = {} }))
    end)
end)

-- ── End to end against the real diffview ─────────────────────────────────────

local dv_path = vim.fn.stdpath("data") .. "/lazy/diffview.nvim"
local have_dv = vim.fn.isdirectory(dv_path) == 1

local function sh(dir, ...)
    local out = vim.fn.system({ "git", "-C", dir, ... })
    assert(vim.v.shell_error == 0, "git failed: " .. out)
    return (out:gsub("%s+$", ""))
end

-- A scratch repository with one commit touching `file`; returns its toplevel
-- exactly as `git rev-parse --show-toplevel` spells it (which is what
-- gitloom stores as `repo.root`, §2.1) and its HEAD hash.
local function scratch_repo(dir, file)
    vim.fn.mkdir(dir, "p")
    sh(dir, "init", "-q")
    sh(dir, "config", "user.email", "t@t")
    sh(dir, "config", "user.name", "t")
    sh(dir, "config", "commit.gpgsign", "false")
    local f = io.open(dir .. "/" .. file, "w")
    f:write("one\n")
    f:close()
    sh(dir, "add", file)
    sh(dir, "commit", "-q", "-m", "init " .. file)
    f = io.open(dir .. "/" .. file, "a")
    f:write("two\n")
    f:close()
    sh(dir, "commit", "-q", "-am", "second " .. file)
    return sh(dir, "rev-parse", "--show-toplevel"), sh(dir, "rev-parse", "HEAD")
end

local function norm(p)
    return (vim.fs.normalize(p):gsub("/+$", ""):lower())
end

;(have_dv and describe or pending)("the default provider drives the real diffview (§2.1/§11.5)", function()
    local base, cwd_repo, graph_repo, graph_root, graph_head
    local old_cwd

    -- plenary.busted has no setup/teardown: the fixture is built once, lazily,
    -- from the first before_each, and torn down by the last `it`.
    local function init()
        if base then return end
        vim.opt.rtp:prepend(dv_path)
        vim.cmd("runtime plugin/diffview.lua")
        require("diffview").setup({ use_icons = false })
        base = vim.fn.tempname()
        -- cwd is one repository; the graph targets ANOTHER one, whose path has a
        -- space in it (the Ex-command-line / arg-parser escaping case).
        cwd_repo = base .. "/cwd-repo"
        graph_repo = base .. "/graph repo"
        scratch_repo(cwd_repo, "a.txt")
        graph_root, graph_head = scratch_repo(graph_repo, "b.txt")
        old_cwd = vim.fn.getcwd()
        vim.cmd.cd(vim.fn.fnameescape(cwd_repo))
    end

    before_each(init)

    local opened -- the view the current test opened, if any
    after_each(function()
        -- Let the view finish its async load, and leave it open: closing a view
        -- (or wiping its buffers) between tests races diffview's own async
        -- teardown, and the failure surfaces inside the NEXT test's open. Every
        -- view is closed once, in the final cleanup.
        if opened then
            vim.wait(5000, function() return opened.ready == true end, 20)
            vim.wait(300)
            opened = nil
        end
    end)

    -- Drive the default provider on `r`. Returns the view diffview registered
    -- (nil if none) and the warnings/errors raised DURING the call — which is
    -- where diffview resolves the repository and parses the rev (the bug's
    -- `Failed to parse rev` is raised synchronously). Diffview's later async
    -- buffer loading is deliberately outside the capture: it is diffview's own
    -- headless behaviour, not the repository resolution under test.
    local function open(r)
        local lib = require("diffview.lib")
        local n0 = #lib.views
        local errors = {}
        local old_notify = vim.notify
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.notify = function(msg, level)
            if (level or 0) >= vim.log.levels.WARN then errors[#errors + 1] = msg end
        end
        local ok, err = pcall(window._internal.open_diffview, r)
        vim.notify = old_notify
        assert(ok, err)
        opened = (#lib.views > n0) and lib.views[#lib.views] or nil
        return opened, errors
    end

    it("opens a single-commit range of the GRAPH's repository, not the cwd's", function()
        local c = { hash = graph_head, parents = { { hash = sh(graph_repo, "rev-parse", "HEAD~1") } } }
        local v, errors = open(git.commit_range(c, graph_root))
        assert.same({}, errors)
        assert.is_not_nil(v, "diffview opened no view")
        assert.equals(norm(graph_root), norm(v.adapter.ctx.toplevel))
    end)

    it("opens a working-tree (single-rev) range in the graph's repository", function()
        -- The unstaged node's range: `HEAD` vs the working tree. It would
        -- "succeed" in the cwd repo too (it has a HEAD), so the toplevel is the
        -- only discriminator.
        local c = { hash = "0000000000000000000000000000000000000001", parents = {}, virtual = "unstaged" }
        local v, errors = open(git.commit_range(c, graph_root))
        assert.same({}, errors)
        assert.is_not_nil(v, "diffview opened no view")
        assert.equals(norm(graph_root), norm(v.adapter.ctx.toplevel))
    end)

    it("(cleanup)", function()
        vim.cmd.tabnew()
        for _, v in ipairs(vim.list_extend({}, require("diffview.lib").views)) do
            pcall(function() v:close() end)
        end
        vim.wait(300)
        while #vim.api.nvim_list_tabpages() > 1 do pcall(vim.cmd.tabclose, { bang = true }) end
        vim.cmd.cd(vim.fn.fnameescape(old_cwd))
        vim.fn.delete(base, "rf")
    end)
end)
