local M = {}


-- snacks is required only to open a window; load it lazily so the pure helpers
-- (and their tests) don't need it in the runtime. create_win errors if missing.
local snacks_ok, snacks = pcall(require, "snacks.win")

-- 1-based indexing, inclusive range
local function get_visible_range(win)
    win = win or 0
    local first = vim.fn.line("w0", win)
    --local last = vim.fn.line("w$", win)
    local last = first + vim.api.nvim_win_get_height(win) - 1
    return first, last
end

local function create_win(opts)
    if not snacks_ok then
        error("snacks.win not found. Install snacks.nvim")
    end
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

--- The column-array rows of a DisplayElement field. `line`/`text` are a single
--- row (a flat column array); `above`/`below` are a **list of rows** (stacked
--- virtual lines), so a commit can carry several (e.g. a split line and the
--- dual-mode branch line). Always returns a list of rows.
---@param element table
---@param field string
---@return table[]
local function field_rows(element, field)
    local v = element[field]
    if not v then return {} end
    if field == "above" or field == "below" then return v end
    return { v }
end

--- 1-based indexing
---@param win integer?   the list window (unused here; nil in unit tests)
---@param model ListViewModel
---@param first integer
---@param last integer
---@return boolean
local function refresh_columns(win, model, first, last)
    first = first or 1
    last = last or #model.items

    local changed = false

    -- The flex column (e.g. the message, or the dual-mode branch line's labels)
    -- sizes per row, not by alignment, so it never drives the shared max widths.
    local function counts(j)
        return not (model.flex and j == model.flex)
    end

    -- Compute any newly-visible items and normalise string columns to
    -- DisplayItems. A freshly computed item means the widths may need a redo.
    for i = first, last do
        local item = model.items[i]
        if item and not item.columns then
            item.columns = model.display(item.data)
            for _, field in ipairs({ "above", "below", "line", "text" }) do
                for _, row in ipairs(field_rows(item.columns, field)) do
                    for j, column in ipairs(row) do
                        if type(column) == "string" then
                            row[j] = { text = column, highlight = nil }
                        end
                    end
                end
            end
            changed = true
        end
    end

    -- Even without a new item, a row whose column widths no longer match the
    -- shared maxima forces a recompute (e.g. after a display-mode toggle).
    if not changed then
        for i = first, last do
            local item = model.items[i]
            if item and item.columns then
                for _, field in ipairs({ "above", "below", "line", "text" }) do
                    for _, row in ipairs(field_rows(item.columns, field)) do
                        for j = 1, #row do
                            if counts(j) and (not model.columns[j]
                                    or vim.fn.strdisplaywidth(row[j].text) ~= model.columns[j]) then
                                changed = true
                                break
                            end
                        end
                        if changed then break end
                    end
                    if changed then break end
                end
            end
            if changed then break end
        end
    end

    if changed then
        local new_columns = {}
        for i = first, last do
            local item = model.items[i]
            for _, field in ipairs({ "above", "below", "line", "text" }) do
                if item and item.columns then
                    for _, row in ipairs(field_rows(item.columns, field)) do
                        for j, column in ipairs(row) do
                            if counts(j) then
                                new_columns[j] = math.max(
                                    vim.fn.strdisplaywidth(column.text),
                                    new_columns[j] or 0)
                            end
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
---@field highlight? HighlightInfo
---@field align? "left"|"right"  column padding side (default left)

---@class DisplayElement
---@field above? (DisplayItem|string)[][]  stacked virtual rows above (each a column array)
---@field line (DisplayItem|string)[]
---@field below? (DisplayItem|string)[][]  stacked virtual rows below (each a column array)
---@field line_right? DisplayItem[]  right-pinned items for the line (e.g. refs)

--- Requested width in display cells. With `ellipsis`, truncation appends "…"
--- (reserving one cell) instead of a hard cut.
---@param item DisplayItem|string
---@param requested_utf_len integer
---@param ellipsis boolean?
---@return DisplayItem
local function fix_width(item, requested_utf_len, ellipsis)
    -- above/below lines mix plain string spacers with DisplayItems; normalise.
    if type(item) == "string" then item = { text = item } end
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
        -- Truncate. With an ellipsis, reserve one cell for "…".
        local target = requested_utf_len
        local suffix = ""
        if ellipsis and requested_utf_len >= 1 then
            target = requested_utf_len - 1
            suffix = "…"
        end
        local requested_len = vim.str_byteindex(item.text, "utf-8", target, false)

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
            text = string.sub(text, 1, requested_len) .. suffix,
            highlight = highlight
        }
    end
end

--- Pack right-pinned items into `budget` display cells, whole items only and in
--- order (a `sep`-cell gap between them), reserving room for a "+N" overflow
--- marker when some don't fit. Returns the number shown (a prefix), the
--- overflow count, and the display width used. Pure; exposed for testing.
---@param widths integer[]   -- display width of each item, in order
---@param budget integer
---@param sep integer?       -- gap between items (default 1)
---@return integer shown, integer overflow, integer used
local function pack_right(widths, budget, sep)
    sep = sep or 1
    local n = #widths
    local function width_for(k)
        local w = 0
        for i = 1, k do
            w = w + widths[i] + (i > 1 and sep or 0)
        end
        local overflow = n - k
        if overflow > 0 then
            local marker = 1 + #tostring(overflow) -- "+N"
            w = w + (k > 0 and sep or 0) + marker
        end
        return w
    end

    local best = 0
    for k = 0, n do
        if width_for(k) <= budget then best = k end
    end
    return best, n - best, width_for(best)
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

--- Build the `line` string for one row plus its absolute highlight ranges.
--- When `model.flex` is set, columns before it are fixed-width (aligned), the
--- flex column fills the remaining window width (truncated with "…"), and the
--- row's `line_right` items are packed against the right edge. The refs may use
--- all the free width except what the flex column needs — its natural width, but
--- never reserving more than `model.message_min` (so refs fill empty space, yet
--- a long message keeps its floor). Overflow collapses into a "+N" marker.
---@return string line, table[] highlights
local function build_line(win, model, columns, right)
    local line, highlights = "", {}
    local function append(fixed)
        local offset = string.len(line)
        line = line .. fixed.text
        for _, hl in ipairs(fixed.highlight or {}) do
            highlights[#highlights + 1] = {
                start_pos = offset + hl.start_pos,
                end_pos = offset + hl.end_pos,
                hl = hl.hl,
            }
        end
    end

    local flex = model.flex
    if not flex then
        for j, column in ipairs(columns) do
            append(fix_width(column, model.columns[j] or 0))
        end
        return line, highlights
    end

    -- Fixed columns before the flex one.
    local used = 0
    for j = 1, flex - 1 do
        local w = model.columns[j] or 0
        append(fix_width(columns[j] or { text = "" }, w))
        used = used + w
    end

    local available = math.max(0, vim.api.nvim_win_get_width(win) - used)

    -- Pack the right-pinned items into the available width, reserving only what
    -- the flex column actually needs (its natural width, capped at message_min).
    -- So refs use free space, while a long message keeps at least message_min.
    right = right or {}
    local widths = {}
    for k, it in ipairs(right) do widths[k] = vim.fn.strdisplaywidth(it.text or "") end
    local flex_item = columns[flex] or { text = "" }
    local flex_w = vim.fn.strdisplaywidth(flex_item.text or "")
    local reserve = math.min(flex_w, model.message_min or 24)
    local budget = math.max(0, available - reserve)
    local shown, overflow, right_w = pack_right(widths, budget)

    -- Compose the right text: shown items, space-separated, then "+N".
    local parts = {}
    for k = 1, shown do
        if k > 1 then parts[#parts + 1] = " " end
        parts[#parts + 1] = right[k]
    end
    if overflow > 0 then
        if shown > 0 then parts[#parts + 1] = " " end
        local m = "+" .. overflow
        parts[#parts + 1] = { text = m, highlight = model.overflow_hl
            and { { start_pos = 0, end_pos = #m, hl = model.overflow_hl } } or {} }
    end
    local right_item = compose(parts)

    -- The flex (message) column fills what's left of the packed refs.
    local flex_target = math.max(0, available - right_w)
    append(fix_width(flex_item, flex_target, true))
    append(right_item)
    return line, highlights
end

--- Build the extmark `virt_lines` entries for one buffer line's stacked virtual
--- rows (each `above`/`below` row → one virtual line). The flex column is drawn
--- at its natural width (no pad/truncate) so the dual-mode branch line's labels
--- are not clipped; the other columns align to the shared maxima.
---@param model ListViewModel
---@param rows table[]   list of column-array rows
---@return table[]       list of virt_text chunk-lists
local function build_virt_rows(model, rows)
    local out = {}
    for _, row in ipairs(rows) do
        local cols = {}
        for j, column in ipairs(row) do
            if model.flex and j == model.flex then
                cols[#cols + 1] = (type(column) == "string") and { text = column } or column
            else
                cols[#cols + 1] = fix_width(column, model.columns[j] or 0)
            end
        end
        out[#out + 1] = build_virt_text_chunks(compose(cols))
    end
    return out
end

--- 1-based indexing, inclusive last
---@param win integer
---@param buf integer
---@param model ListViewModel
---@param first integer
---@param last integer
local function display(win, buf, model, first, last)
    first = first or 1
    last = last or #model.items

    local lines = {}
    local highlight = {}
    local virt_lines = {}
    local virt_lines_below = {}
    for i = first, last do
        local item = model.items[i]

        local line = ""
        local above_rows = {}
        local below_rows = {}
        if item then
            local built, hls = build_line(win, model, item.columns.line, item.columns.line_right)
            line = built
            for _, hl in ipairs(hls) do
                highlight[#highlight + 1] = {
                    line = i - 1,
                    start_pos = hl.start_pos,
                    end_pos = hl.end_pos,
                    hl = hl.hl,
                }
            end

            above_rows = build_virt_rows(model, field_rows(item.columns, "above"))
            below_rows = build_virt_rows(model, field_rows(item.columns, "below"))
        end

        if #above_rows > 0 then
            table.insert(virt_lines, { line = i - 1, rows = above_rows })
        end

        if #below_rows > 0 then
            table.insert(virt_lines_below, { line = i - 1, rows = below_rows })
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

    -- Each entry's `rows` are stacked top-to-bottom; above a line the last row
    -- renders nearest the buffer line (so graph emits [split, branch]).
    for _, vl in ipairs(virt_lines) do
        vim.api.nvim_buf_set_extmark(buf, namespace, vl.line, 0, {
            virt_lines = vl.rows,
            virt_text_pos = "eol",
            virt_lines_above = true,
        })
    end

    for _, vl in ipairs(virt_lines_below) do
        vim.api.nvim_buf_set_extmark(buf, namespace, vl.line, 0, {
            virt_lines = vl.rows,
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
---@field col_offset fun(row: integer, field: string, j: integer): integer

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
---@field flex? integer        index of the flex column in `line` (fills width)
---@field message_min? integer min width kept for the flex column
---@field overflow_hl? string  highlight for the "+N" overflow marker

---@class ListViewOptions
---@field namespace? integer
---@field display DisplayFunction
---@field on_redraw? OnRedrawFunction
---@field on_controller OnControllerFunction
---@field flex? integer
---@field message_min? integer
---@field overflow_hl? string

---@param opts ListViewOptions
function M.open(opts)
    ---@type ListViewModel
    local model = {
        items = {},
        columns = {},
        display = opts.display,
        flex = opts.flex,
        message_min = opts.message_min,
        overflow_hl = opts.overflow_hl,
    }

    opts = opts or {}
    opts.namespace = namespace
    opts.on_redraw = function(winid, bufnr, top, bottom)
        local changed = refresh_columns(winid, model, top, bottom)
        display(winid, bufnr, model, top, bottom)
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
            display(win.win, win.buf, model, first, last)
        end,
        -- Byte offset where column `j` of `field` starts on the rendered row,
        -- summing the fixed columns before it (used to park the cursor).
        col_offset = function(row, field, j)
            local item = model.items[row]
            if not item or not item.columns or not item.columns[field] then
                return 0
            end
            local off = 0
            for k = 1, (j or 1) - 1 do
                local col = item.columns[field][k]
                if col then
                    off = off + #(fix_width(col, model.columns[k] or 0).text)
                end
            end
            return off
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

-- Exposed for testing only. Not part of the public API.
M._internal = {
    pack_right = pack_right,
    refresh_columns = refresh_columns,
}

return M
