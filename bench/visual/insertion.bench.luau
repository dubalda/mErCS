--!strict
--!optimize 2
--!native
--[[
    Benchmarker: insert 8 components into 500 existing entities that have none (the first
    set of each component), in a fresh world per run.
]]

-- Benchmarker requires a clone of this module, which has no parent: relative requires cannot
-- work here, so the helpers are reached from ReplicatedStorage
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local libs = require(
    ReplicatedStorage:WaitForChild("mErCSCheck"):WaitForChild("bench"):WaitForChild("visual"):WaitForChild("libs")
) :: any

local N = 500

type Setup = { world: any, components: { any }, entities: { any } }

local function setup(ecs: any): Setup
    local world = ecs.world()
    local components = table.create(8)
    for i = 1, 8 do
        components[i] = world:component()
    end
    local entities = table.create(N)
    for i = 1, N do
        entities[i] = world:entity()
    end
    return { world = world, components = components, entities = entities }
end

local function insert(s: Setup)
    local world, entities = s.world, s.entities
    local c1, c2, c3, c4, c5, c6, c7, c8 = table.unpack(s.components, 1, 8)
    for _, e in entities do
        world:set(e, c1, true)
        world:set(e, c2, true)
        world:set(e, c3, true)
        world:set(e, c4, true)
        world:set(e, c5, true)
        world:set(e, c6, true)
        world:set(e, c7, true)
        world:set(e, c8, true)
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
        ["Jecs"] = function(_Profiler: any, jecs_setup: Setup, _lib_setup: Setup)
            insert(jecs_setup)
        end,

        ["mErCS"] = function(_Profiler: any, _jecs_setup: Setup, lib_setup: Setup)
            insert(lib_setup)
        end,
    },
}
