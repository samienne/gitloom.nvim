--- Tests for the ordered pin list (spec §10.6) and the pinned-branches dialog's
--- pure layout (§10.6.1). The list is ONE list — the pinned branches, in priority
--- order — with the dedicated-lane flag (§10.6.2) living ON each entry, so
--- `reserved ⊆ pinned` and "unpin implies unreserve" hold by construction. These
--- are the pure pieces; the dialog's window glue is untested like the rest of it.

local internal = require("gitloom.graph")._internal
local pin_resolve = internal.pin_resolve
local pin_move = internal.pin_move
local pin_toggle_reserved = internal.pin_toggle_reserved
local pin_remove = internal.pin_remove
local pin_add = internal.pin_add
local pin_ids = internal.pin_ids
local reserved_order = internal.reserved_order
local pin_dialog_lines = internal.pin_dialog_lines

-- A pin list from `"name"` / `"name*"` (the star = reserved) shorthand.
local function pins(...)
    local out = {}
    for _, s in ipairs({ ... }) do
        local name, star = s:match("^(.-)(%*?)$")
        out[#out + 1] = { id = name, reserved = star == "*" }
    end
    return out
end

-- The ids of a pin list, in order.
local function ids(list)
    local out = {}
    for _, e in ipairs(list) do out[#out + 1] = e.id end
    return out
end

-- The `"name"`/`"name*"` shorthand of a pin list, so order AND flags assert as one.
local function shorthand(list)
    local out = {}
    for _, e in ipairs(list) do out[#out + 1] = e.id .. (e.reserved and "*" or "") end
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

    it("defaults are pinned but NOT reserved", function()
        local out = pin_resolve({}, {}, { "master", "dev" }, registry("master", "dev"))
        for _, e in ipairs(out) do assert.is_false(e.reserved) end
        assert.same({}, reserved_order(out))
    end)

    it("unplaced defaults come first; stored entries keep their order and flags after", function()
        local out = pin_resolve(pins("topic1*", "master"), {}, { "master", "main" },
            registry("master", "main", "topic1"))
        assert.same({ "main", "topic1*", "master" }, shorthand(out))
    end)

    it("defaults keep their order with HEAD's anchor last, a new pin at the bottom", function()
        -- pin_defaults order: trunks, seeds, then HEAD's anchor (`feat`).
        local stored = pin_add({}, "topic")
        local out = pin_resolve(stored, {}, { "master", "dev", "feat" },
            registry("master", "dev", "feat", "topic"))
        assert.same({ "master", "dev", "feat", "topic" }, ids(out))
    end)

    it("does not duplicate a default already on the stored list", function()
        local out = pin_resolve(pins("master*"), {}, { "master" }, registry("master"))
        assert.same({ "master*" }, shorthand(out))
    end)

    it("an explicitly unpinned id is suppressed, stored or defaulted", function()
        local out = pin_resolve(pins("topic1"), { topic1 = true, dev = true },
            { "master", "dev" }, registry("master", "dev", "topic1"))
        assert.same({ "master" }, ids(out))
    end)

    it("drops an entry whose ref no longer exists", function()
        local out = pin_resolve(pins("gone*", "master"), {}, {}, registry("master"))
        assert.same({ "master" }, ids(out))
    end)

    it("accepts every id when no registry is given", function()
        local out = pin_resolve(pins("anything"), {}, {}, nil)
        assert.same({ "anything" }, ids(out))
    end)

    it("does not mutate the stored list", function()
        local stored = pins("master*")
        pin_resolve(stored, {}, { "dev" }, registry("master", "dev"))
        assert.same({ "master*" }, shorthand(stored))
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

    it("carries the reserve flag with the entry", function()
        local out = pin_move(pins("a", "b*"), 2, -1)
        assert.same({ "b*", "a" }, shorthand(out))
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

describe("pin_toggle_reserved (§10.6.1 <Space>)", function()
    it("flips the entry's flag and leaves the others alone", function()
        local out = pin_toggle_reserved(pins("a", "b"), 2)
        assert.same({ "a", "b*" }, shorthand(out))
        assert.same({ "a", "b" }, shorthand(pin_toggle_reserved(out, 2)))
    end)

    it("does not mutate the input", function()
        local list = pins("a")
        pin_toggle_reserved(list, 1)
        assert.same({ "a" }, shorthand(list))
    end)
end)

describe("pin_remove (§10.6.1 D) — unpin implies unreserve", function()
    it("removes the entry", function()
        local out = pin_remove(pins("a", "b", "c"), 2)
        assert.same({ "a", "c" }, ids(out))
    end)

    it("takes the reserve flag with it — nothing is left to clear", function()
        local list = pins("a*", "b*")
        local out = pin_remove(list, 1)
        assert.same({ "b" }, ids(out))
        assert.same({ "b" }, reserved_order(out)) -- only the surviving entry reserves
        -- Re-pinning the removed branch brings it back UNRESERVED: the flag was
        -- never stored anywhere but on the entry that left.
        local back = pin_add(out, "a")
        assert.same({ "b*", "a" }, shorthand(back))
        assert.same({ "b" }, reserved_order(back))
    end)

    it("is a no-op on a missing index and does not mutate the input", function()
        local list = pins("a")
        assert.same({ "a" }, ids(pin_remove(list, 5)))
        pin_remove(list, 1)
        assert.same({ "a" }, ids(list))
    end)
end)

describe("pin_add", function()
    it("appends unreserved", function()
        assert.same({ "a*", "b" }, shorthand(pin_add(pins("a*"), "b")))
    end)

    it("is idempotent — an already-pinned branch keeps its place and its flag", function()
        assert.same({ "a*", "b" }, shorthand(pin_add(pins("a*", "b"), "a")))
    end)

    it("does not mutate the input", function()
        local list = pins("a")
        pin_add(list, "b")
        assert.same({ "a" }, ids(list))
    end)
end)

describe("pin_ids", function()
    it("is the membership set — what view.owners / collapse_owners consume", function()
        local set = pin_ids(pins("a*", "b"))
        assert.is_true(set.a)
        assert.is_true(set.b)
        assert.is_nil(set.c)
    end)
end)

describe("reserved_order (§10.6.2)", function()
    it("is the reserved ids in list order, skipping the unreserved between them", function()
        assert.same({ "a", "d" }, reserved_order(pins("a*", "b", "c", "d*")))
    end)

    it("is empty when nothing is reserved — the default state", function()
        assert.same({}, reserved_order(pins("a", "b", "c")))
    end)

    it("an unreserved entry's position is LATENT: moving it changes nothing", function()
        local list = pins("a*", "b", "c*")
        local before = reserved_order(list)
        local moved = pin_move(list, 2, 1) -- move the unreserved `b` past `c*`
        assert.same({ "a", "c" }, before)
        assert.same(before, reserved_order(moved))
        -- …and becomes meaningful the moment it is reserved, at the position it
        -- was quietly holding all along.
        assert.same({ "a", "c", "b" }, reserved_order(pin_toggle_reserved(moved, 3)))
    end)

    it("reordering reserved entries reorders the columns they claim", function()
        local list = pins("a*", "b", "c*")
        assert.same({ "c", "a" }, reserved_order((pin_move(list, 3, -2))))
    end)
end)

describe("pin_dialog_lines (§10.6.1)", function()
    local function joined(lines) return table.concat(lines, "\n") end

    it("numbers every entry and marks only the reserved ones", function()
        local lines, rows = pin_dialog_lines(pins("master*", "topic1*", "origin/release", "dev"))
        local text = joined(lines)
        assert.truthy(text:find("1  ◆  master", 1, true))
        assert.truthy(text:find("2  ◆  topic1", 1, true))
        assert.truthy(text:find("3     origin/release", 1, true))
        assert.truthy(text:find("4     dev", 1, true))
        -- Exactly one ◆ per reserved entry (2), plus the title row's legend and
        -- the closing note — the unreserved entries carry none.
        local n = select(2, text:gsub("◆", ""))
        assert.equals(4, n)
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

    it("shows the key help and the add-a-branch row", function()
        local text = joined((pin_dialog_lines(pins("master"))))
        for _, key in ipairs({ "<C-j>/<C-k>", "<Space>", "D", "<CR>", "q" }) do
            assert.truthy(text:find(key, 1, true))
        end
        assert.truthy(text:find("Pin new branch", 1, true))
    end)

    it("says the dedicated-lane flag is not honoured yet (an inert control must say so)", function()
        local text = joined((pin_dialog_lines(pins("master*"))))
        assert.truthy(text:lower():find("not", 1, true))
        assert.truthy(text:find("◆", 1, true))
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

    it("opens focused, listing the anchors with no dedicated lane claimed", function()
        local ctx, hwin = stub()
        ctx:pin_dialog()
        assert.is_true(vim.api.nvim_get_current_win() ~= hwin)
        local t = text()
        assert.truthy(t:find("1     master", 1, true)) -- no ◆: pinning claims nothing
        assert.truthy(t:find("2     dev", 1, true))
        assert.truthy(t:find("Pin new branch", 1, true))
        feed("q")
        assert.equals(hwin, vim.api.nvim_get_current_win())
    end)

    it("<Space> reserves the entry under the cursor and reflows", function()
        local ctx = stub()
        ctx:pin_dialog()
        feed("<Space>")
        assert.truthy(text():find("1  ◆  master", 1, true))
        assert.equals(1, ctx.reflows)
        assert.same({ "master" }, reserved_order(ctx:effective_pins()))
        feed("q")
    end)

    it("<C-j> moves the entry down, carrying its flag, with the cursor following", function()
        local ctx = stub()
        ctx:pin_dialog()
        feed("<Space><C-j>")
        local t = text()
        assert.truthy(t:find("1     dev", 1, true))
        assert.truthy(t:find("2  ◆  master", 1, true))
        assert.truthy(cursor_line():find("master", 1, true)) -- followed the move
        feed("q")
    end)

    it("D unpins — the entry and its reserve flag both go", function()
        local ctx = stub()
        ctx:pin_dialog()
        feed("<Space>D")
        assert.is_nil(text():find("master", 1, true))
        assert.same({}, reserved_order(ctx:effective_pins()))
        assert.is_true(ctx.view_state.unpinned.master) -- the default anchor stays gone
        feed("q")
    end)
end)

describe("pin_counterparts / pin_rank (§10.6 implicit remote counterparts)", function()
    local selectm = require("gitloom.graph.select")
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
            v1 = { name = "v1", kind = "tag" },
        }
        return r
    end

    it("lists same-short-name remotes in `git remote` order, the rest by name, then the upstream", function()
        assert.same({ "fork/dev", "origin/dev", "zz/dev", "up/dev-renamed" },
            selectm.pin_counterparts(refs(), { "fork", "origin" }, "dev"))
        -- Before the remote list loads: every remote by name.
        assert.same({ "fork/dev", "origin/dev", "zz/dev", "up/dev-renamed" },
            selectm.pin_counterparts(refs(), nil, "dev"))
    end)

    it("does not repeat an upstream that already shares the short name", function()
        local r = refs()
        r.topic.upstream = { short = "origin/topic" }
        assert.same({ "origin/topic" }, selectm.pin_counterparts(r, { "origin" }, "topic"))
    end)

    it("has none for a remote, a tag or an unknown ref", function()
        assert.same({}, selectm.pin_counterparts(refs(), { "origin" }, "origin/dev"))
        assert.same({}, selectm.pin_counterparts(refs(), { "origin" }, "v1"))
        assert.same({}, selectm.pin_counterparts(refs(), { "origin" }, "nope"))
    end)

    it("ranks entries by place, a counterpart sharing its local's rank", function()
        local rank = selectm.pin_rank(pins("master", "dev"), refs(), { "origin" }, {})
        assert.same({
            master = 1, ["origin/master"] = 1,
            dev = 2, ["origin/dev"] = 2, ["fork/dev"] = 2, ["zz/dev"] = 2, ["up/dev-renamed"] = 2,
        }, rank)
    end)

    it("excludes an explicitly unpinned counterpart, keeping the others", function()
        local rank = selectm.pin_rank(pins("dev"), refs(), { "origin" }, { ["origin/dev"] = true })
        assert.is_nil(rank["origin/dev"])
        assert.equal(1, rank["fork/dev"])
        assert.equal(1, rank.dev)
    end)

    it("an explicitly pinned remote keeps its own rank", function()
        local rank = selectm.pin_rank(pins("origin/dev", "master", "dev"), refs(), { "origin" }, {})
        assert.equal(1, rank["origin/dev"])
        assert.equal(3, rank.dev)
        assert.equal(3, rank["fork/dev"])
        -- …and below its local, it still has its own (worse) rank.
        rank = selectm.pin_rank(pins("dev", "master", "origin/dev"), refs(), { "origin" }, {})
        assert.equal(3, rank["origin/dev"])
        assert.equal(1, rank["fork/dev"])
    end)

    it("pins no counterpart with counterparts off (pin_upstream = false)", function()
        assert.same({ dev = 1 }, selectm.pin_rank(pins("dev"), refs(), { "origin" }, {}, false))
    end)

    it("counterparts off is the layout's map: entries only, an explicit remote kept (§5.5)", function()
        -- The anchor set (counterparts on) is a superset; the layout ranks entries only,
        -- so no counterpart can be born with, or claim, a pinned colour.
        local layout = selectm.pin_rank(pins("master", "origin/dev", "dev"), refs(), { "origin" }, {}, false)
        assert.same({ master = 1, ["origin/dev"] = 2, dev = 3 }, layout)
        local anchors = selectm.pin_rank(pins("master", "origin/dev", "dev"), refs(), { "origin" }, {})
        for id, k in pairs(layout) do assert.equal(k, anchors[id]) end
        assert.equal(1, anchors["origin/master"])
    end)

    it("the dialog lists the entries only — counterparts have no rows", function()
        local list = pin_resolve(pins("dev"), {}, { "master" }, refs())
        local lines, rows = pin_dialog_lines(list)
        local n = 0
        for _, v in pairs(rows) do if type(v) == "number" then n = n + 1 end end
        assert.equal(2, n)
        for _, l in ipairs(lines) do assert.is_nil(l:find("origin/dev", 1, true)) end
    end)
end)
