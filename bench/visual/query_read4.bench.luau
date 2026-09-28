--!strict
--!optimize 2
--!native
--[[
    Benchmarker, a query case of bench/query_cases.luau: "read 4 components". One pass of a
    4-component query over 80 000 entities (half of them have the fourth component), adding up
    the four values. jecs: the for-in loop; mErCS: query:each. The worlds are built when the
    module is required.
]]

-- Benchmarker requires a clone of this module, which has no parent: relative requires cannot
-- work here, so the helpers are reached from ReplicatedStorage
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local worlds = require(
    ReplicatedStorage:WaitForChild("mErCSCheck")
        :WaitForChild("bench")
        :WaitForChild("visual")
        :WaitForChild("query_worlds")
) :: any

local jecs_query = worlds.read4(worlds.libs.jecs)
local lib_query = worlds.read4(worlds.libs.lib)

local acc = 0
local function read(_: any, a: number, b: number, c: number, d: number)
    acc += a + b + c + d
end

return {
    ParameterGenerator = function()
        return
    end,

    BeforeAll = function() end,
    AfterAll = function() end,
    BeforeEach = function() end,
    AfterEach = function() end,

    Functions = {
        [worlds.libs.jecs_label] = function(_Profiler: any)
            local sum = 0
            for _, a, b, c, d in jecs_query do
                sum += a + b + c + d
            end
        end,

        [worlds.libs.lib_label] = function(_Profiler: any)
            acc = 0
            lib_query:each(read)
        end,
    },
}
