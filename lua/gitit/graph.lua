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

    local command = { "git", "log", "--decorate=full", "--parents", unpack(opts.branch),
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

        if i == 1 then
            item.tracks = {
                {
                    id = get_next_id(),
                    char = "o",
                    commit = item.commit,
                    active = true,
                },
            }
        else
            local prev = order[i - 1]

            local newTracks = {}
            local found = false
            local merging = 0
            local splitting = 0
            local shift_count = 0
            local merging_id = nil
            for _, t in ipairs(prev.tracks) do
                local new_track = nil
                if table_contains(t.commit.parents, item.commit) then
                    if t.active then
                        local already_present = false
                        for _, t2 in ipairs(newTracks) do
                            if t2.commit == item.commit then
                                t2.merging = true
                                already_present = true
                                break
                            end
                        end

                        found = true
                        merging = math.max(0, #item.commit.parents - 1)
                        if already_present then
                            splitting = math.max(0, splitting - 1)
                        else
                            splitting = math.max(0, #item.commit.children - 1)
                        end

                        -- ┴─┴─┘
                        new_track = {
                            id = t.id,
                            char = already_present and "┘" or (#item.commit.parents > 1) and "M" or "o",
                            commit = item.commit,
                            active = not already_present,
                            merging = already_present or merging > 0 or splitting > 0,
                        }

                        if merging > 0 then
                            merging_id = new_track.id
                        end
                    else
                        if merging > 0 and merging_id ~= nil then
                            merging = merging - 1
                            new_track = {
                                id = merging_id,
                                char = "─",
                                commit = item.commit,
                                active = false,
                                merging = true,
                            }
                        else
                            shift_count = shift_count + 1
                        end
                    end
                elseif t.active then
                    new_track = {
                        id = t.id,
                        char = "│",
                        commit = t.commit,
                        active = true,
                        merging = merging > 0 or splitting > 0,
                    }
                end

                if new_track ~= nil then
                    for i = 1, shift_count do
                        table.insert(newTracks, {
                            id = t.id,
                            char = i == 1 and "┌" or i == shift_count and "┘" or "─",
                            commit = item.commit,
                            active = false,
                            merging = i < shift_count,
                        })
                    end
                    shift_count = 0

                    table.insert(newTracks, new_track)
                end
            end

            for i = 1, merging do
                table.insert(newTracks, {
                    id = merging_id,
                    char = "┐",
                    commit = item.commit,
                    active = true,
                    merging = true,
                })
            end
            merging = 0


            --[[
            for _ = 1, merging do
                table.insert(newTracks, {
                    id = get_next_id(),
                    char = "\\",
                    commit = item.commit,
                    active = true,
                })
            end
            --]]

            if not found then
                table.insert(newTracks, {
                    id = get_next_id(),
                    char = "o",
                    commit = item.commit,
                    active = true,
                })
            end

            item.tracks = newTracks
        end
    end
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

    local compose = function(list)
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

            local tracks = ""
            for i, t in ipairs(item.tracks) do
                tracks = tracks .. (t and t.char or " ") .. (t.merging and i < #item.tracks and "─" or " ")
            end
            tracks = tracks .. " "
            return {
                highlight_text(item.commit.date .. " ", palette.date),
                highlight_text(item.commit.author .. " ", palette.author),
                tracks,
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
