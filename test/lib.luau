--!strict
--# selene: allow(empty_loop) -- benchmark loops iterate for their cost only
--[[
    Tests of mErCS features that the shared core suite (test/core.luau) and the jecs
    suite (test/jecs_compat) do not cover: query:each, cached query list mode, changes during
    iteration, more than 4 ids in get/has, relationships, cleanup without leftovers, signals.

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
    local q = world:query(pair(Likes, bob)):cached() -- a concrete pair: changed in place
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

-- a failed case must fail the process (CI reads the exit code)
assert(FINISH() == 0, "some test cases failed")
