--- Commit timestamps — parsing git's date fields into a structured Timestamp
--- and formatting them for display (specification.md §4, §6). Pure; part of the
--- gitloom.git data library.

local M = {}

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
function M.parse_timestamp(epoch_str, iso)
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
function M.format_absolute(ts, fmt)
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
function M.format_relative(ts, now)
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

-- The largest count the relative vocabulary prints for the top unit (years).
-- Every other unit's count is bounded by the next larger unit (59 seconds, 23
-- hours, ...); a year count is not, so it is capped where a longer phrase would
-- need five digits (§6: "9999 years ago" is as long as "59 seconds ago").
local REL_MAX_YEARS = 9999

--- Display width (cells) of a string; `vim` is always present at runtime, the
--- byte length is the fallback for a bare-Lua caller.
local function cells(s)
    if vim and vim.fn and vim.fn.strdisplaywidth then return vim.fn.strdisplaywidth(s) end
    return #s
end

local relative_cache

--- The widest phrase `format_relative` can produce, in cells (§6): for every unit
--- the largest count it is printed with — one less than the next larger unit in
--- this unit (`59 seconds`, `23 hours`, `4 weeks`, `12 months`), the year count
--- capped at REL_MAX_YEARS — plus "just now". Derived from REL_UNITS, so it
--- follows the vocabulary.
---@return integer
function M.relative_width()
    if relative_cache then return relative_cache end
    local w = cells("just now")
    for i, u in ipairs(REL_UNITS) do
        local n = (i == 1) and REL_MAX_YEARS or math.floor((REL_UNITS[i - 1][1] - 1) / u[1])
        w = math.max(w, cells(M.format_relative({ epoch = 0, offset = 0 }, n * u[1])))
    end
    relative_cache = w
    return w
end

-- Probe dates for absolute_width: one per day of 2001 (from Monday 2001-01-01
-- 00:00 UTC), so every month, every weekday and every day number (1-31, two-digit
-- ones included) appear, each at a two-digit morning and a two-digit evening time
-- (AM and PM, 10:10:10 / 23:59:59).
local PROBE_BASE = 978307200 -- 2001-01-01 00:00:00 UTC
local PROBE_TIMES = { 10 * 3600 + 10 * 60 + 10, 23 * 3600 + 59 * 60 + 59 }
local absolute_cache = {}

--- The widest text the os.date format `fmt` produces over the probe dates, in
--- cells (§6): a format with names (`%B`, `%a`) gets its longest name in the
--- current locale. Cached per format.
---@param fmt string?
---@return integer
function M.absolute_width(fmt)
    fmt = fmt or "%Y-%m-%d %H:%M"
    local cached = absolute_cache[fmt]
    if cached then return cached end
    local w = 0
    for day = 0, 364 do
        for _, t in ipairs(PROBE_TIMES) do
            local ts = { epoch = PROBE_BASE + day * 86400 + t, offset = 0 }
            w = math.max(w, cells(M.format_absolute(ts, fmt)))
        end
    end
    absolute_cache[fmt] = w
    return w
end

--- The date column's text width for `opts.date_mode` (§6): a function of the
--- mode (and `date_format`) alone, never of the commits shown.
---@param opts GraphOptions
---@return integer
function M.date_width(opts)
    if opts.date_mode == "relative" then return M.relative_width() end
    return M.absolute_width(opts.date_format)
end

--- Render a commit's date for display per opts.date_mode (§6).
---@param ts Timestamp?
---@param opts GraphOptions
---@return string
function M.format_date(ts, opts)
    if type(ts) ~= "table" then return ts and tostring(ts) or "" end
    if opts.date_mode == "relative" then
        return M.format_relative(ts, os.time())
    end
    return M.format_absolute(ts, opts.date_format)
end

return M
