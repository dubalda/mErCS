--!strict
--!optimize 2
--!native
--[[
    Benchmarker: one change to every match of a query. Half of 2000 entities are Marked; the
    Stunned tag is added to the marked ones and removed again. jecs has no batch operations:
    the matches are collected first (changing archetypes during the loop is unsafe), then
    changed one by one. mErCS uses query:add_all / query:remove_all.
]]

-- Benchmarker requires a clone of this module, which has no parent: relative requires cannot
-- work here, so the helpers are reached from ReplicatedStorage
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local libs = require(
    ReplicatedStorage:WaitForChild("mErCSCheck"):WaitForChild("bench"):WaitForChild("visual"):WaitForChild("libs")
) :: any

local N = 2000

type Setup = { world: any, position: any, marked: any, stunned: any }

local function setup(ecs: any): Setup
    local world = ecs.world()
    local position = world:component()
    local marked, stunned = world:entity(), world:entity()
    for i = 1, N do
        local e = world:entity()
        world:set(e, position, i)
        if i % 2 == 0 then
            world:add(e, marked)
        end
    end
    return { world = world, position = position, marked = marked, stunned = stunned }
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
        ["Jecs"] = function(_Profiler: any, s: Setup, _lib_setup: Setup)
            local world = s.world
            local matches = {}
            for e in world:query(s.position):with(s.marked) do
                table.insert(matches, e)
            end
            for _, e in matches do
                world:add(e, s.stunned)
            end
            table.clear(matches)
            for e in world:query(s.stunned) do
                table.insert(matches, e)
            end
            for _, e in matches do
                world:remove(e, s.stunned)
            end
        end,

        ["mErCS"] = function(_Profiler: any, _jecs_setup: Setup, s: Setup)
            local world = s.world
            world:query(s.position):with(s.marked):add_all(s.stunned)
            world:query(s.stunned):remove_all(s.stunned)
        end,
    },
}
