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
-- (measured on nvim 0.11.6 / Windows 11: the last command line that spawns is
-- 32766 characters; the environment block does not count toward it). A resync
-- puts every current tip AND every previous tip on that line, so at 41 bytes per
-- hash a repository with a few hundred distinct ref tips walks into the cap.
--
-- The fix is to carry the revisions on **stdin** (`git log --stdin`), which
-- removes the bound instead of raising it. These specs pin that: the argv must
-- stay constant-size however many tips are passed, and the stdin form must
-- return exactly the same commits as the old command-line form.

local fetch = require("gitloom.git.fetch")

-- A stand-in for the resolved executable path libuv prepends (it replaces
-- argv[0] with the absolute path, quoted when it holds a space —
-- `"C:\Program Files\Git\cmd\git.EXE"` is 34 characters with its quotes).
local EXE = '"C:\\Program Files\\Git\\cmd\\git.EXE"'
local WINDOWS_CMDLINE_MAX = 32766

-- The command line libuv builds from an argv: argv[0] swapped for the resolved
-- exe path, the rest joined with single spaces.
local function cmdline_len(argv)
    local n = #EXE
    for i = 2, #argv do n = n + 1 + #argv[i] end
    return n
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
