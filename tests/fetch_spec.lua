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
