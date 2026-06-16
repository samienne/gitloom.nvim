--- Tests for the gitloom public surface — setup and command registration.

describe("gitloom", function()
    it("exposes setup()", function()
        local gitloom = require("gitloom")
        assert.is_function(gitloom.setup)
    end)

    it("registers the GitloomGraph command on load", function()
        require("gitloom")
        local cmds = vim.api.nvim_get_commands({})
        assert.is_not_nil(cmds.GitloomGraph)
    end)

    it("merges options into config", function()
        local gitloom = require("gitloom")
        gitloom.setup({ foo = "bar" })
        assert.equals("bar", gitloom.config.foo)
    end)
end)
