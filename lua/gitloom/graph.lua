local M = {}

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


local function fetch_branches(opts)
    opts = opts or {}

    local future, promise = make_future()

    vim.fn.jobstart(
        { "git", "for-each-ref", "--format=%(refname:short) %(objectname)", "refs/heads" },
        {
            stdout_buffered = true,
            on_stdout = function(_, lines)
                for _, line in ipairs(lines) do
                    if line ~= "" then
                        local name, hash = line:match("^(%S+)%s+(%x+)$")

                        if name and hash then
                            if opts.on_item then
                                opts.on_item(name, hash)
                            end
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

local function parse_refs(str)
    ---@type Refs
    local result = {
        branches = {},
        tags = {},
        symbols = {},
        raw = {}
    }

    if str == "" then
        return result
    end

    for entry in string.gmatch(str, "([^,]+)") do
        entry = vim.trim(entry)

        local left, right = entry:match("^(.-)%s*%-%>%s(.+)$")
        if left and right then
            table.insert(result.symbols, { from = left, to = right })
            table.insert(result.branches, { name = right })
            goto continue
        end

        local tag = entry:match("^tag:%s*(.+)$")
        if tag then
            table.insert(result.tags, { name = tag })
            goto continue
        end

        local head = entry:match("^refs/heads/(.+)$")
        if head then
            table.insert(result.branches, { name = head })
            goto continue
        end

        table.insert(result.raw, entry)

        ::continue::
    end

    return result
end

local function parse_commit_line(line)
    local fields = vim.split(line, "\x1f")

    local hash = fields[1]
    local parents = vim.split(fields[2], " ")
    local author = fields[3]
    local date = fields[4]
    local subject = fields[5]
    local refs = parse_refs(fields[6])

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
        refs = refs
    }
end

local function fetch_commits(opts)
    opts = opts or {}

    local future, promise = make_future()

    if opts.branch and type(opts.branch) ~= "table" then
        opts.branch = { opts.branch }
    end

    local command = { "git", "log", "--remotes", "--topo-order", "--decorate=full", "--parents", unpack(opts.branch),
        "--pretty=format:%H%x1f%P%x1f%an%x1f%ai%x1f%s%x1f%D" }
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

---@class Refs
---@field branches Ref[]
---@field tags Ref[]

---@class Commit
---@field hash string
---@field parents Commit[]|string[]
---@field children Commit[]|string[]
---@field refs Refs
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
--- NOTE: migrating to a `lanes: Lane[]` cell model (specification.md §5):
--- glyph = union of lanes' connectivity, color = a "top" lane's id. The
--- single-id fields above are the current representation.

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
local function get_track_chars(opts, tracks)
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
        local track_id = track.id
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
            for j = i + 1, #tracks do
                local t = tracks[j]
                local is_cross = t.connectivity.down and t.connectivity.up and t.connectivity.left and
                    t.connectivity.right
                local is_jump = not t.connectivity.down and not t.connectivity.up and t.connectivity.right and
                    t.connectivity.left
                if not is_cross and not is_jump then
                    track_id = t.id
                    break
                end
            end
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

    return result
end

---@class SelectionState
---@field cursor integer

---@param opts GraphOptions
---@param item OrderItem
---@param selection_state SelectionState
---@return DisplayElement
local function display_item(opts, item, selection_state)
    local palette = opts.palette

    local branches = ""
    for _, branch in ipairs(item.commit.refs.branches or {}) do
        branches = branches .. "(" .. branch.name .. ")"
    end
    if branches ~= "" then
        branches = branches .. " "
    end

    local tags = ""
    for _, tag in ipairs(item.commit.refs.tags or {}) do
        tags = tags .. "[" .. tag.name .. "]"
    end
    if tags ~= "" then
        tags = tags .. " "
    end

    --[[
            local symbols = ""
            for _, symbol in ipairs(item.commit.refs.symbols or {}) do
                symbols = symbols .. "{" .. symbol.name .. "}"
            end
            if symbols ~= "" then
                symbols = symbols .. " "
            end
            --]]

    --tracks = ""

    local get_tracks = function(tracks)
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
                highlight_text(item.commit.date .. " ", palette.date),
                highlight_text(item.commit.author .. " ", palette.author),
                get_track_chars(opts, item.tracks),
                compose({
                    get_tracks(item.tracks),
                    highlight_text(branches, palette.branch),
                    highlight_text(tags, palette.tags),
                    --highlight_text(vim.inspect(item.commit.refs.symbols, { newline=" " }), palette.tags),
                    --highlight_text(vim.inspect(item.commit.refs.raw, { newline=" " }), palette.tags),

                    highlight_text(item.commit.message, palette.message) or "",
                }),
            }
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

---@class GraphWinOptions
---@field border string
---@field width number
---@field height number
---@field title string
---@field footer string

---@class GraphPalette
---@field date? string
---@field author? string
---@field branch? string
---@field message? string
---@field tags? string
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

---@param opts GraphOptions
function M.open(folder, opts)
    ---@type GraphOptions
    local defaults = {
        win = {
            border = "rounded",
            width = 0.80,
            height = 0.80,
            title = "GraphView",
            footer = "Press 'q' to quit",
        },
        palette = {
            date = "Title",
            author = "Comment",
            branch = "WarningMsg",
            message = nil,
            tags = "Comment",
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
        merge_style = {
            allow_merge_on_split = false,
            merge_on_separate_line = false,
            split_on_separate_line = true,
        },
        icons = {
            --merge = "M",
        },
    }
    ---@type GraphOptions
    opts = vim.tbl_deep_extend("force", defaults, opts or {})

    local listview = require("gitloom.listview")

    -- Fresh lane-id sequence per opened graph so colors are deterministic.
    reset_ids()

    ---@class Repo
    ---@field commits table<string, Commit>
    ---@field order Commit[]
    ---@field branches string[]
    ---@field heads string[]
    ---@field refresh_scheduled boolean

    ---@type Repo
    local repo = {
        commits = {},
        order = {},
        branches = {},
        heads = {},
        refresh_scheduled = false,
    }

    local palette = opts.palette

    ---@type SelectionState
    local selection_state = {
        cursor = 1
    }

    ---@type ListViewOptions
    local listview_options = {
        win = opts.win,
        display = function(item)
            return display_item(opts, item, selection_state)
        end,
        on_controller = function(controller)
            fetch_branches({
                on_item = function(name, hash)
                    repo.branches[name] = hash
                    table.insert(repo.heads, { name = name, hash = hash })
                end,
            }).next(function()
                return fetch_commits({
                    branch = opts.branches or { "--all" },
                    ---@param item Commit
                    on_item = function(item)
                        --if not repo.commits[item.hash] then
                        -- New commit

                        local existing = repo.commits[item.hash]
                        if existing then
                            existing.hash = item.hash
                            existing.author = item.author
                            existing.date = item.date
                            existing.refs = item.refs
                            existing.parents = item.parents
                            existing.message = item.message

                            item = existing
                        else
                            repo.commits[item.hash] = item
                            item.children = {}
                        end

                        -- Convert parent hashes to references
                        local newParents = {}
                        for _, p in ipairs(item.parents) do
                            local parent = repo.commits[p]
                            if not parent then
                                -- Add a dummy parent if not seen yet
                                parent = { hash = p, parents = {}, children = {}, refs = {} }
                                repo.commits[p] = parent
                            end

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

    return listview.open(listview_options)
end

-- Internal functions exposed for testing only. Not part of the public API.
M._internal = {
    parse_refs = parse_refs,
    parse_commit_line = parse_commit_line,
    build_graph = build_graph,
    get_track_chars = get_track_chars,
    reset_ids = reset_ids,
}

return M
