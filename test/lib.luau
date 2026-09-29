--!strict
--# selene: allow(empty_loop) -- benchmark loops iterate for their cost only
--[[
    Tests of mErCS features that the shared core suite (test/core.luau) and the jecs
    suite (test/jecs_compat) do not cover: query:each, cached query list mode and its patches
    after small changes (and passes over the bitsets after many), empty queries, changes during
    iteration, more than 4 ids in get/has, relationships and (*, T) targets (also before their
    first read), slot pools, large worlds, cleanup without leftovers, signals, hooks of ids
    beyond the shared signature tables, cascades deeper than 100 levels, hooks and signals on
    builtin ids, pair records freed in batches, the shared query shapes of deleted entities,
    the iteration contexts that queries which are not cached reuse, the values of wildcard
    pairs (their mirrors), world:each and world:children over large records, query shapes
    shared from their second request, the buffered loops of small queries that are not cached,
    match lists that skip the changes outside their unchanged terms, and query monitors.

    Run from the repository root:
        luau test/lib.luau
]]

local testkit = require("@testkit")
local ecs = require("@lib")
local gc = require("@bench/gc")

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

-- The internal state of a query handle: white-box checks of shared shapes and match lists.
local function internal(q: any): any
    return q.state
end

-- Whether a query shape is shared once it is requested again: a shape is shared from its second
-- request, and a variant (with, without, any) from its second request after its base is shared.
local function shared_shape(make: () -> any): boolean
    for _ = 1, 3 do
        if internal(make()).shared == true then
            return true
        end
    end
    return false
end

TEST("query:each", function()
    local world = ecs.world()
    local A, B, C = world:component(), world:component(), world:component()
    local T = world:entity()
    for i = 1, 1000 do
        local e = world:entity()
        world:set(e, A, i)
        if i % 2 == 0 then
            world:set(e, B, i * 10)
        end
        if i % 3 == 0 then
            world:add(e, T)
        end
        if i == 500 then
            world:set(e, C, "c")
        end
    end

    CASE("values match world:get")
    local n, ok = 0, true
    world:query(A, B):each(function(e: any, a: any, b: any)
        n += 1
        if world:get(e, A) ~= a or b ~= a * 10 then
            ok = false
        end
    end)
    CHECK(n == 500 and ok)

    CASE("without and with")
    n = 0
    world:query(A):without(B):with(T):each(function(_e: any, a: any)
        n += 1
        if a % 2 == 0 or a % 3 ~= 0 then
            ok = false
        end
    end)
    CHECK(n == 167 and ok)

    CASE("sparse match")
    n = 0
    world:query(A, C):each(function(_e: any, a: any, c: any)
        n += 1
        ok = ok and a == 500 and c == "c"
    end)
    CHECK(n == 1 and ok)

    CASE("no values")
    n = 0
    world:query(T):each(function(_e: any)
        n += 1
    end)
    CHECK(n == 333)
end)

TEST("cached queries", function()
    local world = ecs.world()
    local A, B = world:component() :: ecs.Component<number>, world:component() :: ecs.Component<number>
    local list = {}
    for i = 1, 2000 do
        local e = world:entity()
        world:set(e, A, i)
        if i % 50 == 0 then
            world:set(e, B, -i)
        end
        list[i] = e
    end
    local q = world:query(A, B):cached()

    CASE("repeated iteration switches to the dense list and stays correct")
    local sums = {}
    for round = 1, 4 do
        local total = 0
        for _e, a, b in q do
            total += a + b
        end
        sums[round] = total
    end
    CHECK(sums[1] == 0 and sums[2] == 0 and sums[3] == 0 and sums[4] == 0)

    CASE("changes are observed")
    world:set(list[7], B, 1)
    local seen = false
    for e, a, b in q do
        if e == list[7] then
            seen = a == 7 and b == 1
        end
    end
    CHECK(seen)
    world:remove(list[50], B)
    CHECK(count(q) == 40)
    CHECK(count(q) == 40)
    local n = 0
    q:each(function()
        n += 1
    end)
    CHECK(n == 40)

    CASE("value changes without structural changes are visible in list mode")
    for _ = 1, 3 do
        for _ in q do
        end
    end
    world:set(list[100], A, 12345)
    local value = nil
    for e, a in q do
        if e == list[100] then
            value = a
        end
    end
    CHECK(value == 12345)
    q:each(function(e: any, a: any)
        if e == list[100] then
            value = a
        end
    end)
    CHECK(value == 12345)
end)

TEST("a value set on a component added without one", function()
    local world = ecs.world()
    local C, Other = world:component(), world:component()
    local list = {}
    for i = 1, 3000 do
        local e = world:entity()
        world:set(e, Other, i)
        if i % 50 == 0 and i < 2000 then
            world:set(e, C, i)
        end
        list[i] = e
    end
    local lonely = list[2900]
    world:add(lonely, C) -- no value: the page of C around it does not exist yet
    local q = world:query(C):cached()
    for _ = 1, 3 do -- stable scattered matches: the match list is used
        count(q)
    end
    world:set(lonely, C, 42)
    local seen, each_seen = nil, nil
    for e, v in q do
        if e == lonely then
            seen = v
        end
    end
    q:each(function(e: any, v: any)
        if e == lonely then
            each_seen = v
        end
    end)
    CHECK(seen == 42 and each_seen == 42 and world:get(lonely, C) == 42)
end)

TEST("changing a cached query after iterating it", function()
    local world = ecs.world()
    local Likes, Enemy, Filler = world:entity(), world:entity(), world:component()
    local bob = world:entity()
    local list = {}
    for i = 1, 3000 do
        local e = world:entity()
        world:set(e, Filler, i)
        if i % 40 == 0 then
            world:add(e, pair(Likes, bob))
            if i % 400 == 0 then
                world:add(e, Enemy)
            end
        end
        list[i] = e
    end
    -- an id that is not alive keeps the shape from being shared: :cached() keeps a state of its
    -- own, which the modifiers change in place (it excludes nothing: no entity has the id)
    local gone = world:entity()
    world:delete(gone)
    local q = world:query(pair(Likes, bob)):without(gone):cached()
    local function counts(times: number): string
        local seen: { string } = {}
        for i = 1, times do -- repeated iterations of an unchanged world use the match list
            seen[i] = tostring(count(q))
        end
        return table.concat(seen, " ")
    end
    CHECK(counts(2) == "75 75")
    q:with(Enemy)
    CHECK(counts(3) == "7 7 7")
    world:add(list[40], Enemy)
    world:add(list[80], Enemy)
    CHECK(count(q) == 9) -- the new term is observed
    q:without(Filler)
    CHECK(count(q) == 0)
end)

TEST("reused iteration state", function()
    local world = ecs.world()
    local A, B = world:component(), world:component()
    for i = 1, 40 do
        local e = world:entity()
        world:set(e, A, i)
        if i % 2 == 0 then
            world:set(e, B, i)
        end
    end
    local dense = world:query(A)
    local scattered = world:query(A, B)

    CASE("nested loops over the same query")
    for _, q in { dense, scattered } do
        local expected = count(q)
        for _ = 1, 3 do -- the later rounds reuse the state
            local n = 0
            for _ in q do
                for _ in q do
                    n += 1
                end
            end
            CHECK(n == expected * expected)
        end
    end

    CASE("a loop left early does not disturb the next one")
    for _, q in { dense, scattered } do
        local expected = count(q)
        for _ = 1, 3 do
            for _ in q do
                break
            end
            CHECK(count(q) == expected)
        end
    end

    CASE("each inside a loop over the same query")
    local n = 0
    for _ in scattered do
        scattered:each(function()
            n += 1
        end)
    end
    CHECK(n == 20 * 20)
    CHECK(count(world:query(A, B)) == 20)

    CASE("a nested loop that rebuilds the match list does not disturb the running one")
    local w2 = ecs.world()
    local C, D = w2:component(), w2:component()
    local list = {}
    for i = 1, 400 do
        local e = w2:entity()
        w2:set(e, C, i)
        if i % 7 == 0 then
            w2:set(e, D, i)
        end
        list[i] = e
    end
    local q = w2:query(C, D):cached()
    count(q)
    count(q) -- stable and scattered: the match list is used
    for _, use_each in { false, true } do
        local visited, wrong = 0, 0
        local function visit(e: any, c: any, d: any)
            visited += 1
            if w2:get(e, C) ~= c or w2:get(e, D) ~= d then
                wrong += 1
            end
            if visited == 5 then
                -- a new match before the current one: the rebuilt list shifts
                w2:set(list[if use_each then 2 else 1], D, 0)
                count(q) -- direct after the change
                count(q) -- builds the list again
            end
        end
        if use_each then
            q:each(visit)
        else
            for e, c, d in q do
                visit(e, c, d)
            end
        end
        CHECK(wrong == 0)
        CHECK(visited == 57 or visited == 58)
        count(q)
        count(q)
    end
end)

TEST("changes during iteration", function()
    local world = ecs.world()
    local A, B = world:component(), world:component()
    local list = {}
    for i = 1, 300 do
        local e = world:entity()
        world:set(e, A, i)
        world:set(e, B, i)
        list[i] = e
    end

    CASE("deleting other entities of the current run does not break the loop")
    local visited = 0
    local deleted = 0
    for e in world:query(A, B) do
        visited += 1
        if visited == 1 then
            for i = 2, 40, 2 do
                world:delete(list[i])
                deleted += 1
            end
        end
        if not world:contains(e) then
            -- a deleted entity may still be reported once in the current word
            visited -= 1
        end
    end
    CHECK(visited <= 300 - deleted + 1)
    CHECK(count(world:query(A, B)) == 300 - deleted)

    CASE("deleting entities ahead in partial words visits every other match once")
    local P, Q = world:component(), world:component()
    local interleaved = {}
    for i = 1, 400 do
        local e = world:entity()
        world:set(e, P, i)
        if i % 3 ~= 0 then
            world:set(e, Q, i)
        end
        interleaved[i] = e
    end
    local visits: { [any]: number } = {}
    local dead_seen = 0
    local first_pass = true
    for e in world:query(P, Q) do
        if first_pass then
            first_pass = false
            for i = 10, 400, 10 do
                world:delete(interleaved[i])
            end
        end
        if world:contains(e) then
            visits[e] = (visits[e] or 0) + 1
        else
            dead_seen += 1
        end
    end
    local expected_visits, once = 0, true
    for i, e in interleaved do
        if i % 3 ~= 0 and world:contains(e) then
            expected_visits += 1
            once = once and visits[e] == 1
        end
    end
    CHECK(once and expected_visits > 0)
    CHECK(dead_seen <= 40)

    CASE("uncached queries of a stable shape use the shared list; deletions ahead are safe")
    local S, U = world:component(), world:component()
    local scattered = {}
    for i = 1, 600 do
        local e = world:entity()
        world:set(e, S, i)
        if i % 5 == 0 then
            world:set(e, U, i)
        end
        scattered[i] = e
    end
    for _ = 1, 3 do
        CHECK(count(world:query(S, U)) == 120)
    end
    local seen_alive: { [any]: number } = {}
    local started = false
    for e in world:query(S, U) do
        if not started then
            started = true
            for i = 50, 600, 50 do
                world:delete(scattered[i])
            end
        end
        if world:contains(e) then
            seen_alive[e] = (seen_alive[e] or 0) + 1
        end
    end
    local all_once = true
    local alive_matches = 0
    for i, e in scattered do
        if i % 5 == 0 and world:contains(e) then
            alive_matches += 1
            all_once = all_once and seen_alive[e] == 1
        end
    end
    CHECK(all_once and alive_matches == 108)
    CHECK(count(world:query(S, U)) == 108)

    CASE("removing the queried component from the current entity")
    local n = 0
    for e in world:query(A, B) do
        world:remove(e, B)
        n += 1
    end
    CHECK(n == 300 - deleted)
    CHECK(count(world:query(A, B)) == 0)

    CASE("each over deleted entities skips them")
    for i = 1, 300 do
        if world:contains(list[i]) then
            world:set(list[i], B, i)
        end
    end
    local calls = 0
    world:query(A, B):each(function(e: any)
        calls += 1
        if calls == 1 then
            for i = 41, 80 do
                world:delete(list[i])
            end
        end
        CHECK(world:contains(e) or calls == 1)
    end)
    CHECK(count(world:query(A, B)) == 300 - deleted - 40)
end)

TEST("get and has with many ids", function()
    local world = ecs.world()
    local ids = {}
    for i = 1, 12 do
        ids[i] = world:component()
    end
    local e = world:entity()
    for i, id in ids do
        world:set(e, id, i)
    end

    CASE("positional up to 8")
    local v1, v2, v3, v4, v5, v6, v7, v8 = world:get(e, ids[1], ids[2], ids[3], ids[4], ids[5], ids[6], ids[7], ids[8])
    CHECK(v1 == 1 and v2 == 2 and v3 == 3 and v4 == 4 and v5 == 5 and v6 == 6 and v7 == 7 and v8 == 8)
    CHECK(world:has(e, ids[1], ids[2], ids[3], ids[4], ids[5], ids[6], ids[7], ids[8]))

    CASE("more than 8 positional ids is an error")
    CHECK_EXPECT_ERR(function()
        local w: any = world
        return w:get(e, ids[1], ids[2], ids[3], ids[4], ids[5], ids[6], ids[7], ids[8], ids[9])
    end)

    CASE("lists take any number of ids")
    local values = world:get_list(e, ids)
    CHECK(#values == 12 and values[12] == 12)
    CHECK(world:has_all(e, ids))
    world:remove(e, ids[11])
    CHECK(not world:has_all(e, ids))
end)

TEST("queries with more than 8 values", function()
    local world = ecs.world()
    local ids = {}
    for i = 1, 11 do
        ids[i] = world:component()
    end
    local list = {}
    for n = 1, 300 do
        local e = world:entity()
        for i, id in ids do
            world:set(e, id, n * 100 + i)
        end
        list[n] = e
    end
    world:remove(list[7], ids[11])

    local function check_row(e: any, ...: any): boolean
        local n = table.find(list, e) :: number
        for i = 1, 11 do
            if select(i, ...) ~= n * 100 + i then
                return false
            end
        end
        return select("#", ...) == 11
    end

    CASE("for-in returns every value")
    -- a dynamic list of ids: the typed overloads need a fixed count, hence the cast
    local q = (world :: any):query(table.unpack(ids))
    local seen, ok = 0, true
    for e, a, b, c, d, e5, f, g, h, i, j, k in q do
        seen += 1
        ok = ok and check_row(e, a, b, c, d, e5, f, g, h, i, j, k)
    end
    CHECK(seen == 299 and ok)

    CASE("each passes every value")
    seen, ok = 0, true
    q:each(function(e: any, ...: any)
        seen += 1
        ok = ok and check_row(e, ...)
    end)
    CHECK(seen == 299 and ok)

    CASE("wildcard values through each")
    local Owns = world:component()
    local target = world:entity()
    world:set(list[1], pair(Owns, target), "x")
    local got = nil
    world:query(ids[1], pair(Owns, ecs.Wildcard)):each(function(_e: any, _a: any, v: any)
        got = v
    end)
    CHECK(got == "x")
end)

TEST("relationships", function()
    local world = ecs.world()
    local Likes = world:entity()
    local Owns = world:component()

    CASE("targets are sorted and target() indexes them")
    local e = world:entity()
    local t1, t2, t3 = world:entity(), world:entity(), world:entity()
    world:add(e, pair(Likes, t3))
    world:add(e, pair(Likes, t1))
    world:add(e, pair(Likes, t2))
    CHECK(world:target(e, Likes, 0) == t1)
    CHECK(world:target(e, Likes, 1) == t2)
    CHECK(world:target(e, Likes, 2) == t3)
    CHECK(world:target(e, Likes, 3) == nil)
    local list = {}
    for t in world:targets(e, Likes) do
        table.insert(list, t)
    end
    CHECK(#list == 3 and list[1] == t1 and list[3] == t3)

    CASE("pair values")
    world:set(e, pair(Owns, t1), 10)
    CHECK(world:get(e, pair(Owns, t1)) == 10)
    CHECK(world:get(e, pair(Owns, ecs.Wildcard)) == 10)

    CASE("wildcard queries")
    CHECK(count(world:query(pair(Likes, ecs.Wildcard))) == 1)
    CHECK(count(world:query(pair(ecs.Wildcard, t2))) == 1)
    world:remove(e, pair(Likes, t2))
    CHECK(count(world:query(pair(ecs.Wildcard, t2))) == 0)
    CHECK(world:target(e, Likes, 1) == t3)

    CASE("removing a wildcard removes every matching pair")
    world:remove(e, pair(Likes, ecs.Wildcard))
    CHECK(world:target(e, Likes) == nil)
    CHECK(not world:has(e, pair(Likes, t1)))

    CASE("ChildOf is exclusive")
    local child = world:entity()
    local p1, p2 = world:entity(), world:entity()
    world:add(child, pair(ecs.ChildOf, p1))
    world:add(child, pair(ecs.ChildOf, p2))
    CHECK(world:parent(child) == p2)
    CHECK(not world:has(child, pair(ecs.ChildOf, p1)))
    CHECK(count(world:children(p1)) == 0)
    CHECK(count(world:children(p2)) == 1)

    CASE("deleting a parent deletes its children recursively")
    local root = world:entity()
    local a = world:entity()
    local b = world:entity()
    world:add(a, pair(ecs.ChildOf, root))
    world:add(b, pair(ecs.ChildOf, a))
    world:delete(root)
    CHECK(not world:contains(a) and not world:contains(b))

    CASE("deleting a very deep hierarchy does not overflow the stack")
    local top = world:entity()
    local chain = {}
    local cursor = top
    for i = 1, 20000 do
        local node = world:entity()
        world:add(node, pair(ecs.ChildOf, cursor))
        chain[i] = node
        cursor = node
    end
    world:delete(top)
    local survivors = 0
    for _, node in chain do
        if world:contains(node) then
            survivors += 1
        end
    end
    CHECK(survivors == 0)

    CASE("deleting a target removes pairs of other relations")
    local holder = world:entity()
    local target = world:entity()
    world:add(holder, pair(Likes, target))
    world:delete(target)
    CHECK(world:contains(holder))
    CHECK(world:target(holder, Likes) == nil)
end)

TEST("hooks that change the entity being deleted", function()
    local world = ecs.world()
    local A, B, C, D = world:component(), world:component(), world:component(), world:component()
    world:set(A, ecs.OnRemove, function(e: any)
        world:remove(e, B)
    end)
    world:set(C, ecs.OnRemove, function(e: any)
        world:set(e, D, true)
    end)

    CASE("ids removed or added by on_remove hooks do not stay in the world")
    local e = world:entity()
    world:set(e, A, 1)
    world:set(e, B, 2)
    world:set(e, C, 3)
    world:delete(e)
    CHECK(not world:contains(e))
    CHECK(count(world:query(A)) == 0 and count(world:query(B)) == 0)
    CHECK(count(world:query(C)) == 0 and count(world:query(D)) == 0)

    CASE("the reused slot starts empty")
    local f = world:entity()
    CHECK(ecs.ECS_ID(f) == ecs.ECS_ID(e))
    CHECK(not world:has(f, A) and not world:has(f, B) and not world:has(f, D))
    world:set(f, B, 5)
    world:delete(f)
    CHECK(count(world:query(B)) == 0)

    CASE("hooks that delete the entity itself or each other")
    local G: ecs.Component<any> = world:component()
    world:set(G, ecs.OnRemove, function(entity: any)
        local other = world:get(entity, G)
        world:delete(entity)
        if other then
            world:delete(other)
        end
    end)
    local g = world:entity()
    world:set(g, G, false)
    world:set(g, A, 1)
    world:delete(g)
    CHECK(not world:contains(g))
    local g1, g2 = world:entity(), world:entity()
    world:set(g1, G, g2)
    world:set(g2, G, g1)
    world:set(g2, A, 2)
    world:delete(g1)
    CHECK(not world:contains(g1) and not world:contains(g2))
    CHECK(count(world:query(G)) == 0 and count(world:query(A)) == 0)
    local h1, h2, h3 = world:entity(), world:entity(), world:entity()
    CHECK(h1 ~= h2 and h2 ~= h3 and h1 ~= h3)
    CHECK(world:contains(h1) and world:contains(h2) and world:contains(h3))

    CASE("the hook of an id removed by an earlier hook runs once")
    local P, Q = world:component(), world:component()
    local q_calls = 0
    world:set(P, ecs.OnRemove, function(entity: any)
        world:remove(entity, Q)
    end)
    world:set(Q, ecs.OnRemove, function()
        q_calls += 1
    end)
    for _, deleting in { false, true } do
        local k = world:entity()
        world:set(k, P, 1)
        world:set(k, Q, 1)
        if deleting then
            world:delete(k)
        else
            world:clear(k)
        end
    end
    CHECK(q_calls == 2)

    CASE("a hook that clears its own entity does not run the hooks again")
    local Once = world:component()
    local once_calls = 0
    world:set(Once, ecs.OnRemove, function(entity: any)
        once_calls += 1
        world:clear(entity)
    end)
    local o = world:entity()
    world:set(o, Once, 1)
    world:set(o, A, 1)
    world:delete(o)
    CHECK(once_calls == 1 and not world:contains(o))

    CASE("an entity that takes the slot inside a hook runs its own hooks")
    local Reuse = world:component()
    local reuse_calls: { any } = {}
    local fresh: any = nil
    world:set(Reuse, ecs.OnRemove, function(entity: any)
        table.insert(reuse_calls, entity)
        if fresh == nil then
            fresh = false
            world:delete(entity) -- the entity goes inside its own hook
            local taker = world:entity() -- takes its slot
            fresh = taker
            world:set(taker, Reuse, 2)
            world:delete(taker)
        end
    end)
    local r = world:entity()
    world:set(r, Reuse, 1)
    world:delete(r)
    CHECK(#reuse_calls == 2 and reuse_calls[1] == r and reuse_calls[2] == fresh)
    CHECK(ecs.ECS_ID(fresh) == ecs.ECS_ID(r) and not world:contains(fresh))

    CASE("ids written into a parent by the hooks of its cascade do not stay in the world")
    local Mark = world:entity()
    local Counter = world:component()
    world:set(Mark, ecs.OnRemove, function(entity: any)
        local parent = world:parent(entity)
        if parent then
            world:set(parent, Counter, 1)
        end
    end)
    local owner = world:entity()
    local parent = world:entity()
    world:add(parent, pair(ecs.ChildOf, owner))
    local child = world:entity()
    world:add(child, pair(ecs.ChildOf, parent))
    world:add(child, Mark)
    world:delete(parent)
    CHECK(not world:contains(parent) and not world:contains(child))
    CHECK(count(world:query(Counter)) == 0)
    for _ = 1, 4 do
        CHECK(not world:has(world:entity(), Counter))
    end
end)

TEST("on_remove hooks set, changed and released at any time", function()
    local world = ecs.world()
    local calls = 0
    local function hook()
        calls += 1
    end

    CASE("a hook set after the entity got the component runs on delete")
    local A = world:component()
    local e = world:entity()
    world:set(e, A, 1)
    world:set(A, ecs.OnRemove, hook)
    world:delete(e)
    CHECK(calls == 1)

    CASE("a removed hook does not run")
    world:remove(A, ecs.OnRemove)
    local f = world:entity()
    world:set(f, A, 1)
    world:delete(f)
    CHECK(calls == 1)

    CASE("a hook set on a relation after its pairs exist")
    local R = world:component()
    local t = world:entity()
    local g = world:entity()
    world:set(g, pair(R, t), 5)
    world:set(R, ecs.OnRemove, hook)
    world:delete(g)
    CHECK(calls == 2)

    CASE("the signature bit of a deleted hooked component is reused without the hook")
    local H = world:component()
    world:set(H, ecs.OnRemove, hook)
    local h = world:entity()
    world:set(h, H, 1)
    world:delete(H)
    CHECK(calls == 3)
    local N = world:component()
    local x = world:entity()
    world:set(x, N, 1)
    world:delete(x)
    CHECK(calls == 3)
    CHECK(count(world:query(N)) == 0)
end)

TEST("relation and target cleanup", function()
    local world = ecs.world()
    local A = world:component()

    CASE("several targets: deleting one keeps the others sorted")
    local Likes = world:entity()
    local e = world:entity()
    local t1, t2, t3 = world:entity(), world:entity(), world:entity()
    world:add(e, pair(Likes, t3))
    world:add(e, pair(Likes, t2))
    world:add(e, pair(Likes, t1))
    world:delete(t2)
    CHECK(world:target(e, Likes, 0) == t1 and world:target(e, Likes, 1) == t3)
    CHECK(world:target(e, Likes, 2) == nil)
    CHECK(count(world:query(pair(Likes, ecs.Wildcard))) == 1)

    CASE("deleting the source clears the target records")
    world:delete(e)
    CHECK(count(world:query(pair(ecs.Wildcard, t1))) == 0)
    CHECK(count(world:query(pair(ecs.Wildcard, t3))) == 0)
    CHECK(count(world:query(pair(Likes, ecs.Wildcard))) == 0)

    CASE("deleting a relation removes its pairs; recycled records do not inherit members")
    local R = world:entity()
    local x = world:entity()
    world:set(x, A, 1)
    world:add(x, pair(R, t1))
    world:add(x, pair(R, t3))
    world:delete(R)
    CHECK(world:contains(x) and world:get(x, A) == 1)
    CHECK(count(world:query(pair(ecs.Wildcard, t1))) == 0)
    local R2 = world:entity()
    local y = world:entity()
    world:add(y, pair(R2, t1))
    CHECK(count(world:query(pair(R2, ecs.Wildcard))) == 1)
    CHECK(not world:has(x, pair(R2, t1)))
    world:delete(x)
    CHECK(count(world:query(pair(R2, ecs.Wildcard))) == 1)
    CHECK(count(world:query(A)) == 0)

    CASE("a deleted entity with several targets leaves no relation state in its slot")
    local Rel = world:entity()
    local u1, u2, u3 = world:entity(), world:entity(), world:entity()
    local owner = world:entity()
    world:add(owner, pair(Rel, u1))
    world:add(owner, pair(Rel, u2))
    world:delete(owner)
    local heir = world:entity()
    CHECK(ecs.ECS_ID(heir) == ecs.ECS_ID(owner))
    world:add(heir, pair(Rel, u3))
    CHECK(world:target(heir, Rel, 0) == u3 and world:target(heir, Rel, 1) == nil)
    CHECK(count(world:query(pair(Rel, ecs.Wildcard))) == 1)

    CASE("removing a wildcard with several targets")
    local z = world:entity()
    world:add(z, pair(R2, t1))
    world:add(z, pair(R2, t3))
    world:remove(z, pair(R2, ecs.Wildcard))
    CHECK(world:target(z, R2) == nil)
    CHECK(count(world:query(pair(ecs.Wildcard, t3))) == 0)

    CASE("many targets of a relation on one entity, added and removed in any order, stay sorted")
    local Holds = world:component()
    local holder = world:entity()
    local items: { any } = {}
    for i = 1, 120 do
        items[i] = world:entity()
    end
    local seed = 77
    local function shuffled(): { any }
        local list = table.clone(items)
        for i = #list, 2, -1 do
            seed = seed * 16807 % 2147483647
            local j = seed % i + 1
            list[i], list[j] = list[j], list[i]
        end
        return list
    end
    local held: { [any]: boolean } = {}
    -- the targets by world:targets and world:target, the value of (Holds, *) (the lowest target)
    -- and a query over the pairs, against the set of held items
    local function sorted_ok(): boolean
        local want: { any } = {}
        for _, item in items do
            if held[item] then
                table.insert(want, item)
            end
        end
        local i = 0
        for t in world:targets(holder, Holds) do
            i += 1
            if t ~= want[i] or world:target(holder, Holds, i - 1) ~= t then
                return false
            end
        end
        if i ~= #want or world:target(holder, Holds, i) ~= nil then
            return false
        end
        local lowest: any = nil
        for _, value in world:query(pair(Holds, ecs.Wildcard)) do
            lowest = value
        end
        return lowest == (if want[1] then world:get(holder, pair(Holds, want[1])) else nil)
    end
    for i, item in shuffled() do
        world:set(holder, pair(Holds, item), i)
        held[item] = true
    end
    CHECK(sorted_ok())
    for i, item in shuffled() do
        if i % 3 ~= 0 then
            world:remove(holder, pair(Holds, item))
            held[item] = nil
        end
    end
    CHECK(sorted_ok())
    for i, item in items do
        if i % 2 == 0 and not held[item] then
            world:set(holder, pair(Holds, item), -i)
            held[item] = true
        end
    end
    CHECK(sorted_ok())
    world:delete(items[1])
    held[items[1]] = nil
    table.remove(items, 1)
    CHECK(sorted_ok())
end)

TEST("no leftovers", function()
    local world = ecs.world()
    local A = world:component()

    CASE("hierarchy churn releases records")
    gc.full()
    local before = gc.kb()
    for round = 1, 3 do
        for _ = 1, 2000 do
            local parent = world:entity()
            local child = world:entity()
            world:set(child, A, round)
            world:add(child, pair(ecs.ChildOf, parent))
            world:delete(parent)
        end
        gc.full()
    end
    local after = gc.kb()
    -- slots are reused and pair records are freed: memory stays flat
    CHECK(after - before < 64)
    CHECK(count(world:query(A)) == 0)
end)

TEST("signals", function()
    local world = ecs.world()
    local A = world:component()
    local log: { string } = {}

    CASE("several listeners and disconnect")
    local d1 = world:added(A, function(_e: any, _id: any, value: any)
        table.insert(log, `a1:{value}`)
    end)
    world:added(A, function(_e: any, _id: any, value: any)
        table.insert(log, `a2:{value}`)
    end)
    world:changed(A, function(_e: any, _id: any, value: any)
        table.insert(log, `c:{value}`)
    end)
    world:removed(A, function()
        table.insert(log, "r")
    end)
    local e = world:entity()
    world:set(e, A, 1)
    world:set(e, A, 2)
    d1()
    world:remove(e, A)
    world:set(e, A, 3)
    CHECK(table.concat(log, ",") == "a1:1,a2:1,c:2,r,a2:3")

    CASE("hooks on a relation apply to its pairs")
    local Rel = world:component()
    local seen = 0
    world:set(Rel, ecs.OnAdd, function()
        seen += 1
    end)
    local x = world:entity()
    world:set(x, pair(Rel, world:entity()), true)
    world:set(x, pair(Rel, world:entity()), true)
    CHECK(seen == 2)

    CASE("a listener that disconnects itself during a dispatch")
    local S = world:component()
    local order: { string } = {}
    local disconnect_once: () -> ()
    disconnect_once = world:added(S, function()
        table.insert(order, "once")
        disconnect_once()
    end)
    world:added(S, function()
        table.insert(order, "b")
    end)
    world:added(S, function()
        table.insert(order, "c")
    end)
    world:set(world:entity(), S, 1)
    world:set(world:entity(), S, 1)
    CHECK(table.concat(order, ",") == "once,b,c,b,c") -- none skipped, order kept

    CASE("hooks and signals coexist in any order")
    local B = world:component()
    local calls: { string } = {}
    world:changed(B, function()
        table.insert(calls, "signal")
    end)
    world:track(B)
    world:set(B, ecs.OnChange, function()
        table.insert(calls, "hook") -- set after the signal: must not replace it
    end)
    local y = world:entity()
    world:set(y, B, 1)
    world:tick()
    local changed = world:query(B):changed(B):cached()
    count(changed)
    world:set(y, B, 2)
    CHECK(table.concat(calls, ",") == "hook,signal")
    world:tick()
    CHECK(count(changed) == 1) -- tracking still works
    world:remove(B, ecs.OnChange)
    world:set(y, B, 3)
    CHECK(table.concat(calls, ",") == "hook,signal,signal")
    local late = 0
    world:set(B, ecs.OnChange, function()
        late += 1
    end)
    world:changed(B, function()
        late += 10
    end)
    world:set(y, B, 4)
    CHECK(late == 11)
    CHECK(world:get(B, ecs.OnChange) ~= nil)
end)

TEST("spans fast path", function()
    local world = ecs.world()
    local A, B = world:component(), world:component()
    for i = 1, 1000 do
        local e = world:entity()
        world:set(e, A, i)
        if i % 4 ~= 0 then
            world:set(e, B, i)
        end
    end
    CASE("spans visit exactly the matches")
    local pages = world:column(B)
    local n, sum = 0, 0
    for first, last, mask in world:query(A, B):spans() do
        local page = pages[first // ecs.PAGE_SIZE + 1]
        local offset = (first // ecs.PAGE_SIZE) * ecs.PAGE_SIZE - 1
        if mask == 4294967295 then
            for s = first, last :: number do
                n += 1
                sum += page[s - offset]
            end
        else
            local m = mask
            while m ~= 0 do
                local s = first + bit32.countrz(m)
                m = bit32.band(m, m - 1)
                n += 1
                sum += page[s - offset]
            end
        end
    end
    local expected_n, expected_sum = 0, 0
    for i = 1, 1000 do
        if i % 4 ~= 0 then
            expected_n += 1
            expected_sum += i
        end
    end
    CHECK(n == expected_n and sum == expected_sum)
end)

TEST("many ids per world (signatures beyond the shared tables)", function()
    local world = ecs.world()
    local ids: { any } = {}
    for i = 1, 400 do
        ids[i] = if i % 2 == 0 then world:component() else world:entity()
    end
    local e = world:entity()
    local f = world:entity()
    for i, id in ids do
        if i % 2 == 0 then
            world:set(e, id, i)
        else
            world:add(e, id)
        end
        if i % 7 == 0 then
            world:add(f, id)
        end
    end

    CASE("every id is reported and readable")
    CHECK(#world:ids(e) == 400)
    CHECK(world:get(e, ids[400]) == 400 and world:has(e, ids[399]))

    CASE("remove, clear and delete work for high record indices")
    world:remove(e, ids[350])
    CHECK(not world:has(e, ids[350]) and #world:ids(e) == 399)
    world:clear(e)
    CHECK(#world:ids(e) == 0 and count(world:query(ids[400])) == 0)
    world:delete(f)
    CHECK(count(world:query(ids[399])) == 0 and count(world:query(ids[7])) == 0)
    local g = world:entity()
    world:add(g, ids[301])
    CHECK(#world:ids(g) == 1 and count(world:query(ids[301])) == 1)

    CASE("deleting ids used by many entities")
    for i = 300, 400 do
        world:delete(ids[i])
    end
    CHECK(#world:ids(g) == 0)
    local h = world:entity()
    local fresh = world:component()
    world:set(h, fresh, 1)
    CHECK(#world:ids(h) == 1 and world:get(h, fresh) == 1)
end)

TEST("remove_all", function()
    local world = ecs.world()
    local A = world:component()
    local Hit = world:entity()
    local list = {}
    for i = 1, 500 do
        local e = world:entity()
        world:set(e, A, i)
        if i % 3 == 0 then
            world:add(e, Hit)
        end
        list[i] = e
    end

    CASE("a tag without hooks is removed from everyone at once")
    world:remove_all(Hit)
    CHECK(count(world:query(Hit)) == 0)
    CHECK(not world:has(list[3], Hit) and world:get(list[3], A) == 3)
    CHECK(#world:ids(list[3]) == 1)
    world:add(list[4], Hit)
    CHECK(count(world:query(Hit)) == 1)
    world:delete(list[4])
    CHECK(count(world:query(Hit)) == 0)

    CASE("a component: values are dropped")
    world:remove_all(A)
    CHECK(count(world:query(A)) == 0 and world:get(list[1], A) == nil)
    world:set(list[1], A, 7)
    CHECK(world:get(list[1], A) == 7 and count(world:query(A)) == 1)

    CASE("hooks run for every entity")
    local removed = 0
    world:set(Hit, ecs.OnRemove, function()
        removed += 1
    end)
    for i = 1, 10 do
        world:add(list[i + 10], Hit)
    end
    world:remove_all(Hit)
    CHECK(removed == 10 and count(world:query(Hit)) == 0)
end)

TEST("batch operations on query matches", function()
    local world = ecs.world()
    local A = world:component()
    local B = world:component()
    local Marked = world:entity()
    local list = {}
    for i = 1, 300 do
        local e = world:entity()
        world:set(e, A, i)
        if i % 2 == 0 then
            world:set(e, B, i)
        end
        list[i] = e
    end
    local function all_have(ids_of: (number) -> boolean, id: any): boolean
        for i, e in list do
            if world:contains(e) and world:has(e, id) ~= ids_of(i) then
                return false
            end
        end
        return true
    end

    CASE("count")
    CHECK(world:query(A):count() == 300)
    CHECK(world:query(A, B):count() == 150)
    CHECK(world:query(A):without(B):count() == 150)
    CHECK(world:query(Marked):count() == 0)

    CASE("add_all: a tag word by word")
    world:query(A):without(B):add_all(Marked)
    CHECK(world:query(Marked):count() == 150 and count(world:query(Marked)) == 150)
    CHECK(all_have(function(i)
        return i % 2 == 1
    end, Marked))
    CHECK(table.find(world:ids(list[1]), Marked) ~= nil)
    world:query(A):add_all(Marked) -- adding again is a no-op for those that have it
    CHECK(world:query(Marked):count() == 300)
    world:remove(list[5], Marked)
    CHECK(world:query(Marked):count() == 299)

    CASE("set_all: new and existing values")
    world:query(A):without(B):set_all(B, -1)
    CHECK(world:get(list[1], B) == -1 and world:get(list[2], B) == 2)
    CHECK(world:query(B):count() == 300)
    world:query(B):set_all(B, 5)
    local fives = 0
    for _, b in world:query(B) do
        if b == 5 then
            fives += 1
        end
    end
    CHECK(fives == 300)

    CASE("remove_all: a component, including a term of the query")
    world:query(A):with(Marked):remove_all(B)
    CHECK(world:query(B):count() == 1 and world:get(list[5], B) == 5)
    CHECK(world:get(list[6], B) == nil and world:has(list[6], A))
    world:query(A):remove_all(A)
    CHECK(world:query(A):count() == 0 and world:get(list[1], A) == nil)
    CHECK(#world:ids(list[1]) == 1) -- Marked
    for i, e in list do
        world:set(e, A, i)
    end

    CASE("tags cannot take a value")
    CHECK_EXPECT_ERR(function()
        (world:query(A) :: any):set_all(Marked, 1)
        return true
    end)
    world:remove_all(Marked)
    world:query(A):set_all(Marked, nil)
    CHECK(world:query(Marked):count() == 300)

    -- back to: A on everyone, B on the even ones
    world:remove_all(B)
    for i = 2, 300, 2 do
        world:set(list[i], B, i)
    end

    CASE("hooks run for every entity")
    local Hooked = world:component()
    local added, changed, removed = 0, 0, 0
    world:set(Hooked, ecs.OnAdd, function()
        added += 1
    end)
    world:set(Hooked, ecs.OnChange, function()
        changed += 1
    end)
    world:set(Hooked, ecs.OnRemove, function()
        removed += 1
    end)
    world:query(A):without(B):set_all(Hooked, 1)
    world:query(A):set_all(Hooked, 2)
    world:query(Hooked):remove_all(Hooked)
    CHECK(added == 300 and changed == 150 and removed == 300)

    CASE("pairs")
    local Likes = world:entity()
    local target = list[300]
    world:query(A):without(B):add_all(pair(Likes, target))
    CHECK(world:target(list[1], Likes) == target and world:target(list[2], Likes) == nil)
    CHECK(world:query(pair(Likes, ecs.Wildcard)):count() == 150)
    world:query(A):set_all(pair(B, target), 3)
    CHECK(world:get(list[2], pair(B, target)) == 3)
    world:query(A):remove_all(pair(Likes, ecs.Wildcard))
    CHECK(world:query(pair(Likes, ecs.Wildcard)):count() == 0)

    CASE("disabled entities are skipped unless named")
    world:add(list[1], ecs.Disabled)
    local Seen = world:entity()
    world:query(A):add_all(Seen)
    CHECK(not world:has(list[1], Seen) and world:query(Seen):count() == 299)
    world:query(A):with(ecs.Disabled):add_all(Seen)
    CHECK(world:has(list[1], Seen))

    CASE("delete_all")
    world:query(A):without(B):delete_all()
    CHECK(not world:contains(list[3]) and world:contains(list[4]))
    CHECK(world:contains(list[1]) and world:query(A):count() == 150) -- list[1] is disabled
    world:query(A):with(ecs.Disabled):delete_all()
    CHECK(not world:contains(list[1]) and world:query(A):count() == 150)

    CASE("count does not consume changes, batch operations do")
    local Tracked = world:entity()
    world:track(Tracked)
    world:query(A):add_all(Tracked)
    world:tick()
    local fresh = world:query(Tracked):added(Tracked)
    local counted = fresh:count()
    CHECK(counted == 150 and fresh:count() == counted)
    fresh:remove_all(Tracked)
    CHECK(world:query(Tracked):count() == 0 and fresh:count() == 0)
end)

TEST("any: OR terms", function()
    local world = ecs.world()
    local X = world:component()
    local Burning, Poisoned, Frozen = world:entity(), world:entity(), world:entity()
    local list = {}
    for i = 1, 120 do
        local e = world:entity()
        world:set(e, X, i)
        if i % 2 == 0 then
            world:add(e, Burning)
        end
        if i % 3 == 0 then
            world:add(e, Poisoned)
        end
        if i % 5 == 0 then
            world:add(e, Frozen)
        end
        list[i] = e
    end
    local function expected(f: (number) -> boolean): number
        local n = 0
        for i = 1, 120 do
            if f(i) then
                n += 1
            end
        end
        return n
    end

    CASE("burning or poisoned")
    local q = world:query(X):any(Burning, Poisoned)
    CHECK(count(q) == expected(function(i)
        return i % 2 == 0 or i % 3 == 0
    end))
    CHECK(q:has(list[3]) and q:has(list[4]) and not q:has(list[5]))

    CASE("two OR terms and a without")
    local q2 = world:query(X):any(Burning, Poisoned):any(Frozen, Poisoned):without(Burning)
    CHECK(count(q2) == expected(function(i)
        return (i % 2 == 0 or i % 3 == 0) and (i % 5 == 0 or i % 3 == 0) and i % 2 ~= 0
    end))

    CASE("stored queries follow changes")
    local cached = world:query(X):any(Burning, Frozen)
    for _ = 1, 3 do
        count(cached)
    end
    world:add(list[1], Frozen)
    world:remove(list[2], Burning)
    CHECK(count(cached) == expected(function(i)
        return i == 1 or (i ~= 2 and (i % 2 == 0 or i % 5 == 0))
    end))

    CASE("an OR term of ids that no entity has matches nothing")
    local Unused = world:entity()
    CHECK(count(world:query(X):any(Unused)) == 0)
    local n = 0
    world:query(X):any(Burning, Poisoned):each(function()
        n += 1
    end)
    CHECK(n > 0)
end)

TEST("disabled entities", function()
    local world = ecs.world()
    local A = world:component()
    local list = {}
    for i = 1, 100 do
        local e = world:entity()
        world:set(e, A, i)
        list[i] = e
    end
    for i = 1, 100, 10 do
        world:add(list[i], ecs.Disabled)
    end

    CASE("queries skip entities with Disabled")
    CHECK(count(world:query(A)) == 90)
    local n = 0
    world:query(A):each(function()
        n += 1
    end)
    CHECK(n == 90)
    CHECK(not world:query(A):has(list[1]) and world:query(A):has(list[2]))

    CASE("a query that names Disabled sees them")
    CHECK(count(world:query(A):with(ecs.Disabled)) == 10)
    CHECK(count(world:query(A, ecs.Disabled)) == 10)
    CHECK(count(world:query(A):without(ecs.Disabled)) == 90)

    CASE("cached queries follow enable and disable")
    local q = world:query(A):cached()
    for _ = 1, 3 do
        CHECK(count(q) == 90)
    end
    world:remove(list[1], ecs.Disabled)
    CHECK(count(q) == 91)
    world:add(list[2], ecs.Disabled)
    world:add(list[3], ecs.Disabled)
    CHECK(count(q) == 89)
    CHECK(world:get(list[2], A) == 2)
end)

TEST("change tracking", function()
    local world = ecs.world()
    local Health = world:component()
    local Stunned = world:entity()
    world:track(Health)
    world:track(Stunned)
    local list = {}
    for i = 1, 50 do
        local e = world:entity()
        world:set(e, Health, 100)
        list[i] = e
    end

    local function collect(q: any): { [any]: boolean }
        local set = {}
        for e in q do
            set[e] = true
        end
        return set
    end
    local function size(set: { [any]: boolean }): number
        local n = 0
        for _ in set do
            n += 1
        end
        return n
    end

    CASE("changes become visible after world:tick()")
    local added = world:query(Health):added(Health):cached()
    CHECK(size(collect(added)) == 0)
    world:tick()
    CHECK(size(collect(added)) == 50)
    CHECK(size(collect(added)) == 0) -- already seen by this query

    CASE("value changes")
    local changed = world:query(Health):changed(Health):cached()
    world:set(list[3], Health, 90)
    world:set(list[7], Health, 80)
    world:tick()
    local seen = collect(changed)
    CHECK(size(seen) == 2 and seen[list[3]] and seen[list[7]])
    CHECK(changed:has(list[3]) == false) -- the window is consumed

    CASE("a query that runs less often sees the accumulated ticks")
    local slow = world:query(Health):changed(Health):cached()
    collect(slow) -- a new query starts with the previous tick
    world:set(list[1], Health, 1)
    world:tick()
    world:set(list[2], Health, 2)
    world:tick()
    world:set(list[4], Health, 4)
    world:tick()
    CHECK(size(collect(slow)) == 3)

    CASE("removals, tags and each")
    local removed = world:query():with(Stunned):removed(Stunned)
    local lost = world:query(Health):removed(Stunned):cached()
    world:add(list[10], Stunned)
    world:add(list[11], Stunned)
    world:tick()
    CHECK(size(collect(lost)) == 0)
    world:remove(list[10], Stunned)
    world:delete(list[11])
    world:tick()
    local n = 0
    lost:each(function(e: any)
        n += 1
        CHECK(e == list[10])
    end)
    CHECK(n == 1)
    CHECK(size(collect(removed)) == 0) -- the removed entities no longer have Stunned

    CASE("a fresh query sees the previous tick")
    world:set(list[20], Health, 20)
    world:tick()
    local fresh = collect(world:query(Health):changed(Health))
    CHECK(size(fresh) == 1 and fresh[list[20]])

    CASE("a deleted entity does not pass its changes to the next entity of its slot")
    local victim = world:entity()
    world:set(victim, Health, 5)
    world:set(victim, Health, 6)
    world:delete(victim)
    local newcomer = world:entity()
    CHECK(ecs.ECS_ID(newcomer) == ecs.ECS_ID(victim))
    world:set(newcomer, Health, 1)
    world:tick()
    local changed_now = collect(world:query(Health):changed(Health))
    CHECK(not changed_now[newcomer])

    CASE("a deleted entity does not pass its removals to the next entities of its slot")
    local lost_stun = world:query(Health):removed(Stunned):cached()
    local all_lost = world:query():removed(Stunned):cached()
    local stunned = world:entity()
    local recovered = world:entity()
    for _, e in { stunned, recovered } do
        world:set(e, Health, 1)
        world:add(e, Stunned)
    end
    world:tick()
    collect(lost_stun)
    collect(all_lost)
    world:delete(stunned) -- dies while stunned
    world:remove(recovered, Stunned)
    world:delete(recovered) -- the stun ended, then it died
    local first = world:entity()
    local second = world:entity()
    CHECK(ecs.ECS_ID(first) == ecs.ECS_ID(recovered) and ecs.ECS_ID(second) == ecs.ECS_ID(stunned))
    world:set(first, Health, 1)
    world:set(second, Health, 1)
    world:tick()
    CHECK(size(collect(lost_stun)) == 0)
    CHECK(size(collect(all_lost)) == 0) -- a dead entity is never returned

    CASE("change filters need tracked ids")
    CHECK_EXPECT_ERR(function()
        local Other = world:component()
        for _ in world:query(Other):changed(Other) do
        end
        return true
    end)

    CASE("deletes skip change tracking, but not the hooks and signals of the id")
    local D = world:component()
    world:track(D)
    local signal_calls, hook_calls = 0, 0
    local function spawn_and_delete()
        local x = world:entity()
        world:set(x, D, 1)
        world:delete(x)
    end
    spawn_and_delete()
    local disconnect = world:removed(D, function(_e: any, _id: any, deleting: any)
        if deleting then
            signal_calls += 1
        end
    end)
    spawn_and_delete()
    CHECK(signal_calls == 1)
    disconnect()
    spawn_and_delete()
    world:set(D, ecs.OnRemove, function(_e: any, _id: any, deleting: any)
        if deleting then
            hook_calls += 1
        end
    end)
    spawn_and_delete()
    world:remove(D, ecs.OnRemove)
    spawn_and_delete()
    CHECK(signal_calls == 1 and hook_calls == 1)
    local lost_d = world:query():removed(D):cached()
    local y = world:entity()
    world:set(y, D, 1)
    world:tick()
    count(lost_d)
    world:remove(y, D)
    world:tick()
    CHECK(count(lost_d) == 1) -- removals from live entities are still recorded
    local Rel = world:entity()
    world:track(Rel)
    local rel_calls = 0
    world:removed(Rel, function(_e: any, _id: any, deleting: any)
        if deleting then
            rel_calls += 1
        end
    end)
    local source = world:entity()
    world:add(source, pair(Rel, world:entity()))
    world:delete(source)
    CHECK(rel_calls == 1)
end)

TEST("random relationship operations against a model", function()
    local seed = 777
    local function next_int(low: number, high: number): number
        seed = seed * 16807 % 2147483647
        return low + seed % (high - low + 1)
    end
    local world = ecs.world()
    local R = world:entity()
    local targets: { any } = {}
    local sources: { any } = {}
    -- model: source -> set of targets
    local model: { [any]: { [any]: boolean } } = {}
    for i = 1, 6 do
        targets[i] = world:entity()
    end
    for i = 1, 40 do
        local e = world:entity()
        sources[i] = e
        model[e] = {}
    end
    local mismatches = 0

    local function check()
        for e, set in model do
            local sorted: { any } = {}
            for t in set do
                table.insert(sorted, t)
            end
            table.sort(sorted, function(a: any, b: any)
                return ecs.ECS_ID(a) < ecs.ECS_ID(b)
            end)
            for k, t in sorted do
                if world:target(e, R, k - 1) ~= t or not world:has(e, pair(R, t)) then
                    mismatches += 1
                end
            end
            if world:target(e, R, #sorted) ~= nil then
                mismatches += 1
            end
            if world:has(e, pair(R, ecs.Wildcard)) ~= (#sorted > 0) then
                mismatches += 1
            end
        end
        local with_any = 0
        for e in world:query(pair(R, ecs.Wildcard)) do
            with_any += 1
            if next(model[e]) == nil then
                mismatches += 1
            end
        end
        for _, t in targets do
            if world:contains(t) then
                local n = 0
                for e in world:query(pair(ecs.Wildcard, t)) do
                    n += 1
                    if not model[e][t] then
                        mismatches += 1
                    end
                end
                local expected = 0
                for _, set in model do
                    if set[t] then
                        expected += 1
                    end
                end
                if n ~= expected then
                    mismatches += 1
                end
            end
        end
        local expected_any = 0
        for _, set in model do
            if next(set) ~= nil then
                expected_any += 1
            end
        end
        if with_any ~= expected_any then
            mismatches += 1
        end
    end

    CASE("pairs, targets, wildcards and target deletion match the model")
    for round = 1, 60 do
        for _ = 1, 25 do
            local e = sources[next_int(1, #sources)]
            local k = next_int(1, #targets)
            local t = targets[k]
            local roll = next_int(1, 100)
            if roll <= 55 then
                world:add(e, pair(R, t))
                model[e][t] = true
            elseif roll <= 90 then
                world:remove(e, pair(R, t))
                model[e][t] = nil
            else
                world:remove(e, pair(R, ecs.Wildcard))
                model[e] = {}
            end
        end
        if round % 7 == 0 then
            -- delete a source (with any number of targets); a new entity takes its slot
            local k = next_int(1, #sources)
            local old = sources[k]
            world:delete(old)
            model[old] = nil
            local fresh = world:entity()
            sources[k] = fresh
            model[fresh] = {}
            local first_target = targets[next_int(1, #targets)]
            world:add(fresh, pair(R, first_target))
            model[fresh][first_target] = true
        end
        if round % 10 == 0 then
            -- delete a target: every source loses the pair; a new target takes its place
            local k = next_int(1, #targets)
            local t = targets[k]
            world:delete(t)
            for _, set in model do
                set[t] = nil
            end
            targets[k] = world:entity()
        end
        check()
    end
    CHECK(mismatches == 0)
end)

TEST("debug mode", function()
    local world = ecs.world(true)
    local A = world:component()
    local R = world:entity()

    CASE("normal use works")
    local e = world:entity()
    world:set(e, A, 1)
    world:add(e, pair(R, world:entity()))
    world:remove(e, pair(R, ecs.Wildcard))
    world:clear(e)
    world:delete(e)
    CHECK(not world:contains(e))

    CASE("outdated handles and dead ids raise errors")
    CHECK_EXPECT_ERR(function()
        world:set(e, A, 1)
        return true
    end)
    CHECK_EXPECT_ERR(function()
        world:delete(e)
        return true
    end)
    local f = world:entity()
    CHECK_EXPECT_ERR(function()
        world:add(f, e)
        return true
    end)
    CHECK_EXPECT_ERR(function()
        world:add(f, pair(R, ecs.Wildcard))
        return true
    end)

    CASE("batch operations check their ids")
    world:set(f, A, 2)
    CHECK_EXPECT_ERR(function()
        world:query(A):add_all(e) -- e was deleted
        return true
    end)
    CHECK_EXPECT_ERR(function()
        (world:query(A) :: any):set_all(pair(R, ecs.Wildcard), 1)
        return true
    end)
    world:query(A):remove_all(pair(R, ecs.Wildcard)) -- a wildcard can be removed
    world:query(A):add_all(R)
    CHECK(world:has(f, R))

    CASE("a world without debug ignores such calls")
    local quiet = ecs.world()
    local g = quiet:entity()
    quiet:delete(g)
    quiet:set(g, quiet:component(), 1)
    quiet:delete(g)
    CHECK(not quiet:contains(g))
end)

TEST("introspection", function()
    local world = ecs.world()
    local A = world:component()
    local T = world:entity()
    local R = world:entity()
    local p1, p2 = world:entity(), world:entity()
    local e = world:entity()
    world:set(e, A, 1)
    world:add(e, T)
    world:add(e, pair(R, p2))
    world:add(e, pair(R, p1))
    world:set(e, ecs.Name, "e")

    CASE("world:ids lists components, tags and pairs, sorted")
    local ids = world:ids(e)
    local expected = { A, T, pair(R, p1), pair(R, p2), ecs.Name }
    table.sort(expected :: any)
    CHECK(#ids == #expected)
    local same = true
    for i, id in expected do
        same = same and ids[i] == id
    end
    CHECK(same)
    CHECK(#world:ids(world:entity()) == 0)

    CASE("the builtins are named")
    local names = {}
    for id, name in world:query(ecs.Name) do
        names[name] = id
    end
    CHECK(names.e == e and names["mercs.ChildOf"] == ecs.ChildOf)
    CHECK(names["mercs.Disabled"] == ecs.Disabled)
end)

TEST("random operations against a model", function()
    -- A deterministic random sequence of structural changes; after each batch every query
    -- form is compared with a plain Luau model of the world.
    local seed = 12345
    local function next_int(low: number, high: number): number
        seed = seed * 16807 % 2147483647 -- Park-Miller: exact in doubles
        return low + seed % (high - low + 1)
    end
    local world = ecs.world()
    local ids: { any } = {}
    for i = 1, 6 do
        ids[i] = world:component()
    end
    ids[7] = world:entity() -- tags
    ids[8] = world:entity()

    local model: { [any]: { [any]: any } } = {}
    local list: { any } = {}

    local function spawn()
        local e = world:entity()
        model[e] = {}
        table.insert(list, e)
    end

    local function mutate()
        local roll = next_int(1, 100)
        if roll <= 20 or #list == 0 then
            spawn()
            return
        end
        local at = next_int(1, #list)
        local e = list[at]
        if roll <= 28 then
            world:delete(e)
            model[e] = nil
            list[at] = list[#list]
            list[#list] = nil
            return
        end
        local k = next_int(1, #ids)
        local id = ids[k]
        if roll <= 70 then
            if k <= 6 then
                local value = next_int(1, 1000)
                world:set(e, id, value)
                model[e][id] = value
            else
                world:add(e, id)
                model[e][id] = true
            end
        else
            world:remove(e, id)
            model[e][id] = nil
        end
    end

    local function expected(with: { any }, without: { any }): { [any]: boolean }
        local result = {}
        for e, set in model do
            local ok = true
            for _, id in with do
                if set[id] == nil then
                    ok = false
                    break
                end
            end
            for _, id in without do
                if set[id] ~= nil then
                    ok = false
                end
            end
            if ok then
                result[e] = true
            end
        end
        return result
    end

    local cached: { [string]: any } = {}
    local mismatches = 0

    local function compare(with: { any }, without: { any })
        local want = expected(with, without)
        local key = table.concat(with :: any, ",") .. "|" .. table.concat(without :: any, ",")
        local q = cached[key]
        if q == nil then
            q = (world :: any):query(table.unpack(with)):without(table.unpack(without)):cached()
            cached[key] = q
        end
        local fresh = (world :: any):query(table.unpack(with))
        if #without > 0 then
            fresh:without(table.unpack(without))
        end
        for _, query in { q, fresh, q } do
            local seen = 0
            for e, v1 in query do
                seen += 1
                if not want[e] or (with[1] ~= ids[7] and with[1] ~= ids[8] and model[e][with[1]] ~= v1) then
                    mismatches += 1
                end
            end
            local count_want = 0
            for _ in want do
                count_want += 1
            end
            if seen ~= count_want then
                mismatches += 1
            end
            local each_seen = 0
            query:each(function(e: any)
                each_seen += 1
                if not want[e] then
                    mismatches += 1
                end
            end)
            if each_seen ~= count_want then
                mismatches += 1
            end
        end
        for e in model do
            if (want[e] == true) ~= q:has(e) then
                mismatches += 1
            end
        end
    end

    CASE("queries, has and get match the model")
    for _ = 1, 300 do
        spawn()
    end
    for _ = 1, 40 do
        for _ = 1, 150 do
            mutate()
        end
        compare({ ids[1] }, {})
        compare({ ids[1], ids[2] }, {})
        compare({ ids[2], ids[3], ids[7] }, {})
        compare({ ids[1] }, { ids[2] })
        compare({ ids[4], ids[5] }, { ids[8], ids[6] })
        for e, set in model do
            local expected_ids = 0
            for k, id in ids do
                if world:has(e, id) ~= (set[id] ~= nil) then
                    mismatches += 1
                end
                if k <= 6 and world:get(e, id) ~= set[id] then
                    mismatches += 1
                end
                if set[id] ~= nil then
                    expected_ids += 1
                end
            end
            local listed = world:ids(e)
            if #listed ~= expected_ids then
                mismatches += 1
            end
            for _, id in listed do
                if set[id] == nil then
                    mismatches += 1
                end
            end
        end
    end
    CHECK(mismatches == 0)

    CASE("dense blocks: full words appear and disappear")
    for _ = 1, 2000 do
        spawn()
        local e = list[#list]
        world:set(e, ids[1], 1)
        model[e][ids[1]] = 1
        world:set(e, ids[2], 2)
        model[e][ids[2]] = 2
    end
    compare({ ids[1], ids[2] }, {})
    for i = #list, 1, -7 do
        local e = list[i]
        world:remove(e, ids[2])
        model[e][ids[2]] = nil
    end
    compare({ ids[1], ids[2] }, {})
    compare({ ids[1] }, { ids[2] })
    CHECK(mismatches == 0)
end)

-- Entities of a query as a set, from a for-in loop and from each, and whether both agree with
-- the expected set (a table entity -> true).
local function same_matches(q: any, expected: { [any]: boolean }): boolean
    local n_expected = 0
    for _ in expected do
        n_expected += 1
    end
    local seen, ok = 0, true
    for e in q do
        seen += 1
        if not expected[e] then
            ok = false
        end
    end
    local each_seen = 0
    q:each(function(e: any)
        each_seen += 1
        if not expected[e] then
            ok = false
        end
    end)
    return ok and seen == n_expected and each_seen == n_expected
end

TEST("cached match lists follow small changes", function()
    -- a debug world checks every patched list against a scan of the bitsets
    local world = ecs.world(true)
    local A, T = world:component() :: ecs.Component<number>, world:entity()
    local filler = world:component()
    local list = {}
    for i = 1, 3000 do
        local e = world:entity()
        world:set(e, filler, i)
        if i % 3 == 0 then
            world:set(e, A, i)
            table.insert(list, e)
        end
    end
    local q = world:query(A):without(T):cached()
    local expected: { [any]: boolean } = {}
    for _, e in list do
        expected[e] = true
    end

    CASE("a stable list, then single changes")
    CHECK(same_matches(q, expected))
    CHECK(same_matches(q, expected))
    local ok = true
    for k = 1, 50 do
        local e = list[(k * 37) % #list + 1]
        if expected[e] then
            world:add(e, T)
            expected[e] = nil
        else
            world:remove(e, T)
            expected[e] = true
        end
        ok = ok and same_matches(q, expected)
    end
    CHECK(ok)

    CASE("many changes between two loops")
    for k = 1, 700 do
        local e = list[(k * 101) % #list + 1]
        if expected[e] then
            world:add(e, T)
            expected[e] = nil
        else
            world:remove(e, T)
            expected[e] = true
        end
    end
    CHECK(same_matches(q, expected))

    CASE("a deleted match and a new entity in its slot")
    local gone = list[10]
    world:delete(gone)
    expected[gone] = nil
    local fresh = world:entity()
    CHECK(ecs.ECS_ID(fresh) == ecs.ECS_ID(gone))
    world:set(fresh, A, -1)
    expected[fresh] = true
    CHECK(same_matches(q, expected))
    local value = nil
    q:each(function(e: any, a: any)
        if e == fresh then
            value = a
        end
    end)
    CHECK(value == -1)

    CASE("batch operations")
    world:query(A):add_all(T)
    CHECK(same_matches(q, {}))
    world:query(A):remove_all(T)
    for e in world:query(A) do
        expected[e] = true
    end
    CHECK(same_matches(q, expected))

    CASE("a loop over the list keeps its matches while a nested loop sees a change")
    local before = count(q)
    local outer = 0
    local nested = -1
    local left: any = nil
    for e in q do
        outer += 1
        if outer == 3 then
            left = e
            world:add(e, T) -- the current entity leaves the query
            nested = count(q)
        end
    end
    expected[left] = nil
    CHECK(outer == before and nested == before - 1)
    CHECK(same_matches(q, expected))

    CASE("loops left with break, then changes and nested loops")
    for _ in q do
        break
    end
    ok = true
    for k = 1, 20 do
        local e = list[(k * 53) % #list + 1]
        if expected[e] then
            world:add(e, T)
            expected[e] = nil
        else
            world:remove(e, T)
            expected[e] = true
        end
        ok = ok and same_matches(q, expected)
        if k % 5 == 0 then
            for _ in q do
                break
            end
        end
    end
    CHECK(ok)
    -- a loop that runs to the end while a nested loop sees a change
    local now = count(q)
    local visited = 0
    local changed: any = nil
    local seen_inside = -1
    for e in q do
        visited += 1
        if visited == 2 then
            changed = e
            world:add(e, T)
            seen_inside = count(q)
        end
    end
    expected[changed] = nil
    CHECK(visited == now and seen_inside == now - 1)
    CHECK(same_matches(q, expected))
end)

TEST("a query that takes its list as it is sees every change", function()
    -- a loop after which nothing that cached queries observe changed takes the list as it is;
    -- a debug world checks that none of the records of the query changed then
    local world = ecs.world(true)
    local A, B = world:component() :: ecs.Component<number>, world:component() :: ecs.Component<number>
    local R = world:component() :: ecs.Component<number>
    local T, target = world:entity(), world:entity()
    local filler = world:component()
    local list = {}
    for i = 1, 2000 do
        local e = world:entity()
        world:set(e, filler, i)
        if i % 40 == 0 then
            world:set(e, A, i)
            table.insert(list, e)
        end
    end
    local q = world:query(A):without(T):cached()
    local function expected(): { [any]: boolean }
        local set = {}
        for _, e in list do
            if world:contains(e) and world:has(e, A) and not world:has(e, T) and not world:has(e, ecs.Disabled) then
                set[e] = true
            end
        end
        return set
    end
    -- two loops: the second one takes the list as it is
    local function twice(query: any, set: { [any]: boolean }): boolean
        local first = same_matches(query, set)
        return same_matches(query, set) and first
    end
    local function same_twice(): boolean
        return twice(q, expected())
    end
    CHECK(same_twice())

    CASE("single changes, Disabled and clear")
    world:add(list[1], T)
    CHECK(same_twice())
    world:add(list[2], ecs.Disabled)
    CHECK(same_twice())
    world:remove(list[2], ecs.Disabled)
    world:clear(list[3])
    CHECK(same_twice())
    world:set(list[3], A, 3)
    CHECK(same_twice())

    CASE("batch operations")
    world:query(A):add_all(T)
    CHECK(same_twice())
    world:remove_all(T)
    CHECK(same_twice())
    for k = 1, 5 do
        world:set(list[k], B, k)
    end
    world:query(B):remove_all(A)
    CHECK(same_twice())
    world:query(filler):with(B):set_all(A, 0)
    CHECK(same_twice())
    world:query(B):delete_all()
    CHECK(same_twice())

    CASE("new records and pairs")
    local C = world:component()
    world:set(list[10], C, 1)
    CHECK(same_twice())
    local q2 = world:query(A, ecs.pair(ecs.Wildcard, target)):cached()
    local with_target: { [any]: boolean } = {}
    CHECK(twice(q2, with_target))
    world:add(list[11], ecs.pair(T, target))
    with_target[list[11]] = true
    CHECK(twice(q2, with_target))
    -- the first pair with a value: the wildcard returns values from now on
    world:set(list[12], ecs.pair(R, target), 5)
    with_target[list[12]] = true
    CHECK(twice(q2, with_target))
    world:delete(target)
    CHECK(twice(q2, {}))
    CHECK(same_twice())
end)

TEST("empty queries", function()
    local world = ecs.world(true)
    local A, B = world:component(), world:component()
    local list = {}
    for i = 1, 2000 do
        local e = world:entity()
        if i % 2 == 0 then
            world:set(e, A, i)
        else
            world:set(e, B, i)
        end
        list[i] = e
    end

    CASE("no overlap: empty, and the first match appears")
    local q = world:query(A, B):cached()
    local empty = true
    for _ = 1, 3 do
        empty = empty and count(q) == 0
    end
    CHECK(empty)
    world:set(list[2], B, 0)
    CHECK(same_matches(q, { [list[2]] = true }))
    world:remove(list[2], B)
    CHECK(same_matches(q, {}))

    CASE("a required id without a record")
    local Rare = world:entity()
    local r = world:query(A):with(Rare):cached()
    empty = true
    for _ = 1, 3 do
        empty = empty and count(r) == 0
    end
    CHECK(empty)
    world:add(list[4], Rare)
    CHECK(same_matches(r, { [list[4]] = true }))
end)

TEST("groups of one match and larger groups", function()
    local world = ecs.world(true)
    local A, T = world:component() :: ecs.Component<number>, world:entity()
    local expected: { [any]: boolean } = {}
    local lone: any = nil
    -- one match per value page, then a dense page
    for i = 1, 20 * 256 do
        local e = world:entity()
        if i % 256 == 7 or (i > 19 * 256 and i % 3 == 0) then
            world:set(e, A, i)
            expected[e] = true
            if i == 5 * 256 + 7 then
                lone = e
            end
        end
    end
    local q = world:query(A):without(T):cached()
    CHECK(same_matches(q, expected))
    CHECK(same_matches(q, expected))
    local wrong, n = 0, 0
    for e, a in q do
        n += 1
        if a ~= world:get(e, A) then
            wrong += 1
        end
    end
    CHECK(wrong == 0 and n > 0)

    CASE("a group of one match gets a second one, then loses the first")
    local neighbour = world:entity(ecs.ECS_COMBINE(ecs.ECS_ID(lone) + 1, 0))
    world:set(neighbour, A, 1)
    expected[neighbour] = true
    CHECK(same_matches(q, expected))
    world:add(lone, T)
    expected[lone] = nil
    CHECK(same_matches(q, expected))
end)

TEST("(*, T) wildcard targets", function()
    local world = ecs.world(true)
    local R1, R2, T = world:entity(), world:entity(), world:entity()
    local Data = world:component() :: ecs.Component<number>
    local a, b, c = world:entity(), world:entity(), world:entity()
    local W = ecs.Wildcard

    CASE("pairs added before the first read")
    world:add(a, pair(R1, T))
    world:add(b, pair(R1, T))
    world:add(b, pair(R2, T))
    CHECK(world:has(a, pair(W, T)) and world:has(b, pair(W, T)) and not world:has(c, pair(W, T)))
    CHECK(same_matches(world:query(pair(W, T)), { [a] = true, [b] = true }))

    CASE("a slot with two pairs of the target keeps it until both are gone")
    world:remove(b, pair(R1, T))
    CHECK(world:has(b, pair(W, T)))
    world:remove(b, pair(R2, T))
    CHECK(not world:has(b, pair(W, T)))
    CHECK(same_matches(world:query(pair(W, T)), { [a] = true }))

    CASE("a cached query follows later changes")
    local q = world:query(pair(W, T)):cached()
    CHECK(same_matches(q, { [a] = true }))
    world:add(c, pair(R2, T))
    CHECK(same_matches(q, { [a] = true, [c] = true }))
    world:remove(c, pair(W, T))
    CHECK(same_matches(q, { [a] = true }))

    CASE("values: nil for tag pairs, the value of a data pair once one exists")
    local nils = true
    for _, v in world:query(pair(W, T)) do
        nils = nils and v == nil
    end
    CHECK(nils)
    world:set(c, pair(Data, T), 5)
    local value = nil
    for e, v in world:query(pair(W, T)) do
        if e == c then
            value = v
        end
    end
    CHECK(value == 5)

    CASE("deleting a relation keeps the other pairs of the target")
    world:add(b, pair(R2, T))
    world:delete(R2)
    CHECK(not world:has(b, pair(W, T)) and world:has(a, pair(W, T)))
    CHECK(same_matches(q, { [a] = true, [c] = true }))

    CASE("deleting the target removes every pair")
    world:delete(T)
    CHECK(not world:has(a, pair(R1, W)) and not world:has(c, pair(Data, W)))
end)

TEST("slot pools", function()
    local world = ecs.world(true)
    local Model = world:component() :: ecs.Component<number>
    local npcs = world:pool()

    CASE("pool entities take consecutive slots between other entities")
    local list = {}
    for i = 1, 300 do
        list[i] = npcs:entity()
        world:set(list[i], Model, i)
        for _ = 1, 20 do
            world:entity() -- skills and effects
        end
    end
    local consecutive = true
    for i = 2, 256 do
        consecutive = consecutive and ecs.ECS_ID(list[i]) == ecs.ECS_ID(list[i - 1]) + 1
    end
    CHECK(consecutive)
    CHECK(ecs.ECS_ID(list[1]) % 256 == 0) -- a block starts a value page

    CASE("a query over them reads runs of full words")
    local runs = 0
    for _first, _last, mask in world:query(Model):spans() do
        if mask == 0xFFFFFFFF then
            runs += 1
        end
    end
    CHECK(runs > 0 and count(world:query(Model)) == 300)

    CASE("a deleted pool entity gives its slot back to the pool")
    local old = list[5]
    world:delete(old)
    local other = world:entity()
    CHECK(ecs.ECS_ID(other) ~= ecs.ECS_ID(old))
    local reused = npcs:entity()
    CHECK(ecs.ECS_ID(reused) == ecs.ECS_ID(old) and ecs.ECS_GENERATION(reused) == 1)
    CHECK(world:contains(reused) and not world:contains(old))

    CASE("pool entities work with every call")
    local parent = npcs:entity()
    local child = npcs:entity()
    world:add(child, pair(ecs.ChildOf, parent))
    world:set(child, Model, 1)
    world:delete(parent)
    CHECK(not world:contains(child))

    CASE("an explicit id inside a block leaves the pool")
    local slot: number = ecs.ECS_ID(npcs:entity() :: any) + 1
    local taken: any = world:entity(slot)
    CHECK(world:contains(taken))
    local next_one = npcs:entity()
    CHECK(ecs.ECS_ID(next_one) ~= slot)

    CASE("world:range bounds the blocks")
    local ranged = ecs.world()
    ranged:range(1000, 1300)
    local pool = ranged:pool()
    local e = pool:entity()
    CHECK(ecs.ECS_ID(e) >= 1024 and ecs.ECS_ID(e) < 1300)
    CHECK_EXPECT_ERR(function()
        for _ = 1, 400 do
            pool:entity()
        end
        return true
    end)
end)

TEST("large worlds and scattered members", function()
    local world = ecs.world(true)
    local A, T = world:component() :: ecs.Component<number>, world:entity()
    local expected: { [any]: boolean } = {}
    local order: { any } = {}
    for i = 1, 150000 do
        local e = world:entity()
        if i % 30011 == 0 or i % 9973 == 0 then
            world:set(e, A, i)
            expected[e] = true
            table.insert(order, e)
        end
    end

    CASE("matches far apart, in ascending slot order")
    local q = world:query(A):cached()
    local same = true
    for _ = 1, 3 do
        same = same and same_matches(q, expected)
    end
    CHECK(same)
    local k, ordered = 0, true
    for e in world:query(A) do
        k += 1
        ordered = ordered and e == order[k]
    end
    CHECK(ordered and k == #order)

    CASE("a tag toggled on scattered entities")
    local toggled: { [any]: boolean } = {}
    for round = 1, 3000 do
        local e = order[round % #order + 1]
        if toggled[e] then
            world:remove(e, T)
            toggled[e] = nil
        else
            world:add(e, T)
            toggled[e] = true
        end
    end
    local tagged, wrong = 0, 0
    for e in world:query(T) do
        tagged += 1
        if not toggled[e] then
            wrong += 1
        end
    end
    local n_toggled = 0
    for _ in toggled do
        n_toggled += 1
    end
    CHECK(tagged == n_toggled and wrong == 0)
    for i = 1, 5000 do
        local e = order[i % #order + 1]
        if not toggled[e] then
            world:add(e, T)
            world:remove(e, T)
        end
    end
    CHECK(count(world:query(T)) == n_toggled)
end)

TEST("on_remove hooks run once, whatever the signature index of the id", function()
    local world = ecs.world()
    local Low = world:component()
    world:add(world:entity(), Low) -- the record of Low: a small signature index
    for _ = 1, 300 do
        world:add(world:entity(), world:entity()) -- 300 more records
    end
    -- records beyond the shared signature tables (index > 256)
    local High = world:component()
    world:add(world:entity(), High)
    local Rel = world:entity()
    world:add(world:entity(), pair(Rel, world:entity()))
    local calls = { low = 0, high = 0, rel = 0 }
    world:set(Low, ecs.OnRemove, function()
        calls.low += 1
    end)
    world:set(High, ecs.OnRemove, function()
        calls.high += 1
    end)
    world:set(Rel, ecs.OnRemove, function()
        calls.rel += 1
    end)
    local function hooked_entity(): any
        local e = world:entity()
        world:add(e, Low)
        world:set(e, High, 1)
        world:add(e, pair(Rel, world:entity()))
        return e
    end

    CASE("delete")
    world:delete(hooked_entity())
    CHECK(calls.low == 1 and calls.high == 1 and calls.rel == 1)

    CASE("clear")
    local e = hooked_entity()
    world:clear(e)
    CHECK(calls.low == 2 and calls.high == 2 and calls.rel == 2)
    CHECK(#world:ids(e) == 0)

    CASE("hooks only beyond the shared signature tables")
    world:remove(Low, ecs.OnRemove)
    world:delete(hooked_entity())
    CHECK(calls.low == 2 and calls.high == 3 and calls.rel == 3)
end)

TEST("an entity that takes a slot inside an on_remove hook runs its own hooks", function()
    local world = ecs.world()
    local X = world:component()
    local first: any, second: any = nil, nil
    local calls: { any } = {}
    world:set(X, ecs.OnRemove, function(e: any)
        table.insert(calls, e)
        if e == first and second == nil then
            world:delete(first)
            second = world:entity() -- takes the slot of the first entity
            world:add(second, X)
            world:delete(second)
        end
    end)
    first = world:entity()
    world:add(first, X)

    CASE("the hook runs for the new entity while the old one is cleared")
    world:clear(first)
    CHECK(ecs.ECS_ID(second) == ecs.ECS_ID(first))
    CHECK(#calls == 2 and calls[1] == first and calls[2] == second)
    CHECK(not world:contains(first) and not world:contains(second))
    CHECK(count(world:query(X)) == 0)
end)

TEST("cascades deeper than 100 levels through tags, relations and ChildOf", function()
    local N = 250
    local function survivors(world: any, list: { any }): number
        local n = 0
        for _, e in list do
            if world:contains(e) then
                n += 1
            end
        end
        return n
    end

    CASE("a tag with (OnDelete, Delete): each entity has the previous one")
    local world = ecs.world()
    local V = world:component()
    local removed, bad = 0, 0
    world:set(V, ecs.OnRemove, function(_e: any, _id: any, deleting: any)
        removed += 1
        if not deleting then
            bad += 1
        end
    end)
    local chain: { any } = {}
    for i = 1, N do
        local e = world:entity()
        world:add(e, pair(ecs.OnDelete, ecs.Delete))
        world:set(e, V, i)
        if i > 1 then
            world:add(e, chain[i - 1])
        end
        chain[i] = e
    end
    world:delete(chain[1])
    CHECK(survivors(world, chain) == 0)
    CHECK(removed == N and bad == 0 and count(world:query(V)) == 0)
    -- the signature indices of the freed records serve new records
    local fresh = world:entity()
    for _ = 1, 40 do
        world:add(fresh, world:entity())
    end
    CHECK(#world:ids(fresh) == 40)
    world:delete(fresh)
    CHECK(not world:contains(fresh))

    CASE("a relation with (OnDelete, Delete): each entity has a pair of the previous one")
    local target = world:entity()
    local links: { any } = {}
    for i = 1, N do
        local e = world:entity()
        world:add(e, pair(ecs.OnDelete, ecs.Delete))
        if i > 1 then
            world:add(e, pair(links[i - 1], target))
        end
        links[i] = e
    end
    world:delete(links[1])
    CHECK(survivors(world, links) == 0 and world:contains(target))
    CHECK(count(world:query(pair(ecs.Wildcard, target))) == 0)
    local other = world:entity()
    world:add(other, pair(world:entity(), target))
    CHECK(#world:ids(other) == 1 and count(world:query(pair(ecs.Wildcard, target))) == 1)

    CASE("ChildOf: the hook of every child runs once, for a deleted child of a live parent")
    local tree = ecs.world()
    local calls: { [any]: number } = {}
    local wrong = 0
    tree:set(ecs.ChildOf, ecs.OnRemove, function(e: any, _id: any, deleting: any)
        calls[e] = (calls[e] or 0) + 1
        local parent = tree:parent(e)
        if not deleting or parent == nil or not tree:contains(parent) then
            wrong += 1
        end
    end)
    local nodes: { any } = { tree:entity() }
    for i = 2, N do
        local node = tree:entity()
        tree:add(node, pair(ecs.ChildOf, nodes[i - 1]))
        nodes[i] = node
    end
    tree:delete(nodes[1])
    local once = true
    for i = 2, N do
        once = once and calls[nodes[i]] == 1
    end
    CHECK(survivors(tree, nodes) == 0 and once and wrong == 0)
    CHECK(count(tree:query(pair(ecs.ChildOf, ecs.Wildcard))) == 0)
end)

TEST("hooks and signals on builtin ids keep the internal hooks", function()
    -- whether Exclusive still acts on a relation whose (R, *) record exists, after `setup`
    local function exclusive_after(setup: (world: any) -> ()): boolean
        local world = ecs.world()
        setup(world)
        local Rel = world:entity()
        local e, t1, t2 = world:entity(), world:entity(), world:entity()
        world:add(e, pair(Rel, t1))
        world:add(Rel, ecs.Exclusive)
        world:add(e, pair(Rel, t2))
        local exclusive = not world:has(e, pair(Rel, t1)) and world:target(e, Rel) == t2
        world:remove(Rel, ecs.Exclusive)
        world:add(e, pair(Rel, t1))
        return exclusive and world:has(e, pair(Rel, t1)) and world:has(e, pair(Rel, t2))
    end

    CASE("a listener, a hook or tracking on Exclusive")
    local seen = 0
    CHECK(exclusive_after(function(world: any)
        world:added(ecs.Exclusive, function()
            seen += 1
        end)
    end))
    CHECK(exclusive_after(function(world: any)
        world:set(ecs.Exclusive, ecs.OnAdd, function()
            seen += 10
        end)
    end))
    CHECK(exclusive_after(function(world: any)
        world:removed(ecs.Exclusive, function()
            seen += 100
        end)
    end))
    CHECK(exclusive_after(function(world: any)
        world:track(ecs.Exclusive)
    end))
    CHECK(seen == 111)

    CASE("a listener on OnAdd: hooks set later reach the records that exist")
    local world = ecs.world()
    local A = world:component()
    world:add(world:entity(), A) -- the record of A exists
    local listened = 0
    local disconnect = world:added(ecs.OnAdd, function()
        listened += 1
    end)
    local calls = 0
    world:set(A, ecs.OnAdd, function()
        calls += 1
    end)
    world:set(world:entity(), A, 1)
    CHECK(listened == 1 and calls == 1)
    disconnect()
    world:remove(A, ecs.OnAdd)
    world:set(world:entity(), A, 2)
    CHECK(calls == 1)

    CASE("a hook on OnAdd itself")
    local fresh = ecs.world()
    local B = fresh:component()
    fresh:add(fresh:entity(), B)
    local meta = 0
    fresh:set(ecs.OnAdd, ecs.OnAdd, function()
        meta += 1 -- OnAdd is added to B below
    end)
    local b_calls = 0
    fresh:set(B, ecs.OnAdd, function()
        b_calls += 1
    end)
    fresh:set(fresh:entity(), B, 1)
    CHECK(meta == 1 and b_calls == 1)

    CASE("signals and tracking take a relation, not a pair")
    local R, T = world:entity(), world:entity()
    local w: any = world
    CHECK_EXPECT_ERR(function()
        w:added(pair(R, T), function() end)
    end)
    CHECK_EXPECT_ERR(function()
        w:changed(pair(R, ecs.Wildcard), function() end)
    end)
    CHECK_EXPECT_ERR(function()
        w:removed(pair(ecs.Wildcard, T), function() end)
    end)
    CHECK_EXPECT_ERR(function()
        w:track(pair(R, T))
    end)
    local pairs_seen = 0
    world:added(R, function()
        pairs_seen += 1
    end)
    world:add(world:entity(), pair(R, T))
    CHECK(pairs_seen == 1) -- the relation covers its pairs
end)

TEST("values on tag pairs, queries without terms", function()
    local world = ecs.world()
    local w: any = world
    local R, T = world:entity(), world:entity()
    local e = world:entity()

    CASE("a value on a tag pair raises an error, also when the entity has the pair")
    CHECK_EXPECT_ERR(function()
        w:set(e, pair(R, T), 5)
    end)
    CHECK(world:has(e, pair(R, T))) -- the pair stays added, as a tag does
    CHECK_EXPECT_ERR(function()
        w:set(e, pair(R, T), 5)
    end)
    CHECK(world:get(e, pair(R, T)) == nil)
    w:set(e, pair(R, T), nil) -- nil is no value
    CHECK(world:has(e, pair(R, T)))

    CASE("a tag that stays added by a rejected value runs OnAdd, signals, monitors and tracking")
    local Tag = world:entity()
    local R2, T2 = world:entity(), world:entity()
    local hook_calls, signal_calls, entered = 0, 0, 0
    world:set(Tag, ecs.OnAdd, function(_: any, _: any, value: any)
        if value == nil then
            hook_calls += 1
        end
    end)
    world:added(R2, function()
        signal_calls += 1
    end)
    world:track(Tag)
    local monitor = world:query(Tag):monitor()
    monitor.added(function()
        entered += 1
    end)
    local f = world:entity()
    CHECK_EXPECT_ERR(function()
        w:set(f, Tag, 5)
    end)
    CHECK_EXPECT_ERR(function()
        w:set(f, pair(R2, T2), 5)
    end)
    world:tick()
    CHECK(world:has(f, Tag) and world:has(f, pair(R2, T2)))
    CHECK(hook_calls == 1 and signal_calls == 1 and entered == 1)
    CHECK(count(world:query(Tag):added(Tag)) == 1)
    monitor.disconnect()

    CASE("a query without terms matches nothing, has() included")
    local q = world:query()
    CHECK(count(q) == 0 and q:count() == 0 and not q:has(e))
    CHECK(not world:query():without(T):has(e))
    world:add(e, T)
    CHECK(world:query():with(T):has(e))
end)

TEST("pair records left without members are freed in batches", function()
    CASE("the records of pairs that are gone do not add up")
    do
        local world = ecs.world()
        local Likes = world:entity()
        local e = world:entity()
        local targets: { any } = {}
        for i = 1, 20000 do
            targets[i] = world:entity()
        end
        gc.full()
        local before = gc.kb()
        for i = 1, 20000 do
            world:add(e, pair(Likes, targets[i]))
            world:remove(e, pair(Likes, targets[i]))
        end
        gc.full()
        -- 0.2.0 before this change kept every record until its target was deleted: 33 MB
        CHECK(gc.kb() - before < 4096)
        CHECK(world:target(e, Likes) == nil and count(world:query(pair(Likes, ecs.Wildcard))) == 0)
    end

    CASE("a pair added again after its record was freed")
    local world = ecs.world()
    local Owns = world:component() :: ecs.Component<string>
    local added = 0
    world:set(Owns, ecs.OnAdd, function()
        added += 1
    end)
    local holder = world:entity()
    -- more empty pair records than a batch: the ones before them are freed
    local function empty_batch()
        for _ = 1, 600 do
            local t = world:entity()
            world:add(holder, pair(Owns, t))
            world:remove(holder, pair(Owns, t))
        end
    end
    local e, item = world:entity(), world:entity()
    world:set(e, pair(Owns, item), "sword")
    world:remove(e, pair(Owns, item))
    empty_batch()
    world:set(e, pair(Owns, item), "shield")
    CHECK(world:get(e, pair(Owns, item)) == "shield" and world:target(e, Owns) == item)
    CHECK(added == 602) -- the hook of the relation reaches the new record
    CHECK(count(world:query(pair(Owns, item))) == 1 and count(world:query(pair(ecs.Wildcard, item))) == 1)
    local parent, child = world:entity(), world:entity()
    world:add(child, pair(ecs.ChildOf, parent))
    world:remove(child, pair(ecs.ChildOf, parent))
    empty_batch()
    CHECK(world:parent(child) == nil and count(world:children(parent)) == 0)
    world:add(child, pair(ecs.ChildOf, parent))
    CHECK(world:parent(child) == parent and count(world:children(parent)) == 1)
    world:delete(parent)
    CHECK(not world:contains(child))

    CASE("an exclusive relation switches to a pair whose record is freed during the switch")
    local X, Y = world:entity(), world:entity()
    world:add(X, ecs.Exclusive)
    local f, t1, t2 = world:entity(), world:entity(), world:entity()
    local other, helper = world:entity(), world:entity()
    local spares: { any } = {}
    for i = 1, 600 do
        spares[i] = world:entity()
        world:add(helper, pair(Y, spares[i]))
    end
    world:add(f, pair(X, t1))
    local armed = true
    world:set(X, ecs.OnRemove, function(entity: any)
        if armed and entity == f then
            armed = false
            -- the record of (X, t2), which f is getting, is left empty...
            world:add(other, pair(X, t2))
            world:remove(other, pair(X, t2))
            -- ...and a batch of empty pair records is freed, that record included
            for _, s in spares do
                world:remove(helper, pair(Y, s))
            end
        end
    end)
    world:add(f, pair(X, t2))
    CHECK(not armed and world:target(f, X) == t2 and world:has(f, pair(X, t2)))
    CHECK(not world:has(f, pair(X, t1)) and count(world:query(pair(X, t2))) == 1)

    CASE("pairs with many targets against a model, with cached queries (debug world)")
    local seed = 4242
    local function next_int(low: number, high: number): number
        seed = seed * 16807 % 2147483647
        return low + seed % (high - low + 1)
    end
    local debug_world = ecs.world(true)
    local Data = debug_world:component() :: ecs.Component<number>
    local Excl = debug_world:entity()
    debug_world:add(Excl, ecs.Exclusive)
    local data_added = 0
    debug_world:set(Data, ecs.OnAdd, function()
        data_added += 1
    end)
    local targets: { any } = {}
    local sources: { any } = {}
    for i = 1, 600 do
        targets[i] = debug_world:entity()
    end
    -- the model: source -> target -> value, and source -> exclusive target
    local data: { [any]: { [any]: number } } = {}
    local excl: { [any]: any } = {}
    for i = 1, 50 do
        local s = debug_world:entity()
        sources[i] = s
        data[s] = {}
    end
    local watched = targets[1] -- never deleted
    local by_data = debug_world:query(pair(Data, ecs.Wildcard)):cached()
    local by_target = debug_world:query(pair(ecs.Wildcard, watched)):cached()
    local by_pair = debug_world:query(pair(Data, watched)):cached()
    local mismatches, expected_added = 0, 0
    local function check()
        for s, set in data do
            for t, value in set do
                if debug_world:get(s, pair(Data, t)) ~= value then
                    mismatches += 1
                end
            end
            if debug_world:target(s, Excl) ~= excl[s] then
                mismatches += 1
            end
            if debug_world:has(s, pair(Data, ecs.Wildcard)) ~= (next(set) ~= nil) then
                mismatches += 1
            end
            local n = 0
            for _ in debug_world:targets(s, Data) do
                n += 1
            end
            for _ in set do
                n -= 1
            end
            if n ~= 0 then
                mismatches += 1
            end
        end
        local want_data, want_target, want_pair = 0, 0, 0
        for s, set in data do
            if next(set) ~= nil then
                want_data += 1
            end
            if set[watched] ~= nil or excl[s] == watched then
                want_target += 1
            end
            if set[watched] ~= nil then
                want_pair += 1
            end
        end
        local n_pair = 0
        for s, value in by_pair do
            n_pair += 1
            if data[s][watched] ~= value then
                mismatches += 1
            end
        end
        if count(by_data) ~= want_data or count(by_target) ~= want_target or n_pair ~= want_pair then
            mismatches += 1
        end
    end
    for round = 1, 40 do
        for _ = 1, 200 do
            local s = sources[next_int(1, #sources)]
            local t = targets[next_int(1, #targets)]
            local roll = next_int(1, 100)
            if roll <= 35 then
                local value = next_int(1, 1000)
                if data[s][t] == nil then
                    expected_added += 1
                end
                debug_world:set(s, pair(Data, t), value)
                data[s][t] = value
            elseif roll <= 70 then
                debug_world:remove(s, pair(Data, t))
                data[s][t] = nil
            elseif roll <= 90 then
                debug_world:add(s, pair(Excl, t))
                excl[s] = t
            else
                debug_world:remove(s, pair(Excl, ecs.Wildcard))
                excl[s] = nil
            end
        end
        if round % 5 == 0 then
            -- a target is deleted: its pairs go, a new target takes its place
            local k = next_int(2, #targets)
            local t = targets[k]
            debug_world:delete(t)
            for s, set in data do
                set[t] = nil
                if excl[s] == t then
                    excl[s] = nil
                end
            end
            targets[k] = debug_world:entity()
        end
        check()
    end
    CHECK(mismatches == 0 and data_added == expected_added)
end)

TEST("shared query shapes of deleted entities", function()
    -- the shared query states of a world (MAX_SHAPES of src/init.luau)
    local MAX_SHAPES = 1024

    CASE("queries on entity ids keep nothing once the entities are deleted")
    do
        local world = ecs.world()
        local events: { any } = {}
        for i = 1, 4 do
            events[i] = world:component()
        end
        local function casters(n: number)
            for _ = 1, n do
                local caster = world:entity()
                for i = 1, 4 do
                    for _ in world:query():with(caster, events[i]) do
                    end
                end
                world:delete(caster)
            end
        end
        casters(2000)
        gc.full()
        local before = gc.kb()
        casters(20000)
        gc.full()
        -- 0.2.0 kept a node and four child nodes per entity (+8 MB here) and the first 1024
        -- states, and shared no new shape after them
        CHECK(gc.kb() - before < 64)
        local fresh = world:component()
        CHECK(shared_shape(function()
            return world:query(fresh)
        end))
        CHECK(shared_shape(function()
            return world:query(events[1]):without(events[2])
        end))
    end

    CASE("queries with a pair are shared by shape, and go with the target of the pair")
    do
        local world = ecs.world()
        local A, B = world:component(), world:component()
        local R = world:entity()
        local t = world:entity()
        local e = world:entity()
        world:set(e, A, 1)
        world:add(e, pair(R, t))
        CHECK(shared_shape(function()
            return world:query(A, pair(R, t))
        end))
        CHECK(shared_shape(function()
            return world:query(A):with(pair(R, t)):without(B)
        end))
        CHECK(shared_shape(function()
            return world:query(A):with(pair(ecs.Wildcard, t))
        end))
        local kept = world:query(A, pair(R, t))
        CHECK(internal(kept).shared == true and count(kept) == 1)
        world:delete(t)
        CHECK(count(kept) == 0)
        -- a pair whose target is not alive matches nothing: not shared
        CHECK(internal(world:query(A, pair(R, t))).shared ~= true)
        CHECK(internal(world:query(A, pair(R, t))).shared ~= true)
        -- an entity that takes the slot of the target has the same pairs: a new shape of them
        local heir = world:entity()
        CHECK(ecs.ECS_ID(heir) == ecs.ECS_ID(t))
        world:add(e, pair(R, heir))
        CHECK(shared_shape(function()
            return world:query(A, pair(R, heir))
        end))
        CHECK(internal(world:query(A, pair(R, heir))) ~= internal(kept))
        CHECK(count(kept) == 1) -- the kept query still reads the pair of the slot
        -- the pair of a slot that no entity ever had
        local never: any = 1000000
        CHECK(internal(world:query(A, pair(R, never))).shared ~= true)
        CHECK(internal(world:query(A, pair(R, never))).shared ~= true)
    end

    CASE("the shapes of pairs, and of their target as a term, leave no room taken")
    do
        local world = ecs.world()
        local A, B = world:component(), world:component()
        local R = world:entity()
        CHECK(shared_shape(function() -- the one shared state that stays
            return world:query(A)
        end))
        for _ = 1, 3000 do
            local x = world:entity()
            local holder = world:entity()
            world:set(holder, A, 1)
            world:add(holder, pair(R, x))
            for _ = 1, 2 do
                count(world:query(A, pair(R, x)))
                count(world:query(A, x)) -- the target as a term under the same node
                count(world:query(A):with(pair(R, x)):without(B)) -- a variant of a variant
                count(world:query(A):any(pair(R, x), pair(ecs.Wildcard, x)))
                count(world:query(A):without(pair(ecs.Wildcard, x)))
            end
            world:delete(x)
            world:delete(holder)
        end
        local shared = 0
        for _ = 1, MAX_SHAPES + 10 do
            local e = world:entity()
            world:query(A, pair(R, e)) -- the first request marks the shape
            if internal(world:query(A, pair(R, e))).shared == true then
                shared += 1
            end
        end
        CHECK(shared == MAX_SHAPES - 1)
    end

    CASE("a kept query works after its entity is deleted and made alive again")
    do
        local world = ecs.world()
        local A, B = world:component(), world:component()
        local x = world:entity()
        local e = world:entity()
        world:set(e, A, 1)
        world:add(e, x)
        CHECK(shared_shape(function()
            return world:query(A):with(x)
        end))
        local q = world:query(A):with(x)
        local kept = internal(q)
        CHECK(kept.shared == true and count(q) == 1)
        world:delete(x)
        CHECK(count(q) == 0)
        CHECK(internal(world:query(A):with(x)).shared ~= true) -- a dead id is not shared
        CHECK(world:entity(x) == x)
        world:add(e, x)
        world:query(A):with(x) -- the first request of the shape of the entity made alive again
        local again = world:query(A):with(x)
        CHECK(internal(again).shared == true and internal(again) ~= kept)
        CHECK(count(again) == 1 and count(q) == 1)
        -- the modifiers of the dropped state return queries of their own
        q:without(B)
        CHECK(internal(q) ~= kept and internal(q).shared ~= true and count(q) == 1)
    end

    CASE("every dropped state leaves the count once")
    do
        local world = ecs.world()
        local A, B = world:component(), world:component()
        CHECK(shared_shape(function() -- the one shared state that stays
            return world:query(A)
        end))
        for _ = 1, 3000 do
            local x = world:entity()
            local kept = world:query(A):with(x)
            count(kept)
            count(world:query(x, x)) -- the entity twice in a shape
            count(world:query(A):with(x):without(B)) -- a variant of a variant
            count(world:query(A):any(x, B))
            world:delete(x)
            kept:without(B) -- a modifier of a dropped state shares nothing
            count(kept)
        end
        local shared = 0
        for _ = 1, MAX_SHAPES + 10 do
            local e = world:entity()
            world:query(e) -- the first request marks the shape
            if internal(world:query(e)).shared == true then
                shared += 1
            end
        end
        CHECK(shared == MAX_SHAPES - 1)
    end

    CASE("the shapes that a hook makes while its entity is deleted go with the entity")
    do
        local world = ecs.world()
        local A, B = world:component(), world:component()
        world:set(A, ecs.OnRemove, function(entity: any)
            -- the entity is still alive in its hook; the shape of B is shared, its variant with the
            -- entity too (requested again)
            count(world:query(B):with(entity))
            count(world:query(B):with(entity))
            count(world:query(B):with(entity))
        end)
        for _ = 1, 3000 do
            local e = world:entity() -- not an id of anything: world:delete takes its short path
            world:set(e, A, 1)
            world:delete(e)
        end
        local x = world:entity()
        world:add(world:entity(), x) -- an id: the long path, whose hooks run before the prune
        world:set(x, A, 1)
        world:delete(x)
        local shared = 0
        for _ = 1, MAX_SHAPES + 10 do
            local e = world:entity()
            world:query(e) -- the first request marks the shape
            if internal(world:query(e)).shared == true then
                shared += 1
            end
        end
        CHECK(shared == MAX_SHAPES - 1) -- only the shape of B stays
    end

    CASE("a debug world goes on when the shared states run out (it prints a warning once)")
    do
        local world = ecs.world(true)
        local ids: { any } = {}
        for i = 1, MAX_SHAPES + 5 do
            ids[i] = world:entity()
        end
        local shared, matched = 0, 0
        for i = 1, MAX_SHAPES + 5 do
            world:query(ids[i]) -- the first request marks the shape
            local q = world:query(ids[i])
            if internal(q).shared == true then
                shared += 1
            end
            matched += count(q)
        end
        CHECK(shared == MAX_SHAPES and matched == 0)
        -- the states of a deleted entity make room for new shapes
        world:delete(ids[1])
        local fresh = world:entity()
        world:query(fresh)
        CHECK(internal(world:query(fresh)).shared == true)
    end
end)

TEST("queries that are not cached reuse their iteration contexts", function()
    local world = ecs.world()
    local A = world:component() :: ecs.Component<number>
    local R, T1, T2 = world:entity(), world:entity(), world:entity()
    local n1, n2 = 0, 0
    for i = 1, 300 do
        local e = world:entity()
        world:set(e, A, i)
        if i % 3 == 0 then
            world:add(e, pair(R, T1))
            n1 += 1
        end
        if i % 5 == 0 then
            world:add(e, pair(R, T2))
            n2 += 1
        end
    end
    -- an id that is not alive keeps the shape from being shared: a new query state on every call
    -- (it excludes nothing: no entity has the id)
    local gone = world:entity()
    world:delete(gone)
    local function q1(): any
        return world:query(A):with(pair(R, T1)):without(gone)
    end
    local function q2(): any
        return world:query(A):with(pair(R, T2)):without(gone)
    end
    CHECK(internal(q1()).shared ~= true and internal(q1()).first_use == nil)

    CASE("values, loop after loop")
    local ok = true
    for _ = 1, 3 do
        local n = 0
        for e, a in q1() do
            n += 1
            ok = ok and world:get(e, A) == a
        end
        q1():each(function(e: any, a: any)
            n += 1
            ok = ok and world:get(e, A) == a
        end)
        ok = ok and n == 2 * n1
    end
    CHECK(ok)

    CASE("nested loops over queries with as many values")
    local n = 0
    for _ in q1() do
        for _ in q2() do
            n += 1
        end
    end
    CHECK(n == n1 * n2)
    n = 0
    q1():each(function()
        q2():each(function()
            n += 1
        end)
        for _ in q2() do
            n += 1
        end
    end)
    CHECK(n == 2 * n1 * n2)

    CASE("a loop left early, and an error in a callback")
    for _ in q1() do
        break
    end
    CHECK(count(q1()) == n1)
    local failed = not pcall(function()
        q1():each(function()
            error("stop")
        end)
    end)
    n = 0
    q1():each(function()
        n += 1
    end)
    CHECK(failed and n == n1)

    CASE("the entity of the loop deleted")
    n = 0
    for e in q2() do
        world:delete(e)
        n += 1
    end
    CHECK(n == n2 and count(q2()) == 0)
end)

TEST("a match list after many changes between loops", function()
    local world = ecs.world(true) -- checks every patched list against a scan of the bitsets
    local A = world:component() :: ecs.Component<number>
    local states = { world:entity(), world:entity(), world:entity() }
    local list: { any } = {}
    local state_of: { [any]: number } = {}
    for i = 1, 3000 do
        local e = world:entity()
        if i % 5 == 0 then -- scattered: the queries keep match lists (200 entities each)
            world:set(e, A, i)
            local s = #list % 3 + 1
            world:add(e, states[s])
            table.insert(list, e)
            state_of[e] = s
        end
    end
    -- moves k entities from one state tag to another: k changes of each of the two tags
    local function move(k: number, from: number, to: number)
        local moved = 0
        for _, e in list do
            if moved == k then
                break
            end
            if state_of[e] == from then
                world:remove(e, states[from])
                world:add(e, states[to])
                state_of[e] = to
                moved += 1
            end
        end
    end
    local function check(): boolean
        local ok = true
        for s = 1, 3 do
            local want: { [any]: boolean } = {}
            for e, state in state_of do
                if state == s then
                    want[e] = true
                end
            end
            ok = ok and same_matches(world:query(A):with(states[s]), want)
        end
        return ok
    end

    CASE("a few changes patch the list")
    CHECK(check())
    CHECK(check()) -- a shape is shared from its second request (a variant after its base)
    local q = world:query(A):with(states[1])
    CHECK(internal(q).shared == true)
    CHECK(check() and internal(q).mode == 2)
    move(3, 1, 2) -- the list of q: 197
    count(q)
    CHECK(internal(q).mode == 2 and check())

    CASE("changes up to a quarter of the list patch it")
    -- more changes than the journal of the tag holds (4 at first): a pass over the bitsets, and
    -- the journal grows for the next loops
    move(40, 2, 1)
    count(q)
    CHECK(internal(q).mode == 0 and check()) -- the list is built again: 237
    move(40, 1, 3)
    count(q)
    CHECK(internal(q).mode == 2 and check()) -- patched: 197

    CASE("more than a quarter of the list: a pass over the bitsets, the list after fewer")
    move(60, 1, 3) -- the journal holds them, but 60 > 197 // 4 (and more than half of the words of the tag)
    count(q)
    CHECK(internal(q).mode == 0)
    count(q) -- no change since: the list is built again
    CHECK(internal(q).mode == 2 and check())
end)

TEST("small queries that share a large term changed many times between loops", function()
    local world = ecs.world(true) -- checks every patched list against a scan of the bitsets
    local Position = world:component() :: ecs.Component<number>
    local Moving = world:entity()
    local kinds: { any } = {}
    for k = 1, 6 do
        kinds[k] = world:entity()
    end
    local list: { any } = {}
    local kind_of: { [any]: number } = {}
    local page_firsts: { any } = {}
    for i = 1, 3000 do
        local e = world:entity()
        world:set(e, Position, i)
        if i % 2 == 0 then
            world:add(e, Moving)
        end
        -- each kind has a few members in two words, one of them on the first slot of a page
        local k = i // 400
        if k >= 1 and k <= 6 and i % 400 < 40 and i % 4 == 0 then
            world:add(e, kinds[k])
            kind_of[e] = k
        end
        if ecs.ECS_ID(e) % 256 == 0 then
            table.insert(page_firsts, e)
            if k >= 1 and k <= 6 then
                world:add(e, kinds[k])
                kind_of[e] = k
            end
        end
        list[i] = e
    end
    local queries: { any } = {}
    for k = 1, 6 do
        queries[k] = world:query(Position):with(Moving, kinds[k]):cached()
    end
    local function check(): boolean
        for k, q in queries do
            local want = 0
            for _, e in list do
                if kind_of[e] == k and world:has(e, Moving) then
                    want += 1
                end
            end
            local got = 0
            for e in q do
                if kind_of[e] ~= k or not world:has(e, Moving) then
                    return false
                end
                got += 1
            end
            if got ~= want then
                return false
            end
        end
        return true
    end
    CHECK(check() and internal(queries[1]).mode == 2)
    local seed = 5
    local function rand(n: number): number
        seed = seed * 16807 % 2147483647
        return seed % n + 1
    end
    local function toggle(e: any)
        if world:has(e, Moving) then
            world:remove(e, Moving)
        else
            world:add(e, Moving)
        end
    end
    local ok = true
    for round = 1, 80 do
        -- 9 to 30 changes of Moving between two loops (the journal holds them): members of
        -- the kinds among them, the first slot of a page, a slot changed twice
        for _ = 1, 8 + rand(22) do
            local e = if rand(4) == 1 then list[(rand(6) * 400) + 4 * rand(10) - 4] else list[rand(#list)]
            toggle(e)
            if rand(8) == 1 then
                toggle(page_firsts[rand(#page_firsts)])
            end
            if rand(10) == 1 then
                toggle(e)
            end
        end
        if round % 8 == 0 then
            -- a member of a kind goes, another one comes: the small term changes too
            local e = list[(rand(6) * 400) + 4 * rand(10) - 4]
            local k = kind_of[e]
            if k then
                world:remove(e, kinds[k])
                kind_of[e] = nil
            else
                k = rand(6)
                world:add(e, kinds[k])
                kind_of[e] = k
            end
        end
        ok = ok and check()
    end
    CHECK(ok)
end)

TEST("a (*, T) record before its first read", function()
    local world = ecs.world(true)
    local R1, R2 = world:entity(), world:entity()
    local Data = world:component() :: ecs.Component<number>
    local W = ecs.Wildcard

    CASE("values and removals of its pairs, and its target deleted, without a read of (*, T)")
    local T = world:entity()
    local a, b, c = world:entity(), world:entity(), world:entity()
    world:add(a, pair(R1, T))
    world:set(b, pair(Data, T), 7)
    world:add(c, pair(R2, T))
    CHECK(world:get(b, pair(W, T)) == 7) -- the value of a data pair through the lazy record
    world:remove(a, pair(R1, T))
    world:delete(c)
    world:delete(T)
    CHECK(not world:has(b, pair(Data, W)) and world:target(b, Data) == nil)

    CASE("built from the pairs of its target at the first read")
    local U = world:entity()
    local d, e = world:entity(), world:entity()
    world:add(d, pair(R1, U))
    world:add(d, pair(R2, U))
    world:set(e, pair(Data, U), 1)
    CHECK(world:has(d, pair(W, U)) and world:has(e, pair(W, U)))
    world:remove(d, pair(R1, U))
    CHECK(world:has(d, pair(W, U))) -- d still has (R2, U)
    CHECK(same_matches(world:query(pair(W, U)), { [d] = true, [e] = true }))

    CASE("each, remove and remove_all as the first reads")
    local V1, V2, V3 = world:entity(), world:entity(), world:entity()
    for _, t in { V1, V2, V3 } do
        world:add(d, pair(R1, t))
        world:add(e, pair(R2, t))
    end
    CHECK(count(world:each(pair(W, V1))) == 2)
    world:remove(d, pair(W, V2))
    CHECK(not world:has(d, pair(R1, V2)) and world:has(e, pair(R2, V2)))
    world:remove_all(pair(W, V3))
    CHECK(not world:has(d, pair(R1, V3)) and not world:has(e, pair(R2, V3)))

    CASE("its last pair record freed")
    local X = world:entity()
    local holder = world:entity()
    world:add(holder, pair(R1, X))
    world:remove(holder, pair(R1, X))
    for _ = 1, 600 do -- more empty pair records than a batch: the ones before are freed
        local t = world:entity()
        world:add(holder, pair(R1, t))
        world:remove(holder, pair(R1, t))
    end
    world:add(holder, pair(R2, X))
    CHECK(world:has(holder, pair(W, X)) and count(world:query(pair(W, X))) == 1)
end)

TEST("wildcard values: (R, *) and (*, T) read through their mirrors", function()
    local W = ecs.Wildcard

    -- the value a query returns for an entity (nil when it does not match), and whether get agrees
    local function value_in(world: any, query: any, e: any, id: any): (any, boolean)
        local found, value = false, nil
        query:each(function(entity: any, v: any)
            if entity == e then
                found, value = true, v
            end
        end)
        local through_for = nil
        for entity, v in query do
            if entity == e then
                through_for = v
            end
        end
        return value, (not found or world:get(e, id) == value) and through_for == value
    end

    CASE("(R, *): the value of the lowest target, kept up to date")
    local world = ecs.world(true)
    local Owns = world:component()
    local t1, t2, t3 = world:entity(), world:entity(), world:entity()
    local e = world:entity()
    world:set(e, pair(Owns, t2), "b")
    local q = world:query(pair(Owns, W)):cached()
    local owns = pair(Owns, W)
    local v, ok = value_in(world, q, e, owns)
    CHECK(v == "b" and ok)
    world:set(e, pair(Owns, t1), "a") -- a lower target comes first
    v, ok = value_in(world, q, e, owns)
    CHECK(v == "a" and ok)
    world:set(e, pair(Owns, t1), "A") -- the value of the first pair changes in place
    v, ok = value_in(world, q, e, owns)
    CHECK(v == "A" and ok)
    world:set(e, pair(Owns, t2), "B") -- not the first pair
    v, ok = value_in(world, q, e, owns)
    CHECK(v == "A" and ok)
    world:remove(e, pair(Owns, t1))
    v, ok = value_in(world, q, e, owns)
    CHECK(v == "B" and ok)
    world:add(e, pair(Owns, t3)) -- a higher target without a value
    world:remove(e, pair(Owns, t2))
    v, ok = value_in(world, q, e, owns)
    CHECK(v == nil and ok and q:has(e))
    world:set(e, pair(Owns, t3), "c")
    v, ok = value_in(world, q, e, owns)
    CHECK(v == "c" and ok)
    world:delete(t3)
    CHECK(not q:has(e) and world:get(e, owns) == nil)

    CASE("(*, T): the value of the lowest relation")
    world = ecs.world(true)
    -- the relations in the order of their slots (world:component() would take ids 1..256)
    local Early = world:entity() -- a tag relation with a lower slot than the data relations
    -- data relations: A has the lower slot
    local A: ecs.Component<number>, B: ecs.Component<number> = world:entity() :: any, world:entity() :: any
    world:add(A, ecs.Component)
    world:add(B, ecs.Component)
    local Late = world:entity() -- a tag relation with a higher slot
    local T = world:entity()
    e = world:entity()
    local target = pair(W, T)
    world:set(e, pair(B, T), 2)
    q = world:query(target):cached()
    v, ok = value_in(world, q, e, target)
    CHECK(v == 2 and ok)
    world:set(e, pair(A, T), 1)
    v, ok = value_in(world, q, e, target)
    CHECK(v == 1 and ok)
    world:set(e, pair(B, T), 20) -- not the first pair
    world:set(e, pair(A, T), 10) -- the first pair
    v, ok = value_in(world, q, e, target)
    CHECK(v == 10 and ok)
    world:add(e, pair(Late, T))
    v, ok = value_in(world, q, e, target)
    CHECK(v == 10 and ok)
    world:remove(e, pair(A, T))
    v, ok = value_in(world, q, e, target)
    CHECK(v == 20 and ok)
    world:add(e, pair(Early, T)) -- a tag pair comes first: no value
    v, ok = value_in(world, q, e, target)
    CHECK(v == nil and ok and q:has(e))
    world:remove(e, pair(Early, T))
    v, ok = value_in(world, q, e, target)
    CHECK(v == 20 and ok)
    world:delete(B) -- the relation goes with its pairs
    v, ok = value_in(world, q, e, target)
    CHECK(v == nil and ok and q:has(e)) -- (Late, T) is left

    CASE("(*, T): a slot back to one pair, and to none")
    world = ecs.world(true)
    -- three data relations in the order of their slots
    local R1: ecs.Component<number>, R2: ecs.Component<number>, R3: ecs.Component<number> =
        world:entity() :: any, world:entity() :: any, world:entity() :: any
    for _, relation in { R1, R2, R3 } do
        world:add(relation, ecs.Component)
    end
    T = world:entity()
    target = pair(W, T)
    e = world:entity()
    world:set(e, pair(R1, T), 1)
    world:set(e, pair(R3, T), 3)
    q = world:query(target):cached()
    v, ok = value_in(world, q, e, target)
    CHECK(v == 1 and ok)
    world:remove(e, pair(R3, T)) -- not the pair that gives the value
    world:set(e, pair(R1, T), 10) -- the only pair now
    v, ok = value_in(world, q, e, target)
    CHECK(v == 10 and ok)
    world:set(e, pair(R3, T), 30)
    world:remove(e, pair(R1, T)) -- the pair that gives the value
    v, ok = value_in(world, q, e, target)
    CHECK(v == 30 and ok)
    world:set(e, pair(R2, T), 20) -- a lower relation than the one left
    v, ok = value_in(world, q, e, target)
    CHECK(v == 20 and ok)
    world:remove(e, pair(R2, T))
    world:remove(e, pair(R3, T))
    CHECK(not q:has(e) and world:get(e, target) == nil)
    world:set(e, pair(R3, T), 300)
    v, ok = value_in(world, q, e, target)
    CHECK(v == 300 and ok)

    CASE("get before any query reads the same pair")
    world = ecs.world()
    A, B = world:component() :: any, world:component() :: any
    T = world:entity()
    e = world:entity()
    world:set(e, pair(B, T), "b")
    world:set(e, pair(A, T), "a")
    CHECK(world:get(e, pair(W, T)) == "a")
    world:remove(e, pair(A, T))
    CHECK(world:get(e, pair(W, T)) == "b")

    CASE("clear, delete and remove_all leave no values in the mirrors")
    world = ecs.world(true)
    Owns = world:component()
    local R = world:component()
    t1, t2 = world:entity(), world:entity()
    local a, b, c = world:entity(), world:entity(), world:entity()
    for _, x in { a, b, c } do
        world:set(x, pair(Owns, t1), x)
        world:set(x, pair(R, t2), x)
    end
    local by_relation = world:query(pair(Owns, W)):cached()
    local by_target = world:query(pair(W, t2)):cached()
    CHECK(count(by_relation) == 3 and count(by_target) == 3)
    world:clear(a)
    world:delete(b)
    CHECK(count(by_relation) == 1 and count(by_target) == 1)
    CHECK(world:get(c, pair(Owns, W)) == c and world:get(c, pair(W, t2)) == c)
    local fresh = world:entity() -- may reuse the slot of b: nothing of b is left
    CHECK(world:get(fresh, pair(Owns, W)) == nil and world:get(fresh, pair(W, t2)) == nil)
    world:set(fresh, pair(Owns, t1), "fresh")
    local seen = {}
    by_relation:each(function(x: any, value: any)
        seen[x] = value
    end)
    CHECK(seen[fresh] == "fresh" and seen[c] == c)
    world:remove_all(pair(R, t2))
    CHECK(count(by_target) == 0 and world:get(c, pair(W, t2)) == nil)

    CASE("a mirror goes with the last pair that holds values, and comes back")
    world = ecs.world(true)
    Owns = world:component()
    e = world:entity()
    local targets = {}
    for i = 1, 3 do
        targets[i] = world:entity()
        world:set(e, pair(Owns, targets[i]), i)
    end
    q = world:query(pair(Owns, W)):cached()
    CHECK(world:get(e, pair(Owns, W)) == 1 and count(q) == 1)
    for _, t in targets do
        world:delete(t) -- the pair records go with their targets
    end
    CHECK(count(q) == 0 and world:get(e, pair(Owns, W)) == nil)
    local t = world:entity()
    world:set(e, pair(Owns, t), "again")
    v, ok = value_in(world, q, e, pair(Owns, W))
    CHECK(v == "again" and ok)

    CASE("match lists with mirrored values follow changes")
    world = ecs.world(true) -- checks every patched list against its bitsets
    local Health = world:component()
    local Damage = world:component()
    local Mark = world:entity()
    local hit = {}
    for i = 1, 4 do
        hit[i] = world:entity()
    end
    local list = {}
    local model: { [any]: { [number]: number } } = {}
    for i = 1, 3000 do
        local x = world:entity()
        world:set(x, Health, i)
        if i % 7 == 0 then
            world:add(x, Mark)
            local targets_of = {}
            world:set(x, pair(Damage, hit[i % 4 + 1]), i)
            targets_of[i % 4 + 1] = i
            model[x] = targets_of
            table.insert(list, x)
        end
        for _ = 1, 20 do
            world:entity() -- spread the entities over many pages
        end
    end
    local damaged = world:query(Health, pair(Damage, W)):with(Mark):cached()
    local seed = 5
    local function random(n: number): number
        seed = seed * 16807 % 2147483647
        return seed % n + 1
    end
    local all_ok = true
    for _ = 1, 60 do
        for _ = 1, 6 do
            local x = list[random(#list)]
            local k = random(4)
            local targets_of = model[x]
            if targets_of[k] and random(2) == 1 then
                world:remove(x, pair(Damage, hit[k]))
                targets_of[k] = nil
            else
                local value = random(1000)
                world:set(x, pair(Damage, hit[k]), value)
                targets_of[k] = value
            end
        end
        local expected = {}
        for x, targets_of in model do
            for k = 1, 4 do -- the targets were created in this order: the lowest slot first
                if targets_of[k] then
                    expected[x] = targets_of[k]
                    break
                end
            end
        end
        local visited = 0
        damaged:each(function(x: any, _: any, value: any)
            visited += 1
            all_ok = all_ok and expected[x] == value
        end)
        local expected_count = 0
        for _ in expected do
            expected_count += 1
        end
        all_ok = all_ok and visited == expected_count
    end
    CHECK(all_ok)
end)

TEST("match lists that skip the changes outside their smallest term", function()
    CASE("a new value page of a returned component is seen")
    -- a debug world checks the page references of every patched list, too
    local world = ecs.world(true)
    local A = world:component()
    local Rare, Common = world:entity(), world:entity()
    for _ = 1, 600 do -- A and Common on many entities: Rare is the smallest term
        local x = world:entity()
        world:set(x, A, 0)
        world:add(x, Common)
    end
    for _ = 1, 600 do
        world:entity() -- the next entities start a page where A has no values
    end
    local others = {}
    for i = 1, 40 do
        others[i] = world:entity()
    end
    local e = world:entity() -- not the first slot of its page
    world:add(e, Rare)
    world:add(e, Common)
    world:add(e, A) -- A without a value: no value page yet
    local q = world:query(A):with(Rare, Common):cached()
    local function value_of_e(): any
        local found = "missing"
        q:each(function(entity: any, a: any)
            if entity == e then
                found = a
            end
        end)
        return found
    end
    CHECK(value_of_e() == nil)
    world:add(others[1], Common) -- a change outside Rare: the list is patched and up to date
    CHECK(value_of_e() == nil)
    world:add(others[2], Common)
    world:set(e, A, 42) -- the first value of the page: a new page, noted at its first slot
    CHECK(value_of_e() == 42)
    local through_for = nil
    for entity, a in q do
        if entity == e then
            through_for = a
        end
    end
    CHECK(through_for == 42)

    CASE("changes outside the smallest term leave the list as it is")
    world = ecs.world(true)
    local Moving = world:entity()
    local Kind = world:entity()
    local Position = world:component()
    local list = {}
    local members = {}
    for i = 1, 3000 do
        local x = world:entity()
        world:set(x, Position, i)
        world:add(x, Moving)
        if i % 300 == 0 then
            world:add(x, Kind)
            members[x] = true
        end
        list[i] = x
    end
    q = world:query(Position):with(Moving, Kind):cached()
    local seed = 3
    local all_ok = true
    for _ = 1, 30 do
        for _ = 1, 20 do
            seed = seed * 16807 % 2147483647
            local x = list[seed % #list + 1]
            if world:has(x, Moving) then
                world:remove(x, Moving)
            else
                world:add(x, Moving)
            end
        end
        local seen = 0
        q:each(function(x: any)
            seen += 1
            all_ok = all_ok and members[x] == true and world:has(x, Moving)
        end)
        local want = 0
        for x in members do
            if world:has(x, Moving) then
                want += 1
            end
        end
        all_ok = all_ok and seen == want
    end
    CHECK(all_ok)
end)

TEST("world:each and world:children walk the bitsets of large records", function()
    local world = ecs.world()
    local Tag = world:entity()
    local list: { any } = {}
    for i = 1, 500 do
        local e = world:entity()
        if i % 3 ~= 0 then -- words that are full and words that are not
            world:add(e, Tag)
            table.insert(list, e)
        end
    end

    CASE("every member once, in ascending order")
    local seen: { any } = {}
    for e in world:each(Tag) do
        table.insert(seen, e)
    end
    local ordered = #seen == #list
    for i, e in seen do
        ordered = ordered and e == list[i]
    end
    CHECK(ordered)

    CASE("members that leave or are deleted ahead of the loop are skipped")
    local skipped = { [list[10]] = true, [list[40]] = true, [list[300]] = true }
    local visited = 0
    local wrong = false
    for e in world:each(Tag) do
        visited += 1
        if skipped[e] then
            wrong = true
        end
        if e == list[5] then
            world:remove(list[10], Tag) -- the same word
            world:delete(list[40]) -- a later word
            world:remove(list[300], Tag)
        end
    end
    CHECK(not wrong and visited == #list - 3)

    CASE("the current entity may be deleted, entities created in the loop are not visited")
    local count_before = 0
    for _ in world:each(Tag) do
        count_before += 1
    end
    visited = 0
    for e in world:each(Tag) do
        visited += 1
        world:delete(e)
        world:add(world:entity(), Tag) -- new entities with the tag: the loop still ends
    end
    CHECK(visited == count_before and count(world:each(Tag)) == count_before)

    CASE("the children of a parent with many children")
    local parent = world:entity()
    local children: { [any]: boolean } = {}
    for _ = 1, 200 do
        local child = world:entity()
        world:add(child, pair(ecs.ChildOf, parent))
        children[child] = true
    end
    local n, ok = 0, true
    for child in world:children(parent) do
        n += 1
        ok = ok and children[child] == true
    end
    CHECK(ok and n == 200)
    -- deleting the children in the loop (each child is visited once)
    n = 0
    for child in world:children(parent) do
        n += 1
        world:delete(child)
    end
    CHECK(n == 200 and count(world:children(parent)) == 0)

    CASE("the id deleted inside its own loop: its members are not returned after that")
    local Gone = world:entity()
    for _ = 1, 3000 do
        world:add(world:entity(), Gone)
    end
    local after = 0
    local started = false
    for _ in world:each(Gone) do
        if started then
            after += 1
        else
            started = true
            world:delete(Gone) -- every member loses the id
        end
    end
    CHECK(started and after == 0)

    CASE("a (*, T) record read the first time by world:each")
    local T = world:entity()
    local R1, R2 = world:entity(), world:entity()
    for i = 1, 150 do
        local e = world:entity()
        world:add(e, pair(if i % 2 == 0 then R1 else R2, T))
    end
    CHECK(count(world:each(pair(ecs.Wildcard, T))) == 150)

    CASE("two members far apart come in ascending order (the words of a small record)")
    local far: { any } = {}
    for i = 1, 20000 do
        far[i] = world:entity()
    end
    local ascending = true
    for a = 1, 30 do
        for gap = 1, 12 do
            local Mark = world:entity()
            local low, high = far[a * 37], far[a * 37 + gap * 1500]
            world:add(high, Mark) -- the later slot first
            world:add(low, Mark)
            local order: { any } = {}
            for e in world:each(Mark) do
                table.insert(order, e)
            end
            ascending = ascending and #order == 2 and order[1] == low and order[2] == high
        end
    end
    CHECK(ascending)
end)

TEST("query shapes are shared from their second request", function()
    local world = ecs.world()
    local A, B, C = world:component(), world:component(), world:component()
    for i = 1, 100 do
        local e = world:entity()
        world:set(e, A, i)
        if i % 2 == 0 then
            world:set(e, B, i)
        end
    end

    CASE("the first request is a query of its own, the second one shares its state")
    local first = world:query(A, C)
    CHECK(internal(first).shared ~= true)
    local second = world:query(A, C)
    CHECK(internal(second).shared == true and internal(world:query(A, C)) == internal(second))

    CASE("a query kept and iterated again becomes the shared state of its shape")
    local kept = world:query(B)
    CHECK(internal(kept).shared ~= true)
    CHECK(count(kept) == 50)
    CHECK(count(kept) == 50) -- the second loop: kept by the caller
    CHECK(internal(kept).shared == true and internal(world:query(B)) == internal(kept))

    CASE(":cached() on a first request shares it")
    local D = world:component()
    local cached = world:query(D):cached()
    CHECK(internal(cached).shared == true and internal(world:query(D)) == internal(cached))

    CASE("a modifier shares the base: identical queries with a modifier share one state")
    local E = world:component()
    local states: { any } = {}
    for i = 1, 5 do
        states[i] = internal(world:query(E):with(A):cached())
    end
    local same = states[1].shared == true
    for i = 2, 5 do
        same = same and states[i] == states[1]
    end
    CHECK(same)

    CASE("a query requested once keeps nothing after its entity is deleted")
    local x = world:entity()
    world:set(world:entity(), A, 0)
    CHECK(count(world:query(A):with(x)) == 0) -- the first request marks the shape
    world:delete(x)
    CHECK(count(world:query(A):with(x)) == 0) -- a dead id: not shared
    CHECK(internal(world:query(A):with(x)).shared ~= true)
end)

TEST("queries that are not cached gather small results first", function()
    local world = ecs.world()
    local A, B = world:component(), world:component()
    local Link, Other = world:entity(), world:entity()
    local link = pair(Link, Other)
    local marked: { [any]: number } = {}
    for i = 1, 3000 do
        local e = world:entity()
        world:set(e, A, i)
        world:set(e, B, -i)
        if i % 37 == 0 then
            world:add(e, link)
            marked[e] = i
        end
    end
    local n_marked = 0
    for _ in marked do
        n_marked += 1
    end

    CASE("for-in and each return every match with its values")
    local ok, n = true, 0
    for e, a: any, b: any in world:query(A, B, link) do
        n += 1
        ok = ok and marked[e] == a and b == -a
    end
    CHECK(ok and n == n_marked)
    n = 0
    world:query(A, B, link):each(function(e: any, a: any, b: any)
        n += 1
        ok = ok and marked[e] == a and b == -a
    end)
    CHECK(ok and n == n_marked)

    CASE("nested loops over queries that are not cached")
    local pairs_seen = 0
    for _ in world:query(A, link) do
        for _ in world:query(B, link) do
            pairs_seen += 1
        end
    end
    CHECK(pairs_seen == n_marked * n_marked)

    CASE("a loop left early, then a new one")
    for _ in world:query(A, link) do
        break
    end
    CHECK(count(world:query(A, link)) == n_marked)

    CASE("an error in a callback, then a new loop")
    local failed = not pcall(function()
        world:query(A, link):each(function()
            error("stop")
        end)
    end)
    CHECK(failed and count(world:query(A, link)) == n_marked)

    CASE("the entity of the loop deleted, and one ahead of it")
    local deleted = 0
    for e in world:query(A, link) do
        if world:contains(e) then
            world:delete(e)
            deleted += 1
        end
    end
    CHECK(deleted == n_marked and count(world:query(A, link)) == 0)
end)

TEST("queries that share a changing tag re-check its changes", function()
    local world = ecs.world(true) -- checks every patched list against a scan of the bitsets
    local Moving = world:entity()
    local Position = world:component()
    local kinds: { any } = {}
    for k = 1, 6 do
        kinds[k] = world:entity()
    end
    local list: { any } = {}
    local kind_of: { [any]: number } = {}
    for i = 1, 6000 do
        local e = world:entity()
        world:set(e, Position, i)
        world:add(e, Moving)
        if i % 100 == 0 then
            local k = (i // 100) % 6 + 1
            world:add(e, kinds[k])
            kind_of[e] = k
        end
        list[i] = e
    end
    local queries: { any } = {}
    for k = 1, 6 do
        queries[k] = world:query(Position):with(Moving, kinds[k]):cached()
    end
    local seed = 17
    local function random(n: number): number
        seed = seed * 16807 % 2147483647
        return seed % n + 1
    end

    CASE("few and many changes of a large term between the loops")
    local all_ok = true
    for frame = 1, 40 do
        -- a few changes, and many (more than the list sizes, fewer than the words of the terms)
        for _ = 1, if frame % 4 == 0 then 120 else 10 do
            local e = list[random(#list)]
            if world:has(e, Moving) then
                world:remove(e, Moving)
            else
                world:add(e, Moving)
            end
        end
        for k, q in queries do
            local want: { [any]: boolean } = {}
            for e, kind in kind_of do
                if kind == k and world:has(e, Moving) then
                    want[e] = true
                end
            end
            all_ok = all_ok and same_matches(q, want)
        end
    end
    CHECK(all_ok)
    -- many changes of a large term patch small lists instead of passing over the bitsets
    CHECK(internal(queries[1]).mode == 2)
end)

-- The monitor of a query and a function that returns its events since the previous call:
-- "+name" for an entity that started matching, "-name" for one that stopped.
local function monitored(q: any, names: { [any]: string }): (any, () -> string)
    local log: { string } = {}
    local monitor = q:monitor()
    monitor.added(function(e: any)
        table.insert(log, "+" .. (names[e] or "?"))
    end)
    monitor.removed(function(e: any)
        table.insert(log, "-" .. (names[e] or "?"))
    end)
    return monitor,
        function(): string
            local text = table.concat(log, " ")
            table.clear(log)
            return text
        end
end

TEST("query monitors", function()
    CASE("an entity enters and leaves with the ids of the query")
    local world = ecs.world()
    -- the cases give A and B new components: plain ids for the type checker
    local A: any, B: any = world:component(), world:component()
    local e = world:entity()
    local _, take = monitored(world:query(A):with(B), { [e] = "e" })
    world:set(e, A, 1)
    CHECK(take() == "")
    world:set(e, B, 2)
    CHECK(take() == "+e")
    world:set(e, A, 3) -- a value changes: nothing
    world:add(e, B)
    CHECK(take() == "")
    world:remove(e, B)
    CHECK(take() == "-e")
    world:remove(e, B)
    CHECK(take() == "")
    world:set(e, B, 4)
    CHECK(take() == "+e")

    CASE("added runs after the add, removed before the removal: the values can be read")
    local seen_added, seen_removed = nil, nil
    local reader = world:query(A):with(B):monitor()
    reader.added(function(x: any)
        seen_added = world:get(x, B)
    end)
    reader.removed(function(x: any)
        seen_removed = world:get(x, A)
    end)
    local f = world:entity()
    world:set(f, A, 7)
    world:set(f, B, 8)
    world:remove(f, A)
    CHECK(seen_added == 8 and seen_removed == 7)
    reader.disconnect()

    CASE("excluded ids and Disabled")
    world = ecs.world()
    A, B = world:component(), world:component()
    local Frozen = world:entity()
    e = world:entity()
    world:set(e, A, 1)
    local frozen_in_added: boolean? = nil
    local monitor, take2 = monitored(world:query(A):without(Frozen), { [e] = "e" })
    CHECK(take2() == "") -- the matches when the monitor is made are members already
    world:add(e, Frozen)
    CHECK(take2() == "-e")
    monitor.added(function(x: any)
        frozen_in_added = world:has(x, Frozen)
    end)
    world:remove(e, Frozen)
    CHECK(frozen_in_added == true) -- before the removal of the excluded id completes
    monitor.disconnect()
    local _, take3 = monitored(world:query(A):without(Frozen), { [e] = "e" })
    world:add(e, ecs.Disabled)
    CHECK(take3() == "-e")
    world:remove(e, ecs.Disabled)
    CHECK(take3() == "+e")
    local _, take4 = monitored(world:query(A):with(ecs.Disabled), { [e] = "e" })
    world:add(e, ecs.Disabled)
    CHECK(take4() == "+e" and take3() == "-e")

    CASE("OR terms")
    world = ecs.world()
    A = world:component()
    local T1, T2 = world:entity(), world:entity()
    e = world:entity()
    world:set(e, A, 1)
    local _, take5 = monitored(world:query(A):any(T1, T2), { [e] = "e" })
    world:add(e, T1)
    CHECK(take5() == "+e")
    world:add(e, T2)
    world:remove(e, T1)
    CHECK(take5() == "")
    world:remove(e, T2)
    CHECK(take5() == "-e")

    CASE("pairs with a target and with any target")
    world = ecs.world()
    A = world:component()
    local Likes = world:entity()
    local t1, t2 = world:entity(), world:entity()
    e = world:entity()
    world:set(e, A, 1)
    local _, take_pair = monitored(world:query(A):with(pair(Likes, t1)), { [e] = "e" })
    local _, take_any = monitored(world:query(A):with(pair(Likes, ecs.Wildcard)), { [e] = "e" })
    world:add(e, pair(Likes, t2))
    CHECK(take_pair() == "" and take_any() == "+e")
    world:add(e, pair(Likes, t1))
    CHECK(take_pair() == "+e" and take_any() == "")
    world:remove(e, pair(Likes, t2))
    CHECK(take_pair() == "" and take_any() == "")
    world:add(e, pair(Likes, t2))
    world:remove(e, pair(Likes, ecs.Wildcard))
    CHECK(take_pair() == "-e" and take_any() == "-e")
    world:add(e, Likes) -- the relation as a tag: no pair
    CHECK(take_pair() == "" and take_any() == "")

    CASE("an exclusive relation that replaces a pair")
    world = ecs.world()
    A = world:component()
    local p1, p2 = world:entity(), world:entity()
    local c = world:entity()
    world:set(c, A, 1)
    local names = { [c] = "c" }
    local _, any_parent = monitored(world:query(A):with(pair(ecs.ChildOf, ecs.Wildcard)), names)
    local _, of_p1 = monitored(world:query(A):with(pair(ecs.ChildOf, p1)), names)
    local _, of_p2 = monitored(world:query(A):with(pair(ecs.ChildOf, p2)), names)
    local _, orphan = monitored(world:query(A):without(pair(ecs.ChildOf, ecs.Wildcard)), names)
    world:add(c, pair(ecs.ChildOf, p1))
    CHECK(any_parent() == "+c" and of_p1() == "+c" and of_p2() == "" and orphan() == "-c")
    local has_new_parent: boolean? = nil
    local timing = world:query(A):with(pair(ecs.ChildOf, ecs.Wildcard)):without(pair(ecs.ChildOf, p1)):monitor()
    timing.added(function(entity: any)
        has_new_parent = world:has(entity, pair(ecs.ChildOf, p2)) -- the entry comes with the add
    end)
    world:add(c, pair(ecs.ChildOf, p2))
    timing.disconnect()
    CHECK(has_new_parent == true)
    CHECK(any_parent() == "" and of_p1() == "-c" and of_p2() == "+c" and orphan() == "")
    world:remove(c, pair(ecs.ChildOf, p2))
    CHECK(any_parent() == "-c" and of_p2() == "-c" and orphan() == "+c")

    CASE("an exclusive replacement whose new pair is not added")
    local p3 = world:entity()
    world:add(c, pair(ecs.ChildOf, p1))
    CHECK(any_parent() == "+c" and of_p1() == "+c" and orphan() == "-c")
    local disconnect = world:removed(ecs.ChildOf, function(_: any, id: any)
        if id == pair(ecs.ChildOf, p1) then
            world:delete(p3) -- the new target goes while the old pair is removed
        end
    end)
    world:add(c, pair(ecs.ChildOf, p3))
    disconnect()
    CHECK(not world:has(c, pair(ecs.ChildOf, ecs.Wildcard)))
    CHECK(any_parent() == "-c" and orphan() == "+c")

    CASE("clear and delete leave once, and never enter")
    world = ecs.world()
    A, B = world:component(), world:component()
    local Excluded = world:entity()
    local x, y = world:entity(), world:entity()
    for _, entity in { x, y } do
        world:set(entity, A, 1)
        world:set(entity, B, 2)
    end
    world:add(y, Excluded)
    local _, take6 = monitored(world:query(A, B):without(Excluded), { [x] = "x", [y] = "y" })
    world:clear(x)
    CHECK(take6() == "-x")
    world:clear(y) -- a non-member with the excluded id: nothing
    CHECK(take6() == "")
    world:set(x, A, 1)
    world:set(x, B, 2)
    CHECK(take6() == "+x")
    world:delete(x)
    CHECK(take6() == "-x")
    world:set(y, A, 1)
    world:set(y, B, 2)
    world:add(y, Excluded)
    CHECK(take6() == "+y -y")
    world:delete(y)
    CHECK(take6() == "")

    CASE("cascades and deleted ids")
    world = ecs.world()
    A = world:component()
    local parent = world:entity()
    local kids: { [any]: string } = {}
    for i = 1, 3 do
        local kid = world:entity()
        world:set(kid, A, i)
        world:add(kid, pair(ecs.ChildOf, parent))
        kids[kid] = "k"
    end
    local _, take7 = monitored(world:query(A):with(pair(ecs.ChildOf, parent)), kids)
    world:delete(parent)
    CHECK(take7() == "-k -k -k")
    local Tag = world:entity()
    local tagged: { [any]: string } = {}
    for _ = 1, 2 do
        local t = world:entity()
        world:set(t, A, 0)
        world:add(t, Tag)
        tagged[t] = "t"
    end
    local _, take8 = monitored(world:query(A):with(Tag), tagged)
    world:delete(Tag) -- the id goes from its members
    CHECK(take8() == "-t -t")

    CASE("batch operations")
    world = ecs.world()
    A = world:component()
    local Mark = world:entity()
    local all: { [any]: string } = {}
    for i = 1, 3 do
        local b = world:entity()
        world:set(b, A, i)
        all[b] = "b"
    end
    local _, take9 = monitored(world:query(A):with(Mark), all)
    world:query(A):add_all(Mark)
    CHECK(take9() == "+b +b +b")
    world:remove_all(Mark)
    CHECK(take9() == "-b -b -b")
    world:query(A):add_all(Mark)
    CHECK(take9() == "+b +b +b")
    world:query(A):with(Mark):delete_all()
    CHECK(take9() == "-b -b -b")

    CASE("disconnect, also from a callback")
    world = ecs.world()
    A = world:component()
    e = world:entity()
    local m, take10 = monitored(world:query(A), { [e] = "e" })
    m.disconnect()
    m.disconnect() -- again: nothing
    world:set(e, A, 1)
    CHECK(take10() == "")
    local calls = 0
    local self_stopping = world:query(A):monitor()
    self_stopping.removed(function()
        calls += 1
        self_stopping.disconnect()
    end)
    world:remove(e, A)
    world:set(e, A, 2)
    world:remove(e, A)
    CHECK(calls == 1)

    CASE("callbacks that change the world")
    world = ecs.world()
    A, B = world:component(), world:component()
    e = world:entity()
    local bouncing, take11 = monitored(world:query(A):with(B), { [e] = "e" })
    local once = true
    bouncing.added(function(entity: any)
        if once then
            once = false
            world:remove(entity, B) -- leaves from inside its entry
        end
    end)
    world:set(e, A, 1)
    world:set(e, B, 2)
    CHECK(take11() == "-e" and not world:has(e, B))
    world:set(e, B, 3)
    CHECK(take11() == "")

    CASE("several monitors, and a hook on the same id")
    world = ecs.world()
    A = world:component()
    local hooked = 0
    world:set(A, ecs.OnAdd, function()
        hooked += 1
    end)
    e = world:entity()
    local _, first = monitored(world:query(A), { [e] = "e" })
    local _, second = monitored(world:query(A), { [e] = "e" })
    world:set(e, A, 1)
    CHECK(first() == "+e" and second() == "+e" and hooked == 1)

    CASE("a monitor without required ids sees deletes")
    world = ecs.world()
    local X1, X2 = world:entity(), world:entity()
    e = world:entity()
    world:add(e, X2)
    local _, take_or = monitored(world:query():any(X1, X2), { [e] = "e" })
    world:delete(e)
    CHECK(take_or() == "-e")

    CASE("ids without records when the monitor is made")
    world = ecs.world()
    A = world:component()
    local Later, Rel = world:entity(), world:entity()
    local target = world:entity()
    e = world:entity()
    local _, take12 = monitored(world:query(A):with(Later, pair(Rel, ecs.Wildcard)), { [e] = "e" })
    world:set(e, A, 1)
    world:add(e, Later)
    world:add(e, pair(Rel, target))
    CHECK(take12() == "+e")
    world:delete(e)
    CHECK(take12() == "-e")

    CASE("an exclusive replacement that removes an excluded pair")
    world = ecs.world()
    A = world:component()
    local Slot = world:entity()
    world:add(Slot, ecs.Exclusive)
    local old_item, new_item = world:entity(), world:entity()
    e = world:entity()
    world:set(e, A, 1)
    world:add(e, pair(Slot, old_item))
    local _, take_swap = monitored(world:query(A):without(pair(Slot, old_item)), { [e] = "e" })
    world:add(e, pair(Slot, new_item)) -- replaces the excluded pair: the entity enters
    CHECK(take_swap() == "+e")
    world:add(e, pair(Slot, old_item))
    CHECK(take_swap() == "-e")

    CASE("a pair term and a term (R, *) of its relation in other roles")
    world = ecs.world()
    A = world:component()
    local Tagged, Held = world:entity(), world:entity()
    local item = world:entity()
    e = world:entity()
    world:set(e, A, 1)
    world:add(e, Tagged)
    local _, take_roles =
        monitored(world:query(A):without(pair(Held, ecs.Wildcard)):any(Tagged, pair(Held, item)), { [e] = "e" })
    world:add(e, pair(Held, item)) -- an OR term, but any pair of Held excludes the entity
    CHECK(take_roles() == "-e")
    world:remove(e, pair(Held, item))
    CHECK(take_roles() == "+e")

    CASE("the terms of a query that is not shared, changed after its monitor was made")
    world = ecs.world()
    A = world:component()
    local Rel2 = world:entity()
    local owner = world:entity()
    local Or1, Or2, B2, C2 = world:entity(), world:entity(), world:entity(), world:entity()
    -- an id that is not alive keeps the shape from being shared: a state of its own, changed in
    -- place by the modifiers (it excludes nothing: no entity has the id)
    local gone = world:entity()
    world:delete(gone)
    local grown = world:query(A):with(pair(Rel2, owner)):without(gone):any(Or1)
    local grown_monitor = grown:monitor()
    local grown_log: { string } = {}
    grown_monitor.added(function()
        table.insert(grown_log, "+")
    end)
    grown:any(Or2) -- the monitor keeps the terms it was made with
    e = world:entity()
    world:set(e, A, 1)
    world:add(e, Or1)
    world:add(e, pair(Rel2, owner))
    CHECK(table.concat(grown_log) == "+")
    local replaced = world:query(A):with(pair(Rel2, owner)):without(B2, gone)
    local other = world:entity()
    local _, take_replaced = monitored(replaced, { [other] = "f" })
    replaced:without(C2)
    world:set(other, A, 1)
    world:add(other, pair(Rel2, owner))
    world:add(other, B2)
    world:add(other, C2)
    world:remove(other, B2) -- excluded by the terms of the monitor no more
    CHECK(take_replaced() == "+f -f +f" and not replaced:has(other))

    CASE("terms that a monitor does not take")
    world = ecs.world()
    A = world:component()
    world:track(A)
    CHECK_EXPECT_ERR(function()
        world:query(A):with(pair(ecs.Wildcard, world:entity())):monitor()
    end)
    CHECK_EXPECT_ERR(function()
        world:query(A):changed(A):monitor()
    end)
end)

-- a failed case must fail the process (CI reads the exit code)
assert(FINISH() == 0, "some test cases failed")
