--!strict
--# selene: allow(empty_loop) -- the loops iterate for their cost only
--!optimize 2
--!native
--[[
    Benchmarker, a query case of bench/query_cases.luau: "usually empty". 100 000 entities,
    each with Stunned or Invulnerable; the query of both never matches. 100 passes per call
    (one pass is too short to measure). jecs: the for-in loop; mErCS: query:each. The worlds
    are built when the module is required.
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

local jecs_query = worlds.empty(worlds.libs.jecs)
local lib_query = worlds.empty(worlds.libs.lib)

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
            for _ = 1, 100 do
                for _ in jecs_query do
                end
            end
        end,

        [worlds.libs.lib_label] = function(_Profiler: any)
            for _ = 1, 100 do
                lib_query:each(visit)
            end
        end,
    },
}
