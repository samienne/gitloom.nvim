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

--- `read` for the cases that must have produced a file: asserts and narrows the
--- optional away so the body can be searched directly.
---@return string
local function must_read(path)
    local s = read(path)
    assert.truthy(s)
    return s or ""
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

    describe("the measured ceiling, against the real OS", function()
        -- The whole diagnostic rests on `cmdline_len` being EXACT, not a
        -- model: spawn one command line of exactly WIN_CMDLINE_MAX characters
        -- and one of WIN_CMDLINE_MAX + 1, and require the OS to agree.
        -- Through fetch.lua's own `spawn` (vim.system), the one spawner every
        -- git command uses: the ceiling was first bisected against jobstart,
        -- and this pins that it carried over unchanged.
        it("predicts a real spawn failure to the character", function()
            if vim.fn.has("win32") ~= 1 or vim.fn.executable("git") ~= 1 then return end
            local exe = vim.fn.exepath("git")
            local function try(pad)
                local argv = { "git", "-c", "x=" .. string.rep("a", pad), "--version" }
                local resolved = { exe, argv[2], argv[3], argv[4] }
                local done = false
                local ok, obj = pcall(D.spawn, argv, {}, function() done = true end)
                if ok then vim.wait(10000, function() return done end, 10) end
                return D.cmdline_len(resolved), ok, obj
            end
            local pad = D.WIN_CMDLINE_MAX - D.cmdline_len({ exe, "-c", "x=", "--version" })
            local len_at, spawned_at = try(pad)
            local len_over, spawned_over, err = try(pad + 1)
            assert.equals(D.WIN_CMDLINE_MAX, len_at)
            assert.equals(D.WIN_CMDLINE_MAX + 1, len_over)
            assert.is_true(spawned_at)   -- exactly at the cap still spawns
            assert.is_false(spawned_over) -- one character over does not
            -- ...and the failure is re-raised as vim.system reported it.
            assert.truthy(tostring(err):find("ENAMETOOLONG", 1, true), tostring(err))
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
            assert.truthy(rec:find("pid 12", 1, true))
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
            local body = must_read(path)
            assert.truthy(body:find("|log|", 1, true))
            assert.truthy(body:find("|status|", 1, true))
            local n = select(2, body:gsub("gitloom git spawn", ""))
            assert.equals(2, n)
        end)
    end)

    describe("the spawn helper", function()
        it("captures a real spawn when the global is set", function()
            if vim.fn.executable("git") ~= 1 then return end
            local path = tmpfile()
            vim.g.gitloom_git_debug = path
            fetch.fetch_rev_order({ "--max-count=1", "--all" }, "--topo-order")
            vim.g.gitloom_git_debug = nil
            local body = must_read(path)
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
