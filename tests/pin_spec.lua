--- Tests for the ordered pin list (spec §10.6) and the pinned-branches dialog's
--- pure layout (§10.6.1). The list is ONE list — the pinned branches, in priority
--- order, each entry `{ id }` (the former per-entry dedicated-lane flag was
--- dropped). These are the pure pieces plus a windowed smoke of the dialog.

local internal = require("gitloom.graph")._internal
local pin_resolve = internal.pin_resolve
local pin_move = internal.pin_move
local pin_remove = internal.pin_remove
local pin_add = internal.pin_add
local pin_ids = internal.pin_ids
local pin_dialog_lines = internal.pin_dialog_lines

-- A pin list from names.
local function pins(...)
    local out = {}
    for _, s in ipairs({ ... }) do out[#out + 1] = { id = s } end
    return out
end

-- The ids of a pin list, in order.
local function ids(list)
    local out = {}
    for _, e in ipairs(list) do out[#out + 1] = e.id end
    return out
end

-- A ref registry standing in for repo.refs (only key presence matters here).
local function registry(...)
    local refs = {}
    for _, n in ipairs({ ... }) do refs[n] = { name = n } end
    return refs
end

describe("pin_resolve (§10.6)", function()
    it("is the defaults, in default order, for an untouched repository", function()
        local out = pin_resolve({}, {}, { "master", "dev" }, registry("master", "dev"))
        assert.same({ "master", "dev" }, ids(out))
    end)

    it("entries are { id } alone — a stray legacy `reserved` field is not carried", function()
        local out = pin_resolve({ { id = "topic1", reserved = true } }, {}, { "master" },
            registry("master", "topic1"))
        assert.same({ { id = "master" }, { id = "topic1" } }, out)
    end)

    it("unplaced defaults come first; stored entries keep their order after", function()
        local out = pin_resolve(pins("topic1", "master"), {}, { "master", "main" },
            registry("master", "main", "topic1"))
        assert.same({ "main", "topic1", "master" }, ids(out))
    end)

    it("defaults keep their order with HEAD's anchor last, a new pin at the bottom", function()
        -- pin_defaults order: trunks, seeds, then HEAD's anchor (`feat`).
        local stored = pin_add({}, "topic")
        local out = pin_resolve(stored, {}, { "master", "dev", "feat" },
            registry("master", "dev", "feat", "topic"))
        assert.same({ "master", "dev", "feat", "topic" }, ids(out))
    end)

    it("does not duplicate a default already on the stored list", function()
        local out = pin_resolve(pins("master"), {}, { "master" }, registry("master"))
        assert.same({ "master" }, ids(out))
    end)

    it("an explicitly unpinned id is suppressed, stored or defaulted", function()
        local out = pin_resolve(pins("topic1"), { topic1 = true, dev = true },
            { "master", "dev" }, registry("master", "dev", "topic1"))
        assert.same({ "master" }, ids(out))
    end)

    it("drops an entry whose ref no longer exists", function()
        local out = pin_resolve(pins("gone", "master"), {}, {}, registry("master"))
        assert.same({ "master" }, ids(out))
    end)

    it("accepts every id when no registry is given", function()
        local out = pin_resolve(pins("anything"), {}, {}, nil)
        assert.same({ "anything" }, ids(out))
    end)

    it("does not mutate the stored list", function()
        local stored = pins("master")
        pin_resolve(stored, {}, { "dev" }, registry("master", "dev"))
        assert.same({ "master" }, ids(stored))
    end)
end)

describe("pin_move (§10.6.1 <C-j>/<C-k>)", function()
    it("moves the entry down and reports its new index", function()
        local out, at = pin_move(pins("a", "b", "c"), 1, 1)
        assert.same({ "b", "a", "c" }, ids(out))
        assert.equals(2, at)
    end)

    it("moves the entry up", function()
        local out, at = pin_move(pins("a", "b", "c"), 3, -1)
        assert.same({ "a", "c", "b" }, ids(out))
        assert.equals(2, at)
    end)

    it("clamps at both ends (a repeatable key is a no-op there)", function()
        local top, at_top = pin_move(pins("a", "b"), 1, -1)
        assert.same({ "a", "b" }, ids(top))
        assert.equals(1, at_top)
        local bot, at_bot = pin_move(pins("a", "b"), 2, 1)
        assert.same({ "a", "b" }, ids(bot))
        assert.equals(2, at_bot)
    end)

    it("is a no-op on a missing index", function()
        local out = pin_move(pins("a"), 7, 1)
        assert.same({ "a" }, ids(out))
    end)

    it("does not mutate the input", function()
        local list = pins("a", "b")
        pin_move(list, 1, 1)
        assert.same({ "a", "b" }, ids(list))
    end)
end)

describe("pin_remove (§10.6.1 D)", function()
    it("removes the entry", function()
        local out = pin_remove(pins("a", "b", "c"), 2)
        assert.same({ "a", "c" }, ids(out))
    end)

    it("is a no-op on a missing index and does not mutate the input", function()
        local list = pins("a")
        assert.same({ "a" }, ids(pin_remove(list, 5)))
        pin_remove(list, 1)
        assert.same({ "a" }, ids(list))
    end)
end)

describe("pin_add", function()
    it("appends at the bottom", function()
        assert.same({ { id = "a" }, { id = "b" } }, pin_add(pins("a"), "b"))
    end)

    it("is idempotent — an already-pinned branch keeps its place", function()
        assert.same({ "a", "b" }, ids(pin_add(pins("a", "b"), "a")))
    end)

    it("does not mutate the input", function()
        local list = pins("a")
        pin_add(list, "b")
        assert.same({ "a" }, ids(list))
    end)
end)

describe("pin_ids", function()
    it("is the membership set — what view.owners / toggle_target consume", function()
        local set = pin_ids(pins("a", "b"))
        assert.is_true(set.a)
        assert.is_true(set.b)
        assert.is_nil(set.c)
    end)
end)

describe("pin_dialog_lines (§10.6.1)", function()
    local function joined(lines) return table.concat(lines, "\n") end

    it("numbers every entry, with no dedicated-lane marker", function()
        local lines, rows = pin_dialog_lines(pins("master", "topic1", "origin/release", "dev"))
        local text = joined(lines)
        assert.truthy(text:find("1  master", 1, true))
        assert.truthy(text:find("2  topic1", 1, true))
        assert.truthy(text:find("3  origin/release", 1, true))
        assert.truthy(text:find("4  dev", 1, true))
        assert.is_nil(text:find("◆", 1, true))
        -- The row map addresses each entry and the "pin new" row.
        local seen = {}
        for _, v in pairs(rows) do seen[tostring(v)] = true end
        assert.is_true(seen["1"] and seen["2"] and seen["3"] and seen["4"] and seen["new"])
    end)

    it("orders the row map by priority (row n is entry n)", function()
        local lines, rows = pin_dialog_lines(pins("a", "b", "c"))
        local by_index = {}
        for line, v in pairs(rows) do
            if type(v) == "number" then by_index[v] = line end
        end
        assert.is_true(by_index[1] < by_index[2] and by_index[2] < by_index[3])
        assert.truthy(lines[by_index[1]]:find("a", 1, true))
        assert.truthy(lines[by_index[3]]:find("c", 1, true))
    end)

    it("shows the key help and the add-a-branch row — no <Space> lane toggle", function()
        local text = joined((pin_dialog_lines(pins("master"))))
        for _, key in ipairs({ "<C-j>/<C-k>", "D", "<CR>", "q" }) do
            assert.truthy(text:find(key, 1, true))
        end
        assert.is_nil(text:find("<Space>", 1, true))
        assert.is_nil(text:lower():find("lane", 1, true))
        assert.truthy(text:find("Pin new branch", 1, true))
    end)

    it("renders an empty list as just the add row (no entries, no crash)", function()
        local lines, rows = pin_dialog_lines({})
        local text = joined(lines)
        assert.truthy(text:find("Pin new branch", 1, true))
        for _, v in pairs(rows) do assert.equals("new", v) end
    end)

    it("pads every row to the same left column so the help aligns", function()
        local lines = pin_dialog_lines(pins("a", "a-much-longer-branch-name"))
        local col = {}
        for _, l in ipairs(lines) do
            local s = l:find("<", 1, true)
            if s then col[#col + 1] = vim.fn.strdisplaywidth(l:sub(1, s - 1)) end
        end
        assert.is_true(#col >= 2)
        for _, c in ipairs(col) do assert.equals(col[1], c) end
    end)
end)

-- The dialog's window glue (§10.6.1) is conventionally untested, but a *smoke*
-- test is cheap here and catches the class of bug the unit tests cannot: a
-- runtime error in the keymaps, the re-render, or the focus handoff. It drives
-- the real dialog in a real float over a stub ctx (no git, no snacks, no
-- listview) and asserts what the user sees after each key.
describe("pinned-branches dialog (§10.6.1) — windowed smoke", function()
    local window = require("gitloom.window")
    local git = require("gitloom.git")

    -- A stub GraphCtx: a real host window plus counted no-op glue, so the dialog's
    -- reflow / cursor-restore path runs without a live graph.
    local function stub()
        local repo = { root = "/r", commits = {}, order = {}, refs = {} }
        git.add_ref(repo, "master", "local", "h1")
        git.add_ref(repo, "dev", "local", "h2")
        repo.head = "master"
        local hbuf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(hbuf, 0, -1, false, { "a", "b", "c" })
        local hwin = vim.api.nvim_open_win(hbuf, true, {
            relative = "editor", row = 1, col = 1, width = 60, height = 15,
            style = "minimal", zindex = 41, -- the host layer (§14.1)
        })
        local ctx = {
            repo = repo, opts = {}, repo_key = "/r",
            view_state = { pins = {}, unpinned = {}, modes = {}, effective = {} },
            seed_pin_names = {}, selection_state = {}, reflows = 0,
            win = function() return hwin end,
            cursor_hash = function() return nil end,
            reflow = function(c) c.reflows = c.reflows + 1 end,
            place_cursor = function() end,
            update_footer = function() end,
            update_panes = function() end,
            goto_hash = function() return true end,
        }
        for k, f in pairs(window._internal) do ctx[k] = f end
        return ctx, hwin
    end

    local function feed(keys)
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
    end

    local function text()
        return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    end

    -- The dialog line the cursor sits on.
    local function cursor_line()
        local l = vim.api.nvim_win_get_cursor(0)[1]
        return vim.api.nvim_buf_get_lines(0, l - 1, l, false)[1] or ""
    end

    it("opens focused, listing the anchors", function()
        local ctx, hwin = stub()
        ctx:pin_dialog()
        assert.is_true(vim.api.nvim_get_current_win() ~= hwin)
        local t = text()
        assert.truthy(t:find("1  master", 1, true))
        assert.truthy(t:find("2  dev", 1, true))
        assert.truthy(t:find("Pin new branch", 1, true))
        feed("q")
        assert.equals(hwin, vim.api.nvim_get_current_win())
    end)

    it("<Space> is not bound — it edits nothing and does not reflow", function()
        local ctx = stub()
        ctx:pin_dialog()
        feed("<Space>")
        assert.equals(0, ctx.reflows)
        assert.same({ { id = "master" }, { id = "dev" } }, ctx:effective_pins())
        feed("q")
    end)

    it("<C-j> moves the entry down, with the cursor following", function()
        local ctx = stub()
        ctx:pin_dialog()
        feed("<C-j>")
        local t = text()
        assert.truthy(t:find("1  dev", 1, true))
        assert.truthy(t:find("2  master", 1, true))
        assert.truthy(cursor_line():find("master", 1, true)) -- followed the move
        assert.same({ { id = "dev" }, { id = "master" } }, ctx:effective_pins())
        feed("q")
    end)

    it("D unpins the entry", function()
        local ctx = stub()
        ctx:pin_dialog()
        feed("D")
        assert.is_nil(text():find("master", 1, true))
        assert.same({ "dev" }, ids(ctx:effective_pins()))
        assert.is_true(ctx.view_state.unpinned.master) -- the default anchor stays gone
        feed("q")
    end)
end)

describe("pin_rank / pin_anchors (§10.6 a pin covers the identity)", function()
    local selectm = require("gitloom.graph.select")
    local rankm = require("gitloom.graph.rank")
    -- dev tracks `up/dev-renamed`; origin, fork and a remote missing from the
    -- `git remote` list (zz) all carry a `dev`.
    local function refs()
        local r = {
            master = { name = "master", kind = "local" },
            dev = { name = "dev", kind = "local", upstream = { short = "up/dev-renamed" } },
            topic = { name = "topic", kind = "local" },
            ["origin/dev"] = { name = "origin/dev", kind = "remote" },
            ["fork/dev"] = { name = "fork/dev", kind = "remote" },
            ["zz/dev"] = { name = "zz/dev", kind = "remote" },
            ["up/dev-renamed"] = { name = "up/dev-renamed", kind = "remote" },
            ["origin/topic"] = { name = "origin/topic", kind = "remote" },
            ["origin/master"] = { name = "origin/master", kind = "remote" },
            ["origin/solo"] = { name = "origin/solo", kind = "remote" },
            ["fork/solo"] = { name = "fork/solo", kind = "remote" },
            v1 = { name = "v1", kind = "tag" },
        }
        return r
    end
    local function anchors(list, unpinned)
        local r = refs()
        return selectm.pin_anchors(list, rankm.pair(r, { remotes = { "fork", "origin" }, pins = list }), unpinned)
    end

    it("pin_rank ranks the entries only, by place", function()
        assert.same({ master = 1, ["origin/dev"] = 2, dev = 3 }, selectm.pin_rank(pins("master", "origin/dev", "dev")))
    end)

    it("pinning a local anchors every paired remote and its differently named upstream", function()
        assert.same({ dev = true, ["origin/dev"] = true, ["fork/dev"] = true, ["zz/dev"] = true,
            ["up/dev-renamed"] = true }, anchors(pins("dev")))
    end)

    it("pinning a paired remote anchors its whole identity, the local included", function()
        local a = anchors(pins("origin/dev"))
        assert.is_true(a.dev)
        assert.is_true(a["fork/dev"])
        assert.is_nil(a.master)
    end)

    it("pinning a remote-only branch anchors every remote of its short name", function()
        assert.same({ ["origin/solo"] = true, ["fork/solo"] = true }, anchors(pins("origin/solo")))
    end)

    it("an explicit unpin drops one member's anchor, keeping the others; an entry is never dropped", function()
        local a = anchors(pins("dev"), { ["origin/dev"] = true })
        assert.is_nil(a["origin/dev"])
        assert.is_true(a["fork/dev"])
        assert.is_true(a.dev)
        -- an entry is its own anchor even with a stale override (pin_resolve already filters)
        assert.is_true(anchors(pins("origin/dev"), { ["origin/dev"] = true })["origin/dev"])
    end)

    it("a tag entry anchors itself only", function()
        assert.same({ v1 = true }, anchors(pins("v1")))
    end)

    it("the dialog lists the entries only — identity members have no rows", function()
        local list = pin_resolve(pins("dev"), {}, { "master" }, refs())
        local lines, rows = pin_dialog_lines(list)
        local n = 0
        for _, v in pairs(rows) do if type(v) == "number" then n = n + 1 end end
        assert.equal(2, n)
        for _, l in ipairs(lines) do assert.is_nil(l:find("origin/dev", 1, true)) end
    end)
end)
