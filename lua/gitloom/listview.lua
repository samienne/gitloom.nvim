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

--- 1-based indexing
---@param win integer
---@param model ListViewModel
---@param first integer
---@param last integer
---@return boolean
local function refresh_columns(win, model, first, last)
    first = first or 1
    last = last or #model.items

    local changed = false

    for _, field in ipairs({ "above", "line", "text" }) do
        for i = first, last do
            local item = model.items[i]
            if item and not item.columns then
                item.columns = model.display(item.data)
                if item.columns[field] then
                    for j, column in ipairs(item.columns[field]) do
                        if type(column) == "string" then
                            item.columns[field][j] = {
                                text = column,
                                highlight = nil
                            }
                        end
                    end
                    changed = true
                end
            end
        end

        if not changed then
            for i = first, last do
                local item = model.items[i]
                if item.columns[field] then
                    if item then
                        if #item.columns[field] ~= #model.columns then
                            changed = true
                        end

                        for j = 1, #item.columns[field] do
                            if not model.columns[j] or vim.fn.strdisplaywidth(item.columns[field][j].text) ~= model.columns[j] then
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
        end
    end

    if changed then
        local new_columns = {}
        for i = first, last do
            local item = model.items[i]
            for _, field in ipairs({ "above", "line", "text" }) do
                if item and item.columns[field] then
                    for j, column in ipairs(item.columns[field]) do
                        if #new_columns < j then
                            table.insert(new_columns, vim.fn.strdisplaywidth(column.text))
                        else
                            new_columns[j] = math.max(vim.fn.strdisplaywidth(column.text), new_columns[j])
                        end
                    end
                end
            end
        end

        model.columns = new_columns
    end

    return changed
end

---@class HighlightInfo
---@field hl string
---@field start_pos integer
---@field end_pos integer

---@class DisplayItem
---@field text string
---@field highlight HighlightInfo
---@field align? "left"|"right"  column padding side (default left)

---@class DisplayElement
---@field above? (DisplayItem|string)[]
---@field line (DisplayItem|string)[]
---@field below? (DisplayItem|string)[]

--- Requested width in utf code points.
---@param item DisplayItem
---@param requested_utf_len integer
---@return DisplayItem
local function fix_width(item, requested_utf_len)
    local text = item.text or ""
    local utf_len = vim.fn.strdisplaywidth(text)

    if utf_len == requested_utf_len then
        return item
    elseif utf_len < requested_utf_len then
        local pad = requested_utf_len - utf_len
        if item.align == "right" then
            -- Right-align: prepend padding and shift each highlight range by the
            -- pad's byte length (a space is one byte).
            local highlight = {}
            for _, hl in ipairs(item.highlight or {}) do
                table.insert(highlight, {
                    start_pos = hl.start_pos + pad,
                    end_pos = hl.end_pos + pad,
                    hl = hl.hl,
                })
            end
            return {
                text = string.rep(" ", pad) .. text,
                highlight = highlight,
            }
        end
        return {
            text = text .. string.rep(" ", pad),
            highlight = item.highlight,
        }
    else
        local requested_len = vim.str_byteindex(item.text, "utf-8", requested_utf_len, false)

        ---@type HighlightInfo[]
        local highlight = {}
        if item.highlight then
            for _, hl in ipairs(item.highlight) do
                local start_pos = hl.start_pos
                local end_pos = hl.end_pos
                if start_pos < requested_len then
                    end_pos = math.min(end_pos, requested_len)

                    ---@type HighlightInfo
                    local new_highlight = {
                        start_pos = start_pos,
                        end_pos = end_pos,
                        hl = hl.hl
                    }

                    table.insert(highlight, new_highlight)
                end
            end
        end

        return {
            text = string.sub(text, 1, requested_len),
            highlight = highlight
        }
    end
end

---@param item DisplayItem
local function build_virt_text_chunks(item)
    local text = item.text

    if not item.highlight then
        return { { text, nil } }
    end

    local ranges = vim.deepcopy(item.highlight or {})

    table.sort(ranges, function(a, b)
        return a.start_pos < b.start_pos
    end)

    local chunks = {}
    local pos = 0
    local len = #text

    for _, h in ipairs(ranges) do
        local s = h.start_pos
        local e = h.end_pos

        if s < e and s >= 0 and e <= len then
            if s > pos then
                local plain = text:sub(pos + 1, s)
                table.insert(chunks, { plain, nil })
            end

            local highlighted = text:sub(s + 1, e)
            table.insert(chunks, { highlighted, h.hl })

            pos = e
        end
    end

    if pos < len then
        table.insert(chunks, { text.sub(pos + 1, len), nil })
    end

    return chunks
end

local function compose(list)
    local text = ""
    local highlight = {}
    for _, item in ipairs(list) do
        if type(item) == "table" then
            local offset = string.len(text)
            for _, hl in ipairs(item.highlight or {}) do
                table.insert(highlight, {
                    start_pos = offset + hl.start_pos,
                    end_pos = offset + hl.end_pos,
                    hl = hl.hl
                })
            end
            text = text .. (item.text or "")
        elseif type(item) == "string" then
            text = text .. item
        end
    end

    return {
        text = text,
        highlight = highlight,
    }
end

local namespace = vim.api.nvim_create_namespace("gitloom.listview")

--- 1-based indexing, inclusive last
---@param buf integer
---@param model ListViewModel
---@param first integer
---@param last integer
local function display(buf, model, first, last)
    first = first or 1
    last = last or #model.items

    local lines = {}
    local highlight = {}
    local virt_lines = {}
    local virt_lines_below = {}
    for i = first, last do
        local item = model.items[i]

        local line = ""
        local above = {}
        local below = {}
        if item then
            for j, column in ipairs(item.columns.line) do
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

            for j, column in ipairs(item.columns.above or {}) do
                local fixed = fix_width(column, model.columns[j])
                table.insert(above, fixed)
            end

            for j, column in ipairs(item.columns.below or {}) do
                local fixed = fix_width(column, model.columns[j])
                table.insert(below, fixed)
            end
        end

        if #above > 0 then
            local chunks = build_virt_text_chunks(compose(above))
            table.insert(virt_lines, {
                line = i - 1,
                chunks = chunks
            })
        end

        if #below > 0 then
            local chunks = build_virt_text_chunks(compose(below))
            table.insert(virt_lines_below, {
                line = i - 1,
                chunks = chunks
            })
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

    for _, line in ipairs(virt_lines) do
        vim.api.nvim_buf_set_extmark(buf, namespace, line.line, 0, {
            virt_lines = { line.chunks },
            virt_text_pos = "eol",
            virt_lines_above = true,
        })
    end

    for _, line in ipairs(virt_lines_below) do
        vim.api.nvim_buf_set_extmark(buf, namespace, line.line, 0, {
            virt_lines = { line.chunks },
            virt_text_pos = "eol",
            virt_lines_above = false,
        })
    end

    --[[
    for i = first, last do
        local item = model.items[i]
        if item.columns.above then
            vim.api.nvim_buf_set_extmark(buf, namespace, i, 0, {
                virt_lines = {
                },
            })
        end
    end
    --]]
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true
end

local function preserve_cursor_visual_pos(win, buf, fn)
    -- Implement later
    fn()
end

---@param win any
---@param model ListViewModel
---@param items DisplayItem[]
---@param pos integer
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

---@class ListViewController
---@field insert fun(items: OrderItem[], pos: integer)
---@field remove fun(pos: integer)
---@field refresh fun()

---@alias DisplayFunction fun(item): DisplayElement

---@alias OnRedrawFunction fun(winid: integer, bufnr: integer, top: integer, bottom: integer)

---@alias OnControllerFunction fun(controller: ListViewController)

---@class ListItem
---@field data any
---@field columns DisplayElement
---
---@class ListViewModel
---@field items ListItem[]
---@field columns integer[]
---@field display DisplayFunction

---@class ListViewOptions
---@field namespace? integer
---@field display DisplayFunction
---@field on_redraw? OnRedrawFunction
---@field on_controller OnControllerFunction

---@param opts ListViewOptions
function M.open(opts)
    ---@type ListViewModel
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

    ---@type ListViewController
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
        -- Re-render the visible range from scratch (drops cached columns), for
        -- when the display function's output changes (e.g. a display toggle).
        refresh = function()
            for _, item in ipairs(model.items) do
                item.columns = nil
            end
            local first, last = get_visible_range(win.win)
            refresh_columns(win.win, model, first, last)
            display(win.buf, model, first, last)
        end,
    }

    if opts.on_controller then
        opts.on_controller(controller)
    end

    vim.bo[win.buf].buftype = "nofile"
    vim.bo[win.buf].modifiable = false
    vim.bo[win.buf].readonly = true

    return { win = win, controller = controller }
end

return M
