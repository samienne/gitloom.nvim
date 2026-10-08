--- Integration test for the windowed right-pinned ref overflow (spec §6):
--- gitloom's `display_item` (which sets `line_right` + `line_right_sel`) feeding
--- the listview's `build_line` windowing, rendered into a real (stubbed) window.
--- Asserts the end-to-end behaviour that pure unit tests can't: the selected ref
--- is brought fully into view, the cursor target (`ref_byte_col`) finds it, and a
--- single over-long ref truncates cleanly instead of spilling past the window.

local gi = require("gitloom.graph")._internal

local function ref(kind, name) return { kind = kind, name = name } end

-- A right-mode commit OrderItem carrying `names` as local branches.
local function commit_item(names)
    local refs = {}
    for _, n in ipairs(names) do refs[#refs + 1] = ref("local", n) end
    local commit = { hash = "h", message = "a short message", author = "", date = nil,
        parents = {}, refs = refs }
    return { type = "commit", commit = commit, columns = {} }, commit
end

local OPTS = {
    palette = { branch = "B", remote = "R", tags = "T", head = "H", selected = "S",
        message = nil, date = "D", author = "A" },
    label_mode = "right", highlight = false, message_min = 24,
}

describe("windowed right-ref overflow (integration, §6)", function()
    local listview
    local WIN_W = 50

    before_each(function()
        package.loaded["snacks.win"] = {
            new = function(o)
                local b = vim.api.nvim_create_buf(false, true)
                local w = vim.api.nvim_open_win(b, false,
                    { relative = "editor", width = WIN_W, height = 20, row = 1, col = 1 })
                return { win = w, buf = b, opts = o or {} }
            end,
        }
        package.loaded["gitloom.listview"] = nil
        listview = require("gitloom.listview")
    end)
    after_each(function()
        package.loaded["gitloom.listview"] = nil
        package.loaded["snacks.win"] = nil
    end)

    -- Render `item` with the given selection state and return the first buffer line.
    local function render(item, sel_state, pins)
        local ctrl
        local inst = listview.open({
            win = {}, flex = 4, message_min = OPTS.message_min, overflow_hl = "R",
            line_count = function() return 1 end,
            display = function(d) return gi.display_item(OPTS, d, sel_state, nil, nil, nil, nil, pins) end,
            on_controller = function(c) ctrl = c end,
        })
        ctrl.insert({ item }, 1)
        ctrl.refresh()
        return vim.api.nvim_buf_get_lines(inst.win.buf, 0, 1, false)[1]
    end

    it("default (no selection): whole labels then a trailing +N, the overflow hidden", function()
        local item = commit_item({ "alpha", "beta", "gamma", "delta" })
        local line = render(item, { commit = nil, index = nil })
        assert.is_not_nil(line:find("(alpha)", 1, true))
        assert.is_not_nil(line:find("+1", 1, true))      -- delta overflowed
        assert.is_nil(line:find("(delta)", 1, true))    -- and is not shown
    end)

    it("selecting the overflowed ref scrolls it into view and the cursor finds it", function()
        local item, commit = commit_item({ "alpha", "beta", "gamma", "delta" })
        local line = render(item, { commit = commit, index = 4 })
        assert.is_not_nil(line:find("(delta)", 1, true))  -- now fully visible
        assert.is_not_nil(line:find("+1", 1, true))       -- alpha hidden on the left
        assert.is_nil(line:find("(alpha)", 1, true))
        -- The cursor target (place_cursor uses this) resolves to the ref.
        local texts = gi.decoration_texts(commit)
        assert.is_not_nil(gi.ref_byte_col(line, texts[4]))
    end)

    it("a single over-long selected ref truncates cleanly within the window", function()
        local long = "a-really-long-branch-name-that-cannot-fit-on-one-line-at-all"
        local item, commit = commit_item({ "alpha", "beta", "gamma", long })
        local line = render(item, { commit = commit, index = 4 })
        assert.is_true(vim.fn.strdisplaywidth(line) <= WIN_W) -- never spills past the edge
        assert.is_not_nil(line:find("…", 1, true))            -- truncated, not partial-cut
        assert.is_not_nil(line:find("+3", 1, true))           -- the others as a left marker
    end)

    -- §6: HEAD's label is FIRST, so with no selection the +N overflow never hides
    -- it — even when HEAD's branch was the ref listed last.
    it("HEAD's label stays visible when its branch would have overflowed", function()
        local item, commit = commit_item({ "alpha", "beta", "gamma", "delta" })
        commit.refs[#commit.refs + 1] = { kind = "head", name = "HEAD", branch = "delta" }
        local line = render(item, { commit = nil, index = nil })
        assert.is_not_nil(line:find("(HEAD → delta)", 1, true))
        assert.is_not_nil(line:find("%+%d"))              -- something else overflowed
        assert.is_nil(line:find("(gamma)", 1, true))      -- the last non-HEAD label
        -- h/l index 1 is that label, and the cursor target finds it.
        local sel = render(item, { commit = commit, index = 1 })
        assert.is_not_nil(gi.ref_byte_col(sel, gi.decoration_texts(commit)[1]))
    end)

    it("a detached HEAD shows a bare HEAD first, not hidden by the overflow", function()
        local item, commit = commit_item({ "alpha", "beta", "gamma", "delta" })
        commit.refs[#commit.refs + 1] = { kind = "head", name = "HEAD" }
        local line = render(item, { commit = nil, index = nil })
        local at = line:find("HEAD", 1, true)
        assert.is_not_nil(at)
        assert.is_true(at < line:find("(alpha)", 1, true))
    end)

    -- A packed marker-group row (§10.4): the labels are left-aligned after the
    -- graph (line_right_align = "left") but get the same windowed overflow.
    local function markers_item(names)
        local markers = {}
        for _, n in ipairs(names) do
            markers[#markers + 1] = { hash = n, collapsed = true, count = 1,
                refs = { ref("local", n) } }
        end
        return { type = "markers", columns = {}, markers = markers }
    end

    it("packs marker labels left-aligned with a trailing +N (no selection)", function()
        local item = markers_item({ "lauri/on_frame", "lauri/shader_weak", "IBL_zd_Test", "lauri/embed_2d" })
        local line = render(item, { commit = nil, index = nil })
        assert.is_not_nil(line:find("(lauri/on_frame)", 1, true)) -- first labels shown
        assert.is_not_nil(line:match("%+%d"))                     -- the rest overflow into +N
        assert.is_nil(line:find("(lauri/embed_2d)", 1, true))     -- last not shown
        -- Left-aligned: the first label sits before any +N marker.
        assert.is_true(line:find("(lauri/on_frame)", 1, true) < (line:find("%+%d")))
    end)

    it("windows the marker labels around the selected marker", function()
        local item = markers_item({ "lauri/on_frame", "lauri/shader_weak", "IBL_zd_Test", "lauri/embed_2d" })
        local line = render(item, { commit = item, index = 4 })
        assert.is_not_nil(line:find("(lauri/embed_2d)", 1, true)) -- selected scrolled into view
        assert.is_not_nil(line:match("%+%d"))                     -- earlier markers hidden left
        assert.is_nil(line:find("(lauri/on_frame)", 1, true))
    end)

    -- The pin icon (§6/§10.6) is part of the label text: the windowing, the
    -- selection highlight and the cursor target all see the label as drawn.
    it("draws the pin icon on pinned labels and the cursor target still finds them", function()
        local pins = { set = { delta = true, alpha = true }, icon = "⚲" }
        local item, commit = commit_item({ "alpha", "beta", "gamma", "delta" })
        local line = render(item, { commit = nil, index = nil }, pins)
        assert.is_not_nil(line:find("(⚲alpha)", 1, true))
        assert.is_nil(line:find("(⚲beta)", 1, true))
        local sel = render(item, { commit = commit, index = 4 }, pins)
        assert.is_not_nil(sel:find("(⚲delta)", 1, true)) -- selected, windowed into view
        local texts = gi.decoration_texts(commit, nil, pins)
        assert.equals("(⚲delta)", texts[4])
        assert.is_not_nil(gi.ref_byte_col(sel, texts[4]))
    end)

    it("never puts the pin icon on HEAD's label", function()
        local pins = { set = { main = true }, icon = "⚲" }
        local item, commit = commit_item({ "main" })
        commit.refs[#commit.refs + 1] = { kind = "head", name = "HEAD", branch = "main" }
        local line = render(item, { commit = nil, index = nil }, pins)
        assert.is_not_nil(line:find("(HEAD → main)", 1, true))
        assert.is_nil(line:find("⚲", 1, true))
    end)
end)
