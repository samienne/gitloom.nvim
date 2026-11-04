--- Tests for Checkout & examine (spec §10.4.2): the pure decisions in
--- `gitloom.git.examine` (`examine_plan` over clean/dirty × single/range ×
--- working-tree end × an examine already active, `examine_stash_message`,
--- `return_plan` for a branch vs a detached `orig` with and without a stash,
--- `stash_index`), the single-rev base (`range.examine_range`, incl. a root commit
--- giving the empty tree) and the palette entries that reach it (Return, the
--- selection's Checkout & examine, the row's), plus **Examine** — the newer end
--- already HEAD's commit (`needs_checkout`): an `open` plan with no checkout,
--- stash or state whatever the tree / an active examine, and the palette's
--- `Examine <short>` / `Examine selection` labels from a cached head hash. Then the git side
--- (`fetch.examine_probe` / `examine_run` / `examine_return`) against REAL scratch
--- repositories — never this one: a dirty tree is stashed, checked out detached
--- and restored by Return with the stash dropped and the index restored (staged
--- stays staged), falling back to a plain apply when git refuses `--index`
--- (`index_refused`); a conflicting apply keeps the
--- stash; a failed checkout after a stash re-applies it. Optionally, with diffview
--- installed, the single-rev open's right side is the files on disk (LOCAL). The
--- window glue (prompt, busy flag, notices, resync) is untested like the rest.

local examine = require("gitloom.git.examine")
local range = require("gitloom.git.range")
local fetch = require("gitloom.git.fetch")
local palette = require("gitloom.graph.palette")

local A, B, C, P = ("a"):rep(40), ("b"):rep(40), ("c"):rep(40), ("p"):rep(40)
local ROOT = "C:/r"
local CLEAN = { staged = 0, unstaged = 0, untracked = 0, paths = 0 }
local DIRTY = { staged = 1, unstaged = 2, untracked = 1 }
local ON_MAIN = { branch = "main", hash = C }

local parent = { hash = P, parents = {} }
local older = { hash = B, parents = { parent } }
local newer = { hash = A, parents = { older } }

local function ids(entries)
    local out = {}
    for _, e in ipairs(entries) do out[#out + 1] = e.id end
    return out
end

describe("examine_range (§10.4.2)", function()
    it("is ONE rev — the older end's first parent — against the working tree", function()
        local r = range.examine_range(newer, older, ROOT)
        assert.equals(P, r.rev)
        assert.equals(parent, r.from)
        assert.equals("worktree", r.to)
        assert.equals(ROOT, r.root)
        assert.same({ "-C" .. ROOT, P }, range.diffview_args(r))
    end)

    it("a single commit's base is its own first parent", function()
        assert.equals(B, range.examine_range(newer, newer, ROOT).rev)
    end)

    it("a root older end gives the empty tree", function()
        local r = range.examine_range(newer, parent, ROOT)
        assert.equals(range.EMPTY_TREE, r.rev)
        assert.is_nil(r.from)
    end)

    it("a raw-hash parent is used as is", function()
        local raw = { hash = A, parents = { P } }
        assert.equals(P, range.examine_range(raw, raw).rev)
    end)

    it("a working-tree newer end is the selection's own (single-rev) range", function()
        local v = { hash = ("0"):rep(40), virtual = "unstaged", parents = { newer } }
        local r = range.examine_range(v, older, ROOT)
        assert.same(range.range_endpoints(v, older, ROOT), r)
        assert.equals(P, r.rev)
    end)
end)

describe("dirty_count (§10.4.2 — the prompt's N)", function()
    local parse_status = require("gitloom.git.parse").parse_status

    it("counts each changed path once: a staged+unstaged (MM) file is one change", function()
        local st = parse_status({ "M  staged.lua", "MM both.lua", "?? new.lua" })
        assert.equals(3, examine.dirty_count(st))
    end)

    it("counts a rename once", function()
        assert.equals(1, examine.dirty_count(parse_status({ "RM old.lua -> new.lua" })))
    end)

    it("the plan's stash count is the path count", function()
        local st = parse_status({ "MM a", "MM b" })
        assert.equals(2, examine.examine_plan({ newer = newer, older = older, status = st,
            head = ON_MAIN }).stash.count)
    end)
end)

describe("examine_stash_message (§10.4.2)", function()
    it("names the examined commit and where it came from", function()
        assert.equals("gitloom: examine aaaaaaa (from main)", examine.examine_stash_message(A, ON_MAIN))
        assert.equals("gitloom: examine aaaaaaa (from ccccccc)", examine.examine_stash_message(A, { hash = C }))
    end)
end)

describe("examine_plan (§10.4.2)", function()
    it("clean, single commit: detach at it, no stash, records orig = the branch", function()
        local p = examine.examine_plan({ newer = older, older = older, status = CLEAN, head = ON_MAIN, root = ROOT })
        assert.equals("checkout", p.kind)
        assert.same({ "git", "checkout", "--detach", B }, p.checkout)
        assert.is_nil(p.stash)
        assert.same({ orig = "main", detached = false, examined = B }, p.state)
        assert.equals(P, p.range.rev)
        assert.equals(ROOT, p.range.root)
    end)

    it("clean, range: checks out the NEWER end, base = older's first parent", function()
        local p = examine.examine_plan({ newer = newer, older = older, status = CLEAN, head = ON_MAIN })
        assert.same({ "git", "checkout", "--detach", A }, p.checkout)
        assert.equals(P, p.range.rev)
        assert.equals("worktree", p.range.to)
    end)

    it("clean from a detached HEAD: orig is the hash", function()
        local p = examine.examine_plan({ newer = newer, older = older, status = CLEAN, head = { hash = C } })
        assert.same({ orig = C, detached = true, examined = A }, p.state)
    end)

    it("dirty: stashes first with -u and the examine message; N counts every change", function()
        local p = examine.examine_plan({ newer = newer, older = older, status = DIRTY, head = ON_MAIN })
        assert.equals("checkout", p.kind)
        local msg = "gitloom: examine aaaaaaa (from main)"
        assert.same({ argv = { "git", "stash", "push", "-u", "-m", msg }, message = msg, count = 4 }, p.stash)
        assert.equals(msg, p.state.stash_message)
        assert.is_nil(p.state.stash) -- filled in by the runner from stash@{0}
    end)

    it("a working-tree newer end: open its range, no checkout, no stash, whatever the tree", function()
        local v = { hash = ("0"):rep(40), virtual = "staged", parents = { newer } }
        for _, st in ipairs({ CLEAN, DIRTY }) do
            local p = examine.examine_plan({ newer = v, older = newer, status = st, head = ON_MAIN, root = ROOT })
            assert.equals("open", p.kind)
            assert.is_nil(p.checkout)
            assert.is_nil(p.stash)
            assert.same(range.range_endpoints(v, newer, ROOT), p.range)
        end
    end)

    local active = { orig = "main", detached = false, stash = C, stash_message = "m", examined = B }

    it("examine active + clean: keeps orig and the stash, only examined moves", function()
        local p = examine.examine_plan({ newer = newer, older = newer, status = CLEAN,
            head = { hash = B }, state = active })
        assert.equals("checkout", p.kind)
        assert.is_nil(p.stash)
        assert.same({ orig = "main", detached = false, stash = C, stash_message = "m", examined = A }, p.state)
        assert.equals(B, active.examined) -- the active state is not mutated
    end)

    it("examine active + dirty: refused — Return first, never a second stash", function()
        local p = examine.examine_plan({ newer = newer, older = newer, status = DIRTY,
            head = { hash = B }, state = active })
        assert.equals("refuse", p.kind)
        assert.is_nil(p.checkout)
        assert.truthy(p.reason:find("Return to main first", 1, true))
        assert.truthy(p.reason:find("4 changes", 1, true))
    end)

    -- Examine: the newer end already is HEAD's commit — nothing to check out.
    it("newer end at HEAD (attached or detached): open examine_range, no checkout/stash/state", function()
        for _, head in ipairs({ { branch = "main", hash = A }, { hash = A } }) do
            for _, st in ipairs({ CLEAN, DIRTY }) do
                for _, o in ipairs({ newer, older }) do
                    local p = examine.examine_plan({ newer = newer, older = o, status = st,
                        head = head, root = ROOT })
                    assert.equals("open", p.kind)
                    assert.is_nil(p.checkout)
                    assert.is_nil(p.stash)
                    assert.is_nil(p.state)
                    assert.same(range.examine_range(newer, o, ROOT), p.range)
                end
            end
        end
    end)

    it("newer end at HEAD with an examine active: opens, the active state untouched", function()
        local act = { orig = "main", detached = false, stash = C, stash_message = "m", examined = A }
        for _, st in ipairs({ CLEAN, DIRTY }) do
            local p = examine.examine_plan({ newer = newer, older = older, status = st,
                head = { hash = A }, state = act, root = ROOT })
            assert.equals("open", p.kind)
            assert.is_nil(p.state)
        end
        assert.same({ orig = "main", detached = false, stash = C, stash_message = "m", examined = A }, act)
    end)

    it("needs_checkout: not for a §4.2 node or HEAD's commit; yes otherwise / HEAD unknown", function()
        assert.is_false(examine.needs_checkout(newer, A))
        local v = { hash = ("0"):rep(40), virtual = "staged", parents = {} }
        assert.is_false(examine.needs_checkout(v, A))
        assert.is_true(examine.needs_checkout(newer, B))
        assert.is_true(examine.needs_checkout(newer, nil))
        assert.is_false(examine.needs_checkout(nil, A))
    end)

    it("refuses when HEAD is unknown and no examine is active", function()
        assert.equals("refuse", examine.examine_plan({ newer = newer, older = older, status = CLEAN }).kind)
    end)

    it("never forces", function()
        local p = examine.examine_plan({ newer = newer, older = older, status = DIRTY, head = ON_MAIN })
        for _, argv in ipairs({ p.checkout, p.stash.argv }) do
            for _, a in ipairs(argv) do assert.falsy(a == "-f" or a:match("^%-%-force")) end
        end
    end)
end)

describe("return_plan (§10.4.2)", function()
    it("a branch orig with a stash: switch, then apply by SHA with --index (plain as fallback)", function()
        local rp = examine.return_plan({ orig = "main", detached = false, stash = C, stash_message = "m", examined = A })
        assert.equals("Return to main", rp.label)
        assert.same({ "git", "switch", "main" }, rp.switch)
        assert.same({ "git", "stash", "apply", "--index", C }, rp.apply)
        assert.same({ "git", "stash", "apply", C }, rp.apply_plain)
        assert.equals(C, rp.stash)
        assert.equals("m", rp.stash_message)
    end)

    it("a detached orig without a stash: detached checkout, no apply", function()
        local rp = examine.return_plan({ orig = B, detached = true, examined = A })
        assert.equals("Return to bbbbbbb", rp.label)
        assert.same({ "git", "checkout", "--detach", B }, rp.switch)
        assert.is_nil(rp.apply)
        assert.is_nil(rp.apply_plain)
    end)
end)

describe("index_refused (§10.4.2)", function()
    it("only git's 'conflicts in index' refusal of --index licenses the plain fallback", function()
        local refusal = "error: patch failed: a.txt:1\nerror: a.txt: patch does not apply\n"
            .. "error: conflicts in index. Try without --index."
        assert.is_true(examine.index_refused({ code = 1, out = "", err = refusal }))
        -- older git capitalises it
        assert.is_true(examine.index_refused({ code = 1, out = "", err = "Conflicts in index. Try without --index." }))
        assert.is_false(examine.index_refused({ code = 0, out = "", err = refusal }))
        -- a merge conflict, a local change in the way: the tree may already be
        -- touched, so no fallback
        assert.is_false(examine.index_refused({ code = 1, out = "CONFLICT (content): Merge conflict in g", err = "" }))
        assert.is_false(examine.index_refused({ code = 1, out = "",
            err = "error: Your local changes to the following files would be overwritten by merge:" }))
        assert.is_false(examine.index_refused({ code = -1, out = "", err = "spawn failed" }))
        assert.is_false(examine.index_refused(nil))
    end)
end)

describe("stash_index", function()
    it("finds the stash@{n} position by SHA; nil when absent", function()
        local out = A .. "\r\n" .. B .. "\n" .. C .. "\n"
        assert.equals(0, examine.stash_index(out, A))
        assert.equals(2, examine.stash_index(out, C))
        assert.is_nil(examine.stash_index(out, P))
        assert.is_nil(examine.stash_index("", A))
    end)
end)

describe("palette entries for examine (§17, §10.4.2)", function()
    local st = { orig = "main", detached = false, examined = A }
    local row = { kind = "plain", commit = { hash = A, refs = {} } }

    it("the row's Checkout & examine needs a provider and a real commit", function()
        assert.same({ "diff", "checkout", "checkout_examine" }, ids(palette.row_entries(row, true)))
        assert.same({ "checkout" }, ids(palette.row_entries(row, false)))
        local v = { kind = "plain", commit = { hash = A, refs = {}, virtual = "untracked" } }
        assert.same({ "diff", "examine_worktree" }, ids(palette.row_entries(v, true)))
    end)

    it("every working-tree row, clean included, offers Examine working tree (§10.4.2)", function()
        for _, kind in ipairs({ "staged", "unstaged", "untracked", "clean" }) do
            local v = { kind = "plain", commit = { hash = A, refs = {}, virtual = kind } }
            local e = palette.row_entries(v, true, B)
            assert.same({ "diff", "examine_worktree" }, ids(e), kind)
            assert.equals("Examine working tree", e[2].label)
            assert.equals("examine_worktree", e[2].op)
            -- no provider: neither entry
            assert.same({}, ids(palette.row_entries(v, false, B)), kind)
        end
    end)

    it("HEAD's row offers Examine instead of Checkout & examine (cached head hash)", function()
        local e = palette.row_entries(row, true, A)
        assert.same({ "diff", "checkout", "examine" }, ids(e))
        assert.equals("Examine aaaaaaa", e[3].label)
        assert.equals("examine", e[3].op)
        assert.equals(A, e[3].commit.hash)
        -- another commit, or HEAD unknown: unchanged
        assert.same({ "diff", "checkout", "checkout_examine" }, ids(palette.row_entries(row, true, B)))
        assert.same({ "diff", "checkout", "checkout_examine" }, ids(palette.row_entries(row, true, nil)))
        -- no provider: no examine entry of either kind
        assert.same({ "checkout" }, ids(palette.row_entries(row, false, A)))
        -- through palette_entries, with an examine active: Return still listed
        local all = palette.palette_entries({ row = row, has_diff = true, head = A, examine = st })
        assert.same({ "diff", "checkout", "examine", "return" }, { all[1].id, all[2].id, all[3].id, all[4].id })
    end)

    it("the selection's entry reads Examine selection when its newer end needs no checkout", function()
        local function label(info)
            for _, e in ipairs(palette.palette_entries(info)) do
                if e.id == "examine_selection" then return e.label end
            end
        end
        local c = { hash = A, parents = {} }
        assert.equals("Examine selection", label({ selection = true, has_diff = true, newest = c, head = A }))
        assert.equals("Checkout & examine selection",
            label({ selection = true, has_diff = true, newest = c, head = B }))
        assert.equals("Checkout & examine selection", label({ selection = true, has_diff = true, head = A }))
        local v = { hash = ("0"):rep(40), virtual = "unstaged", parents = { c } }
        assert.equals("Examine selection", label({ selection = true, has_diff = true, newest = v, head = B }))
        assert.is_nil(label({ selection = true, has_diff = false, newest = c, head = A }))
    end)

    it("Return is labelled with orig (a detached one by its short hash)", function()
        local e = palette.palette_entries({ examine = st })
        assert.equals("return", e[1].id)
        assert.equals("Return to main", e[1].label)
        local d = palette.palette_entries({ examine = { orig = B, detached = true, examined = A } })
        assert.equals("Return to bbbbbbb", d[1].label)
    end)

    it("binds the selection and Return actions to the session", function()
        local calls = {}
        local ctx = {
            open_selection_diff = function() calls[#calls + 1] = "diff" end,
            examine_selection = function() calls[#calls + 1] = "sel" end,
            examine_return = function() calls[#calls + 1] = "ret" end,
        }
        local e = palette.palette_entries({ selection = true, has_diff = true, examine = st })
        for k = 1, 3 do e[k].action(ctx) end
        assert.same({ "diff", "sel", "ret" }, calls)
    end)
end)

-- ── The git side against real scratch repositories ───────────────────────────

---@param future table
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

-- main: root(f=1) <- second(f=2). Returns the repo dir + the two hashes.
local function scratch()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    sh(dir, "init", "-q", "-b", "main")
    sh(dir, "config", "user.email", "t@example.invalid")
    sh(dir, "config", "user.name", "T")
    sh(dir, "config", "commit.gpgsign", "false")
    sh(dir, "config", "core.autocrlf", "false")
    write(dir .. "/f", "1\n")
    write(dir .. "/g", "g\n")
    sh(dir, "add", "-A")
    sh(dir, "commit", "-q", "-m", "root")
    local root_hash = sh(dir, "rev-parse", "HEAD")
    write(dir .. "/f", "2\n")
    sh(dir, "commit", "-q", "-am", "second")
    return dir, root_hash, sh(dir, "rev-parse", "HEAD")
end

local function stash_list(dir) return sh(dir, "stash", "list", "--format=%H") end

-- Probe, plan, run — the window glue's sequence, minus the prompt (answered yes).
---@return any plan, any result
local function run_examine(dir, hash, state)
    local probe = await(fetch.examine_probe(dir))
    local c = { hash = hash, parents = {} }
    local plan = examine.examine_plan({ newer = c, older = c, status = probe.status,
        head = probe.head, state = state, root = dir })
    if plan.kind ~= "checkout" then return plan, nil end
    local r = await(fetch.examine_run(plan, dir))
    if r.ok and plan.stash then plan.state.stash = r.stash end
    return plan, r
end

describe("examine against a real repository (§10.4.2)", function()
    it("probe: HEAD's branch + the dirty counts; detached has no branch", function()
        local dir, root_hash = scratch()
        local p = await(fetch.examine_probe(dir))
        assert.equals("main", p.head.branch)
        assert.same(CLEAN, p.status)
        write(dir .. "/f", "dirty\n")
        write(dir .. "/new", "u\n")
        sh(dir, "add", "g") -- nothing staged (unchanged) — still 1 unstaged + 1 untracked
        p = await(fetch.examine_probe(dir))
        assert.same({ staged = 0, unstaged = 1, untracked = 1, paths = 2 }, p.status)
        sh(dir, "checkout", "-q", "-f", "--detach", root_hash)
        p = await(fetch.examine_probe(dir))
        assert.is_nil(p.head.branch)
        assert.equals(root_hash, p.head.hash)
        vim.fn.delete(dir, "rf")
    end)

    it("probe: a staged + unstaged (MM) file counts once in the prompt's N", function()
        local dir, root_hash = scratch()
        write(dir .. "/f", "staged\n")
        sh(dir, "add", "f")                   -- f: staged only
        write(dir .. "/g", "staged\n")
        sh(dir, "add", "g")
        write(dir .. "/g", "and unstaged\n")  -- g: MM
        write(dir .. "/new", "u\n")           -- untracked
        local p = await(fetch.examine_probe(dir))
        assert.equals(3, examine.dirty_count(p.status))
        local c = { hash = root_hash, parents = {} }
        local plan = examine.examine_plan({ newer = c, older = c, status = p.status,
            head = p.head, root = dir })
        assert.equals(3, plan.stash.count)
        vim.fn.delete(dir, "rf")
    end)

    it("dirty → stash → detached checkout; Return → branch, edits restored, stash dropped", function()
        local dir, root_hash = scratch()
        write(dir .. "/g", "edited\n")
        write(dir .. "/untracked", "u\n")
        local before = stash_list(dir)
        local plan, r = run_examine(dir, root_hash)
        assert.equals("checkout", plan.kind)
        assert.is_true(r.ok)
        assert.is_not_nil(r.stash)
        assert.equals(sh(dir, "rev-parse", "stash@{0}"), r.stash)
        assert.equals("On main: gitloom: examine " .. root_hash:sub(1, 7) .. " (from main)",
            sh(dir, "log", "-1", "--format=%s", r.stash))
        assert.equals(root_hash, sh(dir, "rev-parse", "HEAD"))
        assert.equals("HEAD", sh(dir, "rev-parse", "--abbrev-ref", "HEAD"))
        assert.equals("", sh(dir, "status", "--porcelain"))
        assert.same({ orig = "main", detached = false, stash = r.stash,
            stash_message = plan.stash.message, examined = root_hash }, plan.state)

        local rr = await(fetch.examine_return(examine.return_plan(plan.state), dir))
        assert.is_true(rr.ok)
        assert.equals("main", sh(dir, "rev-parse", "--abbrev-ref", "HEAD"))
        assert.equals("edited\n", read(dir .. "/g"))
        assert.equals("u\n", read(dir .. "/untracked"))
        assert.equals(before, stash_list(dir))
        vim.fn.delete(dir, "rf")
    end)

    it("Examine at HEAD on a dirty tree: opens, nothing stashed, HEAD and the edits untouched", function()
        for _, detach in ipairs({ false, true }) do
            local dir, _, head = scratch()
            if detach then sh(dir, "checkout", "-q", "--detach", "HEAD") end
            write(dir .. "/f", "dirty\n")
            write(dir .. "/new", "u\n")
            local plan, r = run_examine(dir, head)
            assert.equals("open", plan.kind)
            assert.is_nil(r)
            assert.equals("worktree", plan.range.to) -- one rev against the files on disk
            assert.equals(head, sh(dir, "rev-parse", "HEAD"))
            assert.equals("", stash_list(dir))
            assert.equals(detach and "HEAD" or "main", sh(dir, "rev-parse", "--abbrev-ref", "HEAD"))
            assert.equals("dirty\n", read(dir .. "/f"))
            assert.equals("u\n", read(dir .. "/new"))
            vim.fn.delete(dir, "rf")
        end
    end)

    it("clean tree: no stash, state still records orig; Return switches back", function()
        local dir, root_hash = scratch()
        local plan, r = run_examine(dir, root_hash)
        assert.is_true(r.ok)
        assert.is_nil(r.stash)
        assert.equals("", stash_list(dir))
        local rr = await(fetch.examine_return(examine.return_plan(plan.state), dir))
        assert.is_true(rr.ok)
        assert.equals("main", sh(dir, "rev-parse", "--abbrev-ref", "HEAD"))
        vim.fn.delete(dir, "rf")
    end)

    it("a second examine keeps orig + the stash; a dirty one is refused", function()
        local dir, root_hash, second = scratch()
        write(dir .. "/g", "edited\n")
        local plan = run_examine(dir, root_hash)
        local plan2, r2 = run_examine(dir, second, plan.state)
        assert.is_true(r2.ok)
        assert.equals(second, sh(dir, "rev-parse", "HEAD"))
        assert.equals(plan.state.stash, plan2.state.stash)
        assert.equals("main", plan2.state.orig)
        write(dir .. "/g", "again\n")
        local plan3, r3 = run_examine(dir, root_hash, plan2.state)
        assert.equals("refuse", plan3.kind)
        assert.is_nil(r3)
        assert.equals(second, sh(dir, "rev-parse", "HEAD"))
        sh(dir, "checkout", "-q", "--", "g")
        local rr = await(fetch.examine_return(examine.return_plan(plan2.state), dir))
        assert.is_true(rr.ok)
        assert.equals("edited\n", read(dir .. "/g"))
        vim.fn.delete(dir, "rf")
    end)

    it("a conflicting apply KEEPS the stash (and HEAD is back on the branch)", function()
        local dir, root_hash = scratch()
        write(dir .. "/g", "stashed\n")
        local plan = run_examine(dir, root_hash)
        local sha = plan.state.stash
        assert.is_not_nil(sha)
        -- Meanwhile `main` moves g, so the stashed edit no longer applies cleanly.
        sh(dir, "switch", "-q", "main")
        write(dir .. "/g", "moved\n")
        sh(dir, "commit", "-q", "-am", "move g")
        sh(dir, "checkout", "-q", "--detach", root_hash)
        local rr = await(fetch.examine_return(examine.return_plan(plan.state), dir))
        assert.is_false(rr.ok)
        assert.equals("apply", rr.stage)
        assert.is_true(rr.res.code ~= 0)
        assert.equals("main", sh(dir, "rev-parse", "--abbrev-ref", "HEAD"))
        assert.equals(0, examine.stash_index(stash_list(dir), sha --[[@as string]]))
        vim.fn.delete(dir, "rf")
    end)

    it("Return restores the index: staged stays staged, unstaged unstaged, untracked back", function()
        local dir, root_hash = scratch()
        write(dir .. "/g", "staged\n")
        sh(dir, "add", "g")
        write(dir .. "/f", "unstaged\n")
        write(dir .. "/untracked", "u\n")
        local before = stash_list(dir)
        local plan = run_examine(dir, root_hash)
        assert.equals("", sh(dir, "status", "--porcelain"))
        local rr = await(fetch.examine_return(examine.return_plan(plan.state), dir))
        assert.is_true(rr.ok)
        assert.is_nil(rr.unstaged)
        assert.equals("main", sh(dir, "rev-parse", "--abbrev-ref", "HEAD"))
        assert.equals("g", sh(dir, "diff", "--cached", "--name-only"))
        assert.equals("f", sh(dir, "diff", "--name-only"))
        assert.equals("staged\n", read(dir .. "/g"))
        assert.equals("unstaged\n", read(dir .. "/f"))
        assert.equals("u\n", read(dir .. "/untracked"))
        assert.equals(before, stash_list(dir))
        vim.fn.delete(dir, "rf")
    end)

    it("a file with BOTH a staged and an unstaged edit round-trips both", function()
        local dir, root_hash = scratch()
        write(dir .. "/g", "in the index\n")
        sh(dir, "add", "g")
        write(dir .. "/g", "in the tree\n")
        local plan = run_examine(dir, root_hash)
        local rr = await(fetch.examine_return(examine.return_plan(plan.state), dir))
        assert.is_true(rr.ok)
        assert.equals("in the index", sh(dir, "show", ":g"))
        assert.equals("in the tree\n", read(dir .. "/g"))
        assert.equals("", stash_list(dir))
        vim.fn.delete(dir, "rf")
    end)

    -- A five-line file whose line 1 is staged; meanwhile `main` changes line 3.
    -- `--index` replays the staged patch with exact context, so git refuses it
    -- ("conflicts in index") having touched nothing — but the plain 3-way apply
    -- merges cleanly.
    local function five_lines(dir)
        write(dir .. "/h", "1\n2\n3\n4\n5\n")
        sh(dir, "add", "h")
        sh(dir, "commit", "-q", "-m", "h")
        local base = sh(dir, "rev-parse", "HEAD")
        -- Move `main` past `base` (h untouched): examining HEAD's own commit would
        -- be a plain Examine — no checkout, no stash (§10.4.2).
        write(dir .. "/k", "k\n")
        sh(dir, "add", "k")
        sh(dir, "commit", "-q", "-m", "k")
        return base
    end

    it("--index refused → plain apply: changes back but unstaged, flagged, stash dropped", function()
        local dir = scratch()
        local base = five_lines(dir)
        write(dir .. "/h", "ONE\n2\n3\n4\n5\n")
        sh(dir, "add", "h")
        write(dir .. "/g", "unstaged\n")
        write(dir .. "/untracked", "u\n")
        local plan = run_examine(dir, base)
        sh(dir, "switch", "-q", "main")
        write(dir .. "/h", "1\n2\nTHREE\n4\n5\n")
        sh(dir, "commit", "-q", "-am", "move h")
        sh(dir, "checkout", "-q", "--detach", base)
        local rr = await(fetch.examine_return(examine.return_plan(plan.state), dir))
        assert.is_true(rr.ok)
        assert.is_true(rr.unstaged)
        assert.is_true(examine.index_refused(rr.index_res))
        assert.equals("main", sh(dir, "rev-parse", "--abbrev-ref", "HEAD"))
        assert.equals("ONE\n2\nTHREE\n4\n5\n", read(dir .. "/h"))
        assert.equals("unstaged\n", read(dir .. "/g"))
        assert.equals("u\n", read(dir .. "/untracked"))
        assert.equals("", sh(dir, "diff", "--cached", "--name-only"))
        assert.equals("", stash_list(dir))
        vim.fn.delete(dir, "rf")
    end)

    it("--index refused and the plain apply conflicts too: the stash is KEPT", function()
        local dir = scratch()
        local base = five_lines(dir)
        write(dir .. "/h", "ONE\n2\n3\n4\n5\n")
        sh(dir, "add", "h")
        local plan = run_examine(dir, base)
        local sha = plan.state.stash
        sh(dir, "switch", "-q", "main")
        write(dir .. "/h", "uno\n2\n3\n4\n5\n")
        sh(dir, "commit", "-q", "-am", "clash on line 1")
        sh(dir, "checkout", "-q", "--detach", base)
        local rr = await(fetch.examine_return(examine.return_plan(plan.state), dir))
        assert.is_false(rr.ok)
        assert.equals("apply", rr.stage)
        assert.is_true(rr.res.code ~= 0)
        assert.equals("main", sh(dir, "rev-parse", "--abbrev-ref", "HEAD"))
        assert.equals(0, examine.stash_index(stash_list(dir), sha --[[@as string]]))
        vim.fn.delete(dir, "rf")
    end)

    it("a failed switch back stops before the apply (state kept by the caller)", function()
        local dir, root_hash = scratch()
        write(dir .. "/g", "stashed\n")
        local plan = run_examine(dir, root_hash)
        -- A new local edit to f, which differs between root and main: switch refuses.
        write(dir .. "/f", "local\n")
        local rr = await(fetch.examine_return(examine.return_plan(plan.state), dir))
        assert.is_false(rr.ok)
        assert.equals("switch", rr.stage)
        assert.equals(root_hash, sh(dir, "rev-parse", "HEAD"))
        assert.equals(0, examine.stash_index(stash_list(dir), plan.state.stash))
        vim.fn.delete(dir, "rf")
    end)

    it("a checkout failing after the stash re-applies it (clean → dropped)", function()
        local dir = scratch()
        write(dir .. "/g", "edited\n")
        write(dir .. "/untracked", "u\n")
        local before = stash_list(dir)
        local plan, r = run_examine(dir, ("d"):rep(40)) -- no such commit
        assert.equals("checkout", plan.kind)
        assert.is_false(r.ok)
        assert.equals("checkout", r.stage)
        assert.is_not_nil(r.stash)
        assert.is_true(r.restored)
        assert.equals("main", sh(dir, "rev-parse", "--abbrev-ref", "HEAD"))
        assert.equals("edited\n", read(dir .. "/g"))
        assert.equals("u\n", read(dir .. "/untracked"))
        assert.equals(before, stash_list(dir))
        vim.fn.delete(dir, "rf")
    end)

    it("leaves other stashes alone (drop is by SHA, not position)", function()
        local dir, root_hash = scratch()
        write(dir .. "/g", "older stash\n")
        sh(dir, "stash", "push", "-q", "-m", "examine_spec: someone else's")
        local other = sh(dir, "rev-parse", "stash@{0}")
        write(dir .. "/g", "mine\n")
        local plan = run_examine(dir, root_hash)
        -- Another session pushes on top while we examine.
        write(dir .. "/h", "x\n")
        sh(dir, "stash", "push", "-q", "-u", "-m", "examine_spec: pushed later")
        local later = sh(dir, "rev-parse", "stash@{0}")
        local rr = await(fetch.examine_return(examine.return_plan(plan.state), dir))
        assert.is_true(rr.ok)
        assert.equals("mine\n", read(dir .. "/g"))
        assert.equals(later .. "\n" .. other, stash_list(dir))
        vim.fn.delete(dir, "rf")
    end)
end)

-- ── Optional: the single-rev open against the real diffview ─────────────────

local dv_path = vim.g.gitloom_test_deps .. "/diffview.nvim"
local have_dv = vim.fn.isdirectory(dv_path) == 1

;(have_dv and describe or pending)("examine's single-rev range in the real diffview (§10.4.2)", function()
    it("opens with the right side LOCAL — the files on disk", function()
        vim.opt.rtp:prepend(dv_path)
        vim.cmd("runtime plugin/diffview.lua")
        require("diffview").setup({ use_icons = false })
        local dir, root_hash = scratch()
        local toplevel = sh(dir, "rev-parse", "--show-toplevel")
        local plan, r = run_examine(toplevel, root_hash)
        assert.is_true(r.ok)
        local lib = require("diffview.lib")
        local n0 = #lib.views
        require("gitloom.window")._internal.open_diffview(plan.range)
        assert.is_true(#lib.views > n0, "diffview opened no view")
        local v = lib.views[#lib.views]
        local RevType = require("diffview.vcs.rev").RevType
        assert.equals(RevType.LOCAL, v.right.type)
        assert.equals(RevType.COMMIT, v.left.type)
        -- Let the view finish loading and leave it open: closing a view races
        -- diffview's async teardown (see diff_provider_spec), and this is the
        -- file's last test. The scratch directory is left to the OS temp dir.
        vim.wait(5000, function() return v.ready == true end, 20)
        vim.wait(300)
    end)
end)
