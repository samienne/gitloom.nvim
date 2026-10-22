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
local sync = require("gitloom.git.sync")
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
---@field remote_log? boolean    a fetch / pull has run in this session — its log exists (§17.4)
---@field row? PaletteRow        the cursor row (nil while selecting or with no row)
---@field newest_at_head? boolean  selecting: the selection's newer end needs no checkout —
---                              HEAD's commit or a §4.2 working-tree node (§10.4.2)

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
    { id = "examine_selection", scope = "selection",
        label = function(st)
            return st.newest_at_head and "Examine selection" or "Checkout & examine selection"
        end,
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
    -- The running or last fetch / pull's output (§17.4); listed once one has run.
    { id = "remote_log", label = "Show fetch log", scope = "global",
        when = function(st) return st.remote_log == true end,
        action = function(ctx) ctx:show_remote_log() end },
    -- Reset (§18.5): clear the persisted view settings + this repository's pins and
    -- restore the configured values live. Asks for confirmation itself.
    { id = "reset_view", label = "Reset view settings…", scope = "global",
        action = function(ctx) ctx:reset_view() end },
}

---@alias PaletteOp "diff"|"checkout"|"checkout_examine"|"examine"|"examine_worktree"|"collapse"|"expand"|"hide"|"fast_forward"|"reset_branch"|"checkout_ff"|"checkout_reset"|"track"|"set_upstream"|"unset_upstream"

---@class PaletteEntry
---@field id string              `fetch:origin`, `collapse`, `hide:2`, `key:R`, …
---@field label string           the picker text, key hint appended: `Open diff  (D)`
---@field key? string            the key that runs the same thing (its hint is in the label)
---@field action? fun(ctx: table)  a registry command or a key: run on the session
---@field op? PaletteOp          a row entry: what window.lua runs on the row
---@field commit? table          diff / checkout_examine / examine: the commit to act on
---                              (examine_worktree: the §4.2 row's node)
---@field checkout? CheckoutSpec checkout: what to run
---@field marker? integer        expand/hide on a packed line: the marker index
---@field sync? SyncTarget       fast_forward / reset_branch: the branch + its upstream (§17.2)
---@field upstream? UpstreamTarget  track / set_upstream / unset_upstream: the branch (§17.2;
---                              `choices` = Set's picker items)
---@field choice? UpstreamChoice track: the remote-tracking branch it sets

---@class PaletteRow  the cursor row, as window.lua classifies it
---@field kind "plain"|"branch"|"markers"
---@field commit? table          the row's commit (a collapsed head stands for its tip;
---                              a packed line: the selected marker's tip)
---@field ref? SelectedRef       the ref selected with h/l, if any
---@field state? string          `branch_under_cursor`'s state (expanded / collapsed / mainline)
---@field own? string            the collapse / expand entry's owners, named (§10.4 —
---                              `select.owner_label` of the row's own owners); nil/"" = "branch"
---@field keepers? string        a collapse's keepers, named: the entry says it stays open via them
---@field markers? string[]      a packed line's marker label texts
---@field selected? integer      a packed line: the marker selected with h/l, if any
---@field head? table            a collapsed head / the selected marker: the node whose
---                              labels the row shows (its region's refs), for the sync's
---                              sole local branch (§17.2)

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
---    examine — **examine** instead when the row is HEAD's commit (`head`, the
---    cached `HEAD` ref's hash; §10.4.2);
---  * `"branch"` — a ref selected, or a collapsed head: checkout of the branch (a
---    head's tip), the branch sync entries (§17.2), then collapse+hide (expanded)
---    or expand+hide (collapsed) — the toggle carrying `<Space>` and naming the
---    row's own owners (`row.own`, `row.keepers`; §10.4); none on mainline; no commit diff,
---    no checkout & examine;
---  * `"markers"` — a packed line: with a marker selected (`row.selected`) that
---    marker's checkout (`row.commit`, its tip), sync entries, expand and hide
---    only; with none, expand+hide per marker (`row.markers`).
---
--- The sync entries (fast-forward / reset to upstream) are for a local branch
--- with an upstream: the h/l-selected ref, else the sole local branch among the
--- row's labels (`row.head`'s refs, else the commit's; `select.sole_local_ref`);
--- offered from the cached tracking counts only. A selected remote branch whose
--- local counterpart (`ref.counterpart`, §10.4.1) tracks it from another commit
--- gets `checkout_ff` / `checkout_reset` (or, when that branch is current, its
--- `fast_forward` / `reset_branch`) first, then the detached checkout.
---
--- The upstream entries (§17.2) act on the same branch — any local one, or a
--- selected remote branch's counterpart: Track `<r>/<b>` (ahead of the sync
--- entries when the label warns of a mismatch, else after them), Set upstream…
--- and Unset upstream; decided from the cached `refs` / `remotes` only.
---
--- Open diff and checkout & examine need a diff provider (`has_diff`, §11.5); a
--- §4.2 virtual commit gets neither checkout but **Examine working tree** (also
--- provider-gated). Pure.
---@param row PaletteRow?
---@param diff boolean?
---@param head string?  HEAD's commit hash, from the cached refs (nil when unknown)
---@param refs table<string, Ref>?  the repo's ref registry — the upstream entries' remote-tracking
---                    branches (§17.2); nil (a test seam) lists no upstream entries
---@param remotes string[]?  the cached `git remote` names (Track's order)
---@return PaletteEntry[]
function M.row_entries(row, diff, head, refs, remotes)
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
    -- The branch the sync and upstream entries act on (§17.2 Which branch).
    local function target_ref()
        return row.ref or selectm.sole_local_ref(row.head or selectm.menu_target(row.commit))
    end
    -- §17.2 Upstream: Track (before the sync when the label warns, `lead`),
    -- then Set upstream… and Unset after the sync.
    local up_offers, up_target
    if refs then
        up_target = sync.upstream_target(target_ref())
        up_offers = sync.upstream_offers(up_target, refs, remotes)
    end
    local function track_entries(lead)
        if not up_target or up_offers.first ~= lead then return end
        for _, c in ipairs(up_offers.track) do
            add({ id = "track:" .. c.name, op = "track", label = (sync.upstream_labels(up_target, c)),
                upstream = up_target, choice = c })
        end
    end
    local function upstream_entries()
        if not up_target then return end
        track_entries(false)
        local _, set_label, unset_label = sync.upstream_labels(up_target)
        local u = vim.tbl_extend("force", up_target, { choices = up_offers.choices })
        add({ id = "set_upstream", op = "set_upstream", label = set_label, upstream = u })
        if up_offers.unset then
            add({ id = "unset_upstream", op = "unset_upstream", label = unset_label, upstream = up_target })
        end
    end
    local function sync_entries()
        local ref = target_ref()
        local t = sync.sync_target(ref)
        local offers = sync.sync_offers(t)
        if not t then return end
        local ff_label, reset_label = sync.sync_labels(t)
        if offers.ff then add({ id = "fast_forward", op = "fast_forward", label = ff_label, sync = t }) end
        if offers.reset then add({ id = "reset_branch", op = "reset_branch", label = reset_label, sync = t }) end
    end
    -- §10.4.1: a remote branch `origin/foo` whose local `foo` sits at another
    -- commit and tracks it — the explicit checkout-and-sync entry (or, when `foo`
    -- is current, its plain §17.2 entries), ahead of the detached checkout that
    -- `checkout_spec` gives such a ref. A non-tracking local: no branch entry.
    local function counterpart_entries()
        local ref = row.ref
        if not ref or ref.kind ~= "remote" then return end
        local cp = ref.counterpart
        if not cp then return end
        local up = cp.upstream
        if not (up and up.ref == "refs/remotes/" .. ref.name) then return end
        local t = sync.sync_target(cp)
        local offers = sync.sync_offers(t)
        if not t then return end
        if cp.current then
            local ff_label, reset_label = sync.sync_labels(t)
            if offers.ff then add({ id = "fast_forward", op = "fast_forward", label = ff_label, sync = t }) end
            if offers.reset then add({ id = "reset_branch", op = "reset_branch", label = reset_label, sync = t }) end
            return
        end
        local ff_label, reset_label = sync.checkout_labels(t)
        if offers.ff then
            add({ id = "checkout_ff", op = "checkout_ff", label = ff_label, sync = t })
        elseif offers.reset then
            add({ id = "checkout_reset", op = "checkout_reset", label = reset_label, sync = t })
        end
    end
    local function marker(i, text)
        add({ id = "expand:" .. i, op = "expand", label = "Expand " .. text, marker = i })
        add({ id = "hide:" .. i, op = "hide", label = "Hide " .. text, marker = i })
    end
    if row.kind == "plain" then
        local c = selectm.menu_target(row.commit)
        if c and diff then add({ id = "diff", op = "diff", label = "Open diff", key = "D", commit = c }) end
        -- A §4.2 working-tree row (clean included): Examine working tree — every
        -- uncommitted change vs HEAD, nothing checked out (§10.4.2). Nothing else:
        -- it has no ref, owner or commit object.
        if c and c.virtual and diff then
            add({ id = "examine_worktree", op = "examine_worktree", commit = c,
                label = "Examine working tree" })
        end
        checkout()
        if spec and c and diff then
            if examine.needs_checkout(c, head) then
                add({ id = "checkout_examine", op = "checkout_examine", commit = c,
                    label = ("Checkout & examine %s (detached)"):format(c.hash:sub(1, 7)) })
            else
                add({ id = "examine", op = "examine", commit = c,
                    label = ("Examine %s"):format(c.hash:sub(1, 7)) })
            end
        end
    elseif row.kind == "markers" then
        local texts = row.markers or {}
        if row.selected then
            checkout()
            track_entries(true)
            sync_entries()
            upstream_entries()
            marker(row.selected, texts[row.selected] or "")
        else
            for i, text in ipairs(texts) do marker(i, text) end
        end
    elseif row.kind == "branch" then
        counterpart_entries()
        checkout()
        track_entries(true)
        sync_entries()
        upstream_entries()
        -- Collapse / expand are <Space>'s (§10.4): they act on the row's own owners,
        -- which the entry names (`own`), and a collapse a branch built on top will
        -- leave open says so (`keepers`). A mainline row has neither entry.
        local own = (row.own and row.own ~= "") and row.own or "branch"
        if row.state == "expanded" then
            local stays = (row.keepers and row.keepers ~= "") and (" (stays open via " .. row.keepers .. ")") or ""
            add({ id = "collapse", op = "collapse", label = "Collapse " .. own .. stays, key = "<Space>" })
            add({ id = "hide", op = "hide", label = "Hide branch" })
        elseif row.state == "collapsed" then
            add({ id = "expand", op = "expand", label = "Expand " .. own, key = "<Space>" })
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
---@field remote_log? boolean     a fetch / pull has run in this session (§17.4)
---@field head? string           HEAD's commit hash, from the cached refs — the commit row's
---                               Examine vs Checkout & examine (§10.4.2); no git spawn
---@field refs? table<string, Ref>  the repo's cached ref registry — the §17.2 upstream entries
---@field newest? table           selecting: the selection's newer end (a real or §4.2 commit)
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
    local state = { examine = info.examine, has_diff = info.has_diff, remote_log = info.remote_log,
        row = not info.selection and info.row or nil,
        newest_at_head = info.selection and info.newest ~= nil
            and not examine.needs_checkout(info.newest, info.head) or nil }
    local out = info.selection and scoped(commands, "selection", info.remotes, state)
        or M.row_entries(info.row, info.has_diff, info.head, info.refs, info.remotes)
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
