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

    local command = { "git", "log", "--remotes", "--date-order", "--decorate=full", "--parents", unpack(opts.branch),
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

---@param state TrackState
---@param track? Track
---@param item OrderItem
local function handle_commit(state, track, item)
    -- We have a completely new commit as not merge or split is happening.
    local has_commit = state.merge == nil and state.split == nil

    if not state.merge then
        state.merge = {
            remaining = #item.commit.parents,
            new_parents = {},
        }

        for _, p in ipairs(item.commit.parents) do
            table.insert(state.merge.new_parents, p)
        end
    else
        state.merge.remaining = #state.merge.new_parents
    end

    if not state.split then
        state.split = {
            remaining = #item.commit.children
        }
    end

    local splitting_or_merging = state.merge and #state.merge.new_parents > 1 or state.split ~= nil

    local track_id = track and track.id or get_next_id()

    for i = 1, state.space_available do
        if i > 1 and not (state.merge and #state.merge.new_parents > 0) and not (state.split and state.split.remaining > 0) then
            break
        end

        local parent = state.merge and table.remove(state.merge.new_parents, 1)

        ---@type Track
        local new_track = {
            id = track_id,
            --override = "*",
            connectivity = {
                down = parent ~= nil,
                right = state.merge and #state.merge.new_parents > 0 or i < state.space_available or
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
---@param track Track
local function handle_line(state, track)
    local splitting_or_merging = state.merge and #state.merge.new_parents > 0 or
        state.split and state.split.remaining > 0 or false

    for i = 1, state.space_available do
        ---@type Track
        local new_track = {
            id = state.merge_id or track.id,
            --override = "*",
            --override = state.split and tostring(state.split.remaining) or "-",
            connectivity = {
                up = i == state.space_available,
                down = splitting_or_merging and i == state.space_available or i == 1,
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

---@class Refs
---@field branches string[]
---@field tags string[]

---@class Commit
---@field hash string
---@field parents Commit[]
---@field children Commit[]
---@field refs Refs

---@class Connectivity
---@field up boolean
---@field down boolean
---@field left boolean
---@field right boolean

---@class Track
---@field id integer
---@field connectivity Connectivity
---@field has_commit boolean
---@field commit? Commit
---@field parent Commit
---@field override? string

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
---@field commit Commit
---@field tracks Track[]

---@param order OrderItem[]
---@param start_pos integer
local function refresh_tracks(order, start_pos)
    start_pos = start_pos or 1
    for i = start_pos, #order do
        ---@type OrderItem
        local item = order[i]
        ---@type OrderItem?
        local prev = order[i - 1]

        ---@type TrackState
        local state = {
            new_tracks = {},
            space_available = 1,
            tracks = {}
        }

        ---@type Track[]
        local tracks = prev and prev.tracks or {}
        local handled = false
        for _, t in ipairs(tracks) do
            if t.connectivity.down then
                if t.parent == item.commit then
                    handle_commit(state, t, item)
                    handled = true
                else
                    handle_line(state, t)
                end

                state.space_available = 1
            else
                state.space_available = state.space_available + 1
            end
        end

        if not handled then
            handle_commit(state, nil, item)
        end

        -- Add a new track for each new parent that hasn't been handled yet.
        if state.merge then
            for j, p in ipairs(state.merge.new_parents) do
                ---@type Track
                local new_track = {
                    id = get_next_id(),
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

        item.tracks = state.new_tracks
    end
end

local function compose(list)
    local text = ""
    local highlight = {}
    for _, item in ipairs(list) do
        if type(item) == "table" then
            local offset = string.len(text)
            for _, hl in ipairs(item.highlight) do
                table.insert(highlight, {
                    start_pos = offset + hl.start_pos,
                    end_pos = offset + hl.end_pos,
                    hl = hl.hl
                })
            end
            text = text .. item.text
        elseif type(item) == "string" then
            text = text .. item
        end
    end

    return {
        text = text,
        highlight = highlight,
    }
end

---@param tracks Track[]
local function get_track_chars(tracks)
    local result = ""

    for i = 1, #tracks do
        local track = tracks[i]
        local next = tracks[i + 1]

        local c = {
            left = track.connectivity.left,
            right = track.connectivity.right or next and next.connectivity.left,
            up = track.connectivity.up,
            down = track.connectivity.down,
        }

        local char = " "
        if track.override ~= nil then
            char = track.override
        elseif track.has_commit then
            char = (#track.commit.parents > 1) and "M" or "o"
        elseif c.left and c.right and not c.up and not c.down then
            char = "─"
        elseif c.left and c.up and not c.right and c.down then
            char = "┤"
        elseif not c.left and c.up and c.right and c.down then
            char = "├"
        elseif c.left and c.up and c.right and not c.down then
            char = "┴"
        elseif c.left and not c.up and c.right and c.down then
            char = "┬"
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

        -- "┌"  "┘" or "─",
        -- ┴─┴─ ┤
        result = result .. char

        if next ~= nil and (track.connectivity.right and next.connectivity.left) then
            result = result .. "─"
        elseif next ~= nil and (track.connectivity.right and not next.connectivity.left) then
            result = result .. "╴"
        elseif next ~= nil and (not track.connectivity.right and next.connectivity.left) then
            result = result .. "╶"
        else
            result = result .. " "
        end
    end

    return result
end

function M.open(folder, opts)
    opts = vim.tbl_deep_extend("force", {
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
        },
    }, opts or {})

    local listview = require("gitit.listview")

    local repo = {
        commits = {},
        order = {},
        branches = {},
        heads = {},
        refresh_scheduled = false,
    }

    local palette = opts.palette

    local highlight_text = function(text, hl)
        if text == "" then
            return {
                text = text,
                highlight = {},
            }
        end

        return {
            text = text,
            highlight = {
                {
                    start_pos = 0,
                    end_pos = string.len(text),
                    hl = hl,
                },
            }
        }
    end

    return listview.open({
        win = opts.win,
        display = function(item)
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

            return {
                highlight_text(item.commit.date .. " ", palette.date),
                highlight_text(item.commit.author .. " ", palette.author),
                get_track_chars(item.tracks),
                compose({
                    highlight_text(branches, palette.branch),
                    highlight_text(tags, palette.tags),
                    --highlight_text(vim.inspect(item.commit.refs.symbols, { newline=" " }), palette.tags),
                    --highlight_text(vim.inspect(item.commit.refs.raw, { newline=" " }), palette.tags),
                    highlight_text(item.commit.message, palette.message),
                }),
            }
        end,
        on_controller = function(controller)
            fetch_branches({
                on_item = function(name, hash)
                    repo.branches[name] = hash
                    table.insert(repo.heads, { name = name, hash = hash })
                end,
            }).next(function()
                return fetch_commits({
                    branch = opts.branch or { "--all" },
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
                            existing.loaded = item.loaded

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

                        local order_item = {
                            commit = item,
                            tracks = {},
                        }
                        table.insert(repo.order, order_item)
                        refresh_tracks(repo.order, #repo.order)
                        controller.insert({ order_item }, #repo.order)
                        --end
                    end,
                })
            end).next(function()
                --vim.notify(vim.inspect(repo))
            end)
        end,
    })
end

return M
