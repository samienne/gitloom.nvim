--- Tests for the working-tree virtual-commit pure helpers (spec §3.3/§4.2/§11.8):
--- parse_status (the `git status --porcelain` counter), commit_range for a virtual
--- commit (the working-tree DiffRange, §11.5), worktree_label (the graph-row
--- subject) and format_worktree_detail (the commit-view metadata header). All pure,
--- no Neovim runtime needed.

local internal = require("gitloom.graph")._internal
local parse_status = internal.parse_status
local commit_range = internal.commit_range
local worktree_label = internal.worktree_label
local format_worktree_detail = internal.format_worktree_detail

-- Fill the Commit fields the helpers' type wants but the tests don't care about.
---@return Commit
local function C(t)
    t.hash = t.hash or "x"
    t.parents = t.parents or {}
    t.children = t.children or {}
    t.refs = t.refs or {}
    return t
end

describe("parse_status", function()
    it("counts a staged modification on the index side (X)", function()
        local st = parse_status({ "M  file.lua" })
        assert.equal(1, st.staged)
        assert.equal(0, st.unstaged)
        assert.equal(0, st.untracked)
    end)

    it("counts an unstaged modification on the worktree side (Y)", function()
        local st = parse_status({ " M file.lua" })
        assert.equal(0, st.staged)
        assert.equal(1, st.unstaged)
        assert.equal(0, st.untracked)
    end)

    it("counts a both-staged-and-unstaged file on both sides", function()
        local st = parse_status({ "MM file.lua" })
        assert.equal(1, st.staged)
        assert.equal(1, st.unstaged)
    end)

    it("counts an untracked file as untracked, not staged/unstaged", function()
        local st = parse_status({ "?? new.lua" })
        assert.equal(0, st.staged)
        assert.equal(0, st.unstaged)
        assert.equal(1, st.untracked)
    end)

    it("treats a staged add / delete / rename as staged", function()
        local st = parse_status({ "A  added.lua", "D  gone.lua", "R  old.lua -> new.lua" })
        assert.equal(3, st.staged)
        assert.equal(0, st.unstaged)
    end)

    it("tallies a mixed porcelain output", function()
        local st = parse_status({
            "M  staged.lua",   -- staged
            " M dirty.lua",    -- unstaged
            "MM both.lua",     -- both
            "?? a.lua",        -- untracked
            "?? b.lua",        -- untracked
        })
        assert.equal(2, st.staged)   -- staged.lua, both.lua
        assert.equal(2, st.unstaged) -- dirty.lua, both.lua
        assert.equal(2, st.untracked)
    end)

    it("returns all zeros for a clean tree", function()
        local st = parse_status({})
        assert.same({ staged = 0, unstaged = 0, untracked = 0 }, st)
    end)
end)

describe("commit_range for a virtual commit (§11.5)", function()
    it("maps a staged node to index vs HEAD (--cached)", function()
        local head = C({ hash = "abc1234" })
        local v = C({ hash = "0000000000000000000000000000000000000001",
            virtual = "staged", parents = { head } })
        local r = commit_range(v)
        assert.equal("--cached", r.rev)
        assert.equal(head, r.from)
        assert.equal("index", r.to)
    end)

    it("maps an unstaged node to the working tree vs HEAD", function()
        local v = C({ hash = "0000000000000000000000000000000000000000",
            virtual = "unstaged", parents = { C({ hash = "deadbee" }) } })
        local r = commit_range(v)
        assert.equal("HEAD", r.rev)
        assert.equal("index", r.from)
        assert.equal("worktree", r.to)
    end)

    it("leaves a real commit's range unchanged", function()
        local p = C({ hash = "p" })
        local c = C({ hash = "child", parents = { p } })
        local r = commit_range(c)
        assert.equal("child^!", r.rev)
        assert.equal(p, r.from)
        assert.equal(c, r.to)
    end)
end)

describe("worktree_label (§4.2)", function()
    it("labels a staged node with its file count (pluralized)", function()
        assert.equal("Staged changes · 1 file",
            worktree_label(C({ virtual = "staged", wt = { changed = 1 } })))
        assert.equal("Staged changes · 3 files",
            worktree_label(C({ virtual = "staged", wt = { changed = 3 } })))
    end)

    it("labels an unstaged node and appends the untracked count when present", function()
        assert.equal("Unstaged changes · 2 files",
            worktree_label(C({ virtual = "unstaged", wt = { changed = 2, untracked = 0 } })))
        assert.equal("Unstaged changes · 2 files, 1 untracked",
            worktree_label(C({ virtual = "unstaged", wt = { changed = 2, untracked = 1 } })))
    end)
end)

describe("format_worktree_detail (§11.8)", function()
    -- The rows are highlight_text tables; assert on their `.text`.
    local function texts(rows)
        local out = {}
        for _, r in ipairs(rows) do out[#out + 1] = r.text end
        return out
    end

    it("headers a staged node as index vs HEAD", function()
        local rows = texts(format_worktree_detail(C({ virtual = "staged", wt = { changed = 1 } }), {}))
        assert.equal("Staged changes", rows[1])
        assert.equal("index vs HEAD", rows[2])
    end)

    it("headers an unstaged node and notes untracked additions when present", function()
        local rows = texts(format_worktree_detail(
            C({ virtual = "unstaged", wt = { changed = 2, untracked = 3 } }), {}))
        assert.equal("Unstaged changes", rows[1])
        assert.equal("working tree vs index", rows[2])
        assert.equal("includes 3 untracked files as additions", rows[3])
    end)

    it("omits the untracked note when there are none", function()
        local rows = texts(format_worktree_detail(
            C({ virtual = "unstaged", wt = { changed = 2, untracked = 0 } }), {}))
        for _, t in ipairs(rows) do
            assert.is_nil(t:match("untracked"))
        end
    end)
end)
