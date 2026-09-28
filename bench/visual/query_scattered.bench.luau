--!strict
--# selene: allow(empty_loop) -- the loops iterate for their cost only
--!optimize 2
--!native
--[[
    Benchmarker, a query case of bench/query_cases.luau: "scattered after recycling". One pass
    of a 4-component query over 50 000 entities with random subsets of 8 components, after
    100 000 deletes and respawns scattered their ids. jecs: the for-in loop; mErCS:
    query:each. The worlds are built when the module is required.
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

local jecs_query = worlds.scattered(worlds.libs.jecs)
local lib_query = worlds.scattered(worlds.libs.lib)

local function visit() end

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
            for _ in jecs_query do
            end
        end,

        [worlds.libs.lib_label] = function(_Profiler: any)
            lib_query:each(visit)
        end,
    },
}
