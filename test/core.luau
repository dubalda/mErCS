--!strict
--[[
	Core behaviour tests run against jecs and this library.

	The suite encodes jecs semantics for the core subset: entities, components, tags,
	get/has/remove/delete/clear, recycling with generations, hooks, queries with/without.
	Run from the repository root:
		luau test/core.luau
]]

local testkit = require("@testkit")
local jecs = require("@jecs")
local lib = require("@lib")

local it = testkit.test()
local TEST, CASE, CHECK, FINISH = it.TEST, it.CASE, it.CHECK, it.FINISH

local ENTITY_MASK = 2 ^ 24

type Impl = { name: string, ecs: any, many_ids: boolean }

local impls: { Impl } = {
    { name = "jecs", ecs = jecs, many_ids = false },
    { name = "lib", ecs = lib, many_ids = true },
}

for _, impl in impls do
    local ecs = impl.ecs
    local prefix = `[{impl.name}] `

    TEST(prefix .. "entity ids", function()
        local world = ecs.world()
        CASE("first entity follows builtin ids")
        CHECK(world:entity() == ecs.Rest + 1)
        CASE("components start at 1")
        CHECK(world:component() == 1)
        CHECK(world:component() == 2)
        CASE("recycled id gets the next generation")
        local e = world:entity()
        world:delete(e)
        CHECK(not world:contains(e))
        local recycled = world:entity()
        CHECK(recycled % ENTITY_MASK == e % ENTITY_MASK)
        CHECK(recycled == e + ENTITY_MASK)
        CHECK(world:contains(recycled))
        CHECK(world:exists(e))
    end)

    TEST(prefix .. "set/get/has/remove", function()
        local world = ecs.world()
        local A, B = world:component(), world:component()
        local e = world:entity()
        CASE("set new")
        world:set(e, A, 10)
        CHECK(world:get(e, A) == 10)
        CHECK(world:has(e, A))
        CHECK(not world:has(e, B))
        CHECK(world:get(e, B) == nil)
        CASE("set existing")
        world:set(e, A, 11)
        CHECK(world:get(e, A) == 11)
        CASE("get several")
        world:set(e, B, 20)
        local a, b = world:get(e, A, B)
        CHECK(a == 11 and b == 20)
        CHECK(world:has(e, A, B))
        CASE("remove")
        world:remove(e, A)
        CHECK(not world:has(e, A))
        CHECK(world:get(e, A) == nil)
        CHECK(world:get(e, B) == 20)
        CASE("remove missing is a no-op")
        world:remove(e, A)
        CHECK(world:get(e, B) == 20)
        CASE("dead entity")
        world:delete(e)
        CHECK(world:get(e, B) == nil)
        CHECK(not world:has(e, B))
        world:set(e, B, 1)
        CHECK(world:get(e, B) == nil)
    end)

    TEST(prefix .. "tags", function()
        local world = ecs.world()
        local A = world:component()
        local T = world:entity()
        local e = world:entity()
        CASE("add tag")
        world:set(e, A, 1)
        world:add(e, T)
        CHECK(world:has(e, T))
        CHECK(world:get(e, T) == nil)
        CHECK(world:has(e, A, T))
        CASE("add twice is idempotent")
        world:add(e, T)
        CHECK(world:has(e, T))
        CASE("remove tag")
        world:remove(e, T)
        CHECK(not world:has(e, T))
        CHECK(world:get(e, A) == 1)
        CASE("add component without value")
        local e2 = world:entity()
        world:add(e2, A)
        CHECK(world:has(e2, A))
        CHECK(world:get(e2, A) == nil)
        world:set(e2, A, 5)
        CHECK(world:get(e2, A) == 5)
    end)

    TEST(prefix .. "delete and clear", function()
        local world = ecs.world()
        local A, B = world:component(), world:component()
        local T = world:entity()
        local e = world:entity()
        world:set(e, A, 1)
        world:set(e, B, 2)
        world:add(e, T)
        CASE("clear keeps the entity")
        world:clear(e)
        CHECK(world:contains(e))
        CHECK(not world:has(e, A))
        CHECK(not world:has(e, B))
        CHECK(not world:has(e, T))
        CASE("delete")
        world:set(e, A, 1)
        world:delete(e)
        CHECK(not world:contains(e))
        CASE("recycled slot starts empty")
        local r = world:entity()
        CHECK(r % ENTITY_MASK == e % ENTITY_MASK)
        CHECK(not world:has(r, A))
        CHECK(world:get(r, A) == nil)
        local count = 0
        for _ in world:query(A) do
            count += 1
        end
        CHECK(count == 0)
    end)

    TEST(prefix .. "hooks", function()
        local world = ecs.world()
        local A = world:component()
        local log: { string } = {}
        world:set(A, ecs.OnAdd, function(_entity: any, _id: any, value: any)
            table.insert(log, `add {value}`)
        end)
        world:set(A, ecs.OnChange, function(_entity: any, _id: any, value: any)
            table.insert(log, `change {value}`)
        end)
        world:set(A, ecs.OnRemove, function(_entity: any, _id: any)
            table.insert(log, "remove")
        end)
        local e = world:entity()
        world:set(e, A, 1)
        world:set(e, A, 2)
        world:remove(e, A)
        world:set(e, A, 3)
        world:delete(e)
        CASE("order and arguments")
        CHECK(table.concat(log, ",") == "add 1,change 2,remove,add 3,remove")
    end)

    TEST(prefix .. "queries", function()
        local world = ecs.world()
        local A, B, C = world:component(), world:component(), world:component()
        local T = world:entity()
        local expected_ab = 0
        local expected_a_not_b = 0
        for i = 1, 300 do
            local e = world:entity()
            world:set(e, A, i)
            if i % 3 == 0 then
                world:set(e, B, i * 2)
                expected_ab += 1
            else
                expected_a_not_b += 1
            end
            if i % 5 == 0 then
                world:add(e, T)
            end
            if i % 7 == 0 then
                world:set(e, C, true)
            end
        end
        CASE("two components with values")
        local n, ok = 0, true
        for e, a, b in world:query(A, B) do
            n += 1
            if b ~= a * 2 or world:get(e, A) ~= a then
                ok = false
            end
        end
        CHECK(n == expected_ab)
        CHECK(ok)
        CASE("without")
        n = 0
        for _, a in world:query(A):without(B) do
            n += 1
            if a % 3 == 0 then
                ok = false
            end
        end
        CHECK(n == expected_a_not_b)
        CHECK(ok)
        CASE("with tag")
        n = 0
        for _, a in world:query(A):with(T) do
            n += 1
            if a % 5 ~= 0 then
                ok = false
            end
        end
        CHECK(n == 60)
        CHECK(ok)
        CASE("cached query can be iterated again")
        local cached = world:query(A, C):cached()
        local first, second = 0, 0
        for _ in cached do
            first += 1
        end
        for _ in cached do
            second += 1
        end
        CHECK(first == 42 and second == 42)
        CASE("unused id gives an empty query")
        local unused = world:component()
        n = 0
        for _ in world:query(A, unused) do
            n += 1
        end
        CHECK(n == 0)
        CASE("removing the current entity during iteration")
        n = 0
        for e in world:query(A, C) do
            world:remove(e, C)
            n += 1
        end
        CHECK(n == 42)
        n = 0
        for _ in world:query(A, C) do
            n += 1
        end
        CHECK(n == 0)
    end)

    if impl.many_ids then
        TEST(prefix .. "no limits", function()
            local world = ecs.world()
            CASE("more than 256 components")
            local list = {}
            for i = 1, 300 do
                list[i] = world:component()
            end
            local e = world:entity()
            for i, id in list do
                world:set(e, id, i)
            end
            CHECK(world:get(e, list[300]) == 300)
            CASE("get and has with 8 ids")
            local v1, _v2, _v3, v4, v5, _v6, _v7, v8 =
                world:get(e, list[1], list[2], list[3], list[4], list[5], list[6], list[7], list[8])
            CHECK(v1 == 1 and v4 == 4 and v5 == 5 and v8 == 8)
            CHECK(world:has(e, list[1], list[2], list[3], list[4], list[5], list[6], list[7], list[8]))
            CHECK(not world:has(e, list[1], list[2], list[3], list[4], list[5], list[6], list[7], world:component()))
            CASE("query with 10 terms")
            local n = 0
            for _, a, _, _, _, _, _, _, _, _, j in
                world:query(list[1], list[2], list[3], list[4], list[5], list[6], list[7], list[8], list[9], list[10])
            do
                n += 1
                if a ~= 1 or j ~= 10 then
                    n = -100
                end
            end
            CHECK(n == 1)
        end)
    end
end

-- a failed case must fail the process (CI reads the exit code)
assert(FINISH() == 0, "some test cases failed")
