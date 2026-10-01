--!strict
--[[
    Behavior cases: changes of the ids of one entity.

    - world:toggle adds an id that the entity does not have and removes one that it has, and
      tells which it did: a component toggled on has no value, toggled off it loses its value;
      a pair of an exclusive relation replaces the target; Disabled toggled hides and shows the
      entity; hooks, signals, monitors and change tracking run as for add and remove; a dead
      entity is ignored (a debug world raises an error) and a wildcard is an error.
    - The Component trait is given to an id before its first use: then the id holds values.
      Added to an id used already (as an id, a relation or a target) it raises an error and the
      id stays a tag; removed from a component used already, by world:remove or world:clear, it
      raises an error and nothing changes; a used component is deleted as any id. A refused
      change leaves nothing pending. A toggle is refused the same way; a refused add is undone,
      which the removal listeners of Component hear (its addition listeners hear nothing).
    - A component set, removed and set again, and the delete of another entity: every entity
      keeps its own value, and the queries return live entities with their own values.
    - A deleted id given to a live entity (add, set, toggle) is ignored in a world without debug
      and raises an error in a debug world; a pair whose element has a free slot raises an
      error in both.
    - Exclusive given to a relation that an entity has with several targets raises an error and
      is not added; with one target per entity the relation becomes exclusive.
]]

local api = require("@lib")
local support = require("./support")

return function(spec: support.Spec)
    local ecs, TEST, CASE, CHECK, CHECK_EXPECT_ERR = spec.ecs, spec.TEST, spec.CASE, spec.CHECK, spec.CHECK_EXPECT_ERR
    local pair = ecs.pair
    local collect, same = support.collect, support.same

    TEST("world:toggle", function()
        local world = ecs.world()
        local Stunned, Health = world:entity(), world:component()
        local e = world:entity()

        CASE("an absent id is added (true), a present one removed (false)")
        CHECK(world:toggle(e, Stunned) == true and world:has(e, Stunned))
        CHECK(world:toggle(e, Stunned) == false and not world:has(e, Stunned))

        CASE("a component toggled off loses its value; toggled on it has none")
        world:set(e, Health, 10)
        CHECK(world:toggle(e, Health) == false and world:get(e, Health) == nil)
        CHECK(world:toggle(e, Health) == true and world:has(e, Health) and world:get(e, Health) == nil)

        CASE("a pair of an exclusive relation toggled on replaces the target")
        local Target = world:entity()
        world:add(Target, ecs.Exclusive)
        local first, second = world:entity(), world:entity()
        world:toggle(e, pair(Target, first))
        CHECK(world:toggle(e, pair(Target, second)) == true)
        CHECK(world:has(e, pair(Target, second)) and not world:has(e, pair(Target, first)))
        CHECK(world:toggle(e, pair(Target, second)) == false and world:target(e, Target) == nil)

        CASE("Disabled toggled hides the entity from queries and shows it again")
        world:add(e, Stunned)
        CHECK(world:toggle(e, ecs.Disabled) == true and #collect(world:query():with(Stunned)) == 0)
        CHECK(world:toggle(e, ecs.Disabled) == false and same(collect(world:query():with(Stunned)), { e }))

        CASE("hooks, signals, monitors and change tracking run as for add and remove")
        local Flag = world:entity()
        local hooks: { string } = {}
        world:set(Flag, ecs.OnAdd, function()
            table.insert(hooks, "add")
        end)
        world:set(Flag, ecs.OnRemove, function()
            table.insert(hooks, "remove")
        end)
        local signals = 0
        local disconnect = world:added(Flag, function()
            signals += 1
        end)
        local entries, exits = 0, 0
        local monitor = world:query():with(Flag):monitor()
        monitor.added(function()
            entries += 1
        end)
        monitor.removed(function()
            exits += 1
        end)
        world:track(Flag)
        local added = world:query(Health):added(Flag):cached()
        local removed = world:query(Health):removed(Flag):cached()
        world:tick()
        collect(added)
        collect(removed)
        world:toggle(e, Flag)
        world:tick()
        CHECK(same(collect(added), { e }) and #collect(removed) == 0)
        world:toggle(e, Flag)
        world:tick()
        CHECK(#collect(added) == 0 and same(collect(removed), { e }))
        CHECK(hooks[1] == "add" and hooks[2] == "remove" and #hooks == 2)
        CHECK(signals == 1 and entries == 1 and exits == 1)
        disconnect()
        monitor.disconnect()

        CASE("a dead entity is ignored (false); a debug world raises an error")
        local plain = ecs.world(false) -- a world without the checks of a debug world
        local Plain = plain:entity()
        local dead = plain:entity()
        plain:delete(dead)
        CHECK(plain:toggle(dead, Plain) == false and not plain:contains(dead))
        local strict = ecs.world(true)
        local Tag = strict:entity()
        local gone = strict:entity()
        strict:delete(gone)
        CHECK_EXPECT_ERR(function()
            strict:toggle(gone, Tag)
        end)

        CASE("a wildcard is an error")
        CHECK_EXPECT_ERR(function()
            world:toggle(e, pair(Target, ecs.Wildcard))
        end)
    end)

    TEST("the Component trait", function()
        for _, debug in { false, true } do
            local kind = if debug then " (debug world)" else ""
            local world = ecs.world(debug)
            local e = world:entity()

            CASE(`given to an id before its first use, the id holds values{kind}`)
            -- an entity typed as a component: it gets the trait before its first use
            local Fresh = world:entity() :: any
            world:add(Fresh, ecs.Component)
            world:set(e, Fresh, 5)
            CHECK(world:get(e, Fresh) == 5)

            CASE(`added to an id used as a tag, a relation or a target: an error, the id stays a tag{kind}`)
            local Tag, Relation, Target = world:entity(), world:entity(), world:entity()
            world:add(e, Tag)
            world:add(e, pair(Relation, Target))
            for _, id in { Tag, Relation, Target } do
                CHECK_EXPECT_ERR(function()
                    world:add(id, ecs.Component)
                end)
                CHECK(not world:has(id, ecs.Component))
            end
            CHECK(world:has(e, Tag) and world:has(e, pair(Relation, Target)))
            CHECK_EXPECT_ERR(function()
                world:set(e, Tag :: any, 1)
            end)

            CASE(`toggled on a used id: an error, the id stays a tag; the undo is a removal for listeners{kind}`)
            do
                local Toggled = world:entity()
                world:add(e, Toggled)
                local removals, additions = 0, 0
                local off_removed = world:removed(ecs.Component, function()
                    removals += 1
                end)
                local off_added = world:added(ecs.Component, function()
                    additions += 1
                end)
                CHECK_EXPECT_ERR(function()
                    world:toggle(Toggled, ecs.Component)
                end)
                off_removed()
                off_added()
                CHECK(not world:has(Toggled, ecs.Component) and removals == 1 and additions == 0)
            end

            CASE(`removed from a used component by remove or clear: an error, nothing changes{kind}`)
            local Health = world:component()
            world:set(Health, ecs.Name, "Health")
            world:set(e, Health, 10)
            CHECK_EXPECT_ERR(function()
                world:remove(Health, ecs.Component)
            end)
            CHECK_EXPECT_ERR(function()
                world:clear(Health)
            end)
            CHECK(world:has(Health, ecs.Component) and world:get(Health, ecs.Name) == "Health")
            world:set(e, Health, 11)
            CHECK(world:get(e, Health) == 11)

            CASE(`a used component is deleted as any id; its removal listeners run once{kind}`)
            local Marker = world:entity()
            world:add(Health, Marker)
            local heard = 0
            world:removed(Marker, function()
                heard += 1
            end)
            world:delete(Health)
            CHECK(heard == 1 and not world:contains(Health) and not world:has(e, Health))

            CASE(`a refused removal leaves nothing pending: Component comes off once the target is not used{kind}`)
            local Holds = world:entity()
            local Kind = world:component()
            world:add(e, pair(Holds, Kind))
            CHECK_EXPECT_ERR(function()
                world:remove(Kind, ecs.Component)
            end)
            world:remove(e, pair(Holds, Kind))
            -- many pairs that come and go: the records of the pairs that are gone are freed
            for _ = 1, 1000 do
                local other = world:entity()
                world:add(e, pair(Holds, other))
                world:remove(e, pair(Holds, other))
            end
            world:remove(Kind, ecs.Component)
            CHECK(not world:has(Kind, ecs.Component))
        end
    end)

    TEST("a deleted id given to a live entity", function()
        for _, debug in { false, true } do
            for _, operation in { "add", "set", "toggle" } do
                CASE(`{operation} of a deleted tag {if debug then "raises an error (debug world)" else "does nothing"}`)
                local world = ecs.world(debug)
                local tag, entity = world:entity(), world:entity()
                world:delete(tag)
                local toggled: boolean? = nil
                local ok = pcall(function()
                    if operation == "add" then
                        world:add(entity, tag)
                    elseif operation == "set" then
                        world:set(entity, tag, nil)
                    else
                        toggled = world:toggle(entity, tag)
                    end
                end)
                CHECK(ok ~= debug and #world:ids(entity) == 0)
                CHECK(debug or operation ~= "toggle" or toggled == false)
            end

            CASE(
                `a pair with the free slot of a deleted target raises an error{if debug then " (debug world)" else ""}`
            )
            local world = ecs.world(debug)
            local relation, target, entity = world:entity(), world:entity(), world:entity()
            world:delete(target)
            CHECK(not pcall(world.add, world, entity, pair(relation, target)))
            CHECK(#world:ids(entity) == 0)
        end
    end)

    TEST("Exclusive after the first use of a relation", function()
        for _, debug in { false, true } do
            local kind = if debug then " (debug world)" else ""
            CASE(`an entity with several targets of the relation: an error, and the relation is not exclusive{kind}`)
            do
                local world = ecs.world(debug)
                local relation, a, b, e = world:entity(), world:entity(), world:entity(), world:entity()
                world:add(e, pair(relation, a))
                world:add(e, pair(relation, b))
                CHECK(not pcall(world.add, world, relation, ecs.Exclusive))
                CHECK(not world:has(relation, ecs.Exclusive))
                world:add(e, pair(relation, a))
                CHECK(world:target(e, relation, 0) ~= nil and world:target(e, relation, 1) ~= nil)
            end

            CASE(`one target per entity: the relation becomes exclusive{kind}`)
            do
                local world = ecs.world(debug)
                local relation, a, b, e = world:entity(), world:entity(), world:entity(), world:entity()
                world:add(e, pair(relation, a))
                world:add(relation, ecs.Exclusive)
                CHECK(world:has(relation, ecs.Exclusive))
                world:add(e, pair(relation, b))
                CHECK(world:target(e, relation, 0) == b and world:target(e, relation, 1) == nil)
            end
        end
    end)

    TEST("values after a component set, removed and set again", function()
        for _, debug in { false, true } do
            CASE(
                `and the delete of another entity: every entity keeps its value{if debug then " (debug world)" else ""}`
            )
            local world = ecs.world(debug)
            local A = world:component() :: api.Component<string>
            local e2 = world:entity()
            world:set(e2, A, "e2")
            world:remove(e2, A)
            local e1 = world:entity()
            world:set(e1, A, "e1")
            world:remove(e1, A)
            local e3 = world:entity()
            world:set(e3, A, "e3")
            world:set(e1, A, "e1")
            world:delete(e2)
            CHECK(world:get(e1, A) == "e1" and world:get(e3, A) == "e3")
            local own = true
            for e, value in world:query(A) do
                own = own and world:contains(e) and value == world:get(e, A)
            end
            CHECK(own)
            world:delete(e1)
            local left: { any } = {}
            for e, value in world:query(A) do
                table.insert(left, { e, value })
            end
            CHECK(#left == 1 and left[1][1] == e3 and left[1][2] == "e3")
        end
    end)
end
