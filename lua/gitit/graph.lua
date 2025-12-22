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

    return {
        hash = hash,
        parents = parents,
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
    track.commit = commit.hash
    track.parent = old_parent.hash

    local result = vim.inspect(track)

    commit.parents = old_parents
    commit.children = old_children
    track.commit = old_commit
    track.parent = old_parent

    return result
end

local function refresh_tracks(order, start_pos)
    start_pos = start_pos or 1
    for i = start_pos, #order do
        local item = order[i]
        local prev = order[i - 1]

        local tracks = prev and prev.tracks or {}
        local new_tracks = {}
        local found = false
        local merging = 0
        local splitting = 0
        local merging_id = nil
        local new_commits = {}
        local connections = {}
        local shift = nil
        for _, t in ipairs(tracks) do
            if t.connectivity.down then
                table.insert(connections, t)
            end
        end
        local new_parents = {}
        for _, p in ipairs(item.commit.parents) do
            table.insert(new_parents, p)
        end

        for i, t in ipairs(tracks) do
            local new_track = nil
            if shift then
                -- Handle shift before anything else
                shift.count = shift.count + 1
                new_track = {
                    id = shift.connection.id,
                    --override = t.connectivity.down and "E" or "*",
                    connectivity = {
                        up = t.connectivity.down,
                        left = true,
                        right = not t.connectivity.down,
                        down = false,
                    },
                    has_commit = false,
                }

                if t.connectivity.down then
                    shift = nil
                end
            elseif t.connectivity.down and t.parent ~= nil and t.parent == item.commit then
                found = true
                merging = math.max(0, merging - 1)
                if merging == 0 then
                    merging = #item.commit.parents
                end

                splitting = math.max(0, splitting - 1)
                if splitting == 0 then
                    splitting = #item.commit.children
                end

                local parent = nil
                if #new_parents > 0 then
                    --parent = new_parents[1]
                    parent = table.remove(new_parents, 1)
                end

                if #new_commits > 0 then
                    table.remove(new_commits, 1)
                end

                new_track = {
                    id = t.id,
                    commit = item.commit,
                    --override = "*",
                    --override = tostring(splitting),
                    parent = parent,
                    connectivity = {
                        up = t.connectivity.down,
                        left = splitting < #item.commit.children,
                        right = splitting > 1 and splitting <= #item.commit.children or
                            merging > 1 and merging <= #item.commit.parents,
                        --down = splitting == #item.commit.children or merging >= 1,
                        down = parent ~= nil,
                    },
                    has_commit = splitting == #item.commit.children --or merging == #item.commit.parents
                }

                --[[
                if (new_track.parent ~= nil) ~= new_track.connectivity.down then
                    if #item.commit.parents > 0 then
                        vim.notify(inspect_commit(item.commit.parents[1]))
                    end
                    vim.notify(inspect_track(new_track))
                end
                --]]

                if new_track.has_commit then
                    for j, p in ipairs(item.commit.parents) do
                        if j > 1 then
                            table.insert(new_commits, p)
                        end
                    end
                end

                if merging > 1 then
                    merging_id = new_track.id
                end
            elseif t.connectivity.down then
                new_track = {
                    id = t.id,
                    char = "│",
                    parent = t.parent,
                    connectivity = {
                        up = true,
                        down = true,
                        left = splitting > 1 or merging > 1,
                        right = splitting > 1 or merging > 1,
                    },
                    has_commit = false,
                }
            elseif #connections > 0 then
                shift = {
                    connection = connections[1],
                    count = 1,
                }

                table.remove(connections, 1)

                new_track = {
                    id = shift.connection.id,
                    --override = "*",
                    connectivity = {
                        up = false,
                        left = false,
                        right = true,
                        down = true,
                    },
                    parent = shift.connection.parent,
                    has_commit = false,
                }
            end

            if new_track ~= nil then
                --[[
                for j = 1, shift_count do
                    table.insert(new_tracks, {
                        id = t.id,
                        connectivity = {
                            left = j > 1,
                            up = j == shift_count,
                            right = j < shift_count,
                            down = j == 1,
                        },
                        has_commit = false,
                    })
                end
                shift_count = 0
                --]]

                if #connections > 0 and connections[1].id == new_track.id then
                    table.remove(connections, 1)
                end
                --[[
                for j, p in ipairs(new_parents) do
                    if p == new_tracks.parent then
                        vim.notify(inspect_commit(new_parents[j]))
                        table.remove(new_parents, j)
                        break
                    end
                end
                --]]
                table.insert(new_tracks, new_track)
            end
        end

        merging = 0

        local commit_found = false
        for _, t in ipairs(new_tracks) do
            if t.commit == item.commit then
                commit_found = true
                break
            end
        end

        if not commit_found then
            merging_id = nil
            new_commits = {}
            for _, p in ipairs(item.commit.parents) do
                table.insert(new_commits, p)
            end
        end

        for j, parent in ipairs(new_commits) do
            local new_track = {
                id = merging_id or get_next_id(),
                --override = "a",
                connectivity = {
                    left = merging_id ~= nil,
                    right = j < #new_commits,
                    down = true,
                },
                parent = parent,
                --commit = merging_id == nil and item.commit,
                commit = merging_id == nil and item.commit or nil,
                --has_commit = merging_id == nil,
                has_commit = merging_id == nil,
            }

            table.insert(new_tracks, new_track)

            merging_id = new_track.id
        end

        --[[
        local item_found = false
        for _, t in ipairs(new_tracks) do
            if t.commit == item.commit then
                item_found = true
                break
            end
        end

        if not item_found then
            --vim.notify(inspect_commit(item.commit))
            local s = inspect_commit(item.commit) .. "\n"
            for _, t in ipairs(new_tracks) do
                s = s .. inspect_track(t) .. "\n"
            end
            vim.notify(s)
        end
        --]

        merging_id = nil
        --[[

        if not found then
            for j, p in ipairs(item.commit.parents) do
                table.insert(new_tracks,
                    {
                        id = get_next_id(),
                        parent = p,
                        connectivity = {
                            down = true,
                            left = j > 1,
                            right = j ~= #item.commit.parents,
                        },
                        commit = j == 1 and item.commit or nil,
                        has_commit = j == 1,
                    })
            end
        end
        --]]

        item.tracks = new_tracks
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
        elseif not c.left and not c.up and c.right and c.down then
            char = "╭"
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
