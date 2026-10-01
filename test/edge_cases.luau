--!strict
--[[
    Boundary and reentrant-operation cases: snapshots retain full entity generations,
    nested buffers belong to their own loop, and hooks cannot make a pending removal run
    twice. Batch operations keep the matches of their start; query values retain nils.

    Run with luau test/edge_cases.luau, optionally -a ../tmp/release-024-baseline to check
    a release extracted from git. The optional require is the only untyped module boundary.
]]

local api = require("@lib")
local testkit = require("@testkit")
local args = { ... }
local ecs: typeof(api) = if args[1] then (require :: any)(args[1]) else api
local it = testkit.test()
local TEST, CASE, CHECK, FINISH = it.TEST, it.CASE, it.CHECK, it.FINISH
type Entity = api.Entity
type Iterator = () -> Entity?

local function collect(iterator: Iterator): { Entity }
    local result: { Entity } = {}
    for entity in iterator do
        table.insert(result, entity)
    end
    return result
end

local function equal(actual: { Entity }, expected: { Entity }): boolean
    if #actual ~= #expected then
        return false
    end
    for i, entity in expected do
        if actual[i] ~= entity then
            return false
        end
    end
    return true
end

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

TEST("deleting ids with reentrant removal listeners", function()
    for _, deleting_relation in { false, true } do
        CASE(if deleting_relation then "delete the relation" else "delete the target")
        local world = ecs.world()
        local relation, target = world:entity(), world:entity()
        local pair = ecs.pair(relation, target)
        local holders = { world:entity(), world:entity(), world:entity() }
        for _, e in holders do
            world:add(e, pair)
        end
        local calls: { [Entity]: number } = {}
        local alive_in_callback = true
        world:removed(relation, function(e)
            calls[e] = (calls[e] or 0) + 1
            alive_in_callback = alive_in_callback and world:contains(e) and world:has(e, pair)
            if e == holders[1] then
                world:remove(holders[2], pair)
                world:delete(holders[3])
            end
        end)
        world:delete(if deleting_relation then relation else target)
        CHECK(calls[holders[1]] == 1 and calls[holders[2]] == 1 and calls[holders[3]] == 1)
        CHECK(alive_in_callback and #collect(world:each(pair)) == 0)
        CHECK(world:contains(holders[1]) and world:contains(holders[2]) and not world:contains(holders[3]))
    end
end)

TEST("a cascade reaches the same entity through ownership and ChildOf", function()
    CASE("a child hook deletes a sibling while the parent is being deleted")
    local world = ecs.world()
    local owner = world:entity()
    world:add(owner, ecs.pair(ecs.OnDeleteTarget, ecs.Delete))
    local value = world:component() :: api.Component<number>
    local parent = world:entity()
    local children = { world:entity(), world:entity(), world:entity() }
    local calls: { [Entity]: number } = {}
    for i, e in children do
        world:add(e, ecs.pair(owner, parent))
        world:add(e, ecs.pair(ecs.ChildOf, parent))
        world:set(e, value, i)
    end
    local query = world:query(value):cached()
    world:removed(value, function(e, _, deleting)
        CHECK(deleting == true and world:contains(e) and world:get(e, value) ~= nil)
        calls[e] = (calls[e] or 0) + 1
        if e == children[1] then
            world:delete(children[2])
            world:set(parent, value, 100)
        end
    end)
    world:delete(parent)
    for _, e in children do
        CHECK(calls[e] == 1 and not world:contains(e))
    end
    CHECK(query:count() == 0 and #collect(world:children(parent)) == 0)
end)

TEST("batch snapshots survive nested operations", function()
    CASE("new matches and replacements from a hook are not added to the outer batch")
    local world = ecs.world()
    local match, out, nested = world:entity(), world:entity(), world:entity()
    local first, last = world:entity(), world:entity()
    world:add(first, match)
    world:add(last, match)
    local added: { Entity } = {}
    local replacement: Entity? = nil
    world:added(out, function(e)
        table.insert(added, e)
        if e == first then
            world:delete(last)
            local fresh = world:entity()
            replacement = fresh
            world:add(fresh, match)
            world:query():with(match):add_all(nested)
        end
    end)
    world:query():with(match):add_all(out)
    CHECK(equal(added, { first }) and replacement ~= nil)
    CHECK(world:has(replacement :: Entity, nested) and not world:has(replacement :: Entity, out))
    CHECK(world:query():with(out):count() == 1)

    CASE("a nested remove_all cannot overwrite the remaining outer matches")
    local a, b = world:component(), world:component()
    for _ = 1, 70 do
        local e = world:entity()
        world:set(e, a, 1)
        world:set(e, b, 2)
    end
    local removed = 0
    world:removed(a, function()
        removed += 1
        world:query(b):remove_all(b)
    end)
    world:query(a):remove_all(a)
    CHECK(removed == 70 and world:query(a):count() == 0 and world:query(b):count() == 0)
end)

TEST("signals keep the listener list of each dispatch", function()
    CASE("disconnect the last listener, reconnect and dispatch inside the old listener")
    local world = ecs.world()
    local tag = world:entity()
    local log: { string } = {}
    local disconnect: () -> () = function() end
    disconnect = world:added(tag, function()
        table.insert(log, "old")
        disconnect()
        world:added(tag, function()
            table.insert(log, "new")
        end)
        world:add(world:entity(), tag)
    end)
    world:add(world:entity(), tag)
    world:add(world:entity(), tag)
    CHECK(table.concat(log, ",") == "old,new,new")

    CASE("a replacement listener receives the next member during target cleanup")
    local relation, target = world:entity(), world:entity()
    local linked = ecs.pair(relation, target)
    local members = { world:entity(), world:entity(), world:entity() }
    for _, e in members do
        world:add(e, linked)
    end
    local old_calls, new_calls = 0, 0
    local off: () -> () = function() end
    off = world:removed(relation, function()
        old_calls += 1
        off()
        world:removed(relation, function()
            new_calls += 1
        end)
    end)
    world:delete(target)
    CHECK(old_calls == 1 and new_calls == 2)
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

TEST("callback errors keep their documented propagation", function()
    CASE("a failing hook aborts the operation with its original error")
    local world = ecs.world()
    local tag = world:entity()
    world:added(tag, function()
        error("sentinel callback failure")
    end)
    local ok, message = pcall(function()
        world:add(world:entity(), tag)
    end)
    CHECK(not ok and string.find(tostring(message), "sentinel callback failure", 1, true) ~= nil)
    -- The contract treats this world as unusable; no further operation is attempted on it.
end)

assert(FINISH() == 0, "some edge cases failed")
