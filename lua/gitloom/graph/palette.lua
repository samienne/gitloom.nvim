--- gitloom.graph.palette — the command palette, gitloom's single action menu
--- (spec §17, §10.4).
---
--- Pure: the registry of session-wide commands plus the row / ref context
--- entries, and the one function that turns a context snapshot into the ordered
--- picker entries — context first (the cursor row's actions, or the §13
--- selection's while one is active), then the global commands, then the graph's
--- keys that apply in that context (§17.1). A registry entry's `action` takes the
--- graph session (`ctx`) and only calls its methods; a row entry instead carries
--- an `op` (+ its data) that window.lua's `palette` helper runs against the row it
--- resolved; a key entry runs the key's handler. The key registry itself lives in
--- window.lua (`GRAPH_KEYS` — its handlers are window locals) and is passed in; the
--- `?` help is generated from it here too (`help_lines`), so neither the palette
--- nor the help can drift from what is bound. Nothing here touches a window.

local examine = require("gitloom.git.examine")
local selectm = require("gitloom.graph.select")

local M = {}

---@alias PaletteScope "global"|"selection"

---@alias KeyGroup "refs"|"view"|"select"|"other"
---@alias KeyContext "commit"|"branch"|"markers"|"selection"

---@class GraphKey  one graph key: bound from, listed in help from, offered in the palette from (§17.1)
---@field key string|string[]    the lhs; a list for aliases (`<C-Space>`/`<C-@>`) — the first is shown
---@field run? fun(ctx: table)   the handler; nil = bound elsewhere (`<C-o>`/`<C-i>`, §14.3), help only
---@field desc string            one line: the mapping's desc, the palette label, the help text
---@field help? string           a longer help text (defaults to `desc`)
---@field group? KeyGroup        the palette / help group; nil = bound and in help, never in the palette
---@field contexts? KeyContext[] where the palette offers it; nil = everywhere
---@field when? fun(st: PaletteState): boolean  offered only when it holds

---@class PaletteState  the session snapshot the registry's conditions read (§17.1)
---@field examine? ExamineState  the repository's active Checkout & examine (§10.4.2)
---@field has_diff? boolean      a diff provider is configured (§11.5)
---@field row? PaletteRow        the cursor row (nil while selecting or with no row)

---@class PaletteCommand
---@field id string              stable name (`fetch`, `pull`, `return`); a
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
--- The resync is not here: it is the `R` key's entry in the key registry.
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
    { id = "fetch", label = "Fetch", scope = "global",
        action = function(ctx) ctx:run_remote("fetch") end },
    { id = "fetch", label = "Fetch %s", scope = "global", per_remote = true,
        action = function(ctx, remote) ctx:run_remote("fetch", remote) end },
    { id = "pull", label = "Pull", scope = "global",
        action = function(ctx) ctx:run_remote("pull") end },
}

---@alias PaletteOp "diff"|"checkout"|"checkout_examine"|"collapse"|"expand"|"hide"

---@class PaletteEntry
---@field id string              `fetch:origin`, `collapse`, `hide:2`, `key:R`, …
---@field label string           the picker text, key hint appended: `Open diff  (D)`
---@field key? string            the key that runs the same thing (its hint is in the label)
---@field action? fun(ctx: table)  a registry command or a key: run on the session
---@field op? PaletteOp          a row entry: what window.lua runs on the row
---@field commit? table          diff / checkout_examine: the real commit to act on
---@field checkout? CheckoutSpec checkout: what to run
---@field marker? integer        expand/hide on a packed line: the marker index

---@class PaletteRow  the cursor row, as window.lua classifies it
---@field kind "plain"|"branch"|"markers"
---@field commit? table          the row's commit (a collapsed head stands for its tip;
---                              a packed line: the selected marker's tip)
---@field ref? SelectedRef       the ref selected with h/l, if any
---@field state? string          `branch_under_cursor`'s state (expanded / collapsed / …)
---@field markers? string[]      a packed line's marker label texts
---@field selected? integer      a packed line: the marker selected with h/l, if any

--- The context a row is (§17.1): `commit` for a plain row, `branch` for a
--- selected ref / collapsed head or a packed line with a marker selected,
--- `markers` for a packed line with none; nil without a row. Pure.
---@param row PaletteRow?
---@return KeyContext?
function M.row_context(row)
    if not row then return nil end
    if row.kind == "plain" then return "commit" end
    if row.kind == "markers" and not row.selected then return "markers" end
    return "branch"
end

---@param label string
---@param key string?
---@return string
local function hinted(label, key)
    return key and ("%s  (%s)"):format(label, key) or label
end

--- The row / ref entries (§10.4), scoped to the row's context (§17.1) — a commit
--- or a branch, never both. `row.kind`:
---
---  * `"plain"` (commit) — open diff (`D`), checkout (detached), checkout &
---    examine;
---  * `"branch"` — a ref selected, or a collapsed head: checkout of the branch (a
---    head's tip), then collapse+hide (expanded) or expand+hide (collapsed), the
---    toggle carrying `<Space>`; no commit diff, no checkout & examine;
---  * `"markers"` — a packed line: with a marker selected (`row.selected`) that
---    marker's checkout (`row.commit`, its tip), expand and hide only; with none,
---    expand+hide per marker (`row.markers`).
---
--- Open diff and checkout & examine need a diff provider (`has_diff`, §11.5); a
--- §4.2 virtual commit gets neither checkout. Pure.
---@param row PaletteRow?
---@param diff boolean?
---@return PaletteEntry[]
function M.row_entries(row, diff)
    local out = {}
    if not row then return out end
    local function add(e)
        e.label = hinted(e.label, e.key)
        out[#out + 1] = e
    end
    local spec = selectm.checkout_spec(row.commit, row.ref)
    local function checkout()
        if spec then add({ id = "checkout", op = "checkout", label = spec.label, checkout = spec }) end
    end
    local function marker(i, text)
        add({ id = "expand:" .. i, op = "expand", label = "Expand " .. text, marker = i })
        add({ id = "hide:" .. i, op = "hide", label = "Hide " .. text, marker = i })
    end
    if row.kind == "plain" then
        local c = selectm.menu_target(row.commit)
        if c and diff then add({ id = "diff", op = "diff", label = "Open diff", key = "D", commit = c }) end
        checkout()
        if spec and c and diff then
            add({ id = "checkout_examine", op = "checkout_examine", commit = c,
                label = ("Checkout & examine %s (detached)"):format(c.hash:sub(1, 7)) })
        end
    elseif row.kind == "markers" then
        local texts = row.markers or {}
        if row.selected then
            checkout()
            marker(row.selected, texts[row.selected] or "")
        else
            for i, text in ipairs(texts) do marker(i, text) end
        end
    elseif row.kind == "branch" then
        checkout()
        if row.state == "expanded" then
            add({ id = "collapse", op = "collapse", label = "Collapse branch", key = "<Space>" })
            add({ id = "hide", op = "hide", label = "Hide branch" })
        elseif row.state == "collapsed" then
            add({ id = "expand", op = "expand", label = "Expand branch", key = "<Space>" })
            add({ id = "hide", op = "hide", label = "Hide branch" })
        end
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
            if c.per_remote then
                local fmt = c.label --[[@as string]]
                for _, r in ipairs(remotes or {}) do
                    local action = c.action
                    out[#out + 1] = { id = c.id .. ":" .. r, label = hinted(fmt:format(r), c.key),
                        key = c.key, action = function(ctx) action(ctx, r) end }
                end
            else
                local label = type(c.label) == "function" and c.label(state) or c.label --[[@as string]]
                out[#out + 1] = { id = c.id, label = hinted(label, c.key), key = c.key, action = c.action }
            end
        end
    end
    return out
end

--- The key groups, in palette and help order (§17.1), with their help headings.
---@type { id: KeyGroup, title: string }[]
M.KEY_GROUPS = {
    { id = "refs", title = "Branches, refs & search" },
    { id = "view", title = "View" },
    { id = "select", title = "Commit & selection" },
    { id = "other", title = "Other" },
}

--- A key entry's lhs list (one, or its aliases with the shown one first). Pure.
---@param k GraphKey
---@return string[]
function M.lhs_of(k)
    local key = k.key
    if type(key) == "table" then return key end
    return { key }
end

--- The key registry's palette entries for `context` (§17.1): only keys with a
--- group and a handler, offered in `context` (no `contexts` = everywhere) whose
--- `when` holds and whose key is not in `taken`; groups in `KEY_GROUPS` order,
--- registry order within a group; labelled `<desc>  (<key>)`. Pure.
---@param keys GraphKey[]
---@param context KeyContext?
---@param state PaletteState
---@param taken table<string, boolean>?
---@return PaletteEntry[]
function M.key_entries(keys, context, state, taken)
    local out = {}
    taken = taken or {}
    for _, g in ipairs(M.KEY_GROUPS) do
        for _, k in ipairs(keys) do
            local lhs = M.lhs_of(k)[1]
            local here = not k.contexts or (context ~= nil and vim.tbl_contains(k.contexts, context))
            if k.group == g.id and k.run and here and not taken[lhs]
                and (not k.when or k.when(state)) then
                local run = k.run --[[@as fun(ctx: table)]]
                out[#out + 1] = { id = "key:" .. lhs, key = lhs, label = hinted(k.desc, lhs),
                    action = function(ctx) run(ctx) end }
            end
        end
    end
    return out
end

--- The `?` help float's lines (§2), generated from the key registry: every key,
--- grouped by `KEY_GROUPS`, then the ungrouped ones (motions and plumbing) under
--- `Motion & misc`; aliases joined with ` / `, the key column aligned; `help`
--- over `desc`. Pure.
---@param keys GraphKey[]
---@return string[]
function M.help_lines(keys)
    local sections = {}
    for _, g in ipairs(M.KEY_GROUPS) do sections[#sections + 1] = { id = g.id, title = g.title } end
    sections[#sections + 1] = { title = "Motion & misc" } -- id nil: the ungrouped keys
    local width = 0
    for _, k in ipairs(keys) do
        width = math.max(width, vim.fn.strdisplaywidth(table.concat(M.lhs_of(k), " / ")))
    end
    local lines = { "gitloom keys" }
    for _, sec in ipairs(sections) do
        local rows = {}
        for _, k in ipairs(keys) do
            if k.group == sec.id then
                local lhs = table.concat(M.lhs_of(k), " / ")
                rows[#rows + 1] = ("  %s%s  %s"):format(lhs,
                    (" "):rep(width - vim.fn.strdisplaywidth(lhs)), k.help or k.desc)
            end
        end
        if #rows > 0 then
            lines[#lines + 1] = ""
            lines[#lines + 1] = sec.title
            vim.list_extend(lines, rows)
        end
    end
    return lines
end

---@class PaletteInfo  everything the palette is built from — a snapshot, never waited on
---@field row? PaletteRow         the cursor row's context (ignored while selecting)
---@field selection? boolean      a §13 selection is active
---@field remotes? string[]       the cached `git remote` names (nil until read)
---@field examine? ExamineState   the repository's active examine (§10.4.2)
---@field has_diff? boolean       a diff provider is configured (§11.5)
---@field keys? GraphKey[]        the key registry (window.lua's `GRAPH_KEYS`); no keys listed when nil
---@field commands? PaletteCommand[]  defaults to the registry (a test seam)

--- The palette's entries, in order (§17): the **context** first — the §13
--- selection's entries while one is active, else the cursor row's
--- (`row_entries`) — then the **global** commands, then the **keys** of the
--- context (`key_entries`), minus any key an earlier entry already shows. Built
--- only from what the caller already has; never waits on anything. Pure.
---@param info PaletteInfo?
---@return PaletteEntry[]
function M.palette_entries(info)
    info = info or {}
    local commands = info.commands or M.COMMANDS
    local state = { examine = info.examine, has_diff = info.has_diff,
        row = not info.selection and info.row or nil }
    local out = info.selection and scoped(commands, "selection", info.remotes, state)
        or M.row_entries(info.row, info.has_diff)
    for _, e in ipairs(scoped(commands, "global", info.remotes, state)) do out[#out + 1] = e end
    if info.keys then
        local taken = {}
        for _, e in ipairs(out) do if e.key then taken[e.key] = true end end
        local context = info.selection and "selection" or M.row_context(info.row)
        for _, e in ipairs(M.key_entries(info.keys, context, state, taken)) do out[#out + 1] = e end
    end
    return out
end

return M
