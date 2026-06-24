local M = {}

local color = require("gitloom.color")
local submodule = require("gitloom.submodule")

-- Max commits drawn in a submodule change graph before capping (spec §11.7.3);
-- the rest collapse into a "+K more" note.
local SUBMODULE_MAX = 12

-- merge_style presets the viewer cycles through with `m` (see M.open). Each
-- toggles whether merges/splits get their own virtual line, or are folded
-- onto the commit line (inline), plus the experimental allow_merge_on_split.
local MERGE_STYLES = {
    { name = "split on its own line",   style = { allow_merge_on_split = false, merge_on_separate_line = false, split_on_separate_line = true } },
    { name = "merge on its own line",   style = { allow_merge_on_split = false, merge_on_separate_line = true,  split_on_separate_line = false } },
    { name = "merge + split lines",     style = { allow_merge_on_split = false, merge_on_separate_line = true,  split_on_separate_line = true } },
    { name = "inline",                  style = { allow_merge_on_split = false, merge_on_separate_line = false, split_on_separate_line = false } },
    { name = "inline (merge on split)", style = { allow_merge_on_split = true,  merge_on_separate_line = false, split_on_separate_line = false } },
}
local merge_style_index = 1

-- Ref label placements the viewer cycles through with `B` (spec §6.1). `right`
-- pins refs to the right edge (default); `inline` draws them left-aligned before
-- the message on the commit line; `dual` moves them onto their own line above the
-- message. opts.label_mode is the source of truth; this index drives the cycle
-- and the footer label.
local LABEL_MODES = {
    { name = "refs right",        mode = "right" },
    { name = "refs inline",       mode = "inline" },
    { name = "refs on own line",  mode = "dual" },
}
local label_mode_index = 1

-- Whether the per-lane id column (a debug aid) is shown before the message.
-- Hidden by default; toggled with `i` in the graph window (see M.open).
local show_lane_ids = false

-- Remembered cursor position per repository, keyed by Neovim's cwd (which is the
-- repo the graph reflects — git runs in cwd). The value is the hash of the commit
-- under the cursor when the window last closed, so reopening the graph restores
-- the cursor to the same commit instead of re-focusing HEAD (spec §2). In-memory
-- for the Neovim session; not persisted to disk.
local saved_positions = {}

-- Index of the flex (message) column in a row's `line` field: date, author,
-- graph, message. The message fills the remaining width and refs are pinned to
-- the right edge of the row (specification.md §6; see listview's build_line).
local FLEX_COL = 4
-- The author column (index 2). It is given a sticky cap so it only grows up to
-- a max width and doesn't bounce as different-length names scroll past.
local AUTHOR_COL, AUTHOR_MAX = 2, 25
-- The graph column (index 3). Under mirroring it is sticky (only grows) so the
-- right-aligned graph + message don't shift as the lane width changes.
local GRAPH_COL = 3

-- Graph window keybindings — the single source of truth for the `?` help
-- float. Handlers are registered in M.open.
local KEYBINDS = {
    { "q", "Close the graph" },
    { "m", "Cycle the merge/split rendering style" },
    { "M", "Toggle mirroring (lane 1 on the right)" },
    { "B", "Cycle ref label placement (right / inline / own line)" },
    { "<Tab>", "Collapse / expand the branch under the cursor (toggle)" },
    { "<CR>", "Action menu for the row (examine · diff · collapse/expand/hide)" },
    { "D", "Open the commit's diff (external viewer)" },
    { "d", "Toggle absolute / relative dates" },
    { "h/l", "Select previous / next ref on the row" },
    { "H", "Toggle reachability highlighting (dimming)" },
    { "c", "Toggle first-parent focus (collapse non-mainline branches)" },
    { "P", "Pin / unpin the branch under the cursor as an anchor" },
    { "p", "Toggle marker packing (concurrent collapsed heads share a line)" },
    { "F", "Toggle the off-screen context panes (header + footer)" },
    { "K", "Lane breakdown for the commit under the cursor" },
    { "i", "Toggle lane-id debug + the cutoff/seam highlight" },
    { "?", "Show this help" },
}

-- The graph window footer: live status (the current mode, and whether the graph
-- is mirrored) plus a hint to the help float.
---@param mirror boolean?
---@param modes table<string, string>?  -- explicit branch-mode overrides (§10)
---@param focus boolean?  -- the first-parent focus default is on (§10.7)
local function footer_text(mirror, modes, focus, nanchors)
    local status = ("Mode: %s | Refs: %s"):format(
        MERGE_STYLES[merge_style_index].name, LABEL_MODES[label_mode_index].name)
    if focus then
        status = status .. " | focus"
        -- More than the single default anchor (HEAD) ⇒ note the anchor count.
        if nanchors and nanchors > 1 then status = status .. (" (%d anchors)"):format(nanchors) end
    end
    local nc, nh = 0, 0
    for _, m in pairs(modes or {}) do
        if m == "collapsed" then nc = nc + 1 elseif m == "hidden" then nh = nh + 1 end
    end
    if nc > 0 or nh > 0 then
        status = status .. (" (%d collapsed, %d hidden)"):format(nc, nh)
    end
    if mirror then status = status .. "  (mirrored)" end
    return status .. "    ?: help"
end

-- Lines for the `?` help float.
local function help_lines()
    local lines = { "gitloom keys", "" }
    for _, kb in ipairs(KEYBINDS) do
        lines[#lines + 1] = ("  %-2s  %s"):format(kb[1], kb[2])
    end
    return lines
end

local function make_future()
    local state = {
        callback = nil,
        value = nil,
    }

    local future = {
        next = function(fn)
            local future, promise = make_future()

            if state.value then
                vim.schedule(function()
                    promise.resolve(unpack(state.value))
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
            if value and value.next then
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

local function highlight_text(text, hl)
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

-- Reachability dimming (specification.md §12). A dimmed derivative of a
-- highlight group: resolve its fg, blend it toward Normal's bg by the palette's
-- dim factor, and cache a `GitloomDim_*` group with that color. Without
-- truecolor we cannot blend rgb, so fall back to a single flat group.
local DIM_FALLBACK = "NonText"
local dim_cache = {}

---@param fg integer
---@param bg integer
---@param alpha number  fraction blended toward bg (0 = fg, 1 = bg)
---@return integer
local function blend_color(fg, bg, alpha)
    local function chan(f, b)
        return math.floor(f * (1 - alpha) + b * alpha + 0.5)
    end
    local fr, fg2, fb = math.floor(fg / 65536) % 256, math.floor(fg / 256) % 256, fg % 256
    local br, bg2, bb = math.floor(bg / 65536) % 256, math.floor(bg / 256) % 256, bg % 256
    return chan(fr, br) * 65536 + chan(fg2, bg2) * 256 + chan(fb, bb)
end

--- A dimmed version of `group`, blended toward the Normal background by the
--- palette's dim factor (specification.md §12.2). Cached per (group, factor);
--- the cache is cleared on ColorScheme (the derived groups are wiped by
--- `hi clear`). Returns a flat fallback group when truecolor is off.
---@param opts GraphOptions
---@param group string|nil
---@return string|nil
local function dim_hl(opts, group)
    if not group then return nil end
    if not vim.o.termguicolors then return DIM_FALLBACK end
    local factor = (opts.palette and type(opts.palette.dim) == "number") and opts.palette.dim or 0.45
    local key = group .. "\x1f" .. tostring(factor)
    if dim_cache[key] then return dim_cache[key] end

    local ok_src, src = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
    local ok_norm, normal = pcall(vim.api.nvim_get_hl, 0, { name = "Normal", link = false })
    normal = (ok_norm and normal) or {}
    local fg = (ok_src and src and src.fg) or normal.fg
    if not fg then return DIM_FALLBACK end
    -- A transparent colorscheme leaves Normal without a bg; blend toward the
    -- editor's background tone so dimming still preserves hue (not a flat grey).
    local bg = normal.bg or ((vim.o.background == "light") and 0xffffff or 0x000000)

    local name = "GitloomDim_" .. group:gsub("%W", "_") .. "_" .. tostring(math.floor(factor * 100))
    pcall(vim.api.nvim_set_hl, 0, name, { fg = blend_color(fg, bg, factor) })
    dim_cache[key] = name
    return name
end

--- Clear the dim-group cache (the derived groups are wiped by `hi clear` on a
--- ColorScheme change); they are recreated lazily on the next render.
local function reset_dim_cache()
    for k in pairs(dim_cache) do dim_cache[k] = nil end
end

-- Generated lane colours (specification.md §5.5): lane colour slots beyond
-- `#palette.tracks` are overflow colours generated in OKLCH. Each is realised
-- lazily into a cached `GitloomGen_*` highlight group (mirroring dim_hl), wiped
-- and recomputed on ColorScheme. The lightness/chroma anchor is derived once
-- from the curated `tracks` (so generated colours sit in the theme's key).
local gen_cache = {}      -- ordinal -> highlight group name
local gen_anchor = nil    -- { L, C, base_hue } cached anchor

---@param opts GraphOptions
---@return { L: number, C: number, base_hue: number }
local function generated_anchor(opts)
    if gen_anchor then return gen_anchor end
    local tracks = (opts.palette and opts.palette.tracks) or {}
    local explicit = opts.palette and opts.palette.anchor
    local Ls, Cs, first_h = {}, {}, nil
    for _, grp in ipairs(tracks) do
        local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = grp, link = false })
        if ok and hl and hl.fg then
            local L, C, H = color.rgb_to_oklch(hl.fg)
            Ls[#Ls + 1] = L; Cs[#Cs + 1] = C
            first_h = first_h or H
        end
    end
    local function mean(t, d)
        if #t == 0 then return d end
        local s = 0
        for _, v in ipairs(t) do s = s + v end
        return s / #t
    end
    gen_anchor = {
        L = (explicit and explicit.L) or mean(Ls, 0.72),
        C = (explicit and explicit.C) or mean(Cs, 0.12),
        base_hue = (explicit and explicit.base_hue) or first_h or 0,
    }
    return gen_anchor
end

--- Highlight group for the `ordinal`-th generated lane colour (1-based). Without
--- truecolor (where Phase 1 won't mint generated slots anyway) it degrades to a
--- curated colour so nothing renders blank.
---@param opts GraphOptions
---@param ordinal integer
---@return string|nil
local function generated_hl(opts, ordinal)
    local tracks = (opts.palette and opts.palette.tracks) or {}
    if not vim.o.termguicolors then
        return tracks[((ordinal - 1) % math.max(#tracks, 1)) + 1]
    end
    if gen_cache[ordinal] then return gen_cache[ordinal] end
    local rgb = color.generate(generated_anchor(opts), ordinal)
    local name = "GitloomGen_" .. ordinal
    pcall(vim.api.nvim_set_hl, 0, name, { fg = rgb })
    gen_cache[ordinal] = name
    return name
end

--- Clear the generated-colour caches (groups wiped by `hi clear`, and the anchor
--- may shift with the theme); recreated lazily on the next render.
local function reset_gen_cache()
    gen_anchor = nil
    for k in pairs(gen_cache) do gen_cache[k] = nil end
end


--- Classify a full refname into a ref kind and the name to show.
--- Returns nil to skip the ref (e.g. a remote's HEAD symref).
---@param refname string
---@return string|nil kind  "local"|"remote"|"tag"
---@return string|nil name
local function classify_ref(refname)
    local name = refname:match("^refs/heads/(.+)$")
    if name then
        return "local", name
    end
    name = refname:match("^refs/remotes/(.+)$")
    if name then
        if name:match("/HEAD$") then
            return nil -- skip the remote's default-branch symref
        end
        return "remote", name
    end
    name = refname:match("^refs/tags/(.+)$")
    if name then
        return "tag", name
    end
    return nil
end

--- The Commit for `hash`, created as a sparse placeholder if not seen yet.
--- The placeholder is filled in when its `git log` line arrives (identity
--- preserved), so refs and parents can be resolved in any order.
---@param repo Repo
---@param hash string
---@return Commit
local function get_or_create_commit(repo, hash)
    local commit = repo.commits[hash]
    if not commit then
        commit = { hash = hash, parents = {}, children = {}, refs = {} }
        repo.commits[hash] = commit
    end
    return commit
end

--- Resolve a ref to its target Commit and link them (direct references).
---@param repo Repo
---@param name string
---@param kind string
---@param hash string
local function add_ref(repo, name, kind, hash)
    local commit = get_or_create_commit(repo, hash)
    ---@type Ref
    local ref = { name = name, kind = kind, commit = commit }
    commit.refs = commit.refs or {}
    table.insert(commit.refs, ref)
    repo.refs[ref.kind == "head" and "HEAD" or name] = ref
end

--- Read all refs via `git for-each-ref` and resolve each to its commit.
--- Output line: "<objectname> <refname> [<*objectname>]" — the dereferenced
--- hash is present (and used) for annotated tags.
---@param repo Repo
local function fetch_refs(repo)
    local future, promise = make_future()

    vim.fn.jobstart(
        { "git", "for-each-ref", "--format=%(objectname) %(refname) %(*objectname)",
            "refs/heads", "refs/remotes", "refs/tags" },
        {
            stdout_buffered = true,
            on_stdout = function(_, lines)
                for _, line in ipairs(lines) do
                    if line ~= "" then
                        local parts = vim.split(line, " ")
                        local hash, refname, deref = parts[1], parts[2], parts[3]
                        local kind, name = classify_ref(refname or "")
                        if kind and name and hash then
                            local target = (deref and deref ~= "") and deref or hash
                            add_ref(repo, name, kind, target)
                        end
                    end
                end
            end,
            on_exit = function()
                promise.resolve()
            end,
        })

    return future
end

--- Mark the current branch's commit with a `head` ref (skipped when detached).
---@param repo Repo
local function fetch_head(repo)
    local future, promise = make_future()

    vim.fn.jobstart(
        { "git", "symbolic-ref", "--short", "--quiet", "HEAD" },
        {
            stdout_buffered = true,
            on_stdout = function(_, lines)
                local name = lines[1]
                if name and name ~= "" then
                    repo.head = name
                    local localref = repo.refs[name]
                    if localref then
                        add_ref(repo, "HEAD", "head", localref.commit.hash)
                    end
                end
            end,
            on_exit = function()
                promise.resolve()
            end,
        })

    return future
end

--- Parse git's author date into a structured Timestamp (specification.md §4).
--- `epoch_str` is `%at` (Unix time, UTC); `iso` is `%ai` (carries the tz
--- offset, e.g. "2026-06-17 14:23:05 +0300"). The author's local wall-clock is
--- `epoch + offset`.
---@class Timestamp
---@field epoch integer   author date as Unix time (UTC)
---@field offset integer  author tz offset in seconds (e.g. +03:00 -> 10800)
---@field raw string?     original "%ai" text (debug / fallback)
---@param epoch_str string?
---@param iso string?
---@return Timestamp
local function parse_timestamp(epoch_str, iso)
    local epoch = tonumber(epoch_str) or 0
    local offset = 0
    local sign, hh, mm = (iso or ""):match("([%+%-])(%d%d)(%d%d)%s*$")
    if sign then
        offset = (tonumber(hh) * 3600 + tonumber(mm) * 60) * (sign == "-" and -1 or 1)
    end
    return { epoch = epoch, offset = offset, raw = iso }
end

--- Absolute author-local time. Uses os.date in UTC mode ("!") over the
--- offset-shifted epoch so the result is the author's wall-clock, independent
--- of the viewer's timezone.
---@param ts Timestamp
---@param fmt string?
---@return string
local function format_absolute(ts, fmt)
    -- os.date returns string for a string format (osdate only for "*t"); cast so
    -- the annotated string return type holds.
    return os.date("!" .. (fmt or "%Y-%m-%d %H:%M"), ts.epoch + ts.offset) --[[@as string]]
end

local REL_UNITS = {
    { 31536000, "year" }, { 2592000, "month" }, { 604800, "week" },
    { 86400, "day" }, { 3600, "hour" }, { 60, "minute" }, { 1, "second" },
}

--- Relative age, e.g. "3 days ago". `now` is the reference Unix time (passed in
--- so it is testable).
---@param ts Timestamp
---@param now integer
---@return string
local function format_relative(ts, now)
    local diff = now - ts.epoch
    if diff < 1 then return "just now" end
    for _, u in ipairs(REL_UNITS) do
        if diff >= u[1] then
            local n = math.floor(diff / u[1])
            return ("%d %s%s ago"):format(n, u[2], n > 1 and "s" or "")
        end
    end
    return "just now"
end

--- Render a commit's date for display per opts.date_mode (§6).
---@param ts Timestamp?
---@param opts GraphOptions
---@return string
local function format_date(ts, opts)
    if type(ts) ~= "table" then return ts and tostring(ts) or "" end
    if opts.date_mode == "relative" then
        return format_relative(ts, os.time())
    end
    return format_absolute(ts, opts.date_format)
end

--- Group a commit's refs for compact display (specification.md §6). Branch
--- refs (local + remote) that share a short name collapse into one entry: the
--- name once, plus the remotes that also point here. A remote ref's name keeps
--- its `remote/` prefix (classify_ref), so the short name is the part after the
--- first path component. Tags and the HEAD marker stay separate.
---@class RefGroup
---@field name string
---@field has_local boolean
---@field remotes string[]
---@param refs Ref[]?
---@return { head: boolean, branches: RefGroup[], tags: string[] }
local function group_refs(refs)
    local head = false
    local tags = {}
    local by_name = {} -- short name -> RefGroup
    local order = {}   -- short names, first-seen (stable, matches git's order)

    local function group(short)
        if not by_name[short] then
            by_name[short] = { name = short, has_local = false, remotes = {} }
            order[#order + 1] = short
        end
        return by_name[short]
    end

    for _, ref in ipairs(refs or {}) do
        if ref.kind == "head" then
            head = true
        elseif ref.kind == "tag" then
            tags[#tags + 1] = ref.name
        elseif ref.kind == "local" then
            group(ref.name).has_local = true
        elseif ref.kind == "remote" then
            -- "origin/feature/foo" -> remote "origin", short "feature/foo".
            local remote, short = ref.name:match("^([^/]+)/(.+)$")
            if short then
                table.insert(group(short).remotes, remote)
            else
                group(ref.name) -- malformed; show the raw name, no remote
            end
        end
    end

    local branches = {}
    for _, short in ipairs(order) do
        branches[#branches + 1] = by_name[short]
    end
    return { head = head, branches = branches, tags = tags }
end

--- The plain text of each selectable ref decoration on a commit, in selection
--- order (branch groups then tags). The single source of truth so the rendered
--- text and the cursor-target search use byte-identical strings.
---@param commit { refs: Ref[] }?   only the ref list is read
---@return string[]
local function decoration_texts(commit)
    local g = group_refs(commit and commit.refs or {})
    local out = {}
    for _, b in ipairs(g.branches) do
        local t = "(" .. b.name
        if #b.remotes > 0 then
            t = t .. " ↑" .. table.concat(b.remotes, ",")
        end
        out[#out + 1] = t .. ")"
    end
    for _, tag in ipairs(g.tags) do
        out[#out + 1] = "[" .. tag .. "]"
    end
    return out
end

--- The selectable units of a packed marker-group row (spec §10.4): one per
--- marker, its text being the marker's ref decoration(s) or a "(N)" count when
--- it carries no ref. Used for rendering, `h`/`l` selection, and `<CR>` expand.
---@param item OrderItem  -- a type == "markers" item
---@return { marker: table, text: string }[]
local function marker_units(item)
    local units = {}
    for _, m in ipairs(item.markers or {}) do
        local decos = decoration_texts(m)
        local text = (#decos > 0) and table.concat(decos, " ") or ("(" .. (m.count or 0) .. ")")
        units[#units + 1] = { marker = m, text = text }
    end
    return units
end

-- The branch-mode cycle order (spec §10.1), driven by `<CR>` on a selected ref.
local MODE_CYCLE = { "normal", "collapsed", "hidden" }

--- The next mode after `m` in the cycle (nil/normal → collapsed → hidden → …).
---@param m string?
---@return string
local function next_mode(m)
    m = m or "normal"
    for i, v in ipairs(MODE_CYCLE) do
        if v == m then return MODE_CYCLE[(i % #MODE_CYCLE) + 1] end
    end
    return "collapsed"
end

--- The owner ids (repo.refs keys, i.e. view-builder owner ids) a selected ref
--- decoration stands for. A branch group covers its local ref and each remote
--- (`origin/<name>`), so they cycle together as one branch; a tag is itself.
--- Mirrors decoration_texts' order (branch groups then tags). nil if no match.
---@param commit { refs: Ref[] }
---@param index integer  -- 1-based decoration index (selection_state.index)
---@return string[]|nil
local function selected_owner_ids(commit, index)
    if not index then return nil end
    local g = group_refs(commit.refs)
    if index <= #g.branches then
        local b = g.branches[index]
        local ids = {}
        if b.has_local then ids[#ids + 1] = b.name end
        for _, r in ipairs(b.remotes) do ids[#ids + 1] = r .. "/" .. b.name end
        return #ids > 0 and ids or nil
    end
    local tag = g.tags[index - #g.branches]
    return tag and { tag } or nil
end

--- Move the ref selection. `nil` is the message (the default; the message is to
--- the left, refs are pinned to the right edge); 1..count are the ref
--- decorations, left to right. `l` (dir +1) moves right onto the refs starting
--- at the first; `h` (dir -1) moves back left, returning to the message past the
--- first. Clamps at the last decoration; no wrap (spec §2). `count` is the
--- number of decorations.
---@param pos integer|nil
---@param count integer
---@param dir integer
---@return integer|nil
local function move_selection(pos, count, dir)
    if dir > 0 then
        if pos == nil then return count >= 1 and 1 or nil end
        return math.min(count, pos + 1)
    else
        if pos == nil or pos <= 1 then return nil end
        return pos - 1
    end
end

--- Byte column (0-based) of `deco`'s first occurrence in a rendered row, or nil
--- if absent. Used to park the cursor on the selected ref (which the listview
--- pins to the right edge); message parking uses the listview column offset.
---@param line_text string
---@param deco string
---@return integer|nil
local function ref_byte_col(line_text, deco)
    local s = line_text:find(deco, 1, true)
    return s and (s - 1) or nil
end

--- Parse one `git log` line. Fields are `%x1f`-separated:
--- hash, parent hashes, author, epoch (%at), iso date (%ai), subject. Refs are
--- NOT here — they come from `fetch_refs` (§3.2); a fresh commit starts with an
--- empty refs list.
local function parse_commit_line(line)
    local fields = vim.split(line, "\x1f")

    local hash = fields[1]
    local parents = vim.split(fields[2] or "", " ")
    local author = fields[3]
    local date = parse_timestamp(fields[4], fields[5])
    local subject = fields[6]

    if not hash then
        return
    end

    local new_parents = {}
    for _, p in ipairs(parents) do
        if p ~= "" then
            table.insert(new_parents, p)
        end
    end

    return {
        hash = hash,
        parents = new_parents,
        children = {},
        author = author,
        date = date,
        message = subject,
        loaded = true,
        refs = {},
    }
end

--- Stateful line de-chunker for an **unbuffered** `jobstart` stdout stream.
--- Neovim delivers stdout as lists of strings split on "\n": the first element
--- continues the previous chunk's trailing (partial) line, and the last element
--- is itself partial — continued in the next chunk (`:help channel-lines`).
--- `feed(data)` returns the complete lines contained in this chunk; `flush()`
--- returns the final held line at EOF (git's last line has no trailing newline).
--- Pure (no I/O) so it is unit-testable via `_internal`.
---@class LineBuffer
---@field feed fun(data: string[]): string[]
---@field flush fun(): string

---@return LineBuffer
local function make_line_buffer()
    local pending = ""
    return {
        feed = function(data)
            local out = {}
            if #data == 0 then
                return out
            end
            -- Stitch the held partial onto this chunk's first element; hold the
            -- new trailing partial back for the next chunk.
            data[1] = pending .. data[1]
            pending = data[#data]
            for i = 1, #data - 1 do
                out[#out + 1] = data[i]
            end
            return out
        end,
        flush = function()
            local last = pending
            pending = ""
            return last
        end,
    }
end

-- Commits parsed per scheduled worker turn. The stdout handler only enqueues
-- raw lines; a `vim.schedule`d worker drains the queue this many at a time and
-- yields back to the event loop between batches, so the UI stays responsive and
-- redraws as commits stream in (one `on_batch` => one layout + one insert).
local COMMIT_BATCH = 256

--- Stream `git log` and hand commits to `opts.on_batch` in batches as they
--- arrive. The window is already open; this fills it incrementally rather than
--- blocking until the whole log is read (so a large repo paints progressively).
---
--- The stdout handler stays light — it stitches partial lines and enqueues raw
--- text only. A scheduled worker does the per-commit work (`parse_commit_line` +
--- `on_batch`), `COMMIT_BATCH` at a time, rescheduling itself until drained so a
--- big log never stalls the event loop in one callback. The returned future
--- resolves once the stream has closed *and* the queue is fully drained.
---@param opts { branch?: string|string[], count?: integer, on_batch?: fun(commits: Commit[]) }
local function fetch_commits(opts)
    opts = opts or {}

    local future, promise = make_future()

    if opts.branch and type(opts.branch) ~= "table" then
        opts.branch = { opts.branch --[[@as string]] }
    end
    local branch = opts.branch --[[@as string[] ]] or {}

    -- Refs come from fetch_refs (§3.2), so no --decorate here. %at (epoch) +
    -- %ai (carries the tz offset) feed the structured Timestamp (§4).
    local command = { "git", "log", "--topo-order", "--parents", unpack(branch),
        "--pretty=format:%H%x1f%P%x1f%an%x1f%at%x1f%ai%x1f%s" }
    if opts.count then
        table.insert(command, "-n")
        table.insert(command, tostring(opts.count))
    end

    local linebuf = make_line_buffer()
    -- Raw-line queue drained by the worker. An explicit head/tail avoids the
    -- O(n) `table.remove(_, 1)` and the `#queue` ambiguity that niled holes
    -- would create.
    local queue = {}
    local qhead, qtail = 1, 0
    local scheduled = false
    local stream_done = false

    local function process_batch()
        scheduled = false
        local commits = {}
        local stop = math.min(qhead + COMMIT_BATCH - 1, qtail)
        for i = qhead, stop do
            local commit = parse_commit_line(queue[i])
            if commit then
                commits[#commits + 1] = commit
            end
            queue[i] = nil
        end
        qhead = stop + 1

        if #commits > 0 and opts.on_batch then
            opts.on_batch(commits)
        end

        if qhead <= qtail then
            -- More queued (incl. lines that arrived while we worked): yield to
            -- the loop, then continue.
            scheduled = true
            vim.schedule(process_batch)
        elseif stream_done then
            promise.resolve()
        end
    end

    local function schedule_drain()
        if not scheduled then
            scheduled = true
            vim.schedule(process_batch)
        end
    end

    local function enqueue(lines)
        for _, line in ipairs(lines) do
            qtail = qtail + 1
            queue[qtail] = line
        end
    end

    vim.fn.jobstart(
        command,
        {
            on_stdout = function(_, data)
                enqueue(linebuf.feed(data))
                if qhead <= qtail then
                    schedule_drain()
                end
            end,
            on_exit = function()
                local last = linebuf.flush()
                if last ~= "" then
                    enqueue({ last })
                end
                stream_done = true
                if qhead > qtail then
                    -- Nothing left to process — resolve now; otherwise the
                    -- worker resolves once it drains.
                    promise.resolve()
                else
                    schedule_drain()
                end
            end,
        })

    return future
end

--- The rendered lines of an OrderItem in display order (split / commit / merge),
--- skipping absent ones. A plain `{item.split, item.columns, item.merge}` can't be
--- `ipairs`-ed because a nil `split` truncates the list.
---@param item OrderItem|nil
---@return GraphColumn[][]
local function item_lines(item)
    local out = {}
    if not item then return out end
    if item.split then out[#out + 1] = item.split end
    if item.columns then out[#out + 1] = item.columns end
    if item.merge then out[#out + 1] = item.merge end
    return out
end


--- Build the full graph layout from an ordered list of items, from scratch.
--- Pure and deterministic (fresh lane-id sequence each call). Returns new row
--- tables (does not mutate the inputs). This is the reflow primitive and the
--- entry point for tests.
---@param opts GraphOptions
---@param items OrderItem[]   ordered items, each carrying a wired `.commit`
---@return OrderItem[]
local function build_graph(opts, items)
    -- Phase 1 of the two-phase pipeline (see lua/gitloom/columns.lua): lane
    -- layout into columns with per-segment connectivity, validated for continuity.
    -- Phase 2 (get_column_chars) renders glyphs/colour from the segments.
    return require("gitloom.columns").layout(opts, items)
end

---@class Ref
---@field name string
---@field kind "local"|"remote"|"tag"|"head"
---@field commit Commit   the commit this ref points at (a direct reference)

--- A node in the commit DAG. `hash`/`parents`/`children`/`refs` exist from the
--- moment a commit is created (a ref or another commit's parent can create it as
--- a placeholder); `author`/`date`/`message` are filled in lazily when its own
--- `git log` line arrives (`loaded` then becomes true), so they are optional.
---@class Commit
---@field hash string
---@field parents Commit[]|string[]   parent hashes from `git log`, resolved to Commits
---@field children Commit[]           back-links, set as children stream in
---@field refs Ref[]
---@field author? string
---@field date? Timestamp
---@field message? string
---@field loaded? boolean   true once the commit's own log line has been parsed
---@field deco? string      raw `%d` ref decoration, only on submodule-view commits (§11.7)
--- View-builder fields, present only on a synthetic **collapsed head** node
--- (specification.md §10.3); a real commit leaves them nil. The head flows
--- through `OrderItem.commit`/`GraphColumn.commit` as a commit-like node.
---@field collapsed? boolean  marks a collapsed head (a contracted region)
---@field junction? boolean   a collapsed-region fork/merge kept for topology (§10.4)
---@field tip? Commit         the region's newest member (for the date/author/subject)
---@field count? integer      number of commits the head contracts
---@field region? string[]    member hashes a head contracts (for cursor-follow)
---@field signature? table<string, boolean>  owner ids reaching the region (for expand)

---@class Connectivity
---@field up boolean
---@field down boolean
---@field left boolean
---@field right boolean

--- A **Lane** is one drawn edge, child -> parent (specification.md §5). `begin`
--- is the child (above), `parent` the parent/end (below); `id` drives colour;
--- `highlighted` marks it for the reachability emphasis (§12). One Lane per
--- parent/child edge, shared by every Segment that draws it.
---@class Lane
---@field id integer|nil
---@field color integer|nil   palette slot (1-based) from the free list; drives colour
---@field begin Commit
---@field parent Commit
---@field highlighted boolean

--- A **Segment** is one wire within a `GraphColumn`: its connectivity plus the
--- Lane(s) it draws (a list — usually one, but a shared fan bus carries the set
--- of edges routing through it).
---@class Segment
---@field id integer|nil
---@field color integer|nil   palette slot of the Lane(s) this wire draws
---@field connectivity Connectivity
---@field begin? Commit
---@field parent? Commit
---@field edges? Lane[]   the edge(s) this wire draws (§5)

---@class GraphColumn
---@field id integer|nil
---@field color integer|nil   palette slot for the cell's glyph colour
---@field connectivity Connectivity
---@field has_commit boolean
---@field commit? Commit
---@field begin? Commit   the child end of this wire's edge (lane begin); §5
---@field parent? Commit  the parent end of this wire's edge (lane end); §5
---@field override? string
---@field lanes? Segment[]  per-wire decomposition of the cell (Segments; §5)
---@field active? boolean  commit-marker emphasis state, set by mark_reachable (§12)

---@class OrderItem
---@field type "commit"|"merge"|"split"|"markers"
---@field commit? Commit
---@field markers? Commit[]  the packed marker DisplayNodes on a "markers" row (§10.4)
---@field columns GraphColumn[]
---@field split? GraphColumn[]
---@field merge? GraphColumn[]
---@field parent_lanes? Lane[]  edges out to this commit's parents (§5)
---@field child_lanes? Lane[]   edges in from this commit's children (§5)

--- Re-run Phase 1 over the whole order and copy the fresh lines/lanes back into
--- the existing OrderItems (the view holds references to them). `start_pos` is
--- ignored — the lane layout (with compaction) is global, so a partial relayout
--- would be incorrect; a full rebuild is simplest and cheap enough here.
---@param opts GraphOptions
---@param order OrderItem[]
local function refresh_columns(opts, order, _start_pos)
    local rebuilt = require("gitloom.columns").layout(opts, order)
    for i = 1, #order do
        local r = rebuilt[i]
        order[i].columns = r.columns
        order[i].split = r.split
        order[i].merge = r.merge
        order[i].parent_lanes = r.parent_lanes
        order[i].child_lanes = r.child_lanes
    end
end

--- Pack adjacent **marker** rows (collapsed heads, spec §10.4) that overlay
--- cleanly into one *marker-group* row, so concurrent collapsed branches share a
--- line. Conservative: across the group a column may hold at most one node and
--- one lane id, and any overlapping (≥2-row) column must be horizontal-free —
--- anything else ends the group. Compaction already makes only the safe merges
--- compatible (a turn between two rows breaks vertical continuity). The packed
--- grid is validated by the same wires-connect checker the layout uses.
---@param items OrderItem[]
---@return OrderItem[]
local function pack_markers(items)
    local function is_marker(it)
        return it.commit ~= nil and it.commit.collapsed and it.split == nil and it.merge == nil
    end

    -- Overlay group rows into one columns array; nil if any column is incompatible.
    local function overlay(group)
        local width = 0
        for _, it in ipairs(group) do
            if #it.columns > width then width = #it.columns end
        end
        local cols = {}
        for c = 1, width do
            local node_cell, lane_id, occ, has_h, seg = nil, nil, 0, false, nil
            for _, it in ipairs(group) do
                local cell = it.columns[c]
                if cell and (cell.has_commit or (cell.lanes and #cell.lanes > 0)) then
                    occ = occ + 1
                    if cell.has_commit then
                        if node_cell then return nil end -- two nodes in one column
                        node_cell = cell
                    end
                    for _, s in ipairs(cell.lanes or {}) do
                        seg = seg or s
                        if lane_id == nil then
                            lane_id = s.id
                        elseif lane_id ~= s.id then
                            return nil -- two distinct lanes in one column
                        end
                    end
                    local cc = cell.connectivity
                    if cc and (cc.left or cc.right) then has_h = true end
                end
            end
            if occ >= 2 and has_h then return nil end -- overlapping content + a turn
            -- up from the topmost row, down from the bottom row; horizontals only
            -- from a sole occupant (rejected above when overlapping).
            local top, bot = group[1].columns[c], group[#group].columns[c]
            local conn = {
                up = (top and top.connectivity and top.connectivity.up) or false,
                down = (bot and bot.connectivity and bot.connectivity.down) or false,
                left = false,
                right = false,
            }
            if occ == 1 then
                for _, it in ipairs(group) do
                    local cell = it.columns[c]
                    if cell and (cell.has_commit or (cell.lanes and #cell.lanes > 0)) then
                        conn.left = cell.connectivity.left or false
                        conn.right = cell.connectivity.right or false
                    end
                end
            end
            local lanes = {}
            if seg then
                lanes[1] = {
                    id = seg.id, color = seg.color, begin = seg.begin, parent = seg.parent,
                    connectivity = conn, edges = seg.edges,
                }
            end
            cols[c] = {
                connectivity = conn,
                lanes = lanes,
                has_commit = node_cell ~= nil,
                commit = node_cell and node_cell.commit or nil,
                id = seg and seg.id or nil,
                color = seg and seg.color or nil,
                begin = seg and seg.begin or nil,
                parent = seg and seg.parent or nil,
            }
        end
        return cols
    end

    local out = {}
    local i = 1
    while i <= #items do
        if is_marker(items[i]) then
            local group, merged, j = { items[i] }, items[i].columns, i + 1
            while j <= #items and is_marker(items[j]) do
                local cand = vim.list_extend({}, group)
                cand[#cand + 1] = items[j]
                local m = overlay(cand)
                if not m then break end
                group, merged, j = cand, m, j + 1
            end
            if #group == 1 then
                out[#out + 1] = items[i]
            else
                local markers = {}
                for _, g in ipairs(group) do markers[#markers + 1] = g.commit end
                ---@type OrderItem
                out[#out + 1] = { type = "markers", markers = markers, columns = merged }
            end
            i = j
        else
            out[#out + 1] = items[i]
            i = i + 1
        end
    end
    return out
end

--- The owner ids whose collapse turns the region containing a shown commit into
--- a marker (spec §10.4): every non-anchor owner currently keeping it visible.
--- Returns nil when the commit is **mainline** (a pinned anchor reaches it, so it
--- can't be collapsed) or nothing normal keeps it visible. Used by the `<Tab>`
--- collapse toggle and the `<CR>` menu to act on the region under the cursor
--- without needing a ref.
---@param sig table<string, boolean>?  -- the commit's signature (owner id set)
---@param pinned table<string, boolean>?  -- the anchor owner ids (§10.6)
---@param effective table<string, string>  -- owner id → effective mode
---@return string[]|nil
local function collapse_owners(sig, pinned, effective)
    if not sig then return nil end
    pinned = pinned or {}
    for pid in pairs(pinned) do
        if sig[pid] then return nil end -- on an anchor's line: not collapsible
    end
    local out = {}
    for oid in pairs(sig) do
        if not pinned[oid] and (effective[oid] or "normal") == "normal" then
            out[#out + 1] = oid
        end
    end
    return (#out > 0) and out or nil
end

--- Owners for the view builder (specification.md §10): one per ref, carrying
--- its current mode. The `HEAD` marker is skipped — it is a symref onto a branch
--- already present as its own owner, not an independent branch. The owner id is
--- the ref's table key (its name), so a mode keyed by that name survives reflow.
---@param refs table<string, Ref>
---@param modes table<string, string>  -- ref name → "normal"|"collapsed"|"hidden"
---@return table[]  -- { id, tip = Commit, mode }
local function owners_from_refs(refs, modes)
    local out = {}
    for name, ref in pairs(refs) do
        if ref.kind ~= "head" and ref.commit then
            out[#out + 1] = { id = name, tip = ref.commit, mode = modes[name] or "normal" }
        end
    end
    return out
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

--- Whether a Segment draws any highlighted edge (specification.md §12).
---@param seg Segment
---@return boolean
local function seg_hl(seg)
    for _, e in ipairs(seg.edges or {}) do
        if e.highlighted then return true end
    end
    return false
end

--- The palette slot a Segment renders in: with `emphasis`, a highlighted edge's
--- colour wins (so the cone colour shows); otherwise (and as the fallback) the
--- segment's own slot — so colour is pivot-independent when emphasis is off.
---@param seg Segment|nil
---@param emphasis boolean|nil
---@return integer|nil
local function seg_color(seg, emphasis)
    if not seg then return nil end
    if emphasis then
        for _, e in ipairs(seg.edges or {}) do
            if e.highlighted and e.color then return e.color end
        end
    end
    return seg.color
end

--- The "top" Segment a Column's glyph takes its colour/dim from. With
--- `emphasis`, prefers a highlighted Segment so the cone colour wins a shared
--- cell (§12.2): a highlighted vertical (down then up), then a single-sided
--- fan/branch stub, then a both-sided bus when the cell has no through-vertical
--- (a ┴/┬ fan, never a │ crossing). Without emphasis (or as fallback) it is the
--- plain §5 down-before-up order, so the picture is pivot-independent.
---@param segs Segment[]|nil
---@param emphasis boolean|nil
---@return Segment|nil
local function top_lane(segs, emphasis)
    if not segs then return nil end
    if emphasis then
        for _, s in ipairs(segs) do
            if seg_hl(s) and s.connectivity.down then return s end
        end
        for _, s in ipairs(segs) do
            if seg_hl(s) and s.connectivity.up then return s end
        end
        for _, s in ipairs(segs) do
            local l, r = s.connectivity.left, s.connectivity.right
            if seg_hl(s) and (l or r) and not (l and r) then return s end
        end
        local has_through = false
        for _, s in ipairs(segs) do
            if s.connectivity.up and s.connectivity.down then has_through = true break end
        end
        if not has_through then
            for _, s in ipairs(segs) do
                if seg_hl(s) and s.connectivity.left and s.connectivity.right then return s end
            end
        end
    end
    for _, s in ipairs(segs) do
        if s.connectivity.down then return s end
    end
    for _, s in ipairs(segs) do
        if s.connectivity.up then return s end
    end
    return segs[1]
end

--- Mirror a row's cells for right-aligned rendering (specification.md §5.4).
--- Reverses the column order (so lane 1 becomes the rightmost column, nearest
--- the message) and swaps each cell's left/right connectivity. Because the
--- glyph is a pure function of connectivity (get_column_chars), the mirrored
--- glyphs (╭↔╮, ┤↔├, ╴↔╶) and the inter-lane connectors fall out automatically
--- — no glyph-swap table. Color is unaffected (it comes from each lane's
--- up/down). Returns a fresh array; the model rows are left untouched.
---@param columns GraphColumn[]
---@return GraphColumn[]
local function mirror_columns(columns)
    local out = {}
    for i = #columns, 1, -1 do
        local t = columns[i]
        local c = t.connectivity
        local m = {}
        for k, v in pairs(t) do m[k] = v end
        m.connectivity = { up = c.up, down = c.down, left = c.right, right = c.left }
        out[#out + 1] = m
    end
    return out
end

--- A vertical-only projection of a commit line's columns (spec §6.1). Every lane
--- continuing in direction `dir` — `"up"` (entering from above) or `"down"`
--- (leaving below; the dual-mode message row) — becomes a straight `│` in its own
--- colour; every other column is blank. No node and no horizontal wires, so
--- labels / the message sit cleanly to the right of the continuing graph. Each
--- synthesized Segment keeps the original's `edges` and `color` so the
--- reachability dimming (§12) and colour still apply. Fed through
--- `get_column_chars` like any row (mirroring included).
---@param columns GraphColumn[]
---@param dir? "up"|"down"   which lanes to continue (default "up")
---@return GraphColumn[]
local function passthrough_columns(columns, dir)
    dir = dir or "up"
    local out = {}
    for _, t in ipairs(columns or {}) do
        if t.connectivity and t.connectivity[dir] then
            local lanes = {}
            for _, s in ipairs(t.lanes or {}) do
                if s.connectivity and s.connectivity[dir] then
                    lanes[#lanes + 1] = {
                        connectivity = { up = true, down = true },
                        edges = s.edges,
                        color = s.color,
                    }
                end
            end
            out[#out + 1] = {
                connectivity = { up = true, down = true },
                color = t.color,
                lanes = lanes,
                has_commit = false,
            }
        else
            out[#out + 1] = { connectivity = {}, lanes = {}, has_commit = false }
        end
    end
    return out
end

local function get_column_chars(opts, columns, emphasis)
    -- Right-aligned mirror: flip the cells before deriving glyphs. The graph
    -- column is then right-aligned by the listview (fix_width align = "right").
    if opts.mirror then
        columns = mirror_columns(columns)
    end

    local result = {}

    for i = 1, #columns do
        local track = columns[i]
        local next = columns[i + 1]

        -- A *crossing* is a clean through-horizontal wire passing across a
        -- vertically-continuous cell (a `│` the wire crosses). It is left whole
        -- so a passing cone wire never truncates it; only real junctions — whose
        -- arms all *turn* (no straight left↔right lane) — drop their dim arms and
        -- draw `┼`. The vertical may be one through-lane or, at a merge handoff
        -- (allow_merge_on_split), separate up/down turns sharing the column: the
        -- horizontal still passes over, so the cell stays a crossing, not a `┼`.
        local cross_h = false
        for _, s in ipairs(track.lanes or {}) do
            if s.connectivity.left and s.connectivity.right then cross_h = true end
        end
        local is_crossing = cross_h and track.connectivity.up and track.connectivity.down
        -- A kept junction (§10.4) is drawn node-less — its cell renders the fork/
        -- merge as box-drawing lanes, not a commit node — so the split topology
        -- shows without the commit's weight. Disabled by opts.junction_markers.
        local is_node = track.has_commit
            and not (opts.junction_markers ~= false and track.commit and track.commit.junction)

        -- The glyph's connectivity: the full cell by default, but under emphasis a
        -- real junction keeps only the arms its *highlighted* Segments draw (each
        -- Segment is one edge; build_fan), so off-cone arms gap out. A uniformly
        -- dim cell and a crossing keep their full glyph.
        ---@type Connectivity
        local c = {
            left = track.connectivity.left,
            right = track.connectivity.right,
            up = track.connectivity.up,
            down = track.connectivity.down,
        }
        if emphasis and not is_node and not is_crossing then
            local hc, any = { up = false, down = false, left = false, right = false }, false
            for _, s in ipairs(track.lanes or {}) do
                if seg_hl(s) then
                    any = true
                    local sc = s.connectivity
                    if sc.up then hc.up = true end
                    if sc.down then hc.down = true end
                    if sc.left then hc.left = true end
                    if sc.right then hc.right = true end
                end
            end
            if any then
                if opts.mirror then hc.left, hc.right = hc.right, hc.left end
                c = hc
            end
        end

        local char = " "
        -- Colour (and dim state) from the Column's "top" Segment (§5): the
        -- Segment whose edge colours the glyph (a highlighted edge wins, but
        -- only with emphasis — so the picture is unchanged when it is off).
        local color_seg = top_lane(track.lanes, emphasis)
        local track_color = seg_color(color_seg, emphasis)
        if track.override ~= nil then
            char = track.override
        elseif is_node then
            -- "⏺". A collapsed head (spec §10.3) gets its own glyph so a
            -- contracted region reads differently from a real commit.
            char = track.commit.collapsed and "◍" or
                (#track.commit.parents == 0) and "◎" or
                not opts.merge_style.merge_on_separate_line and (#track.commit.parents > 1) and opts.icons.merge or
                (#track.commit.children == 0) and "◉" or "○"
            --"o"
        elseif c.left and c.right and not c.up and not c.down then
            char = "─"
            -- ═
        elseif c.left and c.up and not c.right and c.down then
            char = "┤"
            -- ╡
        elseif not c.left and c.up and c.right and c.down then
            char = "├"
        elseif c.left and c.up and c.right and not c.down then
            char = "┴"
            -- ╧
        elseif c.left and not c.up and c.right and c.down then
            char = "┬"
            -- ╤─┬
        elseif c.left and c.up and not c.right and not c.down then
            --char = "┘"
            char = "╯"
        elseif not c.left and not c.up and c.right and c.down then
            --char = "┌"
            char = "╭"
        elseif not c.left and c.up and not c.right and not c.down then
            char = "^"
        elseif c.left and not c.up and not c.right and c.down then
            --char = "┐"
            char = "╮"
        elseif not c.left and c.up and c.right and not c.down then
            char = "╰"
        elseif c.left and not c.up and not c.right and not c.down then
            char = "╴"
        elseif not c.left and not c.up and c.right and not c.down then
            char = "╶"
        elseif not c.left and c.up and not c.right and not c.down then
            char = "╵"
        elseif not c.left and not c.up and not c.right and c.down then
            char = "╷"
        elseif c.up and c.down and c.left and c.right and not is_crossing then
            char = "┼" -- a node-less junction fanning both sides (§10.4)
        elseif c.up and c.down then
            -- A real crossing (an independent through-horizontal over this
            -- vertical) stays "│"; the horizontal passes across it (it is not a
            -- junction). Only genuine 4-way junctions reach "┼" above.
            char = "│"
        elseif not c.left and not c.up and not c.right and not c.down then
            char = " " -- empty column (allowed; e.g. a gap awaiting compaction)
        else
            char = "x"
            vim.notify(vim.inspect(c))
        end

        --- Resolve a palette slot (1-based, from Phase 1's free list) to its
        --- highlight group: a curated slot indexes `palette.tracks`; a slot beyond
        --- the curated set is a generated OKLCH colour (§5.5).
        ---@param slot integer|nil
        ---@return string?
        local get_highlight = function(slot)
            if not slot then return nil end
            local n = #opts.palette.tracks
            if slot <= n then return opts.palette.tracks[slot] end
            return generated_hl(opts, slot - n)
        end

        -- Reachability dimming (§12): a cell outside the cone renders its colour
        -- blended toward the background. The commit marker follows its commit
        -- (track.active, set by mark_reachable); other glyphs follow whether
        -- their colour Segment draws a highlighted edge. `emphasis` is false when
        -- the feature is off / no pivot, so everything renders lit.
        local cell_active
        if not emphasis then
            cell_active = true
        elseif track.has_commit then
            cell_active = track.active ~= false
        else
            cell_active = not color_seg or seg_hl(color_seg)
        end
        local cell_hl = get_highlight(track_color)
        if not cell_active then cell_hl = dim_hl(opts, cell_hl) end
        result = compose({ result, highlight_text(char, cell_hl) })

        -- Connector colour: the lane its horizontal run terminates at, found by
        -- scanning past pass-through crossings/jumps — to the right normally, to
        -- the left once mirrored (cells reversed), so the scan flips direction
        -- (§5.4). Keeping this lookahead preserves colour continuity along a run.
        local function real_color(j)
            local t = columns[j]
            if not t then return nil end
            local cc = t.connectivity
            local is_cross = cc.down and cc.up and cc.left and cc.right
            local is_jump = not cc.down and not cc.up and cc.right and cc.left
            if is_cross or is_jump then return false end
            return t.color
        end
        local next_color
        local from, to, step = i + 1, #columns, 1
        if opts.mirror then from, to, step = i, 1, -1 end
        for j = from, to, step do
            local color = real_color(j)
            if color ~= false then next_color = color; break end
        end

        -- Connector dim/colour: it lights iff a *highlighted* Segment leaves this
        -- cell toward the next (visual right — which is the unmirrored "left" once
        -- mirrored reverses the cells). Its colour is that cone edge's, else the
        -- run's terminating lane (continuity).
        local conn_dir = opts.mirror and "left" or "right"
        local conn_lit, conn_color = false, next_color
        if emphasis then
            for _, s in ipairs(track.lanes or {}) do
                if s.connectivity[conn_dir] and seg_hl(s) then
                    conn_lit = true
                    for _, e in ipairs(s.edges or {}) do
                        if e.highlighted and e.color then conn_color = e.color; break end
                    end
                    break
                end
            end
        end

        if next ~= nil and (track.connectivity.right and next.connectivity.left) then
            local hl = get_highlight(conn_color)
            if emphasis and not conn_lit then hl = dim_hl(opts, hl) end
            result = compose({ result, highlight_text("─", hl) })
        elseif next ~= nil and (track.connectivity.right and not next.connectivity.left) then
            result = compose({ result, "╴" })
        elseif next ~= nil and (not track.connectivity.right and next.connectivity.left) then
            result = compose({ result, "╶" })
        else
            result = compose({ result, " " })
        end
    end

    -- Mirrored graphs right-align the column so lane 1 hugs the message edge and
    -- vertical wires stay column-aligned across rows (see fix_width).
    if opts.mirror then
        result.align = "right"
    end

    return result
end

--- The pivot's causal cone (specification.md §12.1): the commit at
--- order[pivot_index] plus its ancestors (a parent-only sweep) and descendants
--- (a child-only sweep), each monotonic, restricted to commits in the visible
--- rows top..bottom (the window bound). Returns a set keyed by Commit, pivot
--- included. Pure (no view/IO).
---@param order OrderItem[]
---@param pivot_index integer
---@param top integer
---@param bottom integer
---@return table<Commit, boolean>
local function reachable_cone(order, pivot_index, top, bottom)
    local cone = {}
    local pivot_item = order[pivot_index]
    local pivot = pivot_item and pivot_item.commit
    if not pivot then return cone end

    -- Only on-screen commits are eligible (§12.1: compute over visible rows).
    local visible = {}
    for i = top, bottom do
        local it = order[i]
        if it and it.commit then visible[it.commit] = true end
    end
    if not visible[pivot] then return cone end

    cone[pivot] = true

    -- Ancestors: a single sweep following parent links only.
    local stack = { pivot }
    while #stack > 0 do
        local c = table.remove(stack)
        for _, p in ipairs(c.parents or {}) do
            if visible[p] and not cone[p] then
                cone[p] = true
                stack[#stack + 1] = p
            end
        end
    end

    -- Descendants: a single sweep following child links only.
    stack = { pivot }
    while #stack > 0 do
        local c = table.remove(stack)
        for _, ch in ipairs(c.children or {}) do
            if visible[ch] and not cone[ch] then
                cone[ch] = true
                stack[#stack + 1] = ch
            end
        end
    end

    return cone
end

--- Mark the reachability emphasis from the pivot (specification.md §12) by
--- walking the **Lane graph**: from the pivot commit, follow `parent_lanes`
--- (ancestors) then `child_lanes` (descendants), setting `highlighted` on each
--- Lane reached and `active` on each cone commit's marker. Bounded to the
--- visible rows top..bottom. Returns the cone commit set (drives the row-field
--- dimming, §12.2). Exact: each Lane is one edge, so a sibling sharing a fan is
--- a distinct Lane and never lights. Assumes Phase 1 (columns.layout) has run,
--- so each OrderItem carries its `parent_lanes`/`child_lanes`.
---@param order OrderItem[]
---@param pivot_index integer
---@param top integer
---@param bottom integer
---@return table<Commit, boolean>
local function mark_reachable(order, pivot_index, top, bottom)
    local item_of, visible = {}, {}
    for i = top, bottom do
        local it = order[i]
        if it and it.commit then
            item_of[it.commit] = it
            visible[it.commit] = true
        end
    end

    -- Reset: clear the highlight on every Lane *drawn* in the window (via each
    -- Segment's edges, so a pass-through lane whose endpoints are off-window is
    -- cleared too) and the incident edges of every visible commit; dim every
    -- commit marker.
    for i = top, bottom do
        local it = order[i]
        if it then
            for _, l in ipairs(it.parent_lanes or {}) do l.highlighted = false end
            for _, l in ipairs(it.child_lanes or {}) do l.highlighted = false end
            for _, line in ipairs(item_lines(it)) do
                for _, t in ipairs(line) do
                    for _, s in ipairs(t.lanes or {}) do
                        for _, e in ipairs(s.edges or {}) do e.highlighted = false end
                    end
                    if t.has_commit then t.active = false end
                end
            end
        end
    end

    local cone = {}
    local pivot = order[pivot_index] and order[pivot_index].commit
    if not pivot or not visible[pivot] then return cone end
    cone[pivot] = true

    -- Every parent edge of an ancestor leads to a deeper ancestor, so all of a
    -- reached commit's parent_lanes are cone edges — highlight them even when the
    -- parent is off-window (its visible stub still lights); only recurse into
    -- on-window parents. Symmetric for descendants via child_lanes.
    local stack = { pivot } -- ancestors
    while #stack > 0 do
        local it = item_of[table.remove(stack)]
        for _, lane in ipairs(it and it.parent_lanes or {}) do
            lane.highlighted = true
            if visible[lane.parent] and not cone[lane.parent] then
                cone[lane.parent] = true
                stack[#stack + 1] = lane.parent
            end
        end
    end

    stack = { pivot } -- descendants
    while #stack > 0 do
        local it = item_of[table.remove(stack)]
        for _, lane in ipairs(it and it.child_lanes or {}) do
            lane.highlighted = true
            if visible[lane.begin] and not cone[lane.begin] then
                cone[lane.begin] = true
                stack[#stack + 1] = lane.begin
            end
        end
    end

    for c in pairs(cone) do -- light the cone commits' markers
        for _, line in ipairs(item_lines(item_of[c])) do
            for _, t in ipairs(line) do
                if t.has_commit and t.commit == c then t.active = true end
            end
        end
    end

    return cone
end


--- Tracks the current ref selection (specification.md §2). Held by commit
--- identity so it survives reflow; `index` is 1-based into the row's selectable
--- decorations (branch groups then tags), or nil for no selection.
--- `commit` is the selection anchor: a Commit on a normal row, or the OrderItem
--- itself on a packed marker-group row (§10.4). `index` is 1-based into the row's
--- selectable units (ref decorations, or markers in a group), or nil.
---@class SelectionState
---@field commit Commit|OrderItem|nil
---@field index integer|nil

--- Whether a commit renders as **two real buffer rows** in the current label
--- mode (spec §6.1): dual mode and the commit actually has selectable
--- decorations. The single source of truth shared by the listview's
--- `line_count` (buffer allocation) and `display_item` (the rendered rows), so
--- they never disagree.
---@param opts GraphOptions
---@param commit Commit|nil
---@return boolean
local function dual_two_line(opts, commit)
    local is_marker = commit ~= nil
        and (commit.collapsed or (commit.junction and opts.junction_markers ~= false))
    return opts.label_mode == "dual" and commit ~= nil and not is_marker
        and #decoration_texts(commit) > 0
end

---@param opts GraphOptions
---@param item OrderItem
---@param selection_state SelectionState
---@param cone table<Commit, boolean>|nil  the pivot's reachability cone (§12), or nil
---@return DisplayElement
local function display_item(opts, item, selection_state, cone)
    local palette = opts.palette

    -- The 1-based decoration index selected on this row, or nil. Selection is
    -- by commit identity, so it follows the commit across reflow.
    local selected = nil
    if selection_state and item.commit and selection_state.commit == item.commit then
        selected = selection_state.index
    end

    -- Reachability dimming (§12): when a cone is active and this commit is
    -- outside it, the row's non-lane fields render dimmed (the lanes dim
    -- per-cell via track.active in get_column_chars). `cone == nil` means no
    -- pivot yet, so nothing dims. `rh` is "row highlight": the field's group,
    -- or its dimmed derivative on an out-of-cone row.
    -- Emphasis is active only with a pivot (cone) and the toggle on; otherwise
    -- everything renders lit. Lane dimming reads `emphasis`; row fields read
    -- `row_active` (this commit in the cone).
    local emphasis = (opts.highlight ~= false) and (cone ~= nil)
    local row_active = (not emphasis) or (item.commit ~= nil and cone ~= nil and cone[item.commit] == true)
    -- On an out-of-cone row, dim the field's group; a field with no group (e.g.
    -- the message, palette.message = nil) dims its default `Normal` foreground so
    -- it recedes with the rest of the row rather than staying full-bright.
    local function rh(text, group)
        if row_active then return highlight_text(text, group) end
        return highlight_text(text, dim_hl(opts, group or "Normal"))
    end

    -- Refs (§6) as a list of right-pinned items: a HEAD marker, then branch
    -- groups, then tags. Branch refs sharing a short name collapse to
    -- "(name ↑remote1,remote2)" — the name once (highlighted if a local exists,
    -- dimmed if remote-only) plus the remotes that also point here (group_refs).
    -- The `selected`-th decoration (branches then tags) is drawn with
    -- palette.selected (§2). The listview packs these against the right edge
    -- with a width budget and a "+N" overflow marker.
    local get_ref_items = function(commit)
        local g = group_refs(commit.refs)
        local texts = decoration_texts(commit) -- same order; shared with the cursor target
        local items = {}
        if g.head then
            items[#items + 1] = rh("HEAD", palette.head)
        end
        local di = 0
        for _, b in ipairs(g.branches) do
            di = di + 1
            if di == selected then
                items[#items + 1] = highlight_text(texts[di], palette.selected)
            else
                local name_hl = b.has_local and palette.branch or palette.remote
                local segs = { rh("(" .. b.name, name_hl) }
                if #b.remotes > 0 then
                    segs[#segs + 1] = rh(" ↑" .. table.concat(b.remotes, ","), palette.remote)
                end
                segs[#segs + 1] = rh(")", name_hl)
                items[#items + 1] = compose(segs)
            end
        end
        for _, t in ipairs(g.tags) do
            di = di + 1
            if di == selected then
                items[#items + 1] = highlight_text(texts[di], palette.selected)
            else
                items[#items + 1] = rh("[" .. t .. "]", palette.tags)
            end
        end
        return items
    end

    local get_columns = function(columns)
        if not show_lane_ids then
            return highlight_text("")
        end
        local result = "("
        for i, t in ipairs(columns) do
            result = result .. (i > 1 and ", " or "") .. (t.id or "-")
        end
        result = result .. ") "

        return highlight_text(result, "Comment")
    end



    -- A packed marker-group (spec §10.4): several concurrent collapsed heads on
    -- one line — their ◍ nodes in the graph column, then each marker's ref
    -- label(s) inline, the selected one highlighted (`h`/`l`). No message.
    if item.type == "markers" then
        local graph_item = get_column_chars(opts, item.columns, emphasis)
        local sel = (selection_state and selection_state.commit == item) and selection_state.index or nil
        local parts = {}
        for i, u in ipairs(marker_units(item)) do
            if i > 1 then parts[#parts + 1] = " " end
            parts[#parts + 1] = (i == sel) and highlight_text(u.text, palette.selected)
                or rh(u.text, palette.branch)
        end
        return { line = { "", "", graph_item, compose(parts) } }
    end

    -- A collapsed head is a **marker** (spec §10.4): a messageless node standing
    -- for a contracted region — the ◍ node, the region's ref label(s), and a
    -- compact commit count, but no subject. Labels render inline in the flex
    -- column regardless of label_mode. Always one row (dual_two_line excludes it).
    local head = item.commit
    if head and head.collapsed then
        local graph_item = get_column_chars(opts, item.columns, emphasis)
        -- No date/author columns: a collapsed head stands for a whole region of
        -- commits, so the tip's lone date/author would misrepresent it. It exists
        -- only to show the region's existence and how it connects to the trunk —
        -- uncollapse for detail.
        local parts = {}
        for _, it in ipairs(get_ref_items(head)) do
            parts[#parts + 1] = it
            parts[#parts + 1] = " "
        end
        parts[#parts + 1] = rh(("(%d)"):format(head.count or 0), "Comment")
        return { line = { "", "", graph_item, compose(parts) } }
    end

    -- A kept junction drawn as a marker (spec §10.4): the split/merge topology
    -- only — node-less graph (get_column_chars), any refs, but no date/author/
    -- message. Keeps the split/merge fan virtual lines. opts.junction_markers off
    -- falls through to the full commit render below.
    if item.commit and item.commit.junction and opts.junction_markers ~= false then
        local graph_item = get_column_chars(opts, item.columns, emphasis)
        local above = {}
        if item.split then
            above[#above + 1] = { "", "", get_column_chars(opts, item.split, emphasis), "" }
        end
        local below
        if item.merge then
            below = { { "", "", get_column_chars(opts, item.merge, emphasis), "" } }
        end
        local parts = {}
        for _, it in ipairs(get_ref_items(item.commit)) do
            parts[#parts + 1] = it
            parts[#parts + 1] = " "
        end
        return {
            above = #above > 0 and above or nil,
            below = below,
            line = { "", "", graph_item, compose(parts) },
        }
    end

    if item.type == "commit" then
        local label_mode = opts.label_mode or "right"
        local ids = get_columns(item.columns) -- optional lane-id debug prefix
        local message = rh(item.commit.message or "", palette.message) or ""
        local ref_items = get_ref_items(item.commit)

        local date_item = rh(format_date(item.commit.date, opts) .. " ", palette.date)
        local author_item = rh((item.commit.author or "") .. " ", palette.author)
        local graph_item = get_column_chars(opts, item.columns, emphasis) -- the node line

        -- Stacked virtual rows above (split fan-in) / below (merge fan-out).
        local above = {}
        if item.split then
            above[#above + 1] = { "", "", get_column_chars(opts, item.split, emphasis), get_columns(item.split) }
        end
        local below
        if item.merge then
            below = { { "", "", get_column_chars(opts, item.merge, emphasis), get_columns(item.merge) } }
        end

        ---@type DisplayElement
        local element = { above = #above > 0 and above or nil, below = below }

        if dual_two_line(opts, item.commit) then
            -- Two real rows (§6.1): row 1 = graph (node) + labels; row 2 = the
            -- message, the graph continued downward (down-passthrough, no node).
            local labels = {}
            for k, it in ipairs(ref_items) do
                if k > 1 then labels[#labels + 1] = " " end
                labels[#labels + 1] = it
            end
            element.lines = {
                { date_item, author_item, graph_item, compose(labels) },
                {
                    "", "",
                    get_column_chars(opts, passthrough_columns(item.columns, "down"), emphasis),
                    compose({ ids, message }),
                },
            }
        elseif label_mode == "inline" then
            -- Labels left-aligned right after the graph, before the message.
            ---@type (DisplayItem|string)[]
            local parts = { ids }
            for _, it in ipairs(ref_items) do
                parts[#parts + 1] = it
                parts[#parts + 1] = " "
            end
            parts[#parts + 1] = message
            element.line = { date_item, author_item, graph_item, compose(parts) }
        else
            -- "right" (default) refs pinned to the right edge; "dual" commits with
            -- no labels fall here too (single row: node + message).
            element.line = { date_item, author_item, graph_item, compose({ ids, message }) }
            if label_mode ~= "dual" then
                element.line_right = ref_items
            end
        end

        return element
    else
        return { line = { "", "", get_column_chars(opts, item.columns), "", "" } }
    end
end

--- Human-readable dump of a row's lanes, for the `K` debug float.
---@param item OrderItem
---@return string[]
local function format_lane_info(item)
    local function short(c)
        return (c and c.hash) and c.hash:sub(1, 7) or "-"
    end
    local function sides(conn)
        local s = {}
        for _, k in ipairs({ "up", "down", "left", "right" }) do
            if conn[k] then s[#s + 1] = k:sub(1, 1) end
        end
        return table.concat(s, "")
    end

    local lines = {}
    lines[#lines + 1] = ("commit %s  %s"):format(short(item.commit), item.commit.message or "")

    local function dump(label, columns)
        if not columns then return end
        lines[#lines + 1] = label .. ":"
        for i, t in ipairs(columns) do
            local head = ("  #%d %s"):format(i, t.has_commit and "●" or "·")
            local lanes = t.lanes or {}
            if #lanes == 0 then
                lines[#lines + 1] = head .. " (no lanes)"
            end
            for j, lane in ipairs(lanes) do
                lines[#lines + 1] = ("%s id=%s [%s] parent=%s"):format(
                    j == 1 and head or string.rep(" ", #head),
                    tostring(lane.id), sides(lane.connectivity), short(lane.parent))
            end
        end
    end

    dump("split (above)", item.split)
    dump("commit line", item.columns)
    dump("merge (below)", item.merge)
    return lines
end

--- Full per-commit detail for the commit view (specification.md §11). Fetched
--- on demand via `git show -s`, independent of the streaming graph model.
---@class CommitDetail
---@field hash string
---@field author_name string
---@field author_email string
---@field author_date string
---@field committer_name string
---@field committer_email string
---@field committer_date string
---@field parents string[]   parent hashes
---@field body string        full message (subject + body), trailing space trimmed

--- Parse the `fetch_commit_detail` output into a CommitDetail. Fields are
--- `%x1f`-separated; the body (`%B`) is last so its embedded newlines stay in
--- the final field. Pure; exposed for testing.
---@param output string?
---@return CommitDetail
local function parse_show(output)
    local fields = vim.split(output or "", "\x1f")
    local parents = {}
    for _, p in ipairs(vim.split(fields[8] or "", " ")) do
        if p ~= "" then
            parents[#parents + 1] = p
        end
    end
    return {
        hash = fields[1] or "",
        author_name = fields[2] or "",
        author_email = fields[3] or "",
        author_date = fields[4] or "",
        committer_name = fields[5] or "",
        committer_email = fields[6] or "",
        committer_date = fields[7] or "",
        parents = parents,
        body = (fields[9] or ""):gsub("%s+$", ""),
    }
end

--- Render a CommitDetail into the commit view's display lines (one compose-style
--- `{ text, highlight }` per buffer line). The committer block is shown only
--- when it differs from the author (the common case is omitted). `opts` carries
--- the row's `decorations` (refs, reused from the model; §6) and the `palette`
--- for highlights. Pure; exposed for testing.
---@param detail CommitDetail
---@param opts? { decorations?: string[], palette?: GraphPalette }
---@return table[]
local function format_commit_detail(detail, opts)
    opts = opts or {}
    local palette = opts.palette or {}
    local decorations = opts.decorations or {}
    local lines = {}

    local function add(segs)
        lines[#lines + 1] = compose(segs)
    end
    -- A "Label:" field: label padded to 12 cells (dimmed) then the value.
    local function field(label, value, value_hl)
        add({ highlight_text(("%-12s"):format(label), palette.author),
            highlight_text(value or "", value_hl) })
    end

    add({ highlight_text("commit ", palette.author), highlight_text(detail.hash, palette.date) })
    if #decorations > 0 then
        field("Refs:", table.concat(decorations, " "), palette.branch)
    end
    field("Author:", detail.author_name .. " <" .. detail.author_email .. ">", palette.message)
    field("AuthorDate:", detail.author_date, palette.date)

    local differs = detail.committer_name ~= detail.author_name
        or detail.committer_email ~= detail.author_email
        or detail.committer_date ~= detail.author_date
    if differs then
        field("Commit:", detail.committer_name .. " <" .. detail.committer_email .. ">", palette.message)
        field("CommitDate:", detail.committer_date, palette.date)
    end

    if #detail.parents > 0 then
        local shorts = {}
        for _, p in ipairs(detail.parents) do
            shorts[#shorts + 1] = p:sub(1, 7)
        end
        field("Parents:", table.concat(shorts, " "), palette.message)
    end

    add({ highlight_text("") })
    for _, l in ipairs(vim.split(detail.body or "", "\n")) do
        add({ highlight_text("    " .. l, palette.message) })
    end

    return lines
end

-- Line prefixes that mark a diff's file-header lines (checked before +/- so the
-- "+++"/"---" file markers don't read as added/removed content).
local DIFF_HEADER_PREFIXES = {
    "diff --git", "index ", "--- ", "+++ ", "old mode", "new mode",
    "deleted file", "new file", "similarity index", "dissimilarity index",
    "rename ", "copy ", "Binary files",
}

--- Classify one patch line by role: "header", "hunk", "add", "delete", or nil
--- (a context line). Pure.
---@param line string
---@return string|nil
local function diff_line_role(line)
    for _, p in ipairs(DIFF_HEADER_PREFIXES) do
        if line:sub(1, #p) == p then
            return "header"
        end
    end
    if line:sub(1, 2) == "@@" then
        return "hunk"
    end
    local c = line:sub(1, 1)
    if c == "+" then
        return "add"
    elseif c == "-" then
        return "delete"
    end
    return nil
end

--- Render a patch into the commit view's diff lines (one compose-style
--- `{ text, highlight }` per line), each line colored by its role via
--- `palette.diff` (add/delete/hunk/header; context uncolored). Line-level
--- highlighting only (specification.md §11.3). Pure; exposed for testing.
---@param patch string?
---@param palette GraphPalette?
---@return table[]
local function format_diff(patch, palette)
    local diff = (palette or {}).diff or {}
    local groups = { add = diff.add, delete = diff.delete, hunk = diff.hunk, header = diff.header }
    local rows = {}
    for _, line in ipairs(vim.split(patch or "", "\n")) do
        local role = diff_line_role(line)
        rows[#rows + 1] = highlight_text(line, role and groups[role] or nil)
    end
    return rows
end

--- Parse a patch into a per-file diffstat (specification.md §11.4). Each entry
--- carries the display path, insertion/deletion counts, a binary flag, and
--- `start` — the 1-based index (into the patch's split lines) of that file's
--- `diff --git` line, used as the jump target. Renames (a/ != b/) show as
--- "old => new". Pure; exposed for testing.
---@param patch string?
---@return { path: string, added: integer, removed: integer, binary: boolean, start: integer }[]
local function diffstat_files(patch)
    local files = {}
    local cur = nil
    for i, line in ipairs(vim.split(patch or "", "\n")) do
        local a, b = line:match("^diff %-%-git a/(.-) b/(.+)$")
        if a then
            cur = { a = a, b = b, added = 0, removed = 0, binary = false, start = i }
            files[#files + 1] = cur
        elseif cur then
            if line:sub(1, 13) == "Binary files " then
                cur.binary = true
            elseif line:sub(1, 3) ~= "+++" and line:sub(1, 1) == "+" then
                cur.added = cur.added + 1
            elseif line:sub(1, 3) ~= "---" and line:sub(1, 1) == "-" then
                cur.removed = cur.removed + 1
            end
        end
    end
    for _, f in ipairs(files) do
        f.path = (f.a ~= f.b) and (f.a .. " => " .. f.b) or f.b
        f.a, f.b = nil, nil
    end
    return files
end

--- Precompute the diff context-header data (specification.md §11.6): for each
--- 1-based line of the rendered patch, the **governing** file and hunk header —
--- the nearest `diff --git` and `@@ … @@` line at or above it — together with the
--- patch-line index where each begins. The window glue (`update_ctx`) compares
--- those begin-indices against the viewport's effective top to decide whether a
--- header has scrolled off and should stick. The file is shown as its display
--- path, with renames as "old => new" (matching the diffstat). A line before any
--- `diff --git` (or a hunk before its file's first `@@`) yields a nil field, so
--- the overlay simply omits it. Pure; exposed for testing.
---@param patch string?
---@return { file?: string, file_line?: integer, hunk?: string, hunk_line?: integer }[]
local function diff_contexts(patch)
    local ctx = {}
    if not patch or patch == "" then return ctx end
    local file, file_line, hunk, hunk_line = nil, nil, nil, nil
    for i, line in ipairs(vim.split(patch or "", "\n")) do
        local a, b = line:match("^diff %-%-git a/(.-) b/(.+)$")
        if a then
            file = (a ~= b) and (a .. " => " .. b) or b
            file_line = i
            hunk, hunk_line = nil, nil
        elseif line:sub(1, 2) == "@@" then
            hunk = line
            hunk_line = i
        end
        ctx[i] = { file = file, file_line = file_line, hunk = hunk, hunk_line = hunk_line }
    end
    return ctx
end

-- Max width of the +/- bar in a diffstat row; long files scale down to fit.
local DIFFSTAT_BAR_MAX = 40

--- Render a diffstat (specification.md §11.4) into compose-style rows: a summary
--- row ("N files changed, …") then one row per file (path, count, colored +/-
--- bar) in `files` order — so the caller can map each file row back to its
--- `diffstat_files` entry by position. The bar uses palette.diff.add/.delete.
--- Pure; exposed for testing.
---@param files { path: string, added: integer, removed: integer, binary: boolean }[]
---@param palette GraphPalette?
---@return table[]
local function format_diffstat(files, palette)
    palette = palette or {}
    local diff = palette.diff or {}
    local rows = {}

    local total_add, total_del, max_path, max_total = 0, 0, 0, 1
    for _, f in ipairs(files) do
        total_add = total_add + f.added
        total_del = total_del + f.removed
        max_path = math.max(max_path, vim.fn.strdisplaywidth(f.path))
        max_total = math.max(max_total, f.added + f.removed)
    end

    local function plural(c, word)
        return ("%d %s%s"):format(c, word, c == 1 and "" or "s")
    end
    local summary = plural(#files, "file") .. " changed"
    if total_add > 0 then summary = summary .. ", " .. plural(total_add, "insertion") .. "(+)" end
    if total_del > 0 then summary = summary .. ", " .. plural(total_del, "deletion") .. "(-)" end
    rows[#rows + 1] = highlight_text(summary, palette.author)

    local scale = math.min(1, DIFFSTAT_BAR_MAX / max_total)
    for _, f in ipairs(files) do
        local count = f.binary and "Bin" or tostring(f.added + f.removed)
        local pad = string.rep(" ", max_path - vim.fn.strdisplaywidth(f.path))
        local segs = {
            highlight_text("  " .. f.path, palette.message),
            highlight_text(pad .. " | ", palette.author),
            highlight_text(("%3s "):format(count), palette.author),
        }
        if not f.binary then
            local add_bar = (f.added > 0) and math.max(1, math.floor(f.added * scale + 0.5)) or 0
            local del_bar = (f.removed > 0) and math.max(1, math.floor(f.removed * scale + 0.5)) or 0
            if add_bar > 0 then segs[#segs + 1] = highlight_text(string.rep("+", add_bar), diff.add) end
            if del_bar > 0 then segs[#segs + 1] = highlight_text(string.rep("-", del_bar), diff.delete) end
        end
        rows[#rows + 1] = compose(segs)
    end

    return rows
end

-- git's well-known empty-tree hash, used as the base for a root commit's diff.
local EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

--- The DiffRange for a single commit's own changes (specification.md §11.5).
--- `rev` is `<hash>^!` (the commit vs its first parent), or an empty-tree range
--- for a root commit (no parents) so it still diffs. `from`/`to` are the
--- structured endpoints. The first range constructor for the diff provider;
--- graph range-selection will add more. Pure; exposed for testing.
---@class DiffRange
---@field rev string       git rev-range the diff tool understands
---@field from? Commit     base endpoint (nil for a root commit)
---@field to Commit        head endpoint
---@param commit Commit
---@return DiffRange
local function commit_range(commit)
    local parents = commit.parents or {}
    if #parents == 0 then
        return { rev = EMPTY_TREE .. ".." .. commit.hash, from = nil, to = commit }
    end
    return { rev = commit.hash .. "^!", from = parents[1], to = commit }
end

--- Default diff provider: open diffview for the range (specification.md §11.5).
--- Guarded — reports rather than errors when diffview is not installed. Override
--- opts.diff.open to use another plugin.
---@param range DiffRange
local function open_diffview(range)
    -- diffview is usually lazy-loaded, so `:DiffviewOpen` does not exist until
    -- the plugin is loaded; require it first (a no-op if already loaded) to
    -- trigger the load, then run the command.
    pcall(require, "diffview")
    if vim.fn.exists(":DiffviewOpen") == 0 then
        vim.notify("diffview.nvim not found; set diff.open to use another diff plugin",
            vim.log.levels.ERROR)
        return
    end
    vim.cmd("DiffviewOpen " .. range.rev)
end

--- Open the configured external diff (§11.5) for a commit: build its DiffRange
--- and hand it to the provider. No-op when no provider is configured.
---@param opts GraphOptions
---@param commit Commit
local function open_diff(opts, commit)
    local open = opts.diff and opts.diff.open
    if open then
        open(commit_range(commit))
    end
end

--- Fetch one commit's full detail via `git show -s` (specification.md §11.1).
--- Buffered; resolves the raw `%x1f`-delimited output as a single string (the
--- body `%B` is last so its newlines survive). On-demand only — not part of the
--- graph stream.
---@param hash string
local function fetch_commit_detail(hash)
    local future, promise = make_future()
    local out = {}

    vim.fn.jobstart(
        { "git", "show", "-s", "--date=iso",
            "--format=%H%x1f%an%x1f%ae%x1f%ad%x1f%cn%x1f%ce%x1f%cd%x1f%P%x1f%B", hash },
        {
            stdout_buffered = true,
            on_stdout = function(_, lines)
                for _, l in ipairs(lines) do
                    out[#out + 1] = l
                end
            end,
            on_exit = function()
                promise.resolve(table.concat(out, "\n"))
            end,
        })

    return future
end

--- Fetch a commit's diff via `git show --format= -p` (specification.md §11.3).
--- Buffered; resolves the raw patch string. On-demand only, chained after
--- fetch_commit_detail by the commit view.
---@param hash string
local function fetch_commit_diff(hash)
    local future, promise = make_future()
    local out = {}

    vim.fn.jobstart(
        { "git", "show", "--format=", "-p", hash },
        {
            stdout_buffered = true,
            on_stdout = function(_, lines)
                for _, l in ipairs(lines) do
                    out[#out + 1] = l
                end
            end,
            on_exit = function()
                promise.resolve(table.concat(out, "\n"))
            end,
        })

    return future
end

-- Trim leading/trailing whitespace (git command output is line-wrapped).
local function trim_ws(s)
    return ((s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Run a git command and resolve `{ code, out }` (stdout joined with newlines).
--- A thin future over `jobstart` for the submodule change view (§11.7). The
--- submodule is addressed with `git -C <path>` by the caller rather than
--- jobstart's `cwd`, so a missing checkout fails the command (nonzero exit)
--- instead of throwing on an invalid working directory. Resolves `{ code = -1 }`
--- if the job cannot be spawned.
---@param args string[]
---@return table  -- future resolving { code: integer, out: string }
local function git_output(args)
    local future, promise = make_future()
    local out = {}
    local ok, jid = pcall(vim.fn.jobstart, args, {
        stdout_buffered = true,
        on_stdout = function(_, lines)
            for _, l in ipairs(lines) do out[#out + 1] = l end
        end,
        on_exit = function(_, code)
            promise.resolve({ code = code, out = table.concat(out, "\n") })
        end,
    })
    if not ok or jid <= 0 then
        vim.schedule(function() promise.resolve({ code = -1, out = "" }) end)
    end
    return future
end

-- The `git log` format the submodule view parses: the same fields as the main
-- stream (so parse_commit_line handles it) plus a trailing `%d` decoration field.
local SUBMODULE_LOG_FMT = "%H%x1f%P%x1f%an%x1f%at%x1f%ai%x1f%s%x1f%d"

--- Fetch the change graph for one parsed submodule bump (spec §11.7), gated and
--- asynchronous — it **never fetches**. Resolves a result table consumed by
--- `submodule_block`:
---   `{ path, available, reason? }`                              -- gate failed
---   `{ path, available, class, ahead, behind, base, items }`   -- ff / rewind
---   `{ path, available, class, ahead, behind, base,
---      new_commit, old_commit, base_commit }`                  -- diverged
--- `items` are linked OrderItems (the commits the bump brings in / rolls back).
---@param opts GraphOptions
---@param change { path: string, old: string, new: string }
---@return table  -- a future
local function fetch_submodule_graph(opts, change)
    local p, old, new = change.path, change.old, change.new
    -- `git -C <submodule path> …` (path is relative to Neovim's cwd, where the
    -- job runs), so an absent checkout simply errors rather than throwing.
    local function gc(args)
        local full = { "git", "-C", p }
        for _, a in ipairs(args) do full[#full + 1] = a end
        return git_output(full)
    end
    local function parse_log(out)
        local commits = {}
        for _, line in ipairs(vim.split(out or "", "\n")) do
            if line ~= "" then
                local c = parse_commit_line(line)
                if c then
                    c.deco = trim_ws((vim.split(line, "\x1f"))[7] or "")
                    commits[#commits + 1] = c
                end
            end
        end
        return commits
    end
    local function one(hash) -- future of a single Commit (nil if absent)
        return gc({ "log", "-1", "--format=" .. SUBMODULE_LOG_FMT, hash }).next(function(r)
            return parse_log(r.out)[1]
        end)
    end

    -- Presence gate (§11.7.1): both commits must resolve in the checked-out
    -- submodule. We never fetch to satisfy this.
    return gc({ "cat-file", "-e", old .. "^{commit}" }).next(function(r1)
        return gc({ "cat-file", "-e", new .. "^{commit}" }).next(function(r2)
            if r1.code ~= 0 or r2.code ~= 0 then
                return gc({ "rev-parse", "--git-dir" }).next(function(rp)
                    return {
                        path = p, available = false,
                        reason = (rp.code ~= 0) and "submodule not checked out"
                            or "commits not present locally",
                    }
                end)
            end
            -- Classify by merge-base, then fetch per class (§11.7.2).
            return gc({ "merge-base", old, new }).next(function(rb)
                local base = (rb.code == 0) and trim_ws(rb.out) or ""
                local class = submodule.classify(old, new, base)
                if class == "unrelated" then
                    return { path = p, available = false, reason = "unrelated histories" }
                end
                return gc({ "rev-list", "--count", base .. ".." .. new }).next(function(ra)
                    return gc({ "rev-list", "--count", base .. ".." .. old }).next(function(rbh)
                        local res = {
                            path = p, available = true, class = class, base = base,
                            ahead = tonumber(trim_ws(ra.out)) or 0,
                            behind = tonumber(trim_ws(rbh.out)) or 0,
                        }
                        if class == "diverged" then
                            -- Glanceable only (§11.7.2): the two tips + the fork
                            -- point, no paths drawn.
                            return one(new).next(function(nc)
                                return one(old).next(function(oc)
                                    return one(base).next(function(bc)
                                        res.new_commit, res.old_commit, res.base_commit = nc, oc, bc
                                        return res
                                    end)
                                end)
                            end)
                        end
                        -- ff / rewind: the moving tip's first-parent line down to
                        -- the fork point (§11.7.3) — `--first-parent` so a merge
                        -- stays a mainline node without dragging its side branch
                        -- in (no lane "from nowhere" at the range boundary). The
                        -- fork point itself is appended as the bottom anchor so
                        -- the old/new pointer there is shown and marked.
                        local tip = (class == "ff") and new or old
                        return gc({ "log", "--first-parent",
                            "--format=" .. SUBMODULE_LOG_FMT, base .. ".." .. tip })
                            .next(function(rl)
                                return one(base).next(function(bc)
                                    local commits = parse_log(rl.out)
                                    if bc then commits[#commits + 1] = bc end
                                    res.items = submodule.link(commits)
                                    return res
                                end)
                            end)
                    end)
                end)
            end)
        end)
    end)
end

--- Render one submodule change's fetched `result` (spec §11.7) into commit-view
--- rows (compose-style `{ text, highlight }`), replacing the raw `Subproject
--- commit` pair. `result` may be nil (not yet fetched) — then the raw hashes are
--- shown, upgraded in place once the fetch resolves (§11.7.4).
---@param opts GraphOptions
---@param change { path: string, old: string, new: string }
---@param result table?
---@return table[]
local function submodule_block(opts, change, result)
    local palette = opts.palette or {}
    local diffp = palette.diff or {}
    local rows = {}
    local function short(h) return (h or ""):sub(1, 8) end

    -- Gate failed or not yet fetched: the raw hashes, with a dim reason (§11.7.1).
    if not result or not result.available then
        rows[#rows + 1] = compose({
            highlight_text("  submodule ", palette.author),
            highlight_text(change.path, diffp.header),
            highlight_text(("  %s → %s"):format(short(change.old), short(change.new)), palette.date),
        })
        if result and result.reason then
            rows[#rows + 1] = highlight_text("  (" .. result.reason .. ")", DIM_FALLBACK)
        end
        return rows
    end

    -- Header: path, old → new, and the direction/counts.
    local dir
    if result.class == "ff" then
        dir = ("+%d"):format(result.ahead)
    elseif result.class == "rewind" then
        dir = ("−%d"):format(result.behind)
    else
        dir = ("diverged +%d / −%d"):format(result.ahead, result.behind)
    end
    rows[#rows + 1] = compose({
        highlight_text("  submodule ", palette.author),
        highlight_text(change.path, diffp.header),
        highlight_text(("  %s → %s  "):format(short(change.old), short(change.new)), palette.date),
        highlight_text("(" .. dir .. ")", palette.branch),
    })

    if result.class == "diverged" then
        local function endpoint(label, c, hl)
            rows[#rows + 1] = compose({
                highlight_text("    " .. label .. " ", hl),
                highlight_text(c and short(c.hash) or "", palette.date),
                highlight_text(c and c.message and ("  " .. c.message) or "", palette.message),
            })
        end
        endpoint("new ", result.new_commit, palette.branch)
        endpoint("base", result.base_commit, palette.author)
        endpoint("old ", result.old_commit, palette.remote)
        return rows
    end

    -- ff / rewind: lay the first-parent commits out (the same Phase 1 the main
    -- graph uses) and draw the glyph gutter. The commits are newest-first with the
    -- fork-point anchor last; when there are too many, keep the newest
    -- SUBMODULE_MAX-1 plus the anchor (pane.cap keeps the last row) and note the
    -- commits elided between (§11.7.3).
    local pane = require("gitloom.pane")
    local laid = build_graph(opts, result.items or {})
    local shown = pane.cap(laid, SUBMODULE_MAX)
    local dropped = #laid - #shown
    -- The pointer tag for a row: "new"/"old" when it is the new/old pointer (§11.7.3).
    local function ptr_tag(hash)
        if hash == change.new then return "new" end
        if hash == change.old then return "old" end
        return nil
    end
    for i, item in ipairs(shown) do
        -- The elision falls between the newest kept rows and the anchor (last).
        if dropped > 0 and i == #shown then
            rows[#rows + 1] = highlight_text(("    … +%d more"):format(dropped), DIM_FALLBACK)
        end
        local c = item.commit
        if c then
            local segs = {
                highlight_text("    ", nil),
                get_column_chars(opts, item.columns, false),
                highlight_text("  " .. short(c.hash), palette.date),
            }
            local tag = ptr_tag(c.hash)
            if tag then segs[#segs + 1] = highlight_text(" ◀ " .. tag, palette.head) end
            if c.deco and c.deco ~= "" then segs[#segs + 1] = highlight_text(" " .. c.deco, palette.branch) end
            if c.message and c.message ~= "" then segs[#segs + 1] = highlight_text("  " .. c.message, palette.message) end
            rows[#rows + 1] = compose(segs)
        end
    end
    return rows
end

local commit_view_ns = vim.api.nvim_create_namespace("gitloom.commit_view")

--- Open the commit view (specification.md §11) for `commit`: a read-only snacks
--- float that fetches the commit's detail + diff on demand and renders the
--- metadata, the diffstat, and the diff. `q` closes it (snacks default); `<CR>`
--- on a diffstat file line jumps to that file's diff section (§11.4). The pure
--- pieces (parse_show / format_commit_detail / format_diff / diffstat_files /
--- format_diffstat) do the work; this is just window + IO glue.
---@param opts GraphOptions
---@param commit Commit
local function open_commit_view(opts, commit)
    local ok, snacks = pcall(require, "snacks.win")
    if not ok then
        vim.notify("snacks.win not found. Install snacks.nvim", vim.log.levels.ERROR)
        return
    end

    -- Match the graph window's geometry so the commit view is the same size.
    local w = snacks.new({
        border = opts.win.border or "rounded",
        width = opts.win.width,
        height = opts.win.height,
        title = "Commit " .. commit.hash:sub(1, 7),
        footer = "q: close",
        keys = { q = "close" },
    })
    local buf = w.buf

    -- Maps a diffstat file row's buffer line -> the buffer line where that
    -- file's diff section begins. Rebuilt on each render; <CR> jumps by it.
    local file_jumps = {}
    -- Buffer line of the diff action label (§11.5), or nil. <CR> there opens the
    -- external diff; the cursor parks here when the view opens.
    local action_line = nil

    -- Diff context-header state (§11.6), set by render(): the per-patch-line
    -- governing file/hunk (diff_contexts) and the buffer line where the patch
    -- begins, so a buffer line L maps to patch index L - diff_start + 1.
    local diff_ctx, diff_start = nil, nil
    -- Buffer line -> patch line index, set by render() only when a submodule
    -- block (§11.7) was spliced in (which breaks the 1:1 patch↔buffer mapping
    -- the line `L - diff_start + 1` assumes); nil otherwise, so the common
    -- no-submodule path is unchanged.
    local diff_buf_to_patch = nil
    -- Submodule change view (§11.7): the fetched result per submodule path,
    -- filled asynchronously after the first render and triggering an in-place
    -- re-render. Read by render() when it splices each change block.
    local sub_results = {}

    local function set_lines(lines)
        if not vim.api.nvim_buf_is_valid(buf) then return end
        vim.bo[buf].modifiable = true
        vim.bo[buf].readonly = false
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modifiable = false
        vim.bo[buf].readonly = true
    end

    -- <CR> dispatches by cursor line: on the action label it opens the external
    -- diff (§11.5); on a diffstat file line it jumps to that file's diff section
    -- (§11.4), scrolling it to the top; elsewhere it does nothing. The jump uses
    -- the `G` motion (a jump command) so the diffstat position lands in the
    -- jumplist — `<C-o>` / `<C-i>` then move back and forth between the diffstat
    -- and the file's diff.
    vim.keymap.set("n", "<CR>", function()
        if not vim.api.nvim_win_is_valid(w.win) then return end
        local line = vim.api.nvim_win_get_cursor(w.win)[1]
        if action_line and line == action_line then
            open_diff(opts, commit)
            return
        end
        local target = file_jumps[line]
        if target then
            vim.api.nvim_win_call(w.win, function()
                vim.cmd("normal! " .. target .. "Gzt")
            end)
        end
    end, { buffer = buf, nowait = true, silent = true })

    -- <C-o> walks the jumplist back through the view's own jumps (diffstat <->
    -- diff). Once the next jump-back would leave the commit view — its target is
    -- another buffer (the graph), or there is none — close the view instead of
    -- jumping out of it (§11.4). getjumplist's curidx is the 1-based index of
    -- the entry <C-o> would visit (0 = nothing to go back to).
    vim.keymap.set("n", "<C-o>", function()
        local jl = vim.fn.getjumplist()
        local list, curidx = jl[1], jl[2]
        local target = (curidx >= 1) and list[curidx] or nil
        if target and target.bufnr == buf then
            vim.api.nvim_feedkeys(
                vim.api.nvim_replace_termcodes("<C-o>", true, false, true), "n", false)
        else
            w:close()
        end
    end, { buffer = buf, nowait = true, silent = true })

    -- Diff context header (§11.6): a borderless overlay pinned to the top of the
    -- view showing the governing file / hunk while the diff is scrolled past
    -- their real header lines. It tracks the viewport top, not the cursor, and
    -- materializes only when there is something to stick (else it is closed).
    local diff_pal = (opts.palette or {}).diff or {}
    local ctx_win, ctx_buf = nil, nil

    local function close_ctx()
        if ctx_win and vim.api.nvim_win_is_valid(ctx_win) then
            pcall(vim.api.nvim_win_close, ctx_win, true)
        end
        ctx_win = nil
    end

    -- The context rows governing an effective viewport top (a buffer line): the
    -- file line when its `diff --git` has scrolled strictly above it, then the
    -- hunk line when its `@@` has — each omitted while its real header is still
    -- visible below the overlay (§11.6).
    local function ctx_rows_for(eff_top)
        if not diff_ctx then return {} end
        -- Buffer line -> patch index: the spliced map when a submodule block
        -- shifted lines (§11.7), else the plain 1:1 offset from diff_start.
        local pidx = diff_buf_to_patch and diff_buf_to_patch[eff_top]
            or (eff_top - diff_start + 1)
        local c = diff_ctx[pidx]
        if not c then return {} end
        local rows = {}
        if c.file and c.file_line < eff_top then
            rows[#rows + 1] = highlight_text(c.file, diff_pal.header)
        end
        if c.hunk and c.hunk_line < eff_top then
            rows[#rows + 1] = highlight_text(c.hunk, diff_pal.hunk)
        end
        return rows
    end

    local function update_ctx()
        if not (diff_ctx and vim.api.nvim_win_is_valid(w.win)) then
            close_ctx()
            return
        end
        -- The overlay covers the top `#rows` rows, so the first row the user
        -- actually reads is the window top advanced past it (§11.6). That offset
        -- depends on the count we are computing, so settle it with a short
        -- fixpoint (the height is 0–2; this converges in a step or two).
        local top = vim.fn.line("w0", w.win)
        local rows = ctx_rows_for(top)
        for _ = 1, 2 do
            local next_rows = ctx_rows_for(top + #rows)
            if #next_rows == #rows then
                rows = next_rows
                break
            end
            rows = next_rows
        end

        if #rows == 0 then
            close_ctx()
            return
        end

        if not (ctx_buf and vim.api.nvim_buf_is_valid(ctx_buf)) then
            ctx_buf = vim.api.nvim_create_buf(false, true)
        end
        local cfg = {
            relative = "win", win = w.win,
            row = 0, col = 0,
            width = vim.api.nvim_win_get_width(w.win),
            height = #rows,
            style = "minimal",
            focusable = false,
            zindex = 200,
        }
        if ctx_win and vim.api.nvim_win_is_valid(ctx_win) then
            pcall(vim.api.nvim_win_set_config, ctx_win, cfg)
        else
            ctx_win = vim.api.nvim_open_win(ctx_buf, false, cfg)
            pcall(vim.api.nvim_set_option_value, "winhl",
                "Normal:NormalFloat,NormalFloat:NormalFloat", { win = ctx_win })
        end

        vim.bo[ctx_buf].modifiable = true
        local lines = {}
        for _, r in ipairs(rows) do
            lines[#lines + 1] = r.text
        end
        vim.api.nvim_buf_set_lines(ctx_buf, 0, -1, false, lines)
        vim.bo[ctx_buf].modifiable = false
        vim.api.nvim_buf_clear_namespace(ctx_buf, commit_view_ns, 0, -1)
        for i, r in ipairs(rows) do
            for _, hl in ipairs(r.highlight or {}) do
                if hl.hl then
                    vim.api.nvim_buf_set_extmark(ctx_buf, commit_view_ns, i - 1, hl.start_pos, {
                        end_col = hl.end_pos,
                        hl_group = hl.hl,
                    })
                end
            end
        end
    end

    local ctx_group = vim.api.nvim_create_augroup("GitloomCommitCtx_" .. buf, { clear = true })
    vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized" }, {
        group = ctx_group,
        callback = function()
            if vim.api.nvim_win_is_valid(w.win) then update_ctx() end
        end,
    })
    vim.api.nvim_create_autocmd("WinClosed", {
        group = ctx_group,
        callback = function(ev)
            if tonumber(ev.match) == w.win then close_ctx() end
        end,
    })

    set_lines({ "Loading…" })

    -- Render the metadata (format_commit_detail), then the diffstat
    -- (format_diffstat), then the diff (format_diff) into one buffer: real lines
    -- + namespaced extmarks (the diff is highlighted this way, not via
    -- filetype=diff, so the metadata header stays clean §11.3). While laying out
    -- the rows, record each diffstat file row -> its diff section line (§11.4).
    local function render(meta_output, diff_output, keep_view)
        if not vim.api.nvim_buf_is_valid(buf) then return end
        -- On an in-place re-render (the submodule upgrade, §11.7.4) preserve the
        -- user's scroll/cursor; the first render parks on the action label.
        local saved_view = keep_view and vim.api.nvim_win_is_valid(w.win)
            and vim.api.nvim_win_call(w.win, vim.fn.winsaveview) or nil
        file_jumps = {}
        action_line = nil
        diff_ctx, diff_start = nil, nil
        diff_buf_to_patch = nil
        local detail = parse_show(meta_output)

        local rows = {}
        -- Diff action label as the first line (§11.5), when a provider is set.
        if opts.diff and opts.diff.open then
            rows[#rows + 1] = highlight_text(opts.diff.label or "▶ Open diff", opts.palette.action)
            action_line = #rows
            rows[#rows + 1] = highlight_text("")
        end
        for _, r in ipairs(format_commit_detail(detail, {
            decorations = decoration_texts(commit),
            palette = opts.palette,
        })) do
            rows[#rows + 1] = r
        end

        -- `git show --format=` prints a leading blank line; drop it.
        local patch = (diff_output or ""):gsub("^%s+", "")
        if patch ~= "" then
            local files = diffstat_files(patch)
            rows[#rows + 1] = highlight_text("")
            local stat_start = #rows + 1 -- buffer line of the diffstat summary row
            for _, r in ipairs(format_diffstat(files, opts.palette)) do
                rows[#rows + 1] = r
            end
            rows[#rows + 1] = highlight_text("")
            diff_start = #rows + 1 -- buffer line of the first patch line

            -- Submodule change blocks (§11.7): replace each `Subproject commit`
            -- pair with its change graph. Splicing shifts buffer lines, so build
            -- patch<->buffer maps for the file-jump and context-header lookups
            -- rather than the plain 1:1 offset (which holds only with no splice).
            local diff_rows = format_diff(patch, opts.palette)
            local repl = {} -- from_line -> { to_line, rows }
            for _, ch in ipairs(submodule.parse_changes(patch)) do
                repl[ch.from_line] = {
                    to_line = ch.to_line,
                    rows = submodule_block(opts, ch, sub_results[ch.path]),
                }
            end
            local patch_to_buf, buf_to_patch = {}, {}
            local pi = 1
            while pi <= #diff_rows do
                local r = repl[pi]
                if r then
                    local at = #rows + 1 -- buffer line of the block's first row
                    for _, br in ipairs(r.rows) do
                        rows[#rows + 1] = br
                        buf_to_patch[#rows] = pi -- block lines govern by the file's region
                    end
                    for k = pi, r.to_line do patch_to_buf[k] = at end
                    pi = r.to_line + 1
                else
                    rows[#rows + 1] = diff_rows[pi]
                    patch_to_buf[pi], buf_to_patch[#rows] = #rows, pi
                    pi = pi + 1
                end
            end

            -- Summary sits at stat_start; file j at stat_start + j. Its diff
            -- section starts where its `diff --git` line landed (identity when
            -- nothing was spliced).
            for j, f in ipairs(files) do
                file_jumps[stat_start + j] = patch_to_buf[f.start] or (diff_start + f.start - 1)
            end
            -- Context-header lookup over the same patch (§11.6); when a block was
            -- spliced the buffer is no longer 1:1 with the patch, so hand
            -- ctx_rows_for the inverse map.
            diff_ctx = diff_contexts(patch)
            if next(repl) then diff_buf_to_patch = buf_to_patch end
        end

        local lines = {}
        for _, r in ipairs(rows) do
            lines[#lines + 1] = r.text
        end
        set_lines(lines)
        vim.api.nvim_buf_clear_namespace(buf, commit_view_ns, 0, -1)
        for i, r in ipairs(rows) do
            for _, hl in ipairs(r.highlight or {}) do
                if hl.hl then
                    vim.api.nvim_buf_set_extmark(buf, commit_view_ns, i - 1, hl.start_pos, {
                        end_col = hl.end_pos,
                        hl_group = hl.hl,
                    })
                end
            end
        end

        if saved_view then
            -- In-place re-render: keep the user where they were (§11.7.4).
            pcall(vim.api.nvim_win_call, w.win, function() vim.fn.winrestview(saved_view) end)
        elseif action_line and vim.api.nvim_win_is_valid(w.win) then
            -- Park the cursor on the action label so <CR><CR> opens the diff (§11.2).
            pcall(vim.api.nvim_win_set_cursor, w.win, { action_line, 0 })
        end

        -- Seed the context header for the initial viewport (§11.6).
        update_ctx()
    end

    -- Fetch metadata, then the diff; render once both arrive (§11.1).
    fetch_commit_detail(commit.hash).next(function(meta_output)
        return fetch_commit_diff(commit.hash).next(function(diff_output)
            return { meta = meta_output, diff = diff_output }
        end)
    end).next(function(res)
        render(res.meta, res.diff)
        -- Submodule change graphs (§11.7): fetch each asynchronously (gated,
        -- never fetching) and re-render in place as they resolve, so a slow or
        -- large submodule never blocks the diff.
        local patch = (res.diff or ""):gsub("^%s+", "")
        for _, ch in ipairs(submodule.parse_changes(patch)) do
            fetch_submodule_graph(opts, ch).next(function(result)
                sub_results[ch.path] = result
                render(res.meta, res.diff, true)
            end)
        end
    end)
end

---@class GraphWinOptions
---@field border string
---@field width number|fun():number   fraction (0–1), absolute (>1), or a function
---@field height number|fun():number
---@field title string
---@field footer string
---@field keys? table  keymaps installed on the graph window (snacks.win keys)

---@class GraphPalette
---@field date? string
---@field author? string
---@field branch? string
---@field remote? string
---@field head? string
---@field message? string
---@field tags? string
---@field selected? string  the h/l-selected ref decoration (§2)
---@field action? string  the commit-view diff action label (§11.5)
---@field diff? { add?: string, delete?: string, hunk?: string, header?: string }  commit-view diff colors (§11.3)
---@field dim? number  blend factor toward bg for out-of-cone rows/lanes (§12)
---@field tracks? string[]  curated lane colours, the free-list seed (§5.5)
---@field buffer? integer  min free-list length: colours drawn before one repeats (§5.5)
---@field generate? boolean  generate overflow OKLCH colours when truecolor (§5.5)
---@field anchor? { L?: number, C?: number, base_hue?: number }  generated-colour anchor (§5.5)

---@class MergeStyle
---@field allow_merge_on_split boolean
---@field merge_on_separate_line boolean
---@field split_on_separate_line boolean

---@class Icons
---@field merge? string

---@class GraphOptions
---@field win GraphWinOptions
---@field palette GraphPalette
-----@field merge_style "compact"|"normal"|"merge"
---@field merge_style MergeStyle
---@field branches? string|string[]
---@field icons Icons
---@field mirror? boolean  render the graph mirrored (lane 1 on the right); §5.4
---@field highlight? boolean  reachability dimming on/off (default true); §12
---@field collapse_merged? boolean  first-parent focus on/off (default true); §10.7
---@field pack_markers? boolean  marker packing on/off (default true); §10.4
---@field panes? boolean  context panes (header/footer) on/off (default on); §6.2
---@field junction_markers? boolean  draw kept junctions node-less (default true); §10.4
---@field date_format? string  os.date format for absolute dates; §6
---@field date_mode? "absolute"|"relative"  initial date rendering; §6
---@field message_min? integer  min width kept for the message; refs use the rest; §6
---@field label_mode? "right"|"inline"|"dual"  ref label placement; §6.1
---@field diff? { open?: fun(range: DiffRange), label?: string }  external diff provider; §11.5

---@param opts GraphOptions
function M.open(folder, opts)
    ---@type GraphOptions
    local defaults = {
        win = {
            border = "rounded",
            -- Nearly full screen: a ~2-char margin on each edge (snacks treats
            -- a returned size >= 1 as absolute and centers it). Re-evaluated on
            -- resize.
            width = function() return math.max(vim.o.columns - 4, 1) end,
            height = function() return math.max(vim.o.lines - 4, 1) end,
            title = "GraphView",
            footer = footer_text(),
        },
        palette = {
            date = "Title",
            author = "Comment",
            branch = "WarningMsg",
            remote = "Comment",
            head = "Special",
            message = nil,
            tags = "Comment",
            selected = "Visual", -- the h/l-selected ref decoration (§2)
            action = "Special",  -- the commit-view diff action label (§11.5)
            -- Reachability dimming (§12): blend factor toward the bg for the
            -- out-of-cone rows/lanes. Higher = more muted.
            dim = 0.45,
            -- Commit-view diff colors (§11.3): per-role highlight groups.
            diff = {
                add = "DiffAdd",
                delete = "DiffDelete",
                hunk = "Title",
                header = "Comment",
            },
            tracks = {
                --"DiagnosticWarn",
                "Constant",
                "String",
                "Number",
                --"Keyword",
                "Function",
                "DiagnosticInfo",
                "Identifier",
                --"DiagnosticHint",
                --"DiagnosticOk",
            },
            -- Lane colouring (§5.5): generate overflow colours in OKLCH when the
            -- curated `tracks` run low (auto-disabled without truecolor), keeping
            -- at least `buffer` colours in reserve so a released colour is not
            -- reused too soon. `anchor` (nil = derive L/C from the theme) sets the
            -- generated colours' lightness/chroma.
            generate = true,
            buffer = 3,
            anchor = nil,
        },
        --merge_style = "merge"
        merge_style = vim.deepcopy(MERGE_STYLES[merge_style_index].style),
        -- Render the graph mirrored (lane 1 at the right, nearest the message)
        -- by default. Toggle live with M.
        mirror = true,
        -- Reachability highlighting (§12) on by default; toggle live with H.
        highlight = true,
        -- First-parent focus (§10.7): on open, show HEAD's first-parent mainline
        -- in full and collapse every other branch (merged and divergent). Toggle
        -- live with `c`; set false to open the plain full graph.
        collapse_merged = true,
        -- Marker packing (§10.4): merge concurrent collapsed heads onto shared
        -- lines. Toggle live with `p`; set false for one marker per line.
        pack_markers = true,
        -- Junction markers (§10.4): draw a kept fork/merge inside collapsed
        -- branches node-less (just the split lanes, no message). Set false to
        -- show those junction commits in full.
        junction_markers = true,
        -- Date column: absolute (os.date format) or relative ("3 days ago").
        -- Toggle live with d.
        date_format = "%Y-%m-%d %H:%M",
        date_mode = "absolute",
        -- Refs are pinned to the right edge and use the free width; the message
        -- keeps at least message_min, and ref overflow becomes a "+N" marker.
        message_min = 24,
        -- Ref label placement (§6.1): "right" (default), "inline", or "dual".
        -- Cycle live with B.
        label_mode = "right",
        -- External diff provider (§11.5): open is called with a DiffRange; the
        -- default opens diffview. Override open/label to use another diff plugin,
        -- or set open = nil to disable (no action label, D is a no-op).
        diff = {
            open = open_diffview,
            label = "▶ Open diff (diffview)",
        },
        icons = {
            --merge = "M",
        },
    }
    -- The default footer is computed before opts.mirror is resolved; unless the
    -- caller set its own footer, recompute it so the initial mirror state shows.
    local user_footer = opts and opts.win and opts.win.footer
    ---@type GraphOptions
    opts = vim.tbl_deep_extend("force", defaults, opts or {})
    if not user_footer then
        opts.win.footer = footer_text(opts.mirror)
    end
    -- Colour generation (§5.5) needs truecolor to realise RGB; without it Phase 1
    -- must not mint generated slots (they would have no colour), so degrade to
    -- the curated palette + sharing.
    opts.palette.generate = (opts.palette.generate ~= false) and vim.o.termguicolors and true or false

    -- Sync the cycle index to the configured label mode so B advances from it and
    -- the footer shows the right name.
    for i, m in ipairs(LABEL_MODES) do
        if m.mode == opts.label_mode then label_mode_index = i break end
    end

    local listview = require("gitloom.listview")

    ---@class Repo
    ---@field commits table<string, Commit>  hash → Commit (the resolution table)
    ---@field order OrderItem[]              raw commit items, 1:1 with commits (projection input)
    ---@field display? OrderItem[]           the projected OrderItem graph the view renders (§10; set at init)
    ---@field refs table<string, Ref>        name → Ref ("HEAD" for the head)
    ---@field head? string                   current branch name

    ---@type Repo
    local repo = {
        commits = {},
        order = {},
        refs = {},
    }
    -- The displayed graph is a projection of `order` under the view state. With
    -- no non-normal branch modes it is the identity, so it shares the same list
    -- (streaming appends to both) until a reflow swaps in a projected one (§10).
    repo.display = repo.order

    local palette = opts.palette

    ---@type SelectionState
    local selection_state = {
        commit = nil,
        index = nil,
    }

    -- Reachability cone for the dimming pass (§12); nil until a pivot exists.
    -- `modes` is the branch-mode view state (ref name → mode); empty = all normal
    -- (the projection is then the identity). The reflow below reads it (§10).
    -- `modes` is explicit per-owner overrides; `effective` is the resolved mode
    -- per owner id after the first-parent default (§10.7), kept for the footer
    -- and the `<CR>` cycle. Both filled by reflow.
    -- `pinned` is the explicit per-ref pin overrides (ref id → boolean), on top
    -- of the HEAD-pinned-by-default rule (§10.6). The effective anchor set is
    -- computed by `effective_pinned()`; it generalises the single trunk of §10.7.
    local view_state = { cone = nil, modes = {}, effective = {}, pinned = {} }

    -- The effective anchor set (§10.6). Pinned by default: the current branch
    -- (HEAD) and the common trunks `master`/`main`/`dev` when present. The user's
    -- explicit pin/unpin overrides apply on top. Returns a set of ref-owner ids.
    local function effective_pinned()
        local p = {}
        if repo.head and repo.refs[repo.head] then p[repo.head] = true end
        for _, name in ipairs({ "master", "main", "dev" }) do
            if repo.refs[name] then p[name] = true end
        end
        for id, v in pairs(view_state.pinned) do
            if v then p[id] = true else p[id] = nil end
        end
        return p
    end
    -- Cached per-commit signatures for the projection (spec §10.5). They depend
    -- only on the commit set, the owner tips/fp-flags and the focus policy, not on
    -- modes, so a mode toggle reuses them; invalidated when those change. Keyed by
    -- the commit/owner counts and the collapse_merged flag.
    local sig_cache = { norder = -1, nowners = -1, cm = nil, sig = nil }

    -- Parks the cursor at the message (or the selected ref). Assigned after the
    -- listview opens; forward-declared so the key handlers can call it.
    local place_cursor = function() end
    -- Recomputes the pivot's cone + re-marks track activeness (§12). Assigned
    -- after the listview opens; forward-declared for the key handlers.
    local update_cone = function() end
    -- Rebuilds the context panes (§6.2) for the current viewport. Assigned after
    -- the listview opens; forward-declared so reflow/scroll can trigger it.
    local update_panes = function() end
    -- Pane debug state (the seam buffer line + height; or, when nothing showed,
    -- why), surfaced in the footer status when lane ids are on (`i`). Set by
    -- update_panes — one set per pane (footer below, header above).
    local footer_seam, footer_height, footer_dbg
    local header_seam, header_height, header_dbg
    -- Rebuilds the projected OrderItem graph under the current view state and
    -- swaps it into the listview (§10). Assigned after `order_at`/`lv` exist;
    -- forward-declared so the stream and key handlers can close over it.
    local reflow = function() end
    -- Moves the cursor onto the display row representing a commit hash (after a
    -- collapse/expand reflow, so the toggle stays under the cursor). Assigned in
    -- the window block; forward-declared for the key handlers.
    local goto_hash = function(_) end
    -- Centers the view vertically on the cursor's row (like `zz`, clamped at the
    -- graph edges). Assigned in the window block; forward-declared so the stream
    -- handler can focus HEAD on open (§2).
    local center_view = function() end
    -- The hash of the commit under the cursor at a buffer line, or nil on a row
    -- with no single commit. Used to remember the cursor position across
    -- close/reopen (§2). Assigned in the window block; forward-declared.
    local cursor_hash = function(_) return nil end

    -- The repository the graph reflects, identified by Neovim's cwd (git runs in
    -- cwd). Keys the remembered cursor position so reopening restores it (§2).
    local repo_key = vim.fn.getcwd()

    -- The listview instance. Forward-declared so the on_controller/stream
    -- callbacks below close over this local (not a stray global) and see it once
    -- it is assigned after the window opens.
    local lv

    -- Resolve a 1-based *buffer* line to its OrderItem, order index, and 0-based
    -- sub-row within the item. In dual mode a labelled commit spans two buffer
    -- lines (sub 0 = label row, sub 1 = message row); the buffer line is mapped
    -- via the listview. Without the map (or other modes) it is 1:1, sub 0.
    local function order_at(line)
        local idx, first = line, line
        if lv and lv.controller and lv.controller.item_at then
            idx = lv.controller.item_at(line)
            first = lv.controller.item_start and lv.controller.item_start(idx) or idx
        end
        return repo.display[idx], idx, line - first
    end

    -- A full reflow (§10.5): project the raw commit order under the current
    -- branch modes into a fresh OrderItem graph, lay it out, and swap it into the
    -- listview. With all-normal modes the projection is the identity; this is the
    -- path every branch-mode change takes (and the stream takes once the
    -- projection is no longer the identity). Recomputes the cone over the new map.
    reflow = function()
        local viewbuilder = require("gitloom.view")
        -- Owners under the first-parent default (§10.7): the pinned anchors
        -- (§10.6; HEAD by default) are first-parent-only + normal, every other ref
        -- and merge parent defaults collapsed; view_state.modes overrides. No
        -- anchor ⇒ all-normal.
        local cm = opts.collapse_merged ~= false
        local owners = viewbuilder.owners(
            repo.order, owners_from_refs(repo.refs, {}), effective_pinned(), view_state.modes, cm)
        view_state.effective = {}
        for _, o in ipairs(owners) do view_state.effective[o.id] = o.mode end
        -- Reuse cached signatures unless the commit/owner set or focus changed;
        -- only the join + contraction (mode-dependent) recompute on a toggle.
        if sig_cache.norder ~= #repo.order or sig_cache.nowners ~= #owners
            or sig_cache.cm ~= cm or not sig_cache.sig then
            sig_cache.sig = viewbuilder.signatures(repo.order, owners)
            sig_cache.norder, sig_cache.nowners, sig_cache.cm = #repo.order, #owners, cm
        end
        local proj = viewbuilder.project(repo.order, owners, sig_cache.sig)
        refresh_columns(opts, proj.items)
        -- Pack concurrent collapsed heads onto shared lines (spec §10.4) unless
        -- packing is off. The unpacked, laid-out list stays the projection input.
        repo.display = (opts.pack_markers ~= false) and pack_markers(proj.items) or proj.items
        if lv and lv.controller and lv.controller.set_items then
            lv.controller.set_items(repo.display)
        end
        update_cone()
        if lv and lv.controller then lv.controller.refresh() end
        update_panes()
    end

    -- The "branch" the collapse interactions (§10.4) act on at a buffer line:
    --   { state = "expanded"|"collapsed"|"mainline", owners = ids to flip,
    --     follow = hash to put the cursor on after the flip, commit = a real
    --     Commit for examine/diff }.
    -- Resolved from the selection (a ref or a packed marker) or, failing that,
    -- the region under the cursor via its signature — so it needs no ref.
    local function branch_under_cursor(line)
        local item = order_at(line)
        if not item then return nil end
        -- a selected marker on a packed line → expand that marker
        if item.type == "markers" then
            if selection_state.commit == item and selection_state.index then
                local u = marker_units(item)[selection_state.index]
                if u then
                    local owners = {}
                    for oid in pairs(u.marker.signature or {}) do owners[#owners + 1] = oid end
                    return { state = "collapsed", owners = owners,
                        follow = u.marker.tip and u.marker.tip.hash, commit = u.marker.tip }
                end
            end
            return { state = "collapsed" } -- packed line, no selection
        end
        local c = item.commit
        if not c then return nil end
        -- a selected ref → that branch (toggle by its effective mode)
        if selection_state.index and selection_state.commit == c then
            local ids = selected_owner_ids(c, selection_state.index)
            if ids then
                local cur = view_state.effective[ids[1]] or "normal"
                return { state = (cur == "collapsed") and "collapsed" or "expanded",
                    owners = ids, follow = c.hash, commit = c }
            end
        end
        -- a single collapsed marker (head) → expand its region
        if c.collapsed then
            local owners = {}
            for oid in pairs(c.signature or {}) do
                if (view_state.effective[oid] or "normal") == "collapsed" then owners[#owners + 1] = oid end
            end
            return { state = "collapsed", owners = owners,
                follow = c.tip and c.tip.hash, commit = c.tip }
        end
        -- a normal/junction commit → collapse the region containing it, if it is
        -- not mainline (no pinned anchor reaches it).
        local ids = collapse_owners(sig_cache.sig and sig_cache.sig[c.hash], effective_pinned(), view_state.effective)
        if ids then
            return { state = "expanded", owners = ids, follow = c.hash, commit = c }
        end
        return { state = "mainline", commit = c }
    end

    -- Recompute the footer (active modes + the branch-mode summary, §10) and
    -- apply it to the floating window. Centralised so every state change updates
    -- it the same way.
    local function update_footer()
        if lv and lv.win and lv.win.win then
            local nanchors = 0
            for _ in pairs(effective_pinned()) do nanchors = nanchors + 1 end
            local status = footer_text(opts.mirror, view_state.modes,
                opts.collapse_merged ~= false, nanchors)
            -- Debug (lane ids on, `i`): the footer-pane cutoff (seam buffer line)
            -- and height when shown, or why it is hidden.
            if show_lane_ids then
                if header_seam then
                    status = status .. (" | hdr@%s h=%d"):format(tostring(header_seam), header_height or 0)
                elseif header_dbg then
                    status = status .. " | hdr hidden: " .. header_dbg
                end
                if footer_seam then
                    status = status .. (" | ftr@%s h=%d"):format(tostring(footer_seam), footer_height or 0)
                elseif footer_dbg then
                    status = status .. " | ftr hidden: " .. footer_dbg
                end
            end
            lv.win.opts.footer = status
            pcall(vim.api.nvim_win_set_config, lv.win.win, {
                footer = lv.win.opts.footer,
                footer_pos = "center",
            })
        end
    end

    -- Apply a mode to a branch's owners, reflow, and keep the cursor on it (§10.4).
    local function set_branch(b, mode, follow)
        for _, oid in ipairs(b.owners or {}) do view_state.modes[oid] = mode end
        reflow()
        update_footer()
        if follow then goto_hash(follow) end
        place_cursor()
    end

    ---@type ListViewOptions
    local listview_options = {
        win = opts.win,
        -- The message (FLEX_COL) fills the row; refs (line_right) pin to the
        -- right edge, using the free width down to message_min (§6).
        flex = FLEX_COL,
        message_min = opts.message_min,
        overflow_hl = opts.palette.remote,
        -- Sticky cap on the author column so it only grows (no scroll bounce).
        col_max = { [AUTHOR_COL] = AUTHOR_MAX },
        -- Under mirroring, make the graph column sticky too (only grow) so the
        -- right-aligned graph + message don't bounce as the lane width changes.
        col_sticky = function() return opts.mirror and { GRAPH_COL } or {} end,
        -- Real buffer lines per item: a dual-mode labelled commit is two rows
        -- (label row + message row), everything else one. Cheap — reads only the
        -- commit's refs + mode — so the listview's buffer-line map needs no layout.
        line_count = function(item)
            return dual_two_line(opts, item and item.commit) and 2 or 1
        end,
        display = function(item)
            return display_item(opts, item, selection_state, view_state.cone)
        end,
        on_controller = function(controller)
            -- Refs first: they create sparse Commit placeholders with refs
            -- attached, which the commit stream then fills in (identity
            -- preserved), so rows render with their refs already present.
            fetch_refs(repo).next(function()
                return fetch_head(repo)
            end).next(function()
                return fetch_commits({
                    branch = opts.branches or { "--all" },
                    -- One batch of streamed commits (spec §3): link each into the
                    -- model, then lay out and insert the whole batch with a single
                    -- relayout + insert (cheaper than per-commit, and the work is
                    -- off the stdout handler — see fetch_commits).
                    ---@param commits Commit[]
                    on_batch = function(commits)
                        local new_items = {}
                        for _, item in ipairs(commits) do
                            local existing = repo.commits[item.hash]
                            if existing then
                                -- Fill the placeholder; keep its resolved refs.
                                existing.author = item.author
                                existing.date = item.date
                                existing.parents = item.parents
                                existing.message = item.message
                                existing.loaded = true

                                item = existing
                            else
                                repo.commits[item.hash] = item
                                item.children = {}
                            end

                            -- Convert parent hashes to references
                            local newParents = {}
                            for _, p in ipairs(item.parents) do
                                -- At this point parents are still the hash
                                -- strings parsed from `git log`, being resolved
                                -- to Commits.
                                local parent = get_or_create_commit(repo, p --[[@as string]])
                                table.insert(parent.children, item)
                                table.insert(newParents, parent)
                            end

                            item.parents = newParents

                            ---@type OrderItem
                            local order_item = {
                                type = "commit",
                                commit = item,
                                columns = {},
                            }
                            table.insert(repo.order, order_item)
                            new_items[#new_items + 1] = order_item
                        end

                        -- Fast path while the projection is the identity (the
                        -- common all-normal case): lay out and append the batch.
                        -- Once a branch mode makes the display a separate
                        -- projection, a streamed batch needs a full reflow (§10).
                        if repo.display == repo.order then
                            local from = #repo.order - #new_items + 1
                            refresh_columns(opts, repo.order, from)
                            controller.insert(new_items, from)
                        else
                            reflow()
                        end
                    end,
                })
            end).next(function()
                -- Stream done: apply the projection (the first-parent default
                -- collapse, §10.7) and compute the initial dimming (§12). reflow
                -- swaps in the projected graph, recomputes the cone, and refreshes.
                reflow()
                update_footer()
                -- Focus the remembered position for this repo if we have one,
                -- else HEAD; center the view on it (§2). goto_hash resolves a
                -- folded commit to its collapsed head; if the target is gone it
                -- leaves the cursor at the top. The HEAD ref (§3.2) is absent on a
                -- detached HEAD, so that case keeps the top of the graph.
                local target = saved_positions[repo_key]
                if not (target and goto_hash(target)) then
                    local headref = repo.refs["HEAD"]
                    if headref and headref.commit then goto_hash(headref.commit.hash) end
                end
                center_view()
                place_cursor()
                -- Focusing HEAD moved the pivot and scrolled the viewport, so the
                -- cone reflow ran for the wrong (top) range — recompute it for the
                -- new pivot/viewport and redraw (§12).
                update_cone()
                if lv and lv.controller then lv.controller.refresh() end
                update_panes()
            end)
        end,
    }

    opts.win.keys = opts.win.keys or {}
    -- m: cycle the merge/split style. A full reflow (re-layout from the raw order
    -- then re-pack) — the packed display can't be relaid in place (its marker
    -- groups aren't single commits).
    opts.win.keys.m = function()
        merge_style_index = (merge_style_index % #MERGE_STYLES) + 1
        opts.merge_style = vim.deepcopy(MERGE_STYLES[merge_style_index].style)
        reflow()
        update_footer() -- reflect the new mode live in the footer
        place_cursor() -- widths shifted; keep the cursor on message/ref
    end
    -- M: toggle graph mirroring (lane 1 on the right). A render-only change, so
    -- just refresh the display (no relayout/re-fetch) — like the `i` toggle.
    opts.win.keys.M = function()
        opts.mirror = not opts.mirror
        if lv and lv.controller then
            lv.controller.refresh()
        end
        update_footer()
        update_panes() -- re-align/re-render the footer for the new orientation
        place_cursor()
    end
    -- B: cycle the ref label placement (right / inline / dual; §6.1). The layout
    -- is unchanged, but dual turns labelled commits into two real rows, which
    -- changes per-item line counts — so relayout (resize the buffer + rebuild the
    -- line map), not just refresh. Reset the selection so it re-derives under the
    -- new mode (dual pre-selects the first label on the next cursor settle).
    opts.win.keys.B = function()
        label_mode_index = (label_mode_index % #LABEL_MODES) + 1
        opts.label_mode = LABEL_MODES[label_mode_index].mode
        selection_state.index = nil
        if lv and lv.controller then
            lv.controller.relayout()
        end
        update_footer()
        update_cone() -- buffer lines shifted; recompute the cone over the new map
        place_cursor()
    end
    -- <Tab>: the quick collapse ⇄ expand toggle for the branch under the cursor
    -- (§10.4). Collapse an expanded branch or expand a marker; the cursor follows
    -- the result (set_branch → goto_hash) so repeated <Tab> flips it in place.
    -- Two-state — hidden is the menu's job, so nothing vanishes under the cursor.
    opts.win.keys["<Tab>"] = function(self)
        local line = vim.api.nvim_win_get_cursor(self.win --[[@as integer]])[1]
        local b = branch_under_cursor(line)
        if not b or not b.owners or #b.owners == 0 then return end
        if b.state == "collapsed" then
            set_branch(b, "normal", b.follow)
        elseif b.state == "expanded" then
            set_branch(b, "collapsed", b.follow)
        end
    end
    -- <CR>: an action menu for the row (§10.4) — examine / diff / collapse /
    -- expand / hide, most-relevant first. On a packed line it lists every marker
    -- by name, so any branch is reachable even when not all labels fit.
    opts.win.keys["<CR>"] = function(self)
        local line = vim.api.nvim_win_get_cursor(self.win --[[@as integer]])[1]
        local item = order_at(line)
        if not item then return end
        local actions = {}
        local function add(label, run) actions[#actions + 1] = { label = label, run = run } end

        if item.type == "markers" then
            -- list every marker by name (overflow-proof access)
            for _, u in ipairs(marker_units(item)) do
                local owners = {}
                for oid in pairs(u.marker.signature or {}) do owners[#owners + 1] = oid end
                local tip = u.marker.tip and u.marker.tip.hash
                add("Expand " .. u.text, function() set_branch({ owners = owners }, "normal", tip) end)
                add("Hide " .. u.text, function() set_branch({ owners = owners }, "hidden", nil) end)
            end
        else
            local b = branch_under_cursor(line)
            if b then
                if b.state == "expanded" then
                    add("Collapse branch", function() set_branch(b, "collapsed", b.follow) end)
                    add("Hide branch", function() set_branch(b, "hidden", nil) end)
                elseif b.state == "collapsed" then
                    add("Expand branch", function() set_branch(b, "normal", b.follow) end)
                    add("Hide branch", function() set_branch(b, "hidden", nil) end)
                end
                if b.commit then
                    add(b.state == "collapsed" and "Examine tip commit" or "Examine commit",
                        function() open_commit_view(opts, b.commit) end)
                    if opts.diff and opts.diff.open then
                        add("Open diff", function() open_diff(opts, b.commit) end)
                    end
                end
            end
        end

        if #actions == 0 then return end
        vim.ui.select(actions, {
            prompt = "gitloom",
            format_item = function(a) return a.label end,
        }, function(choice)
            if choice then choice.run() end
        end)
    end
    -- D: open the commit's diff in the external diff viewer (§11.5).
    opts.win.keys.D = function(self)
        local w = self and self.win
        if not w then return end
        local line = vim.api.nvim_win_get_cursor(w)[1]
        local item = order_at(line)
        if not item or not item.commit or item.commit.collapsed then
            return -- a collapsed head has no single commit to diff
        end
        open_diff(opts, item.commit)
    end
    -- K: float with the full lane breakdown for the commit under the cursor.
    opts.win.keys.K = function(self)
        local w = self and self.win
        if not w then return end
        local line = vim.api.nvim_win_get_cursor(w)[1]
        local item = order_at(line)
        if not item or not item.commit then
            return
        end
        vim.lsp.util.open_floating_preview(format_lane_info(item), "", {
            border = "rounded",
            focusable = true,
        })
    end
    -- d: toggle the date column between absolute and relative. Render-only.
    opts.win.keys.d = function()
        opts.date_mode = (opts.date_mode == "relative") and "absolute" or "relative"
        if lv and lv.controller then
            lv.controller.refresh()
        end
        place_cursor()
    end
    -- H: toggle reachability highlighting (dimming) on/off (§12). Render-only.
    opts.win.keys.H = function()
        opts.highlight = opts.highlight == false
        update_cone() -- recompute for the current pivot so the toggle takes effect
        if lv and lv.controller then
            lv.controller.refresh()
        end
        place_cursor()
    end
    -- c: toggle the first-parent focus (§10.7) — collapse every non-mainline
    -- branch vs. show the full graph. Changes per-item line counts, so reflow.
    opts.win.keys.c = function()
        opts.collapse_merged = opts.collapse_merged == false
        reflow()
        update_footer()
        place_cursor()
    end
    -- p: toggle marker packing (§10.4) — merge concurrent collapsed heads onto
    -- shared lines vs. one per line. Changes line counts, so reflow.
    opts.win.keys.p = function()
        opts.pack_markers = opts.pack_markers == false
        reflow()
        update_footer()
        place_cursor()
    end
    -- P: pin / unpin the branch under the cursor as an **anchor** (§10.6).
    -- Anchors stay normal under focus; everything else collapses. HEAD is pinned
    -- by default. Acts on the selected ref (or the region under the cursor),
    -- restricted to real refs; changes the focus default, so reflow.
    opts.win.keys.P = function(self)
        local w = self and self.win
        if not w then return end
        local line = vim.api.nvim_win_get_cursor(w)[1]
        local b = branch_under_cursor(line)
        if not b or not b.owners then return end
        -- Only refs are pinnable (v1, §10.6) — drop anonymous merge-parent owners.
        local targets = {}
        for _, oid in ipairs(b.owners) do
            if repo.refs[oid] then targets[#targets + 1] = oid end
        end
        if #targets == 0 then return end
        local want = not effective_pinned()[targets[1]]
        for _, oid in ipairs(targets) do view_state.pinned[oid] = want end
        reflow()
        update_footer()
        if b.follow then goto_hash(b.follow) end
        place_cursor()
    end
    -- i: toggle the per-lane id column before the message (main view + footer).
    opts.win.keys.i = function()
        show_lane_ids = not show_lane_ids
        if lv and lv.controller then
            lv.controller.refresh()
        end
        update_panes() -- re-render the footer with/without its lane-id debug column
        place_cursor()
    end
    -- F: toggle the context panes (footer) on/off.
    opts.win.keys.F = function()
        opts.panes = opts.panes == false
        update_panes() -- builds it when on, closes it when off
        place_cursor()
    end
    -- ?: float listing all keybindings.
    opts.win.keys["?"] = function()
        vim.lsp.util.open_floating_preview(help_lines(), "", {
            border = "rounded",
            focusable = true,
        })
    end
    -- h / l: move the ref selection on the current row (§2). Positions are the
    -- branch groups then tags (decoration_texts) plus the message (rightmost,
    -- default). Selection is held by commit identity so it follows the commit
    -- across reflow; the cursor is moved onto the selected ref (or the message).
    local selection_visible = false -- a decoration (not the message) is selected
    local function move_ref(dir)
        return function(self)
            local line = vim.api.nvim_win_get_cursor(self.win --[[@as integer]])[1]
            local item, _, sub = order_at(line)
            -- On a packed marker line, selection moves among the markers (§10.4).
            if item and item.type == "markers" then
                local count = #marker_units(item)
                local pos = (selection_state.commit == item) and selection_state.index or nil
                selection_state.commit = item
                selection_state.index = move_selection(pos, count, dir)
                selection_visible = selection_state.index ~= nil
                if lv and lv.controller then lv.controller.refresh() end
                place_cursor()
                return
            end
            local commit = item and item.commit or nil
            if not commit then
                return
            end
            -- In dual mode the labels live on the first row only; on the message
            -- row (sub 1) there is nothing to select.
            if opts.label_mode == "dual" and sub ~= 0 then
                return
            end
            local count = #decoration_texts(commit)
            local pos = (selection_state.commit == commit) and selection_state.index or nil
            selection_state.commit = commit
            selection_state.index = move_selection(pos, count, dir)
            selection_visible = selection_state.index ~= nil
            if lv and lv.controller then
                lv.controller.refresh()
            end
            place_cursor()
        end
    end
    opts.win.keys.h = move_ref(-1)
    opts.win.keys.l = move_ref(1)

    lv = listview.open(listview_options)

    -- Cursor parking (§2/§7): cursorline marks the row; the cursor rests at the
    -- commit message, or on the selected ref. place_cursor reads the rendered
    -- buffer line and positions the cursor accordingly.
    if lv and lv.win and lv.win.win then
        local win, buf = lv.win.win, lv.win.buf
        pcall(vim.api.nvim_set_option_value, "cursorline", true, { win = win })

        -- Move the cursor onto the display row that now represents `hash` — a real
        -- commit row, the marker (head/packed) whose region contains it, or a
        -- junction. Used after a collapse/expand reflow so the toggle stays put,
        -- and to focus HEAD / the remembered position on open (§2). Returns true
        -- when a row was found and the cursor moved, false otherwise.
        goto_hash = function(hash)
            if not hash then return false end
            for i, it in ipairs(repo.display or {}) do
                local found = it.commit and it.commit.hash == hash
                if not found and it.commit and it.commit.collapsed and it.commit.region then
                    for _, h in ipairs(it.commit.region) do
                        if h == hash then found = true; break end
                    end
                end
                if not found and it.type == "markers" then
                    for _, m in ipairs(it.markers or {}) do
                        if m.hash == hash then found = true; break end
                        for _, h in ipairs(m.region or {}) do
                            if h == hash then found = true; break end
                        end
                        if found then break end
                    end
                end
                if found then
                    local lnum = (lv.controller.item_start and lv.controller.item_start(i)) or i
                    pcall(vim.api.nvim_win_set_cursor, win, { lnum, 0 })
                    return true
                end
            end
            return false
        end

        place_cursor = function()
            local line = vim.api.nvim_win_get_cursor(win)[1]
            local item = order_at(line)
            -- A packed marker line: park on the selected marker's label (§10.4).
            if item and item.type == "markers" then
                local col = nil
                if selection_state.commit == item and selection_state.index then
                    local u = marker_units(item)[selection_state.index]
                    if u then
                        local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
                        col = ref_byte_col(text, u.text)
                    end
                end
                if not col and lv and lv.controller and lv.controller.col_offset then
                    col = lv.controller.col_offset(line, "line", FLEX_COL)
                end
                pcall(vim.api.nvim_win_set_cursor, win, { line, col or 0 })
                return
            end
            if not item or not item.commit then return end
            local col = nil
            -- A selected ref: jump onto it. The label text lives on the rendered
            -- buffer line of the current row (the label row in dual; the commit
            -- line otherwise), so find it there; if it is not on this row (e.g.
            -- the message row, or a `+N`-collapsed ref) we fall back to the flex
            -- column below.
            if selection_state.commit == item.commit and selection_state.index then
                local texts = decoration_texts(item.commit)
                if selection_state.index <= #texts then
                    local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
                    col = ref_byte_col(text, texts[selection_state.index])
                end
            end
            -- Otherwise park at the start of the flex column (message / labels).
            if not col and lv and lv.controller and lv.controller.col_offset then
                col = lv.controller.col_offset(line, "line", FLEX_COL)
            end
            pcall(vim.api.nvim_win_set_cursor, win, { line, col or 0 })
        end

        -- Center the view vertically on the cursor's row when there is room,
        -- clamped at the top/bottom of the graph (exactly `zz`'s behaviour). Used
        -- to focus HEAD / the remembered position on open (§2).
        center_view = function()
            pcall(vim.api.nvim_win_call, win, function() vim.cmd("normal! zz") end)
        end

        -- The hash of the commit under the cursor at `line`: a real commit row
        -- yields its hash; a packed marker line (§10.4) yields the selected (or
        -- first) marker's tip; any other row yields nil. Drives the remembered
        -- position (§2).
        cursor_hash = function(line)
            local item = order_at(line)
            if not item then return nil end
            if item.commit then return item.commit.hash end
            if item.type == "markers" then
                local units = marker_units(item)
                local u = units[selection_state.index] or units[1]
                if u and u.marker and u.marker.tip then return u.marker.tip.hash end
            end
            return nil
        end

        -- Recompute the pivot's cone over the visible rows and re-mark track
        -- activeness (§12). Cheap (O(visible)); the caller then refreshes. The
        -- window gives *buffer* lines; map them to order indices (a dual labelled
        -- commit spans two buffer lines) so the cone walk stays in order space.
        update_cone = function()
            local topbuf = vim.api.nvim_win_call(win, function() return vim.fn.line("w0") end)
            local botbuf = vim.api.nvim_win_call(win, function() return vim.fn.line("w$") end)
            local curbuf = vim.api.nvim_win_get_cursor(win)[1]
            local item, cur = order_at(curbuf)
            local top = select(2, order_at(topbuf))
            local bottom = select(2, order_at(botbuf))
            -- Lanes are attached by Phase 1 (columns.layout, via build_graph /
            -- refresh_columns); walk them from the pivot to mark highlights (§12).
            if not (item and item.commit) then
                view_state.cone = nil
                return
            end
            view_state.cone = mark_reachable(repo.display, cur, top, bottom)
        end

        -- Recomputing the cone and redrawing on *every* CursorMoved makes held
        -- j/k feel sluggish on large graphs, so debounce it: each move re-arms a
        -- short timer and only the last one — once the cursor settles — does the
        -- work. The walk stays synchronous (Lua is single-threaded and the editor
        -- API isn't usable off the main loop); we just run it far less often.
        -- `applying` suppresses the WinScrolled the deferred refresh may emit. A
        -- real scroll that lands during that window is remembered in `pending` and
        -- replayed, so the footer never goes stale on a dropped scroll.
        local CONE_DEBOUNCE_MS = 60
        local cone_gen, applying, pending = 0, false, false
        local function schedule_cone_update()
            cone_gen = cone_gen + 1
            local gen = cone_gen
            vim.defer_fn(function()
                if gen ~= cone_gen or not vim.api.nvim_win_is_valid(win) then return end
                update_cone()
                applying = true
                if lv and lv.controller then lv.controller.refresh() end
                applying = false
                update_panes()
                if pending then pending = false; schedule_cone_update() end
            end, CONE_DEBOUNCE_MS)
        end

        -- Rebuild the dimmed highlight groups after a colorscheme change (the
        -- derived groups are wiped by `hi clear`) and redraw (§12).
        vim.api.nvim_create_autocmd("ColorScheme", {
            group = vim.api.nvim_create_augroup("GitloomDim_" .. buf, { clear = true }),
            callback = function()
                reset_dim_cache()
                reset_gen_cache()
                if lv and lv.controller then
                    lv.controller.refresh()
                end
            end,
        })

        local group = vim.api.nvim_create_augroup("Gitloom_" .. buf, { clear = true })

        -- On moving to a different row, reset the selection to the message,
        -- recompute the cone for the new pivot, redraw the dimming, and re-park.
        local last_line = nil
        vim.api.nvim_create_autocmd("CursorMoved", {
            group = group,
            buffer = buf,
            callback = function()
                local line = vim.api.nvim_win_get_cursor(win)[1]
                if line == last_line then return end
                last_line = line
                -- Remember the commit under the cursor for this repo so reopening
                -- the graph restores the position (§2). Skip rows with no commit so
                -- a marker-less line never clobbers a good remembered position.
                local h = cursor_hash(line)
                if h then saved_positions[repo_key] = h end
                local item, _, sub = order_at(line)
                -- Landing on a packed marker line pre-selects its first marker
                -- (§10.4), so h/l and <CR> act on a marker right away.
                if item and item.type == "markers" then
                    selection_state.commit = item
                    selection_state.index = (#marker_units(item) > 0) and 1 or nil
                    selection_visible = selection_state.index ~= nil
                    place_cursor()
                    schedule_cone_update()
                    return
                end
                local commit = item and item.commit or nil
                selection_state.commit = commit
                -- In dual mode landing on a labelled commit's first row (sub 0,
                -- where the labels live) pre-selects the first one (§2/§6.1); the
                -- message row and other modes default to the message (no
                -- selection).
                local auto = opts.label_mode == "dual" and sub == 0
                    and commit and #decoration_texts(commit) > 0
                selection_state.index = auto and 1 or nil
                selection_visible = auto and true or false
                -- Park the cursor now (responsive); the cone + dimming redraw is
                -- debounced so it lands once movement stops.
                place_cursor()
                schedule_cone_update()
            end,
        })

        -- Scrolling (no row change) shifts the visible window, so the
        -- window-bounded cone must be recomputed for the newly visible rows too.
        -- Scoped to this window; a guard prevents re-entry from the refresh.
        vim.api.nvim_create_autocmd("WinScrolled", {
            group = group,
            pattern = tostring(win),
            callback = function()
                if not vim.api.nvim_win_is_valid(win) then return end
                if applying then pending = true; return end -- replayed after the refresh
                schedule_cone_update()
            end,
        })

        -- Context panes (spec §6.2): two borderless overlays summarising off-screen
        -- topology folded onto the pinned anchors. The FOOTER (below) continues the
        -- bottom-seam lanes down their first-parent chains to the roots (a sub-DAG
        -- rebuild, `pane.continue`/`footer`). The HEADER (above) is a vertical
        -- compaction of the already-laid-out projection slice above the cutoff
        -- (`pane.header`): linear runs drop, junctions go node-less, heads become ◍,
        -- pinned anchors keep a labelled row. Both seed/match the seam so lanes meet
        -- the main view. (Sizing hysteresis and the async rebuild are still to come.)
        local pane = require("gitloom.pane")
        local pane_ns = vim.api.nvim_create_namespace("gitloom_pane")
        -- Debug overlay (toggled with `i`): a full-line highlight on the buffer line the
        -- header treats as its cutoff/seam (and the footer's), so a misaligned seam is
        -- visible. Lives on the MAIN buffer; refreshed on every pane rebuild.
        local seam_ns = vim.api.nvim_create_namespace("gitloom_seam")
        -- GitloomCutoff: the first VISIBLE main-view line (ground truth). GitloomSeam:
        -- the line the header read its boundary from (the system's belief). They should
        -- be adjacent; a gap (or a hidden seam) means the seam is misaligned.
        vim.api.nvim_set_hl(0, "GitloomCutoff", { link = "Search", default = true })
        vim.api.nvim_set_hl(0, "GitloomSeam", { link = "DiffChange", default = true })
        local PANE_MAX = 12
        -- The header (off-screen-newer) diverges going up — its content grows ~1:1
        -- with how deep the seam is read — so it is capped tighter than the footer to
        -- stay a glanceable summary; the surplus collapses into a `+N above`.
        local HEADER_MAX = 8
        -- The two overlays: the footer (off-screen-older topology, below) and the
        -- header (off-screen-newer topology, above). Each is `{ win, buf }`.
        local footer = { win = nil, buf = nil }
        local header = { win = nil, buf = nil }
        local last_pane_err -- throttle repeated pane-error notifications
        -- Force scrolloff off for this window (any inherited value interacts badly
        -- with the overlay and scrolling); revisit once the stuck-scroll is solved.
        pcall(vim.api.nvim_set_option_value, "scrolloff", 0, { scope = "local", win = win })
        -- Inline, node-less merge style for the pane: joins render on one row (no
        -- fan lines) and junctions draw node-less, so the pane stays compact.
        local pane_opts = vim.tbl_extend("force", {}, opts)
        pane_opts.merge_style = {
            allow_merge_on_split = false,
            merge_on_separate_line = false,
            split_on_separate_line = false,
        }

        local function close_pane(p)
            if p.win and vim.api.nvim_win_is_valid(p.win) then
                pcall(vim.api.nvim_win_close, p.win, true)
            end
            p.win = nil
        end
        -- The buffer line a seam tag (e.g. "12s"/"12c") points at.
        local function seam_line(tag) return tag and tonumber(tostring(tag):match("^(%d+)")) end
        -- Refresh the debug cutoff highlight (the `i` overlay). Two full-line marks on
        -- the MAIN buffer, cleared first so they track the view:
        --   • GitloomCutoff — the first FULLY-visible line (the topmost line of the
        --     main view, just below the header overlay): the ground truth.
        --   • GitloomFooterCutoff — the header's seam line (what the system *thinks* the
        --     cutoff is). If the two differ — or the seam line is hidden behind the
        --     overlay — the seam is misaligned (the bug we are chasing).
        local function mark_cutoff()
            pcall(vim.api.nvim_buf_clear_namespace, buf, seam_ns, 0, -1)
            if not show_lane_ids then return end
            pcall(function()
                -- The header's own seam line (may sit behind the overlay).
                local hs = seam_line(header_seam)
                if hs and hs >= 1 and hs <= vim.api.nvim_buf_line_count(buf) then
                    vim.api.nvim_buf_set_extmark(buf, seam_ns, hs - 1, 0,
                        { line_hl_group = "GitloomSeam", priority = 248 })
                end
                -- The first line whose columns row is at/below the overlay's bottom edge
                -- — the topmost VISIBLE line of the main view.
                local r0 = vim.api.nvim_win_call(win, function() return vim.fn.win_screenpos(win)[1] end)
                local floor = r0 + (header_height or 0)
                local w0 = vim.api.nvim_win_call(win, function() return vim.fn.line("w0") end)
                local lastl = vim.api.nvim_buf_line_count(buf)
                for l = w0, lastl do
                    local rr = vim.api.nvim_win_call(win, function() return vim.fn.screenpos(win, l, 1).row end)
                    if rr >= floor then
                        vim.api.nvim_buf_set_extmark(buf, seam_ns, l - 1, 0,
                            { line_hl_group = "GitloomCutoff", priority = 250 })
                        break
                    end
                end
            end)
        end

        local function close_panes()
            close_pane(footer); footer_seam, footer_height = nil, nil
            close_pane(header); header_seam, header_height = nil, nil
            pcall(vim.api.nvim_buf_clear_namespace, buf, seam_ns, 0, -1)
        end

        -- A pane is a borderless overlay covering `height` content rows of the main
        -- window (relative="win"), so its lanes butt directly against the seam with
        -- no border or gap (the sticky-scroll pattern). `top` pins it to the very
        -- top (the header); otherwise the bottom (the footer). The covered main
        -- rows are exactly the off-screen topology the pane replaces with its
        -- summary.
        local function ensure_pane_win(p, top, height)
            local wh = vim.api.nvim_win_get_height(win)
            local cfg = {
                relative = "win", win = win,
                row = top and 0 or math.max(0, wh - height), col = 0,
                width = vim.api.nvim_win_get_width(win),
                height = height,
                style = "minimal",
                focusable = false,
                zindex = 200,
            }
            if p.win and vim.api.nvim_win_is_valid(p.win) then
                pcall(vim.api.nvim_win_set_config, p.win, cfg)
                return
            end
            p.buf = vim.api.nvim_create_buf(false, true)
            p.win = vim.api.nvim_open_win(p.buf, false, cfg)
            -- A faint background so the pane reads as a distinct band while its
            -- lanes still line up with the main graph.
            pcall(vim.api.nvim_set_option_value, "winhl",
                "Normal:NormalFloat,NormalFloat:NormalFloat", { win = p.win })
        end

        -- Render topology-only pane rows (graph glyphs + ref labels, no
        -- date/author/message; §6.2) into the pane buffer with lane colours.
        -- Align the lanes under the main graph: in normal mode the graph starts at
        -- `goff` (the date+author width), so left-pad by it; under mirror the main
        -- graph is right-aligned at the message edge (`foff`), so right-pad so the
        -- glyphs end there.
        -- A dashed-vertical (┊) separator row: one bar per lane crossing `row`'s
        -- seam edge (`dir` = "up" for the footer's top edge, "down" for the
        -- header's bottom edge), so the eye sees each lane being continued.
        local function sep_row(row, dir)
            local sep = {}
            for j, cell in ipairs(row.columns) do
                local lane
                for _, s in ipairs(cell.lanes or {}) do
                    if s.connectivity[dir] then lane = s; break end
                end
                sep[j] = lane
                    and { connectivity = { up = true, down = true },
                        lanes = { { connectivity = { up = true, down = true }, id = lane.id, color = lane.color } } }
                    or { connectivity = {}, lanes = {} }
            end
            return sep
        end

        -- Render topology-only pane rows. `is_header` flips the layout: a footer
        -- puts its seam separator on TOP (lanes enter from the seam above, then the
        -- rows descend to the root); a header pins the tip at the TOP and the seam
        -- at the BOTTOM, padding any slack between the rows and the seam with
        -- straight lane bars so growth/shrink happens at the bottom and the tip
        -- never bounces (§6.2). `overflow` (header) renders a leading `+N above`;
        -- `height` (header) is the exact overlay height the seam was sized for.
        local function render_pane(buf, rows, goff, foff, is_header, overflow, height)
            local lines, marks = {}, {}
            -- Render one columns array (graph glyphs) into a padded, aligned line,
            -- recording highlight extmarks; returns the line text for suffixing.
            local function glyph_line(columns)
                local g = get_column_chars(opts, columns, false)
                -- Dash every straight run so the pane reads as a sketch/summary:
                -- vertical │ → ┊ (quadruple), horizontal ─ → ╌ (double — lighter
                -- horizontally). Both 3-byte, so highlight byte offsets are
                -- unchanged. Corners/junctions have no dashed variant, so they
                -- stay solid.
                local gtext = (g.text or ""):gsub("│", "┊"):gsub("─", "╌")
                local pad = goff or 0
                if opts.mirror then
                    -- Right-align so the glyphs end at the graph's right edge (where
                    -- the message begins); columns are adjacent, no separator.
                    pad = math.max(0, (foff or 0) - vim.api.nvim_strwidth(gtext))
                end
                local li = #lines + 1
                for _, hl in ipairs(g.highlight or {}) do
                    marks[#marks + 1] = { li - 1, pad + hl.start_pos, pad + hl.end_pos, hl.hl }
                end
                return string.rep(" ", pad) .. gtext
            end

            local function body_line(row)
                local text = glyph_line(row.columns)
                local c = row.commit
                local labels = c and decoration_texts(c) or {}
                if #labels > 0 then text = text .. " " .. table.concat(labels, " ") end
                if c and c.collapsed and c.count then text = text .. (" (%d)"):format(c.count) end
                -- Debug (toggled by `i`): the distinct lane ids on this row.
                if show_lane_ids then
                    local ids, seen = {}, {}
                    for _, col in ipairs(row.columns or {}) do
                        for _, s in ipairs(col.lanes or {}) do
                            if s.id and not seen[s.id] then seen[s.id] = true; ids[#ids + 1] = s.id end
                        end
                    end
                    if #ids > 0 then text = text .. "  [" .. table.concat(ids, ",") .. "]" end
                end
                return text
            end

            if is_header then
                local ovfrow = (overflow and overflow > 0) and 1 or 0
                if ovfrow == 1 then
                    lines[#lines + 1] = (string.rep(" ", goff or 0)) .. ("+%d above"):format(overflow)
                end
                for _, row in ipairs(rows) do lines[#lines + 1] = body_line(row) end
                -- Pad the bottom with seam bars down to the exact overlay height, so
                -- the seam (last bar row) butts the main view's top. At least one.
                local seams = math.max(1, (height or (#rows + 1)) - ovfrow - #rows)
                if rows[#rows] then
                    local sep = sep_row(rows[#rows], "down")
                    for _ = 1, seams do lines[#lines + 1] = glyph_line(sep) end
                end
            else
                if rows[1] then lines[#lines + 1] = glyph_line(sep_row(rows[1], "up")) end
                for _, row in ipairs(rows) do lines[#lines + 1] = body_line(row) end
            end
            if #lines == 0 then lines = { "" } end
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
            vim.api.nvim_buf_clear_namespace(buf, pane_ns, 0, -1)
            for _, m in ipairs(marks) do
                pcall(vim.api.nvim_buf_set_extmark, buf, pane_ns, m[1], m[2],
                    { end_col = m[3], hl_group = m[4] })
            end
        end

        -- Hide both panes and record why (surfaced in the `i` status).
        local function hide_all(why)
            footer_dbg, header_dbg = why, why
            close_panes()
            update_footer()
        end

        -- The pane build, wrapped so any error is fully contained — it runs inside
        -- the scroll/cone path, and must never break the main view's scrolling.
        local function build_panes()
            if opts.panes == false then return hide_all("off") end
            if not vim.api.nvim_win_is_valid(win) then return end
            -- Panes are a focus feature: need HEAD and a graph.
            if not (repo.head and repo.refs[repo.head]) then return hide_all("no HEAD") end
            if not repo.display or #repo.display == 0 then return hide_all("no display") end

            local pinned = effective_pinned()
            -- repo.order index per commit hash, for "below the cutoff" tests (footer).
            local idx = {}
            for i, it in ipairs(repo.order) do idx[it.commit.hash] = i end
            local function item_order(item)
                local c = item and item.commit
                if c then return idx[(c.tip and c.tip.hash) or c.hash] end
                local m = item and item.markers and item.markers[1]
                if m then return idx[(m.tip and m.tip.hash) or m.hash] end
            end
            -- repo.display index per commit hash, for "above the cutoff" (header).
            local didx = {}
            for i, it in ipairs(repo.display) do
                local c = it.commit
                if c then didx[(c.tip and c.tip.hash) or c.hash] = i end
                for _, m in ipairs(it.markers or {}) do didx[(m.tip and m.tip.hash) or m.hash] = i end
            end
            -- DisplayNode per hash (own/tip/region) — for resolving pinned tips and
            -- the boundary lanes' projected begins to the projected nodes (§6.2). Also
            -- each branch's main-view lane { id, color } (its first-parent lane), so
            -- the header can colour every branch the SAME as the graph (distinct per
            -- branch, not all the pivot's colour).
            -- dnode (hash → node), lane_main (hash → its branch's main-view {id,color})
            -- and node_col (hash → the COLUMN the node sits in, i.e. its left-right
            -- position in the graph) so the header can order forks to match the graph.
            local dnode, lane_main, node_col = {}, {}, {}
            for _, it in ipairs(repo.display) do
                local pl = it.parent_lanes
                local main = pl and pl[1] and { id = pl[1].id, color = pl[1].color }
                local hcol = {} -- this row's rendered nodes → their column
                for j, cell in ipairs(it.columns or {}) do
                    if cell.has_commit and cell.commit then hcol[cell.commit.hash] = j end
                end
                local function add(n)
                    if not n then return end
                    local col = hcol[n.hash]
                    dnode[n.hash] = n
                    if main then lane_main[n.hash] = main end
                    if col then node_col[n.hash] = col end
                    if n.tip then
                        dnode[n.tip.hash] = n
                        if main then lane_main[n.tip.hash] = main end
                        if col then node_col[n.tip.hash] = col end
                    end
                    for _, hh in ipairs(n.region or {}) do
                        dnode[hh] = n
                        if main then lane_main[hh] = main end
                        if col then node_col[hh] = col end
                    end
                end
                add(it.commit)
                for _, m in ipairs(it.markers or {}) do add(m) end
            end
            local function order_of(n) return n and didx[(n.tip and n.tip.hash) or n.hash] end
            local function lane_of(n) return n and lane_main[(n.tip and n.tip.hash) or n.hash] end
            local function col_of(n) return n and node_col[(n.tip and n.tip.hash) or n.hash] end

            -- The lanes crossing one edge of whichever RENDERED line sits at
            -- absolute screen row `target` — a commit's columns line, or its split
            -- (above) / merge (below) virtual line. The cutoff can fall on a
            -- split/merge virtual line, which has no buffer line, so reading the
            -- nearest buffer line's lanes was wrong. `up` reads the top edge
            -- (ascending lanes — for the header); default the bottom (footer).
            -- Returns the lanes, a debug tag, the seam's DISPLAY index (header
            -- slice), and its repo.order index (footer cutoff tests).
            local function boundary_at(target, up)
                local w0 = vim.api.nvim_win_call(win, function() return vim.fn.line("w0") end)
                local last = vim.api.nvim_win_call(win, function() return vim.fn.line("w$") end)
                for l = last, w0, -1 do
                    local r = vim.fn.screenpos(win, l, 1).row
                    if r > 0 then
                        local item, disp_idx = order_at(l)
                        -- The item's rendered block spans `r-1` (split, above), `r`
                        -- (columns), `r+1` (merge, below). The seam may fall on any.
                        if item and (r == target or (item.split and r - 1 == target)
                                or (item.merge and r + 1 == target)) then
                            if up then
                                -- HEADER: read the TOP edge of whichever rendered
                                -- sub-line of the item actually sits AT the seam (the
                                -- first *uncovered* screen row). The seam item's block
                                -- spans r-1 (split), r (columns), r+1 (merge); reading
                                -- the wrong one is an off-by-one into the COVERED region.
                                --   • merge at the seam (r+1==target): the commit row is
                                --     covered and only its merge (virtual) line shows —
                                --     read the merge's top edge (the lane up into the
                                --     commit), NOT the covered columns line above it.
                                --   • otherwise (columns/split at the seam): read the
                                --     split when present so a fork right below the
                                --     viewport shows all its off-screen children.
                                local line, suff
                                if item.merge and r + 1 == target then
                                    line, suff = item.merge, "m"
                                else
                                    line, suff = (item.split or item.columns), (item.split and "s" or "c")
                                end
                                return pane.boundary_of(line, true), l .. suff, disp_idx, item_order(item)
                            elseif r == target and item.columns then
                                return pane.boundary_of(item.columns), l .. "c", disp_idx, item_order(item)
                            elseif item.merge and r + 1 == target then
                                return pane.boundary_of(item.merge), l .. "m", disp_idx, item_order(item)
                            elseif item.split and r - 1 == target then
                                return pane.boundary_of(item.split), l .. "s", disp_idx, item_order(item)
                            end
                        end
                    end
                end
                return {}, "?"
            end

            -- The absolute screen row of the seam — the main row adjacent to an
            -- `sh`-tall overlay. Anchored on the window's own position so it is
            -- independent of w0's virtual lines. `top` (header): the row just below
            -- the top overlay; default (footer): the row just above the bottom one.
            local function seam_for(sh, top)
                return vim.api.nvim_win_call(win, function()
                    local r0 = vim.fn.win_screenpos(win)[1]
                    if top then return r0 + sh end
                    return r0 + vim.api.nvim_win_get_height(win) - sh
                end)
            end

            -- Build the footer for a seam screen row: continue ONLY the lanes
            -- crossing it down their first-parent chains to a root
            -- (`pane.continue`), condensed, seeded and laid out — every active lane
            -- reaches a root, no non-active branch introduced. Returns rows, tag on
            -- success; nil, reason on failure.
            local function build_footer(target)
                local boundary, tag, _, seam_idx = boundary_at(target)
                if not next(boundary) then return nil, "no lanes@" .. target end
                -- Pinned-ref tips below the cutoff that aren't on an active lane —
                -- add them so a divergent pinned branch still shows as a marker.
                local extra = {}
                if seam_idx then
                    for name in pairs(pinned) do
                        local ref = repo.refs[name]
                        if ref and ref.commit and (idx[ref.commit.hash] or 0) > seam_idx then
                            extra[#extra + 1] = ref.commit
                        end
                    end
                end
                local cond = pane.continue(boundary, pinned, extra, function(n) return idx[n.hash] end)
                if #cond.items == 0 then return nil, "empty graph@" .. target end
                local res = pane.footer(pane_opts, cond.items, boundary, cond.node_of_hash)
                return res.rows, tag
            end

            -- Build the HEADER for an overlay covering at least `cover` screen rows
            -- (off-screen-NEWER topology). The seam is computed from the display items
            -- directly (`pane.header_seam` — NO screenpos, so it's testable and never
            -- splits a commit across the seam: a covered commit's trailing merge line is
            -- covered with it). `pane.continue_up` then rebuilds the focused sub-DAG and
            -- `pane.header` lays it out seam-up. Returns rows, tag, actual-cover on
            -- success; nil, reason on failure. `actual cover` ≥ `cover` (rounded up to
            -- the commit boundary) is the overlay height the rows must fit in.
            local function build_header(cover)
                local w0 = vim.api.nvim_win_call(win, function() return vim.fn.line("w0") end)
                local _, w0disp = order_at(w0)
                if not w0disp or w0disp <= 1 then return nil, "at top" end
                local seam = pane.header_seam(repo.display, w0disp, cover)
                if not seam then return nil, "past end" end
                local line = (seam.kind == "split") and seam.item.split or seam.item.columns
                local boundary = pane.boundary_of(line, true)
                if not next(boundary) then return nil, "no lanes@" .. seam.idx end
                -- Pinned anchor tips above the cutoff, as the display nodes that
                -- represent them (consistent with the boundary lanes' projected begins).
                local tips = {}
                for name in pairs(pinned) do
                    local ref = repo.refs[name]
                    local dn = ref and ref.commit and dnode[ref.commit.hash]
                    if dn and (order_of(dn) or math.huge) < seam.idx then tips[#tips + 1] = dn end
                end
                local cond = pane.continue_up(boundary, tips, pinned, order_of, seam.idx)
                if #cond.items == 0 then return nil, "empty@" .. seam.idx end
                local res = pane.header(cond.items, boundary, cond.node_of_hash, lane_of, col_of)
                if #res.rows == 0 then return nil, "norows@" .. seam.idx end
                return res.rows, seam.idx .. (seam.kind == "split" and "s" or "c"), seam.cover
            end

            -- The footer overlay is the separator row + the footer rows, so its
            -- screen height is `#rows + 1`. Grow the row count until it stabilises
            -- (§6.2 sizing), bounded by PANE_MAX. The final rows + seam come from the
            -- SAME build so the overlay height and the boundary line up.
            local function converge_footer()
                local R, rows, seam_tag = 0, nil, nil
                for _ = 1, PANE_MAX do
                    local r, tag = build_footer(seam_for(R + 1))
                    if not r then return nil, tag end
                    rows, seam_tag = r, tag
                    local nr = math.min(#r, PANE_MAX)
                    if nr == R then break end -- converged
                    R = nr
                end
                return rows, seam_tag
            end

            -- Size the HEADER by a **min-fit search** (spec §6.2): start at the
            -- guess `cover = (#pinned tips above the viewport) + 1` screen rows, build
            -- the seam that budget implies, and grow `cover` until the folded rows fit
            -- in the overlay (the rows + the seam separator). The overlay height is the
            -- seam's actual cover (whole commit blocks, so ≥ the request). Cap at
            -- PANE_MAX, then clip continuity-preserving with `+N above`. Returns rows,
            -- tag, overlay-height, overflow.
            local function converge_header()
                local w0 = vim.api.nvim_win_call(win, function() return vim.fn.line("w0") end)
                local _, w0disp = order_at(w0)
                -- Nothing scrolled off above the viewport ⇒ no header at all.
                if (w0disp or 1) <= 1 then return nil, "at top" end
                local P = 0
                for name in pairs(pinned) do
                    local ref = repo.refs[name]
                    local di = ref and ref.commit and didx[ref.commit.hash]
                    if di and di < (w0disp or 1) then P = P + 1 end
                end
                local rows, seam_tag, height
                -- Clamp the guess to the cap so the loop always runs at least once.
                for cover = math.min(math.max(2, P + 1), HEADER_MAX), HEADER_MAX do
                    local r, tag, actual = build_header(cover)
                    if not r then return nil, tag end
                    rows, seam_tag, height = r, tag, actual
                    if #r + 1 <= actual then return r, tag, actual, 0 end -- fits the overlay
                end
                if not rows then return nil, "no rows" end
                -- Didn't fit: clip to the overlay height while **preserving continuity**
                -- — keep the seam-continuous bottom slice and elide the far tips into
                -- `+N above` (room for the +N line and the seam separator). Eliding the
                -- middle instead would tear every lane at the gap (the old bug).
                local kept, ovf = pane.cap(rows, math.max(1, height - 2), true)
                return kept, seam_tag, height, ovf
            end

            -- Offsets of the main graph column so the pane lanes line up: `goff` =
            -- its left edge (date+author width), `foff` = the message edge (the
            -- graph's right side under mirror). The columns are sticky-aligned, so
            -- any visible commit row measures the same offset; use the first visible
            -- line. col_offset is in BYTES; convert to display columns via the
            -- line's text so multi-byte author names don't skew it.
            local goff, foff = 0, 0
            local refl = vim.api.nvim_win_call(win, function() return vim.fn.line("w0") end)
            if lv.controller.col_offset then
                local ltext = vim.api.nvim_buf_get_lines(buf, refl - 1, refl, false)[1] or ""
                goff = vim.fn.strdisplaywidth(ltext:sub(1, lv.controller.col_offset(refl, "line", GRAPH_COL) or 0))
                foff = vim.fn.strdisplaywidth(ltext:sub(1, lv.controller.col_offset(refl, "line", FLEX_COL) or 0))
            end

            -- FOOTER (off-screen-older topology, below).
            local frows, ftag = converge_footer()
            if not frows or #frows == 0 then
                footer_dbg = ftag or "no rows"; close_pane(footer); footer_seam, footer_height = nil, nil
            else
                frows = pane.cap(frows, PANE_MAX) -- keep the seam-nearest rows AND the root
                footer_seam, footer_height, footer_dbg = ftag, #frows + 1, nil
                ensure_pane_win(footer, false, #frows + 1)
                render_pane(footer.buf, frows, goff, foff, false)
            end

            -- HEADER (off-screen-newer topology, above). The overlay is exactly `H`
            -- tall (the height the seam was sized at), padded at the bottom so the
            -- seam butts the main view's top edge.
            local hrows, htag, H, ovf = converge_header()
            if not hrows or #hrows == 0 then
                header_dbg = htag or "no rows"; close_pane(header); header_seam, header_height = nil, nil
            else
                header_seam, header_height, header_dbg = htag, H, nil
                ensure_pane_win(header, true, H)
                render_pane(header.buf, hrows, goff, foff, true, ovf, H)
            end

            -- Topology-only debug dump (set `vim.g.gitloom_pane_debug` to a file path):
            -- the live seam/boundary/header-lane structure, no commit messages — for
            -- diagnosing seam alignment. Overwrites each build; never breaks the view.
            if type(vim.g.gitloom_pane_debug) == "string" then
                pcall(function()
                    local w0 = vim.api.nvim_win_call(win, function() return vim.fn.line("w0") end)
                    local _, w0disp = order_at(w0)
                    local out = { ("w0=%d w0disp=%s H=%s seam_tag=%s ovf=%s"):format(
                        w0, tostring(w0disp), tostring(H), tostring(htag), tostring(ovf)) }
                    -- The boundary the header was built from (the whole-commit seam).
                    local seam = w0disp and pane.header_seam(repo.display, w0disp, H or 2)
                    local disp_idx = seam and seam.idx
                    local boundary = seam
                        and pane.boundary_of((seam.kind == "split") and seam.item.split or seam.item.columns, true)
                        or {}
                    out[#out + 1] = ("boundary @disp=%s kind=%s:"):format(
                        tostring(disp_idx), tostring(seam and seam.kind))
                    local bcols = {}
                    for col in pairs(boundary) do bcols[#bcols + 1] = col end
                    table.sort(bcols)
                    for _, col in ipairs(bcols) do
                        local l = boundary[col]
                        out[#out + 1] = ("  col=%d id=%s begin_disp=%s"):format(
                            col, tostring(l.id), tostring(l.begin and order_of(l.begin)))
                    end
                    -- The header rows (tip-on-top): per row, each cell's lane ids +
                    -- connectivity + whether it carries a node/head.
                    out[#out + 1] = ("header rows = %d (overlay H=%s):"):format(#(hrows or {}), tostring(H))
                    for ri, r in ipairs(hrows or {}) do
                        local parts = {}
                        for ci, cell in ipairs(r.columns or {}) do
                            local ids = {}
                            for _, s in ipairs(cell.lanes or {}) do
                                local c = s.connectivity or {}
                                ids[#ids + 1] = ("%s%s%s%s%s"):format(tostring(s.id),
                                    c.up and "^" or "", c.down and "v" or "", c.left and "<" or "", c.right and ">" or "")
                            end
                            local node = ""
                            if cell.has_commit and cell.commit then
                                local nm = cell.commit.refs and cell.commit.refs[1] and cell.commit.refs[1].name
                                node = ("[%s gcol=%s]"):format(tostring(nm or "head"), tostring(col_of(cell.commit)))
                            end
                            if #ids > 0 or node ~= "" then parts[#parts + 1] = ("c%d:%s%s"):format(ci, table.concat(ids, "/"), node) end
                        end
                        out[#out + 1] = ("  R%02d %s"):format(ri, table.concat(parts, "  "))
                    end
                    -- The main-view display items around the seam, with their lane ids,
                    -- so the boundary can be checked against the real topology.
                    out[#out + 1] = "main display items (disp: parent_lanes | child_lanes  split/merge):"
                    local lo = math.max(1, (disp_idx or w0disp or 2) - 2)
                    local hi = math.min(#repo.display, (disp_idx or w0disp or 2) + (H or 2) + 1)
                    for di = lo, hi do
                        local it = repo.display[di]
                        if it then
                            local function ids(ls) local t = {}; for _, l in ipairs(ls or {}) do t[#t + 1] = tostring(l.id) end; return table.concat(t, ",") end
                            out[#out + 1] = ("  d%d: P[%s] | C[%s] col=%s%s"):format(di,
                                ids(it.parent_lanes), ids(it.child_lanes),
                                tostring(it.commit and col_of(it.commit)),
                                (it.split and " SPLIT" or "") .. (it.merge and " MERGE" or ""))
                        end
                    end
                    local fh = io.open(vim.g.gitloom_pane_debug, "w")
                    if fh then fh:write(table.concat(out, "\n") .. "\n"); fh:close() end
                end)
            end

            mark_cutoff()   -- refresh the debug cutoff highlight (the `i` overlay)
            update_footer() -- refresh the debug readout (cutoff lines) if `i` is on
        end

        update_panes = function()
            local ok, err = pcall(build_panes)
            if not ok then
                close_panes() -- on any pane error, hide rather than leave a bad state
                err = tostring(err)
                if err ~= last_pane_err then -- surface once per distinct error
                    last_pane_err = err
                    vim.notify("gitloom pane error: " .. err, vim.log.levels.WARN)
                end
            end
        end

        -- (The cursor is kept above the overlay by `scrolloff`, set in
        -- update_panes — no manual clamping needed.)

        -- Tear the panes down with the main window.
        vim.api.nvim_create_autocmd("WinClosed", {
            group = group,
            pattern = tostring(win),
            callback = close_panes,
        })

        -- No initial cone/refresh here: the fetch is async, so no commits are
        -- loaded yet. Initial dimming happens once the stream completes (above).
        place_cursor()
    end

    return lv
end

-- Internal functions exposed for testing only. Not part of the public API.
M._internal = {
    classify_ref = classify_ref,
    group_refs = group_refs,
    decoration_texts = decoration_texts,
    move_selection = move_selection,
    ref_byte_col = ref_byte_col,
    parse_commit_line = parse_commit_line,
    make_line_buffer = make_line_buffer,
    parse_timestamp = parse_timestamp,
    format_absolute = format_absolute,
    format_relative = format_relative,
    parse_show = parse_show,
    format_commit_detail = format_commit_detail,
    format_diff = format_diff,
    diffstat_files = diffstat_files,
    diff_contexts = diff_contexts,
    format_diffstat = format_diffstat,
    commit_range = commit_range,
    reachable_cone = reachable_cone,
    mark_reachable = mark_reachable,
    build_graph = build_graph,
    get_column_chars = get_column_chars,
    passthrough_columns = passthrough_columns,
    owners_from_refs = owners_from_refs,
    next_mode = next_mode,
    selected_owner_ids = selected_owner_ids,
    pack_markers = pack_markers,
    collapse_owners = collapse_owners,
}

return M
