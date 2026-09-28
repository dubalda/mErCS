--!strict
--# selene: allow(empty_loop) -- the loops iterate for their cost only
--!optimize 2
--!native
--[[
    Benchmarker, a query case of bench/query_cases.luau: "wildcard target with churn". 20 000
    entities with Health and one of 64 pairs (R, Target); one random pair is toggled on a
    random entity, then the query of Health and (*, Target) makes one pass. jecs: the for-in
    loop; mErCS: query:each. The worlds are built when the module is required.
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

local jecs_query, jecs_toggle = worlds.wildcard(worlds.libs.jecs)
local lib_query, lib_toggle = worlds.wildcard(worlds.libs.lib)

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
            jecs_toggle()
            for _ in jecs_query do
            end
        end,

        [worlds.libs.lib_label] = function(_Profiler: any)
            lib_toggle()
            lib_query:each(visit)
        end,
    },
}
