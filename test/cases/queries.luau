--!strict
--[[
    Behavior cases: the terms of queries and the loops over the members of an id.

    - The terms of a query on five entities (required and excluded components and tags, OR
      terms, Disabled named or not): every way of reading a query returns the same matches in
      ascending slot order: for-in written inline, a cached query looped twice (the second loop
      reads its match list), each, count and has.
    - world:each and world:children return every member of the id, disabled ones included:
      Disabled hides an entity from queries only, and the entity keeps its ids.
    - query arity and nil or false values: 0, 1, 3, 8 and 9 returned ids, cached or not, through
      each and for-in, as the matches come and go.
    - several excluded ids: query(A):without(B, C) through every way of reading it, before and
      after the excluded ids are removed.
]]

local api = require("@lib")
local support = require("./support")

type Entity = api.Entity

return function(spec: support.Spec)
    local ecs, TEST, CASE, CHECK = spec.ecs, spec.TEST, spec.CASE, spec.CHECK
    local pair = ecs.pair
    local collect, same = support.collect, support.same

    TEST("the terms of a query on five entities", function()
        local world = ecs.world()
        local Position, Velocity, Label = world:component(), world:component(), world:component()
        local Unit, Player = world:entity(), world:entity()
        --        components                  tags
        -- e[1]   Position, Velocity          Unit
        -- e[2]   Position, Label             Player
        -- e[3]   Position, Velocity, Label   Unit, Player
        -- e[4]   Velocity
        -- e[5]   Position, Velocity          Unit; disabled
        local e = {}
        for i = 1, 5 do
            e[i] = world:entity()
        end
        world:set(e[1], Position, 1)
        world:set(e[1], Velocity, 1)
        world:add(e[1], Unit)
        world:set(e[2], Position, 2)
        world:set(e[2], Label, "second")
        world:add(e[2], Player)
        world:set(e[3], Position, 3)
        world:set(e[3], Velocity, 3)
        world:set(e[3], Label, "third")
        world:add(e[3], Unit)
        world:add(e[3], Player)
        world:set(e[4], Velocity, 4)
        world:set(e[5], Position, 5)
        world:set(e[5], Velocity, 5)
        world:add(e[5], Unit)
        world:add(e[5], ecs.Disabled)

        -- Every way of reading the query that `make` builds returns the entities `expected`
        -- (indices into e, which were made in ascending slot order).
        local function reads(make: () -> any, expected: { number }): boolean
            local want: { any } = {}
            local member: { [any]: boolean } = {}
            for _, i in expected do
                table.insert(want, e[i])
                member[e[i]] = true
            end
            local cached = make():cached()
            -- the second loop of a cached query reads its match list
            local first_loop = collect(cached)
            local second_loop = collect(cached)
            local by_each: { any } = {}
            make():each(function(entity: any)
                table.insert(by_each, entity)
            end)
            local query = make()
            local has = true
            for _, entity in e do
                if query:has(entity) ~= (member[entity] == true) then
                    has = false
                end
            end
            return same(collect(make()), want)
                and same(first_loop, want)
                and same(second_loop, want)
                and same(by_each, want)
                and make():count() == #want
                and has
        end

        CASE("required components")
        CHECK(reads(function()
            return world:query(Position, Velocity)
        end, { 1, 3 }))

        CASE("a disabled entity matches only a query that names Disabled")
        CHECK(reads(function()
            return world:query(Position, Velocity):with(ecs.Disabled)
        end, { 5 }))
        CHECK(reads(function()
            return world:query(Position):without(ecs.Disabled)
        end, { 1, 2, 3 }))

        CASE("an excluded component")
        CHECK(reads(function()
            return world:query(Velocity):without(Label)
        end, { 1, 4 }))

        CASE("an OR term alone, and with a required component")
        CHECK(reads(function()
            return world:query():any(Position, Label)
        end, { 1, 2, 3 }))
        CHECK(reads(function()
            return world:query(Velocity):any(Position, Label)
        end, { 1, 3 }))

        CASE("required and excluded tags")
        CHECK(reads(function()
            return world:query():with(Unit, Player)
        end, { 3 }))
        CHECK(reads(function()
            return world:query(Velocity):without(Unit)
        end, { 4 }))

        CASE("an OR term of tags, Disabled named or not")
        CHECK(reads(function()
            return world:query():any(Unit, Player)
        end, { 1, 2, 3 }))
        CHECK(reads(function()
            return world:query():any(Unit, Player):with(ecs.Disabled)
        end, { 5 }))

        CASE("excluded ids alone are an error in every way of reading the query")
        -- such a query would match nothing: the call that uses it raises an error
        local function raises(use: (query: any) -> ()): boolean
            return not pcall(use, world:query():without(Unit))
        end
        CHECK(raises(function(query: any)
            collect(query)
        end) and raises(function(query: any)
            query:each(function() end)
        end) and raises(function(query: any)
            query:count()
        end) and raises(function(query: any)
            query:has(e[4])
        end) and raises(function(query: any)
            query:cached()
        end))
    end)

    TEST("world:each and world:children over disabled members", function()
        local world = ecs.world()
        local Tag, Value = world:entity(), world:component()
        local parent = world:entity()
        local shown, hidden = world:entity(), world:entity()
        for _, member in { shown, hidden } do
            world:add(member, Tag)
            world:set(member, Value, 1)
            world:add(member, pair(ecs.ChildOf, parent))
        end
        world:add(hidden, ecs.Disabled)

        CASE("world:each returns a disabled member; a query over the id does not")
        CHECK(same(collect(world:each(Tag)), { shown, hidden }))
        CHECK(same(collect(world:query():with(Tag)), { shown }))

        CASE("world:children returns a disabled child; a query over the pair does not")
        CHECK(same(collect(world:children(parent)), { shown, hidden }))
        CHECK(same(collect(world:query(pair(ecs.ChildOf, parent))), { shown }))

        CASE("a disabled entity keeps its ids, values and parent")
        CHECK(world:has(hidden, Tag) and world:get(hidden, Value) == 1 and world:parent(hidden) == parent)

        CASE("enabled again, it is a match again")
        world:remove(hidden, ecs.Disabled)
        CHECK(same(collect(world:query():with(Tag)), { shown, hidden }))
        CHECK(same(collect(world:each(Tag)), { shown, hidden }))
    end)

    TEST("query arity and nil values across iteration paths", function()
        -- A dynamic count of returned values deliberately uses the runtime query interface.
        for _, arity in { 0, 1, 3, 8, 9 } do
            for _, cached in { false, true } do
                CASE(`{arity} values, cached={cached}`)
                local world = ecs.world()
                local tag = world:entity()
                local ids: { api.Id<any> } = {}
                for _ = 1, arity do
                    table.insert(ids, world:component())
                end
                local entities = { world:entity(32768), world:entity(32769), world:entity(65537) }
                local function fill(e: Entity)
                    world:add(e, tag)
                    for i, id in ids do
                        world:set(e, id, if i % 3 == 0 then nil elseif i % 3 == 1 then false else i)
                    end
                end
                for _, e in entities do
                    fill(e)
                end
                local q: any = (world :: any):query(table.unpack(ids)):with(tag)
                if cached then
                    q:cached()
                end
                local expected = table.clone(entities)
                local at = 0
                local function check_row(entity: Entity, ...: any)
                    at += 1
                    CHECK(entity == expected[at] and select("#", ...) == arity)
                    local values = table.pack(...)
                    for i = 1, arity do
                        CHECK(values[i] == (if i % 3 == 0 then nil elseif i % 3 == 1 then false else i))
                    end
                end
                local function check_loops()
                    at = 0
                    q:each(check_row)
                    CHECK(at == #expected)
                    at = 0
                    local step, state, control = getmetatable(q).__iter(q)
                    while true do
                        local values = table.pack(step(state, control))
                        if values[1] == nil then
                            break
                        end
                        check_row(table.unpack(values, 1, values.n))
                        control = values[1]
                    end
                    CHECK(at == #expected and q:count() == #expected)
                end
                check_loops()
                for _, e in entities do
                    world:clear(e)
                end
                table.clear(expected)
                check_loops()
                for _, e in entities do
                    fill(e)
                    table.insert(expected, e)
                    check_loops()
                end
            end
        end
    end)

    TEST("several excluded ids", function()
        local world = ecs.world()
        local A, B, C = world:component(), world:entity(), world:entity()
        local only, with_b, with_c, with_bc = world:entity(), world:entity(), world:entity(), world:entity()
        local all = { only, with_b, with_c, with_bc }
        for _, e in all do
            world:set(e, A, 1)
        end
        world:add(with_b, B)
        world:add(with_c, C)
        world:add(with_bc, B)
        world:add(with_bc, C)
        local stored = world:query(A):without(B, C):cached()

        -- every way of reading query(A):without(B, C) returns `expected`
        local function reads(expected: { any }): boolean
            local by_each: { any } = {}
            world:query(A):without(B, C):each(function(e: any)
                table.insert(by_each, e)
            end)
            local has = true
            for _, e in all do
                if world:query(A):without(B, C):has(e) ~= (table.find(expected, e) ~= nil) then
                    has = false
                end
            end
            return same(collect(world:query(A):without(B, C)), expected)
                and same(collect(stored), expected)
                and same(by_each, expected)
                and world:query(A):without(B, C):count() == #expected
                and has
        end

        CASE("query(A):without(B, C) returns the entities that have neither")
        CHECK(reads({ only }))

        CASE("an entity matches once both excluded ids are gone")
        world:remove(with_b, B)
        world:remove(with_c, C)
        world:remove(with_bc, B)
        CHECK(reads({ only, with_b, with_c }))
        world:remove(with_bc, C)
        CHECK(reads(all))
    end)
end
