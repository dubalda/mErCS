--!strict
--[[
    Tests of the jabby adapter (src/jabby.luau): what jabby 0.5 reads from its jecs module and
    from a world, on mErCS worlds.

    Run from the repository root:
        luau test/jabby.luau
]]

local testkit = require("@testkit")
local ecs = require("@lib")
local adapter = require("@lib/jabby")

local it = testkit.test()
local TEST, CASE, CHECK, FINISH = it.TEST, it.CASE, it.CHECK, it.FINISH

local jecs = adapter(ecs)
local pair = ecs.pair

TEST("the jecs-like module", function()
    CASE("exports the library and the adapter functions")
    CHECK(jecs.pair == ecs.pair and jecs.Name == ecs.Name and jecs.world == ecs.world)
    CHECK(type(jecs.is_tag) == "function" and type(jecs.entity_index_try_get) == "function")

    CASE("the library itself stays without them")
    local lib: any = ecs
    CHECK(lib.is_tag == nil and lib.entity_index_try_get == nil and lib.attach == nil)
end)

TEST("attach", function()
    local world: any = ecs.world()
    local other: any = ecs.world()

    CASE("gives entity_index, iter and archetypes to the attached world only")
    CHECK(jecs.attach(world) == world)
    CHECK(world.entity_index ~= nil and world:query().iter ~= nil and world:query().archetypes ~= nil)
    CHECK(other.entity_index == nil and other:query().iter == nil and other:query().archetypes == nil)

    CASE("attaching again changes nothing")
    local index = world.entity_index
    jecs.attach(world)
    CHECK(world.entity_index == index)
end)

TEST("what jabby reads", function()
    local world = jecs.attach(ecs.world())
    local A = world:component()
    local T = world:entity()
    local R = world:entity()
    local p = world:entity()
    local e = world:entity()
    world:set(e, A, 1)
    world:add(e, T)
    world:add(e, pair(R, p))
    world:set(e, ecs.Name, "e")

    CASE("entity_index_try_get: the ids of an entity as archetype types")
    local record = jecs.entity_index_try_get(world.entity_index, e)
    CHECK(record ~= nil and #record.archetype.types == 4)
    local dead = world:entity()
    world:delete(dead)
    CHECK(jecs.entity_index_try_get(world.entity_index, dead) == nil)

    CASE("is_tag")
    CHECK(not jecs.is_tag(world, A) and jecs.is_tag(world, T))
    CHECK(jecs.is_tag(world, pair(R, p)) and not jecs.is_tag(world, pair(A, p)))

    CASE("query:iter: a stateful iterator")
    local names = {}
    for id, name in world:query(jecs.Name):iter() do
        names[name] = id
    end
    CHECK(names.e == e and names["mercs.ChildOf"] == ecs.ChildOf)
    local step = world:query(A):iter()
    local first, value = step()
    CHECK(first == e and value == 1 and step() == nil)

    CASE("query:archetypes: one pseudo archetype with the matches, as jabby builds a table")
    local query = world:query(A):with(T)
    local rows = {}
    for _, archetype in query:archetypes() do
        for _, entity in archetype.entities do
            local cell = world:get(entity, A)
            table.insert(rows, cell)
        end
    end
    CHECK(#rows == 1 and rows[1] == 1)
    CHECK(#world:query(A):without(T):archetypes() == 0)
end)

-- a failed case must fail the process (CI reads the exit code)
assert(FINISH() == 0, "some test cases failed")
