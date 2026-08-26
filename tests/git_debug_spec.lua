-- The `vim.g.gitloom_git_debug` spawn-capture hook (fetch.lua's `js` wrapper).
--
-- The hook exists to diagnose Windows E903 "name too long" (libuv
-- UV_ENAMETOOLONG) failures, which — measured by bisection on nvim 0.11.6 and
-- 0.12.5 alike — happen if and only if the final Windows command line exceeds
-- 32766 characters. `cmdline_len` reproduces that budget, so a captured record
-- says outright whether the spawn was over it.

local fetch = require("gitloom.git.fetch")
local D = fetch._internal

local function tmpfile()
    local p = vim.fn.tempname()
    return p
end

local function read(path)
    local fh = io.open(path, "r")
    if not fh then return nil end
    local s = fh:read("*a")
    fh:close()
    return s
end

describe("git spawn debug hook", function()
    after_each(function()
        vim.g.gitloom_git_debug = nil
    end)

    describe("cmdline_len (the Windows command-line budget)", function()
        it("counts an unquoted argument verbatim", function()
            assert.equals(3, D.quoted_len("abc"))
        end)

        it("quotes an empty argument", function()
            assert.equals(2, D.quoted_len(""))
        end)

        it("wraps an argument containing a space in quotes", function()
            assert.equals(5, D.quoted_len("a b"))
            assert.equals(34, D.quoted_len([[C:\Program Files\Git\cmd\git.EXE]]))
        end)

        it("escapes embedded quotes and the backslashes before them", function()
            -- a"b  ->  "a\"b"   = 2 quotes + a + \" + b = 6
            assert.equals(6, D.quoted_len([[a"b]]))
            -- a\"b ->  "a\\\"b" = 2 + 1 + 2 + 2 + 1 = 8
            assert.equals(8, D.quoted_len([[a\"b]]))
            -- a\b  has no space/tab/quote, so it is NOT quoted at all
            assert.equals(3, D.quoted_len([[a\b]]))
        end)

        it("reproduces the measured 32766-char ceiling (space-free exe)", function()
            -- Measured by bisection: `cmd /c x=<32733 a's>` is the longest
            -- spawn that succeeds; one more character fails with ENAMETOOLONG.
            local argv = { [[C:\windows\system32\cmd.EXE]], "/c", "x=" .. string.rep("a", 32733) }
            assert.equals(D.WIN_CMDLINE_MAX, D.cmdline_len(argv))
        end)

        it("reproduces the measured ceiling for a quoted (spaced) exe path", function()
            -- Same bisection with git, whose resolved path contains a space and
            -- therefore costs two extra characters: last-ok is 32718 a's.
            local argv = { [[C:\Program Files\Git\mingw64\bin\git.EXE]], "/c",
                "x=" .. string.rep("a", 32718) }
            assert.equals(D.WIN_CMDLINE_MAX, D.cmdline_len(argv))
        end)

        it("charges one separator between elements", function()
            assert.equals(#"git log -1", D.cmdline_len({ "git", "log", "-1" }))
        end)
    end)

    describe("spawn_record", function()
        it("lists every argv element separately and verbatim", function()
            local rec = D.spawn_record({
                argv = { "git", "log", "--pretty=format:%H%x1f%P", "deadbeef" },
                exe = [[C:\Program Files\Git\cmd\git.EXE]],
                cwd = "C:/src/repo",
                site = "fetch.lua:438",
                seq = 7,
                ok = true,
                id = 12,
            })
            assert.truthy(rec:find("[001] |git|", 1, true))
            assert.truthy(rec:find("[002] |log|", 1, true))
            assert.truthy(rec:find("[003] |--pretty=format:%H%x1f%P|", 1, true))
            assert.truthy(rec:find("[004] |deadbeef|", 1, true))
            assert.truthy(rec:find("C:/src/repo", 1, true))
            assert.truthy(rec:find("fetch.lua:438", 1, true))
            assert.truthy(rec:find([[C:\Program Files\Git\cmd\git.EXE]], 1, true))
            assert.truthy(rec:find("argc = 4", 1, true))
            assert.truthy(rec:find("spawn #7", 1, true))
            assert.truthy(rec:find("job id 12", 1, true))
            assert.is_nil(rec:find("EXCEEDS", 1, true))
        end)

        it("flags a command line over the Windows ceiling", function()
            local argv = { "git", "log" }
            for _ = 1, 900 do argv[#argv + 1] = string.rep("0", 40) end
            local rec = D.spawn_record({
                argv = argv,
                exe = [[C:\Program Files\Git\cmd\git.EXE]],
                cwd = "C:/src/repo",
                site = "fetch.lua:438",
                seq = 1,
                ok = false,
                id = 'Vim:E903: Process failed to start: name too long: "git"',
            })
            assert.truthy(rec:find("EXCEEDS", 1, true))
            assert.truthy(rec:find("SPAWN FAILED", 1, true))
            assert.truthy(rec:find("E903", 1, true))
            assert.truthy(rec:find(("argc = %d"):format(#argv), 1, true))
        end)
    end)

    describe("debug_log", function()
        it("is inert when the global is unset", function()
            local path = tmpfile()
            vim.g.gitloom_git_debug = nil
            D.debug_log({ "git", "log" }, "C:/x", true, 1)
            assert.is_nil(read(path))
        end)

        it("appends one record per spawn", function()
            local path = tmpfile()
            vim.g.gitloom_git_debug = path
            D.debug_log({ "git", "log" }, "C:/x", true, 1)
            D.debug_log({ "git", "status" }, "C:/x", true, 2)
            local body = read(path)
            assert.truthy(body)
            assert.truthy(body:find("|log|", 1, true))
            assert.truthy(body:find("|status|", 1, true))
            local n = select(2, body:gsub("gitloom git spawn", ""))
            assert.equals(2, n)
        end)
    end)

    describe("the js wrapper", function()
        it("captures a real spawn when the global is set", function()
            if vim.fn.executable("git") ~= 1 then return end
            local path = tmpfile()
            vim.g.gitloom_git_debug = path
            fetch.fetch_rev_order({ "--max-count=1", "--all" }, "--topo-order")
            vim.g.gitloom_git_debug = nil
            local body = read(path)
            assert.truthy(body)
            assert.truthy(body:find("|rev-list|", 1, true))
            assert.truthy(body:find("|--topo-order|", 1, true))
            assert.truthy(body:find("cmdline =", 1, true))
        end)

        it("writes nothing when the global is unset", function()
            if vim.fn.executable("git") ~= 1 then return end
            local path = tmpfile()
            vim.g.gitloom_git_debug = nil
            fetch.fetch_rev_order({ "--max-count=1", "--all" }, "--topo-order")
            assert.is_nil(read(path))
        end)
    end)
end)
