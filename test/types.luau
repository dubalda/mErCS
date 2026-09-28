--!strict
--# selene: allow(empty_loop) -- the loops exist for their types only
--[[
    Type-level test of the public API: this file must type-check without errors
    (luau-lsp analyze, new solver) and run without errors.

    Run from the repository root:
        luau test/types.luau
        bash tools/check.sh
]]

local ecs = require("@lib")

type Vec = { x: number, y: number }

local world = ecs.world()

-- components carry their data type; tags and plain entities carry none
local Position = world:component() :: ecs.Component<Vec>
local Velocity = world:component() :: ecs.Component<Vec>
local Name = ecs.Name
local Health = world:component() :: ecs.Component<number>
local Untyped = world:component()
local Frozen = world:entity()

local e = world:entity()
world:set(e, Position, { x = 0, y = 0 })
world:set(e, Velocity, { x = 1, y = 0 })
world:set(e, Health, 100)
world:set(e, Name, "player")
world:set(e, Untyped, true)
world:add(e, Frozen)

-- get returns the data types
local position: Vec? = world:get(e, Position)
local health, name = world:get(e, Health, Name)
local _h: number?, _n: string? = health, name
local _has: boolean = world:has(e, Position, Velocity)
local _many: { any } = world:get_list(e, { Position, Velocity, Health })
assert(position and position.x == 0, "typed get")

-- queries: for-in and each give typed values
for entity, p, v in world:query(Position, Velocity) do
    local _p: Vec = p
    local _v: Vec = v
    world:set(entity, Position, { x = p.x + v.x, y = p.y + v.y })
end
world:query(Position, Velocity):without(Frozen):each(function(_entity, p, v)
    local _sum: number = p.x + v.x
end)
for _entity, _value in world:query(Untyped) do
end
local cached = world:query(Health):cached()
for _entity, hp in cached do
    local _hp: number = hp
end

-- relationships: a pair of a component relation carries its data type
local Owns = world:component() :: ecs.Component<number>
local item = world:entity()
world:set(e, ecs.pair(Owns, item), 5)
local _count: number? = world:get(e, ecs.pair(Owns, item))
local parent = world:entity()
world:add(e, ecs.pair(ecs.ChildOf, parent))
local _parent: ecs.Entity? = world:parent(e)
local _target: ecs.Entity? = world:target(e, ecs.ChildOf)
for _child in world:children(parent) do
end

-- hooks and signals
world:set(Health, ecs.OnChange, function(_entity, _id, _value) end)
local disconnect = world:removed(Position, function(_entity, _id, _deleted) end)
disconnect()

-- change tracking and Disabled
world:track(Health)
world:tick()
for _entity, _hp in world:query(Health):changed(Health) do
end
world:add(e, ecs.Disabled)
for _entity in world:query(Health):with(ecs.Disabled) do
end
for _entity, _hp in world:query(Health):any(Frozen, ecs.Disabled) do
end

-- batch operations: set_all takes the data type of the id
local _matches: number = world:query(Health):count()
world:query(Health):without(Frozen):set_all(Health, 50)
world:query(Position):add_all(Frozen)
world:query(Frozen):remove_all(Frozen)

-- introspection and helpers
local _ids: { ecs.Id } = world:ids(e)
local _slot: number = ecs.ECS_ID(e)
local _generation: number = ecs.ECS_GENERATION(e)

-- slot pools: their entities are ordinary entities
local npcs: ecs.Pool = world:pool()
local npc = npcs:entity()
world:set(npc, Health, 10)
local _npc_slot: number = ecs.ECS_ID(npc)
local _npc_health: number? = world:get(npc, Health)
world:delete(npc)

world:delete(e)
assert(not world:contains(e), "deleted")
print("types: ok")
