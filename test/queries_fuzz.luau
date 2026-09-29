--!strict
--[[
    Randomized test of queries against brute force: random query shapes (returned ids, with,
    without, OR terms, pairs with a target, (R, *), (*, T), an exclusive relation, ChildOf,
    Disabled named or not, the values of wildcard pairs), cached and written inline, iterated
    with for-in, each, a loop left with break and then a full one, and a nested loop; random
    changes in bursts, few and many per pass (so that match lists are patched, filtered and
    built again), batch operations, deleted targets; entities in dense runs, scattered among
    empty ones, and from a slot pool. After every burst each query must return exactly the
    matches of a brute force over world:has / world:get, in ascending slot order, with their
    values; count() and has() must agree.

    Run from the repository root (a seed and a number of rounds run one world, "debug" makes
    it a debug world, which checks every patched match list; without them, two seeds and a
    debug world):
        luau test/queries_fuzz.luau
        luau test/queries_fuzz.luau -a 42 300 debug
]]

local ecs = require("../src")

local args = { ... }
local pair, W = ecs.pair, ecs.Wildcard

type Entry = {
    label: string,
    q: any,
    returned: { any },
    with: { any },
    without: { any },
    either: { any }?,
    disabled_named: boolean,
    inline: (() -> any)?,
}

local function run(first_seed: number, rounds: number, debug_world: boolean): { string }
    local seed = first_seed
    local function rand(n: number): number
        seed = seed * 16807 % 2147483647
        return seed % n + 1
    end

    local world = ecs.world(debug_world)
    local pool = world:pool()
    local comps: { any } = { world:component(), world:component(), world:component(), world:component() }
    local tags: { any } = { world:entity(), world:entity(), world:entity() }
    local R: any = world:component() -- a data relation
    local S: any = world:entity() -- a tag relation
    local X: any = world:entity() -- an exclusive tag relation
    world:add(X, ecs.Exclusive)
    local targets: { any } = { world:entity(), world:entity(), world:entity(), world:entity() }

    local entities: { any } = {}
    local function spawn_burst()
        local kind = rand(4)
        for _ = 1, rand(40) do
            local e = if kind == 1 then pool:entity() else world:entity()
            table.insert(entities, e)
            if kind == 2 then
                for _ = 1, rand(50) do
                    world:entity() -- empty entities between: scattered matches
                end
            end
            for _, c in comps do
                if rand(2) == 1 then
                    world:set(e, c, rand(100))
                end
            end
            for _, t in tags do
                if rand(3) == 1 then
                    world:add(e, t)
                end
            end
        end
    end
    for _ = 1, 8 do
        spawn_burst()
    end

    local function random_term(): any
        local roll = rand(14)
        if roll <= 4 then
            return comps[rand(#comps)]
        elseif roll <= 6 then
            return tags[rand(#tags)]
        elseif roll == 7 then
            return pair(R, targets[rand(#targets)])
        elseif roll == 8 then
            return pair(R, W)
        elseif roll == 9 then
            return pair(S, W)
        elseif roll == 10 then
            return pair(W, targets[rand(#targets)])
        elseif roll == 11 then
            return pair(X, W)
        elseif roll == 12 then
            return pair(X, targets[rand(#targets)])
        elseif roll == 13 then
            return pair(ecs.ChildOf, W)
        end
        return ecs.Disabled
    end

    -- the value a query returns for a term: a wildcard gives the pair with the lowest slot
    -- (of the target for (R, *), of the relation for (*, T))
    local function value_of(e: any, term: any): any
        if ecs.IS_PAIR(term) then
            local first = ecs.pair_first(world, term)
            local second = ecs.pair_second(world, term)
            if second == W then
                if first == ecs.ChildOf then
                    return nil -- a tag relation
                end
                local best, best_slot = nil, math.huge
                for _, t in targets do
                    if world:has(e, pair(first, t)) and ecs.ECS_ID(t) < best_slot then
                        best, best_slot = pair(first, t), ecs.ECS_ID(t)
                    end
                end
                return if best then world:get(e, best) else nil
            elseif first == W then
                local best, best_slot = nil, math.huge
                for _, relation in { R, S, X } do
                    if world:has(e, pair(relation, second)) and ecs.ECS_ID(relation) < best_slot then
                        best, best_slot = pair(relation, second), ecs.ECS_ID(relation)
                    end
                end
                return if best then world:get(e, best) else nil
            end
        end
        return world:get(e, term)
    end

    local entries: { Entry } = {}
    for k = 1, 24 do
        local returned: { any } = {}
        for _ = 1, rand(3) do
            table.insert(returned, random_term())
        end
        local without: { any } = {}
        if rand(3) == 1 then
            table.insert(without, random_term())
            if rand(3) == 1 then
                table.insert(without, random_term())
            end
        end
        local either: { any }? = if rand(4) == 1 then { random_term(), random_term() } else nil
        local extra: { any } = if rand(3) == 1 then { random_term() } else {}
        local disabled_named = false
        for _, list in { returned, without, extra, either or {} } do
            for _, term in list do
                if term == ecs.Disabled then
                    disabled_named = true
                end
            end
        end
        local with = table.clone(returned)
        for _, term in extra do
            table.insert(with, term)
        end
        local function build(): any
            local q: any = (world :: any):query(table.unpack(returned))
            if #extra > 0 then
                q = q:with(table.unpack(extra))
            end
            if #without > 0 then
                q = q:without(table.unpack(without))
            end
            if either then
                q = q:any(table.unpack(either))
            end
            return q
        end
        local inline = rand(3) == 1
        local q = build()
        if not inline and rand(2) == 1 then
            q = q:cached()
        end
        table.insert(entries, {
            label = `q{k}`,
            q = q,
            returned = returned,
            with = with,
            without = without,
            either = either,
            disabled_named = disabled_named,
            inline = if inline then build else nil,
        })
    end

    local failures: { string } = {}
    local function fail(message: string)
        if #failures < 12 then
            table.insert(failures, message)
        end
    end

    -- the matches of an entry by brute force, in ascending slot order, and their values
    local function expected(entry: Entry): ({ any }, { [any]: { any } })
        local list: { any } = {}
        local values: { [any]: { any } } = {}
        for _, e in entities do
            if not world:contains(e) then
                continue
            end
            local ok = true
            for _, term in entry.with do
                if not world:has(e, term) then
                    ok = false
                    break
                end
            end
            if ok then
                for _, term in entry.without do
                    if world:has(e, term) then
                        ok = false
                        break
                    end
                end
            end
            local either = entry.either
            if ok and either then
                ok = world:has(e, either[1]) or world:has(e, either[2])
            end
            if ok and not entry.disabled_named and world:has(e, ecs.Disabled) then
                ok = false
            end
            if ok then
                table.insert(list, e)
                local row: { any } = {}
                for i, term in entry.returned do
                    row[i] = value_of(e, term)
                end
                values[e] = row
            end
        end
        table.sort(list, function(a: any, b: any): boolean
            return ecs.ECS_ID(a) < ecs.ECS_ID(b)
        end)
        return list, values
    end

    local function check(round: number, entry: Entry)
        local want, values = expected(entry)
        local q = if entry.inline then (entry.inline :: () -> any)() else entry.q
        local style = rand(4)
        local got: { any } = {}
        local got_values: { [any]: { any } } = {}
        local function record(e: any, ...: any)
            table.insert(got, e)
            got_values[e] = { ... }
        end
        if style == 1 then
            for e, a, b, c in q do
                record(e, a, b, c)
            end
        elseif style == 2 then
            q:each(function(e: any, a: any, b: any, c: any)
                record(e, a, b, c)
            end)
        elseif style == 3 then
            local n = 0
            for _ in q do
                n += 1
                if n >= 2 then
                    break -- a loop left early, then a full one
                end
            end
            for e, a, b, c in q do
                record(e, a, b, c)
            end
        else
            local first = true
            for e, a, b, c in q do
                record(e, a, b, c)
                if first then
                    first = false
                    local inner = 0
                    for _ in q do
                        inner += 1
                    end
                    if inner ~= #want then
                        fail(`round {round} {entry.label}: a nested loop returns {inner}, expected {#want}`)
                    end
                end
            end
        end
        if #got ~= #want then
            fail(`round {round} {entry.label} (style {style}): {#got} matches, expected {#want}`)
            return
        end
        for i, e in got do
            if e ~= want[i] then
                fail(`round {round} {entry.label} (style {style}): match {i} is {e}, expected {want[i]}`)
                return
            end
            for k = 1, #entry.returned do
                if got_values[e][k] ~= values[e][k] then
                    fail(`round {round} {entry.label}: value {k} of {e} is {got_values[e][k]}, expected {values[e][k]}`)
                    return
                end
            end
        end
        if q:count() ~= #want then
            fail(`round {round} {entry.label}: count {q:count()}, expected {#want}`)
        end
        for _, e in entities do
            if q:has(e) ~= (values[e] ~= nil) then
                fail(`round {round} {entry.label}: has {e} is {q:has(e)}`)
                return
            end
        end
    end

    local function change(e: any)
        local roll = rand(20)
        if roll <= 4 then
            world:set(e, comps[rand(#comps)], rand(100))
        elseif roll <= 6 then
            world:remove(e, comps[rand(#comps)])
        elseif roll <= 8 then
            world:add(e, tags[rand(#tags)])
        elseif roll <= 10 then
            world:remove(e, tags[rand(#tags)])
        elseif roll == 11 then
            world:set(e, pair(R, targets[rand(#targets)]), rand(100))
        elseif roll == 12 then
            world:remove(e, pair(R, targets[rand(#targets)]))
        elseif roll == 13 then
            world:add(e, pair(S, targets[rand(#targets)]))
        elseif roll == 14 then
            world:remove(e, pair(S, W))
        elseif roll == 15 then
            world:add(e, pair(X, targets[rand(#targets)])) -- exclusive: may replace a pair
        elseif roll == 16 then
            local parent = entities[rand(#entities)]
            if parent ~= e and world:contains(parent) then
                world:add(e, pair(ecs.ChildOf, parent))
            end
        elseif roll == 17 then
            if world:has(e, ecs.Disabled) then
                world:remove(e, ecs.Disabled)
            else
                world:add(e, ecs.Disabled)
            end
        elseif roll == 18 then
            world:delete(e) -- ChildOf children go too
        elseif roll == 19 then
            world:clear(e)
        else
            world:remove(e, pair(W, targets[rand(#targets)]))
        end
    end

    for round = 1, rounds do
        -- a burst of changes: a few, or many (the match lists are built again)
        for _ = 1, if rand(4) == 1 then rand(400) else rand(8) do
            if #entities == 0 or rand(30) == 1 then
                spawn_burst()
            else
                local e = entities[rand(#entities)]
                if world:contains(e) then
                    change(e)
                end
            end
        end
        if rand(6) == 1 then
            local entry = entries[rand(#entries)]
            local roll = rand(4)
            if roll == 1 then
                entry.q:add_all(tags[rand(#tags)])
            elseif roll == 2 then
                entry.q:remove_all(tags[rand(#tags)])
            elseif roll == 3 then
                entry.q:set_all(comps[rand(#comps)], round)
            else
                world:remove_all(tags[rand(#tags)])
            end
        end
        if rand(15) == 1 then
            -- a target goes: its pairs go from their entities
            local k = rand(#targets)
            world:delete(targets[k])
            targets[k] = world:entity()
        end
        for i = #entities, 1, -1 do
            if not world:contains(entities[i]) then
                table.remove(entities, i)
            end
        end
        for _, entry in entries do
            check(round, entry)
        end
        if #failures > 0 then
            break
        end
    end
    return failures
end

local runs: { { any } } = if args[1]
    then { { tonumber(args[1]) :: number, tonumber(args[2]) or 60, table.find(args, "debug") ~= nil } }
    else { { 1, 60, false }, { 2, 60, false }, { 3, 40, true } }
for _, run_args in runs do
    local failures = run(run_args[1], run_args[2], run_args[3])
    if #failures > 0 then
        for _, message in failures do
            print("  " .. message)
        end
        error(`queries fuzz: {#failures} mismatches (seed {run_args[1]})`)
    end
end
print(`queries fuzz: ok ({#runs} worlds)`)
