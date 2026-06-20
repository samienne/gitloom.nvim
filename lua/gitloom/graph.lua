local M = {}

local color = require("gitloom.color")

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

-- Index of the flex (message) column in a row's `line` field: date, author,
-- graph, message. The message fills the remaining width and refs are pinned to
-- the right edge of the row (specification.md §6; see listview's build_line).
local FLEX_COL = 4

-- Graph window keybindings — the single source of truth for the `?` help
-- float. Handlers are registered in M.open.
local KEYBINDS = {
    { "q", "Close the graph" },
    { "m", "Cycle the merge/split rendering style" },
    { "M", "Toggle mirroring (lane 1 on the right)" },
    { "B", "Cycle ref label placement (right / inline / own line)" },
    { "<CR>", "Open the commit view for the row" },
    { "D", "Open the commit's diff (external viewer)" },
    { "d", "Toggle absolute / relative dates" },
    { "h/l", "Select previous / next ref on the row" },
    { "H", "Toggle reachability highlighting (dimming)" },
    { "K", "Lane breakdown for the commit under the cursor" },
    { "i", "Toggle the per-lane id column" },
    { "?", "Show this help" },
}

-- The graph window footer: live status (the current mode, and whether the graph
-- is mirrored) plus a hint to the help float.
---@param mirror boolean?
local function footer_text(mirror)
    local status = ("Mode: %s | Refs: %s"):format(
        MERGE_STYLES[merge_style_index].name, LABEL_MODES[label_mode_index].name)
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

local function fetch_commits(opts)
    opts = opts or {}

    local future, promise = make_future()

    if opts.branch and type(opts.branch) ~= "table" then
        opts.branch = { opts.branch }
    end

    -- Refs come from fetch_refs (§3.2), so no --decorate here. %at (epoch) +
    -- %ai (carries the tz offset) feed the structured Timestamp (§4).
    local command = { "git", "log", "--topo-order", "--parents", unpack(opts.branch),
        "--pretty=format:%H%x1f%P%x1f%an%x1f%at%x1f%ai%x1f%s" }
    if opts.count then
        table.insert(command, "-n")
        table.insert(command, tostring(opts.count))
    end

    vim.fn.jobstart(
        command,
        {
            stdout_buffered = true,
            on_stdout = function(_, lines)
                for _, line in ipairs(lines) do
                    local commit = parse_commit_line(line)
                    if commit and opts.on_item then
                        opts.on_item(commit)
                    end
                end
            end,
            on_exit = function()
                promise.resolve()
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
---@field type "commit"|"merge"|"split"
---@field commit? Commit
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

        -- A *crossing* is an independent through-vertical + through-horizontal in
        -- one cell (a `│` a wire passes across). It is left whole so a passing
        -- cone wire never truncates it; only real junctions drop their dim arms.
        local cross_v, cross_h
        for _, s in ipairs(track.lanes or {}) do
            if s.connectivity.up and s.connectivity.down then cross_v = s end
            if s.connectivity.left and s.connectivity.right then cross_h = true end
        end
        local is_crossing = cross_v ~= nil and cross_h

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
        if emphasis and not track.has_commit and not is_crossing then
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
        elseif track.has_commit then
            -- "⏺"
            char = (#track.commit.parents == 0) and "◎" or
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
        elseif c.up and c.down then
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
---@class SelectionState
---@field commit Commit|nil
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
    return opts.label_mode == "dual" and commit ~= nil and #decoration_texts(commit) > 0
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

    set_lines({ "Loading…" })

    -- Render the metadata (format_commit_detail), then the diffstat
    -- (format_diffstat), then the diff (format_diff) into one buffer: real lines
    -- + namespaced extmarks (the diff is highlighted this way, not via
    -- filetype=diff, so the metadata header stays clean §11.3). While laying out
    -- the rows, record each diffstat file row -> its diff section line (§11.4).
    local function render(meta_output, diff_output)
        if not vim.api.nvim_buf_is_valid(buf) then return end
        file_jumps = {}
        action_line = nil
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
            local diff_start = #rows + 1 -- buffer line of the first patch line
            for _, r in ipairs(format_diff(patch, opts.palette)) do
                rows[#rows + 1] = r
            end
            -- Summary sits at stat_start; file j at stat_start + j. Its diff
            -- section starts at diff_start + (start - 1).
            for j, f in ipairs(files) do
                file_jumps[stat_start + j] = diff_start + f.start - 1
            end
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

        -- Park the cursor on the action label so <CR><CR> opens the diff (§11.2).
        if action_line and vim.api.nvim_win_is_valid(w.win) then
            pcall(vim.api.nvim_win_set_cursor, w.win, { action_line, 0 })
        end
    end

    -- Fetch metadata, then the diff; render once both arrive (§11.1).
    fetch_commit_detail(commit.hash).next(function(meta_output)
        return fetch_commit_diff(commit.hash).next(function(diff_output)
            return { meta = meta_output, diff = diff_output }
        end)
    end).next(function(res)
        render(res.meta, res.diff)
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
    local view_state = { cone = nil, modes = {} }

    -- Parks the cursor at the message (or the selected ref). Assigned after the
    -- listview opens; forward-declared so the key handlers can call it.
    local place_cursor = function() end
    -- Recomputes the pivot's cone + re-marks track activeness (§12). Assigned
    -- after the listview opens; forward-declared for the key handlers.
    local update_cone = function() end
    -- Rebuilds the projected OrderItem graph under the current view state and
    -- swaps it into the listview (§10). Assigned after `order_at`/`lv` exist;
    -- forward-declared so the stream and key handlers can close over it.
    local reflow = function() end

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
        local proj = require("gitloom.view").project(
            repo.order, owners_from_refs(repo.refs, view_state.modes))
        refresh_columns(opts, proj.items)
        repo.display = proj.items
        if lv and lv.controller and lv.controller.set_items then
            lv.controller.set_items(repo.display)
        end
        update_cone()
        if lv and lv.controller then lv.controller.refresh() end
    end

    ---@type ListViewOptions
    local listview_options = {
        win = opts.win,
        -- The message (FLEX_COL) fills the row; refs (line_right) pin to the
        -- right edge, using the free width down to message_min (§6).
        flex = FLEX_COL,
        message_min = opts.message_min,
        overflow_hl = opts.palette.remote,
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
                    ---@param item Commit
                    on_item = function(item)
                        local existing = repo.commits[item.hash]
                        if existing then
                            -- Fill the placeholder; keep its already-resolved refs.
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
                            -- At this point parents are still the hash strings
                            -- parsed from `git log`, being resolved to Commits.
                            local parent = get_or_create_commit(repo, p --[[@as string]])
                            table.insert(parent.children, item)
                            table.insert(newParents, parent)
                        end

                        item.parents = newParents

                        --[[
                        if opts.merge_style.split_on_separate_line and #item.children > 1 then
                            ---@type OrderItem
                            local split_item = {
                                type = "split",
                                commit = item,
                                columns = {},
                            }

                            table.insert(repo.order, split_item)
                            refresh_columns(opts, repo.order, #repo.order)
                            controller.insert({ split_item }, #repo.order)
                        end
                        --]]

                        ---@type OrderItem
                        local order_item = {
                            type = "commit",
                            commit = item,
                            columns = {},
                        }
                        table.insert(repo.order, order_item)
                        -- Fast path while the projection is the identity (the
                        -- common all-normal case): lay out and append one row.
                        -- Once a branch mode makes the display a separate
                        -- projection, a streamed commit needs a full reflow (§10).
                        if repo.display == repo.order then
                            refresh_columns(opts, repo.order, #repo.order)
                            controller.insert({ order_item }, #repo.order)
                        else
                            reflow()
                        end

                        --[[
                        if opts.merge_style.merge_on_separate_line and #item.parents > 1 and #item.children > 0 then
                            ---@type OrderItem
                            local merge_item = {
                                type = "merge",
                                commit = item,
                                columns = {},
                            }

                            table.insert(repo.order, merge_item)
                            refresh_columns(opts, repo.order, #repo.order)
                            controller.insert({ merge_item }, #repo.order)
                        end
                        --]]
                    end,
                })
            end).next(function()
                -- Initial dimming once the graph is populated (§12): compute the
                -- cone for the parked pivot, then refresh and re-park.
                update_cone()
                if lv and lv.controller then
                    lv.controller.refresh()
                end
                place_cursor()
            end)
        end,
    }

    opts.win.keys = opts.win.keys or {}
    -- m: cycle the merge/split style and reflow in place (no re-fetch). This
    -- is the reflow path the interactive views (collapse/pin/toggle) will use:
    -- relayout repo.order, then re-render. One buffer line per commit doesn't
    -- change, so no insert/remove churn — only columns and virtual lines update.
    opts.win.keys.m = function()
        merge_style_index = (merge_style_index % #MERGE_STYLES) + 1
        opts.merge_style = vim.deepcopy(MERGE_STYLES[merge_style_index].style)
        refresh_columns(opts, repo.display, 1)
        update_cone() -- columns regenerated → re-mark active for the cone (§12)
        if lv and lv.controller then
            lv.controller.refresh()
        end
        -- Reflect the new mode live in the footer (no transient notify).
        if lv and lv.win and lv.win.win then
            lv.win.opts.footer = footer_text(opts.mirror)
            pcall(vim.api.nvim_win_set_config, lv.win.win, {
                footer = lv.win.opts.footer,
                footer_pos = "center",
            })
        end
        place_cursor() -- widths shifted; keep the cursor on message/ref
    end
    -- M: toggle graph mirroring (lane 1 on the right). A render-only change, so
    -- just refresh the display (no relayout/re-fetch) — like the `i` toggle.
    opts.win.keys.M = function()
        opts.mirror = not opts.mirror
        if lv and lv.controller then
            lv.controller.refresh()
        end
        if lv and lv.win and lv.win.win then
            lv.win.opts.footer = footer_text(opts.mirror)
            pcall(vim.api.nvim_win_set_config, lv.win.win, {
                footer = lv.win.opts.footer,
                footer_pos = "center",
            })
        end
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
        if lv and lv.win and lv.win.win then
            lv.win.opts.footer = footer_text(opts.mirror)
            pcall(vim.api.nvim_win_set_config, lv.win.win, {
                footer = lv.win.opts.footer,
                footer_pos = "center",
            })
        end
        update_cone() -- buffer lines shifted; recompute the cone over the new map
        place_cursor()
    end
    -- <CR>: open the commit view for the commit on the current row (§11). In dual
    -- mode either of a labelled commit's two rows resolves to the same commit.
    opts.win.keys["<CR>"] = function(self)
        local line = vim.api.nvim_win_get_cursor(self.win --[[@as integer]])[1]
        local item = order_at(line)
        if not item or not item.commit then
            return
        end
        open_commit_view(opts, item.commit)
    end
    -- D: open the commit's diff in the external diff viewer (§11.5).
    opts.win.keys.D = function(self)
        local w = self and self.win
        if not w then return end
        local line = vim.api.nvim_win_get_cursor(w)[1]
        local item = order_at(line)
        if not item or not item.commit then
            return
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
    -- i: toggle the per-lane id column before the message.
    opts.win.keys.i = function()
        show_lane_ids = not show_lane_ids
        if lv and lv.controller then
            lv.controller.refresh()
        end
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

        place_cursor = function()
            local line = vim.api.nvim_win_get_cursor(win)[1]
            local item = order_at(line)
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
        -- `applying` suppresses the WinScrolled the deferred refresh may emit.
        local CONE_DEBOUNCE_MS = 60
        local cone_gen, applying = 0, false
        local function schedule_cone_update()
            cone_gen = cone_gen + 1
            local gen = cone_gen
            vim.defer_fn(function()
                if gen ~= cone_gen or not vim.api.nvim_win_is_valid(win) then return end
                update_cone()
                applying = true
                if lv and lv.controller then lv.controller.refresh() end
                applying = false
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
                local item, _, sub = order_at(line)
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
                if applying or not vim.api.nvim_win_is_valid(win) then return end
                schedule_cone_update()
            end,
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
    parse_timestamp = parse_timestamp,
    format_absolute = format_absolute,
    format_relative = format_relative,
    parse_show = parse_show,
    format_commit_detail = format_commit_detail,
    format_diff = format_diff,
    diffstat_files = diffstat_files,
    format_diffstat = format_diffstat,
    commit_range = commit_range,
    reachable_cone = reachable_cone,
    mark_reachable = mark_reachable,
    build_graph = build_graph,
    get_column_chars = get_column_chars,
    passthrough_columns = passthrough_columns,
    owners_from_refs = owners_from_refs,
}

return M
