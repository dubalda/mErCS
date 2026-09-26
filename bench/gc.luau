--!strict
--!nolint DeprecatedApi
--[[
    Garbage collector access for the tests and benchmarks, in the luau CLI and in Roblox.

    - gc.full(): a full collection in the luau CLI. Roblox allows only collectgarbage("count"),
      so there it yields one frame instead (which also keeps long runs under the script
      timeout).
    - gc.kb(): the heap size in KB.

    Usage:
        local gc = require("./gc")
        gc.full()
        local before = gc.kb()
]]

-- one untyped reference: the Roblox type definitions allow only the "count" option
local collect = collectgarbage :: any
-- the Roblox task library, nil in the luau CLI
local roblox_task = task :: any

local function full()
    if roblox_task then
        roblox_task.wait()
    else
        collect("collect")
    end
end

local function kb(): number
    return collect("count")
end

return {
    full = full,
    kb = kb,
}
