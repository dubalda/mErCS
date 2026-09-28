--!strict
--[[
    The previous release of the library, for the benchmarks that compare it with jecs and the
    current library: tools/previous.sh extracts it from its git tag into tmp/previous (ignored
    by git). Returns nil when it is not there.

    The require goes through a variable, so the type checker does not read the old source.

    Usage:
        local previous = require("./previous")
        if previous then
            print(previous.version, previous.ecs.world())
        end
]]

export type Previous = { version: string, ecs: any }

local path = "../tmp/previous"
local found, previous = pcall(function(): any
    return (require :: any)(path)
end)

return (if found then previous else nil) :: Previous?
