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

    local command = { "git", "log", "--date-order", "--decorate=full", "--parents", unpack(opts.branch),
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
        local shift_count = 0
        local merging_id = nil
        local new_commits = {}
        for _, t in ipairs(tracks) do
            local new_track = nil
            if t.parent ~= nil and t.parent == item.commit then
                if t.connectivity.down then
                    --[[
                    local already_present = false
                        local present_count = 0
                        for _, t2 in ipairs(new_tracks) do
                            if t2.parent == item.commit then
                                present_count = present_count + 1
                                already_present = true
                            end
                        end

                        already_present = #t.commit.parents <= present_count
                        --]]
                    found = true
                    merging = math.max(0, #item.commit.parents - 1)

                    splitting = math.max(0, splitting - 1)
                    if splitting == 0 then
                        splitting = #item.commit.children
                    end

                    --[[
                    if already_present then
                        splitting = math.max(0, splitting - 1)
                    else
                        splitting = math.max(0, #item.commit.children - 1)
                    end
                    --]]

                    local is_merge = #item.commit.parents > 1
                    new_track = {
                        id = t.id,
                        --char = already_present and "┘" or (#item.commit.parents > 1) and "M" or "o",
                        --override = #item.commit.parents > 1 and "M" or nil,
                        commit = item.commit,
                        parent = item.commit.parents[1],
                        --override = tostring(splitting),
                        --override = "a",
                        connectivity = {
                            up = t.connectivity.down,
                            left = splitting < #item.commit.children, -- or merging > 1,
                            right = splitting > 1 and splitting < #item.commit.children, --or #new_commits > 1,
                            down = splitting == #item.commit.children,
                        },
                        --has_commit = not already_present,
                        has_commit = splitting == #item.commit.children
                    }

                    for j, p in ipairs(item.commit.parents) do
                        if j > 1 then
                            table.insert(new_commits, p)
                        end
                    end
                    if merging > 0 then
                        merging_id = new_track.id
                    end
                else
                    if merging > 0 and merging_id ~= nil then
                        merging = merging - 1
                        new_track = {
                            id = merging_id,
                            char = "─",
                            parent = nil,
                            connectivity = {
                                left = true,
                                right = true,
                            },
                            has_commit = false,
                        }
                    else
                        shift_count = shift_count + 1
                    end
                end
            elseif t.connectivity.down then
                new_track = {
                    id = t.id,
                    char = "│",
                    parent = t.parent,
                    connectivity = {
                        up = true,
                        down = true,
                        left = splitting > 1 or merging > 0,
                        right = splitting > 1 or merging > 1,
                    },
                    has_commit = false,
                }
            end

            if new_track ~= nil then
                for j = 1, shift_count do
                    table.insert(new_tracks, {
                        id = t.id,
                        char = j == 1 and "┌" or j == shift_count and "┘" or "─",
                        --commit = item.commit,
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

                table.insert(new_tracks, new_track)
            end
        end

        --[[
            for j = 1, merging do
                table.insert(new_tracks, {
                    id = merging_id,
                    char = "┐",
                    connectivity = {
                        left = true,
                        right = j < merging,
                        down = true,
                    },
                    commit = item.commit,
                    has_commit = false,
                })
            end
            --]]
        merging = 0

        for j, commit in ipairs(new_commits) do
            table.insert(new_tracks, {
                id = merging_id,
                --override = "a",
                connectivity = {
                    left = true,
                    right = j < #new_commits,
                    down = true,
                },
                parent = commit,
                has_commit = false,
            })
        end
        new_commits = {}

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
        elseif c.up and c.down then
            char = "│"
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
        else
            vim.notify(vim.inspect(c))
        end

        -- "┌"  "┘" or "─",
        -- ┴─┴─ ┤
        result = result .. char

        if next ~= nil and (track.connectivity.right or next.connectivity.left) then
            result = result .. "─"
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

            return {
                highlight_text(item.commit.date .. " ", palette.date),
                highlight_text(item.commit.author .. " ", palette.author),
                get_track_chars(item.tracks),
                compose({
                    highlight_text(branches, palette.branch),
                    highlight_text(tags, palette.tags),
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
