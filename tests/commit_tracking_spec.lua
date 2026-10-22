--- The commit view's tracking lines (specification.md §11.1 / §11.2): the pure
--- `format_tracking` / `tracking_entries`, their place in `format_commit_detail`
--- and `build_commit_rows` (none in the preview, range or working-tree views),
--- and `fetch.tracking_probe`'s on-demand queries against a real scratch repo.

local git = require("gitloom.git")
local fetch = require("gitloom.git.fetch")
local window = require("gitloom.window")

local function texts(rows)
    local out = {}
    for _, r in ipairs(rows) do out[#out + 1] = r.text end
    return out
end

local function has_tracking(rows)
    for _, r in ipairs(rows) do
        if r.text:find("^Tracking:") then return true end
    end
    return false
end

local function up(t)
    return vim.tbl_extend("force", { short = "origin/main", ref = "refs/remotes/origin/main",
        remote = "origin", merge = "refs/heads/main", match = true, gone = false,
        ahead = 0, behind = 0 }, t or {})
end

describe("format_tracking (§11.2)", function()
    it("a matching upstream that pushes there is one line", function()
        local rows = git.format_tracking({ { branch = "main", upstream = up(),
            push = "refs/remotes/origin/main" } })
        assert.same({ "Tracking:   main → origin/main  in sync" }, texts(rows))
    end)

    it("spells the state: ahead, behind, both, gone", function()
        local function first(u) return texts(git.format_tracking({ { branch = "main", upstream = u } }))[1] end
        assert.equals("Tracking:   main → origin/main  3 ahead", first(up({ ahead = 3 })))
        assert.equals("Tracking:   main → origin/main  2 behind", first(up({ behind = 2 })))
        assert.equals("Tracking:   main → origin/main  3 ahead, 2 behind", first(up({ ahead = 3, behind = 2 })))
        assert.equals("Tracking:   main → origin/main  gone", first(up({ gone = true, ahead = 1 })))
    end)

    it("no upstream", function()
        assert.same({ "Tracking:   topic → no upstream" },
            texts(git.format_tracking({ { branch = "topic" } })))
    end)

    it("the spec's mismatch example: push reason + same-name counts", function()
        local u = up({ short = "origin/dev", ref = "refs/remotes/origin/dev", merge = "refs/heads/dev",
            match = false, same = { "origin" }, ahead = 4, behind = 6 })
        local rows = git.format_tracking({ { branch = "enne/standard-effect", upstream = u,
            push_err = "cannot resolve 'simple' push to a single destination",
            same = { { remote = "origin", ahead = 0, behind = 0 } } } })
        assert.same({
            "Tracking:   enne/standard-effect → origin/dev  4 ahead, 6 behind",
            "              push: cannot resolve 'simple' push to a single destination",
            "              same name: origin/enne/standard-effect  in sync",
        }, texts(rows))
    end)

    it("a push target other than the upstream gets a push line; a failed count none", function()
        local u = up({ short = "upstream/main", ref = "refs/remotes/upstream/main", remote = "upstream",
            match = false, same = { "origin" } })
        local rows = git.format_tracking({ { branch = "main", upstream = u, push = "refs/remotes/origin/main",
            same = { { remote = "origin" } } } })
        assert.same({
            "Tracking:   main → upstream/main  in sync",
            "              push: origin/main",
            "              same name: origin/main",
        }, texts(rows))
    end)

    it("colours the upstream as the §6.3 label does", function()
        local pal = { remote = "R", track = { upstream = "U", mismatch = "M" } }
        local function up_hl(u)
            local row = git.format_tracking({ { branch = "b", upstream = u } }, pal)[1]
            local s = row.text:find("origin/", 1, true) - 1
            for _, h in ipairs(row.highlight) do
                if h.start_pos == s then return h.hl end
            end
        end
        assert.equals("R", up_hl(up()))
        assert.equals("U", up_hl(up({ match = false })))
        assert.equals("M", up_hl(up({ match = false, same = { "origin" } })))
    end)

    it("several local branches each get a field; same-name only for a non-matching upstream", function()
        local rows = git.format_tracking({
            { branch = "main", upstream = up(), same = { { remote = "origin", ahead = 1, behind = 0 } } },
            { branch = "dev" },
        })
        assert.same({ "Tracking:   main → origin/main  in sync", "Tracking:   dev → no upstream" }, texts(rows))
    end)
end)

describe("tracking_entries (§11.2)", function()
    it("one per local branch, decoration order, HEAD's branch first", function()
        local c = {}
        local refs = {
            { name = "a", kind = "local", commit = c },
            { name = "origin/x", kind = "remote", commit = c },
            { name = "v1", kind = "tag", commit = c },
            { name = "b", kind = "local", commit = c, upstream = up() },
            { name = "HEAD", kind = "head", commit = c, branch = "b" },
        }
        local e = git.tracking_entries(refs)
        assert.equals(2, #e)
        assert.equals("b", e[1].branch)
        assert.equals("origin/main", e[1].upstream.short)
        assert.equals("a", e[2].branch)
        assert.is_nil(e[2].upstream)
    end)
end)

describe("tracking lines in the commit rows (§11.2)", function()
    local meta = table.concat({ "abc1234", "A", "a@x", "2026-01-01 00:00:00 +0000",
        "A", "a@x", "2026-01-01 00:00:00 +0000", "", "Subject" }, "\x1f")
    local opts = { palette = {} }
    local commit = { hash = "abc1234", refs = { { name = "main", kind = "local", upstream = up() } } }
    local tracking = { { branch = "main", upstream = up() } }

    it("sit right after Refs:, and info says where", function()
        commit.refs[1].commit = commit
        local rows, info = window.build_commit_rows(opts, { commit = commit, meta = meta,
            action = false, tracking = tracking })
        local t = texts(rows)
        assert.truthy(t[info.track_edge]:find("^Refs:"))
        assert.equals("Tracking:   main → origin/main  in sync", t[info.track_edge + 1])
        assert.equals(1, info.track_n)
    end)

    it("the preview (no tracking passed) has none", function()
        local rows, info = window.build_commit_rows(opts, { commit = commit, meta = meta, action = false })
        assert.is_false(has_tracking(rows))
        assert.equals(0, info.track_n)
    end)

    it("a range view and a working-tree view have none", function()
        local rows = window.build_commit_rows(opts, { range = { commits = { { hash = "abc1234", message = "s" } },
            range = "a..b" }, tracking = tracking, action = false })
        assert.is_false(has_tracking(rows))
        rows = window.build_commit_rows(opts, { commit = { hash = "w", virtual = "staged", refs = commit.refs },
            tracking = tracking, action = false })
        assert.is_false(has_tracking(rows))
    end)
end)

-- ── The on-demand queries (§11.1), against a scratch repo ───────────────────

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

local function commit_file(dir, name, text, msg)
    local f = assert(io.open(dir .. "/" .. name, "w"))
    f:write(text)
    f:close()
    sh(dir, "add", "-A")
    sh(dir, "commit", "-q", "-m", msg)
    return sh(dir, "rev-parse", "HEAD")
end

describe("tracking_probe against a real repository (§11.1)", function()
    local dir
    before_each(function()
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        sh(dir, "init", "-q", "-b", "main")
        sh(dir, "config", "user.email", "t@example.invalid")
        sh(dir, "config", "user.name", "T")
        sh(dir, "config", "commit.gpgsign", "false")
        sh(dir, "config", "push.default", "simple")
        local base = commit_file(dir, "f", "1\n", "base")
        local dev = commit_file(dir, "f", "2\n", "dev")
        sh(dir, "reset", "-q", "--hard", base)
        commit_file(dir, "g", "g\n", "local")
        sh(dir, "remote", "add", "origin", dir .. "/nonexistent.git")
        sh(dir, "update-ref", "refs/remotes/origin/main", base)
        sh(dir, "update-ref", "refs/remotes/origin/dev", dev)
        sh(dir, "branch", "-q", "-u", "origin/main", "main")
        sh(dir, "branch", "-q", "feat")
        sh(dir, "update-ref", "refs/remotes/origin/feat", base)
        sh(dir, "branch", "-q", "-u", "origin/dev", "feat")
    end)
    after_each(function() vim.fn.delete(dir, "rf") end)

    it("push target, git's push reason, same-name counts", function()
        local entries = {
            { branch = "main", upstream = up({ ahead = 1 }) },
            { branch = "feat", upstream = up({ short = "origin/dev", ref = "refs/remotes/origin/dev",
                merge = "refs/heads/dev", match = false, same = { "origin" }, ahead = 1, behind = 1 }) },
        }
        local res = assert(await(fetch.tracking_probe(entries, dir)))
        assert.equals("refs/remotes/origin/main", res[1].push)
        assert.is_nil(res[1].same)
        assert.is_nil(res[2].push)
        assert.equals("cannot resolve 'simple' push to a single destination", res[2].push_err)
        assert.same({ { remote = "origin", ahead = 1, behind = 0 } }, res[2].same)
        assert.same({
            "Tracking:   main → origin/main  1 ahead",
            "Tracking:   feat → origin/dev  1 ahead, 1 behind",
            "              push: cannot resolve 'simple' push to a single destination",
            "              same name: origin/feat  1 ahead",
        }, texts(git.format_tracking(res)))
    end)
end)
