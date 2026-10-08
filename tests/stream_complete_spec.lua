-- The commit stream delivers the WHOLE log however busy the event loop is
-- (spec §3/§3.1).
--
-- Regression: `fetch_commits` streamed `git log` through `jobstart`'s
-- `on_stdout`. When the main loop is slow to drain the job's output (the worker
-- doing per-batch layout, a redraw, the reflow), Neovim stops reading the pipe;
-- git still writes everything and exits 0, and Neovim then delivers `on_exit`
-- WITHOUT the unread tail. The last delivered line is cut mid-record, so it
-- parsed into a commit with a hash, parents and nothing else -- the "null" row at
-- the bottom of the graph (no subject, no author, dated 1970-01-01, drawn as a
-- root because its real parent never arrived), and every commit below it was
-- silently missing. Measured on nvim 0.12.5 / Windows: a 20 ms batch handler
-- lost 250-280 of 496 commits on every run.
--
-- The handler here blocks the loop on purpose, which is what the graph's own
-- per-batch layout does on a large repository.

local fetch = require("gitloom.git.fetch")

local N = 1500

describe("fetch_commits stream completeness (§3)", function()
    local repo

    before_each(function()
        if repo then return end
        repo = vim.fn.tempname()
        vim.fn.mkdir(repo, "p")
        vim.fn.system({ "git", "init", "-q", repo })
        assert.equals(0, vim.v.shell_error)
        -- A linear history built in one `fast-import`: long subjects so the log
        -- is several pipe buffers deep (~300 KB), which is what lets the reader
        -- fall behind the writer.
        local s = {}
        for i = 1, N do
            local msg = ("commit %d %s"):format(i, ("x"):rep(180))
            s[#s + 1] = "commit refs/heads/main"
            s[#s + 1] = "mark :" .. i
            s[#s + 1] = ("committer T <t@example.invalid> %d +0000"):format(1700000000 + i)
            s[#s + 1] = "data " .. #msg
            s[#s + 1] = msg
            if i > 1 then s[#s + 1] = "from :" .. (i - 1) end
            s[#s + 1] = ""
        end
        local out = vim.fn.system({ "git", "-C", repo, "fast-import", "--quiet" },
            table.concat(s, "\n") .. "\n")
        assert.equals(0, vim.v.shell_error, out)
        fetch.set_cwd(repo)
    end)

    it("delivers every commit, each fully parsed, under a slow batch handler", function()
        local got, partial, done = 0, {}, false
        fetch.fetch_commits({
            branch = { "--all" },
            on_batch = function(commits)
                -- Hold the loop like a heavy layout pass would.
                local t0 = vim.uv.hrtime()
                while vim.uv.hrtime() - t0 < 20e6 do end
                for _, c in ipairs(commits) do
                    got = got + 1
                    if not c.message or c.date.epoch == 0 then
                        partial[#partial + 1] = c.hash
                    end
                end
            end,
        }).next(function() done = true end)
        vim.wait(60000, function() return done end, 10)
        assert.is_true(done)
        assert.same({}, partial)
        assert.equals(N, got)
    end)

    it("releases the scratch repository", function()
        fetch.set_cwd(nil)
        vim.fn.delete(repo, "rf")
        assert.equals(0, vim.fn.isdirectory(repo))
    end)
end)
