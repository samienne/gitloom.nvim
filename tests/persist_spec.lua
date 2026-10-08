--- Tests for the persisted view state (spec §18, `gitloom.persist`): the pure
--- precedence rule (built-in < setup() < persisted, a stored `{ value, base }`
--- yielding to a changed configuration), the pin-list reduction and per-repo
--- storage, and the file I/O — round trip, the re-read-merge write that keeps a
--- concurrent instance's keys, a corrupt file, the `persist = false` opt-out and
--- Reset's scope. Every test points the module at a scratch file; the real
--- `stdpath("state")/gitloom.json` is never touched. The window glue that calls
--- these (the toggle handlers, the pin writers, the live reset) needs a real
--- graph window and is not unit-tested.

local persist = require("gitloom.persist")

local function tmpfile()
    local p = vim.fn.tempname() .. "-gitloom.json"
    persist.set_path(p)
    return p
end

local function write_raw(p, text)
    local f = assert(io.open(p, "wb"))
    f:write(text)
    f:close()
end

local function read_json(p)
    local f = assert(io.open(p, "rb"))
    local t = f:read("*a")
    f:close()
    return vim.json.decode(t)
end

describe("persist precedence (§18.3)", function()
    it("config_values: setup() value, else the built-in default, normalised", function()
        local c = persist.config_values({ mirror = false, layout_policy = "gutter" })
        assert.equals(false, c.mirror)
        assert.equals("gutter", c.layout_policy)
        assert.equals("right", c.label_mode)
        assert.equals(true, c.highlight)     -- nil = on
        assert.equals(false, c.show_lane_ids) -- nil = off
        assert.equals("topo", c.sort_mode)
        assert.same(persist.BUILTIN.merge_style, c.merge_style)
        -- A partial merge style is resolved over the built-in one.
        local m = persist.config_values({ merge_style = { merge_on_separate_line = true } }).merge_style
        assert.equals(true, m.merge_on_separate_line)
        assert.equals(true, m.split_on_separate_line)
    end)

    it("a persisted value wins over the configuration it was saved against", function()
        local config = persist.config_values({})
        local opts = { mirror = true, layout_policy = "compact" }
        local applied = persist.overlay(opts, config, {
            mirror = { value = false, base = true },
            layout_policy = { value = "gutter", base = "compact" },
        })
        assert.same({ "layout_policy", "mirror" }, applied)
        assert.equals(false, opts.mirror)
        assert.equals("gutter", opts.layout_policy)
    end)

    it("a changed configuration wins: an entry whose base differs is ignored", function()
        -- Saved when the config resolved to `compact`; the user has since set
        -- `straight` in setup() — the config wins.
        local config = persist.config_values({ layout_policy = "straight" })
        local opts = { layout_policy = "straight" }
        persist.overlay(opts, config, { layout_policy = { value = "gutter", base = "compact" } })
        assert.equals("straight", opts.layout_policy)
    end)

    it("ignores a stored value of the wrong type, a missing value, and junk", function()
        local config = persist.config_values({})
        local opts = { mirror = true, label_mode = "right" }
        local applied = persist.overlay(opts, config, {
            mirror = { value = "yes", base = true },
            label_mode = { base = "right" },
            date_mode = "relative",
        })
        assert.same({}, applied)
        assert.same({}, persist.overlay(opts, config, nil))
    end)

    it("merge style round-trips as a table and compares structurally", function()
        local config = persist.config_values({})
        local style = { allow_merge_on_split = false, merge_on_separate_line = true, split_on_separate_line = true }
        local data = {}
        persist.set_pref(data, "merge_style", style, config)
        local opts = {}
        persist.overlay(opts, config, vim.json.decode(vim.json.encode(data.view)))
        assert.same(style, opts.merge_style)
    end)

    it("set_pref stores { value, base } and prunes OTHER stale entries", function()
        local config = persist.config_values({ date_mode = "relative" })
        local data = { view = {
            mirror = { value = false, base = true },                     -- still valid
            date_mode = { value = "absolute", base = "absolute" },       -- stale: config changed
            bogus = { value = 1, base = 1 },                             -- unknown key
        } }
        persist.set_pref(data, "highlight", false, config)
        assert.same({ value = false, base = true }, data.view.highlight)
        assert.same({ value = false, base = true }, data.view.mirror)
        assert.is_nil(data.view.date_mode)
        assert.is_nil(data.view.bogus)
    end)
end)

describe("persist pin state (§18.2)", function()
    it("pins_for_save drops unreserved defaults and auto upstreams, keeps the rest in order", function()
        local pins = {
            { id = "feature/x", reserved = false },           -- HEAD's branch: a default → dropped
            { id = "master", reserved = true },                -- reserved default → kept
            { id = "origin/master", reserved = false, auto = "master" }, -- auto → dropped
            { id = "release", reserved = false },              -- explicit → kept
            { id = "dev", reserved = false },                  -- unreserved default → dropped
        }
        assert.same({ { id = "master", reserved = true }, { id = "release", reserved = false } },
            persist.pins_for_save(pins, { "feature/x", "master", "dev" }))
    end)

    it("set_repo / repo_state round-trip per root; an empty state removes the entry", function()
        local data = {}
        persist.set_repo(data, "C:/a", { { id = "rel", reserved = true } }, { dev = true, main = true })
        persist.set_repo(data, "C:/b", { { id = "x", reserved = false } }, {})
        data = vim.json.decode(vim.json.encode(data), { luanil = { object = true, array = true } })
        local pins, unpinned = persist.repo_state(data, "C:/a")
        assert.same({ { id = "rel", reserved = true } }, pins)
        assert.same({ dev = true, main = true }, unpinned)
        assert.same({ { id = "x", reserved = false } }, (persist.repo_state(data, "C:/b")))
        persist.set_repo(data, "C:/b", {}, {})
        assert.is_nil(data.repos["C:/b"])
        local p2, u2 = persist.repo_state(data, "C:/none")
        assert.same({}, p2)
        assert.same({}, u2)
    end)

    it("repo_state sanitises junk entries", function()
        local data = { repos = { r = { pins = { { id = 3 }, "x", { id = "ok", reserved = "y" } }, unpinned = { 1, "d" } } } }
        local pins, unpinned = persist.repo_state(data, "r")
        assert.same({ { id = "ok", reserved = false } }, pins)
        assert.same({ d = true }, unpinned)
    end)
end)

describe("persist file I/O (§18.4)", function()
    -- Back to a throwaway file (never the real one) between tests.
    after_each(function() persist.set_path(vim.fn.tempname() .. "-gitloom.json") end)

    it("a missing file is an empty state, silently", function()
        tmpfile()
        local data, ok = persist.read()
        assert.same({}, data)
        assert.is_true(ok)
    end)

    it("round-trips a preference and a pin list through the file", function()
        local p = tmpfile()
        local opts = { mirror = false }
        local config = persist.config_values({})
        persist.save_pref(opts, config, "mirror")
        persist.save_pins({}, "C:/repo", { { id = "rel", reserved = true } }, { dev = true }, {})
        assert.equals(persist.VERSION, read_json(p).version)
        -- A fresh session (cache dropped) restores both.
        persist.set_path(p)
        local fresh = { mirror = true }
        persist.restore_opts(fresh, {})
        assert.equals(false, fresh.mirror)
        local pins, unpinned = persist.restore_pins({}, "C:/repo")
        assert.same({ { id = "rel", reserved = true } }, pins)
        assert.same({ dev = true }, unpinned)
    end)

    it("replaces an existing file (rename over it works on this platform)", function()
        local p = tmpfile()
        local config = persist.config_values({})
        persist.save_pref({ date_mode = "relative" }, config, "date_mode")
        persist.save_pref({ date_mode = "absolute" }, config, "date_mode")
        assert.same({ value = "absolute", base = "absolute" }, read_json(p).view.date_mode)
        -- No temp files left behind.
        local dir, base = vim.fn.fnamemodify(p, ":h"), vim.fn.fnamemodify(p, ":t")
        for name in vim.fs.dir(dir) do
            assert.is_true(not (name:find(base .. ".", 1, true) and name:match("%.tmp$")), name)
        end
    end)

    it("two writers changing different keys both survive (re-read before write)", function()
        local p = tmpfile()
        local config = persist.config_values({})
        -- Instance A has the file cached before B writes.
        persist.load()
        persist.save_pref({ mirror = false }, config, "mirror")
        -- Instance B (another nvim) writes its own key straight to the file.
        local other = read_json(p)
        other.view.label_mode = { value = "dual", base = "right" }
        other.repos = { ["C:/b"] = { pins = { { id = "x", reserved = false } }, unpinned = {} } }
        write_raw(p, vim.json.encode(other))
        -- A writes another key: B's keys are kept.
        persist.save_pref({ highlight = false }, config, "highlight")
        persist.save_pins({}, "C:/a", { { id = "y", reserved = true } }, {}, {})
        local final = read_json(p)
        assert.same({ value = false, base = true }, final.view.mirror)
        assert.same({ value = "dual", base = "right" }, final.view.label_mode)
        assert.same({ value = false, base = true }, final.view.highlight)
        assert.equals("x", final.repos["C:/b"].pins[1].id)
        assert.equals("y", final.repos["C:/a"].pins[1].id)
    end)

    it("a corrupt file is ignored with ONE warning and never raises", function()
        local p = tmpfile()
        write_raw(p, "{ not json")
        local warnings = 0
        local orig = vim.notify
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.notify = function(_, level)
            if level == vim.log.levels.WARN then warnings = warnings + 1 end
        end
        local ok, err = pcall(function()
            local opts = { mirror = true }
            persist.restore_opts(opts, {})
            assert.equals(true, opts.mirror)
            assert.same({}, (persist.restore_pins({}, "C:/r")))
            persist.read()
        end)
        vim.notify = orig
        assert.is_true(ok, err)
        assert.equals(1, warnings)
        -- A non-object JSON value is just as unusable.
        write_raw(p, "[1, 2]")
        assert.is_false(select(2, persist.read()))
        -- The next write replaces it with a valid file.
        persist.save_pref({ mirror = false }, persist.config_values({}), "mirror")
        assert.same({ value = false, base = true }, read_json(p).view.mirror)
    end)

    it("persist = false neither reads nor writes", function()
        local p = tmpfile()
        write_raw(p, vim.json.encode({ view = { mirror = { value = false, base = true } },
            repos = { ["C:/r"] = { pins = { { id = "z", reserved = true } }, unpinned = {} } } }))
        local before = read_json(p)
        local opts = { mirror = true, persist = false }
        persist.restore_opts(opts, { persist = false })
        assert.equals(true, opts.mirror)
        assert.same({}, (persist.restore_pins(opts, "C:/r")))
        persist.save_pref({ mirror = true, persist = false }, persist.config_values({}), "mirror")
        persist.save_pins(opts, "C:/r", {}, {}, {})
        persist.reset(opts, "C:/r")
        assert.same(before, read_json(p))
        -- And with no file at all, nothing is created.
        local q = tmpfile()
        persist.save_pref({ mirror = false, persist = false }, persist.config_values({}), "mirror")
        assert.is_nil(io.open(q, "rb"))
    end)

    it("reset clears the global preferences and THIS repository only (§18.5)", function()
        local p = tmpfile()
        local config = persist.config_values({})
        persist.save_pref({ mirror = false }, config, "mirror")
        persist.save_pins({}, "C:/a", { { id = "a1", reserved = true } }, {}, {})
        persist.save_pins({}, "C:/b", { { id = "b1", reserved = true } }, { dev = true }, {})
        persist.reset({}, "C:/a")
        local final = read_json(p)
        assert.is_nil(final.view)
        assert.is_nil(final.repos["C:/a"])
        assert.equals("b1", final.repos["C:/b"].pins[1].id)
        -- And the live cache agrees.
        assert.is_nil(persist.load().view)
    end)
end)
