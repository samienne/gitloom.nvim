local M = {}

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
    { "<CR>", "Open the commit view for the row" },
    { "d", "Toggle absolute / relative dates" },
    { "h/l", "Select previous / next ref on the row" },
    { "K", "Lane breakdown for the commit under the cursor" },
    { "i", "Toggle the per-lane id column" },
    { "?", "Show this help" },
}

-- The graph window footer: live status (the current mode, and whether the graph
-- is mirrored) plus a hint to the help float.
---@param mirror boolean?
local function footer_text(mirror)
    local status = ("Mode: %s"):format(MERGE_STYLES[merge_style_index].name)
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
                        if kind and hash then
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
    return os.date("!" .. (fmt or "%Y-%m-%d %H:%M"), ts.epoch + ts.offset)
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
---@param commit Commit?
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

local next_id = 0
local function get_next_id()
    next_id = next_id + 1
    return next_id
end

--- Reset the lane-id counter. Called at the start of a full layout build
--- (build_graph) and when a graph window is opened, so lane ids — and thus
--- colors — are deterministic per build rather than leaking across runs.
local function reset_ids()
    next_id = 0
end

function table_contains(tbl, item)
    for _, t in ipairs(tbl) do
        if item == t then
            return true
        end
    end

    return false
end

---@param commit Commit
---@return string
local function inspect_commit(commit)
    local new_parents = {}
    for _, p in ipairs(commit.parents or {}) do
        table.insert(new_parents, p.hash)
    end

    local new_children = {}
    for _, c in ipairs(commit.children or {}) do
        table.insert(new_children, c.hash)
    end

    local old_parents = commit.parents
    local old_children = commit.children

    commit.parents = new_parents
    commit.children = new_children

    local result = vim.inspect(commit)

    commit.parents = old_parents
    commit.children = old_children

    return result
end

---@param track Track
---@return string
local function inspect_track(track)
    local new_parents = {}
    local commit = track.commit or {}
    for _, p in ipairs(commit.parents or {}) do
        table.insert(new_parents, p.hash)
    end

    local new_children = {}
    for _, c in ipairs(commit.children or {}) do
        table.insert(new_children, c.hash)
    end

    local old_parents = commit.parents
    local old_children = commit.children
    local old_commit = track.commit
    local old_parent = track.parent or {}

    commit.parents = new_parents
    commit.children = new_children

    ---@diagnostic disable-next-line: assign-type-mismatch
    track.commit = commit.hash
    ---@diagnostic disable-next-line: assign-type-mismatch
    track.parent = old_parent.hash

    local result = vim.inspect(track)

    commit.parents = old_parents
    commit.children = old_children
    track.commit = old_commit
    track.parent = old_parent

    return result
end

---@param opts MergeStyle
---@param state TrackState
---@param track? Track
---@param item OrderItem
local function handle_commit(opts, state, track, item)
    local splitting_or_merging = not opts.merge_on_separate_line and state.merge and #state.merge.new_parents > 1 or
        not opts.split_on_separate_line and
        state.split and state.split.remaining > 1

    local has_commit = state.merge_id == nil and (not track or track and track.parent == item.commit) or false

    for _, t in ipairs(state.new_tracks) do
        if t.commit and t.commit == item.commit then
            has_commit = false
            break
        end
    end

    ---@type integer|nil
    local track_id = track and track.id -- or get_next_id()

    for i = 1, state.space_available do
        if i > 1 and not (state.merge and #state.merge.new_parents > 0) and not (state.split and state.split.remaining > 0) then
            break
        end

        local parent = (opts.allow_merge_on_split or opts.split_on_separate_line or has_commit) and state.merge and
            table.remove(state.merge.new_parents, 1) or nil
        if parent ~= nil then
            if opts.merge_on_separate_line or #state.merge.new_parents == #item.commit.parents - 1 then
                track_id = track and track.id or get_next_id()
            else
                track_id = get_next_id()
            end
        else
            track_id = track and track.id
        end

        ---@type Track
        local new_track = {
            id = track_id,
            --override = track == nil and "*" or nil,
            --override = "*",
            --override = opts.merge_on_separate_line and "*" or nil,
            --override = state.merge and tostring(#state.merge.new_parents) or nil,
            --override = state.split and tostring(state.split.remaining) or nil,
            --override = tostring(state.space_available),
            --override = track and track.parent == item.commit and "*" or nil,
            connectivity = {
                down = parent ~= nil,
                right = not opts.merge_on_separate_line and state.merge and #state.merge.new_parents > 0 or
                    i < state.space_available or
                    state.split and state.split.remaining > 1 or false,
                --left = i > 1 or state.split and state.split.remaining == #item.commit.children,
                left = not has_commit,
                up = i == state.space_available and track and track.connectivity.down or false,
            },
            parent = parent,
            commit = i == 1 and has_commit and item.commit or nil,
            has_commit = i == 1 and has_commit and item.commit ~= nil,
        }

        table.insert(state.new_tracks, new_track)

        has_commit = false
    end

    if state.split and state.split.remaining > 0 then
        state.split.remaining = state.split.remaining - 1
    end

    state.merge_id = splitting_or_merging and track_id or nil
end

---@param state TrackState
---@param track? Track
---@param item OrderItem
local function handle_merge(state, track, item)
    local track_id = track and track.commit == item.commit and track.id or get_next_id()

    for i = 1, state.space_available do
        local parent = state.merge and table.remove(state.merge.new_parents, 1) or nil

        ---@type Track
        local new_track = {
            id = track_id,
            --override = "*",
            --override = parent ~= nil and "*" or nil,
            has_commit = false,
            connectivity = {
                down = parent ~= nil,
                up = track and track.commit == item.commit or false,
                left = state.merge and #state.merge.new_parents < #item.commit.parents - 1 or false,
                right = state.merge and #state.merge.new_parents > 0 or false,
            },
            parent = parent,
            commit = nil,
        }

        state.merge_id = new_track.id

        table.insert(state.new_tracks, new_track)
    end
    if not state.merge or #state.merge.new_parents == 0 then
        state.merge_id = nil
    end
end

---@param state TrackState
---@param track? Track
---@param item OrderItem
local function handle_split(state, track, item)
    if not state.split then
        state.split = {
            remaining = #item.commit.children
        }
    end

    for i = 1, state.space_available do
        ---@type Commit|nil
        local parent = state.split and state.split.remaining == #item.commit.children and i == 1 and item.commit or nil

        ---@type Track
        local new_track = {
            id = track and track.id,
            has_commit = false,
            --override = state.split and tostring(state.split.remaining) or nil,
            --override = tostring(#item.commit.children),
            --override = parent and "*" or nil,
            --override = "*",
            connectivity = {
                down = parent ~= nil and i == 1 and state.split.remaining == #item.commit.children,
                up = i == state.space_available,
                left = state.split and state.split.remaining < #item.commit.children or false,
                right = i < state.space_available or state.split.remaining > 1,
            },
            parent = parent,
            commit = nil,
        }

        table.insert(state.new_tracks, new_track)
    end

    if state.split and state.split.remaining > 0 then
        state.merge_id = state.split.remaining > 1 and track and track.id or nil
        state.split.remaining = state.split.remaining - 1
    end
end

---@param state TrackState
---@param track Track
local function handle_line(state, track)
    ---@type boolean
    local splitting_or_merging = state.merge_id and true or false --state.split and state.split.remaining > 0 or false

    for i = 1, state.space_available do
        ---@type Track
        local new_track = {
            --id = state.merge_id or track.id,
            id = track.id,
            --override = "*",
            --override = state.split and tostring(state.split.remaining) or nil,
            --override = splitting_or_merging and "*" or nil,
            --override = tostring(state.space_available),
            connectivity = {
                up = i == state.space_available,
                down = splitting_or_merging and i == state.space_available or not splitting_or_merging and i == 1,
                --left = i > 1 or splitting_or_merging,
                left = #state.new_tracks > 0 and state.new_tracks[#state.new_tracks].connectivity.right or false,
                right = i < state.space_available or splitting_or_merging,
            },
            parent = track.parent,
            has_commit = false,
        }

        table.insert(state.new_tracks, new_track)
    end
end

---@param opts GraphOptions
---@param tracks Track[]
---@param item OrderItem
local function handle_split_line(opts, tracks, item)
    ---@type TrackState
    local state = {
        tracks = tracks,
        new_tracks = {},
        merge_id = nil,
        space_available = 1,
    }

    if #item.commit.children > 1 then
        state.split = {
            remaining = #item.commit.children
        }
    end

    for _, t in ipairs(tracks) do
        if t.connectivity.down then
            if t.parent == item.commit then
                handle_split(state, t, item)
            else
                handle_line(state, t)
            end

            state.space_available = 1
        else
            state.space_available = state.space_available + 1
        end
    end

    return state.new_tracks
end

---@param opts GraphOptions
---@param tracks Track[]
---@param item OrderItem
local function handle_merge_line(opts, tracks, item)
    ---@type TrackState
    local state = {
        tracks = tracks,
        new_tracks = {},
        merge_id = nil,
        space_available = 1,
    }

    if #item.commit.parents > 1 then
        state.merge = {
            remaining = #item.commit.parents,
            new_parents = {},
        }

        for _, p in ipairs(item.commit.parents) do
            table.insert(state.merge.new_parents, p)
        end
    end

    for _, t in ipairs(tracks) do
        if t.connectivity.down then
            if t.commit == item.commit then
                handle_merge(state, t, item)
            else
                handle_line(state, t)
            end
            state.space_available = 1
        elseif state.merge and #state.merge.new_parents > 0 then
            handle_merge(state, t, item)
            state.space_available = 1
        else
            state.space_available = state.space_available + 1
        end
    end

    -- Add a new track for each new parent that hasn't been handled yet.
    if state.merge then
        for j, p in ipairs(state.merge.new_parents) do
            ---@type Track
            local new_track = {
                id = get_next_id(),
                --override = "*",
                connectivity = {
                    up = false,
                    left = true,
                    right = j < #state.merge.new_parents,
                    down = true,
                },
                has_commit = false,
                parent = p,
            }

            table.insert(state.new_tracks, new_track)
        end
    end

    return state.new_tracks
end

---@param opts GraphOptions
---@param tracks Track[]
---@param item OrderItem
local function handle_commit_line(opts, tracks, item)
    ---@type TrackState
    local state = {
        tracks = tracks,
        new_tracks = {},
        merge_id = nil,
        space_available = 1,
    }

    if true or not opts.merge_style.merge_on_separate_line and #item.commit.parents > 1 then
        state.merge = {
            remaining = #item.commit.parents,
            new_parents = {},
        }

        for _, p in ipairs(item.commit.parents) do
            table.insert(state.merge.new_parents, p)
        end
    end

    if not opts.merge_style.split_on_separate_line and #item.commit.children > 1 or #item.commit.children == 1 then
        state.split = {
            remaining = #item.commit.children
        }
    end

    local handled = false

    for _, t in ipairs(tracks) do
        if t.connectivity.down then
            if t.parent == item.commit then
                handle_commit(opts.merge_style, state, t, item)

                handled = true
            else
                handle_line(state, t)
            end

            state.space_available = 1
        elseif state.merge and #state.merge.new_parents > 0 then
            --handle_commit(opts.merge_style, state, t, item)

            --state.space_available = 1
            state.space_available = state.space_available + 1

            while state.merge_id and #state.merge.new_parents > 0 and state.space_available > 0 do
                local parent = table.remove(state.merge.new_parents)
                state.space_available = state.space_available - 1
                ---@type Track
                local new_track = {
                    id = get_next_id(),
                    --override = "*",
                    connectivity = {
                        up = false,
                        left = true,
                        right = #state.merge.new_parents > 1,
                        down = true,
                    },
                    has_commit = false,
                    parent = parent,
                }

                table.insert(state.new_tracks, new_track)
                if #state.merge.new_parents == 0 then
                    state.merge_id = nil
                end
            end
        else
            state.space_available = state.space_available + 1
        end
    end

    if not handled then
        state.space_available = 1
        handle_commit(
            {
                allow_merge_on_split = true,
                merge_on_separate_line = false,
                split_on_separate_line = false,
            },
            state, nil, item
        )
    end

    -- Add a new track for each new parent that hasn't been handled yet.
    if not opts.merge_style.merge_on_separate_line and state.merge then
        for j, p in ipairs(state.merge.new_parents) do
            ---@type Track
            local new_track = {
                id = get_next_id(),
                --override = "*",
                connectivity = {
                    up = false,
                    left = true,
                    right = j < #state.merge.new_parents,
                    down = true,
                },
                has_commit = false,
                parent = p,
            }

            table.insert(state.new_tracks, new_track)
        end
    end

    return state.new_tracks
end

---@class LayoutResult
---@field tracks Track[]       lane state on the commit line
---@field split? Track[]       lane state on the split (above) line, if any
---@field merge? Track[]       lane state on the merge (below) line, if any
---@field carry Track[]        lane state handed to the next item

--- The id of the horizontal wire passing through cell `i` — the next track to
--- the right that is neither a crossing nor a horizontal jump (mirrors the
--- lookahead get_track_chars uses to color a horizontal run).
---@param tracks Track[]
---@param i integer
---@return integer|nil
local function horizontal_id(tracks, i)
    for j = i + 1, #tracks do
        local c = tracks[j].connectivity
        local is_cross = c.down and c.up and c.left and c.right
        local is_jump = not c.down and not c.up and c.right and c.left
        if not (is_cross or is_jump) then
            return tracks[j].id
        end
    end
    return nil
end

--- Attach the lane-model view (specification.md §5) to each track in a row.
--- Decomposes a cell's connectivity into two-sided wires: a crossing becomes a
--- vertical lane + a horizontal lane; a tee becomes a through lane + a branch;
--- a turn is one bent lane; straights and endpoints are one lane. Rendering
--- still reads the flat fields, so this stays output-neutral. Lane ids are
--- best-effort here (vertical = track id, horizontal = lookahead); precise
--- ids and the child edge come with native threading in a later phase.
---@param tracks Track[]?
---@param prev_line Track[]?  the line directly above (column-aligned by index)
local function attach_lanes(tracks, prev_line)
    for i, t in ipairs(tracks or {}) do
        local c = t.connectivity
        local u, d, l, r = c.up or false, c.down or false, c.left or false, c.right or false
        local h_id = horizontal_id(tracks, i)
        local down_id = t.id

        -- The id of the lane entering from above (the cell directly above in
        -- the same column). When it differs from this cell's own (down) id,
        -- the up segment and down segment are *different* lanes sharing the
        -- column — a handoff (e.g. a child's split-in lane reaching the commit
        -- while a parent's merge-out lane leaves it). They are modeled as two
        -- lanes, even though they render as one (best-effort) glyph.
        local up_id = down_id
        if u and prev_line and prev_line[i] and prev_line[i].connectivity.down then
            up_id = prev_line[i].id
        end
        local handoff = u and d and up_id ~= down_id

        local lanes = {}
        local function add(id, sides)
            lanes[#lanes + 1] = { id = id, parent = t.parent, connectivity = sides }
        end

        local vpair, hpair = u and d, l and r
        if hpair then
            -- horizontal through-lane is always its own lane
            add(h_id, { left = true, right = true })
            if handoff then
                add(up_id, { up = true })
                add(down_id, { down = true })
            elseif vpair then
                add(down_id, { up = true, down = true })
            elseif u then
                add(down_id, { up = true })
            elseif d then
                add(down_id, { down = true })
            end
        elseif l or r then
            local h = l and "left" or "right"
            if handoff then
                -- incoming child-lane and outgoing parent-lane share the
                -- horizontal stub toward the commit; modeled separately.
                local up_sides = { up = true }; up_sides[h] = true
                local down_sides = { down = true }; down_sides[h] = true
                add(up_id, up_sides)
                add(down_id, down_sides)
            elseif vpair then
                -- tee: vertical through-lane + horizontal branch
                add(down_id, { up = true, down = true })
                add(h_id, { [h] = true })
            elseif u or d then
                -- turn: one bent lane
                add(down_id, { up = u or nil, down = d or nil, [h] = true })
            else
                add(h_id, { [h] = true })
            end
        else
            -- no horizontal
            if handoff then
                add(up_id, { up = true })
                add(down_id, { down = true })
            else
                add(down_id, { up = u or nil, down = d or nil })
            end
        end

        ---@type Lane[]
        t.lanes = lanes
    end
end

--- Lay out a single item against the previous item's carry-over lanes.
--- Pure: it neither mutates `item` nor touches the list view. Callers decide
--- what to do with the result (assign onto the OrderItem, collect into rows,
--- etc.). This is the seam the incremental path and full-rebuild path share.
---@param opts GraphOptions
---@param prev_tracks Track[]
---@param item OrderItem
---@return LayoutResult
local function layout_item(opts, prev_tracks, item)
    ---@type LayoutResult
    local result = { tracks = {}, carry = {} }
    local tracks = prev_tracks

    if opts.merge_style.split_on_separate_line and #item.commit.children > 1 then
        tracks = handle_split_line(opts, tracks, item)
        result.split = tracks
    end

    tracks = handle_commit_line(opts, tracks, item)
    result.tracks = tracks

    if opts.merge_style.merge_on_separate_line and #item.commit.parents > 1 then
        tracks = handle_merge_line(opts, tracks, item)
        result.merge = tracks
    end

    result.carry = tracks

    -- Attach lanes per rendered line, each against the line above it, so the
    -- handoff (up != down) split can see the incoming lane.
    local prev = prev_tracks
    if result.split then
        attach_lanes(result.split, prev)
        prev = result.split
    end
    attach_lanes(result.tracks, prev)
    prev = result.tracks
    if result.merge then
        attach_lanes(result.merge, prev)
    end

    return result
end

--- Build the full graph layout from an ordered list of items, from scratch.
--- Pure and deterministic (fresh lane-id sequence each call). Returns new row
--- tables (does not mutate the inputs). This is the reflow primitive and the
--- entry point for tests.
---@param opts GraphOptions
---@param items OrderItem[]   ordered items, each carrying a wired `.commit`
---@return OrderItem[]
local function build_graph(opts, items)
    reset_ids()

    local rows = {}
    local carry = {}
    for _, item in ipairs(items) do
        local result = layout_item(opts, carry, item)
        ---@type OrderItem
        rows[#rows + 1] = {
            type = item.type or "commit",
            commit = item.commit,
            tracks = result.tracks,
            split = result.split,
            merge = result.merge,
        }
        carry = result.carry
    end

    return rows
end

---@class Ref
---@field name string
---@field kind "local"|"remote"|"tag"|"head"
---@field commit Commit   the commit this ref points at (a direct reference)

---@class Commit
---@field hash string
---@field parents Commit[]|string[]
---@field children Commit[]|string[]
---@field refs Ref[]
---@field author string
---@field date string
---@field message string

---@class Connectivity
---@field up boolean
---@field down boolean
---@field left boolean
---@field right boolean

--- Target lane model (specification.md §5). A lane is one wire through a
--- cell: the edge child -> parent, with its own connectivity (exactly two
--- sides; one only at a commit endpoint). Migration in progress — see the
--- note on Track.
---@class Lane
---@field id integer|nil
---@field child? Commit       the placed commit (above) the lane emanates from
---@field parent? Commit      the commit (below) the lane terminates at
---@field connectivity Connectivity

---@class Track
---@field id integer|nil
---@field connectivity Connectivity
---@field has_commit boolean
---@field commit? Commit
---@field parent? Commit
---@field override? string
---@field lanes? Lane[]
--- MIGRATION (specification.md §5): a cell is moving to a `lanes: Lane[]`
--- model where glyph = union of lanes' connectivity and color = a "top"
--- lane's id. `lanes` is currently an additive view (one lane per track,
--- mirroring the flat fields); rendering still reads the flat fields.

---@class MergeState
---@field remaining integer
---@field new_parents Commit[]

---@class SplitState
---@field remaining integer

---@class TrackState
---@field tracks Track[]
---@field space_available integer
---@field new_tracks Track[]
---@field merge? MergeState
---@field split? SplitState
---@field merge_id? integer

---@class OrderItem
---@field type "commit"|"merge"|"split"
---@field commit? Commit
---@field tracks Track[]
---@field split? Track[]
---@field merge? Track[]

---@param opts GraphOptions
---@param order OrderItem[]
---@param start_pos integer
local function refresh_tracks(opts, order, start_pos)
    start_pos = start_pos or 1
    local carry = start_pos > 1 and (order[start_pos - 1].merge or order[start_pos - 1].tracks) or {}
    for i = start_pos, #order do
        ---@type OrderItem
        local item = order[i]

        local result = layout_item(opts, carry, item)
        item.tracks = result.tracks
        item.split = result.split
        item.merge = result.merge
        carry = result.carry
    end
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

---@param opts GraphOptions
---@param tracks Track[]
--- The "top" lane whose id colors a cell: prefer the lane heading *down*
--- (so a column reads continuously into the lane below), then the up lane,
--- then any. This is the configurable color strategy (specification.md §5);
--- the chosen id is always one of the cell's lanes'. At a handoff the up and
--- down segments are different lanes — only one color can show, so the visual
--- is best-effort while the model keeps both lanes.
---@param lanes Lane[]?
---@return integer|nil
local function top_lane_id(lanes)
    if not lanes then return nil end
    for _, lane in ipairs(lanes) do
        if lane.connectivity.down then return lane.id end
    end
    for _, lane in ipairs(lanes) do
        if lane.connectivity.up then return lane.id end
    end
    return lanes[1] and lanes[1].id or nil
end

--- Mirror a row's cells for right-aligned rendering (specification.md §5.4).
--- Reverses the column order (so lane 1 becomes the rightmost column, nearest
--- the message) and swaps each cell's left/right connectivity. Because the
--- glyph is a pure function of connectivity (get_track_chars), the mirrored
--- glyphs (╭↔╮, ┤↔├, ╴↔╶) and the inter-lane connectors fall out automatically
--- — no glyph-swap table. Color is unaffected (it comes from each lane's
--- up/down). Returns a fresh array; the model rows are left untouched.
---@param tracks Track[]
---@return Track[]
local function mirror_tracks(tracks)
    local out = {}
    for i = #tracks, 1, -1 do
        local t = tracks[i]
        local c = t.connectivity
        local m = {}
        for k, v in pairs(t) do m[k] = v end
        m.connectivity = { up = c.up, down = c.down, left = c.right, right = c.left }
        out[#out + 1] = m
    end
    return out
end

local function get_track_chars(opts, tracks)
    -- Right-aligned mirror: flip the cells before deriving glyphs. The graph
    -- column is then right-aligned by the listview (fix_width align = "right").
    if opts.mirror then
        tracks = mirror_tracks(tracks)
    end

    local result = {}

    for i = 1, #tracks do
        local track = tracks[i]
        local next = tracks[i + 1]

        ---@type Connectivity
        local c = {
            left = track.connectivity.left,
            --right = track.connectivity.right or next and next.connectivity.left,
            right = track.connectivity.right,
            up = track.connectivity.up,
            down = track.connectivity.down,
        }

        local char = " "
        -- Color from the lane model's "top" lane (specification.md §5). For a
        -- horizontal "─" cell this resolves to the horizontal lane's id, which
        -- attach_lanes derives via the same lookahead this used to do inline.
        local track_id = top_lane_id(track.lanes)
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
        else
            char = "x"
            vim.notify(vim.inspect(c))
        end

        ---@return string
        local get_highlight = function(id)
            return id and opts.palette.tracks[(id % #opts.palette.tracks) + 1] or nil
        end

        -- "┌"  "┘" or "─",
        -- ┴─┴─ ┤
        result = compose({ result, highlight_text(char, get_highlight(track_id))
        })

        local next_track_id = nil
        for j = i + 1, #tracks do
            local t = tracks[j]
            local is_cross = t.connectivity.down and t.connectivity.up and t.connectivity.left and t.connectivity.right
            local is_jump = not t.connectivity.down and not t.connectivity.up and t.connectivity.right and
                t.connectivity.left
            --if not t.connectivity.down or not t.connectivity.up or not t.connectivity.left or not t.connectivity.right then
            if not is_cross and not is_jump then
                next_track_id = t.id
                break
            end
        end

        if next ~= nil and (track.connectivity.right and next.connectivity.left) then
            local hl = get_highlight(next_track_id)
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

--- Tracks the current ref selection (specification.md §2). Held by commit
--- identity so it survives reflow; `index` is 1-based into the row's selectable
--- decorations (branch groups then tags), or nil for no selection.
---@class SelectionState
---@field commit Commit|nil
---@field index integer|nil

---@param opts GraphOptions
---@param item OrderItem
---@param selection_state SelectionState
---@return DisplayElement
local function display_item(opts, item, selection_state)
    local palette = opts.palette

    -- The 1-based decoration index selected on this row, or nil. Selection is
    -- by commit identity, so it follows the commit across reflow.
    local selected = nil
    if selection_state and item.commit and selection_state.commit == item.commit then
        selected = selection_state.index
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
            items[#items + 1] = highlight_text("HEAD", palette.head)
        end
        local di = 0
        for _, b in ipairs(g.branches) do
            di = di + 1
            if di == selected then
                items[#items + 1] = highlight_text(texts[di], palette.selected)
            else
                local name_hl = b.has_local and palette.branch or palette.remote
                local segs = { highlight_text("(" .. b.name, name_hl) }
                if #b.remotes > 0 then
                    segs[#segs + 1] = highlight_text(" ↑" .. table.concat(b.remotes, ","), palette.remote)
                end
                segs[#segs + 1] = highlight_text(")", name_hl)
                items[#items + 1] = compose(segs)
            end
        end
        for _, t in ipairs(g.tags) do
            di = di + 1
            if di == selected then
                items[#items + 1] = highlight_text(texts[di], palette.selected)
            else
                items[#items + 1] = highlight_text("[" .. t .. "]", palette.tags)
            end
        end
        return items
    end

    local get_tracks = function(tracks)
        if not show_lane_ids then
            return highlight_text("")
        end
        local result = "("
        for i, t in ipairs(tracks) do
            result = result .. (i > 1 and ", " or "") .. (t.id or "-")
        end
        result = result .. ") "

        return highlight_text(result, "Comment")
    end



    if item.type == "commit" then
        ---@type DisplayElement
        local element = {
            line = {
                highlight_text(format_date(item.commit.date, opts) .. " ", palette.date),
                highlight_text(item.commit.author .. " ", palette.author),
                get_track_chars(opts, item.tracks),
                -- The flex (message) column: optional lane-id debug prefix, then
                -- the subject. Refs go in line_right, pinned to the right edge.
                compose({
                    get_tracks(item.tracks),
                    highlight_text(item.commit.message, palette.message) or "",
                }),
            },
            line_right = get_ref_items(item.commit),
        }
        if item.split then
            element.above = { "", "", get_track_chars(opts, item.split), get_tracks(item.split) }
        end

        if item.merge then
            element.below = { "", "", get_track_chars(opts, item.merge), get_tracks(item.merge) }
        end

        return element
    else
        return { line = { "", "", get_track_chars(opts, item.tracks), "", "" } }
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

    local function dump(label, tracks)
        if not tracks then return end
        lines[#lines + 1] = label .. ":"
        for i, t in ipairs(tracks) do
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
    dump("commit line", item.tracks)
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
--- float that fetches the commit's detail on demand and renders it. `q` closes
--- it (snacks default). The pure pieces (parse_show / format_commit_detail) do
--- the work; this is just window + IO glue.
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

    local function set_lines(lines)
        if not vim.api.nvim_buf_is_valid(buf) then return end
        vim.bo[buf].modifiable = true
        vim.bo[buf].readonly = false
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modifiable = false
        vim.bo[buf].readonly = true
    end

    set_lines({ "Loading…" })

    -- Render the metadata (format_commit_detail) then the diff (format_diff)
    -- into one buffer: real lines + namespaced extmarks (the diff is highlighted
    -- this way, not via filetype=diff, so the metadata header stays clean §11.3).
    local function render(meta_output, diff_output)
        if not vim.api.nvim_buf_is_valid(buf) then return end
        local detail = parse_show(meta_output)
        local rows = format_commit_detail(detail, {
            decorations = decoration_texts(commit),
            palette = opts.palette,
        })
        -- `git show --format=` prints a leading blank line; drop it.
        local patch = (diff_output or ""):gsub("^%s+", "")
        if patch ~= "" then
            rows[#rows + 1] = highlight_text("")
            for _, r in ipairs(format_diff(patch, opts.palette)) do
                rows[#rows + 1] = r
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

---@class GraphPalette
---@field date? string
---@field author? string
---@field branch? string
---@field remote? string
---@field head? string
---@field message? string
---@field tags? string
---@field selected? string  the h/l-selected ref decoration (§2)
---@field diff? { add?: string, delete?: string, hunk?: string, header?: string }  commit-view diff colors (§11.3)
---@field tracks? string[]

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
---@field date_format? string  os.date format for absolute dates; §6
---@field date_mode? "absolute"|"relative"  initial date rendering; §6
---@field message_min? integer  min width kept for the message; refs use the rest; §6

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
        },
        --merge_style = "merge"
        merge_style = vim.deepcopy(MERGE_STYLES[merge_style_index].style),
        -- Render the graph mirrored (lane 1 at the right, nearest the message)
        -- by default. Toggle live with M.
        mirror = true,
        -- Date column: absolute (os.date format) or relative ("3 days ago").
        -- Toggle live with d.
        date_format = "%Y-%m-%d %H:%M",
        date_mode = "absolute",
        -- Refs are pinned to the right edge and use the free width; the message
        -- keeps at least message_min, and ref overflow becomes a "+N" marker.
        message_min = 24,
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

    local listview = require("gitloom.listview")

    -- Fresh lane-id sequence per opened graph so colors are deterministic.
    reset_ids()

    ---@class Repo
    ---@field commits table<string, Commit>  hash → Commit (the resolution table)
    ---@field order OrderItem[]
    ---@field refs table<string, Ref>        name → Ref ("HEAD" for the head)
    ---@field head? string                   current branch name

    ---@type Repo
    local repo = {
        commits = {},
        order = {},
        refs = {},
    }

    local palette = opts.palette

    ---@type SelectionState
    local selection_state = {
        commit = nil,
        index = nil,
    }

    -- Parks the cursor at the message (or the selected ref). Assigned after the
    -- listview opens; forward-declared so the key handlers can call it.
    local place_cursor = function() end

    ---@type ListViewOptions
    local listview_options = {
        win = opts.win,
        -- The message (FLEX_COL) fills the row; refs (line_right) pin to the
        -- right edge, using the free width down to message_min (§6).
        flex = FLEX_COL,
        message_min = opts.message_min,
        overflow_hl = opts.palette.remote,
        display = function(item)
            return display_item(opts, item, selection_state)
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
                            local parent = get_or_create_commit(repo, p)
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
                                tracks = {},
                            }

                            table.insert(repo.order, split_item)
                            refresh_tracks(opts, repo.order, #repo.order)
                            controller.insert({ split_item }, #repo.order)
                        end
                        --]]

                        ---@type OrderItem
                        local order_item = {
                            type = "commit",
                            commit = item,
                            tracks = {},
                        }
                        table.insert(repo.order, order_item)
                        refresh_tracks(opts, repo.order, #repo.order)
                        controller.insert({ order_item }, #repo.order)

                        --[[
                        if opts.merge_style.merge_on_separate_line and #item.parents > 1 and #item.children > 0 then
                            ---@type OrderItem
                            local merge_item = {
                                type = "merge",
                                commit = item,
                                tracks = {},
                            }

                            table.insert(repo.order, merge_item)
                            refresh_tracks(opts, repo.order, #repo.order)
                            controller.insert({ merge_item }, #repo.order)
                        end
                        --]]
                    end,
                })
            end).next(function()
                --vim.notify(vim.inspect(repo))
            end)
        end,
    }

    ---@type table
    local lv
    opts.win.keys = opts.win.keys or {}
    -- m: cycle the merge/split style and reflow in place (no re-fetch). This
    -- is the reflow path the interactive views (collapse/pin/toggle) will use:
    -- relayout repo.order, then re-render. One buffer line per commit doesn't
    -- change, so no insert/remove churn — only tracks and virtual lines update.
    opts.win.keys.m = function()
        merge_style_index = (merge_style_index % #MERGE_STYLES) + 1
        opts.merge_style = vim.deepcopy(MERGE_STYLES[merge_style_index].style)
        reset_ids()
        refresh_tracks(opts, repo.order, 1)
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
    -- <CR>: open the commit view for the commit on the current row (§11).
    opts.win.keys["<CR>"] = function(self)
        local line = vim.api.nvim_win_get_cursor(self.win)[1]
        local item = repo.order[line]
        if not item or not item.commit then
            return
        end
        open_commit_view(opts, item.commit)
    end
    -- K: float with the full lane breakdown for the commit under the cursor.
    opts.win.keys.K = function(self)
        local line = vim.api.nvim_win_get_cursor(self.win)[1]
        local item = repo.order[line]
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
            local line = vim.api.nvim_win_get_cursor(self.win)[1]
            local item = repo.order[line]
            local commit = item and item.commit or nil
            if not commit then
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
            local item = repo.order[line]
            if not item or not item.commit then return end
            local col = nil
            -- A selected ref: jump onto it (the listview pins refs to the right
            -- edge, so find the decoration text in the rendered line).
            if selection_state.commit == item.commit and selection_state.index then
                local texts = decoration_texts(item.commit)
                if selection_state.index <= #texts then
                    local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
                    col = ref_byte_col(text, texts[selection_state.index])
                end
            end
            -- Otherwise park at the start of the message column (FLEX_COL).
            if not col and lv and lv.controller and lv.controller.col_offset then
                col = lv.controller.col_offset(line, "line", FLEX_COL)
            end
            pcall(vim.api.nvim_win_set_cursor, win, { line, col or 0 })
        end

        -- On moving to a different row, reset the selection to the message and
        -- re-park the cursor. Only refresh when a decoration was highlighted on
        -- the row we left (otherwise nothing to redraw).
        local last_line = nil
        vim.api.nvim_create_autocmd("CursorMoved", {
            group = vim.api.nvim_create_augroup("Gitloom_" .. buf, { clear = true }),
            buffer = buf,
            callback = function()
                local line = vim.api.nvim_win_get_cursor(win)[1]
                if line == last_line then return end
                last_line = line
                local item = repo.order[line]
                selection_state.commit = item and item.commit or nil
                selection_state.index = nil
                if selection_visible and lv.controller then
                    lv.controller.refresh()
                end
                selection_visible = false
                place_cursor()
            end,
        })

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
    build_graph = build_graph,
    get_track_chars = get_track_chars,
    reset_ids = reset_ids,
}

return M
