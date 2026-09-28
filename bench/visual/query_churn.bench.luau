--!strict
--# selene: allow(empty_loop) -- the loops iterate for their cost only
--!optimize 2
--!native
--[[
    Benchmarker, a query case of bench/query_cases.luau: "churn on a queried tag". 70 000
    entities with Position, every 7th with Velocity; the query of both without Stunned.
    Stunned is toggled on 1 or 100 random movers, then the query makes one pass. jecs: the
    for-in loop; mErCS: query:each. The worlds are built when the module is required.
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

local jecs_query, jecs_toggle = worlds.churn(worlds.libs.jecs)
local lib_query, lib_toggle = worlds.churn(worlds.libs.lib)

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
        [`{worlds.libs.jecs_label} toggle 1`] = function(_Profiler: any)
            jecs_toggle()
            for _ in jecs_query do
            end
        end,

        [`{worlds.libs.lib_label} toggle 1`] = function(_Profiler: any)
            lib_toggle()
            lib_query:each(visit)
        end,

        [`{worlds.libs.jecs_label} toggle 100`] = function(_Profiler: any)
            for _ = 1, 100 do
                jecs_toggle()
            end
            for _ in jecs_query do
            end
        end,

        [`{worlds.libs.lib_label} toggle 100`] = function(_Profiler: any)
            for _ = 1, 100 do
                lib_toggle()
            end
            lib_query:each(visit)
        end,
    },
}
