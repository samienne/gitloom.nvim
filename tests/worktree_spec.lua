--- Tests for the working-tree virtual-commit pure helpers (spec §3.3/§4.2/§11.8):
--- parse_status (the `git status --porcelain` counter), commit_range for a virtual
--- commit (the working-tree DiffRange, §11.5; untracked reuses the unstaged range),
--- worktree_label (the graph-row subject) and format_worktree_detail (the
--- commit-view metadata header) — for the three nodes staged / unstaged / untracked.
--- All pure, no Neovim runtime needed.

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

    it("counts each changed path once in `paths` (MM, rename, untracked)", function()
        local st = parse_status({ "M  a.lua", "MM b.lua", "RM old.lua -> new.lua", "?? c.lua" })
        assert.equal(3, st.staged)   -- the per-state counts are unchanged
        assert.equal(2, st.unstaged)
        assert.equal(1, st.untracked)
        assert.equal(4, st.paths)
    end)

    it("returns all zeros for a clean tree", function()
        local st = parse_status({})
        assert.same({ staged = 0, unstaged = 0, untracked = 0, paths = 0 }, st)
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

    it("maps an untracked node to the same working-tree range as unstaged", function()
        local v = C({ hash = "0000000000000000000000000000000000000002",
            virtual = "untracked", parents = { C({ hash = "deadbee" }) } })
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

    it("labels an unstaged node with its tracked file count", function()
        assert.equal("Unstaged changes · 2 files",
            worktree_label(C({ virtual = "unstaged", wt = { changed = 2 } })))
        assert.equal("Unstaged changes · 1 file",
            worktree_label(C({ virtual = "unstaged", wt = { changed = 1 } })))
    end)

    it("labels an untracked node with its file count (pluralized)", function()
        assert.equal("Untracked files · 1 file",
            worktree_label(C({ virtual = "untracked", wt = { changed = 1 } })))
        assert.equal("Untracked files · 4 files",
            worktree_label(C({ virtual = "untracked", wt = { changed = 4 } })))
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

    it("headers an unstaged node as working tree vs index (no untracked note)", function()
        local rows = texts(format_worktree_detail(
            C({ virtual = "unstaged", wt = { changed = 2 } }), {}))
        assert.equal("Unstaged changes", rows[1])
        assert.equal("working tree vs index", rows[2])
        for _, t in ipairs(rows) do
            assert.is_nil(t:match("untracked"))
        end
    end)

    it("headers an untracked node with its file count, shown as additions", function()
        local rows = texts(format_worktree_detail(
            C({ virtual = "untracked", wt = { changed = 3 } }), {}))
        assert.equal("Untracked files", rows[1])
        assert.equal("3 files, shown as additions", rows[2])
    end)

    it("pluralizes a single untracked file", function()
        local rows = texts(format_worktree_detail(
            C({ virtual = "untracked", wt = { changed = 1 } }), {}))
        assert.equal("1 file, shown as additions", rows[2])
    end)
end)

--- The virtual row's **rendered** lane continuity (§4.2/§5). A working-tree node
--- spliced directly above a HEAD that has in-set descendants sits in the middle
--- of the graph, so lanes cross its row — and under the `gutter` policy (§5.6) the
--- node, a fresh tip whose lane owns the next subject row, takes the gutter on a
--- handover row of its own (`item.above`). The layout is faithful; the bug was in
--- `display_item`, whose virtual-commit branch drew only the node line and dropped
--- the item's `above`/`merge` virtual lines, so every lane jogging on them looked
--- cut above the row and re-born below it (HEAD's lane "beginning" at the ◌).
describe("virtual commit row keeps its fan / handover lines (§4.2/§5)", function()
    local h = require("tests.graph_helpers")
    local view = require("gitloom.graph.view")

    -- m → s1 → c(HEAD) → d, with the unstaged node directly above HEAD.
    local function fixture()
        local items = h.dag({ { "m", { "s1" } }, { "s1", { "c" } }, { "wt", { "c" } },
            { "c", { "d" } }, { "d", {} } })
        local by = {}
        for _, it in ipairs(items) do by[it.commit.hash] = it.commit end
        by.wt.virtual = "unstaged"
        by.wt.wt = { changed = 1 }
        return items, by
    end

    -- Every rendered line of every row (above…, the node line, the merge line) must
    -- be handed to the listview.
    local function assert_all_lines_drawn(opts, rows)
        for _, r in ipairs(rows) do
            local el = internal.display_item(opts, r, { index = nil }, nil, nil, nil, nil, nil)
            local name = r.commit and r.commit.hash or r.type
            assert.equals(#(r.above or {}), #(el.above or {}), ("row %s: above lines drawn"):format(name))
            assert.equals(r.merge and 1 or 0, #(el.below or {}), ("row %s: merge line drawn"):format(name))
        end
    end

    for _, policy in ipairs({ "compact", "gutter" }) do
        for _, corpus in ipairs({ "raw", "focused" }) do
            it(("draws every line of the virtual row (%s, %s)"):format(policy, corpus), function()
                local items, by = fixture()
                if corpus == "focused" then
                    by.m.refs = { { name = "master", kind = "local" } }
                    by.c.refs = { { name = "release", kind = "local" } }
                    local ro = { { id = "master", tip = by.m, mode = "normal" },
                        { id = "release", tip = by.c, mode = "normal" } }
                    items = view.project(items, view.owners(items, ro,
                        { master = true, release = true }, {}, true), nil).items
                end
                local opts = h.big_opts()
                opts.layout_policy = policy
                local errs, rows = h.check(opts, items)
                assert.same({}, errs) -- the layout model itself is continuous
                local vrow
                for _, r in ipairs(rows) do
                    if r.commit and r.commit.virtual then vrow = r end
                end
                assert.is_not_nil(vrow)
                if policy == "gutter" then
                    -- Precondition: the case that broke — the virtual row owns a
                    -- handover line above its node line.
                    assert.is_true(#(vrow.above or {}) > 0)
                end
                assert_all_lines_drawn(opts, rows)
            end)
        end
    end
end)

--- The **clean** node (§3.3/§4.2): the always-shown working-tree row on a clean
--- tree — its label, its commit-view header, and its ranges (§10.4.2/§11.8/§13.5):
--- every one is the working tree against HEAD, a single rev, empty by definition.
describe("the clean working-tree node", function()
    local git = require("gitloom.git")
    local SENT = "0000000000000000000000000000000000000003"
    local function texts(rows)
        local out = {}
        for _, r in ipairs(rows) do out[#out + 1] = r.text end
        return out
    end
    local function clean_on(head)
        local v = C({ hash = SENT, virtual = "clean", parents = { head }, wt = { changed = 0 } })
        head.children = { v }
        return v
    end

    it("labels the row `Working tree · clean` (§5.3)", function()
        assert.equal("Working tree · clean", worktree_label(C({ virtual = "clean", wt = { changed = 0 } })))
    end)

    it("headers the commit view `Working tree clean` / `matches HEAD <short>` / `no changes`", function()
        local head = C({ hash = "abcdef0123456789" })
        local rows = texts(format_worktree_detail(clean_on(head), {}))
        assert.equal("Working tree clean", rows[1])
        assert.equal("matches HEAD abcdef0", rows[2])
        assert.is_true(vim.tbl_contains(rows, "no changes"))
    end)

    it("its own range (commit view D) is the working tree vs HEAD, single rev", function()
        local head = C({ hash = "abcdef0123456789" })
        local r = commit_range(clean_on(head), "/repo")
        assert.equal("abcdef0123456789", r.rev)
        assert.equal(head, r.from)
        assert.equal("worktree", r.to)
        assert.equal("/repo", r.root)
        assert.is_nil(r.untracked)
    end)

    it("worktree_examine_range is that same range, from HEAD's real commit", function()
        local head = C({ hash = "abcdef0123456789" })
        local r = git.worktree_examine_range(head, "/repo")
        assert.same({ rev = "abcdef0123456789", from = head, to = "worktree", root = "/repo" }, r)
        -- a raw hash is accepted; an unknown HEAD falls back to the HEAD rev name
        assert.equal("abc", git.worktree_examine_range("abc").rev)
        assert.equal("HEAD", git.worktree_examine_range(nil).rev)
        assert.equal(r.rev, commit_range(clean_on(head), "/repo").rev)
    end)

    it("as a selection's newer end it is `<older>^` vs the working tree (§13.5)", function()
        local p = C({ hash = "p000000" })
        local head = C({ hash = "h000000", parents = { p } })
        local v = clean_on(head)
        local r = git.range_endpoints(v, head)
        assert.equal("p000000", r.rev)
        assert.equal(p, r.from)
        assert.equal("worktree", r.to)
        -- the clean node selected alone is its own (empty) range
        assert.equal("h000000", git.range_endpoints(v, v).rev)
        -- Examine selection on it opens the same range, nothing checked out (§10.4.2)
        local plan = git.examine_plan({ newer = v, older = head })
        assert.equal("open", plan.kind)
        assert.equal("p000000", plan.range.rev)
        assert.is_false(git.needs_checkout(v, "h000000"))
    end)
end)
