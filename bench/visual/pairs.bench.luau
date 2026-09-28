--!strict
--!optimize 2
--!native
--[[
    Benchmarker: relationships. 100 parents get 10 ChildOf children each, every child also
    targets one of the parents through a plain relation (Likes), then the parents are deleted
    (ChildOf deletes the children with them).
]]

-- Benchmarker requires a clone of this module, which has no parent: relative requires cannot
-- work here, so the helpers are reached from ReplicatedStorage
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local libs = require(
    ReplicatedStorage:WaitForChild("mErCSCheck"):WaitForChild("bench"):WaitForChild("visual"):WaitForChild("libs")
) :: any

local PARENTS = 100
local CHILDREN = 10

type Setup = { ecs: any, world: any, likes: any }

local function setup(ecs: any): Setup
    local world = ecs.world()
    return { ecs = ecs, world = world, likes = world:entity() }
end

local function hierarchy(s: Setup)
    local world, likes = s.world, s.likes
    local pair, ChildOf = s.ecs.pair, s.ecs.ChildOf
    local parents = table.create(PARENTS)
    for p = 1, PARENTS do
        parents[p] = world:entity()
    end
    for p, parent in parents do
        for c = 1, CHILDREN do
            local child = world:entity()
            world:add(child, pair(ChildOf, parent))
            world:add(child, pair(likes, parents[(p + c) % PARENTS + 1]))
        end
    end
    for _, parent in parents do
        world:delete(parent)
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
            hierarchy(jecs_setup)
        end,

        [libs.lib_label] = function(_Profiler: any, _jecs_setup: Setup, lib_setup: Setup)
            hierarchy(lib_setup)
        end,
    },
}
