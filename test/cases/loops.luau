--!strict
--[[
    Behavior cases: loops over the members of an id (world:each, world:children): the members at
    the start of the loop with their full generations, in ascending slot order, at the
    boundaries of words, pages and blocks, after emptied words and recycled slots, and when a
    few members keep moving between words; held, exhausted and abandoned iterators of two worlds
    that never share a reused buffer; and a frame of messages whose hooks make and replace
    messages while the outer loop runs.
]]

local api = require("@lib")
local support = require("./support")

type Entity = api.Entity
type Iterator = () -> Entity?

return function(spec: support.Spec)
    local ecs, TEST, CASE, CHECK = spec.ecs, spec.TEST, spec.CASE, spec.CHECK
    local collect, equal = support.collect, support.same

    TEST("snapshots at word and page boundaries", function()
        for _, words in { 0, 1, 2, 63, 64, 65 } do
            CASE(`{words} words, with emptied words and recycled slots`)
            local world = ecs.world()
            local tag, parent = world:entity(), world:entity()
            local child_of = ecs.pair(ecs.ChildOf, parent)
            local members: { Entity } = {}
            for i = 1, words do
                -- Offset across a top-level bitset boundary; alternate ends of a word.
                local e = world:entity(32768 + i * 32 + i % 2 * 31)
                world:add(e, tag)
                world:add(e, child_of)
                members[i] = e
            end
            for pass = 1, 3 do
                local a, b = world:each(tag), world:children(parent)
                if words > 0 then
                    local last = members[words]
                    world:delete(last)
                    local fresh = world:entity()
                    CHECK(ecs.ECS_ID(fresh) == ecs.ECS_ID(last) and fresh ~= last)
                    world:add(fresh, tag)
                    world:add(fresh, child_of)
                    CHECK(equal(collect(a), members) and equal(collect(b), members))
                    members[words] = fresh
                else
                    CHECK(#collect(a) == 0 and #collect(b) == 0)
                end
                CHECK(equal(collect(world:each(tag)), members))
                if pass == 2 then
                    -- The next pass uses records whose words have been emptied and refilled.
                    for _, e in members do
                        world:remove(e, tag)
                        world:remove(e, child_of)
                    end
                    for _, e in members do
                        world:add(e, tag)
                        world:add(e, child_of)
                    end
                end
            end
        end
        CASE("members straddle 32, 256, 1024 and 32768 slots")
        local world = ecs.world()
        local tag = world:entity()
        local expected: { Entity } = {}
        for _, slot in { 31, 32, 33, 255, 256, 257, 1023, 1024, 1025, 32767, 32768, 32769 } do
            local e = world:entity(slot)
            world:add(e, tag)
            table.insert(expected, e)
        end
        CHECK(equal(collect(world:each(tag)), expected))

        -- A state of a small world: each move of a member empties the word it leaves, so the
        -- emptied words soon outnumber the members, then fill the record, then are dropped.
        CASE("a few members moving between words while the emptied words outnumber them")
        local small = ecs.world()
        local state = small:entity()
        local owned: { Entity } = {}
        for i = 1, 1500 do
            owned[i] = small:entity()
        end
        local holders: { Entity } = {}
        for m = 1, 4 do
            holders[m] = owned[(m - 1) * 375 + 1]
            small:add(holders[m], state)
        end
        local function in_slot_order(list: { Entity }): { Entity }
            local sorted = table.clone(list)
            table.sort(sorted, function(a: Entity, b: Entity): boolean
                return ecs.ECS_ID(a) < ecs.ECS_ID(b)
            end)
            return sorted
        end
        local seed = 7
        local function rand(n: number): number
            seed = seed * 16807 % 2147483647
            return seed % n + 1
        end
        local exact = true
        for _ = 1, 2500 do
            local m = rand(4)
            local new = owned[rand(1500)]
            if not small:has(new, state) then
                local before = in_slot_order(holders)
                local held = small:each(state)
                small:remove(holders[m], state)
                small:add(new, state)
                holders[m] = new
                exact = exact
                    and equal(collect(held), before)
                    and equal(collect(small:each(state)), in_slot_order(holders))
            end
        end
        CHECK(exact)
    end)

    TEST("more than sixteen snapshots across two worlds", function()
        local worlds = { ecs.world(), ecs.world() }
        local tags = { worlds[1]:entity(), worlds[2]:entity() }
        local expected: { { Entity } } = { {}, {} }
        for k, world in worlds do
            for _ = 1, 97 + k do
                local e = world:entity()
                world:add(e, tags[k])
                table.insert(expected[k], e)
            end
        end
        CASE("held, exhausted and abandoned iterators do not alias a reused buffer")
        local pending: { Iterator } = {}
        for i = 1, 35 do
            local k = i % 2 + 1
            pending[i] = worlds[k]:each(tags[k])
        end
        for i = #pending, 1, -1 do
            CHECK(equal(collect(pending[i]), expected[i % 2 + 1]))
        end
        local held = worlds[1]:each(tags[1])
        CHECK(held() == expected[1][1])
        local fresh = worlds[2]:each(tags[2])
        for _, old in pending do
            CHECK(old() == nil)
            CHECK(old() == nil)
        end
        CHECK(equal(collect(fresh), expected[2]))
        local tail = table.clone(expected[1])
        table.remove(tail, 1)
        CHECK(equal(collect(held), tail))
    end)

    TEST("one frame of messages keeps its starting generations", function()
        CASE("a hook creates a message and replaces one ahead of the outer loop")
        local world = ecs.world()
        local message = world:component() :: api.Component<number>
        local fire = world:entity()
        local first, second = world:entity(), world:entity()
        world:set(first, message, 1)
        world:set(second, message, 2)
        local fresh: Entity? = nil
        local nested: { Entity } = {}
        world:added(fire, function()
            world:delete(second)
            local e = world:entity()
            fresh = e
            world:set(e, message, 3)
            nested = collect(world:each(message))
        end)
        local seen: { Entity } = {}
        for e in world:each(message) do
            table.insert(seen, e)
            if e == first then
                world:add(e, fire)
            end
        end
        CHECK(equal(seen, { first, second }) and not world:contains(second))
        CHECK(fresh ~= nil and equal(nested, { first, fresh :: Entity }))
        CHECK(equal(collect(world:each(message)), nested))
    end)
end
