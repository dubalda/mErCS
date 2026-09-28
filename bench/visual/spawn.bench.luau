--!strict
--!optimize 2
--!native
--[[
    Benchmarker: spawn 1000 entities with 4 components each, in a fresh world per run.
]]

-- Benchmarker requires a clone of this module, which has no parent: relative requires cannot
-- work here, so the helpers are reached from ReplicatedStorage
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local libs = require(
    ReplicatedStorage:WaitForChild("mErCSCheck"):WaitForChild("bench"):WaitForChild("visual"):WaitForChild("libs")
) :: any

local N = 1000

type Setup = { world: any, a: any, b: any, c: any, d: any }

local function setup(ecs: any): Setup
    local world = ecs.world()
    return { world = world, a = world:component(), b = world:component(), c = world:component(), d = world:component() }
end

local function spawn(s: Setup)
    local world, a, b, c, d = s.world, s.a, s.b, s.c, s.d
    for i = 1, N do
        local e = world:entity()
        world:set(e, a, i)
        world:set(e, b, i)
        world:set(e, c, i)
        world:set(e, d, i)
    end
end

return {
    ParameterGenerator = function()
        return setup(libs.jecs), setup(libs.lib)
    end,

    BeforeAll = function() end,
    AfterAll = function() end,
    BeforeEach = function() end,
    AfterEach = function() end,

    Functions = {
        [libs.jecs_label] = function(_Profiler: any, jecs_setup: Setup, _lib_setup: Setup)
            spawn(jecs_setup)
        end,

        [libs.lib_label] = function(_Profiler: any, _jecs_setup: Setup, lib_setup: Setup)
            spawn(lib_setup)
        end,
    },
}
