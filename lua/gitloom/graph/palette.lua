--- gitloom.graph.palette — the command palette, gitloom's single action menu
--- (spec §17, §10.4).
---
--- Pure: the registry of session-wide commands plus the row / ref context
--- entries, and the one function that turns a context snapshot into the ordered
--- picker entries — context first (the cursor row's actions, or the §13
--- selection's while one is active), then the global commands. A registry
--- entry's `action` takes the graph session (`ctx`) and only calls its methods; a
--- row entry instead carries an `op` (+ its data) that window.lua's `palette`
--- helper runs against the row it resolved. Nothing here touches a window.

local examine = require("gitloom.git.examine")
local selectm = require("gitloom.graph.select")

local M = {}

---@alias PaletteScope "global"|"selection"

---@class PaletteState  the session snapshot the registry's conditions read (§17.1)
---@field examine? ExamineState  the repository's active Checkout & examine (§10.4.2)
---@field has_diff? boolean      a diff provider is configured (§11.5)

---@class PaletteCommand
---@field id string              stable name (`refresh`, `fetch`, `pull`); a
---                              per-remote command's entries are `<id>:<remote>`
---@field label string|fun(st: PaletteState): string  what the picker shows (before
---                              the key hint); a per-remote command's is a format
---                              with one `%s`; a function derives it from the state
---@field key? string            the direct key running the same command, if any
---@field scope PaletteScope     `global`, or `selection` (listed instead of the
---                              row's entries while a §13 selection is active)
---@field per_remote? boolean    expands to one entry per remote (in `git remote`
---                              order), none while the remote list is unknown
---@field when? fun(st: PaletteState): boolean  listed only when it holds
---@field action fun(ctx: table, remote: string?) run on the graph session

local function has_diff(st) return st.has_diff == true end

--- The registry, in palette order within each scope (§17.2). Return leads the
--- global commands: while an examine is active it is the one most likely wanted.
---@type PaletteCommand[]
M.COMMANDS = {
    { id = "selection_diff", label = "Open diff", key = "D", scope = "selection", when = has_diff,
        action = function(ctx) ctx:open_selection_diff() end },
    { id = "examine_selection", label = "Checkout & examine selection", scope = "selection",
        when = has_diff, action = function(ctx) ctx:examine_selection() end },
    { id = "return", scope = "global",
        label = function(st) return examine.return_plan(st.examine).label end,
        when = function(st) return st.examine ~= nil end,
        action = function(ctx) ctx:examine_return() end },
    { id = "refresh", label = "Refresh", key = "R", scope = "global",
        action = function(ctx) ctx:resync(false) end },
    { id = "fetch", label = "Fetch", scope = "global",
        action = function(ctx) ctx:run_remote("fetch") end },
    { id = "fetch", label = "Fetch %s", scope = "global", per_remote = true,
        action = function(ctx, remote) ctx:run_remote("fetch", remote) end },
    { id = "pull", label = "Pull", scope = "global",
        action = function(ctx) ctx:run_remote("pull") end },
}

---@alias PaletteOp "diff"|"checkout"|"checkout_examine"|"collapse"|"expand"|"hide"

---@class PaletteEntry
---@field id string              `refresh`, `fetch:origin`, `collapse`, `hide:2`, …
---@field label string           the picker text, key hint appended: `Refresh  (R)`
---@field action? fun(ctx: table)  a registry command: run on the session
---@field op? PaletteOp          a row entry: what window.lua runs on the row
---@field commit? table          diff / checkout_examine: the real commit to act on
---@field checkout? CheckoutSpec checkout: what to run
---@field marker? integer        expand/hide on a packed line: the marker index

---@class PaletteRow  the cursor row, as window.lua classifies it
---@field kind "plain"|"branch"|"markers"
---@field commit? table          the row's commit (a collapsed head stands for its tip)
---@field ref? SelectedRef       the ref selected with h/l, if any
---@field state? string          `branch_under_cursor`'s state (expanded / collapsed / …)
---@field markers? string[]      a packed line's marker label texts

--- The row / ref entries (§10.4) — what the old `<CR>` menu offered, minus
--- examine (`<CR>` examines directly now). `row.kind`:
---
---  * `"plain"` — a commit's message, no ref selected: diff, checkout, checkout &
---    examine;
---  * `"branch"` — a ref selected, or a collapsed head: collapse+hide (expanded)
---    or expand+hide (collapsed), then diff, checkout, checkout & examine (of the
---    row's commit / the head's tip, §10.4.2);
---  * `"markers"` — a packed line: expand+hide per marker (`row.markers`), then
---    checkout of the selected marker's tip (`row.commit`).
---
--- Open diff and checkout & examine need a diff provider (`has_diff`, §11.5); a
--- §4.2 virtual commit gets neither checkout. Pure.
---@param row PaletteRow?
---@param diff boolean?
---@return PaletteEntry[]
function M.row_entries(row, diff)
    local out = {}
    if not row then return out end
    local function add(e) out[#out + 1] = e end
    local c = selectm.menu_target(row.commit)
    if row.kind == "markers" then
        for i, text in ipairs(row.markers or {}) do
            add({ id = "expand:" .. i, op = "expand", label = "Expand " .. text, marker = i })
            add({ id = "hide:" .. i, op = "hide", label = "Hide " .. text, marker = i })
        end
    elseif row.kind == "branch" then
        if row.state == "expanded" then
            add({ id = "collapse", op = "collapse", label = "Collapse branch" })
            add({ id = "hide", op = "hide", label = "Hide branch" })
        elseif row.state == "collapsed" then
            add({ id = "expand", op = "expand", label = "Expand branch" })
            add({ id = "hide", op = "hide", label = "Hide branch" })
        end
    end
    if c and diff and row.kind ~= "markers" then
        add({ id = "diff", op = "diff", label = "Open diff", commit = c })
    end
    local spec = selectm.checkout_spec(row.commit, row.ref)
    if spec then add({ id = "checkout", op = "checkout", label = spec.label, checkout = spec }) end
    if spec and c and diff and row.kind ~= "markers" then
        add({ id = "checkout_examine", op = "checkout_examine", commit = c,
            label = ("Checkout & examine %s (detached)"):format(c.hash:sub(1, 7)) })
    end
    return out
end

--- The registry entries of `scope` whose `when` holds, each labelled with its key
--- when it has one; a `per_remote` command becomes one entry per name in
--- `remotes` (none when nil — the list has not arrived — or empty). Pure.
---@param commands PaletteCommand[]
---@param scope PaletteScope
---@param remotes string[]?
---@param state PaletteState
---@return PaletteEntry[]
local function scoped(commands, scope, remotes, state)
    local out = {}
    for _, c in ipairs(commands) do
        if c.scope == scope and (not c.when or c.when(state)) then
            local key = c.key and ("  (%s)"):format(c.key) or ""
            if c.per_remote then
                local fmt = c.label --[[@as string]]
                for _, r in ipairs(remotes or {}) do
                    local action = c.action
                    out[#out + 1] = { id = c.id .. ":" .. r, label = fmt:format(r) .. key,
                        action = function(ctx) action(ctx, r) end }
                end
            else
                local label = type(c.label) == "function" and c.label(state) or c.label
                out[#out + 1] = { id = c.id, label = label .. key, action = c.action }
            end
        end
    end
    return out
end

---@class PaletteInfo  everything the palette is built from — a snapshot, never waited on
---@field row? PaletteRow         the cursor row's context (ignored while selecting)
---@field selection? boolean      a §13 selection is active
---@field remotes? string[]       the cached `git remote` names (nil until read)
---@field examine? ExamineState   the repository's active examine (§10.4.2)
---@field has_diff? boolean       a diff provider is configured (§11.5)
---@field commands? PaletteCommand[]  defaults to the registry (a test seam)

--- The palette's entries, in order (§17): the **context** first — the §13
--- selection's entries while one is active, else the cursor row's
--- (`row_entries`) — then the **global** commands. Built only from what the
--- caller already has; never waits on anything. Pure.
---@param info PaletteInfo?
---@return PaletteEntry[]
function M.palette_entries(info)
    info = info or {}
    local commands = info.commands or M.COMMANDS
    local state = { examine = info.examine, has_diff = info.has_diff }
    local out = info.selection and scoped(commands, "selection", info.remotes, state)
        or M.row_entries(info.row, info.has_diff)
    for _, e in ipairs(scoped(commands, "global", info.remotes, state)) do out[#out + 1] = e end
    return out
end

return M
