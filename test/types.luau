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

-- introspection and helpers: they take any id, also straight from a call
local _ids: { ecs.Id } = world:ids(e)
local _slot: number = ecs.ECS_ID(e)
local _generation: number = ecs.ECS_GENERATION(e)
local _fresh_slot: number = ecs.ECS_ID(world:entity())
local _fresh_generation: number = ecs.ECS_GENERATION(world:pool():entity())
local _component_slot: number = ecs.ECS_ID(Health)
local _first: number = ecs.ECS_PAIR_FIRST(ecs.pair(ecs.ChildOf, world:entity()))
local _second: number = ecs.ECS_PAIR_SECOND(ecs.pair(ecs.ChildOf, world:entity()))

-- slot pools: their entities are ordinary entities
local npcs: ecs.Pool = world:pool()
local npc = npcs:entity()
world:set(npc, Health, 10)
local _npc_slot: number = ecs.ECS_ID(npc)
local _npc_health: number? = world:get(npc, Health)
world:delete(npc)

-- query monitors: callbacks with the entity, set and cleared with a dot
local entered = 0
local monitor: ecs.Monitor = world:query(Position):with(Health):monitor()
monitor.added(function(entity: ecs.Entity)
    local _position: Vec? = world:get(entity, Position)
    entered += 1
end)
monitor.removed(nil)
local walker = world:entity()
world:set(walker, Position, { x = 0, y = 0 })
world:set(walker, Health, 5)
assert(entered == 1, "entered once")
monitor.disconnect()

-- optional and union component types: nil only where the type allows it
local Maybe = world:component() :: ecs.Component<number?>
local Either = world:component() :: ecs.Component<number | string>
world:set(e, Maybe, nil)
world:set(e, Maybe, 1)
world:set(e, Either, 1)
world:set(e, Either, "one")
local _maybe: number? = world:get(e, Maybe)
local _either: (number | string)? = world:get(e, Either)

-- a typed wrapper keeps the type of the id it is given
local function put<T>(id: ecs.Component<T>, value: T)
    world:set(e, id, value)
end
put(Health, 5)
put(Name, "wrapped")

-- a pair whose relation is a tag carries the type of its target
local Likes = world:entity()
world:set(e, ecs.pair(Likes, Health), 3)
local _liked: number? = world:get(e, ecs.pair(Likes, Health))

-- mixed lists of ids for reading and filtering
local mixed: { ecs.Id } = { Position, Frozen, ecs.pair(ecs.ChildOf, parent) }
local _all: boolean = world:has_all(e, mixed)
local _values: { any } = world:get_list(e, mixed)
for _entity, _p in world:query(Position):with(Frozen, ecs.pair(ecs.ChildOf, parent)):without(Velocity) do
end

-- toggles and creation tracking
local _added: boolean = world:toggle(e, Frozen)
world:query(Position):toggle_all(Frozen)
world:track_created()
for _entity, _p in world:query(Position):created() do
end

world:delete(e)
assert(not world:contains(e), "deleted")
print("types: ok")
