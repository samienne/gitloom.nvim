--- A detached HEAD acts as a pinned anchor everywhere a pinned ref matters
--- (spec §2, §6.2, §10.6): the pure decisions the window glue routes through.
---  * `select.head_target` — the commit the graph opens on / returns to (§2): HEAD's
---    commit whether HEAD is on a branch or detached; nil only with no HEAD commit.
---  * `pane.decline` — why the context panes are hidden (§6.2): a detached HEAD is
---    an anchor like any other, so it never declines them as "no HEAD".
---  * `select.pin_candidate` — the pin dialog's "Pin new branch…" list (§10.6.1):
---    a detached HEAD (an owner of its own) can be re-pinned after an unpin; an
---    attached one cannot (its branch is the owner).
--- The callers (open focus, on_show, the pane build, the dialog's picker) are
--- window glue and not unit-tested.

local selectm = require("gitloom.graph.select")
local pane = require("gitloom.graph.pane")

local H = ("a"):rep(40)
local C = { hash = H }

local function attached()
    return { HEAD = { name = "HEAD", kind = "head", commit = C, branch = "main" },
        main = { name = "main", kind = "local", commit = C } }
end
local function detached()
    return { HEAD = { name = "HEAD", kind = "head", commit = C } }
end

describe("head_target (§2)", function()
    it("is HEAD's commit on a branch", function()
        assert.equals(H, selectm.head_target(attached()))
    end)
    it("is HEAD's commit when detached — there IS something to focus", function()
        assert.equals(H, selectm.head_target(detached()))
    end)
    it("is nil with no HEAD, or a HEAD without a commit (an empty repository)", function()
        assert.is_nil(selectm.head_target({}))
        assert.is_nil(selectm.head_target(nil))
        ---@type table
        local commitless = { HEAD = { name = "HEAD", kind = "head" } }
        assert.is_nil(selectm.head_target(commitless))
    end)
end)

describe("pane.decline (§6.2)", function()
    local display = { {} }
    it("does not decline on a branch", function()
        assert.is_nil(pane.decline(true, attached(), display))
    end)
    it("does not decline on a detached HEAD", function()
        assert.is_nil(pane.decline(true, detached(), display))
    end)
    it("declines with no HEAD commit, when off, and with no display", function()
        assert.equals("no HEAD", pane.decline(true, {}, display))
        assert.equals("off", pane.decline(false, detached(), display))
        assert.equals("no display", pane.decline(true, detached(), {}))
        assert.equals("no display", pane.decline(true, detached(), nil))
    end)
    it("treats an unset option as on", function()
        assert.is_nil(pane.decline(nil, detached(), display))
    end)
end)

describe("pin_candidate (§10.6.1)", function()
    local head = { name = "HEAD", kind = "head" }
    local dev = { name = "dev", kind = "local" }
    it("offers a detached HEAD that is not on the list", function()
        assert.is_true(selectm.pin_candidate(head, {}, nil))
    end)
    it("never offers an attached HEAD (its branch is the owner)", function()
        assert.is_false(selectm.pin_candidate(head, {}, "main"))
    end)
    it("skips what is already pinned", function()
        assert.is_false(selectm.pin_candidate(head, { HEAD = true }, nil))
        assert.is_false(selectm.pin_candidate(dev, { dev = true }, "main"))
        assert.is_true(selectm.pin_candidate(dev, {}, "main"))
    end)
end)
