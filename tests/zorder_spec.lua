--- The float z-order layers (spec §14.1, §8 `zindex`): the host window is created
--- at the `zindex` option (default 41); gitloom's overlays (context panes, the
--- commit-view sticky header) sit at host + 1 and its transient floats (`?`/`K`,
--- the pin dialog, the filter prompt, its pickers) at host + 2. The layers are
--- read off the host's LIVE zindex, so a real float stands in for the host. That
--- the host is actually CREATED at the option is checked by `make smoke`.
local window = require("gitloom.window")
local I = window._internal

---@param z integer
---@return integer
local function host_at(z)
    local buf = vim.api.nvim_create_buf(false, true)
    return vim.api.nvim_open_win(buf, false, {
        relative = "editor", row = 1, col = 1, width = 20, height = 5,
        style = "minimal", zindex = z,
    })
end

describe("float z-order layers (§14.1)", function()
    local wins = {}
    after_each(function()
        for _, w in ipairs(wins) do pcall(vim.api.nvim_win_close, w, true) end
        wins = {}
    end)

    it("default host 41 -> overlays 42, transient floats 43", function()
        local w = host_at(41); wins[#wins + 1] = w
        assert.equals(41, I.host_zindex(w))
        assert.equals(42, I.overlay_zindex(w))
        assert.equals(43, I.float_zindex(w))
    end)

    it("a custom host zindex shifts all three layers", function()
        local w = host_at(70); wins[#wins + 1] = w
        assert.equals(70, I.host_zindex(w))
        assert.equals(71, I.overlay_zindex(w))
        assert.equals(72, I.float_zindex(w))
    end)

    it("without a host window the layers fall back to the default 41", function()
        assert.equals(41, I.host_zindex(nil))
        assert.equals(42, I.overlay_zindex(nil))
        assert.equals(43, I.float_zindex(nil))
    end)

    it("stays above window decorations and below other plugins' floats", function()
        -- scrollbars / overseer draw at 40; fidget at 45, pickers / vim.ui.select 50+.
        assert.is_true(I.host_zindex(nil) > 40)
        assert.is_true(I.float_zindex(nil) < 45)
    end)
end)
