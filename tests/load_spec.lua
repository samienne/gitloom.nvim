-- Canary: the window controller module must load. LuaJIT errors at *compile*
-- time if a function exceeds 60 upvalues, so a refactor that re-introduces
-- upvalue pressure into `open_graph` would make this require() fail outright.
-- Cheap guard that the ctx-extraction keeps the closure under the ceiling.

describe("gitloom.window", function()
    it("loads (open_graph stays under LuaJIT's 60-upvalue ceiling)", function()
        local ok, mod = pcall(require, "gitloom.window")
        assert.is_true(ok, "require failed: " .. tostring(mod))
        assert.is_function(mod.open)
        assert.is_function(mod.pick)
    end)
end)
