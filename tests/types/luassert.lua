---@meta
--- Minimal luassert (busted `assert`) type stub so lua-language-server doesn't
--- flag the matcher methods as undefined fields. Used only by the language
--- server (it is a `---@meta` file and is never require()d at runtime).

---@class luassert
---@overload fun(value: any, message?: string): any   -- plain assert(value[, msg])
---@field equals fun(expected: any, actual: any, message?: string)
---@field equal fun(expected: any, actual: any, message?: string)
---@field same fun(expected: any, actual: any, message?: string)
---@field is_true fun(value: any, message?: string)
---@field is_false fun(value: any, message?: string)
---@field is_nil fun(value: any, message?: string)
---@field is_not_nil fun(value: any, message?: string)
---@field is_function fun(value: any, message?: string)
---@field truthy fun(value: any, message?: string)
---@field falsy fun(value: any, message?: string)
---@field has_error fun(fn: function, message?: string)
---@field near fun(expected: number, actual: number, tolerance: number, message?: string)
---@field not_equal fun(expected: any, actual: any, message?: string)
---@field matches fun(pattern: string, actual: any, message?: string)

---@type luassert
---@diagnostic disable-next-line: assign-type-mismatch
assert = assert
