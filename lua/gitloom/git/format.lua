--- git data presentation — rendering commit details, diffs, diffstats and the
--- working-tree state into compose-style `{ text, highlight }` rows for the
--- commit view (specification.md §11, §13.5). Pure; part of the gitloom.git
--- data library. The graph engine owns lane/row rendering; this owns the
--- text-only git views.

local util = require("gitloom.util")
local parse = require("gitloom.git.parse")

local highlight_text = util.highlight_text
local compose = util.compose
local trim_ws = util.trim_ws

local M = {}

--- The graph-row label for a working-tree virtual commit (§4.2): a synthesized
--- subject (the model carries no message), with the file counts from §3.3.
---@param commit Commit
---@return string
function M.worktree_label(commit)
    local wt = commit.wt or {}
    local n = wt.changed or 0
    local files = ("%d file%s"):format(n, n == 1 and "" or "s")
    if commit.virtual == "staged" then
        return "Staged changes · " .. files
    elseif commit.virtual == "untracked" then
        return "Untracked files · " .. files
    end
    return "Unstaged changes · " .. files
end

--- Render a CommitDetail into the commit view's display lines (one compose-style
--- `{ text, highlight }` per buffer line). The committer block is shown only
--- when it differs from the author (the common case is omitted). `opts` carries
--- the row's `decorations` (refs, reused from the model; §6) and the `palette`
--- for highlights. Pure; exposed for testing.
---@param detail CommitDetail
---@param opts? { decorations?: string[], palette?: GraphPalette }
---@return table[]
function M.format_commit_detail(detail, opts)
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

--- The §13.5 range list's identity cell for one selected node: the abbreviated
--- hash, or `working` for a §4.2 working-tree virtual commit — whose hash is a
--- reserved sentinel and must never be shown as though it were an object name.
--- Seven cells either way, so the list stays aligned. Pure.
---@param c { hash: string, virtual?: string }
---@return string
local function range_row_id(c)
    if c.virtual then return "working" end
    return c.hash:sub(1, 7)
end
M.range_row_id = range_row_id

--- Metadata rows for the **range** commit view (spec §13.5): a summary line
--- (`N commits  (oldest..newest)`) then one row per selected commit, newest
--- first — abbreviated hash + subject. Replaces the single-commit detail block
--- when the commit view is opened on a selection. A §4.2 working-tree node on the
--- path carries no hash and no subject, so its row is synthesized: the `working`
--- id cell plus `worktree_label`'s text, the same wording the graph row and the
--- §11.8 header use, so the three never disagree. Pure.
---@param commits { hash: string, message?: string, virtual?: string, wt?: table }[]   selected commits, newest first
---@param palette table
---@return table[]
function M.format_range_detail(commits, palette)
    palette = palette or {}
    local rows = {}
    local n = #commits
    local summary = (n == 1) and "1 commit" or (("%d commits"):format(n))
    if n >= 2 then
        summary = summary .. ("  (%s..%s)"):format(range_row_id(commits[n]), range_row_id(commits[1]))
    end
    rows[#rows + 1] = highlight_text(summary, palette.author)
    rows[#rows + 1] = highlight_text("")
    for _, c in ipairs(commits) do
        rows[#rows + 1] = compose({
            highlight_text(range_row_id(c), palette.date),
            highlight_text("  "),
            highlight_text(c.virtual and M.worktree_label(c) or (c.message or ""), palette.message),
        })
    end
    return rows
end

--- Metadata rows for the working-tree commit view (spec §11.8): a short title
--- naming the state (staged / unstaged / untracked). There is no
--- hash/author/committer/parent — the per-file counts come from the diffstat
--- (§11.4) below. Pure.
---@param commit Commit   a virtual commit (commit.virtual + commit.wt)
---@param palette table
---@return table[]
function M.format_worktree_detail(commit, palette)
    palette = palette or {}
    local wt = commit.wt or {}
    local rows = {}
    if commit.virtual == "staged" then
        rows[#rows + 1] = highlight_text("Staged changes", palette.author)
        rows[#rows + 1] = highlight_text("index vs HEAD", palette.date)
    elseif commit.virtual == "untracked" then
        local n = wt.changed or 0
        rows[#rows + 1] = highlight_text("Untracked files", palette.author)
        rows[#rows + 1] = highlight_text(
            ("%d file%s, shown as additions"):format(n, n == 1 and "" or "s"),
            palette.date)
    else
        rows[#rows + 1] = highlight_text("Unstaged changes", palette.author)
        rows[#rows + 1] = highlight_text("working tree vs index", palette.date)
    end
    rows[#rows + 1] = highlight_text("")
    return rows
end

--- Render a patch into the commit view's diff lines (one compose-style
--- `{ text, highlight }` per line), each line colored by its role via
--- `palette.diff` (add/delete/hunk/header; context uncolored). Line-level
--- highlighting only (specification.md §11.3). Pure; exposed for testing.
---@param patch string?
---@param palette GraphPalette?
---@return table[]
function M.format_diff(patch, palette)
    local diff = (palette or {}).diff or {}
    local groups = { add = diff.add, delete = diff.delete, hunk = diff.hunk, header = diff.header }
    local rows = {}
    for _, line in ipairs(vim.split(patch or "", "\n")) do
        local role = parse.diff_line_role(line)
        rows[#rows + 1] = highlight_text(line, role and groups[role] or nil)
    end
    return rows
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
function M.format_diffstat(files, palette)
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

--- One-line description of a failed git command, from a `git_code` result
--- (`{ code, out, err }`). Used where a swallowed exit code would otherwise be
--- indistinguishable from empty output — today the range diff (§13.5), whose
--- endpoints are *derived* rather than typed by the user. `label` names the
--- command (e.g. `"git diff"`). git's own stderr is the useful part, so it is
--- appended when there is any; only its **first** line, since the message goes in
--- a single row / notification. Pure.
---@param label string
---@param res { code: integer, out: string, err: string? }?
---@return string
function M.format_git_error(label, res)
    local code = res and res.code or -1
    local msg = ("%s failed (exit %d)"):format(label, code)
    local err = res and res.err or ""
    local first = err:match("^[^\r\n]*") or ""
    first = trim_ws(first)
    if first ~= "" then msg = msg .. ": " .. first end
    return msg
end

return M
