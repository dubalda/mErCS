--!strict
--[[
    Behavior cases: hooks and signals in reentrant operations: removal listeners that remove
    the pair of another holder or delete it while a target or a relation is deleted (each event
    once, the entity and its pair present in the callback); a listener that disconnects the last
    listener and connects a replacement (the replacement gets the next events, also during
    target cleanup); and an error raised by a hook, which aborts the operation with its error.
    The next world:tick drops what the error left: a removal, a clear, a delete or a cascade that
    did not finish, the target being cleaned up, the pair an exclusive relation replaced; the
    entities the cascade had queued are deleted, and the next changes work as before.

    An OnChange hook reads the new value through world:get, from world:set and from set_all. A
    listener of an id hears every addition of it, also when the id was used before as a tag and
    as a relation.

    Signals reach the listeners connected now: after listeners were disconnected and new ones
    connected, disconnecting an earlier one stops that one only. A disconnected listener or
    monitor is not kept: what its callbacks hold is collected while the world lives, and nothing
    of it fires afterwards.

    Deleting an id: a holder that the cleanup passed reads no value of the id (a set gives the id
    back: an addition, which the cleanup removes again). An id made alive again
    (`world:entity(id)`, or the same id after the generations of its slot went round) has none
    of the hooks of its old components; its signal listeners hear it again. A monitor sees an
    entity leave and a new entity in its slot enter when a removal listener deletes the entity
    and makes the new one, whatever the order of the monitor and the listener; a monitor
    callback that makes the slot of the deleted entity alive keeps it (the next new entity takes
    another slot).

    Listeners that change the entity of their own event: a removal hook or listener that
    deletes or clears its entity runs once, for the removal, and so does a removal listener of a
    deleted id that deletes each member; an add of the id being removed, from its own hook, does
    nothing (the removal completes); an add that a listener takes back (an excluded id or
    Disabled removed again) leaves a monitor of the query as it was, and its next exit is
    reported.

    A clear or a delete notifies every id of the entity once, also an id that a later hook
    removes again (that removal does nothing: the clear removes it); an id that a hook gives the
    entity meanwhile goes with the others, without its removal hooks. A monitor sees an entity
    leave when a listener deletes it during an exclusive replacement, whatever their order, and
    enter when a listener adds a term while Disabled is being removed.
]]

local api = require("@lib")
local support = require("./support")
local gc = require("@bench/gc")

type Entity = api.Entity

return function(spec: support.Spec)
    local ecs, TEST, CASE, CHECK = spec.ecs, spec.TEST, spec.CASE, spec.CHECK
    local collect = support.collect

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

    TEST("a clear or a delete notifies every id once", function()
        for _, debug in { false, true } do
            local kind = if debug then " (debug world)" else ""
            for _, how in { "clear", "delete" } do
                CASE(`{how}: an id that a removal hook gives the entity goes without its removal hooks{kind}`)
                do
                    local world = ecs.world(debug)
                    local A, Tag = world:entity(), world:entity()
                    local e = world:entity()
                    world:add(e, A)
                    local added, removed = 0, 0
                    world:added(Tag, function()
                        added += 1
                    end)
                    world:removed(Tag, function()
                        removed += 1
                    end)
                    local once = true
                    world:removed(A, function(entity)
                        if once then
                            once = false
                            world:add(entity, Tag)
                        end
                    end)
                    if how == "clear" then
                        world:clear(e)
                    else
                        world:delete(e)
                    end
                    CHECK(added == 1 and removed == 0)
                    CHECK(if how == "clear" then world:contains(e) and not world:has(e, Tag) else not world:contains(e))
                end

                CASE(`{how}: an id notified already and removed again by a later hook is notified once{kind}`)
                do
                    local world = ecs.world(debug)
                    local B = world:entity() -- older: its hook runs first
                    local A = world:entity()
                    local e = world:entity()
                    world:add(e, B)
                    world:add(e, A)
                    local heard = 0
                    world:removed(B, function()
                        heard += 1
                    end)
                    world:removed(A, function(entity)
                        world:remove(entity, B)
                    end)
                    if how == "clear" then
                        world:clear(e)
                    else
                        world:delete(e)
                    end
                    CHECK(heard == 1)
                end
            end

            for _, monitor_first in { true, false } do
                local order = if monitor_first then "made before" else "made after"
                CASE(`a monitor {order} the listener sees an entity deleted in an exclusive replacement leave{kind}`)
                local world = ecs.world(debug)
                local X = world:entity()
                world:add(X, ecs.Exclusive)
                local a, b, e = world:entity(), world:entity(), world:entity()
                world:add(e, ecs.pair(X, a))
                local query = world:query(ecs.pair(X, ecs.Wildcard))
                local inside: { [Entity]: boolean } = { [e] = true }
                local function watch()
                    local monitor = query:monitor()
                    monitor.added(function(entity)
                        inside[entity] = true
                    end)
                    monitor.removed(function(entity)
                        inside[entity] = nil
                    end)
                end
                if monitor_first then
                    watch()
                end
                world:removed(X, function(entity)
                    if entity == e then
                        world:delete(entity)
                    end
                end)
                if not monitor_first then
                    watch()
                end
                world:add(e, ecs.pair(X, b))
                CHECK(not world:contains(e) and inside[e] == nil)
            end

            CASE(`a monitor sees an entity enter when a listener adds a term while Disabled is removed{kind}`)
            do
                local world = ecs.world(debug)
                local Needed, Extra = world:entity(), world:entity()
                local e = world:entity()
                world:add(e, Needed)
                world:add(e, ecs.Disabled)
                local query = world:query(Needed, Extra)
                local monitor = query:monitor()
                local inside: { [Entity]: boolean } = {}
                monitor.added(function(entity)
                    inside[entity] = true
                end)
                monitor.removed(function(entity)
                    inside[entity] = nil
                end)
                world:removed(ecs.Disabled, function(entity)
                    world:add(entity, Extra)
                end)
                world:remove(e, ecs.Disabled)
                CHECK(query:has(e) and inside[e] == true)
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
        -- the calls of this frame may be half done; the next world:tick restores the world (below)
    end)

    TEST("world:tick after an error raised by a callback", function()
        -- a callback that raises an error the first time it runs
        local function failing_once(): (...any) -> ()
            local armed = true
            return function()
                if armed then
                    armed = false
                    error("a bug in a hook", 0)
                end
            end
        end
        -- a ChildOf chain under a new root: the root first
        local function chain(world: any, depth: number): { Entity }
            local list = { world:entity() }
            for i = 1, depth do
                local child = world:entity()
                world:add(child, ecs.pair(ecs.ChildOf, list[i]))
                list[i + 1] = child
            end
            return list
        end
        local function alive(world: any, list: { Entity }, first: number, last: number): number
            local n = 0
            for i = first, last do
                if world:contains(list[i]) then
                    n += 1
                end
            end
            return n
        end

        for _, debug in { false, true } do
            local kind = if debug then " (a debug world reports the tick)" else ""
            CASE(`a removal whose hook failed: after the tick the pair can be removed{kind}`)
            local world = ecs.world(debug)
            local Tag, e = world:entity(), world:entity()
            world:add(e, Tag)
            world:set(Tag, ecs.OnRemove, failing_once())
            CHECK(not pcall(world.remove, world, e, Tag))
            world:tick()
            world:remove(e, Tag)
            CHECK(not world:has(e, Tag))
        end

        CASE("a clear whose hook failed: after the tick, a clear and a delete of the entity run its hooks")
        do
            local world = ecs.world()
            local Tag, Other, e = world:entity(), world:entity(), world:entity()
            world:add(e, Tag)
            world:add(e, Other)
            world:set(Tag, ecs.OnRemove, failing_once())
            local heard = 0
            world:removed(Other, function()
                heard += 1
            end)
            CHECK(not pcall(world.clear, world, e))
            world:tick()
            heard = 0
            world:clear(e)
            CHECK(heard == 1 and not world:has(e, Tag) and not world:has(e, Other))
            world:add(e, Other)
            world:delete(e)
            CHECK(heard == 2 and not world:contains(e))
        end

        CASE("a delete whose hook failed: after the tick, the entity is deleted again with its hooks")
        do
            local world = ecs.world()
            local Tag, Other, e = world:entity(), world:entity(), world:entity()
            world:add(e, Tag)
            world:add(e, Other)
            world:set(Tag, ecs.OnRemove, failing_once())
            local heard = 0
            world:removed(Other, function()
                heard += 1
            end)
            CHECK(not pcall(world.delete, world, e))
            world:tick()
            world:delete(e)
            CHECK(heard == 1 and not world:contains(e))
        end

        CASE("a cascade whose hook failed: after the tick, cascades deeper than 100 levels are deleted whole")
        do
            local world = ecs.world()
            local Tag = world:entity()
            local parent, child = world:entity(), world:entity()
            world:add(child, ecs.pair(ecs.ChildOf, parent))
            world:add(child, Tag)
            world:set(Tag, ecs.OnRemove, failing_once())
            CHECK(not pcall(world.delete, world, parent))
            world:tick()
            local list = chain(world, 150)
            world:delete(list[1])
            CHECK(alive(world, list, 1, #list) == 0)
        end

        CASE("a cascade that failed past 100 levels: the tick deletes the entities it had queued")
        do
            local world = ecs.world()
            local list = chain(world, 150)
            -- the entity 101 levels down is queued, then its removal listener fails
            local fail = failing_once()
            world:removed(ecs.ChildOf, function(entity)
                if entity == list[102] then
                    fail()
                end
            end)
            CHECK(not pcall(world.delete, world, list[1]))
            CHECK(alive(world, list, 102, #list) == #list - 101)
            world:tick()
            CHECK(alive(world, list, 102, #list) == 0)
        end

        CASE("a target whose cleanup failed: after the tick, (*, T) follows its pairs again")
        do
            local world = ecs.world()
            local R, T = world:entity(), world:entity()
            local a, b = world:entity(), world:entity()
            world:add(a, ecs.pair(R, T))
            world:add(b, ecs.pair(R, T))
            local any_relation = world:query(ecs.pair(ecs.Wildcard, T)):cached()
            CHECK(any_relation:count() == 2)
            world:set(R, ecs.OnRemove, failing_once())
            CHECK(not pcall(world.delete, world, T))
            world:tick()
            world:remove(a, ecs.pair(R, T))
            world:remove(b, ecs.pair(R, T))
            CHECK(any_relation:count() == 0 and #support.collect(world:query(ecs.pair(ecs.Wildcard, T))) == 0)
        end

        CASE("an exclusive replacement whose hook failed under a monitor: after the tick, the monitor sees the exit")
        do
            local world = ecs.world()
            local R = world:entity()
            world:add(R, ecs.Exclusive)
            local a, b, e = world:entity(), world:entity(), world:entity()
            world:add(e, ecs.pair(R, a))
            local query = world:query(ecs.pair(R, ecs.Wildcard))
            local monitor = query:monitor()
            local exits = 0
            monitor.removed(function()
                exits += 1
            end)
            world:set(R, ecs.OnRemove, failing_once())
            CHECK(not pcall(world.add, world, e, ecs.pair(R, b)))
            world:tick()
            world:delete(e)
            CHECK(exits == 1 and not query:has(e))
        end

        CASE("a removal listener of Component that fails in the undo of a refused add: later refusals hold")
        do
            local world = ecs.world()
            local e, Used = world:entity(), world:entity()
            world:add(e, Used)
            world:removed(ecs.Component, failing_once())
            CHECK(not pcall(world.add, world, Used, ecs.Component))
            world:tick()
            local Health = world:component()
            world:set(e, Health, 1)
            CHECK(not pcall(world.remove, world, Health, ecs.Component))
            CHECK(world:has(Health, ecs.Component) and world:get(e, Health) == 1)
        end
    end)

    TEST("signals reach the listeners connected now", function()
        for _, kind in { "added", "changed", "removed" } do
            CASE(`{kind}: a listener disconnected after the list changed is the one that stops`)
            local world = ecs.world()
            local C = world:component()
            local hook = if kind == "added" then ecs.OnAdd elseif kind == "changed" then ecs.OnChange else ecs.OnRemove
            local hook_runs = 0
            world:set(C, hook, function()
                hook_runs += 1
            end)
            local connect: any = (world :: any)[kind]
            local heard: { string } = {}
            local function listener(name: string): () -> ()
                return function()
                    table.insert(heard, name)
                end
            end
            local off_a = connect(world, C, listener("A"))
            local off_b = connect(world, C, listener("B"))
            off_a()
            connect(world, C, listener("A2"))
            connect(world, C, listener("C"))
            off_b()
            -- one event of the kind
            local function fire()
                local e = world:entity()
                world:set(e, C, 1)
                if kind == "changed" then
                    world:set(e, C, 2)
                elseif kind == "removed" then
                    world:remove(e, C)
                end
            end
            for round = 1, 2 do
                table.clear(heard)
                fire()
                table.sort(heard)
                CHECK(table.concat(heard, ",") == "A2,C" and hook_runs == round)
            end
        end
    end)

    TEST("disconnected listeners and monitors are not kept", function()
        local world = ecs.world()
        local C = world:component()
        -- what the callbacks hold, through weak references: the calls below return before a
        -- collection, so that no stack slot of the test keeps it
        local held = setmetatable({}, { __mode = "v" }) :: { [string]: any }

        CASE("a disconnected listener and what it holds are collected while the world lives")
        local function listen_once()
            local payload = {}
            held.listener = payload
            local disconnect = world:added(C, function()
                local _ = payload
            end)
            disconnect()
        end
        listen_once()
        gc.full()
        CHECK(held.listener == nil)

        CASE("disconnecting one of two listeners keeps the other, which still hears")
        local heard = 0
        local function listen_twice(): () -> ()
            local first, second = {}, {}
            held.first, held.second = first, second
            local off_first = world:added(C, function()
                local _ = first
            end)
            world:added(C, function()
                local _ = second
                heard += 1
            end)
            return off_first
        end
        listen_twice()()
        gc.full()
        world:set(world:entity(), C, 1)
        CHECK(held.first == nil and held.second ~= nil and heard == 1)

        CASE("a disconnected monitor and its callbacks are collected")
        local function monitor_once()
            local payload = {}
            held.monitor = payload
            local monitor = world:query(C):monitor()
            monitor.added(function()
                local _ = payload
            end)
            monitor.disconnect()
        end
        monitor_once()
        gc.full()
        CHECK(held.monitor == nil)

        CASE("monitors made and disconnected many times leave nothing that fires")
        local fired = 0
        for _ = 1, 50 do
            local monitor = world:query(C):monitor()
            monitor.added(function()
                fired += 1
            end)
            monitor.removed(function()
                fired += 1
            end)
            monitor.disconnect()
        end
        local e = world:entity()
        world:set(e, C, 1)
        world:remove(e, C)
        CHECK(fired == 0)
    end)

    TEST("listeners that change the entity of their own event", function()
        for _, debug in { false, true } do
            local kind = if debug then " (debug world)" else ""
            for _, hook in { false, true } do
                local by = if hook then "an OnRemove hook" else "a removal listener"
                CASE(`{by} that deletes its entity runs once, for the removal{kind}`)
                local world = ecs.world(debug)
                local Tag = world:entity()
                local e = world:entity()
                world:add(e, Tag)
                local flags: { boolean } = {}
                local function on_remove(entity: any, _: any, deleting: boolean?)
                    table.insert(flags, deleting == true)
                    world:delete(entity)
                end
                if hook then
                    world:set(Tag, ecs.OnRemove, on_remove)
                else
                    world:removed(Tag, on_remove)
                end
                world:remove(e, Tag)
                CHECK(#flags == 1 and flags[1] == false and not world:contains(e))
            end

            CASE(`an excluded id that a listener removes again leaves the monitor of the query as it was{kind}`)
            local world = ecs.world(debug)
            local Required, Excluded = world:entity(), world:entity()
            local e = world:entity()
            world:add(e, Required)
            world:added(Excluded, function(entity)
                world:remove(entity, Excluded)
            end)
            local query = world:query(Required):without(Excluded)
            local monitor = query:monitor()
            local adds, removes = 0, 0
            monitor.added(function()
                adds += 1
            end)
            monitor.removed(function()
                removes += 1
            end)
            world:add(e, Excluded)
            CHECK(query:has(e) and not world:has(e, Excluded) and adds == 0 and removes == 0)

            CASE(`then the entity leaves the query: the monitor reports the exit{kind}`)
            world:remove(e, Required)
            CHECK(not query:has(e) and adds == 0 and removes == 1)

            CASE(`an OnRemove hook that clears its entity runs once{kind}`)
            do
                local cleared = ecs.world(debug)
                local Tag, Other = cleared:entity(), cleared:entity()
                local entity = cleared:entity()
                cleared:add(entity, Tag)
                cleared:add(entity, Other)
                local runs = 0
                cleared:set(Tag, ecs.OnRemove, function(holder: any)
                    runs += 1
                    cleared:clear(holder)
                end)
                cleared:remove(entity, Tag)
                CHECK(runs == 1 and cleared:contains(entity) and #cleared:ids(entity) == 0)
            end

            CASE(`a removal listener of a deleted id that deletes each member runs once per member{kind}`)
            do
                local doomed = ecs.world(debug)
                local Tag = doomed:entity()
                local members = { doomed:entity(), doomed:entity(), doomed:entity() }
                for _, member in members do
                    doomed:add(member, Tag)
                end
                local calls: { [Entity]: number } = {}
                doomed:removed(Tag, function(member)
                    calls[member] = (calls[member] or 0) + 1
                    doomed:delete(member)
                end)
                doomed:delete(Tag)
                for _, member in members do
                    CHECK(calls[member] == 1 and not doomed:contains(member))
                end
            end

            CASE(`an add of the id being removed, from its own OnRemove, does nothing: the removal completes{kind}`)
            do
                local again = ecs.world(debug)
                local Tag, entity = again:entity(), again:entity()
                again:add(entity, Tag)
                local runs = 0
                again:set(Tag, ecs.OnRemove, function(holder: any)
                    runs += 1
                    again:add(holder, Tag)
                end)
                again:remove(entity, Tag)
                CHECK(runs == 1 and not again:has(entity, Tag))
            end

            CASE(`Disabled that a listener removes again leaves the monitor as it was; the exit comes later{kind}`)
            do
                local hidden = ecs.world(debug)
                local Needed = hidden:entity()
                local entity = hidden:entity()
                hidden:add(entity, Needed)
                hidden:added(ecs.Disabled, function(holder)
                    hidden:remove(holder, ecs.Disabled)
                end)
                local needed = hidden:query(Needed)
                local watch = needed:monitor()
                local entries, exits = 0, 0
                watch.added(function()
                    entries += 1
                end)
                watch.removed(function()
                    exits += 1
                end)
                hidden:add(entity, ecs.Disabled)
                CHECK(needed:has(entity) and not hidden:has(entity, ecs.Disabled) and entries == 0 and exits == 0)
                hidden:remove(entity, Needed)
                CHECK(entries == 0 and exits == 1)
            end
        end
    end)

    TEST("deleted ids and reused slots", function()
        for _, debug in { false, true } do
            local kind = if debug then " (debug world)" else ""
            for _, pair_case in { false, true } do
                CASE(
                    `a holder that the cleanup passed reads no value, and a set gives the id back{if pair_case
                        then " (the target of a pair)"
                        else ""}{kind}`
                )
                local world = ecs.world(debug)
                local Relation = world:component() :: api.Component<number>
                local target = world:entity()
                local id: any = if pair_case then ecs.pair(Relation, target) else Relation
                local first, second = world:entity(), world:entity()
                world:set(first, id, 10)
                world:set(second, id, 20)
                local retried, stale = false, true
                local additions, changes, removals = 0, 0, 0
                world:added(Relation, function()
                    additions += 1
                end)
                world:changed(Relation, function()
                    changes += 1
                end)
                world:removed(Relation, function(entity)
                    removals += 1
                    if entity == second and not retried then
                        retried = true
                        stale = world:has(first, id) or world:get(first, id) ~= nil
                        world:set(first, id, 99)
                    end
                end)
                world:delete(if pair_case then target else Relation)
                CHECK(retried and not stale)
                CHECK(additions == 1 and changes == 0 and removals == 3)
            end

            for _, field in { "OnAdd", "OnChange", "OnRemove" } do
                CASE(`an id made alive again has no {field} of its old components, its listeners stay{kind}`)
                local world = ecs.world(debug)
                local Value = world:component() :: api.Component<number>
                local hook_calls, listener_calls = 0, 0
                local function hook()
                    hook_calls += 1
                end
                local function listener()
                    listener_calls += 1
                end
                if field == "OnAdd" then
                    world:set(Value, ecs.OnAdd, hook)
                    world:added(Value, listener)
                elseif field == "OnChange" then
                    world:set(Value, ecs.OnChange, hook)
                    world:changed(Value, listener)
                else
                    world:set(Value, ecs.OnRemove, hook)
                    world:removed(Value, listener)
                end
                world:delete(Value)
                world:entity(Value)
                world:add(Value, ecs.Component)
                local e = world:entity()
                world:set(e, Value, 1)
                if field == "OnChange" then
                    world:set(e, Value, 2)
                elseif field == "OnRemove" then
                    world:remove(e, Value)
                end
                CHECK(hook_calls == 0 and listener_calls == 1)
            end

            CASE(`the same id after the generations of its slot went round has no hooks of its old life{kind}`)
            do
                local world = ecs.world(debug)
                local holder = world:entity()
                local id = world:entity()
                local hook_calls, listener_calls = 0, 0
                world:set(id, ecs.OnAdd, function()
                    hook_calls += 1
                end)
                world:added(id, function()
                    listener_calls += 1
                end)
                world:delete(id)
                -- the slot is given again until its generations come back to the id
                local again = world:entity()
                while again ~= id do
                    world:delete(again)
                    again = world:entity()
                end
                world:add(holder, id)
                CHECK(world:contains(id) and hook_calls == 0 and listener_calls == 1)
            end

            CASE(`a monitor callback that makes the slot of the deleted entity alive keeps it{kind}`)
            do
                local world = ecs.world(debug)
                local Tag = world:entity()
                local Data = world:component() :: api.Component<number>
                local e = world:entity()
                world:add(e, Tag)
                local revived: Entity? = nil
                world:removed(Tag, function()
                    local monitor = world:query(Tag):monitor()
                    monitor.removed(function(removed)
                        if revived == nil and not world:contains(removed) then
                            local made = world:entity(ecs.ECS_GENERATION_INC(removed))
                            revived = made
                            world:set(made, Data, 99)
                        end
                    end)
                end)
                world:delete(e)
                local next_one = world:entity()
                CHECK(revived ~= nil and world:contains(revived :: Entity) and next_one ~= revived)
                CHECK(world:get(next_one, Data) == nil and world:get(revived :: Entity, Data) == 99)
            end

            for _, operation in { "remove", "delete" } do
                for _, monitor_first in { true, false } do
                    CASE(
                        `{operation}: a removal listener deletes the entity and gives its slot to a new one, the monitor {if monitor_first
                            then "before"
                            else "after"} the listener{kind}`
                    )
                    local world = ecs.world(debug)
                    local Tag = world:entity()
                    local old = world:entity()
                    world:add(old, Tag)
                    local query = world:query():with(Tag)
                    local inside: { [Entity]: boolean } = { [old] = true }
                    local entries, exits = 0, 0
                    local function watch()
                        local monitor = query:monitor()
                        monitor.added(function(entity)
                            entries += 1
                            inside[entity] = true
                        end)
                        monitor.removed(function(entity)
                            exits += 1
                            inside[entity] = nil
                        end)
                    end
                    if monitor_first then
                        watch()
                    end
                    local fresh: Entity? = nil
                    world:removed(Tag, function(entity)
                        if fresh == nil then
                            world:delete(entity)
                            local made = world:entity()
                            fresh = made
                            world:add(made, Tag)
                        end
                    end)
                    if not monitor_first then
                        watch()
                    end
                    if operation == "remove" then
                        world:remove(old, Tag)
                    else
                        world:delete(old)
                    end
                    local new = fresh :: Entity
                    CHECK(ecs.ECS_ID(new) == ecs.ECS_ID(old) and query:has(new))
                    CHECK(inside[new] == true and inside[old] == nil and entries == 1 and exits == 1)
                end
            end
        end
    end)

    TEST("what hooks and listeners see", function()
        for _, debug in { false, true } do
            local kind = if debug then " (debug world)" else ""
            CASE(`an OnChange hook reads the new value through world:get{kind}`)
            do
                local world = ecs.world(debug)
                local C = world:component() :: api.Component<number>
                local seen: { [string]: number? } = {}
                local how = ""
                world:set(C, ecs.OnChange, function(entity)
                    seen[how] = world:get(entity, C)
                end)
                local e = world:entity()
                world:set(e, C, 1)
                how = "set"
                world:set(e, C, 4)
                how = "set_all"
                world:query(C):set_all(C, 7)
                CHECK(seen.set == 4 and seen.set_all == 7)
            end

            for _, before in { "a tag", "a relation", "a tag and a relation" } do
                CASE(`an addition listener hears every addition of an id used before as {before}{kind}`)
                local world = ecs.world(debug)
                local A, B = world:component(), world:component()
                if before ~= "a relation" then
                    world:add(world:entity(), A)
                end
                if before ~= "a tag" then
                    world:add(world:entity(), ecs.pair(A, B))
                end
                local heard = 0
                world:added(A, function()
                    heard += 1
                end)
                local e = world:entity()
                world:add(e, A)
                world:add(e, ecs.pair(A, B))
                CHECK(heard == 2)
            end
        end
    end)
end
