--!strict
--[[
    A tour of mErCS: components, tags, queries, relationships, hooks, change tracking
    and disabled entities. Runs with the standalone luau CLI from the repository root:

        luau examples/basics.luau

    In Roblox, replace the require with the path of the module (for example
    ReplicatedStorage.mErCS) and Vec with Vector3.
]]

local ecs = require("@lib")

type Vec = { x: number, y: number }

local world = ecs.world()

-- Components hold data; the cast gives the data type to get/set/queries.
local Position = world:component() :: ecs.Component<Vec>
local Velocity = world:component() :: ecs.Component<Vec>
local Health = world:component() :: ecs.Component<number>
world:set(Position, ecs.Name, "Position")

-- Any entity can be used as a tag.
local Frozen = world:entity()
local Hit = world:entity()

-- Spawn a few movers.
local movers = {}
for i = 1, 5 do
    local e = world:entity()
    world:set(e, Position, { x = 0, y = i })
    world:set(e, Velocity, { x = 1, y = 0 })
    world:set(e, Health, 100)
    table.insert(movers, e)
end

-- A system: a query written inline is cheap (its state is shared by shape).
local function move()
    world:query(Position, Velocity):without(Frozen):each(function(entity, position, velocity)
        world:set(entity, Position, { x = position.x + velocity.x, y = position.y + velocity.y })
    end)
end

-- Tags for states: adding and removing them costs O(1) and creates nothing.
local first = movers[1]
world:add(first, Frozen)
move()
move()
for entity, position in world:query(Position) do
    print(`entity {ecs.ECS_ID(entity)} at x = {position.x}{if world:has(entity, Frozen) then " (frozen)" else ""}`)
end

-- Relationships: a hierarchy with cascading delete.
local ship = world:entity()
local turret = world:entity()
local barrel = world:entity()
world:add(turret, ecs.pair(ecs.ChildOf, ship))
world:add(barrel, ecs.pair(ecs.ChildOf, turret))
print("turret parent is the ship:", world:parent(turret) == ship)
world:delete(ship)
print("barrel deleted with the ship:", not world:contains(barrel))

-- Hooks run when data is added, changed or removed.
world:set(Health, ecs.OnRemove, function(entity: any)
    print(`entity {ecs.ECS_ID(entity)} lost its health`)
end)

-- Change tracking: a system sees what changed since its previous run.
world:track(Health)
local damaged = world:query(Health):changed(Health):cached()
for entity in world:query(Health) do
    if ecs.ECS_ID(entity) % 2 == 0 then
        world:set(entity, Health, 50)
    end
end
world:tick() -- once per frame: the changes of this frame become visible
local count = 0
for _entity, health in damaged do
    count += 1
    assert(health == 50, "a damaged entity has 50 health")
end
print(`damaged this frame: {count}`)

-- Batch operations change every match of a query at once, 32 entities at a time.
world:query(Health):add_all(Hit)
print("hit:", world:query(Hit):count())
world:remove_all(Hit) -- a one-frame tag: clear it everywhere
print("hit tags left:", world:query(Hit):count())

-- Disabled entities are skipped by queries that do not ask for them.
world:add(first, ecs.Disabled)
local visible = 0
for _ in world:query(Position) do
    visible += 1
end
print(`visible movers: {visible} of 5`)

-- Introspection.
print("ids of the first mover:", #world:ids(first))
world:delete(first)
