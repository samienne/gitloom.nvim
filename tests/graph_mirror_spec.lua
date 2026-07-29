--- Tests for graph mirroring (specification.md §5.4).
---
--- Mirroring is a render-only transform: the cell sequence of each row is
--- reversed and each cell's left/right connectivity swapped, so lane 1 lands at
--- the right edge. Two things must hold:
---   1. the mirrored glyph grid is still a well-formed, connected, color-
---      continuous picture — i.e. the full invariant suite passes on it; and
---   2. it is the *actual* horizontal mirror of the normal render (a valid but
---      different graph would pass (1) yet be wrong), checked by flipping the
---      normal grid (reverse each row + swap asymmetric glyphs) and comparing.

local h = require("tests.graph_helpers")
local graph = require("gitloom.graph")

local STYLES = {
    { name = "split-line",        ms = { split_on_separate_line = true,  merge_on_separate_line = false } },
    { name = "merge-line",        ms = { split_on_separate_line = false, merge_on_separate_line = true } },
    { name = "both-lines",        ms = { split_on_separate_line = true,  merge_on_separate_line = true } },
    { name = "inline",            ms = { split_on_separate_line = false, merge_on_separate_line = false } },
    { name = "inline+mergesplit", experimental = true, ms = { split_on_separate_line = false, merge_on_separate_line = false, allow_merge_on_split = true } },
}

local FIXTURES = {
    { name = "linear",   rows = { { "c1", { "c2" } }, { "c2", { "c3" } }, { "c3", {} } } },
    {
        name = "diamond",
        rows = { { "c1", { "c2", "c3" } }, { "c2", { "c4" } }, { "c3", { "c4" } }, { "c4", {} } },
    },
    {
        name = "octopus",
        rows = {
            { "c1", { "c2", "c3", "c4" } },
            { "c2", { "c5" } }, { "c3", { "c5" } }, { "c4", { "c5" } }, { "c5", {} },
        },
    },
    {
        name = "interleaved",
        rows = {
            { "c1", { "c3" } }, { "c2", { "c4" } }, { "c3", { "c5" } }, { "c4", { "c5" } },
            { "c5", { "c6", "c7" } }, { "c6", { "c8" } }, { "c7", { "c8" } }, { "c8", {} },
        },
    },
}

local function mirror_opts(ms)
    local o = h.big_opts(ms)
    o.mirror = true
    return o
end

--------------------------------------------------------------------------------
-- (1) Invariants hold on the mirrored output
--------------------------------------------------------------------------------

local function assert_ok(opts, items, label, skip_color)
    local errors, _, grid = h.check(opts, items, skip_color)
    if #errors > 0 then
        assert(false, ("\n%s (mirrored)\n--- graph ---\n%s\n--- errors ---\n%s"):format(
            label or "", h.grid_to_string(grid), table.concat(errors, "\n")))
    end
end

for _, style in ipairs(STYLES) do
    describe("mirrored graph layout [" .. style.name .. "]", function()
        for _, fx in ipairs(FIXTURES) do
            it("lays out " .. fx.name, function()
                assert_ok(mirror_opts(style.ms), h.dag(fx.rows),
                    style.name .. "/" .. fx.name, style.experimental)
            end)
        end

        it("produces well-formed graphs for random DAGs", function()
            local failures = {}
            for seed = 1, 60 do
                local n = 3 + (seed % 10)
                local items = h.dag(h.random_dag(n, seed))
                local errors, _, grid = h.check(mirror_opts(style.ms), items, style.experimental)
                if #errors > 0 then
                    failures[#failures + 1] = ("seed=%d n=%d:\n%s\n%s"):format(
                        seed, n, h.grid_to_string(grid), table.concat(errors, "\n"))
                    if #failures >= 3 then break end
                end
            end
            assert(#failures == 0, "\n=== fuzz failures ===\n" .. table.concat(failures, "\n\n"))
        end)
    end)
end

--------------------------------------------------------------------------------
-- (2) The mirror is the true horizontal flip of the normal render
--------------------------------------------------------------------------------

-- Asymmetric glyphs flip; symmetric ones are their own mirror.
local SWAP = {
    ["╭"] = "╮", ["╮"] = "╭", ["╰"] = "╯", ["╯"] = "╰",
    ["├"] = "┤", ["┤"] = "├", ["╴"] = "╶", ["╶"] = "╴",
    ["│"] = "│", ["─"] = "─", ["┬"] = "┬", ["┴"] = "┴",
    ["╵"] = "╵", ["╷"] = "╷", ["^"] = "^", [" "] = " ",
    ["○"] = "○", ["◉"] = "◉", ["◎"] = "◎",
}

-- Flip a glyph grid horizontally: reverse each row and swap asymmetric glyphs.
local function flip(grid)
    local out = {}
    for _, row in ipairs(grid) do
        local cells = {}
        for i = #row, 1, -1 do
            cells[#cells + 1] = SWAP[row[i].ch] or row[i].ch
        end
        out[#out + 1] = table.concat(cells)
    end
    return out
end

-- Trim leading/trailing whitespace per line. The reversed render keeps its
-- inter-lane connector *after* each glyph, so the trailing 1-space gap sits on
-- the right rather than the left versus a pixel-perfect flip — an edge offset
-- only. Interior glyphs and connectors match exactly (see spec §5.4); column
-- alignment is enforced separately by the invariant suite above.
local function core(lines)
    local out = {}
    for _, l in ipairs(lines) do
        out[#out + 1] = (l:gsub("^%s+", ""):gsub("%s+$", ""))
    end
    return table.concat(out, "\n")
end

local function glyph_lines(grid)
    local out = {}
    for _, row in ipairs(grid) do
        local s = {}
        for _, cell in ipairs(row) do s[#s + 1] = cell.ch end
        out[#out + 1] = table.concat(s)
    end
    return out
end

for _, style in ipairs(STYLES) do
    describe("mirror == flip(normal) [" .. style.name .. "]", function()
        for _, fx in ipairs(FIXTURES) do
            it("for " .. fx.name, function()
                local items = h.dag(fx.rows)
                -- The model is mirror-independent: build once, render both ways.
                local rows = graph._internal.build_graph(h.big_opts(style.ms), items)
                local normal = h.render_grid(h.big_opts(style.ms), rows)
                local mirrored = h.render_grid(mirror_opts(style.ms), rows)
                assert.equals(core(flip(normal)), core(glyph_lines(mirrored)),
                    style.name .. "/" .. fx.name)
            end)
        end
    end)
end

--------------------------------------------------------------------------------
-- (3) Mirroring preserves color: a flip never recolors a cell or connector.
--------------------------------------------------------------------------------

-- Every highlight group used, with counts, over the whole grid. With big_opts
-- (64-color palette) a color is a 1:1 proxy for a lane id, so the multiset must
-- be identical mirrored vs normal — a flip moves cells, it never recolors them.
local function color_multiset(grid)
    local set = {}
    for _, row in ipairs(grid) do
        for _, cell in ipairs(row) do
            if cell.hl then set[cell.hl] = (set[cell.hl] or 0) + 1 end
        end
    end
    return set
end

for _, style in ipairs(STYLES) do
    if not style.experimental then -- allow_merge_on_split color is best-effort
        describe("mirror preserves color [" .. style.name .. "]", function()
            local function check(items, label)
                local rows = graph._internal.build_graph(h.big_opts(style.ms), items)
                local normal = color_multiset(h.render_grid(h.big_opts(style.ms), rows))
                local mirrored = color_multiset(h.render_grid(mirror_opts(style.ms), rows))
                assert.same(normal, mirrored, label)
            end

            for _, fx in ipairs(FIXTURES) do
                it("for " .. fx.name, function()
                    check(h.dag(fx.rows), style.name .. "/" .. fx.name)
                end)
            end

            it("for random DAGs", function()
                for seed = 1, 40 do
                    local n = 3 + (seed % 10)
                    check(h.dag(h.random_dag(n, seed)), "seed=" .. seed)
                end
            end)
        end)
    end
end

--------------------------------------------------------------------------------
-- (4) The `gutter` layout policy under mirror (spec §5.6)
--------------------------------------------------------------------------------
-- Mirroring is orthogonal to *movement*, so the four compaction policies need no
-- separate mirror sweep — they emit the same shapes in different columns. `gutter`
-- is different in kind: it changes where NODES go, which produces cell shapes the
-- other policies never emit (a node cell whose only wire is a horizontal; a lane
-- cell where one lane both arrives and leaves, rendered `┤`). Those are exactly
-- the shapes a flip could get wrong, and mirrored is the orientation the policy
-- exists for (§5.4 puts the gutter nearest the message), so it gets the full
-- treatment: invariants on the mirrored render, mirror == flip(normal), and colour
-- preservation, across every merge style.

local function gutter_opts(ms, mirror)
    local o = h.big_opts(ms)
    o.layout_policy = "gutter"
    o.mirror = mirror
    return o
end

for _, style in ipairs(STYLES) do
    describe("gutter policy under mirror [" .. style.name .. "]", function()
        for _, fx in ipairs(FIXTURES) do
            it("lays out " .. fx.name .. " mirrored", function()
                assert_ok(gutter_opts(style.ms, true), h.dag(fx.rows),
                    "gutter/" .. style.name .. "/" .. fx.name, style.experimental)
            end)
        end

        it("is well-formed mirrored across random DAGs", function()
            local failures = {}
            for seed = 1, 120 do
                local n = 3 + (seed % 12)
                local items = h.dag(h.random_dag(n, seed))
                local errors, _, grid = h.check(gutter_opts(style.ms, true), items, style.experimental)
                if #errors > 0 then
                    failures[#failures + 1] = ("seed=%d n=%d:\n%s\n%s"):format(
                        seed, n, h.grid_to_string(grid), table.concat(errors, "\n"))
                    if #failures >= 3 then break end
                end
            end
            assert(#failures == 0, "\n=== gutter fuzz failures ===\n" .. table.concat(failures, "\n\n"))
        end)

        it("is well-formed unmirrored across random DAGs", function()
            local failures = {}
            for seed = 1, 120 do
                local n = 3 + (seed % 12)
                local items = h.dag(h.random_dag(n, seed))
                local errors, _, grid = h.check(gutter_opts(style.ms, false), items, style.experimental)
                if #errors > 0 then
                    failures[#failures + 1] = ("seed=%d n=%d:\n%s\n%s"):format(
                        seed, n, h.grid_to_string(grid), table.concat(errors, "\n"))
                    if #failures >= 3 then break end
                end
            end
            assert(#failures == 0, "\n=== gutter fuzz failures ===\n" .. table.concat(failures, "\n\n"))
        end)

        it("mirrors as the true flip of the normal render", function()
            for _, fx in ipairs(FIXTURES) do
                local items = h.dag(fx.rows)
                local rows = graph._internal.build_graph(gutter_opts(style.ms, false), items)
                local normal = h.render_grid(gutter_opts(style.ms, false), rows)
                local mirrored = h.render_grid(gutter_opts(style.ms, true), rows)
                assert.equals(core(flip(normal)), core(glyph_lines(mirrored)),
                    "gutter/" .. style.name .. "/" .. fx.name)
            end
        end)

        if not style.experimental then
            it("preserves colour under the flip", function()
                for seed = 1, 40 do
                    local items = h.dag(h.random_dag(3 + (seed % 10), seed))
                    local rows = graph._internal.build_graph(gutter_opts(style.ms, false), items)
                    assert.same(
                        color_multiset(h.render_grid(gutter_opts(style.ms, false), rows)),
                        color_multiset(h.render_grid(gutter_opts(style.ms, true), rows)),
                        "gutter/" .. style.name .. "/seed=" .. seed)
                end
            end)
        end
    end)
end
