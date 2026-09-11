-- The git I/O layer's **argv bound** (spec §3.4).
--
-- `M.new_commits_query` is the resync's query builder: the one command in the
-- library whose revision list scales with the repository's *ref count*. An argv
-- is a hard-capped resource — on Windows the entire command line must fit 32767
-- characters including the resolved executable path, and libuv rejects an
-- overlong one with UV_ENAMETOOLONG, which nvim surfaces as
--
--     E903: Process failed to start: name too long: 'C:\...\git.EXE'
--
-- (measured on nvim 0.11.6 AND 0.12.5 / Windows 11 by bisecting `jobstart`: the
-- last command line that spawns is 32766 characters, and it is the ONLY spawn
-- input that produces the error — cwd depth/validity, environment size, variable
-- count and `$PATH` length each move the threshold by exactly zero). A resync
-- puts every current tip AND every previous tip on that line, so at 41 bytes per
-- hash a repository with a few hundred distinct ref tips walks into the cap.
--
-- The fix is to carry the revisions on **stdin** (`git log --stdin`), which
-- removes the bound instead of raising it. These specs pin that: the argv must
-- stay constant-size however many tips are passed, and the stdin form must
-- return exactly the same commits as the old command-line form.

local fetch = require("gitloom.git.fetch")

-- A stand-in for the resolved executable path Neovim substitutes for a bare
-- argv[0] (`exepath("git")`); libuv then quotes it because it holds a space.
local EXE = [[C:\Program Files\Git\cmd\git.EXE]]
-- The measured budget and the measured length model live in the library, so the
-- test and the `vim.g.gitloom_git_debug` records price a spawn the same way (see
-- tests/git_debug_spec.lua, which pins the model against the bisected numbers).
local WINDOWS_CMDLINE_MAX = fetch._internal.WIN_CMDLINE_MAX

-- The command line libuv builds from an argv: argv[0] swapped for the resolved
-- exe path, every element quoted as `quote_cmd_arg` would, joined with spaces.
local function cmdline_len(argv)
    local resolved = { EXE }
    for i = 2, #argv do resolved[i] = argv[i] end
    return fetch._internal.cmdline_len(resolved)
end

local function fake_tips(n, seed)
    local out = {}
    for i = 1, n do
        out[i] = string.format("%040x", seed * 1000000 + i)
    end
    return out
end

describe("new_commits_query (§3.4)", function()
    it("keeps every revision off the command line", function()
        local new_tips, old_tips = fake_tips(500, 1), fake_tips(500, 2)
        local argv = fetch.new_commits_query(new_tips, old_tips)

        -- The argv is the bare command: no revision, and no `--not`, on it.
        for _, a in ipairs(argv) do
            assert.is_nil(a:match("^%^?%x%x%x%x%x%x%x%x"))
            assert.is_true(a ~= "--not")
        end
        assert.is_true(#argv < 10)
    end)

    it("stays inside the Windows command-line limit at any ref count", function()
        for _, n in ipairs({ 0, 1, 200, 1000, 5000 }) do
            local argv = fetch.new_commits_query(fake_tips(math.max(n, 1), 1), fake_tips(n, 2))
            assert.is_true(cmdline_len(argv) < WINDOWS_CMDLINE_MAX,
                ("command line is %d characters for %d tips per side (cap %d)")
                :format(cmdline_len(argv), n, WINDOWS_CMDLINE_MAX))
        end
    end)

    it("writes positives plain and exclusions with a caret, one per line", function()
        local _, stdin = fetch.new_commits_query({ "aaa", "bbb" }, { "ccc" })
        assert.equals("aaa\nbbb\n^ccc\n", stdin)
    end)

    it("writes no exclusion when there are no old tips", function()
        local _, stdin = fetch.new_commits_query({ "aaa" }, {})
        assert.equals("aaa\n", stdin)
    end)

    it("asks git to read the revisions from stdin", function()
        local argv = fetch.new_commits_query({ "aaa" }, { "bbb" })
        assert.is_true(vim.tbl_contains(argv, "--stdin"))
        assert.is_true(vim.tbl_contains(argv, "--parents"))
    end)

    -- The transport change must be invisible: same commits, same bytes.
    it("returns byte-identical output to the old command-line form", function()
        local head = vim.fn.systemlist({ "git", "rev-parse", "HEAD" })[1]
        if vim.v.shell_error ~= 0 or not head or #head ~= 40 then
            pending("not inside a git repository")
            return
        end
        local base = vim.fn.systemlist({ "git", "rev-parse", "HEAD~20" })[1]
        if vim.v.shell_error ~= 0 or not base or #base ~= 40 then
            pending("history too short")
            return
        end

        local argv, stdin = fetch.new_commits_query({ head }, { base })
        local via_stdin = vim.fn.system(argv, stdin)

        local inline = { "git", "log", "--parents",
            "--pretty=format:%H%x1f%P%x1f%an%x1f%at%x1f%ai%x1f%ct%x1f%s",
            head, "--not", base }
        local via_argv = vim.fn.system(inline)

        assert.equals(via_argv, via_stdin)
        assert.is_true(#via_stdin > 0)
    end)
end)

--- The range diff's **exit code** (spec §13.5).
---
--- `fetch_range_diff` is the one diff fetch whose arguments are *derived* rather
--- than named by the user: `from` is the older selected end's first parent and
--- `to` is the newer end. It used to resolve `table.concat(out, "\n")` from
--- `on_exit` whatever git returned, so a `git diff` that failed arrived as an
--- empty string and the range view rendered its commit list with no patch and no
--- error — indistinguishable from a range that genuinely changed nothing. It now
--- resolves `git_code`'s `{ code, out, err }` so the caller can say so.
---
--- Driven against the real repository (like the stdin test above): this is I/O,
--- and the point is precisely that git's exit code survives the transport, which
--- a stub could only assume.
describe("fetch_range_diff exit code (§13.5)", function()
    -- Spin the event loop until the future resolves; returns the result or nil.
    local function await(future)
        local res
        future.next(function(r) res = r end)
        vim.wait(10000, function() return res ~= nil end, 20)
        return res
    end

    -- A minimal Commit for a DiffRange endpoint: only `hash` is read here.
    ---@param hash string
    ---@return Commit
    local function commit(hash)
        return { hash = hash, parents = {}, children = {}, refs = {} }
    end

    local function head_pair()
        local newer = vim.fn.systemlist({ "git", "rev-parse", "HEAD" })[1]
        if vim.v.shell_error ~= 0 or not newer or #newer ~= 40 then return nil end
        local older = vim.fn.systemlist({ "git", "rev-parse", "HEAD~3" })[1]
        if vim.v.shell_error ~= 0 or not older or #older ~= 40 then return nil end
        return newer, older
    end

    it("resolves code 0 and the patch for a real range", function()
        local newer, older = head_pair()
        if not (newer and older) then
            pending("not inside a git repository with enough history")
            return
        end
        local res = await(fetch.fetch_range_diff({
            rev = older .. ".." .. newer, from = commit(older), to = commit(newer),
        }))
        assert.is_not_nil(res)
        assert.equals(0, res.code)
        assert.is_true(#res.out > 0)
        assert.truthy(res.out:find("diff --git", 1, true))
    end)

    -- The shape that used to vanish: a `to` git cannot resolve. Before the fix
    -- this resolved "" and the view showed the commit list with nothing under it.
    it("reports a failing git diff instead of an empty patch", function()
        local newer = head_pair()
        if not newer then
            pending("not inside a git repository")
            return
        end
        local absent = "000000000000000000000000000000000000dead"
        local res = await(fetch.fetch_range_diff({
            rev = newer .. ".." .. absent, from = commit(newer), to = commit(absent),
        }))
        assert.is_not_nil(res)
        assert.is_true(res.code ~= 0)
        assert.equals("", res.out)
        -- git's own diagnosis is carried through, so the view can show it.
        assert.is_true(#res.err > 0)
    end)
end)

--- A range ending at the **working tree** (spec §4.2/§13.5).
---
--- `range_endpoints` maps a virtual newer end to a TREE STATE (`"index"` /
--- `"worktree"`), never to its sentinel hash. `fetch_range_diff` is the other
--- half of that invariant: it must build its argv from the endpoints' *shape* —
--- only a table endpoint is ever asked for its `.hash` — so the three states
--- produce three genuinely different patches and no sentinel can reach git.
---
--- Driven against a REAL dirty repository built in a scratch directory (never a
--- repo under the user's tree). A stub would only re-assert the mapping; the
--- point here is that git accepts these argvs and returns the right content.
describe("fetch_range_diff to the working tree (§13.5)", function()
    local range = require("gitloom.git.range")

    local function await(future)
        local res
        future.next(function(r) res = r end)
        vim.wait(20000, function() return res ~= nil end, 20)
        return res
    end

    local repo

    local function sh(...)
        local out = vim.fn.system({ "git", "-C", repo, ... })
        assert.equals(0, vim.v.shell_error, out)
    end

    -- HEAD~1 <- HEAD, then: `tracked` modified and staged, `tracked2` modified
    -- and left unstaged, and `newfile` untracked. So all three §4.2 nodes exist
    -- and each carries content the other two do not. Built once, lazily
    -- (plenary.busted has no `setup`), into a scratch directory -- never a repo
    -- under the user's tree.
    before_each(function()
        if repo then return end
        repo = vim.fn.tempname()
        vim.fn.mkdir(repo, "p")
        vim.fn.system({ "git", "init", "-q", repo })
        assert.equals(0, vim.v.shell_error)
        sh("config", "user.email", "t@example.invalid")
        sh("config", "user.name", "T")
        vim.fn.writefile({ "base" }, repo .. "/tracked")
        vim.fn.writefile({ "base2" }, repo .. "/tracked2")
        sh("add", "-A")
        sh("commit", "-q", "-m", "root")
        vim.fn.writefile({ "second" }, repo .. "/tracked")
        sh("commit", "-q", "-am", "second")
        -- Dirty it: a staged edit, an unstaged edit, and an untracked file.
        vim.fn.writefile({ "STAGED" }, repo .. "/tracked")
        sh("add", "tracked")
        vim.fn.writefile({ "UNSTAGED" }, repo .. "/tracked2")
        vim.fn.writefile({ "UNTRACKED" }, repo .. "/newfile")
        -- The fetch layer pins every spawn to the active root (§2.1).
        fetch.set_cwd(repo)
    end)

    -- The §4.2 stack over the scratch repo's real HEAD~1 / HEAD.
    local function stack()
        local head = vim.fn.systemlist({ "git", "-C", repo, "rev-parse", "HEAD" })[1]
        local prev = vim.fn.systemlist({ "git", "-C", repo, "rev-parse", "HEAD~1" })[1]
        local headc = { hash = head, parents = { { hash = prev, parents = {} } } }
        local staged = { hash = ("0"):rep(39) .. "1", virtual = "staged", parents = { headc } }
        local unstaged = { hash = ("0"):rep(40), virtual = "unstaged", parents = { staged } }
        local untracked = { hash = ("0"):rep(39) .. "2", virtual = "untracked", parents = { unstaged } }
        return headc, staged, unstaged, untracked, prev
    end

    it("staged: --cached <base> shows the staged edit and not the unstaged one", function()
        local headc, staged, _, _, prev = stack()
        local r = range.range_endpoints(staged, headc)
        assert.equals("--cached " .. prev, r.rev) -- single rev, no `..`
        local res = await(fetch.fetch_range_diff(r))
        assert.equals(0, res.code)
        assert.truthy(res.out:find("STAGED", 1, true))
        assert.is_nil(res.out:find("UNSTAGED", 1, true))
        assert.is_nil(res.out:find("UNTRACKED", 1, true))
    end)

    it("unstaged: <base> shows both the staged and the unstaged edits", function()
        local headc, _, unstaged, _, prev = stack()
        local r = range.range_endpoints(unstaged, headc)
        assert.equals(prev, r.rev) -- a bare single rev: the working-tree form
        local res = await(fetch.fetch_range_diff(r))
        assert.equals(0, res.code)
        assert.truthy(res.out:find("STAGED", 1, true))
        assert.truthy(res.out:find("UNSTAGED", 1, true))
        -- `git diff <rev>` never lists untracked files.
        assert.is_nil(res.out:find("UNTRACKED", 1, true))
    end)

    it("untracked: the same rev, plus the synthesized untracked additions", function()
        local headc, _, _, untracked, prev = stack()
        local r = range.range_endpoints(untracked, headc)
        assert.equals(prev, r.rev) -- identical rev to the unstaged case...
        local res = await(fetch.fetch_range_diff(r))
        assert.equals(0, res.code)
        assert.truthy(res.out:find("STAGED", 1, true))
        assert.truthy(res.out:find("UNSTAGED", 1, true))
        -- ...but the patch differs, which is the whole reason for the flag: an
        -- untracked endpoint that rendered identically to the unstaged one would
        -- make the user's selection invisible.
        assert.truthy(res.out:find("UNTRACKED", 1, true))
        assert.truthy(res.out:find("newfile", 1, true))
    end)

    it("a failing endpoint is still reported, not swallowed", function()
        local absent = ("0"):rep(36) .. "dead"
        local res = await(fetch.fetch_range_diff({
            rev = absent, to = "worktree", untracked = true,
            from = { hash = absent, parents = {}, children = {}, refs = {} },
        }))
        assert.is_true(res.code ~= 0)
        assert.equals("", res.out)
        assert.is_true(#res.err > 0)
    end)

    it("releases the scratch repository", function()
        fetch.set_cwd(nil)
        vim.fn.delete(repo, "rf")
        assert.equals(0, vim.fn.isdirectory(repo))
    end)
end)
