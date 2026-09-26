--!strict
--!optimize 2
--!native
--[[
    Benchmarker: delete 1000 entities with 4 components and a tag each.
]]

-- Benchmarker requires a clone of this module, which has no parent: relative requires cannot
-- work here, so the helpers are reached from ReplicatedStorage
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local libs = require(
    ReplicatedStorage:WaitForChild("mErCSCheck"):WaitForChild("bench"):WaitForChild("visual"):WaitForChild("libs")
) :: any

local N = 1000

type Setup = { world: any, entities: { any } }

local function setup(ecs: any): Setup
    local world = ecs.world()
    local a, b, c, d = world:component(), world:component(), world:component(), world:component()
    local tag = world:entity()
    local entities = table.create(N)
    for i = 1, N do
        local e = world:entity()
        world:set(e, a, i)
        world:set(e, b, i)
        world:set(e, c, i)
        world:set(e, d, i)
        world:add(e, tag)
        entities[i] = e
    end
    return { world = world, entities = entities }
end

local function despawn(s: Setup)
    local world = s.world
    for _, e in s.entities do
        world:delete(e)
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
            despawn(jecs_setup)
        end,

        ["mErCS"] = function(_Profiler: any, _jecs_setup: Setup, lib_setup: Setup)
            despawn(lib_setup)
        end,
    },
}
