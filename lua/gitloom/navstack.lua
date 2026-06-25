--- gitloom.navstack — the pure navigation-stack math for a host window's view
--- stack (specification.md §14.3).
---
--- Git- and window-agnostic: it owns an ordered list of opaque **frame** handles
--- and a 1-based current index, with browser-history semantics — `push`
--- discards the forward tail (going somewhere new after stepping back is a
--- branch), `back`/`forward` clamp at the ends. The window controller binds
--- these to snacks buffer swaps and breadcrumb rendering; identity is positional
--- (the index), never content-addressed (§14.5).
---
--- A Stack is `{ frames = Frame[], idx = integer }`. `frames[1]` is the root
--- (the graph); `idx` points at the active frame.

local M = {}

--- A new stack seeded with its root frame (the graph).
---@param root_frame any
---@return table stack
function M.new(root_frame)
    return { frames = { root_frame }, idx = 1 }
end

--- Push `frame` as the new active frame, discarding any frames ahead of the
--- current one (the forward tail) — going somewhere new after `back` truncates
--- history (§14.3). Returns the dropped frames (tip-first) so the caller can wipe
--- their buffers (§14.5).
---@param stack table
---@param frame any
---@return any[] dropped
function M.push(stack, frame)
    local dropped = {}
    for i = #stack.frames, stack.idx + 1, -1 do
        dropped[#dropped + 1] = stack.frames[i]
        stack.frames[i] = nil
    end
    stack.frames[#stack.frames + 1] = frame
    stack.idx = #stack.frames
    return dropped
end

--- Step back one frame. Returns the now-current frame, or nil if already at the
--- root (no move).
---@param stack table
---@return any|nil
function M.back(stack)
    if stack.idx <= 1 then return nil end
    stack.idx = stack.idx - 1
    return stack.frames[stack.idx]
end

--- Step forward one frame. Returns the now-current frame, or nil if already at
--- the tip (no move).
---@param stack table
---@return any|nil
function M.forward(stack)
    if stack.idx >= #stack.frames then return nil end
    stack.idx = stack.idx + 1
    return stack.frames[stack.idx]
end

--- The currently-active frame.
---@param stack table
---@return any
function M.current(stack)
    return stack.frames[stack.idx]
end

--- The back-trail labels, root → current (the breadcrumb, §14.6). The forward
--- tail is hidden so the trail stays minimal. `label_of(frame) -> string`.
---@param stack table
---@param label_of fun(frame: any): string
---@return string[]
function M.crumbs(stack, label_of)
    local out = {}
    for i = 1, stack.idx do
        out[i] = label_of(stack.frames[i])
    end
    return out
end

return M
