--- `<Space>` (spec §10.4) end to end through the window glue, over a stub ctx
--- with real signatures: `branch_under_cursor` resolves the row's own owners
--- (§10.2), `toggle_branch` acts and gives the notices; `reflow_owners` +
--- `pin_marks` resolve the expanded marker set (§6). No window is opened: the stub
--- records `set_branch` calls instead of reflowing.

local view = require("gitloom.graph.view")
local helpers = require("tests.graph_helpers")
local wi = require("gitloom.window")._internal
local palette = require("gitloom.graph.palette")

--- A stub GraphCtx over the DAG `rows`, refs `{ id = hash }` (ids with a `/`
--- under `remotes` are remote refs), anchors `pinned` and mode overrides `modes`.
--- Returns the ctx plus a `by_hash` map; `ctx.calls` records `set_branch`.
local function stub(rows, refs, pinned, modes, remotes)
    local items = helpers.dag(rows)
    local by_hash = {}
    for _, it in ipairs(items) do by_hash[it.commit.hash] = it.commit end
    local repo_refs = {}
    for id, h in pairs(refs) do
        local kind = (remotes and remotes[id]) and "remote" or "local"
        local r = { kind = kind, name = id, commit = by_hash[h] }
        repo_refs[id] = r
        local c = by_hash[h]
        c.refs = c.refs or {}
        c.refs[#c.refs + 1] = r
    end
    for _, c in pairs(by_hash) do table.sort(c.refs or {}, function(a, b) return a.name < b.name end) end
    local ctx = {
        repo = { order = items, refs = repo_refs },
        opts = { collapse_merged = true, icons = { pin = "⚲", expanded = "▾" } },
        view_state = { modes = modes or {}, effective = {}, owner_tip = {}, expanded = {}, unpinned = {} },
        sig_cache = {},
        selection_state = {},
        calls = {},
    }
    function ctx:effective_pinned() return pinned end
    -- pin_marks resolves the pin set itself, from the ordered entries.
    function ctx:effective_pins()
        local out = {}
        for id in pairs(pinned) do out[#out + 1] = { id = id } end
        return out
    end
    function ctx:set_branch(b, mode, follow)
        self.calls[#self.calls + 1] = { owners = b.owners, mode = mode, follow = follow }
        for _, oid in ipairs(b.owners or {}) do self.view_state.modes[oid] = mode end
    end
    -- The rows the cursor can be on: `ctx.rows[line]` (set per test).
    function ctx:order_at(line) return self.rows[line] end
    local owners = wi.reflow_owners(ctx, true)
    ctx.sig_cache.sig = view.signatures(items, owners)
    return ctx, by_hash
end

--- Run `fn` with vim.notify captured; returns the messages.
local function notices(fn)
    local got, orig = {}, vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg) got[#got + 1] = msg end
    local ok, err = pcall(fn)
    vim.notify = orig
    assert(ok, err)
    return got
end

local function space(ctx, line)
    return notices(function()
        local b = wi.branch_under_cursor(ctx, line)
        if b then wi.toggle_branch(ctx, b) end
    end)
end

-- d1 (D) -> a (A, B) -> a1 -> base ; x (main, pinned) -> base.
local STACK = {
    { "d1", { "a" } }, { "a", { "a1" } }, { "a1", { "base" } },
    { "x", { "base" } }, { "base", {} },
}

describe("<Space> on an open row (§10.4)", function()
    it("folds both refs on a multi-ref row even with one of them selected", function()
        local ctx, c = stub(STACK, { A = "a", B = "a", main = "x" }, { main = true },
            { A = "normal", B = "normal" })
        ctx.rows = { { type = "commit", commit = c.a } }
        ctx.selection_state = { commit = c.a, index = 1 } -- A selected
        local msgs = space(ctx, 1)
        assert.equals(1, #ctx.calls)
        assert.same({ "A", "B" }, ctx.calls[1].owners)
        assert.equals("collapsed", ctx.calls[1].mode)
        assert.same({}, msgs)
    end)

    it("never collapses a branch built on top, and says what keeps the row open", function()
        local ctx, c = stub(STACK, { A = "a", B = "a", D = "d1", main = "x" }, { main = true },
            { A = "normal", B = "normal", D = "normal" })
        ctx.rows = { { type = "commit", commit = c.a } }
        local msgs = space(ctx, 1)
        assert.same({ "A", "B" }, ctx.calls[1].owners)
        assert.equals("normal", ctx.view_state.modes.D)
        assert.same({ "still open via D" }, msgs)
        -- Again: nothing of its own left to collapse — only the notice, no flip back.
        ctx.view_state.effective.A, ctx.view_state.effective.B = "collapsed", "collapsed"
        local again = space(ctx, 1)
        assert.equals(1, #ctx.calls)
        assert.same({ "still open via D" }, again)
    end)

    it("on a mainline row changes nothing and names the anchor", function()
        local ctx, c = stub(STACK, { A = "a", main = "x" }, { main = true }, { A = "normal" })
        ctx.rows = { { type = "commit", commit = c.base } }
        local msgs = space(ctx, 1)
        assert.equals(0, #ctx.calls)
        assert.same({ "on main's mainline — not collapsible" }, msgs)
    end)
end)

describe("<Space> on a ◍ head (§10.4)", function()
    it("expands only its own owners; a collapsed branch above stays a ◍", function()
        local ctx, c = stub(STACK, { A = "a", B = "a", D = "d1", main = "x" }, { main = true })
        local head = { hash = "collapsed:a1", collapsed = true, tip = c.a, refs = c.a.refs,
            signature = ctx.sig_cache.sig.a }
        ctx.rows = { { type = "commit", commit = head } }
        space(ctx, 1)
        assert.same({ "A", "B" }, ctx.calls[1].owners)
        assert.equals("normal", ctx.calls[1].mode)
        assert.is_nil(ctx.view_state.modes.D)
    end)

    it("on a stretch shared below a fork opens every branch reaching it", function()
        local ctx, c = stub({
            { "f1", { "s" } }, { "f2", { "s" } }, { "s", { "base" } },
            { "x", { "base" } }, { "base", {} },
        }, { F1 = "f1", F2 = "f2", main = "x" }, { main = true })
        local head = { hash = "collapsed:s", collapsed = true, tip = c.s, refs = {},
            signature = ctx.sig_cache.sig.s }
        ctx.rows = { { type = "commit", commit = head } }
        space(ctx, 1)
        assert.same({ "F1", "F2" }, ctx.calls[1].owners)
    end)
end)

describe("palette collapse / expand entries name the own owners (§10.4)", function()
    it("names the refs and the keepers", function()
        local ctx, c = stub(STACK, { A = "a", B = "a", D = "d1", main = "x" }, { main = true },
            { A = "normal", B = "normal", D = "normal" })
        ctx.rows = { { type = "commit", commit = c.a } }
        local b = assert(wi.branch_under_cursor(ctx, 1))
        local row = { kind = "branch", state = b.state, commit = b.commit,
            own = require("gitloom.graph.select").owner_label(b.owners, ctx.repo.refs),
            keepers = require("gitloom.graph.select").owner_label(b.keepers, ctx.repo.refs) }
        local labels = {}
        for _, e in ipairs(palette.row_entries(row, false)) do labels[e.id] = e.label end
        assert.equals("Collapse A, B (stays open via D)  (<Space>)", labels.collapse)
    end)
end)

describe("the expanded marker set (§6)", function()
    it("marks refs opened against a collapsed default — not anchors, not anonymous owners", function()
        local ctx = stub({
            { "m", { "x", "g1" } }, { "g1", { "base" } }, { "f", { "x" } }, { "x", { "base" } }, { "base", {} },
        }, { main = "m", feat = "f", other = "g1" }, { main = true },
            { feat = "normal", main = "normal", ["merge:m:2"] = "normal" })
        assert.same({ feat = true }, ctx.view_state.expanded)
        local marks = wi.pin_marks(ctx)
        assert.same({ feat = true }, marks.expanded)
        assert.equals("▾", marks.expanded_icon)
    end)

    it("marks nothing with the first-parent focus off", function()
        local ctx = stub(STACK, { A = "a", main = "x" }, { main = true }, { A = "normal" })
        wi.reflow_owners(ctx, false)
        assert.same({}, ctx.view_state.expanded)
    end)
end)
