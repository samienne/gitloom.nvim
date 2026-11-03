-- The context panes (§6.2) must never float over a commit view (§11/§14.3).
--
-- The commit view is a navigation frame in the graph's host window: pushing it
-- swaps the host's buffer, and the graph's BufWinLeave closes the panes. But the
-- panes are also (re)built from many async paths — the stream completing, a
-- reflow landing, the cone debounce, and the pane build itself, which yields and
-- resumes across event-loop ticks. Any of those firing while the commit view owns
-- the host window used to re-open the footer (relative="win" on the host) right
-- over the commit view, where nothing ever closed it again (the user's "footer
-- got stuck over the commit view").
--
-- Drives the REAL graph on this repository (needs snacks in the lazy install dir).

local function settle(ms) vim.wait(ms or 200, function() return false end) end

-- Overlay floats anchored to `host` sitting BELOW its top row: the graph's
-- footer. (The commit view's own context header sits at row 0.)
local function bottom_overlays(host)
    local found = {}
    for _, w in ipairs(vim.api.nvim_list_wins()) do
        local cfg = vim.api.nvim_win_get_config(w)
        if cfg.relative == "win" and cfg.win == host then
            local row = type(cfg.row) == "table" and cfg.row[false] or cfg.row
            if (tonumber(row) or 0) > 0 then found[#found + 1] = w end
        end
    end
    return found
end

describe("context panes vs the commit view (§6.2/§14.3)", function()
    local window, sess, gbuf

    before_each(function()
        vim.opt.rtp:prepend(vim.fn.stdpath("data") .. "/lazy/snacks.nvim")
        vim.o.lines, vim.o.columns = 30, 160
        require("snacks").setup({})
        window = require("gitloom.window")
        ---@diagnostic disable-next-line: missing-fields
        local lv = window.open(nil, {} --[[@as GraphOptions]])
        gbuf = lv.buf
        -- Let the stream + the open-time reflow settle (stable line count).
        local last_n, stable = -1, 0
        vim.wait(8000, function()
            local n = vim.api.nvim_buf_line_count(gbuf)
            if n == last_n and n > 1 then stable = stable + 1 else stable = 0 end
            last_n = n
            return stable >= 4
        end, 60)
        sess = window._internal.ctx
    end)

    it("a pane rebuild fired while the commit view is up does not re-open the footer over it", function()
        local host = vim.fn.bufwinid(gbuf)
        assert.is_true(host ~= -1, "graph not shown")
        vim.api.nvim_set_current_win(host)
        -- The footer exists over the graph (sanity: the fixture has history below).
        sess:update_panes()
        settle(300)
        assert.is_true(#bottom_overlays(host) > 0, "fixture: no footer over the graph to begin with")

        -- Open the commit view of the cursor's commit (<CR>): a buffer swap.
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
        settle(300)
        assert.is_true(vim.api.nvim_win_get_buf(host) ~= gbuf, "the commit view did not open")
        assert.same({}, bottom_overlays(host), "BufWinLeave did not close the footer")

        -- An async pane rebuild lands now (stream done / reflow / cone debounce /
        -- a resumed build chunk): it must not put the footer over the commit view.
        sess:update_panes()
        sess:maybe_update_panes()
        settle(300)
        assert.is_true(vim.api.nvim_win_get_buf(host) ~= gbuf)
        assert.same({}, bottom_overlays(host), "the footer re-opened over the commit view")

        -- Back on the graph frame (<C-o>), the panes are rebuilt (on_show).
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-o>", true, false, true), "x", false)
        settle(300)
        assert.equals(gbuf, vim.api.nvim_win_get_buf(host), "did not return to the graph")
        assert.is_true(#bottom_overlays(host) > 0, "the footer was not rebuilt on return")
    end)
end)
