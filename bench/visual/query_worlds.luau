--!strict
--!optimize 2
--!native
--[[
    The worlds of the query cases (bench/query_cases.luau), for the Benchmarker files
    query_*.bench.luau: the same code builds a jecs world and a mErCS world. The bench files
    run the loops of the cases: the for-in loop for jecs, query:each for mErCS (the loops never
    break early, so each replaces them fully).

    The bench files reach this module from ReplicatedStorage (a cloned *.bench module has no
    parent):
        local worlds = require(ReplicatedStorage:WaitForChild("mErCSCheck"):WaitForChild("bench")
            :WaitForChild("visual"):WaitForChild("query_worlds")) :: any
        local query = worlds.scattered(worlds.libs.jecs)
]]

local libs = require("./libs")

local function flip(): boolean
    return math.random() >= 0.5
end

-- 50 000 entities with random subsets of 8 components, then 100 000 deletes and respawns:
-- the query of 4 of them.
local function scattered(ecs: any): any
    local world = ecs.world()
    local components = {}
    for i = 1, 8 do
        components[i] = world:component()
    end
    math.randomseed(42)
    local function spawn(): any
        local entity = world:entity()
        for i, component in components do
            if flip() then
                world:set(entity, component, i)
            end
        end
        return entity
    end
    local entities = {}
    for i = 1, 50000 do
        entities[i] = spawn()
    end
    for _ = 1, 100000 do
        local i = math.random(#entities)
        world:delete(entities[i])
        entities[i] = spawn()
    end
    return world:query(components[1], components[2], components[3], components[4]):cached()
end

-- 70 000 entities with Position, every 7th with Velocity: the query of both without Stunned,
-- and a function that toggles Stunned on a random mover.
local function churn(ecs: any): (any, () -> ())
    local world = ecs.world()
    local Position, Velocity = world:component(), world:component()
    local Stunned = world:entity()
    math.randomseed(42)
    local movers = {}
    for i = 1, 70000 do
        local entity = world:entity()
        world:set(entity, Position, i)
        if i % 7 == 0 then
            world:set(entity, Velocity, 1)
            table.insert(movers, entity)
        end
    end
    local function toggle()
        local entity = movers[math.random(#movers)]
        if world:has(entity, Stunned) then
            world:remove(entity, Stunned)
        else
            world:add(entity, Stunned)
        end
    end
    return world:query(Position, Velocity):without(Stunned):cached(), toggle
end

-- 80 000 entities with A, B, C, half of them with D (and half with a tag): the query of four.
local function read4(ecs: any): any
    local world = ecs.world()
    local A, B, C, D = world:component(), world:component(), world:component(), world:component()
    local Tag = world:entity()
    math.randomseed(42)
    for i = 1, 80000 do
        local entity = world:entity()
        world:set(entity, A, i)
        world:set(entity, B, i)
        world:set(entity, C, i)
        if flip() then
            world:set(entity, D, i)
        end
        if flip() then
            world:add(entity, Tag)
        end
    end
    return world:query(A, B, C, D):cached()
end

-- 20 000 entities with Health and one of 64 pairs (R, Target): the query of Health and
-- (*, Target), and a function that toggles a random pair on a random entity.
local function wildcard(ecs: any): (any, () -> ())
    local world = ecs.world()
    local Health = world:component()
    local Target = world:entity()
    math.randomseed(42)
    local relations = {}
    for i = 1, 64 do
        relations[i] = ecs.pair(world:entity(), Target)
    end
    local entities = {}
    for i = 1, 20000 do
        local entity = world:entity()
        world:set(entity, Health, 100)
        world:add(entity, relations[i % 64 + 1])
        entities[i] = entity
    end
    local function toggle()
        local entity = entities[math.random(#entities)]
        local relation = relations[math.random(#relations)]
        if world:has(entity, relation) then
            world:remove(entity, relation)
        else
            world:add(entity, relation)
        end
    end
    return world:query(Health, ecs.pair(ecs.Wildcard, Target)):cached(), toggle
end

-- 100 000 entities, each with Stunned or Invulnerable: the query of both, which never matches.
local function empty(ecs: any): any
    local world = ecs.world()
    local Stunned, Invulnerable = world:component(), world:component()
    math.randomseed(42)
    for _ = 1, 100000 do
        local entity = world:entity()
        if flip() then
            world:set(entity, Stunned, true)
        else
            world:set(entity, Invulnerable, true)
        end
    end
    return world:query(Stunned, Invulnerable):cached()
end

return {
    libs = libs,
    scattered = scattered,
    churn = churn,
    read4 = read4,
    wildcard = wildcard,
    empty = empty,
}
