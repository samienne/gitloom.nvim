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
        parent = parents,
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
            message = "WarningMsg",
            branch = "Comment",
            tags = "Comment",
        },
    }, opts or {})

    local listview = require("gitit.listview")

    local repo = {
        commits = {},
        order = {},
        branches = {},
        heads = {},
    }

    local palette = opts.palette

    local highlight_text = function(text, hl)
        return {
            text = text,
            highlight = {
                start_pos = 0,
                end_pos = string.len(text),
                hl = hl,
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
                        hl = hl.highlight
                    })
                end
                text = text .. item.text
            elseif type(item) == "string" then
                text = text .. item
            end
        end

        return {
            text = text,
            highlight,
        }
    end

    return listview.open({
        win = opts.win,
        display = function(item)
            local branches = ""
            for _, branch in ipairs(item.refs.branches) do
                branches = branches .. "(" .. branch.name .. ")"
            end
            if branches ~= "" then
                branches = branches .. " "
            end

            local tags = ""
            for _, tag in ipairs(item.refs.tags) do
                tags = tags .. "[" .. tag.name .. "]"
            end
            if tags ~= "" then
                tags = tags .. " "
            end

            return {
                highlight_text(item.date .. " ", palette.date),
                highlight_text(item.author .. " ", palette.author),
                compose({
                    highlight_text(branches, palette.branch),
                    highlight_text(tags, palette.tags),
                    highlight_text(item.message, palette.message),
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
                        if not repo.commits[item.hash] then
                            -- New commit
                            repo.commits[item.hash] = item
                            table.insert(repo.order, item)
                            controller.insert({ item }, #repo.order)
                        end
                    end,
                })
            end).next(function()
                --vim.notify(vim.inspect(repo))
            end)
        end,
    })
end

return M
