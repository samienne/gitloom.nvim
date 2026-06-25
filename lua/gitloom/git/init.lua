--- gitloom.git — the git data library.
---
--- The model + parsers + formatters + ordering that turn a repository into the
--- immutable commit DAG the graph engine renders, plus the I/O to fetch it.
--- Pure where it can be (everything here except the fetch/runner layer), and
--- deliberately free of any Neovim window/buffer coupling.
---
--- This module is the public aggregator: it re-exports each submodule's surface
--- under one table. graph.lua aliases from here during the library split.

local M = {}

local function reexport(mod)
    for k, v in pairs(mod) do
        M[k] = v
    end
end

reexport(require("gitloom.git.model"))
reexport(require("gitloom.git.order"))
reexport(require("gitloom.git.date"))
reexport(require("gitloom.git.parse"))
reexport(require("gitloom.git.refs"))
reexport(require("gitloom.git.range"))
reexport(require("gitloom.git.format"))
-- The I/O layer (jobstart-backed) — the only Neovim-coupled part of the library.
reexport(require("gitloom.git.fetch"))

return M
