-- Minimal init for plenary.busted tests.
-- Sets up runtime path so require("gitloom.*") works.

-- Add the plugin itself to rtp
vim.opt.rtp:prepend(".")

-- Test dependencies (plenary, and the optional snacks / diffview / fidget the
-- specs load) live in ONE directory, `vim.g.gitloom_test_deps`, which every spec
-- reads: $GITLOOM_DEPS when set (CI clones them there), else `.deps/` in the
-- checkout when present, else lazy.nvim's install dir (the local default).
local deps = vim.env.GITLOOM_DEPS
if deps == nil or deps == "" then
    deps = vim.fn.isdirectory(".deps") == 1 and vim.fn.fnamemodify(".deps", ":p:h")
        or (vim.fn.stdpath("data") .. "/lazy")
end
vim.g.gitloom_test_deps = deps

-- Add plenary
local plenary_path = deps .. "/plenary.nvim"
if vim.fn.isdirectory(plenary_path) == 1 then
    vim.opt.rtp:prepend(plenary_path)
end

-- Disable swap files and shada for test runs
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"

-- Never read or write the user's real view-state file (spec §18): point the
-- persistence module at a throwaway file for the whole run.
require("gitloom.persist").set_path(vim.fn.tempname() .. "-gitloom-state.json")
