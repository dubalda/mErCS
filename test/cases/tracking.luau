--!strict
--[[
    Behavior cases: change tracking (world:track, world:tick and the change filters added,
    changed and removed).

    - What one tick records: an addition and a removal of the same id in one tick are both
      reported, whatever their order, and they do not cancel each other; a value set when the
      component is new is an addition and a later set is a change; a repeated add of a present
      id records nothing; two change filters on one query must both hold.
    - Batch operations on a tracked id record what they do: add_all and set_all additions and
      changes, remove_all removals; a delete records nothing, the entity is gone.
    - The depth of the history: a query that skipped ticks sees the changes of the last 7
      finished ticks, no older ones.
    - Creation tracking (world:track_created and the change filter created): the entities made
      since the previous run of a query (world:entity, a pool, world:entity(id) making an id
      alive) and still alive; a new entity in the slot of a deleted one counts; nothing made
      before the tracking started; the filter needs the tracking.
    - An entity that a listener deletes in its event takes its changes with it: the new entity
      in its slot does not get them, whether the id was tracked before or after the listener
      was connected.
    - A loop over a query with change filters returns every change also when the query cannot
      gather its matches first (more than 64 words of the driving record, more terms): as many
      as `count`, `each` and a cached query.
]]

local api = require("@lib")
local support = require("./support")

return function(spec: support.Spec)
    local ecs, TEST, CASE, CHECK = spec.ecs, spec.TEST, spec.CASE, spec.CHECK
    local collect, same = support.collect, support.same

    TEST("change tracking: what one tick records", function()
        local world = ecs.world()
        -- Base is not tracked: every entity of the cases has it, so that the queries below
        -- see the entities that lost the tracked ids
        local Base, C, T = world:component(), world:component(), world:entity()
        world:track(C)
        world:track(T)
        local added = world:query(Base):added(C):cached()
        local removed = world:query(Base):removed(C):cached()
        local changed = world:query(Base):changed(C):cached()
        local added_and_present = world:query(C):added(C):cached()
        local tag_added = world:query(Base):added(T):cached()
        local tag_removed = world:query(Base):removed(T):cached()
        local queries = { added, removed, changed, added_and_present, tag_added, tag_removed }

        local function fresh(): any
            local e = world:entity()
            world:set(e, Base, 0)
            return e
        end
        -- the changes so far become visible and every query takes them: the next tick starts clean
        local function settle()
            world:tick()
            for _, q in queries do
                collect(q)
            end
        end

        CASE("added and removed in one tick: an addition and a removal, and the id is gone")
        local e = fresh()
        settle()
        world:set(e, C, 1)
        world:remove(e, C)
        world:tick()
        CHECK(same(collect(added), { e }) and same(collect(removed), { e }))
        CHECK(#collect(changed) == 0 and #collect(added_and_present) == 0)

        CASE("removed and added again in one tick: a removal and an addition, and the id is there")
        e = fresh()
        world:set(e, C, 1)
        settle()
        world:remove(e, C)
        world:set(e, C, 2)
        world:tick()
        CHECK(same(collect(added), { e }) and same(collect(removed), { e }))
        CHECK(#collect(changed) == 0 and same(collect(added_and_present), { e }))
        CHECK(world:get(e, C) == 2)

        CASE("added, removed and added again in one tick: the last value stays")
        e = fresh()
        settle()
        world:set(e, C, 1)
        world:remove(e, C)
        world:set(e, C, 3)
        world:tick()
        CHECK(same(collect(added), { e }) and same(collect(removed), { e }))
        CHECK(same(collect(added_and_present), { e }) and world:get(e, C) == 3)

        CASE("a value set when the component is new is an addition; set again, a change")
        e = fresh()
        settle()
        world:set(e, C, 1)
        world:tick()
        CHECK(same(collect(added), { e }) and #collect(changed) == 0)
        world:set(e, C, 2)
        world:tick()
        CHECK(#collect(added) == 0 and same(collect(changed), { e }))

        CASE("set twice in the tick it is new: an addition and a change")
        e = fresh()
        settle()
        world:set(e, C, 1)
        world:set(e, C, 2)
        world:tick()
        CHECK(same(collect(added), { e }) and same(collect(changed), { e }))

        CASE("a repeated add of a present id records nothing")
        e = fresh()
        world:add(e, T)
        settle()
        world:add(e, T)
        world:tick()
        CHECK(#collect(tag_added) == 0 and #collect(tag_removed) == 0)

        CASE("a tag added and removed in one tick: an addition and a removal")
        e = fresh()
        settle()
        world:add(e, T)
        world:remove(e, T)
        world:tick()
        CHECK(same(collect(tag_added), { e }) and same(collect(tag_removed), { e }))

        CASE("two change filters on one query: an entity must pass both")
        local A, B = world:component(), world:component()
        world:track(A)
        world:track(B)
        local both = world:query(Base):added(A):changed(B):cached()
        local g, h = fresh(), fresh()
        world:set(g, B, 0)
        world:set(h, B, 0)
        world:tick()
        collect(both)
        world:set(g, A, 1)
        world:set(g, B, 1)
        world:set(h, A, 1) -- added, but B is not changed
        world:tick()
        CHECK(same(collect(both), { g }))
    end)

    TEST("change tracking of batch operations", function()
        local world = ecs.world()
        local Kind, C, T = world:component(), world:component(), world:entity()
        world:track(C)
        world:track(T)
        local list: { any } = {}
        for i = 1, 6 do
            list[i] = world:entity()
            world:set(list[i], Kind, i)
        end
        world:set(list[1], C, 0)
        world:set(list[2], C, 0)
        local tag_added = world:query(Kind):added(T):cached()
        local tag_removed = world:query(Kind):removed(T):cached()
        local added = world:query(Kind):added(C):cached()
        local changed = world:query(Kind):changed(C):cached()
        local removed = world:query(Kind):removed(C):cached()
        world:tick()
        for _, q in { tag_added, tag_removed, added, changed, removed } do
            collect(q)
        end

        CASE("add_all of a tracked tag: every match is an addition")
        world:query(Kind):add_all(T)
        world:tick()
        CHECK(same(collect(tag_added), list))

        CASE("set_all of a tracked component: an addition where it is new, a change where it was set")
        world:query(Kind):set_all(C, 5)
        world:tick()
        CHECK(same(collect(added), { list[3], list[4], list[5], list[6] }))
        CHECK(same(collect(changed), { list[1], list[2] }))

        CASE("remove_all of a query and world:remove_all: every holder is a removal")
        world:query(Kind):remove_all(T)
        world:remove_all(C)
        world:tick()
        CHECK(same(collect(tag_removed), list) and same(collect(removed), list))

        CASE("delete_all: the deleted entities are reported by no filter")
        world:query(Kind):add_all(T)
        world:tick()
        collect(tag_added)
        world:query(Kind):delete_all()
        world:tick()
        CHECK(#collect(world:query(Kind):removed(T)) == 0 and #collect(tag_removed) == 0)
    end)

    TEST("the depth of the change history", function()
        CASE("a query that skipped ticks sees the changes of the last 7 finished ticks, no older")
        local world = ecs.world()
        local C = world:component()
        world:track(C)
        local list: { any } = {}
        for i = 1, 10 do
            list[i] = world:entity()
            world:set(list[i], C, 0)
        end
        local changed = world:query(C):changed(C):cached()
        world:tick()
        collect(changed)
        -- one change per tick, for 10 ticks, while the query does not run
        for i = 1, 10 do
            world:set(list[i], C, i)
            world:tick()
        end
        CHECK(same(collect(changed), table.move(list, 4, 10, 1, {})))

        CASE("then it goes on tick by tick")
        world:set(list[1], C, 11)
        world:tick()
        CHECK(same(collect(changed), { list[1] }))
    end)

    TEST("creation tracking", function()
        local world = ecs.world()
        local Base = world:component()
        local before = world:entity()
        world:set(before, Base, 0)
        world:track_created()
        local created = world:query(Base):created():cached()
        local any_new = world:query():created():cached()
        world:tick()

        CASE("nothing made before the tracking started")
        CHECK(#collect(created) == 0 and #collect(any_new) == 0)

        CASE("the entities made since the previous run of the query, made in any way")
        local first, second = world:entity(), world:entity()
        local pooled = world:pool():entity()
        local explicit = ecs.ECS_COMBINE(ecs.ECS_ID(second) + 50, 0)
        world:entity(explicit)
        for _, e in { first, second, pooled, explicit } do
            world:set(e, Base, 1)
        end
        world:tick()
        CHECK(same(collect(created), support.in_slot_order(ecs, { first, second, pooled, explicit })))
        CHECK(#collect(created) == 0) -- seen by this query

        CASE("query():created() returns the new entities whatever their ids")
        CHECK(same(collect(any_new), support.in_slot_order(ecs, { first, second, pooled, explicit })))

        CASE("an entity deleted after it was made is not returned; a new one in its slot is")
        local gone = world:entity()
        world:set(gone, Base, 1)
        world:delete(gone)
        local reused = world:entity()
        world:set(reused, Base, 1)
        CHECK(ecs.ECS_ID(reused) == ecs.ECS_ID(gone))
        world:tick()
        CHECK(same(collect(created), { reused }))

        CASE("the live id given to world:entity is not made again")
        world:entity(explicit)
        world:tick()
        CHECK(#collect(created) == 0)

        CASE("the filter needs world:track_created")
        local untracked = ecs.world()
        local Other = untracked:component()
        spec.CHECK_EXPECT_ERR(function()
            collect(untracked:query(Other):created())
        end)
    end)

    TEST("change tracking of an entity that a listener of the change deletes", function()
        for _, debug in { false, true } do
            for _, kind in { "added", "changed", "removed" } do
                for _, tracked_first in { false, true } do
                    local order = if tracked_first then "tracked before" else "tracked after"
                    local world_kind = if debug then " (debug world)" else ""
                    CASE(`{kind}, {order} the listener: the new entity in the slot gets no change{world_kind}`)
                    local world = ecs.world(debug)
                    local C = world:component()
                    local e = world:entity()
                    if kind ~= "added" then
                        world:set(e, C, 1)
                    end
                    if tracked_first then
                        world:track(C)
                    end
                    local function delete(entity: any)
                        world:delete(entity)
                    end
                    if kind == "added" then
                        world:added(C, delete)
                    elseif kind == "changed" then
                        world:changed(C, delete)
                    else
                        world:removed(C, delete)
                    end
                    if not tracked_first then
                        world:track(C)
                    end
                    if kind == "removed" then
                        world:remove(e, C)
                    else
                        world:set(e, C, 2)
                    end
                    local replacement = world:entity()
                    CHECK(not world:contains(e) and ecs.ECS_ID(replacement) == ecs.ECS_ID(e))
                    world:tick()
                    local query = world:query()
                    if kind == "added" then
                        query = query:added(C)
                    elseif kind == "changed" then
                        query = query:changed(C)
                    else
                        query = query:removed(C)
                    end
                    CHECK(not query:has(replacement) and query:count() == 0)
                end
            end
        end
    end)

    TEST("change filters in a loop that cannot gather its matches first", function()
        for _, debug in { false, true } do
            for _, kind in { "added", "changed", "removed", "created" } do
                for _, size in { 1, 2100 } do
                    CASE(
                        `{kind}: {size} {if size == 1 then "match, four terms" else "matches"}{if debug
                            then " (debug world)"
                            else ""}`
                    )
                    local world = ecs.world(debug)
                    local C = world:component() :: api.Component<number>
                    local a, b, c, d = world:entity(), world:entity(), world:entity(), world:entity()
                    world:track(C)
                    world:track_created()
                    local made: { any } = {}
                    for i = 1, size do
                        local e = world:entity()
                        made[i] = e
                        world:set(e, C, 10)
                        world:add(e, a)
                        world:add(e, b)
                        world:add(e, c)
                        world:add(e, d)
                    end
                    if kind == "changed" or kind == "removed" then
                        world:tick()
                        for _, e in made do
                            if kind == "changed" then
                                world:set(e, C, 20)
                            else
                                world:remove(e, C)
                            end
                        end
                    end
                    world:tick()
                    local function filtered(): any
                        local query = world:query(a)
                        if kind == "added" then
                            query:added(C)
                        elseif kind == "changed" then
                            query:changed(C)
                        elseif kind == "removed" then
                            query:removed(C)
                        else
                            query:created()
                        end
                        if size == 1 then
                            query:with(b, c, d)
                        end
                        return query
                    end
                    local looped, eached = 0, 0
                    for _ in filtered() do
                        looped += 1
                    end
                    filtered():each(function()
                        eached += 1
                    end)
                    CHECK(looped == size and eached == size and filtered():count() == size)
                end
            end
        end
    end)
end
