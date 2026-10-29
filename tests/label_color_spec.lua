--- Ref labels and their colours (spec §6 "Label colour", §5.5 "Muting", §12.2):
--- every ranked ref's label takes ITS OWN ref's colour (`row.ref_colors`) at its
--- brightness level (`row.ref_levels`: 1 full, 2 slightly muted — `remote_mute` —
--- 3 muted — `collapsed_mute`); a branch group splits by member (name = the local,
--- each `↑remote` at its own level); a collapsed `◍` head's and a packed marker's
--- labels are coloured the same way; a tag takes its node's colour as drawn;
--- worktree labels are per-kind. HEAD's marker keeps `palette.head`, the
--- h/l-selected label `palette.selected`, and `lane_label_colors = false` restores
--- the per-kind groups everywhere (tags included). Out of the cone labels dim with
--- their row; a level-2 colour then blends by `remote_mute_out` (brighter than every
--- other dim), a level-3 one blends by `collapsed_mute_out`. The remote-only
--- marker (`icons.remote`, §6) is covered at the end. Driven through the real
--- `display_item` on hand-built rows and on a real `columns.layout` (the
--- lumeeditor shape), plus the pane pieces (`pane_labels`, `ref_label_hl`).

local render = require("gitloom.graph.render")
local rank = require("gitloom.graph.rank")
local helpers = require("tests.graph_helpers")

local function opts(extra)
    local o = helpers.big_opts() -- tracks C0..C63; slot n -> "C" .. (n - 1)
    o.palette.head = "HeadHl"
    o.palette.selected = "SelHl"
    o.palette.branch = "BranchHl"
    o.palette.remote = "RemoteHl"
    o.palette.tags = "TagHl"
    o.palette.worktree = "WtHl"
    o.icons = {}
    for k, v in pairs(extra or {}) do o[k] = v end
    return o
end

local function commit(t)
    t.parents = t.parents or { {} }
    t.children = t.children or { {} }
    t.refs = t.refs or {}
    t.message = t.message or "msg"
    return t
end

-- A straight node cell in palette slot `slot`.
local function node_cell(c, slot, extra)
    local cell = {
        connectivity = { up = true, down = true },
        lanes = { { connectivity = { up = true, down = true }, id = slot, color = slot, edges = {} } },
        has_commit = true,
        commit = c,
    }
    for k, v in pairs(extra or {}) do cell[k] = v end
    return cell
end

-- `extra`: more row fields (`ref_levels`, `selected_color`, `selected_level`).
local function row(c, cells, colors, extra)
    local r = { type = "commit", commit = c, columns = cells, ref_colors = colors }
    for k, v in pairs(extra or {}) do r[k] = v end
    return r
end

-- `display_item` with no ref selection (and an optional cone).
local function draw(o, item, sel, cone)
    return render.display_item(o, item, sel or {}, cone)
end

-- Every highlight run of a rendered piece as { text, hl } in order.
local function runs(piece)
    local out = {}
    for _, h in ipairs(piece.highlight or {}) do
        out[#out + 1] = { piece.text:sub(h.start_pos + 1, h.end_pos), h.hl }
    end
    return out
end

-- The distinct highlight groups of a rendered piece.
local function groups(piece)
    local set, out = {}, {}
    for _, r in ipairs(runs(piece)) do
        if not set[r[2]] then set[r[2]] = true; out[#out + 1] = r[2] end
    end
    return out
end

-- The node glyph's highlight on a row (what the label must match).
local function node_glyph_hl(o, cells, emphasis)
    local res = render.get_column_chars(o, cells, emphasis)
    return res.highlight[1].hl
end

local LOCAL = { kind = "local", name = "feat" }
local REMOTE = { kind = "remote", name = "origin/feat" }
local TAG = { kind = "tag", name = "v1" }

local ODEV = { kind = "remote", name = "origin/dev" }
local DEV = { kind = "local", name = "dev" }
local OVAL = { kind = "remote", name = "origin/leppanen/validation" }

describe("ref labels take their own ref's colour (§6 'Label colour')", function()
    it("a branch group: name in the local's colour, `↑remote` slightly muted; the tag in its node's", function()
        local o = opts()
        local c = commit({ refs = { LOCAL, REMOTE, TAG } })
        local el = draw(o, row(c, { node_cell(c, 3) }, { feat = 3, ["origin/feat"] = 3 },
            { ref_levels = { feat = 1, ["origin/feat"] = 2 }, selected_color = 3, selected_level = 1 }))
        assert.equals(2, #el.line_right)
        assert.same({
            { "(", "C2" }, { "feat", "C2" }, { " ↑origin", render.slot_hl(o, -3) }, { ")", "C2" },
        }, runs(el.line_right[1]))
        assert.same({ "C2" }, groups(el.line_right[2]))
    end)

    it("a tag takes its node's colour AS DRAWN: at the selected ref's level", function()
        local o = opts()
        local c = commit({ refs = { TAG } })
        -- the node's selected ref is a slightly muted remote (slot 4, level 2)
        local el = draw(o, row(c, { node_cell(c, -4) }, {}, { selected_color = 4, selected_level = 2 }))
        assert.same({ render.slot_hl(o, -4) }, groups(el.line_right[1]))
        -- … and a collapsed, unpinned one (level 3)
        el = draw(o, row(c, { node_cell(c, 4) }, {}, { selected_color = 4, selected_level = 3 }))
        assert.same({ render.slot_hl(o, rank.drawn(4, 3)) }, groups(el.line_right[1]))
        -- no node colour known: per-kind
        el = draw(o, row(c, { node_cell(c, 4) }, {}))
        assert.same({ "TagHl" }, groups(el.line_right[1]))
    end)

    it("a label keeps its own colour on another ref's track (no lane owner)", function()
        local o = opts()
        local c = commit({ refs = { LOCAL } })
        -- the node sits on a track carrying slot 5; feat's own colour is slot 3
        local el = draw(o, row(c, { node_cell(c, 5) }, { feat = 3 }))
        assert.equals("C4", node_glyph_hl(o, { node_cell(c, 5) }))
        assert.same({ "C2" }, groups(el.line_right[1]))
    end)

    it("a group of remotes only: bracket and name in the first remote's muted colour, each `↑` its own", function()
        local o = opts()
        local c = commit({ refs = { { kind = "remote", name = "origin/x" }, { kind = "remote", name = "fork/x" } } })
        local el = draw(o, row(c, { node_cell(c, 1) }, { ["origin/x"] = 4, ["fork/x"] = 4 }))
        local m = render.slot_hl(o, -4)
        assert.same({ { "(", m }, { "x", m }, { " ↑origin", m }, { ",fork", m }, { ")", m } },
            runs(el.line_right[1]))
    end)

    it("a ref without a colour on its row (not a visible ranked ref) is per-kind", function()
        local o = opts()
        local c = commit({ refs = { LOCAL, REMOTE } })
        local el = draw(o, row(c, { node_cell(c, 3) }, {}))
        assert.same({ { "(", "BranchHl" }, { "feat", "BranchHl" }, { " ↑origin", "RemoteHl" }, { ")", "BranchHl" } },
            runs(el.line_right[1]))
    end)

    it("a collapsed ◍ head's labels take their identity colour at their level", function()
        local o = opts()
        local c = commit({ refs = { LOCAL, REMOTE, TAG }, collapsed = true, count = 4 })
        local muted = render.slot_hl(o, rank.drawn(9, 3))
        local el = draw(o, row(c, { node_cell(c, rank.drawn(9, 3)) }, { feat = 9, ["origin/feat"] = 9 },
            { ref_levels = { feat = 3, ["origin/feat"] = 3 }, selected_color = 9, selected_level = 3 }))
        local r = runs(el.line[4])
        -- level 3 replaces remote_mute: the local and its remote are drawn alike
        assert.same({ { "(", muted }, { "feat", muted }, { " ↑origin", muted }, { ")", muted } },
            { r[1], r[2], r[3], r[4] })
        assert.same({ "[v1]", muted }, r[5]) -- the tag in its node's colour
        assert.is_true(muted ~= "BranchHl") -- not per-kind (distinct from C8 under truecolor, below)
        -- a PINNED collapsed ref stays at level 1
        el = draw(o, row(c, { node_cell(c, 9) }, { feat = 9 }, { ref_levels = { feat = 1 } }))
        assert.same({ "(", "C8" }, runs(el.line[4])[1])
    end)

    it("a packed marker row: labels in identity colour, a tag in its marker's node colour", function()
        local o = opts()
        local m1 = commit({ refs = { { kind = "local", name = "a" }, TAG }, collapsed = true, count = 1 })
        local m2 = commit({ refs = {}, collapsed = true, count = 2 })
        local item = { type = "markers", markers = { m1, m2 }, columns = { node_cell(m1, 2), node_cell(m2, 4) },
            ref_colors = { a = 2 }, ref_levels = { a = 3 },
            marker_items = {
                { type = "commit", commit = m1, selected_color = 5, selected_level = 1 },
                { type = "commit", commit = m2, selected_color = 4, selected_level = 3 },
            } }
        local el = draw(o, item)
        local a = render.slot_hl(o, rank.drawn(2, 3))
        assert.same({ { "(", a }, { "a", a }, { ")", a }, { "[v1]", "C4" } }, runs(el.line_right[1]))
        assert.equals("(a) [v1]", el.line_right[1].text)
        assert.same({ "C3" }, groups(el.line_right[2]))
        -- lane_label_colors off: per-kind again
        local plain = draw(opts({ lane_label_colors = false }), item)
        assert.same({ "BranchHl", "TagHl" }, groups(plain.line_right[1]))
    end)

    -- The reported lumeeditor shape, through a REAL layout: `dev` pinned at X, its
    -- remote `origin/dev` one commit ahead at Y together with a remote-only branch
    -- listed FIRST, and an unlabelled commit Z above Y. Y's track carries origin/dev
    -- (muted dev); `(dev)` at Y is muted dev, and the remote-only
    -- `(leppanen/validation ↑origin)` sitting inside dev's track takes ITS OWN muted
    -- colour — never dev's (the original bug).
    describe("the lumeeditor shape through columns.layout", function()
        local columns = require("gitloom.graph.columns")
        local function laid_out(policy)
            local items = helpers.dag({
                { "Z", { "Y" } }, { "Y", { "X" } }, { "X", { "W" } }, { "W", {} },
            })
            local by = {}
            for _, it in ipairs(items) do by[it.commit.hash] = it.commit end
            by.Y.refs = { OVAL, ODEV }
            by.X.refs = { DEV }
            local o = helpers.ranked(opts({ layout_policy = policy }), items, { pins = { "dev" } })
            local rows = columns.layout(o, items)
            local out = {}
            for _, r in ipairs(rows) do out[r.commit.hash] = r end
            return o, out
        end
        for _, policy in ipairs({ "compact", "gutter" }) do
            it("origin/dev and its node are muted dev; the remote-only label keeps its own colour [" .. policy .. "]",
                function()
                    local o, rows = laid_out(policy)
                    local muted_dev = render.slot_hl(o, -1)
                    assert.equals(muted_dev, render.node_lane_hl(o, rows.Y.columns))
                    local k = rows.Y.ref_colors["origin/leppanen/validation"]
                    assert.is_not_nil(k)
                    assert.is_true(k ~= 1, "a remote-only identity has its own colour")
                    local y = draw(o, rows.Y)
                    assert.same({ render.slot_hl(o, -k) }, groups(y.line_right[1]))
                    assert.same({ muted_dev }, groups(y.line_right[2]))
                    local x = draw(o, rows.X)
                    assert.same({ "C0" }, groups(x.line_right[1]))
                    assert.equals("C0", render.node_lane_hl(o, rows.X.columns))
                end)
        end
    end)

    describe("HEAD and selection keep their own highlight", function()
        it("the attached label: `HEAD → ` in palette.head, the rest in its ref's colour", function()
            local o = opts()
            local c = commit({ refs = { { kind = "head", name = "HEAD", branch = "feat" }, LOCAL } })
            local el = draw(o, row(c, { node_cell(c, 3) }, { feat = 3 }))
            assert.same({
                { "(", "C2" }, { "HEAD → ", "HeadHl" }, { "feat", "C2" }, { ")", "C2" },
            }, runs(el.line_right[1]))
        end)

        it("a detached HEAD's bare label stays palette.head", function()
            local o = opts()
            local c = commit({ refs = { { kind = "head", name = "HEAD" }, LOCAL } })
            local el = draw(o, row(c, { node_cell(c, 3) }, { feat = 3 }))
            assert.same({ { "HEAD", "HeadHl" } }, runs(el.line_right[1]))
            assert.same({ "C2" }, groups(el.line_right[2]))
        end)

        it("the h/l-selected label draws palette.selected over its colour", function()
            local o = opts()
            local c = commit({ refs = { LOCAL, TAG } })
            local el = draw(o, row(c, { node_cell(c, 3) }, { feat = 3 }), { commit = c, index = 2 })
            assert.same({ "C2" }, groups(el.line_right[1]))
            assert.same({ "SelHl" }, groups(el.line_right[2]))
        end)

        it("a ref's own colour (a submodule pointer mark) is kept", function()
            local o = opts()
            local c = commit({ refs = { { kind = "tag", name = "new", hl = "MarkHl" } } })
            local el = draw(o, row(c, { node_cell(c, 3) }))
            assert.same({ "MarkHl" }, groups(el.line_right[1]))
        end)
    end)

    it("lane_label_colors = false gives every label its per-kind colour; tracks stay coloured", function()
        local o = opts({ lane_label_colors = false })
        local c = commit({ refs = { { kind = "head", name = "HEAD", branch = "feat" }, LOCAL, REMOTE, TAG } })
        local cells = { node_cell(c, 3) }
        local el = draw(o, row(c, cells, { feat = 3, ["origin/feat"] = 3 }, { selected_color = 3, selected_level = 1 }))
        assert.same({ "HeadHl", "RemoteHl" }, groups(el.line_right[1]))
        assert.same({ "TagHl" }, groups(el.line_right[2])) -- a tag too: not its node's colour
        local plain = commit({ refs = { LOCAL } })
        assert.equals("C2", node_glyph_hl(o, { node_cell(plain, 3) }))
        assert.equals("BranchHl", render.ref_label_hl(o, { feat = 3 }, "feat", false, "BranchHl"))
    end)

    describe("context panes (§6.2)", function()
        it("pane_labels marks the `HEAD → ` span of the current branch's label", function()
            local c = commit({ refs = { { kind = "head", name = "HEAD", branch = "feat" }, LOCAL } })
            local segs = render.pane_labels(c, "feat")
            assert.equals("head", segs[1].kind)
            local a = assert(segs[1].arrow)
            assert.equals("HEAD → ", segs[1].text:sub(a[1], a[2]))
            -- a detached HEAD's bare label and an ordinary branch carry no span
            local d = render.pane_labels(commit({ refs = { { kind = "head", name = "HEAD" }, LOCAL } }), nil)
            assert.equals("HEAD", d[1].text)
            assert.is_nil(d[1].arrow)
            assert.is_nil(d[2].arrow)
        end)

        it("pane_labels carries each group's colouring members and `↑remote` spans", function()
            local c = commit({ refs = { OVAL, DEV, ODEV, { kind = "remote", name = "fork/dev" }, TAG } })
            local segs = render.pane_labels(c, nil)
            assert.equals("origin/leppanen/validation", segs[1].ref)
            assert.is_true(segs[1].remote)
            assert.equals("dev", segs[2].ref)
            assert.is_false(segs[2].remote)
            local rs = assert(segs[2].rspans)
            assert.equals(2, #rs)
            assert.equals(" ↑origin", segs[2].text:sub(rs[1].span[1], rs[1].span[2]))
            assert.equals("origin/dev", rs[1].ref)
            assert.equals(",fork", segs[2].text:sub(rs[2].span[1], rs[2].span[2]))
            assert.equals("fork/dev", rs[2].ref)
            assert.is_nil(segs[3].ref) -- a tag: per-kind
            local o = opts()
            local colors = { dev = 2, ["origin/dev"] = 2 }
            assert.equals("C1", render.ref_label_hl(o, colors, segs[2].ref, segs[2].remote, "BranchHl"))
            assert.equals(render.slot_hl(o, -2), render.ref_label_hl(o, colors, rs[1].ref, true, "RemoteHl"))
            assert.equals("RemoteHl", render.ref_label_hl(o, colors, rs[2].ref, true, "RemoteHl"))
        end)
    end)
end)

describe("muted remotes (§5.5, §12.2)", function()
    local saved
    before_each(function()
        saved = vim.o.termguicolors
        vim.o.termguicolors = true
        vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff, bg = 0x000000 })
        vim.api.nvim_set_hl(0, "C0", { fg = 0xc86400 })
        render.reset_dim_cache()
    end)
    after_each(function()
        vim.o.termguicolors = saved
        render.reset_dim_cache()
    end)

    local function o(pal)
        local x = opts()
        for k, v in pairs(pal or {}) do x.palette[k] = v end
        return x
    end
    local function fg(group)
        return vim.api.nvim_get_hl(0, { name = group, link = false }).fg
    end

    it("slot -k is the light blend of slot k (default 0.25), cached, flat without truecolor", function()
        local g = render.slot_hl(o(), -1)
        assert.is_true(g ~= "C0")
        assert.equals(render.mute_hl(o(), "C0"), g)
        -- 0xc8 * 0.75 = 150, 0x64 * 0.75 = 75
        assert.equals(150 * 65536 + 75 * 256, fg(g))
        assert.equals(g, render.slot_hl(o(), -1)) -- cached
        vim.o.termguicolors = false
        assert.equals("C0", render.slot_hl(o(), -1))
    end)

    it("remote_mute sets the factor; counterpart_dim is its alias, the new name winning", function()
        assert.equals(100 * 65536 + 50 * 256, fg(render.slot_hl(o({ remote_mute = 0.5 }), -1)))
        assert.equals(100 * 65536 + 50 * 256, fg(render.slot_hl(o({ counterpart_dim = 0.5 }), -1)))
        assert.equals(100 * 65536 + 50 * 256,
            fg(render.slot_hl(o({ remote_mute = 0.5, counterpart_dim = 0.1 }), -1)))
    end)

    -- Out of the cone a remote is NOT composed (mute then dim) but blended from its
    -- slot colour by `remote_mute_out` (default 0.75 * dim), so it reads brighter than
    -- every other dimmed colour, its own local's included.
    it("out of the cone a remote is brighter than every dimmed colour (0.75 * dim)", function()
        local mg = render.slot_hl(o(), -1)
        local d = render.dim_hl(o(), mg)
        -- factor 0.3375: 200 * 0.6625 = 132.5 -> 133; 100 * 0.6625 = 66.25 -> 66
        assert.equals(133 * 65536 + 66 * 256, fg(d))
        -- the local dimmed: 200 * 0.55 = 110, 100 * 0.55 = 55
        local pd = fg(render.dim_hl(o(), "C0"))
        assert.equals(110 * 65536 + 55 * 256, pd)
        local function ch(c) return math.floor(c / 65536) % 256, math.floor(c / 256) % 256 end
        local r1, g1 = ch(fg(d))
        local r2, g2 = ch(pd)
        assert.is_true(r1 > r2 and g1 > g2, "brighter than the dimmed local")
        assert.is_true(r1 < 160 and g1 < 80, "still dimmer than the in-cone muted colour")
        -- the out-of-cone factor follows `dim`, is configurable, and has its alias
        assert.equals(140 * 65536 + 70 * 256, fg(render.dim_hl(o({ remote_mute_out = 0.3 }), mg)))
        assert.equals(140 * 65536 + 70 * 256, fg(render.dim_hl(o({ counterpart_dim_out = 0.3 }), mg)))
        assert.equals(110 * 65536 + 55 * 256, fg(render.dim_hl(o({ dim = 0.6 }), mg)))
    end)

    it("a remote's label and node: muted in the cone, the brighter dim out of it", function()
        local c = commit({ refs = { { kind = "remote", name = "origin/x" } } })
        local cells = { {
            connectivity = { up = true, down = true },
            lanes = { { connectivity = { up = true, down = true }, id = 1, color = -1, edges = {} } },
            has_commit = true, commit = c,
        } }
        local x = o()
        local item = row(c, cells, { ["origin/x"] = 1 })
        local want = render.slot_hl(x, -1)
        assert.equals(want, render.get_column_chars(x, cells).highlight[1].hl)
        assert.same({ want }, groups(draw(x, item, nil, nil).line_right[1]))
        -- a cone that does not hold this commit: the row and its label are dimmed
        local out = render.dim_hl(x, want)
        assert.same({ out }, groups(draw(x, item, nil, {}).line_right[1]))
        assert.equals(133 * 65536 + 66 * 256, fg(out))
    end)

    it("a local's label out of the cone takes the plain dim of its colour", function()
        local x = o()
        local c = commit({ refs = { LOCAL } })
        local el = draw(x, row(c, { node_cell(c, 1, { active = false }) }, { feat = 1 }), nil, {})
        local dim = render.dim_hl(x, "C0")
        assert.is_true(dim ~= render.DIM_FALLBACK)
        assert.same({ dim }, groups(el.line_right[1]))
        -- in the cone / no pivot: undimmed
        local item = row(c, { node_cell(c, 1) }, { feat = 1 })
        assert.same({ "C0" }, groups(draw(x, item, nil, { [c] = true }).line_right[1]))
        assert.same({ "C0" }, groups(draw(x, item, nil, nil).line_right[1]))
    end)
end)

describe("three brightness levels (§5.5 'Muting', §12.2)", function()
    local saved
    before_each(function()
        saved = vim.o.termguicolors
        vim.o.termguicolors = true
        vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff, bg = 0x000000 })
        vim.api.nvim_set_hl(0, "C0", { fg = 0xc86400 })
        render.reset_dim_cache()
    end)
    after_each(function()
        vim.o.termguicolors = saved
        render.reset_dim_cache()
    end)

    local function o(pal)
        local x = opts()
        for k, v in pairs(pal or {}) do x.palette[k] = v end
        return x
    end
    local function fg(group)
        return vim.api.nvim_get_hl(0, { name = group, link = false }).fg
    end
    local function rg(c) return math.floor(c / 65536) % 256, math.floor(c / 256) % 256 end

    it("levels 1, 2 and 3 draw distinct groups: full, remote_mute 0.25, collapsed_mute 0.45", function()
        local x = o()
        local l1 = render.slot_hl(x, rank.drawn(1, 1))
        local l2 = render.slot_hl(x, rank.drawn(1, 2))
        local l3 = render.slot_hl(x, rank.drawn(1, 3))
        assert.equals("C0", l1)
        assert.is_true(l1 ~= l2 and l2 ~= l3 and l1 ~= l3)
        assert.equals(200 * 65536 + 100 * 256, fg(l1))
        assert.equals(150 * 65536 + 75 * 256, fg(l2)) -- 0.25
        assert.equals(110 * 65536 + 55 * 256, fg(l3)) -- 0.45
        -- a generated ref (rank level 4) is drawn at full strength
        assert.equals(l1, render.slot_hl(x, rank.drawn(1, rank.drawn_level(rank.generated(1)))))
    end)

    it("collapsed_mute replaces remote_mute, is configurable, 0 turns it off, junk falls back", function()
        assert.equals(150 * 65536 + 75 * 256, fg(render.slot_hl(o({ collapsed_mute = 0.25 }), rank.drawn(1, 3))))
        -- remote_mute never composes into level 3
        assert.equals(110 * 65536 + 55 * 256, fg(render.slot_hl(o({ remote_mute = 0.9 }), rank.drawn(1, 3))))
        -- 0: the level's muting is off (drawn at full strength)
        assert.equals(200 * 65536 + 100 * 256, fg(render.slot_hl(o({ collapsed_mute = 0 }), rank.drawn(1, 3))))
        assert.equals(200 * 65536 + 100 * 256, fg(render.slot_hl(o({ remote_mute = 0 }), rank.drawn(1, 2))))
        -- invalid values (out of 0..1, not a number) read as unset: the default
        assert.equals(110 * 65536 + 55 * 256, fg(render.slot_hl(o({ collapsed_mute = 2 }), rank.drawn(1, 3))))
        assert.equals(110 * 65536 + 55 * 256, fg(render.slot_hl(o({ collapsed_mute = "x" }), rank.drawn(1, 3))))
        assert.equals(150 * 65536 + 75 * 256, fg(render.slot_hl(o({ remote_mute = -1 }), rank.drawn(1, 2))))
        -- without truecolor every level is the plain colour
        vim.o.termguicolors = false
        assert.equals("C0", render.slot_hl(o(), rank.drawn(1, 3)))
        assert.equals("C0", render.slot_hl(o(), rank.drawn(1, 2)))
    end)

    it("out of the cone level 3 blends by collapsed_mute_out (default 0.45), without stacking", function()

        local x = o()

        local l3 = render.slot_hl(x, rank.drawn(1, 3))

        -- default 0.45: 200 * 0.55 = 110, 100 * 0.55 = 55, the level-1 dim at the default dim

        local r3, g3 = rg(fg(render.dim_hl(x, l3)))

        assert.is_true(math.abs(r3 - 110) <= 1 and math.abs(g3 - 55) <= 1)

        -- the same level as a level-1 colour out of the cone (master's dim)

        assert.equals(fg(render.dim_hl(x, render.slot_hl(x, rank.drawn(1, 1)))), fg(render.dim_hl(x, l3)))

        -- it does not follow dim

        local x3 = o({ dim = 0.7 })

        local r, g = rg(fg(render.dim_hl(x3, render.slot_hl(x3, rank.drawn(1, 3)))))

        assert.is_true(math.abs(r - 110) <= 1 and math.abs(g - 55) <= 1)

    end)



    it("collapsed_mute_out is configurable", function()

        local x = o({ collapsed_mute_out = 0.8 })

        local r, g = rg(fg(render.dim_hl(x, render.slot_hl(x, rank.drawn(1, 3)))))

        assert.is_true(math.abs(r - 40) <= 1 and math.abs(g - 20) <= 1)

    end)



    it("an invalid collapsed_mute_out falls back to the default", function()

        for _, bad in ipairs({ 2, -1, "x" }) do

            local x = o({ collapsed_mute_out = bad })

            local r, g = rg(fg(render.dim_hl(x, render.slot_hl(x, rank.drawn(1, 3)))))

            assert.is_true(math.abs(r - 110) <= 1 and math.abs(g - 55) <= 1)

        end

    end)



    it("a collapsed ◍ head's label dims with its row by the composed blend", function()
        local x = o()
        local c = commit({ refs = { LOCAL }, collapsed = true, count = 2 })
        local item = row(c, { node_cell(c, rank.drawn(1, 3)) }, { feat = 1 }, { ref_levels = { feat = 3 } })
        local l3 = render.slot_hl(x, rank.drawn(1, 3))
        assert.same({ "(", l3 }, runs(draw(x, item, nil, nil).line[4])[1])
        assert.same({ "(", render.dim_hl(x, l3) }, runs(draw(x, item, nil, {}).line[4])[1])
    end)

    -- §12.2: while the reachability highlight is active, levels 2 and 3 IN the cone
    -- blend by `highlight_mute` (default 0.1: 200 * 0.9 = 180, 100 * 0.9 = 90).
    it("in the cone with the highlight on, levels 2 and 3 use the highlight_mute 0.1 blend", function()
        local x = o()
        for _, level in ipairs({ 2, 3 }) do
            local lit = render.lit_hl(x, render.slot_hl(x, rank.drawn(1, level)))
            assert.equals(180 * 65536 + 90 * 256, fg(lit))
        end
        -- level 1 and plain groups pass through unchanged
        assert.equals("C0", render.lit_hl(x, render.slot_hl(x, rank.drawn(1, 1))))
        assert.equals("Comment", render.lit_hl(x, "Comment"))
        -- out of the cone is unchanged: the dim of a lit group's source still applies
        local l3 = render.slot_hl(x, rank.drawn(1, 3))
        local r, g = rg(fg(render.dim_hl(x, l3)))
        assert.is_true(math.abs(r - 110) <= 1 and math.abs(g - 55) <= 1)
    end)

    it("a ◍ head's node and label: highlight_mute in the cone, 0.45 with the highlight off, dim out", function()
        local x = o()
        local c = commit({ refs = { LOCAL }, collapsed = true, count = 2 })
        local item = row(c, { node_cell(c, rank.drawn(1, 3)) }, { feat = 1 }, { ref_levels = { feat = 3 } })
        local l3 = render.slot_hl(x, rank.drawn(1, 3))
        local hm = render.lit_hl(x, l3)
        assert.is_true(hm ~= l3)
        -- highlight on, in the cone
        local inc = draw(x, item, nil, { [c] = true })
        assert.same({ "(", hm }, runs(inc.line[4])[1])
        assert.equals(hm, runs(inc.line[3])[1][2])
        -- highlight off (no pivot, or the toggle off): the plain 0.45 level
        assert.same({ "(", l3 }, runs(draw(x, item, nil, nil).line[4])[1])
        local off = o({}); off.highlight = false
        local offd = draw(off, item, nil, { [c] = true })
        assert.same({ "(", l3 }, runs(offd.line[4])[1])
        assert.equals(l3, runs(offd.line[3])[1][2])
        assert.equals(110 * 65536 + 55 * 256, fg(l3))
        -- out of the cone: unchanged
        -- (the node glyph follows track.active, which mark_reachable sets)
        local oitem = row(c, { node_cell(c, rank.drawn(1, 3), { active = false }) }, { feat = 1 },
            { ref_levels = { feat = 3 } })
        local out = draw(x, oitem, nil, {})
        assert.same({ "(", render.dim_hl(x, l3) }, runs(out.line[4])[1])
        assert.equals(render.dim_hl(x, l3), runs(out.line[3])[1][2])
    end)

    it("a level-2 remote with the highlight off keeps remote_mute 0.25", function()
        local x = o()
        local l2 = render.slot_hl(x, rank.drawn(1, 2))
        assert.equals(150 * 65536 + 75 * 256, fg(l2))
        assert.equals(180 * 65536 + 90 * 256, fg(render.lit_hl(x, l2)))
    end)

    it("highlight_mute is configurable (0 = full) and invalid values fall back to 0.1", function()
        local x = o({ highlight_mute = 0.5 })
        assert.equals(100 * 65536 + 50 * 256, fg(render.lit_hl(x, render.slot_hl(x, rank.drawn(1, 2)))))
        local z = o({ highlight_mute = 0 })
        assert.equals(200 * 65536 + 100 * 256, fg(render.lit_hl(z, render.slot_hl(z, rank.drawn(1, 3)))))
        for _, bad in ipairs({ 2, -1, "x" }) do
            local b = o({ highlight_mute = bad })
            assert.equals(180 * 65536 + 90 * 256, fg(render.lit_hl(b, render.slot_hl(b, rank.drawn(1, 3)))))
        end
    end)
end)

describe("remote-only marker (§6 icons.remote)", function()
    local REFS = {
        { name = "dev", kind = "local" },
        { name = "origin/dev", kind = "remote" },
        { name = "origin/foo", kind = "remote" },
        { name = "fork/foo", kind = "remote" },
        { name = "feat", kind = "local", upstream = { short = "origin/renamed" } },
        { name = "origin/renamed", kind = "remote" },
    }
    local function remote_only()
        return rank.input(REFS, { remotes = { "origin", "fork" } }).remote_only
    end
    local function marks(extra)
        local m = { set = {}, expanded = {}, remote_only = remote_only() }
        for k, v in pairs(extra or {}) do m[k] = v end
        return m
    end
    local FOO = { { kind = "remote", name = "origin/foo" }, { kind = "remote", name = "fork/foo" } }

    it("the ranking input lists exactly the members of remote-only identities", function()
        assert.same({ ["origin/foo"] = true, ["fork/foo"] = true }, remote_only())
    end)

    it("a remote-only group carries ⇣ before its name; a paired remote or a local group never", function()
        local m = marks()
        assert.equals("(⇣foo ↑origin,fork)", render.decoration_texts(commit({ refs = FOO }), nil, m)[1])
        -- origin/dev ahead of dev: its identity has a local — no marker
        assert.equals("(dev ↑origin)",
            render.decoration_texts(commit({ refs = { { kind = "remote", name = "origin/dev" } } }), nil, m)[1])
        -- a remote claimed only through upstream configuration is not remote-only
        assert.equals("(renamed ↑origin)",
            render.decoration_texts(commit({ refs = { { kind = "remote", name = "origin/renamed" } } }), nil, m)[1])
        -- a group with its local branch
        assert.equals("(dev ↑origin)", render.decoration_texts(commit({ refs = { DEV, ODEV } }), nil, m)[1])
    end)

    it("orders pin, expanded, remote, then the name; \"\" turns it off", function()
        local m = marks({ set = { ["origin/foo"] = true }, expanded = { ["origin/foo"] = true } })
        assert.equals("(⚲▾⇣foo ↑origin,fork)", render.decoration_texts(commit({ refs = FOO }), nil, m)[1])
        m.remote_icon = ""
        assert.equals("(⚲▾foo ↑origin,fork)", render.decoration_texts(commit({ refs = FOO }), nil, m)[1])
        m.remote_icon = "R"
        assert.equals("(⚲▾Rfoo ↑origin,fork)", render.decoration_texts(commit({ refs = FOO }), nil, m)[1])
    end)

    it("is drawn in the label's own colour in the graph", function()
        local o = opts()
        local c = commit({ refs = FOO })
        local item = row(c, { node_cell(c, 4) }, { ["origin/foo"] = 4, ["fork/foo"] = 4 },
            { ref_levels = { ["origin/foo"] = 2, ["fork/foo"] = 2 } })
        local el = render.display_item(o, item, {}, nil, nil, nil, nil, marks())
        local m = render.slot_hl(o, -4)
        assert.same({ { "(", m }, { "⇣foo", m }, { " ↑origin", m }, { ",fork", m }, { ")", m } },
            runs(el.line_right[1]))
    end)

    it("appears in a pane label, after the pin and expanded icons, with the ↑remote spans shifted", function()
        local m = marks({ set = { ["origin/foo"] = true }, expanded = { ["origin/foo"] = true } })
        local segs = render.pane_labels(commit({ refs = FOO }), nil, m)
        assert.equals("(⚲▾⇣foo ↑origin,fork)", segs[1].text)
        local rs = assert(segs[1].rspans)
        assert.equals(" ↑origin", segs[1].text:sub(rs[1].span[1], rs[1].span[2]))
        assert.equals(",fork", segs[1].text:sub(rs[2].span[1], rs[2].span[2]))
        -- a paired remote in a pane: no marker
        local d = render.pane_labels(commit({ refs = { { kind = "remote", name = "origin/dev" } } }), nil, m)
        assert.equals("(dev ↑origin)", d[1].text)
    end)

    it("appears on packed marker units", function()
        local m1 = commit({ refs = FOO, collapsed = true, count = 1 })
        local units = render.marker_units({ type = "markers", markers = { m1 }, columns = {} }, marks())
        assert.equals("(⇣foo ↑origin,fork)", units[1].text)
    end)
end)
