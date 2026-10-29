-- Persisted view state (spec §18): the global view toggles and each repository's
-- pin list, kept across Neovim sessions in ONE JSON file shared by every instance.
--
-- Two layers. The **pure** half (`config_values`, `overlay`, `set_pref`,
-- `repo_state`, `set_repo`, `pins_for_save`, `clear`) works on a decoded data
-- table and touches nothing. The **I/O** half (`read`, `load`, `update`, `write`)
-- owns the file: a lazy one-time read for opens, and for every change a
-- re-read → merge one key → temp file → rename, so two Neovim instances changing
-- different keys never clobber each other (§18.4). A corrupt or unreadable file is
-- ignored with a single WARN and never fails a graph open.
--
-- The window glue (window.lua) only calls the high-level wrappers at the bottom
-- (`restore_opts`, `save_pref`, `restore_pins`, `save_pins`, `reset`), which also
-- honour the `persist = false` opt-out.

local M = {}

M.VERSION = 1

--- The persisted global view preferences (§18.2), in key-table order.
M.KEYS = {
    "merge_style", "layout_policy", "mirror", "label_mode", "date_mode", "highlight",
    "sort_mode", "collapse_merged", "pack_markers", "panes", "show_lane_ids",
}

--- The built-in default of each persisted key — what the configuration resolves
--- to when `setup()` sets nothing. Mirrors window.lua's `defaults` (the merge style
--- is MERGE_STYLES[1], the sort mode SORT_MODES[1]).
M.BUILTIN = {
    merge_style = { allow_merge_on_split = false, merge_on_separate_line = false, split_on_separate_line = true },
    layout_policy = "compact",
    mirror = true,
    label_mode = "right",
    date_mode = "absolute",
    highlight = true,
    sort_mode = "topo",
    collapse_merged = true,
    pack_markers = true,
    panes = true,
    show_lane_ids = false,
}

-- Keys read as "on unless explicitly false" by the renderer (`opts.x ~= false`).
local DEFAULT_ON = { mirror = true, highlight = true, collapse_merged = true, pack_markers = true, panes = true }

--- Normalise one key's value to the shape that is stored and compared: booleans
--- as booleans (the renderer's own nil reading), a merge style deep-extended over
--- the built-in style, strings as is. nil means "the built-in default".
---@param key string
---@param v any
---@return any
function M.normalize(key, v)
    if key == "merge_style" then
        if type(v) ~= "table" then return vim.deepcopy(M.BUILTIN.merge_style) end
        local out = vim.tbl_extend("force", M.BUILTIN.merge_style, {})
        for k in pairs(M.BUILTIN.merge_style) do
            if v[k] ~= nil then out[k] = v[k] and true or false end
        end
        return out
    end
    if DEFAULT_ON[key] then return v ~= false end
    if key == "show_lane_ids" then return v and true or false end
    if v == nil then return M.BUILTIN[key] end
    return v
end

--- The configuration-resolved value of every persisted key (§18.3): the user's
--- `setup()` / open value, else the built-in default, normalised.
---@param user table?  the options as the caller passed them (NOT merged over defaults)
---@return table<string, any>
function M.config_values(user)
    user = user or {}
    local out = {}
    for _, k in ipairs(M.KEYS) do out[k] = M.normalize(k, user[k]) end
    return out
end

--- Structural equality over JSON-shaped values.
---@return boolean
local function equal(a, b)
    return vim.deep_equal(a, b)
end

--- Is a stored `{ value, base }` entry still valid against the current
--- configuration-resolved value? Its base must equal it and its value must have
--- the same type.
---@param entry any
---@param config any
---@return boolean
local function entry_ok(entry, config)
    return type(entry) == "table" and entry.value ~= nil
        and type(entry.value) == type(config) and equal(entry.base, config)
end

--- Apply the persisted preferences onto `opts` (§18.3): an entry wins only while
--- its `base` equals today's configuration-resolved value. Returns the applied keys.
---@param opts table          the merged graph options (mutated)
---@param config table        config_values() of the caller's options
---@param view table?         the file's `view` table
---@return string[]
function M.overlay(opts, config, view)
    local applied = {}
    if type(view) ~= "table" then return applied end
    for _, k in ipairs(M.KEYS) do
        local e = view[k]
        if entry_ok(e, config[k]) then
            opts[k] = M.normalize(k, vim.deepcopy(e.value))
            applied[#applied + 1] = k
        end
    end
    return applied
end

--- Record one preference in `data` (pure), dropping every OTHER entry whose base
--- no longer matches the configuration (the "pruned on next write" rule).
---@param data table
---@param key string
---@param value any
---@param config table  config_values() — `config[key]` is the stored base
function M.set_pref(data, key, value, config)
    if type(data.view) ~= "table" then data.view = {} end
    for k, e in pairs(data.view) do
        if k ~= key and (config[k] == nil or not entry_ok(e, config[k])) then data.view[k] = nil end
    end
    data.view[key] = { value = M.normalize(key, value), base = config[key] }
end

--- A repository's stored pin state, sanitised: an ordered `PinEntry[]` and the
--- unpinned id set. A `reserved` field on a stored entry — written by an older
--- version (the dropped dedicated-column flag, §18) — is ignored.
---@param data table
---@param root string
---@return PinEntry[] pins, table<string, boolean> unpinned
function M.repo_state(data, root)
    local pins, unpinned = {}, {}
    local r = type(data.repos) == "table" and data.repos[root]
    if type(r) ~= "table" then return pins, unpinned end
    if type(r.pins) == "table" then
        for _, e in ipairs(r.pins) do
            if type(e) == "table" and type(e.id) == "string" then
                pins[#pins + 1] = { id = e.id }
            end
        end
    end
    if type(r.unpinned) == "table" then
        for _, id in ipairs(r.unpinned) do
            if type(id) == "string" then unpinned[id] = true end
        end
    end
    return pins, unpinned
end

--- The pin list as saved (§18.2): drop what the open-time resolution re-derives —
--- the **leading run** of default anchors that still sit in their default order,
--- above every explicitly placed entry, where `pin_resolve` puts them back. A
--- default the user moved below an explicit entry (or out of default order) is
--- kept with its place. Entries are written as `{ id }` alone. The members a pin
--- covers through its identity (§10.6) are never entries, so there is nothing to
--- drop for them.
---@param pins PinEntry[]
---@param defaults string[]?  the default anchor ids at save time, in default order
---@return PinEntry[]
function M.pins_for_save(pins, defaults)
    local pos = {}
    for i, id in ipairs(defaults or {}) do pos[id] = pos[id] or i end
    pins = pins or {}
    local skip, last = 0, 0
    for _, e in ipairs(pins) do
        local p = pos[e.id]
        if not p or p < last then break end
        skip, last = skip + 1, p
    end
    local out = {}
    for i = skip + 1, #pins do
        local e = pins[i]
        out[#out + 1] = { id = e.id }
    end
    return out
end

--- Store a repository's pin state in `data` (pure). An empty state removes the
--- repository's entry.
---@param data table
---@param root string
---@param pins PinEntry[]       already reduced by pins_for_save
---@param unpinned table<string, boolean>
function M.set_repo(data, root, pins, unpinned)
    if type(data.repos) ~= "table" then data.repos = {} end
    local ids = {}
    for id, on in pairs(unpinned or {}) do
        if on then ids[#ids + 1] = id end
    end
    table.sort(ids)
    if #pins == 0 and #ids == 0 then
        data.repos[root] = nil
        return
    end
    data.repos[root] = { pins = pins, unpinned = ids }
end

--- Reset (§18.5), pure: drop the global preferences and `root`'s pin state; other
--- repositories are kept.
---@param data table
---@param root string?
function M.clear(data, root)
    data.view = nil
    if root and type(data.repos) == "table" then data.repos[root] = nil end
end

-- ── I/O ────────────────────────────────────────────────────────────────────────

local path_override = nil
local cache = nil       -- the lazily read data (load())
local warned = {}       -- path → true once a WARN was shown for it

--- The state file's path: `stdpath("state")/gitloom.json`, or the test override.
---@return string
function M.path()
    return path_override or (vim.fn.stdpath("state") .. "/gitloom.json")
end

--- Point the module at another file (tests), or back at the default with nil.
--- Drops the cached read and the one-warning memory.
---@param p string?
function M.set_path(p)
    path_override = p
    cache = nil
    warned = {}
end

local function warn(msg)
    local p = M.path()
    if warned[p] then return end
    warned[p] = true
    vim.notify("gitloom: " .. msg, vim.log.levels.WARN)
end

--- Read and decode the file. A missing file is `{}` silently; an unreadable or
--- corrupt one is `{}` with a single WARN. Never raises.
---@return table data, boolean ok  ok = false when the file existed but was unusable
function M.read()
    local p = M.path()
    local f = io.open(p, "rb")
    if not f then return {}, true end
    local text = f:read("*a")
    f:close()
    if not text or text:match("^%s*$") then return {}, true end
    local ok, data = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
    -- Only a JSON object is a state; an array (or a scalar) is as unusable as junk.
    if not ok or type(data) ~= "table" or (next(data) ~= nil and vim.islist(data)) then
        warn(("ignoring the unreadable view-state file %s"):format(p))
        return {}, false
    end
    return data, true
end

--- The cached data, read once on first use.
---@return table
function M.load()
    if not cache then cache = M.read() end
    return cache
end

--- Write `data` atomically: a temp file in the same directory renamed over the
--- original (on a platform where rename cannot replace, unlink first). Returns
--- false (with one WARN) on failure; never raises.
---@param data table
---@return boolean
function M.write(data)
    local p = M.path()
    data.version = M.VERSION
    local ok, text = pcall(vim.json.encode, data)
    if not ok then
        warn("could not encode the view state: " .. tostring(text))
        return false
    end
    pcall(vim.fn.mkdir, vim.fn.fnamemodify(p, ":h"), "p")
    local uv = vim.uv or vim.loop
    local tmp = ("%s.%d.%d.tmp"):format(p, uv.os_getpid(), uv.hrtime())
    local f = io.open(tmp, "wb")
    if not f then
        warn("could not write the view-state file " .. p)
        return false
    end
    f:write(text)
    f:close()
    local rok = uv.fs_rename(tmp, p)
    if not rok then
        uv.fs_unlink(p)
        rok = uv.fs_rename(tmp, p)
    end
    if not rok then
        uv.fs_unlink(tmp)
        warn("could not replace the view-state file " .. p)
        return false
    end
    return true
end

--- Re-read the file, apply `fn(data)`, write it back, and refresh the cache — so
--- a concurrent instance's keys survive (§18.4).
---@param fn fun(data: table)
---@return boolean
function M.update(fn)
    local data = M.read()
    fn(data)
    local ok = M.write(data)
    cache = data
    return ok
end

-- ── Window-facing wrappers (honour `persist = false`) ───────────────────────────

---@param opts table?
---@return boolean
function M.enabled(opts)
    return not (opts and opts.persist == false)
end

--- On open: overlay the persisted preferences onto the merged `opts`. Returns the
--- configuration-resolved values (kept on the session: the base of every later
--- save, and what Reset restores).
---@param opts table   merged graph options (mutated)
---@param user table?  the caller's own options
---@return table<string, any> config
function M.restore_opts(opts, user)
    local config = M.config_values(user)
    if M.enabled(opts) then M.overlay(opts, config, M.load().view) end
    return config
end

--- Persist one toggled preference.
---@param opts table
---@param config table
---@param key string
function M.save_pref(opts, config, key)
    if not M.enabled(opts) then return end
    local value = opts[key]
    M.update(function(data) M.set_pref(data, key, value, config) end)
end

--- On session creation: the repository's stored pin list + unpinned set.
---@param opts table
---@param root string
---@return PinEntry[] pins, table<string, boolean> unpinned
function M.restore_pins(opts, root)
    if not M.enabled(opts) then return {}, {} end
    return M.repo_state(M.load(), root)
end

--- Persist a repository's pin state.
---@param opts table
---@param root string
---@param pins PinEntry[]
---@param unpinned table<string, boolean>
---@param defaults string[]?  the default anchors at save time (pins_for_save)
function M.save_pins(opts, root, pins, unpinned, defaults)
    if not M.enabled(opts) then return end
    local kept = M.pins_for_save(pins, defaults)
    M.update(function(data) M.set_repo(data, root, kept, unpinned) end)
end

--- Ask before a reset (§18.5): Reset / Cancel through `vim.ui.select`; `on_yes`
--- runs only on Reset.
---@param on_yes fun()
function M.confirm_reset(on_yes)
    vim.ui.select({ "Reset", "Cancel" }, {
        prompt = "Reset gitloom view settings (toggles + this repository's pins)?",
    }, function(choice)
        if choice == "Reset" then on_yes() end
    end)
end

--- Reset (§18.5): clear the global preferences + `root`'s pin state from the file.
---@param opts table?
---@param root string?
function M.reset(opts, root)
    if not M.enabled(opts) then return end
    M.update(function(data) M.clear(data, root) end)
end

return M
