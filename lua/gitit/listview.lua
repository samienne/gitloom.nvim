local M = {}


local snacks_ok, snacks = pcall(require, "snacks.win")
if not snacks_ok then
    error("snacks.win not found. Install snacks.nvim")
end

-- 1-based indexing, inclusive range
local function get_visible_range(win)
    win = win or 0
    local first = vim.fn.line("w0", win)
    --local last = vim.fn.line("w$", win)
    local last = first + vim.api.nvim_win_get_height(win) - 1
    return first, last
end

local function create_win(opts)
    opts = opts or {}
    local win_opts = vim.tbl_deep_extend("force", {
        border = "rounded",
        width = 0.80,
        height = 0.80,
        title = "ListView",
        footer = "Press 'q' to quit",
    }, opts.win or {})

    local w = snacks.new(win_opts)

    local state = {
        namespace = opts.namespace,
        winid = w.win,
        buf = w.buf,
        top = 0,
        bottom = 0,
    }

    if opts.on_redraw then
        vim.api.nvim_set_decoration_provider(state.namespace, {
            on_win = function(win, winid, bufnr, topline, botline)
                if not win == "win" then
                    return
                end

                if state.winid == winid then
                    if topline ~= 0 and botline ~= 0 and topline ~= state.top or botline ~= state.bottom then
                        state.top = topline
                        state.bottom = botline
                        vim.schedule(function()
                            -- Convert from 0-based indexing
                            opts.on_redraw(winid, bufnr, topline + 1, botline + 1)
                        end)
                    end
                end
            end,
        })
    end

    return w
end

-- 1-based indexing
local function refresh_columns(win, model, first, last)
    first = first or 1
    last = last or #model.items

    local changed = false

    for i = first, last do
        local item = model.items[i]

        if item and not item.columns then
            item.columns = model.display(item.data)
            for j, column in ipairs(item.columns) do
                if type(column) == "string" then
                    item.columns[j] = {
                        text = column,
                        highlight = nil
                    }
                end
            end
            changed = true
        end
    end

    if not changed then
        for i = first, last do
            local item = model.items[i]

            if item then
                if #item.columns ~= #model.columns then
                    changed = true
                end

                for j = 1, #item.columns do
                    if not model.columns[j] or vim.fn.strdisplaywidth(item.columns[j].text) ~= model.columns[j] then
                        changed = true
                        break
                    end
                end

                if changed then
                    break
                end
            end
        end
    end

    if changed then
        local new_columns = {}
        for i = first, last do
            local item = model.items[i]
            if item then
                for j, column in ipairs(item.columns) do
                    if #new_columns < j then
                        table.insert(new_columns, vim.fn.strdisplaywidth(column.text))
                    else
                        new_columns[j] = math.max(vim.fn.strdisplaywidth(column.text), new_columns[j])
                    end
                end
            end
        end

        model.columns = new_columns
    end

    return changed
end

-- Requested width in utf code points
local function fix_width(item, requested_utf_len)
    local utf_len = vim.fn.strdisplaywidth(item.text)

    if utf_len == requested_utf_len then
        return item
    elseif utf_len < requested_utf_len then
        local highlight = {}
        if item.highlight then
            local requested_len = vim.str_byteindex(item.text, "utf-8", requested_utf_len, false)

            for _, hl in ipairs(item.highlight) do
                local start_pos = hl.start_pos
                local end_pos = hl.end_pos
                if start_pos < requested_len then
                    end_pos = math.min(end_pos, requested_len)

                    table.insert(highlight, {
                        start_pos = start_pos,
                        end_pos = end_pos,
                        hl = hl.hl
                    })
                end
            end
        end

        return {
            text = item.text .. string.rep(" ", requested_utf_len - utf_len),
            highlight = highlight,
        }
    else
        local requested_len = vim.str_byteindex(item.text, "utf-8", requested_utf_len, false)

        return {
            text = string.sub(item.text, 1, requested_len),
            highlight = item.highlight
        }
    end
end

local namespace = vim.api.nvim_create_namespace("gitit.listview")

-- 1-based indexing, inclusive last
local function display(buf, model, first, last)
    first = first or 1
    last = last or #model.items

    local lines = {}
    local highlight = {}
    for i = first, last do
        local item = model.items[i]

        local line = ""
        if item then
            for j, column in ipairs(item.columns) do
                local fixed = fix_width(column, model.columns[j])
                local offset = string.len(line)
                line = line .. fixed.text
                for _, hl in ipairs(fixed.highlight or {}) do
                    table.insert(highlight, {
                        line = i - 1,
                        start_pos = offset + hl.start_pos,
                        end_pos = offset + hl.end_pos,
                        hl = hl.hl,
                    })
                end
            end
        end

        table.insert(lines, line)
    end

    vim.bo[buf].modifiable = true
    vim.bo[buf].readonly = false

    -- Convert first,last from 1-based inclusive last to 0-based exclusive last.
    vim.api.nvim_buf_set_lines(buf, first - 1, last, false, lines)
    vim.api.nvim_buf_clear_namespace(buf, namespace, first - 1, last)

    for _, hl in ipairs(highlight) do
        vim.api.nvim_buf_set_extmark(buf, namespace, hl.line, hl.start_pos, {
            end_col = hl.end_pos,
            hl_group = hl.hl,
        })
    end
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true
end

local function preserve_cursor_visual_pos(win, buf, fn)
    -- Implement later
    fn()
end

local function insert(win, model, items, pos)
    local lines = {}
    for i, item in ipairs(items) do
        local table_item = {
            index = pos, -- 1-based indexing
            data = item
        }
        table_item.columns = nil
        table_item.index = pos + i - 1

        if pos then
            table.insert(model.items, pos, table_item)
        else
            table.insert(model.items, table_item)
        end

        table.insert(lines, "")
    end

    preserve_cursor_visual_pos(win.win, win.buf, function()
        local buf = win.buf
        vim.bo[buf].modifiable = true
        vim.bo[buf].readonly = false
        -- Convert first,last from 1-based inclusive last to 0-based exclusive last.
        vim.api.nvim_buf_set_lines(buf, pos - 1, pos, false, lines)
        vim.bo[buf].modifiable = false
        vim.bo[buf].readonly = true
    end)
end

function M.open(opts)
    local model = {
        items = {},
        columns = {},
        display = opts.display,
    }

    opts = opts or {}
    opts.namespace = namespace
    opts.on_redraw = function(winid, bufnr, top, bottom)
        local changed = refresh_columns(winid, model, top, bottom)
        display(bufnr, model, top, bottom)
    end

    local win = create_win(opts or {})

    local controller = {
        -- 1-based indexing
        insert = function(items, pos)
            insert(win, model, items, pos)
        end,
        remove = function(pos)
            local item = model.items[pos]
            if not item then
                return
            end

            table.remove(model.items, pos)
        end,
        move = function()
        end,
    }

    if opts.on_controller then
        opts.on_controller(controller)
    end

    vim.bo[win.buf].buftype = "nofile"
    vim.bo[win.buf].modifiable = false
    vim.bo[win.buf].readonly = true
end

return M
