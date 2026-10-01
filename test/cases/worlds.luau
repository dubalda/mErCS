--!strict
--[[
    Behavior cases: worlds and the ids of entities.

    - Two worlds in one process are independent: each numbers its ids from the start, so the
      same numbers live in both, and the values, hooks, signals, change tracking, queries and
      deletes of one world never reach the other.
    - world:entity(id) makes exactly that id alive: a live entity of another generation in its
      slot is deleted first (its hooks run), so is a new entity that those hooks make in the slot
      (with its values and its uses as an id), and the next entity of the slot takes the
      following generation. An older generation made alive again over newer ones: the newer ids
      stay dead, and after its delete the next entity of the slot takes the generation after
      the newest one.
    - An old id of a slot that a new entity took reads nothing of the new entity, and its
      changes (set, add, remove, toggle, clear, delete; of ids the new entity has and has not)
      do nothing in a world without debug and raise errors in a debug world; the new entity
      keeps its data and memberships, and no hook, signal or monitor hears the old id.
    - Explicit ids and new entities: the next generation of a deleted entity made alive is alive
      and no new entity gets it; a deleted id made alive again, then a new entity: two live
      entities; a delete of an entity made before world:range makes no id of the range alive; an
      explicit id above the highest slot keeps the slot of a deleted entity for new entities.
    - world:range: the new ids stay inside the range, also after ids outside it were made alive
      and deleted, and start at first + 1 after an id above it (an older generation made alive
      again after its slot left the range and came back keeps the newer ids dead); a range of
      one slot gives its id
      and then an error, and its deleted id is used again; ids of another world made alive in
      any order leave their slots to them; deleted ids made alive again in another order leave
      the other free slots to the new ids; a pool made before the range gives new ids inside it
      and never again the slots of its ids from before, also when its block reaches into the
      range (it goes on with the slots of the block inside it).
]]

local api = require("@lib")
local support = require("./support")

type Entity = api.Entity

return function(spec: support.Spec)
    local ecs, TEST, CASE, CHECK = spec.ecs, spec.TEST, spec.CASE, spec.CHECK
    local collect, same = support.collect, support.same
    local pair = ecs.pair

    TEST("two worlds in one process", function()
        local first, second = ecs.world(), ecs.world()
        local C1, C2 = first:component(), second:component()
        local a1, a2 = first:entity(), second:entity()

        CASE("each world numbers its ids from the start: the same numbers in both")
        CHECK(C1 == C2 and a1 == a2)

        CASE("the values of one world are not in the other")
        first:set(a1, C1, 1)
        CHECK(not second:has(a2, C2) and second:get(a2, C2) == nil)
        second:set(a2, C2, 2)
        CHECK(first:get(a1, C1) == 1 and second:get(a2, C2) == 2)

        CASE("the hooks and signals of one world do not run for the other")
        local hooks, signals = 0, 0
        first:set(C1, ecs.OnChange, function()
            hooks += 1
        end)
        local disconnect = first:changed(C1, function()
            signals += 1
        end)
        second:set(a2, C2, 3)
        CHECK(hooks == 0 and signals == 0)
        first:set(a1, C1, 4)
        CHECK(hooks == 1 and signals == 1)
        disconnect()

        CASE("the tick of one world does not advance the change tracking of the other")
        first:track(C1)
        second:track(C2)
        local changed1 = first:query(C1):changed(C1):cached()
        local changed2 = second:query(C2):changed(C2):cached()
        first:tick()
        second:tick()
        collect(changed1)
        collect(changed2)
        first:set(a1, C1, 5)
        second:set(a2, C2, 5)
        first:tick()
        CHECK(same(collect(changed1), { a1 }) and #collect(changed2) == 0)
        second:tick()
        CHECK(same(collect(changed2), { a2 }))

        CASE("the queries of one world return its own entities, also while the other one changes")
        local cached = first:query(C1):cached()
        collect(cached)
        for _ = 1, 50 do
            local e = second:entity()
            second:set(e, C2, 0)
        end
        CHECK(same(collect(cached), { a1 }) and same(collect(first:query(C1)), { a1 }))
        CHECK(#collect(second:query(C2)) == 51)

        CASE("deleting an entity in one world leaves the same id alive in the other")
        second:delete(a2)
        CHECK(first:contains(a1) and first:get(a1, C1) == 5 and not second:contains(a2))
    end)

    TEST("world:entity(id): an explicit id", function()
        local world = ecs.world()
        local C = world:component()
        local removals: { { any } } = {}
        world:set(C, ecs.OnRemove, function(e: any, _: any, deleting: any)
            table.insert(removals, { e, deleting })
        end)
        local old = world:entity()
        world:set(old, C, 1)
        local id = ecs.ECS_COMBINE(ecs.ECS_ID(old), ecs.ECS_GENERATION(old) + 3)

        CASE("a slot held by a live entity of another generation: that entity is deleted, its hooks run")
        local made = world:entity(id)
        CHECK(made == id and world:contains(id) and not world:contains(old))
        CHECK(#removals == 1 and removals[1][1] == old and removals[1][2] == true)
        CHECK(not world:has(id, C))

        CASE("the live id itself is returned as it is, and nothing runs")
        CHECK(world:entity(id) == id and #removals == 1 and world:contains(id))

        CASE("the next entity of the slot takes the following generation")
        world:delete(id)
        local next_one = world:entity()
        CHECK(ecs.ECS_ID(next_one) == ecs.ECS_ID(old))
        CHECK(ecs.ECS_GENERATION(next_one) == ecs.ECS_GENERATION(id) + 1)

        for _, debug in { false, true } do
            CASE(
                `an older generation made alive again over newer ones: the newer ids stay dead{if debug
                    then " (debug world)"
                    else ""}`
            )
            do
                local w = ecs.world(debug)
                local first = w:entity()
                w:delete(first)
                local second = w:entity()
                w:delete(second)
                local third = w:entity() -- the newest generation, alive
                CHECK(ecs.ECS_ID(third) == ecs.ECS_ID(first) and ecs.ECS_GENERATION(third) == 2)
                CHECK(w:entity(first) == first and w:contains(first) and not w:contains(third))
                w:delete(first)
                local after = w:entity()
                CHECK(ecs.ECS_ID(after) == ecs.ECS_ID(first) and ecs.ECS_GENERATION(after) == 3)
                CHECK(not w:contains(second) and not w:contains(third) and w:contains(after))
            end

            CASE(
                `the hooks of that delete make a new entity in the slot: it is deleted too{if debug
                    then " (debug world)"
                    else ""}`
            )
            local w = ecs.world(debug)
            local Trigger = w:component() :: api.Component<number>
            local Data = w:component() :: api.Component<number>
            local survivor, owner = w:entity(), w:entity()
            w:set(owner, Trigger, 1)
            local requested = ecs.ECS_COMBINE(ecs.ECS_ID(owner), ecs.ECS_GENERATION(owner) + 3)
            local replacement: Entity? = nil
            w:removed(Trigger, function(entity)
                if replacement == nil then
                    w:delete(entity)
                    local fresh = w:entity()
                    replacement = fresh
                    w:set(fresh, Data, 99)
                    w:add(survivor, fresh)
                end
            end)
            CHECK(w:entity(requested) == requested and w:contains(requested))
            local fresh = replacement :: Entity
            CHECK(ecs.ECS_ID(fresh) == ecs.ECS_ID(requested) and not w:contains(fresh))
            CHECK(w:get(requested, Data) == nil and not w:has(survivor, fresh))
        end
    end)

    TEST("an old id of a slot that a new entity took", function()
        for _, debug in { false, true } do
            CASE(
                if debug
                    then "a debug world: reads of the old id see nothing, its changes raise errors"
                    else "reads of the old id see nothing of the new entity, its changes do nothing"
            )
            local world = ecs.world(debug)
            -- C, T and the pair are on the new entity; D is not
            local C, D, T, R = world:component(), world:component(), world:entity(), world:entity()
            local target = world:entity()
            local old = world:entity()
            world:set(old, C, 1)
            world:set(old, D, 1)
            world:delete(old)
            local new = world:entity()
            CHECK(ecs.ECS_ID(new) == ecs.ECS_ID(old) and new ~= old)
            world:set(new, C, 2)
            world:add(new, T)
            world:add(new, pair(R, target))
            -- what may not hear the old id: hooks, signals and a monitor of every id
            local events = 0
            local function count()
                events += 1
            end
            for _, id in { C, D, T, R } do
                world:set(id, ecs.OnAdd, count)
                world:set(id, ecs.OnChange, count)
                world:set(id, ecs.OnRemove, count)
                world:added(id, count)
                world:changed(id, count)
                world:removed(id, count)
            end
            local monitor = world:query(C):with(T):monitor()
            monitor.added(count)
            monitor.removed(count)

            -- reads through the old id
            local values = world:get_list(old, { C, D })
            CHECK(world:get(old, C) == nil and values[1] == nil and values[2] == nil)
            CHECK(not world:has(old, C) and not world:has(old, T) and not world:has(old, pair(R, target)))
            CHECK(not world:has_all(old, { C, T }) and not world:query(C):has(old))

            -- changes through the old id, of ids that the new entity has and has not
            local changes: { () -> () } = {
                function()
                    world:set(old, C, 9)
                end,
                function()
                    world:set(old, D, 9)
                end,
                function()
                    world:add(old, T)
                end,
                function()
                    world:add(old, D)
                end,
                function()
                    world:remove(old, C)
                end,
                function()
                    world:remove(old, D)
                end,
                function()
                    world:toggle(old, T)
                end,
                function()
                    world:toggle(old, D)
                end,
                function()
                    world:clear(old)
                end,
                function()
                    world:delete(old)
                end,
            }
            local refused = true
            for _, change in changes do
                local ok = pcall(change)
                if ok == debug then
                    refused = false -- a debug world raises an error, a world without debug does not
                end
            end
            CHECK(refused)

            -- the new entity is as it was, and nothing heard the old id
            CHECK(world:contains(new) and not world:contains(old))
            CHECK(world:get(new, C) == 2 and world:has(new, T) and world:has(new, pair(R, target)))
            CHECK(not world:has(new, D))
            CHECK(same(collect(world:query(C):with(T)), { new }) and same(collect(world:each(T)), { new }))
            CHECK(events == 0)
            monitor.disconnect()
        end
    end)

    TEST("world:range and explicit ids", function()
        local ID, GENERATION = ecs.ECS_ID, ecs.ECS_GENERATION

        CASE("a range of one slot: its id, then an error; its deleted id is used again")
        do
            local world = ecs.world()
            world:range(1000, 1002)
            local only = world:entity()
            CHECK(ID(only) == 1001)
            spec.CHECK_EXPECT_ERR(function()
                world:entity()
            end)
            world:delete(only)
            local again = world:entity()
            CHECK(ID(again) == 1001 and GENERATION(again) == GENERATION(only) + 1)
            spec.CHECK_EXPECT_ERR(function()
                world:entity()
            end)
        end

        CASE("ids made alive below and above the range never become new ids, also once deleted")
        do
            local world = ecs.world()
            world:range(1000, 2000)
            local first = world:entity()
            CHECK(ID(first) == 1001)
            local below, above = world:entity(500), world:entity(5000)
            CHECK(world:contains(below) and world:contains(above))
            world:delete(below)
            world:delete(above)
            local inside, seen = true, {}
            for _ = 1, 40 do
                local made = world:entity()
                local slot = ID(made)
                inside = inside and slot > 1000 and slot < 2000 and not seen[slot]
                seen[slot] = true
            end
            CHECK(inside and seen[1002] == true)
        end

        CASE("after an id above the range, the new ids start at first + 1 and stay inside it")
        do
            local world = ecs.world()
            world:range(1000, 1005)
            world:entity(9000)
            local slots: { number } = {}
            for i = 1, 4 do
                local made = world:entity()
                slots[i] = ID(made)
            end
            CHECK(table.concat(slots, ",") == "1001,1002,1003,1004")
            spec.CHECK_EXPECT_ERR(function()
                world:entity()
            end)
        end

        CASE("ids of another world made alive and deleted: new ids take none of their slots")
        do
            local source = ecs.world()
            source:range(1000, 2000)
            local ids: { Entity } = {}
            for i = 1, 20 do
                ids[i] = source:entity()
            end
            local mirror = ecs.world()
            mirror:range(3000, 4000)
            for _, e in ids do
                mirror:entity(e)
            end
            for i = 1, 20, 2 do
                mirror:delete(ids[i])
            end
            local inside = true
            for _ = 1, 30 do
                local made = mirror:entity()
                local slot = ID(made)
                inside = inside and slot > 3000 and slot < 4000
            end
            CHECK(inside)
            for i = 2, 20, 2 do
                CHECK(mirror:contains(ids[i]))
            end
        end

        CASE("ids of another world made alive in any order: new ids take none of their slots")
        do
            local source = ecs.world()
            source:range(1000, 2000)
            local ids: { Entity } = {}
            for i = 1, 30 do
                ids[i] = source:entity()
            end
            local mirror = ecs.world()
            mirror:range(3000, 4000)
            -- a fixed shuffle
            local order: { Entity } = {}
            for i = 1, 30 do
                order[i] = ids[(i * 7) % 30 + 1]
            end
            for _, e in order do
                CHECK(mirror:entity(e) == e)
            end
            local mine: { [number]: boolean } = {}
            local inside = true
            for _ = 1, 30 do
                local made = mirror:entity()
                local slot = ID(made)
                inside = inside and slot > 3000 and slot < 4000 and not mine[slot]
                mine[slot] = true
            end
            CHECK(inside)
            for _, e in ids do
                CHECK(mirror:contains(e))
            end
        end

        CASE("deleted ids made alive again in another order: new ids take the remaining slots")
        do
            local world = ecs.world()
            world:range(1000, 2000)
            local list: { any } = {}
            for i = 1, 6 do
                list[i] = world:entity()
            end
            for _, i in { 2, 4, 5 } do
                world:delete(list[i])
            end
            -- the slots of list[2] and list[5] made alive again with their next generation
            local back2 = ecs.ECS_COMBINE(ID(list[2]), GENERATION(list[2]) + 1)
            local back5 = ecs.ECS_COMBINE(ID(list[5]), GENERATION(list[5]) + 1)
            CHECK(world:entity(back2) == back2 and world:entity(back5) == back5)
            local next1, next2 = world:entity(), world:entity()
            CHECK(ID(next1) == ID(list[4]) and ID(next2) == ID(list[6]) + 1)
            CHECK(world:contains(back2) and world:contains(back5) and not world:contains(list[2]))
        end

        for _, debug in { false, true } do
            local kind = if debug then " (debug world)" else ""
            CASE(`a pool made before the range: new ids inside it, never again the slots from before{kind}`)
            local world = ecs.world(debug)
            local pool = world:pool()
            local old = pool:entity()
            world:range(1000, 2000)
            local made = pool:entity()
            CHECK(ID(made) > 1000 and ID(made) < 2000)
            world:delete(old)
            local inside = true
            -- more than one block of the pool, and as many new ids of the world
            for _ = 1, 300 do
                local slot, other = ID(pool:entity()), ID(world:entity())
                inside = inside and slot > 1000 and slot < 2000 and other > 1000 and other < 2000
            end
            CHECK(inside)
        end

        CASE("a pool whose block reaches into the range goes on with the slots of the block inside it")
        do
            local world = ecs.world()
            local pool = world:pool()
            local first = pool:entity()
            world:range(ID(first) + 88, 2000)
            local next1, next2 = pool:entity(), pool:entity()
            CHECK(ID(next1) == ID(first) + 89 and ID(next2) == ID(first) + 90)
        end
    end)

    TEST("the generations of a slot that left the range", function()
        for _, debug in { false, true } do
            CASE(
                `an older generation made alive again keeps the newer ids dead{if debug then " (debug world)" else ""}`
            )
            local world = ecs.world(debug)
            local old = world:entity()
            world:delete(old)
            local newer = world:entity()
            world:delete(newer)
            local slot = ecs.ECS_ID(old)
            world:range(slot + 1, slot + 100)
            world:range(slot - 1, slot + 100)
            CHECK(world:entity(old) == old)
            world:delete(old)
            local next_one = world:entity()
            CHECK(ecs.ECS_ID(next_one) == slot and next_one ~= newer)
            CHECK(ecs.ECS_GENERATION(next_one) == ecs.ECS_GENERATION(newer) + 1 and not world:contains(newer))
        end
    end)

    TEST("explicit ids and new entities", function()
        for _, debug in { false, true } do
            local kind = if debug then " (debug world)" else ""

            CASE(`the next generation of a deleted entity made alive: no new entity gets it{kind}`)
            do
                local world = ecs.world(debug)
                local C = world:component() :: api.Component<string>
                local e = world:entity()
                world:delete(e)
                local next_id = ecs.ECS_GENERATION_INC(e)
                CHECK(world:entity(next_id) == next_id and world:contains(next_id))
                world:set(next_id, C, "payload")
                local fresh = world:entity()
                CHECK(fresh ~= next_id and world:get(fresh, C) == nil and world:get(next_id, C) == "payload")
            end

            CASE(`a deleted id made alive again, then a new entity: two live entities{kind}`)
            do
                local world = ecs.world(debug)
                local T = world:component()
                local a, b = world:entity(), world:entity()
                world:delete(a)
                world:delete(b)
                CHECK(world:entity(a) == a and world:contains(a))
                local made = world:entity()
                world:add(made, T)
                CHECK(made ~= a and world:contains(made) and world:has(made, T))
                CHECK(world:query(T):count() == 1)
            end

            CASE(`a delete of an entity made before world:range makes no id of the range alive{kind}`)
            do
                local world = ecs.world(debug)
                local A = world:component() :: api.Component<string>
                local e = world:entity()
                world:set(e, A, "real")
                world:range(1000, 2000)
                world:delete(e)
                local placeholder: Entity = 1000 :: any -- an id of the range that no one made
                CHECK(not world:contains(placeholder) and world:query(A):count() == 0)
            end

            CASE(`an explicit id above the highest slot keeps the slot of a deleted entity for new entities{kind}`)
            do
                local world = ecs.world(debug)
                local a = world:entity()
                world:delete(a)
                local next_id = ecs.ECS_GENERATION_INC(a)
                local explicit: Entity = 5000 :: any
                CHECK(world:entity(explicit) == explicit and world:contains(explicit))
                local given = false
                for _ = 1, 6000 do
                    if world:entity() == next_id then
                        given = true
                        break
                    end
                end
                CHECK(given)
            end
        end
    end)
end
