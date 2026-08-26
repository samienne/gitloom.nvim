--- Small vendored utilities shared inside gitloom.
---
--- These are deliberately gitloom-local copies, not a dependency on
--- loomworks.nvim (see CLAUDE.md "Relationship to loomworks"): `make_future`
--- is gitloom's own minimal promise, and `compose` is the highlight-composition
--- helper. listview.lua keeps its **own** private copy of `compose` so it stays
--- a standalone, git-agnostic widget — do not route it through this module.

local M = {}

---@class Future
---@field next fun(fn: fun(value: any): any): Future

--- A minimal promise/future. `promise.resolve(value)` settles it; `future.next`
--- chains a continuation, flattening a returned future. A continuation chained
--- onto an already-resolved future still runs (scheduled), so a synchronously
--- resolved future does not silently drop its callback.
---@return Future, { resolve: fun(value: any) }
function M.make_future()
    local state = {
        callback = nil,
        value = nil,
    }

    local future = {
        next = function(fn)
            local future, promise = M.make_future()

            if state.value then
                -- Already resolved: still run `fn` (it was being dropped — the bug
                -- behind the open-time reflow never firing after a synchronously
                -- resolved future, e.g. the gitloom sort mode's apply_sort).
                vim.schedule(function()
                    promise.resolve(fn(unpack(state.value)))
                end)
            else
                state.callback = function(value)
                    promise.resolve(fn(value))
                end
            end

            return future
        end,
    }

    local promise = {
        resolve = function(value)
            state.value = { value }
            -- A future is always a table; probing `.next` on a non-table (e.g. a
            -- number) would throw "attempt to index a number value".
            if type(value) == "table" and value.next then
                value.next(function(next_value)
                    if state.callback then
                        state.callback(next_value)
                    end
                end)
            else
                if state.callback then
                    state.callback(value)
                end
            end
        end,
    }

    return future, promise
end

--- Build a single `{ text, highlight }` fragment: `text` optionally wrapped in
--- one highlight span covering its whole width. An empty string carries no span.
--- The single-fragment primitive that `compose` concatenates. Left untyped (like
--- the original local) so callers may pass a possibly-nil cell char/group
--- without a lint warning.
function M.highlight_text(text, hl)
    if text == "" then
        return {
            text = text,
            highlight = {},
        }
    end

    return {
        text = text,
        highlight = hl and {
            {
                start_pos = 0,
                end_pos = string.len(text),
                hl = hl,
            },
        } or nil,
    }
end

--- Concatenate a list of text/highlight fragments into a single
--- `{ text, highlight }` record, offsetting each fragment's highlight spans by
--- the running text length. List items may be `{ text, highlight }` tables or
--- plain strings. Left untyped (like the original local) so callers may add
--- fields such as `align` to the result without a lint inject-field warning.
function M.compose(list)
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

--- Trim leading/trailing whitespace (git command output is line-wrapped).
---@param s string|nil
---@return string
function M.trim_ws(s)
    return ((s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- ===== pane-lifecycle trace (`vim.g.gitloom_pane_trace`) ====================
--
-- The context panes (spec §6.2) are rebuilt through an async, cancellable
-- coroutine that is **scroll-gated**: `update_panes` records the scroll key the
-- build targets and `maybe_update_panes` repaints instead of rebuilding while
-- that key is unchanged. When the panes go missing (or go stale) after a
-- programmatic reposition, the question is always the same one — did the build
-- run, was it abandoned, did it decline, or was the gate simply never reopened?
-- None of that is visible from outside, so this records it.
--
-- Set `vim.g.gitloom_pane_trace` to a file path and every `update_panes` /
-- `maybe_update_panes` / drive / decline / close appends one line:
--
--     0001 +12ms maybe key=137:0 want=137:0 act=repaint
--     0002 +0ms  update key=201:0 gen=8 site=jump_to_ref
--     0003 +1ms  abandon gen=8 cur=9 at=post
--
-- A no-op — and free of any work at all — while the global is not a string, so
-- the call sites cost one global read. Diagnostics only: every step is guarded,
-- and a broken trace must never break the view.
local trace_seq, trace_t0 = 0, nil

--- Append one pane-lifecycle record. `fields` are rendered as `k=v` in sorted
--- key order (so successive lines line up and diff cleanly).
---@param event string
---@param fields table<string, any>?
function M.pane_trace(event, fields)
    local path = vim.g.gitloom_pane_trace
    if type(path) ~= "string" then return end
    pcall(function()
        local now = vim.uv and vim.uv.hrtime() or vim.loop.hrtime()
        trace_t0 = trace_t0 or now
        trace_seq = trace_seq + 1
        local f = fields or {}
        local keys = {}
        for k in pairs(f) do keys[#keys + 1] = k end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do
            parts[#parts + 1] = ("%s=%s"):format(k, tostring(f[k]))
        end
        local line = ("%04d +%dms %s %s"):format(
            trace_seq, math.floor((now - trace_t0) / 1e6), event, table.concat(parts, " "))
        local fh = io.open(path, "a")
        if not fh then return end
        fh:write(line); fh:write(string.char(10))
        fh:close()
    end)
end

--- True while the pane trace is armed — for call sites that would otherwise do
--- real work (a stack capture) just to build the fields.
---@return boolean
function M.pane_tracing()
    return type(vim.g.gitloom_pane_trace) == "string"
end

return M
