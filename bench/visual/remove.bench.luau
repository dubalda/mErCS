--!strict
--!optimize 2
--!native
--[[
    Benchmarker: remove one of 5 components from 1000 entities (in jecs every remove moves the
    entity to another archetype).
]]

-- Benchmarker requires a clone of this module, which has no parent: relative requires cannot
-- work here, so the helpers are reached from ReplicatedStorage
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local libs = require(
    ReplicatedStorage:WaitForChild("mErCSCheck"):WaitForChild("bench"):WaitForChild("visual"):WaitForChild("libs")
) :: any

local N = 1000

type Setup = { world: any, removed: any, entities: { any } }

local function setup(ecs: any): Setup
    local world = ecs.world()
    local components = table.create(5)
    for i = 1, 5 do
        components[i] = world:component()
    end
    local entities = table.create(N)
    for i = 1, N do
        local e = world:entity()
        for _, component in components do
            world:set(e, component, i)
        end
        entities[i] = e
    end
    return { world = world, removed = components[3], entities = entities }
end

local function remove(s: Setup)
    local world, removed = s.world, s.removed
    for _, e in s.entities do
        world:remove(e, removed)
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
            remove(jecs_setup)
        end,

        [libs.lib_label] = function(_Profiler: any, _jecs_setup: Setup, lib_setup: Setup)
            remove(lib_setup)
        end,
    },
}
