--!strict
--[[
    Behavior cases: relations kept in sync by their own hooks. The OnAdd hook of a relation gives
    the target the pair of the other side, and its OnRemove hook removes it; the hooks of the
    other side do the same back, so every change starts a removal or an add that comes back to
    the side it started on. A removal of the same id from the same entity that the hooks of a
    removal start again does nothing (the running removal completes it), and a repeated add of
    a present id does nothing, so the hook of each side runs once and both sides stay in sync:

    - one relation in both directions (an exclusive one: a partner);
    - two relations, one per direction (Mount and Rider);
    - one to many (a child's exclusive Parent and the parent's Child pairs);
    - many to many (memberships and owners);
    - a hook that removes the id whose removal runs.

    And a cascade that reaches the same entity through ownership and ChildOf, whose child hook
    deletes a sibling while the parent is being deleted: each removal runs once.

    Listeners that give a relation or a deleted id new uses while it changes: an exclusive
    relation whose removal listener gives the entity another target keeps one target, the one
    of the outer add; the entities that a removal listener gives a deleted id during its cleanup
    are cleaned up too (they lose the id, or are deleted under a delete policy); an entity that
    becomes an id for the first time inside its own delete leaves no use behind; a removal
    listener that deletes the id itself and gives its slot to a new entity leaves the pairs of
    the new one (as the relation or the target) and their holders as they are; a set of an
    exclusive pair whose replacement listener sets the same pair keeps the value of the set.

    The same for the pairs of a deleted relation or target, under the default policy and a delete
    policy, and for a child given to a parent deleted past 100 levels of a cascade; an entity
    that its own delete makes an id for the first time has lost its own policy with its ids, so
    those uses are removed. Hooks that never stop giving new uses raise an error after 100
    rounds (an exclusive relation keeps one target), and the next world:tick restores the world.
    The uses that hooks make while the cascade of a delete runs (the entity as a new id, a pair
    with it as the target) go too, and an exclusive relation keeps one target when its listeners
    add targets while the pair of a deleted target is removed.

    Deletes of relations and targets: a relation in the slot of a deleted one has none of its
    policy or hooks; a target deleted with a ChildOf cascade leaves no pair to it, also after a
    new entity takes its slot; (OnDeleteTarget, Delete) and (OnDelete, Delete) delete every
    holder, whatever the order the holders got their ids and while the cascade makes new
    combinations of ids; a survivor of the delete of a target keeps its other components and
    values; a child re-parented to the entity in the slot of a deleted parent has that parent
    and stays in its queries.
]]

local api = require("@lib")
local support = require("./support")

type Entity = api.Entity

return function(spec: support.Spec)
    local ecs, TEST, CASE, CHECK = spec.ecs, spec.TEST, spec.CASE, spec.CHECK
    local pair = ecs.pair

    -- the hooks that keep pair(there, e) on t while e has pair(here, t), with call counts
    type Counts = { adds: number, removes: number }
    local function mirror(world: any, here: any, there: any, counts: Counts)
        world:set(here, ecs.OnAdd, function(e: any, id: any)
            counts.adds += 1
            local target = ecs.pair_second(world, id)
            if world:contains(target) then
                world:add(target, pair(there, e))
            end
        end)
        world:set(here, ecs.OnRemove, function(e: any, id: any)
            counts.removes += 1
            local target = ecs.pair_second(world, id)
            if world:contains(target) then
                world:remove(target, pair(there, e))
            end
        end)
    end

    -- whether every pair (here, t) of the entities has its pair (there, e) on t, and back
    local function in_sync(world: any, entities: { any }, here: any, there: any): boolean
        for _, e in entities do
            if world:contains(e) then
                for t in world:targets(e, here) do
                    if not world:has(t, pair(there, e)) then
                        return false
                    end
                end
                for t in world:targets(e, there) do
                    if not world:has(t, pair(here, e)) then
                        return false
                    end
                end
            end
        end
        return true
    end

    TEST("relations kept in sync by their own hooks", function()
        CASE("one relation both ways: added from one side, both sides have it, a hook per side")
        local world = ecs.world()
        local Partner = world:entity()
        world:add(Partner, ecs.Exclusive)
        local counts: Counts = { adds = 0, removes = 0 }
        mirror(world, Partner, Partner, counts)
        local a, b, c = world:entity(), world:entity(), world:entity()
        world:add(a, pair(Partner, b))
        CHECK(world:has(a, pair(Partner, b)) and world:has(b, pair(Partner, a)))
        CHECK(counts.adds == 2 and counts.removes == 0)

        CASE("removed from either side: both sides lose it, a hook per side")
        counts.adds, counts.removes = 0, 0
        world:remove(b, pair(Partner, a))
        CHECK(not world:has(a, pair(Partner, b)) and not world:has(b, pair(Partner, a)))
        CHECK(counts.removes == 2)

        CASE("an exclusive relation that replaces the target unlinks the old partner on both sides")
        world:add(a, pair(Partner, b))
        counts.adds, counts.removes = 0, 0
        world:add(a, pair(Partner, c))
        CHECK(world:has(a, pair(Partner, c)) and world:has(c, pair(Partner, a)))
        CHECK(not world:has(a, pair(Partner, b)) and not world:has(b, pair(Partner, a)))
        CHECK(counts.adds == 2 and counts.removes == 2)

        CASE("deleting one side: the other loses its pair, a hook per side")
        counts.adds, counts.removes = 0, 0
        world:delete(a)
        CHECK(not world:has(c, pair(Partner, a)) and counts.removes == 2)
        CHECK(in_sync(world, { b, c }, Partner, Partner))

        CASE("two relations, one per direction: setting one side sets the other")
        world = ecs.world()
        local Mount, Rider = world:entity(), world:entity()
        world:add(Mount, ecs.Exclusive)
        world:add(Rider, ecs.Exclusive)
        counts = { adds = 0, removes = 0 }
        mirror(world, Mount, Rider, counts)
        mirror(world, Rider, Mount, counts)
        local player, horse = world:entity(), world:entity()
        world:add(player, pair(Mount, horse))
        CHECK(world:has(horse, pair(Rider, player)) and counts.adds == 2)
        world:remove(horse, pair(Rider, player))
        CHECK(not world:has(player, pair(Mount, horse)) and counts.removes == 2)

        CASE("one to many: a child's exclusive Parent and the Child pairs of its parent")
        world = ecs.world()
        local Parent, Child = world:entity(), world:entity()
        world:add(Parent, ecs.Exclusive)
        counts = { adds = 0, removes = 0 }
        mirror(world, Parent, Child, counts)
        mirror(world, Child, Parent, counts)
        local father, mother = world:entity(), world:entity()
        local kids: { any } = {}
        for i = 1, 3 do
            kids[i] = world:entity()
            world:add(kids[i], pair(Parent, father))
        end
        local late = world:entity()
        world:add(father, pair(Child, late)) -- from the parent's side
        table.insert(kids, late)
        local family = { father, mother, kids[1], kids[2], kids[3], late }
        CHECK(world:has(late, pair(Parent, father)) and in_sync(world, family, Parent, Child))
        world:add(kids[1], pair(Parent, mother)) -- a new parent replaces the old one
        CHECK(not world:has(father, pair(Child, kids[1])) and world:has(mother, pair(Child, kids[1])))
        world:delete(kids[2])
        CHECK(not world:has(father, pair(Child, kids[2])))
        world:delete(father)
        CHECK(not world:has(kids[3], pair(Parent, father)) and not world:has(late, pair(Parent, father)))
        CHECK(in_sync(world, family, Parent, Child))

        CASE("many to many: deleting a group or a member leaves no pair behind")
        world = ecs.world()
        local Memberships, Owners = world:entity(), world:entity()
        counts = { adds = 0, removes = 0 }
        mirror(world, Memberships, Owners, counts)
        mirror(world, Owners, Memberships, counts)
        local users, groups = {}, {}
        for i = 1, 4 do
            users[i] = world:entity()
            groups[i] = world:entity()
        end
        for u = 1, 4 do
            for g = 1, 4 do
                if (u + g) % 2 == 0 then
                    world:add(users[u], pair(Memberships, groups[g]))
                end
            end
        end
        local everyone = table.move(groups, 1, 4, 5, table.clone(users))
        CHECK(world:has(groups[2], pair(Owners, users[2])) and in_sync(world, everyone, Memberships, Owners))
        world:delete(groups[2])
        world:delete(users[1])
        world:remove(groups[3], pair(Owners, users[3]))
        CHECK(not world:has(users[3], pair(Memberships, groups[3])))
        CHECK(in_sync(world, everyone, Memberships, Owners))

        CASE("a hook that removes the id whose removal runs: the removal runs once")
        world = ecs.world()
        local Mark = world:entity()
        local runs = 0
        world:set(Mark, ecs.OnRemove, function(e: any)
            runs += 1
            world:remove(e, Mark)
        end)
        local e = world:entity()
        world:add(e, Mark)
        world:remove(e, Mark)
        CHECK(runs == 1 and not world:has(e, Mark))
        world:add(e, Mark)
        world:delete(e)
        CHECK(runs == 2 and not world:contains(e))
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
        CHECK(query:count() == 0 and #support.collect(world:children(parent)) == 0)
    end)

    TEST("listeners that give a changing relation or a deleted id new uses", function()
        for _, debug in { false, true } do
            local kind = if debug then " (debug world)" else ""

            CASE(
                `an exclusive relation whose removal listener adds another target keeps the target of the outer add{kind}`
            )
            local world = ecs.world(debug)
            local relation = world:entity()
            world:add(relation, ecs.Exclusive)
            local e = world:entity()
            local a, b, c, d = world:entity(), world:entity(), world:entity(), world:entity()
            local names = { [a] = "a", [b] = "b", [c] = "c", [d] = "d" }
            local events: { string } = {}
            local function name(id: any): string
                return names[ecs.pair_second(world, id)]
            end
            world:added(relation, function(_, id)
                table.insert(events, "+" .. name(id))
            end)
            world:removed(relation, function(entity, id)
                table.insert(events, "-" .. name(id))
                if entity == e and ecs.pair_second(world, id) == a then
                    world:add(entity, ecs.pair(relation, c))
                end
            end)
            world:add(e, ecs.pair(relation, a))
            world:add(e, ecs.pair(relation, b))
            local targets = support.collect(world:targets(e, relation))
            CHECK(#targets == 1 and targets[1] == b and not world:has(e, ecs.pair(relation, c)))
            -- the target of the listener comes and goes with its own events
            CHECK(table.concat(events, " ") == "+a -a +c -c +b")

            CASE(`a removal listener that adds the target of the outer add: one target, one addition{kind}`)
            table.clear(events)
            world:removed(relation, function(entity, id)
                if entity == e and ecs.pair_second(world, id) == b then
                    world:add(entity, ecs.pair(relation, d))
                end
            end)
            world:add(e, ecs.pair(relation, d))
            targets = support.collect(world:targets(e, relation))
            CHECK(#targets == 1 and targets[1] == d)
            CHECK(table.concat(events, " ") == "-b +d")

            CASE(`a removal listener of a deleted id gives it to another entity: that one loses it too{kind}`)
            world = ecs.world(debug)
            local Tag = world:entity()
            local first, second = world:entity(), world:entity()
            world:add(first, Tag)
            world:removed(Tag, function(entity)
                if entity == first then
                    CHECK(world:contains(Tag))
                    world:add(second, Tag)
                end
            end)
            world:delete(Tag)
            CHECK(world:contains(second) and not world:has(second, Tag) and #world:ids(second) == 0)

            CASE(`under a delete policy, the entity given the deleted id by a listener is deleted too{kind}`)
            local Doomed = world:entity()
            world:add(Doomed, ecs.pair(ecs.OnDelete, ecs.Delete))
            local holder, late = world:entity(), world:entity()
            world:add(holder, Doomed)
            world:removed(Doomed, function(entity)
                if entity == holder then
                    world:add(late, Doomed)
                end
            end)
            world:delete(Doomed)
            CHECK(not world:contains(holder) and not world:contains(late))

            CASE(`an entity first used as an id by a removal listener of its own delete leaves no use{kind}`)
            local Trigger = world:entity()
            local deleted, survivor = world:entity(), world:entity()
            world:add(deleted, Trigger)
            world:removed(Trigger, function(entity)
                if entity == deleted then
                    CHECK(world:contains(entity))
                    world:add(survivor, entity)
                end
            end)
            world:delete(deleted)
            CHECK(not world:contains(deleted) and world:contains(survivor))
            CHECK(not world:has(survivor, deleted) and #world:ids(survivor) == 0)
        end
    end)

    TEST("new uses given by listeners: pairs, deep cascades and endless hooks", function()
        for _, policy in { false, true } do
            local what = if policy then "is deleted under a delete policy" else "loses the pair"

            CASE(`a listener gives the pair of a relation being deleted to another entity: it {what}`)
            do
                local world = ecs.world()
                local R = world:entity()
                if policy then
                    world:add(R, pair(ecs.OnDelete, ecs.Delete))
                end
                local x = world:entity()
                local holder, late = world:entity(), world:entity()
                world:add(holder, pair(R, x))
                world:removed(R, function(entity)
                    if entity == holder then
                        world:add(late, pair(R, x))
                    end
                end)
                world:delete(R)
                CHECK(world:contains(holder) == not policy and world:contains(late) == not policy)
                CHECK(policy or #world:ids(late) == 0)
            end

            CASE(`a listener gives a pair of a target being deleted to another entity: it {what}`)
            do
                local world = ecs.world()
                local R = world:entity()
                if policy then
                    world:add(R, pair(ecs.OnDeleteTarget, ecs.Delete))
                end
                local T = world:entity()
                local holder, late = world:entity(), world:entity()
                world:add(holder, pair(R, T))
                world:removed(R, function(entity)
                    if entity == holder then
                        world:add(late, pair(R, T))
                    end
                end)
                world:delete(T)
                CHECK(world:contains(holder) == not policy and world:contains(late) == not policy)
                CHECK(policy or #world:ids(late) == 0)
            end
        end

        CASE("past 100 levels of a cascade, a child that a listener gives to a parent being deleted goes too")
        do
            local world = ecs.world()
            local list = { world:entity() }
            for i = 1, 105 do
                local child = world:entity()
                world:add(child, pair(ecs.ChildOf, list[i]))
                list[i + 1] = child
            end
            local newcomer = world:entity()
            local given = false
            world:removed(ecs.ChildOf, function(entity)
                if entity == list[102] and not given then
                    given = true
                    world:add(newcomer, pair(ecs.ChildOf, list[101]))
                end
            end)
            world:delete(list[1])
            local left = 0
            for _, e in list do
                if world:contains(e) then
                    left += 1
                end
            end
            CHECK(given and left == 0 and not world:contains(newcomer))
        end

        for _, as in { "relation", "target" } do
            CASE(`an entity first used as a {as} by the hooks of its own delete leaves no use`)
            local world = ecs.world()
            local Trigger, X = world:entity(), world:entity()
            local deleted, survivor = world:entity(), world:entity()
            world:add(deleted, Trigger)
            world:removed(Trigger, function(entity)
                if entity == deleted then
                    world:add(survivor, if as == "relation" then pair(entity, X) else pair(X, entity))
                end
            end)
            world:delete(deleted)
            local id = if as == "relation" then pair(deleted, X) else pair(X, deleted)
            CHECK(not world:contains(deleted) and not world:has(survivor, id))
            CHECK(#world:ids(survivor) == 0 and world:query(id):count() == 0)
        end

        CASE("its own delete policy is gone with its ids: those first uses are removed, not deleted")
        do
            local world = ecs.world()
            local Trigger = world:entity()
            local deleted, survivor = world:entity(), world:entity()
            world:add(deleted, pair(ecs.OnDelete, ecs.Delete))
            world:add(deleted, Trigger)
            world:removed(Trigger, function(entity)
                if entity == deleted then
                    world:add(survivor, entity)
                end
            end)
            world:delete(deleted)
            CHECK(world:contains(survivor) and #world:ids(survivor) == 0)
        end

        CASE("the cascade of a delete: an entity used as an id for the first time by a hook leaves no use")
        do
            local world = ecs.world()
            local parent, child, survivor = world:entity(), world:entity(), world:entity()
            world:add(child, pair(ecs.ChildOf, parent))
            world:removed(ecs.ChildOf, function(entity)
                if entity == child then
                    world:add(survivor, parent)
                end
            end)
            world:delete(parent)
            CHECK(not world:contains(parent) and not world:contains(child))
            CHECK(world:contains(survivor) and #world:ids(survivor) == 0)
        end

        CASE("a pair that a hook makes with a target while the target is cleaned up goes too")
        do
            local world = ecs.world()
            local R, P = world:entity(), world:entity()
            local T, holder, late = world:entity(), world:entity(), world:entity()
            world:add(holder, pair(R, T))
            world:removed(R, function(entity)
                if entity == holder then
                    world:add(late, pair(P, T))
                end
            end)
            world:delete(T)
            CHECK(world:contains(late) and #world:ids(late) == 0)
            CHECK(#support.collect(world:query(pair(P, ecs.Wildcard))) == 0)
        end

        CASE("an exclusive relation whose listeners add targets while a deleted target's pair goes: one target")
        do
            local world = ecs.world()
            local X = world:entity()
            world:add(X, ecs.Exclusive)
            local t1, t2, t3, e = world:entity(), world:entity(), world:entity(), world:entity()
            world:add(e, pair(X, t1))
            local step = 0
            world:removed(X, function(entity)
                if entity == e and step == 0 then
                    step = 1
                    world:add(entity, pair(X, t2))
                end
            end)
            world:added(X, function(entity)
                if entity == e and step == 1 then
                    step = 2
                    world:add(entity, pair(X, t3))
                end
            end)
            world:delete(t1)
            local targets = support.collect(world:targets(e, X))
            CHECK(step == 2 and #targets == 1 and targets[1] == t3)
        end

        CASE("an exclusive relation whose listener keeps adding targets: an error, one target; tick restores")
        do
            local world = ecs.world()
            local R = world:entity()
            world:add(R, ecs.Exclusive)
            local e = world:entity()
            world:add(e, pair(R, world:entity()))
            local endless = true
            world:removed(R, function(entity)
                if endless and entity == e then
                    world:add(entity, pair(R, world:entity()))
                end
            end)
            spec.CHECK_EXPECT_ERR(function()
                world:add(e, pair(R, world:entity()))
            end)
            CHECK(#support.collect(world:targets(e, R)) == 1)
            endless = false
            world:tick()
            local last = world:entity()
            world:add(e, pair(R, last))
            local targets = support.collect(world:targets(e, R))
            CHECK(#targets == 1 and targets[1] == last)
        end

        CASE("a deleted id whose listener keeps giving it to new entities: an error; tick restores")
        do
            local world = ecs.world()
            local Tag = world:entity()
            world:add(world:entity(), Tag)
            local endless = true
            world:removed(Tag, function()
                if endless then
                    world:add(world:entity(), Tag)
                end
            end)
            spec.CHECK_EXPECT_ERR(function()
                world:delete(Tag)
            end)
            endless = false
            world:tick()
            world:delete(Tag)
            CHECK(not world:contains(Tag) and world:query(Tag):count() == 0)
        end
    end)

    TEST("a cleanup that a listener ends by giving the slot to a new entity", function()
        for _, debug in { false, true } do
            for _, cascade in { false, true } do
                for _, role in { "relation", "target" } do
                    CASE(
                        `the pairs of the new entity as the {role} stay{if cascade
                            then ", under delete policies"
                            else ""}{if debug then " (debug world)" else ""}`
                    )
                    local world = ecs.world(debug)
                    local old, holder, survivor = world:entity(), world:entity(), world:entity()
                    local Other, target = world:entity(), world:entity()
                    if cascade then
                        world:add(old, ecs.pair(ecs.OnDelete, ecs.Delete))
                        world:add(Other, ecs.pair(ecs.OnDeleteTarget, ecs.Delete))
                    end
                    world:add(holder, old)
                    local started = false
                    local fresh: Entity? = nil
                    local link: any = nil
                    world:removed(old, function()
                        if not started then
                            started = true
                            world:delete(old)
                            local made = world:entity()
                            fresh = made
                            link = if role == "relation" then ecs.pair(made, target) else ecs.pair(Other, made)
                            world:add(survivor, link)
                        end
                    end)
                    world:delete(old)
                    local new = fresh :: Entity
                    CHECK(ecs.ECS_ID(new) == ecs.ECS_ID(old) and world:contains(new))
                    CHECK(world:contains(survivor) and world:has(survivor, link))
                end
            end
        end
    end)

    TEST("a set of an exclusive pair that a replacement listener sets too", function()
        for _, debug in { false, true } do
            CASE(`the value of the outer set stays{if debug then " (debug world)" else ""}`)
            local world = ecs.world(debug)
            local relation = world:component() :: api.Component<number>
            world:add(relation, ecs.Exclusive)
            local a, b, e = world:entity(), world:entity(), world:entity()
            world:set(e, pair(relation, a), 10)
            local changes = 0
            world:changed(relation, function()
                changes += 1
            end)
            world:removed(relation, function(entity)
                world:set(entity, pair(relation, b), 20)
            end)
            world:set(e, pair(relation, b), 30)
            CHECK(world:get(e, pair(relation, b)) == 30 and world:target(e, relation, 0) == b)
            CHECK(world:target(e, relation, 1) == nil and changes == 1)
        end
    end)

    TEST("deletes of relations and targets", function()
        for _, debug in { false, true } do
            local kind = if debug then " (debug world)" else ""

            CASE(`a relation in the slot of a deleted one has none of its policy or hooks{kind}`)
            do
                local world = ecs.world(debug)
                local R = world:entity()
                world:add(R, pair(ecs.OnDelete, ecs.Delete))
                local hook_calls = 0
                world:set(R, ecs.OnAdd, function()
                    hook_calls += 1
                end)
                local a, b, holder = world:entity(), world:entity(), world:entity()
                world:add(holder, pair(R, a))
                world:add(holder, pair(R, b))
                world:delete(holder)
                world:delete(R)
                local R2 = world:entity()
                CHECK(ecs.ECS_ID(R2) == ecs.ECS_ID(R))
                local before = hook_calls
                local victim, t = world:entity(), world:entity()
                world:add(victim, pair(R2, t))
                world:delete(R2)
                CHECK(hook_calls == before and world:contains(victim) and #world:ids(victim) == 0)
            end

            CASE(`a target deleted with a ChildOf cascade leaves no pair to it{kind}`)
            do
                local world = ecs.world(debug)
                local R, X, E, C, V = world:entity(), world:entity(), world:entity(), world:entity(), world:entity()
                world:add(V, pair(R, C))
                world:add(V, pair(X, E))
                world:add(C, pair(ecs.ChildOf, E))
                world:delete(E)
                CHECK(not world:contains(C) and world:contains(V) and world:target(V, X) == nil)
                CHECK(world:query(pair(X, ecs.Wildcard)):count() == 0)
                local E2 = world:entity()
                CHECK(not world:has(V, pair(X, E2)) and world:target(V, X) == nil)
            end

            CASE(`(OnDeleteTarget, Delete) deletes every holder, whatever their order{kind}`)
            do
                local world = ecs.world(debug)
                local R = world:entity()
                world:add(R, pair(ecs.OnDeleteTarget, ecs.Delete))
                local S = world:entity()
                local P, second, first = world:entity(), world:entity(), world:entity()
                world:add(first, pair(S, second))
                world:add(first, pair(R, P))
                world:add(second, pair(R, P))
                world:delete(P)
                CHECK(not world:contains(first) and not world:contains(second))
                CHECK(world:query(pair(R, ecs.Wildcard)):count() == 0)
            end

            CASE(`(OnDelete, Delete) deletes every holder while the cascade makes new combinations{kind}`)
            do
                local world = ecs.world(debug)
                local R = world:entity()
                local id = world:entity()
                world:add(id, pair(ecs.OnDelete, ecs.Delete))
                local holders: { Entity } = {}
                for i = 1, 50 do
                    local c = world:entity()
                    world:add(c, id)
                    for _ = 1, 3 do
                        world:add(world:entity(), world:entity())
                    end
                    local tag, y = world:entity(), world:entity()
                    world:add(y, tag)
                    world:add(y, pair(R, c))
                    world:add(y, id)
                    holders[i] = y
                end
                world:delete(id)
                local survivors = 0
                for _, y in holders do
                    if world:contains(y) then
                        survivors += 1
                    end
                end
                CHECK(survivors == 0)
            end

            CASE(`a survivor of the delete of a target keeps its other components{kind}`)
            do
                local world = ecs.world(debug)
                local Comp = world:component() :: api.Component<string>
                local plain, deleting = world:entity(), world:entity()
                world:add(deleting, pair(ecs.OnDeleteTarget, ecs.Delete))
                local R3, R4, T = world:entity(), world:entity(), world:entity()
                local survivor = world:entity()
                world:set(survivor, Comp, "data")
                world:add(survivor, pair(R3, T))
                world:add(survivor, pair(R4, T))
                local doomed = world:entity()
                world:add(doomed, pair(plain, T))
                world:add(doomed, pair(deleting, T))
                world:delete(T)
                CHECK(not world:contains(doomed) and world:contains(survivor))
                CHECK(world:get(survivor, Comp) == "data" and #world:ids(survivor) == 1)
            end

            CASE(`a child re-parented to the entity in the slot of a deleted parent{kind}`)
            do
                local world = ecs.world(debug)
                local X = world:component()
                local p1, p2 = world:entity(), world:entity()
                local moved, child = world:entity(), world:entity()
                for _, e in { moved, child } do
                    world:add(e, X)
                    world:add(e, pair(ecs.ChildOf, p1))
                end
                world:add(moved, pair(ecs.ChildOf, p2))
                world:delete(p2)
                local heir: Entity
                repeat
                    heir = world:entity()
                until ecs.ECS_ID(heir) == ecs.ECS_ID(p2)
                world:add(child, pair(ecs.ChildOf, heir))
                CHECK(world:has(child, pair(ecs.ChildOf, heir)) and world:parent(child) == heir)
                CHECK(world:query(X):has(child) and not world:contains(moved))
            end
        end
    end)
end
