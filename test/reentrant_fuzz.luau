--!strict
--[[
    Randomized test of nested changes: hooks, signal listeners and monitor callbacks that change
    the world while it changes. A callback changes the entity of its event or another one, the
    id of its event or another: it adds, removes, toggles and sets ids, adds the pairs of a
    relation, of an exclusive relation and of ChildOf, gives an entity to others as an id, clears
    and deletes entities (also the ids and the targets being deleted), makes entities (also right
    after a delete, in the freed slot), makes explicit ids alive over live entities and deleted
    ids alive again, runs batch operations with ids and pairs that its callbacks may delete,
    disables and enables entities. Half of the entities used as ids are components. A callback acts with a probability, at most MAX_DEPTH levels deep and at
    most MAX_NESTED times per operation of the run.

    There is no model of what the callbacks do: after every operation the world must agree with
    itself.
    - Every addition and removal of an id is notified once: for every entity and id seen in an
      event, the additions less the removals are 1 when the entity has the id, otherwise 0 (0
      for a dead entity and for a dead id). An id that the hooks give an entity during its own
      clear or delete goes without its removal hooks: its addition may stay unmatched.
    - No live entity has a dead id or a pair with a dead element, and world:ids reads every live
      entity.
    - An exclusive relation and ChildOf have at most one target per entity.
    - world:has, world:each, queries and their counts agree for the tags, a component and
      Disabled.
    - The members of every monitor (the entities that entered less those that left) are the
      live matches of its query.
    - After each world:tick, a change filter returns only live entities that had that change in
      the tick (as the listeners heard it), and the created filter only entities made in it.
    - With "range", every new id is inside the range of the world, also after ids outside it were
      made alive and deleted.

    Run from the repository root (seed, number of rounds and the flags are optional; "debug" uses
    a debug world, which checks every call and every patched match list; "pool" makes half of the
    entities from a slot pool; "range" sets a range first and makes ids below it alive; an
    argument with a slash is the module path of the library to run on):
        luau test/reentrant_fuzz.luau
        luau test/reentrant_fuzz.luau -a 7 200 debug pool range
        luau test/reentrant_fuzz.luau -a 7 200 ../tmp/previous/mercs
]]

local args = { ... }
local ecs = require("../src")
for _, argument in args do
    if string.find(tostring(argument), "/", 1, true) then
        ecs = (require :: any)(argument)
    end
end
local seed = tonumber(args[1]) or 20261001
local rounds = tonumber(args[2]) or 60
local debug_world = table.find(args, "debug") ~= nil
local pooled = table.find(args, "pool") ~= nil
local ranged = table.find(args, "range") ~= nil
local first_seed = seed

local function next_int(low: number, high: number): number
    seed = seed * 16807 % 2147483647
    return low + seed % (high - low + 1)
end

local function chance(percent: number): boolean
    return next_int(1, 100) <= percent
end

local pair = ecs.pair
local Wildcard = ecs.Wildcard
local ChildOf = ecs.ChildOf
local Disabled = ecs.Disabled

-- operations of the run per round, nested actions per operation, levels of nesting
local OPERATIONS = 25
local MAX_NESTED = 12
local MAX_DEPTH = 3
-- the range of "range", and the slots below it that ids of "another world" take
local RANGE_FIRST, RANGE_LAST = 1000, 1000000
local FOREIGN_FIRST, FOREIGN_LAST = 600, 990

local world: any = ecs.world(debug_world)
if ranged then
    world:range(RANGE_FIRST, RANGE_LAST)
end
local pool: any = if pooled then world:pool() else nil

-- (a saved release without world:toggle, query:toggle_all or creation tracking: toggles are
-- made of add and remove, and the created filter is left out)
local has_toggle = world.toggle ~= nil
local has_created = world.track_created ~= nil
local function toggle(e: any, id: any)
    if has_toggle then
        world:toggle(e, id)
    elseif world:has(e, id) then
        world:remove(e, id)
    else
        world:add(e, id)
    end
end

local C1: any = world:component()
local C2: any = world:component()
local T1: any = world:entity()
local T2: any = world:entity()
local T3: any = world:entity()
-- R: deleting a target deletes its sources; P: the default policy (the pairs are removed)
local R: any = world:entity()
world:add(R, pair(ecs.OnDeleteTarget, ecs.Delete))
local P: any = world:entity()
local X: any = world:entity()
world:add(X, ecs.Exclusive)

-- what happened so far, for the message of a failure
local trace: { string } = {}
local depth = 0
local round_now, operation_now = 0, 0

local function name(e: any): string
    return `{ecs.ECS_ID(e)}v{ecs.ECS_GENERATION(e)}`
end

local NAMES: { [any]: string } = {
    [C1] = "C1",
    [C2] = "C2",
    [T1] = "T1",
    [T2] = "T2",
    [T3] = "T3",
    [R] = "R",
    [P] = "P",
    [X] = "X",
    [ChildOf] = "ChildOf",
    [Disabled] = "Disabled",
}

local function id_name(id: any): string
    if ecs.IS_PAIR(id) then
        local first = (world:alive_table() :: { number })[ecs.ECS_PAIR_FIRST(id)]
        local relation = if first and NAMES[first] then NAMES[first] else `#{ecs.ECS_PAIR_FIRST(id)}`
        return `({relation}, #{ecs.ECS_PAIR_SECOND(id)})`
    end
    return NAMES[id] or name(id)
end

local function note(text: string)
    table.insert(trace, string.rep("  ", depth) .. text)
    if #trace > 600 then
        table.move(trace, 301, #trace, 1)
        for i = #trace, #trace - 299, -1 do
            trace[i] = nil
        end
    end
end

local function fail(message: string)
    print(`reentrant fuzz: seed {first_seed}, round {round_now}, operation {operation_now}: {message}`)
    print("the last actions (nested ones indented):")
    for i = math.max(1, #trace - 80), #trace do
        print(trace[i])
    end
    error("reentrant fuzz failed", 0)
end

-- whether an id is alive: a live entity, or a pair whose elements are both alive
local function id_alive(id: any): boolean
    if ecs.IS_PAIR(id) then
        local alive = world:alive_table() :: { number }
        return (alive[ecs.ECS_PAIR_FIRST(id)] or 0) > 0 and (alive[ecs.ECS_PAIR_SECOND(id)] or 0) > 0
    end
    return world:contains(id)
end

-- the events heard by the listeners: additions less removals per entity and id, and the changes
-- of the tracked ids (T1, C1) and the entities made in the current tick
local balance: { [any]: { [any]: number } } = {}
local frame: { [string]: { [any]: boolean } } = {
    added_T1 = {},
    removed_T1 = {},
    added_C1 = {},
    changed_C1 = {},
    removed_C1 = {},
    created = {},
}

-- the entities whose clear (a call of the run) or delete (a removal callback with the delete
-- flag) runs, and how many times their hooks give them an id meanwhile (see check)
local clearing_now: { [any]: number } = {}
local deleting_now: { [any]: number } = {}
local given_while_cleared: { [any]: { [any]: number } } = {}

local function count(e: any, id: any, delta: number)
    local row = balance[e]
    if row == nil then
        row = {}
        balance[e] = row
    end
    row[id] = (row[id] or 0) + delta
end

local function watch(id: any)
    world:added(id, function(e: any, event_id: any)
        count(e, event_id, 1)
        if (clearing_now[e] or 0) > 0 or (deleting_now[e] or 0) > 0 then
            local row = given_while_cleared[e]
            if row == nil then
                row = {}
                given_while_cleared[e] = row
            end
            row[event_id] = (row[event_id] or 0) + 1
        end
    end)
    world:removed(id, function(e: any, event_id: any)
        count(e, event_id, -1)
    end)
end

-- the entities of the run (dead ones too); born orders them, so that ChildOf goes from an older
-- parent to a newer child and makes no cycle
local entities: { any } = {}
local born: { [any]: number } = {}
local born_count = 0
local entity_ids: { any } = {}
local foreign_used: { [number]: boolean } = {}

local function alive_entities(): { any }
    local list = {}
    for _, e in entities do
        if world:contains(e) then
            table.insert(list, e)
        end
    end
    return list
end

local function pick(list: { any }): any
    if #list == 0 then
        return nil
    end
    return list[next_int(1, #list)]
end

-- (a deleted id made alive again keeps its place)
local function adopt(e: any)
    if born[e] == nil then
        born_count += 1
        born[e] = born_count
        table.insert(entities, e)
    end
    frame.created[e] = true
end

local function make_entity(): any
    local e = if pool and chance(50) then pool:entity() else world:entity()
    if ranged then
        local slot = ecs.ECS_ID(e)
        if slot <= RANGE_FIRST or slot >= RANGE_LAST then
            fail(`a new id {name(e)} is outside the range ({RANGE_FIRST}, {RANGE_LAST})`)
        end
    end
    adopt(e)
    note(`make {name(e)}`)
    return e
end

-- an id of another world, below the range, made alive here (once per slot)
local function make_foreign(): any?
    for _ = 1, 8 do
        local slot = next_int(FOREIGN_FIRST, FOREIGN_LAST)
        if not foreign_used[slot] then
            foreign_used[slot] = true
            local e = world:entity(slot)
            adopt(e)
            note(`make the foreign id {name(e)}`)
            return e
        end
    end
    return nil
end

local act: (event_entity: any?, event_id: any?) -> ()
local nested_left = 0

-- a callback that acts with a probability, within the limits of nesting
local function reacting(label: string, percent: number, removal: boolean?): (...any) -> ()
    return function(e: any, id: any, deleting: any?)
        if depth < MAX_DEPTH and nested_left > 0 and chance(percent) then
            nested_left -= 1
            note(`{label}: {name(e)} {if id ~= nil then id_name(id) else ""}`)
            local deleted = removal == true and deleting == true
            if deleted then
                deleting_now[e] = (deleting_now[e] or 0) + 1
            end
            depth += 1
            act(e, id)
            depth -= 1
            if deleted then
                deleting_now[e] -= 1
            end
        end
    end
end

-- an entity used as an id by others (a tag, or half of the time a component), with listeners
-- that count and act
local function make_entity_id(): any
    local e: any
    if chance(50) then
        -- (not among the entities that operations change: a clear of a used component raises
        -- an error by design, see the Component trait)
        e = world:component()
        frame.created[e] = true
        note(`make the component {name(e)}`)
    else
        e = make_entity()
    end
    watch(e)
    world:added(e, reacting(`added {name(e)}`, 25))
    world:removed(e, reacting(`removed {name(e)}`, 35, true))
    table.insert(entity_ids, e)
    NAMES[e] = `E{name(e)}`
    return e
end

local function pick_tag(): any
    local k = next_int(1, 6)
    if k == 1 then
        return T1
    elseif k == 2 then
        return T2
    elseif k == 3 then
        return T3
    elseif k == 4 then
        return Disabled
    end
    local live = {}
    for _, e in entity_ids do
        if world:contains(e) then
            table.insert(live, e)
        end
    end
    return pick(live) or T3
end

function act(event_entity: any?, event_id: any?)
    local list = alive_entities()
    local e: any = if event_entity ~= nil
            and world:contains(event_entity)
            and chance(50)
        then event_entity
        else pick(list)
    if e == nil then
        e = make_entity()
    end
    local kind = next_int(1, 26)
    if kind <= 4 then
        local tag = pick_tag()
        local op = next_int(1, 3)
        if op == 1 then
            note(`add {id_name(tag)} to {name(e)}`)
            world:add(e, tag)
        elseif op == 2 then
            note(`remove {id_name(tag)} from {name(e)}`)
            world:remove(e, tag)
        else
            note(`toggle {id_name(tag)} on {name(e)}`)
            toggle(e, tag)
        end
    elseif kind <= 6 then
        local component = if chance(50) then C1 else C2
        if chance(70) then
            local value = next_int(1, 100)
            note(`set {id_name(component)} of {name(e)} to {value}`)
            world:set(e, component, value)
        elseif chance(50) then
            note(`add {id_name(component)} to {name(e)} without a value`)
            world:add(e, component)
        else
            note(`remove {id_name(component)} from {name(e)}`)
            world:remove(e, component)
        end
    elseif kind <= 8 then
        local relation = if chance(50) then R else P
        local target = pick(list)
        if target ~= nil and target ~= e and world:contains(target) then
            if chance(65) then
                note(`add ({id_name(relation)}, {name(target)}) to {name(e)}`)
                world:add(e, pair(relation, target))
            else
                note(`remove ({id_name(relation)}, {name(target)}) from {name(e)}`)
                world:remove(e, pair(relation, target))
            end
        else
            note(`remove ({id_name(relation)}, *) from {name(e)}`)
            world:remove(e, pair(relation, Wildcard))
        end
    elseif kind <= 10 then
        local target = pick(list)
        if target ~= nil and target ~= e and world:contains(target) and chance(75) then
            note(`add (X, {name(target)}) to {name(e)}`)
            world:add(e, pair(X, target))
        else
            note(`remove (X, *) from {name(e)}`)
            world:remove(e, pair(X, Wildcard))
        end
    elseif kind == 11 then
        local parent = pick(list)
        if parent ~= nil and parent ~= e and world:contains(parent) and born[parent] < born[e] then
            note(`add (ChildOf, {name(parent)}) to {name(e)}`)
            world:add(e, pair(ChildOf, parent))
        end
    elseif kind == 12 then
        -- the pair of the event again: added during its removal, removed during its addition
        if event_entity ~= nil and event_id ~= nil and world:contains(event_entity) and id_alive(event_id) then
            if chance(50) then
                note(`add the id of the event {id_name(event_id)} to {name(event_entity)}`)
                world:add(event_entity, event_id)
            else
                note(`remove the id of the event {id_name(event_id)} from {name(event_entity)}`)
                world:remove(event_entity, event_id)
            end
        end
    elseif kind == 13 then
        note(`clear {name(e)}`)
        clearing_now[e] = (clearing_now[e] or 0) + 1
        world:clear(e)
        clearing_now[e] -= 1
    elseif kind <= 15 then
        note(`delete {name(e)}`)
        world:delete(e)
    elseif kind == 16 then
        local victim = pick(entity_ids)
        if victim ~= nil and world:contains(victim) then
            note(`delete the id {id_name(victim)}`)
            world:delete(victim)
        end
    elseif kind == 17 then
        local made = make_entity()
        if chance(50) then
            local tag = pick_tag()
            note(`add {id_name(tag)} to the new {name(made)}`)
            world:add(made, tag)
        end
    elseif kind == 18 then
        -- e used as an id by another entity (for the first time, maybe while e is deleted)
        local holder = pick(list)
        if holder ~= nil and holder ~= e and world:contains(holder) and world:contains(e) then
            note(`add {name(e)} as an id to {name(holder)}`)
            world:add(holder, e)
        end
    elseif kind == 19 then
        note(`toggle Disabled on {name(e)}`)
        toggle(e, Disabled)
    elseif kind == 20 then
        -- an entity used as an id: a value when it is a component; a deleted one is ignored (a
        -- debug world raises an error for it: not given there)
        local id = pick(entity_ids)
        if id ~= nil and not world:contains(id) and not debug_world then
            local op = next_int(1, 3)
            note(
                `give the deleted id {id_name(id)} to {name(e)} ({if op == 1
                    then "add"
                    elseif op == 2 then "set"
                    else "toggle"})`
            )
            if op == 1 then
                world:add(e, id)
            elseif op == 2 then
                world:set(e, id, nil)
            else
                toggle(e, id)
            end
        elseif id ~= nil and world:contains(id) then
            if world:has(id, ecs.Component) then
                local value = next_int(1, 100)
                note(`set {id_name(id)} of {name(e)} to {value}`)
                world:set(e, id, value)
            else
                note(`add {id_name(id)} to {name(e)}`)
                world:add(e, id)
            end
        end
    elseif kind == 21 then
        -- a batch operation with an id that its callbacks may delete
        local id = pick(entity_ids)
        local base = if chance(50) then T1 else T2
        if id ~= nil and world:contains(id) then
            local op = next_int(1, 3)
            if op == 1 and world:has(id, ecs.Component) then
                note(`query({id_name(base)}):set_all({id_name(id)})`)
                world:query(base):set_all(id, next_int(1, 100))
            elseif op == 2 and has_toggle then
                note(`query({id_name(base)}):toggle_all({id_name(id)})`)
                world:query(base):toggle_all(id)
            else
                note(`query({id_name(base)}):add_all({id_name(id)})`)
                world:query(base):add_all(id)
            end
        end
    elseif kind == 22 then
        -- a batch operation with a pair whose target its callbacks may delete
        local target = pick(list)
        local relation = if chance(50) then R else P
        if target ~= nil and world:contains(target) then
            local id = pair(relation, target)
            if chance(50) and has_toggle then
                note(`query(T3):toggle_all({id_name(id)})`)
                world:query(T3):toggle_all(id)
            else
                note(`query(T3):add_all({id_name(id)})`)
                world:query(T3):add_all(id)
            end
        end
    elseif kind == 23 then
        -- an explicit id of a later generation over a live entity (its delete runs first)
        if world:contains(e) and ecs.ECS_GENERATION(e) < 1000 then
            local id = ecs.ECS_COMBINE(ecs.ECS_ID(e), ecs.ECS_GENERATION(e) + next_int(1, 3))
            note(`make the explicit id {name(id)} over {name(e)}`)
            world:entity(id)
            if world:contains(id) then
                adopt(id)
            end
        end
    elseif kind == 24 then
        -- a deleted id made alive again, also an older generation of its slot (an entity in its
        -- slot is deleted first; the newer ids of the slot stay dead)
        local id = pick(entity_ids)
        if id ~= nil and not world:contains(id) then
            note(`make the deleted id {id_name(id)} alive again`)
            world:entity(id)
            adopt(id)
        end
    elseif kind == 25 then
        -- the entity deleted and a new one made at once (it takes the freed slot), with the id
        -- of the event
        if world:contains(e) then
            note(`delete {name(e)} and make a new entity`)
            world:delete(e)
            local made = make_entity()
            if event_id ~= nil and id_alive(event_id) and not ecs.IS_PAIR(event_id) then
                note(`add the id of the event {id_name(event_id)} to the new {name(made)}`)
                world:add(made, event_id)
            end
        end
    else
        local value = next_int(1, 100)
        note(`set C1 of {name(e)} to {value}`)
        world:set(e, C1, value)
    end
end

-- monitors whose members are kept from their callbacks
type Watched = { label: string, query: any, members: { [any]: boolean } }
local monitors: { Watched } = {}
local function monitor(label: string, query: any, acts: boolean)
    local entry: Watched = { label = label, query = query, members = {} }
    local handle = query:monitor()
    local react = if acts then reacting(`monitor {label} entry`, 15) else nil
    handle.added(function(e: any)
        entry.members[e] = true
        if react then
            react(e, nil)
        end
    end)
    handle.removed(function(e: any)
        entry.members[e] = nil
    end)
    table.insert(monitors, entry)
end

-- the callbacks: hooks, listeners and the counting listeners of every id of the run; two
-- monitors listen before the other callbacks, two after them (a monitor that hears a change
-- first sees the entity before the other callbacks change it)
for _, id in { C1, C2, T1, T2, T3, R, P, X, ChildOf, Disabled } do
    watch(id)
end
monitor("T1 without T2", world:query(T1):without(T2), true)
monitor("(X, *)", world:query(pair(X, Wildcard)), false)
world:set(T1, ecs.OnAdd, reacting("OnAdd T1", 30))
world:set(T1, ecs.OnRemove, reacting("OnRemove T1", 30, true))
world:added(T2, reacting("added T2", 25))
world:removed(T2, reacting("removed T2", 30, true))
world:set(C1, ecs.OnChange, reacting("OnChange C1", 20))
world:removed(C2, reacting("removed C2", 20, true))
world:removed(R, reacting("removed R", 30, true))
world:added(P, reacting("added P", 20))
world:removed(P, reacting("removed P", 30, true))
world:added(X, reacting("added X", 25))
world:removed(X, reacting("removed X", 35, true))
world:removed(ChildOf, reacting("removed ChildOf", 25, true))
world:added(Disabled, reacting("added Disabled", 25))
world:removed(Disabled, reacting("removed Disabled", 20, true))

monitor("C1 with T3", world:query(C1):with(T3), false)
monitor("T2 and (P, *)", world:query(T2, pair(P, Wildcard)), true)

-- change tracking: the listeners log the changes of the tick, the filters must agree
world:track(T1)
world:track(C1)
if has_created then
    world:track_created()
end
world:added(T1, function(e: any)
    frame.added_T1[e] = true
end)
world:removed(T1, function(e: any)
    frame.removed_T1[e] = true
end)
world:added(C1, function(e: any)
    frame.added_C1[e] = true
end)
world:changed(C1, function(e: any)
    frame.changed_C1[e] = true
end)
world:removed(C1, function(e: any)
    frame.removed_C1[e] = true
end)
type Filter = { label: string, query: any, log: string }
local filters: { Filter } = {
    { label = "added(T1)", query = world:query():added(T1):cached(), log = "added_T1" },
    { label = "removed(T1)", query = world:query():removed(T1):cached(), log = "removed_T1" },
    { label = "added(C1)", query = world:query():added(C1):cached(), log = "added_C1" },
    { label = "changed(C1)", query = world:query():changed(C1):cached(), log = "changed_C1" },
    { label = "removed(C1)", query = world:query():removed(C1):cached(), log = "removed_C1" },
}
if has_created then
    table.insert(filters, { label = "created()", query = world:query():created():cached(), log = "created" })
end

local function tick_and_check()
    note("tick")
    world:tick()
    for _, filter in filters do
        local log = frame[filter.log]
        for e in filter.query do
            if not world:contains(e) then
                fail(`{filter.label} returns the dead {name(e)}`)
            end
            if not log[e] then
                fail(`{filter.label} returns {name(e)}, which had no such change in the tick`)
            end
        end
    end
    for key in frame do
        frame[key] = {}
    end
end

local function check()
    local list = alive_entities()

    -- an id that the hooks gave an entity during its own clear or delete went without its
    -- removal hooks: as many additions at most stay unmatched
    for e, given in given_while_cleared do
        local row = balance[e]
        if row ~= nil then
            for id, times in given do
                local expected = if world:contains(e) and id_alive(id) and world:has(e, id) then 1 else 0
                local excess = (row[id] or 0) - expected
                if excess > 0 and excess <= times then
                    row[id] = expected
                end
            end
        end
    end
    table.clear(given_while_cleared)

    -- every addition and removal notified once
    for e, row in balance do
        local alive = world:contains(e)
        for id, value in row do
            local expected = if alive and id_alive(id) and world:has(e, id) then 1 else 0
            if value ~= expected then
                fail(
                    `the events of {id_name(id)} on {name(e)}: {value} additions more than removals, expected {expected}`
                )
            end
        end
        if not alive then
            balance[e] = nil -- a dead id never comes back
        end
    end

    for _, e in list do
        -- no dead id, world:ids reads the entity
        local ok, ids = pcall(world.ids, world, e)
        if not ok then
            fail(`world:ids({name(e)}) raised an error: {ids}`)
        end
        for _, id in ids :: { any } do
            if not id_alive(id) then
                fail(`{name(e)} has the dead id {id_name(id)}`)
            end
        end
        -- one target of an exclusive relation
        for _, relation in { X, ChildOf } do
            local targets = 0
            for _ in world:targets(e, relation) do
                targets += 1
            end
            if targets > 1 then
                fail(`{name(e)} has {targets} targets of the exclusive {id_name(relation)}`)
            end
        end
    end

    -- has, each, queries and counts agree
    for _, id in { T1, T2, T3, C1, Disabled } do
        local holders: { [any]: boolean } = {}
        local held, visible = 0, 0
        for _, e in list do
            if world:has(e, id) then
                holders[e] = true
                held += 1
                if not world:has(e, Disabled) or id == Disabled then
                    visible += 1
                end
            end
        end
        local each = 0
        for e in world:each(id) do
            if not world:contains(e) then
                fail(`world:each({id_name(id)}) returns the dead {name(e)}`)
            elseif not holders[e] then
                fail(`world:each({id_name(id)}) returns {name(e)}, which does not have it`)
            end
            each += 1
        end
        if each ~= held then
            fail(`world:each({id_name(id)}) returns {each} entities, {held} have it`)
        end
        local query = world:query(id)
        local matched = 0
        for e in query do
            if not holders[e] then
                fail(`query({id_name(id)}) returns {name(e)}, which does not have it`)
            end
            matched += 1
        end
        if matched ~= visible or query:count() ~= visible then
            fail(`query({id_name(id)}) returns {matched} (count {query:count()}), {visible} match`)
        end
    end

    -- the members of every monitor are the live matches of its query
    for _, entry in monitors do
        for e in entry.members do
            if not world:contains(e) then
                fail(`the monitor of {entry.label} keeps the dead {name(e)}`)
            elseif not entry.query:has(e) then
                fail(`the monitor of {entry.label} keeps {name(e)}, which does not match`)
            end
        end
        for _, e in list do
            if entry.query:has(e) and not entry.members[e] then
                fail(`the monitor of {entry.label} misses {name(e)}`)
            end
        end
    end
end

local function operation()
    local live = alive_entities()
    if #live < 30 then
        make_entity()
    end
    local live_ids = 0
    for _, e in entity_ids do
        if world:contains(e) then
            live_ids += 1
        end
    end
    if live_ids < 4 then
        make_entity_id()
    end
    local kind = next_int(1, 100)
    if kind <= 4 then
        tick_and_check()
    elseif kind <= 8 then
        -- a batch operation over the matches of a query
        local op = next_int(1, 4)
        if op == 1 then
            note("query(T1):add_all(T3)")
            world:query(T1):add_all(T3)
        elseif op == 2 then
            note("query(T2):remove_all(T1)")
            world:query(T2):remove_all(T1)
        elseif op == 3 and has_toggle then
            note("query(C1):toggle_all(T2)")
            world:query(C1):toggle_all(T2)
        elseif op == 3 then
            note("query(C1):add_all(T2)")
            world:query(C1):add_all(T2)
        else
            note("query(T3, T2):delete_all()")
            world:query(T3, T2):delete_all()
        end
    elseif kind <= 10 and ranged then
        make_foreign()
    else
        act(nil, nil)
    end
end

for round = 1, rounds do
    round_now = round
    for o = 1, OPERATIONS do
        operation_now = o
        nested_left = MAX_NESTED
        depth = 0
        local ok, problem = pcall(operation)
        if not ok then
            if problem == "reentrant fuzz failed" then
                error(problem, 0) -- reported already
            end
            fail(`an operation raised an error: {problem}`)
        end
        check()
    end
end
tick_and_check()
check()
print(`reentrant fuzz: ok ({rounds} rounds of {OPERATIONS} operations)`)
