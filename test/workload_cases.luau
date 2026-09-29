--!strict
--# selene: allow(empty_loop) -- loops iterate for what they visit only
--[[
    The behavior cases of the reference workload: the behavior that a game that uses the
    library relies on (section 4 of its release requirements), one case per line of the
    requirements, each a test of the library alone. A release passes all of them; a change of
    one of them is listed as a changed behavior in the release notes.

    Run from the repository root:
        luau test/workload_cases.luau
]]

local testkit = require("@testkit")
local ecs = require("@lib")

local it = testkit.test()
local TEST, CASE, CHECK, FINISH = it.TEST, it.CASE, it.CHECK, it.FINISH
local CHECK_EXPECT_ERR = it.CHECK_EXPECT_ERR

local pair = ecs.pair

local function count(iterator: any): number
    local n = 0
    for _ in iterator do
        n += 1
    end
    return n
end

TEST("4.1 ids and liveness", function()
    CASE("an id of a deleted entity is inert: get returns nil, has false, changes do nothing")
    do
        local world = ecs.world()
        local A, T = world:component(), world:entity()
        local e = world:entity()
        world:set(e, A, 5)
        world:add(e, T)
        world:delete(e)
        CHECK(world:get(e, A) == nil and not world:has(e, A) and not world:has(e, T))
        world:set(e, A, 1)
        world:add(e, T)
        world:remove(e, A)
        world:clear(e)
        world:delete(e)
        CHECK(not world:contains(e) and world:get(e, A) == nil and count(world:query(A)) == 0)
    end

    CASE("a reused slot gets a new generation; the old id stays dead")
    do
        local world = ecs.world()
        local A = world:component()
        local e = world:entity()
        world:delete(e)
        local f = world:entity()
        CHECK(ecs.ECS_ID(f) == ecs.ECS_ID(e) and f ~= e)
        world:set(f, A, 1)
        CHECK(world:contains(f) and not world:contains(e) and world:get(e, A) == nil)
    end

    CASE("contains is the liveness check; exists stays true for a deleted entity")
    do
        local world = ecs.world()
        local e = world:entity()
        world:delete(e)
        CHECK(not world:contains(e))
        CHECK(world:exists(e)) -- the slot was used: this release answers true
    end

    CASE("set(e, C, nil) keeps the component; clear keeps the entity; Name round-trips")
    do
        local world = ecs.world()
        local C, T = world:component(), world:entity()
        local e = world:entity()
        world:set(e, C, 1)
        world:set(e, C, nil)
        CHECK(world:has(e, C) and world:get(e, C) == nil)
        world:add(e, T)
        world:clear(e)
        CHECK(world:contains(e) and not world:has(e, C) and not world:has(e, T))
        world:set(e, ecs.Name, "unit")
        CHECK(world:get(e, ecs.Name) == "unit")
    end

    CASE("the entities of a slot pool are ordinary for queries, each, children and cascades")
    do
        local world = ecs.world()
        local A, T = world:component(), world:entity()
        local pool = world:pool()
        local parent = world:entity()
        local members: { any } = {}
        for i = 1, 5 do
            local e = pool:entity()
            world:set(e, A, i)
            world:add(e, T)
            world:add(e, pair(ecs.ChildOf, parent))
            members[i] = e
        end
        world:set(world:entity(), A, 0) -- an entity outside the pool
        CHECK(count(world:query(A):with(T)) == 5 and count(world:each(T)) == 5)
        CHECK(count(world:children(parent)) == 5)
        world:delete(parent)
        local alive = 0
        for _, e in members do
            if world:contains(e) then
                alive += 1
            end
        end
        CHECK(alive == 0 and count(world:query(A)) == 1)
    end
end)

TEST("4.2 hooks and signals", function()
    CASE("hooks and signals run once per change; an add of a present id and a removal of an absent one run nothing")
    do
        local world = ecs.world()
        local C, T = world:component(), world:entity()
        local log: { string } = {}
        world:set(C, ecs.OnAdd, function()
            table.insert(log, "hook add")
        end)
        world:set(C, ecs.OnChange, function()
            table.insert(log, "hook change")
        end)
        world:set(C, ecs.OnRemove, function()
            table.insert(log, "hook remove")
        end)
        world:added(C, function()
            table.insert(log, "added")
        end)
        world:changed(C, function()
            table.insert(log, "changed")
        end)
        world:removed(C, function()
            table.insert(log, "removed")
        end)
        local tag_log = 0
        world:added(T, function()
            tag_log += 1
        end)
        world:removed(T, function()
            tag_log += 10
        end)
        local e = world:entity()
        world:set(e, C, 1)
        world:set(e, C, 2)
        world:remove(e, C)
        world:remove(e, C) -- absent: nothing
        CHECK(table.concat(log, ",") == "hook add,added,hook change,changed,hook remove,removed")
        world:add(e, T)
        world:add(e, T) -- present: nothing
        world:remove(e, T)
        world:remove(e, T)
        CHECK(tag_log == 11)
    end

    CASE("a hook set before a signal and one set after it both run")
    do
        local world = ecs.world()
        local A, B = world:component(), world:component()
        local log: { string } = {}
        world:set(A, ecs.OnAdd, function()
            table.insert(log, "A hook")
        end)
        world:added(A, function()
            table.insert(log, "A signal")
        end)
        world:added(B, function()
            table.insert(log, "B signal")
        end)
        world:set(B, ecs.OnAdd, function()
            table.insert(log, "B hook")
        end)
        local e = world:entity()
        world:set(e, A, 1)
        world:set(e, B, 1)
        CHECK(table.concat(log, ",") == "A hook,A signal,B hook,B signal")
    end

    CASE("the listeners of a relation receive the id of the pair")
    do
        local world = ecs.world()
        local R = world:entity()
        local t = world:entity()
        local got: any = nil
        world:added(R, function(_: any, id: any)
            got = id
        end)
        world:add(world:entity(), pair(R, t))
        CHECK(got == pair(R, t))
    end

    CASE("the removal listeners of a deleted entity run once each in a world of more than 256 records")
    do
        local world = ecs.world()
        local holder = world:entity()
        for _ = 1, 300 do
            world:add(holder, world:entity()) -- more than 256 records
        end
        local ids: { any } = {}
        local calls: { [any]: number } = {}
        for i = 1, 3 do
            local id = world:component()
            ids[i] = id
            world:removed(id, function()
                calls[id] = (calls[id] or 0) + 1
            end)
        end
        local late = world:entity() -- an id beyond the shared signature tables
        world:removed(late, function()
            calls[late] = (calls[late] or 0) + 1
        end)
        local e = world:entity()
        for i, id in ids do
            world:set(e, id, i)
        end
        world:add(e, late)
        world:delete(e)
        CHECK(calls[ids[1]] == 1 and calls[ids[2]] == 1 and calls[ids[3]] == 1 and calls[late] == 1)
    end

    CASE("on delete, removal listeners read the values of the entity and contains is true")
    do
        local world = ecs.world()
        local A, B = world:component(), world:component()
        local seen: { any } = {}
        world:removed(A, function(entity: any)
            seen = { world:get(entity, A), world:get(entity, B), world:contains(entity) }
        end)
        local e = world:entity()
        world:set(e, A, 1)
        world:set(e, B, 2)
        world:delete(e)
        CHECK(seen[1] == 1 and seen[2] == 2 and seen[3] == true)
    end

    CASE("an entity deleted by a cascade gets the delete flag; a pair removed from a survivor does not")
    do
        local world = ecs.world()
        local A = world:component()
        local Likes = world:entity()
        local flags: { [any]: any } = {}
        world:removed(A, function(entity: any, _: any, deleting: any)
            flags[entity] = deleting == true
        end)
        local pair_flag: any = "none"
        world:removed(Likes, function(_: any, _: any, deleting: any)
            pair_flag = deleting == true
        end)
        local parent = world:entity()
        local child = world:entity()
        world:set(child, A, 1)
        world:add(child, pair(ecs.ChildOf, parent))
        local survivor = world:entity()
        world:add(survivor, pair(Likes, parent))
        world:delete(parent)
        CHECK(flags[child] == true)
        CHECK(pair_flag == false and world:contains(survivor) and not world:has(survivor, pair(Likes, parent)))
    end

    CASE("a removal hook may remove other ids of the entity being deleted and delete other entities")
    do
        local world = ecs.world()
        local A, B = world:component(), world:component()
        local other = world:entity()
        world:set(A, ecs.OnRemove, function(entity: any)
            world:remove(entity, B)
            world:delete(other)
        end)
        local e = world:entity()
        world:set(e, A, 1)
        world:set(e, B, 2)
        world:delete(e)
        CHECK(not world:contains(e) and not world:contains(other))
        CHECK(count(world:query(A)) == 0 and count(world:query(B)) == 0)
    end

    CASE("a hook of a child deleted by a cascade may write into the parent being deleted")
    do
        local world = ecs.world()
        local A, Mark = world:component(), world:component()
        world:set(A, ecs.OnRemove, function(entity: any)
            local parent = world:parent(entity)
            if parent then
                world:set(parent, Mark, 1)
            end
        end)
        local parent = world:entity()
        for _ = 1, 3 do
            local child = world:entity()
            world:set(child, A, 1)
            world:add(child, pair(ecs.ChildOf, parent))
        end
        world:delete(parent)
        CHECK(not world:contains(parent))
        CHECK(count(world:query(A)) == 0 and count(world:query(Mark)) == 0 and count(world:each(Mark)) == 0)
    end
end)

TEST("4.3 relations", function()
    CASE("pair, pair_first and pair_second round-trip")
    do
        local world = ecs.world()
        local R, t = world:entity(), world:entity()
        local p = pair(R, t)
        CHECK(ecs.pair_first(world, p) == R and ecs.pair_second(world, p) == t)
    end

    CASE("an exclusive relation replaces its target")
    do
        local world = ecs.world()
        local R = world:entity()
        world:add(R, ecs.Exclusive)
        local e, t1, t2 = world:entity(), world:entity(), world:entity()
        world:add(e, pair(R, t1))
        world:add(e, pair(R, t2))
        CHECK(world:has(e, pair(R, t2)) and not world:has(e, pair(R, t1)) and world:target(e, R) == t2)
    end

    CASE("deleting a target deletes the sources under a delete policy and removes the pairs by default")
    do
        local world = ecs.world()
        local Owner, Likes = world:entity(), world:entity()
        world:add(Owner, pair(ecs.OnDeleteTarget, ecs.Delete))
        local agent = world:entity()
        local owned, fan = world:entity(), world:entity()
        world:add(owned, pair(Owner, agent))
        world:add(fan, pair(Likes, agent))
        world:delete(agent)
        CHECK(not world:contains(owned))
        CHECK(world:contains(fan) and not world:has(fan, pair(Likes, agent)))
    end

    CASE("ChildOf with children and its cascade; target by index; a wildcard query")
    do
        local world = ecs.world()
        local R = world:entity()
        local parent = world:entity()
        local children: { any } = {}
        for i = 1, 3 do
            local child = world:entity()
            world:add(child, pair(ecs.ChildOf, parent))
            children[i] = child
        end
        CHECK(count(world:children(parent)) == 3 and world:parent(children[1]) == parent)
        local e = world:entity()
        local t1, t2 = world:entity(), world:entity()
        world:add(e, pair(R, t1))
        world:add(e, pair(R, t2))
        CHECK(world:target(e, R, 0) == t1 and world:target(e, R, 1) == t2 and world:target(e, R, 2) == nil)
        CHECK(count(world:query(pair(R, ecs.Wildcard))) == 1)
        world:delete(parent)
        CHECK(not world:contains(children[1]) and not world:contains(children[3]))
    end

    CASE("a data pair holds one value per target; targets iterates a snapshot; remove_all of a pair")
    do
        local world = ecs.world()
        local Expiry = world:component()
        local holder, other = world:entity(), world:entity()
        local t1, t2 = world:entity(), world:entity()
        world:set(holder, pair(Expiry, t1), 10)
        world:set(holder, pair(Expiry, t2), 20)
        world:set(other, pair(Expiry, t1), 30)
        CHECK(world:get(holder, pair(Expiry, t1)) == 10 and world:get(holder, pair(Expiry, t2)) == 20)
        world:set(holder, pair(Expiry, t1), 11) -- refreshed
        CHECK(world:get(holder, pair(Expiry, t1)) == 11)
        local seen = 0
        for t in world:targets(holder, Expiry) do
            seen += 1
            world:remove(holder, pair(Expiry, t)) -- the snapshot goes on
        end
        CHECK(seen == 2 and world:target(holder, Expiry) == nil)
        world:remove_all(pair(Expiry, t1))
        CHECK(not world:has(other, pair(Expiry, t1)) and world:contains(other))
    end

    CASE("one entity used as a tag and as a relation keeps both roles apart")
    do
        local world = ecs.world()
        local X = world:entity()
        local t = world:entity()
        local e = world:entity()
        world:add(e, X)
        world:add(e, pair(X, t))
        world:remove(e, X)
        CHECK(not world:has(e, X) and world:has(e, pair(X, t)))
        world:add(e, X)
        world:remove(e, pair(X, t))
        CHECK(world:has(e, X) and not world:has(e, pair(X, t)))
        CHECK(count(world:each(X)) == 1 and count(world:query(pair(X, ecs.Wildcard))) == 0)
    end
end)

TEST("4.4 loops", function()
    CASE("each of an id; query values with with and without; a stored query sees ids made after it")
    do
        local world = ecs.world()
        local A, T, U = world:component() :: ecs.Component<number>, world:entity(), world:entity()
        local stored = world:query(A):with(T):without(U):cached()
        for i = 1, 10 do
            local e = world:entity()
            world:set(e, A, i)
            world:add(e, T)
            if i % 2 == 0 then
                world:add(e, U)
            end
        end
        local sum = 0
        for _, a in stored do
            sum += a
        end
        CHECK(sum == 1 + 3 + 5 + 7 + 9 and count(world:each(T)) == 10)
    end

    CASE("the current entity of a loop may be changed, lose the filter tag of the loop or be deleted")
    do
        local world = ecs.world()
        local A, T = world:component() :: ecs.Component<number>, world:entity()
        for i = 1, 300 do
            local e = world:entity()
            world:set(e, A, i)
            world:add(e, T)
        end
        local seen: { [any]: number } = {}
        local twice = false
        for e, a in world:query(A):with(T) do
            seen[e] = (seen[e] or 0) + 1
            twice = twice or seen[e] > 1
            if a % 3 == 0 then
                world:set(e, A, a + 1000) -- changed
            elseif a % 3 == 1 then
                world:remove(e, T) -- loses the filter tag
            else
                world:delete(e)
            end
        end
        local n = 0
        for _ in seen do
            n += 1
        end
        CHECK(n == 300 and not twice)
    end

    CASE("a loop that deletes other entities visits no living entity twice; a deleted one at most once")
    do
        local world = ecs.world()
        local T = world:entity()
        local list: { any } = {}
        for i = 1, 400 do
            local e = world:entity()
            world:add(e, T)
            list[i] = e
        end
        local seen: { [any]: number } = {}
        local ok = true
        for e in world:each(T) do
            seen[e] = (seen[e] or 0) + 1
            if seen[e] > 1 then
                ok = false
            end
            if world:contains(e) then
                local other = list[(ecs.ECS_ID(e) * 7) % #list + 1]
                world:delete(other)
            end
        end
        CHECK(ok)
    end

    CASE("nested loops over one stored query and over inline queries, also when the inner loop changes the world")
    do
        local world = ecs.world()
        local A, B = world:component() :: ecs.Component<number>, world:component() :: ecs.Component<number>
        for i = 1, 50 do
            local e = world:entity()
            world:set(e, A, i)
            if i % 2 == 0 then
                world:set(e, B, i)
            end
        end
        local stored = world:query(A):cached()
        local outer, inner = 0, 0
        for _ in stored do
            outer += 1
            for e2, a in stored do
                inner += 1
                if a % 10 == 0 then
                    world:set(e2, A, a) -- a change inside the inner loop
                end
            end
            for _ in world:query(A, B) do
            end
        end
        CHECK(outer == 50 and inner == 50 * 50)
    end

    CASE(
        "world:each and world:children return the members at the start of the loop, in ascending slot order, for any layout"
    )
    do
        -- layouts: one member, a few, members 32 and 64 slots apart, runs of 8, a dense block
        local layouts: { { any } } = {
            { "one", 1, 1 },
            { "few", 3, 1 },
            { "32 apart", 200, 32 },
            { "64 apart", 200, 64 },
            { "runs of 8", 200, 0 },
            { "dense", 3000, 1 },
        }
        local ok = true
        for _, layout in layouts do
            local world = ecs.world()
            local Tag = world:entity()
            local parent = world:entity()
            local entities: { any } = {}
            for i = 1, 20000 do
                entities[i] = world:entity()
            end
            local members: { any } = {}
            local count_members, step = layout[2] :: number, layout[3] :: number
            for k = 1, count_members do
                local index = if step == 0 then (k - 1) // 8 * 96 + (k - 1) % 8 + 1 else (k - 1) * step + 1
                local e = entities[index]
                world:add(e, Tag)
                world:add(e, pair(ecs.ChildOf, parent))
                members[k] = e
            end
            local loops: { () -> any } = {
                function(): any
                    return world:each(Tag)
                end,
                function(): any
                    return world:children(parent)
                end,
            }
            for _, iterate in loops do
                local visited: { any } = {}
                local first = true
                for e in iterate() do
                    table.insert(visited, e)
                    if first then
                        first = false
                        -- the id given ahead of the loop: in a word with members, in a word and
                        -- a block of 1024 slots without members, to new entities
                        for _, index in { 2, 17, 33, 65, 5000, 19999 } do
                            local other = entities[index]
                            if not world:has(other, Tag) then
                                world:add(other, Tag)
                                world:add(other, pair(ecs.ChildOf, parent))
                            end
                        end
                        for _ = 1, 3 do
                            local fresh = world:entity()
                            world:add(fresh, Tag)
                            world:add(fresh, pair(ecs.ChildOf, parent))
                            table.insert(entities, fresh)
                        end
                        if #members > 2 then
                            world:delete(members[#members]) -- a member ahead: may come as a dead id
                        end
                    end
                end
                -- the members of the start, in ascending slot order (a deleted one included)
                if #visited ~= #members then
                    ok = false
                    print(`  {layout[1]}: {#visited} returned, {#members} members at the start`)
                else
                    for k, e in visited do
                        if e ~= members[k] then
                            ok = false
                            print(`  {layout[1]}: member {k} out of place`)
                            break
                        end
                    end
                end
                -- the next loop starts from the world as it is now
                members = {}
                for _, e in entities do
                    if world:contains(e) and world:has(e, Tag) then
                        table.insert(members, e)
                    end
                end
                table.sort(members, function(a: any, b: any): boolean
                    return ecs.ECS_ID(a) < ecs.ECS_ID(b)
                end)
            end
        end
        CHECK(ok)
    end

    CASE("entities created during a query loop: what this release does")
    do
        local world = ecs.world()
        local A = world:component()
        for i = 1, 100 do
            world:set(world:entity(), A, i)
        end
        local stored = world:query(A):cached()
        count(stored) -- a stored query with its list
        local made: { [any]: boolean } = {}
        local made_count, visited_new, visits = 0, 0, 0
        for e in stored do
            visits += 1
            if made[e] then
                visited_new += 1
            end
            if made_count < 5 then
                local fresh = world:entity()
                world:set(fresh, A, 0)
                made[fresh] = true
                made_count += 1
            end
        end
        -- not asserted: the case reports what the release does
        print(`  5 entities made during a loop over a stored query of 100: {visited_new} of them visited`)
        CHECK(visits == 100 + visited_new)
    end
end)

TEST("4.5 debugging aids", function()
    CASE("a debug world raises an error on a change of a dead id")
    do
        local world = ecs.world(true)
        local A = world:component()
        local e = world:entity()
        world:delete(e)
        CHECK_EXPECT_ERR(function()
            world:set(e, A, 1)
            return true
        end)
    end

    CASE("a debug world warns once when the shared query states are all taken (the warning prints once)")
    do
        local world = ecs.world(true)
        local shared = 0
        for _ = 1, 1030 do
            local e = world:entity()
            world:query(e) -- the first request marks the shape
            local q: any = world:query(e)
            if q.state.shared == true then
                shared += 1
            end
        end
        CHECK(shared == 1024)
    end
end)

-- a failed case must fail the process (CI reads the exit code)
assert(FINISH() == 0, "some test cases failed")
