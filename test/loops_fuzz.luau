--!strict
--# selene: allow(empty_loop) -- a nested loop runs for its effect on the outer one
--[[
    Randomized test of loops that change the world: queries over dense runs and scattered
    matches, cached and written inline, looped with for-in and each; inside the loop the current
    entity is changed or deleted, other entities are changed, deleted or created (a new one may
    take a slot ahead of the loop), and the same query is looped again, nested. What the
    running loop sees of the changes of other entities is not specified, but no entity may be
    returned twice by one loop, and every entity that matched when the loop started and that
    nothing touched during the loop must be returned exactly once.

    Run from the repository root (a seed and a number of loops; without them, two seeds):
        luau test/loops_fuzz.luau
        luau test/loops_fuzz.luau -a 42 1000
]]

local ecs = require("../src")

local args = { ... }

local function run(first_seed: number, rounds: number): { string }
    local seed = first_seed
    local function rand(n: number): number
        seed = seed * 16807 % 2147483647
        return seed % n + 1
    end

    local world = ecs.world()
    local comps: { any } = { world:component(), world:component(), world:component() }
    local tags: { any } = { world:entity(), world:entity() }
    local entities: { any } = {}
    local function spawn()
        local e = world:entity()
        table.insert(entities, e)
        for _, c in comps do
            if rand(3) > 1 then
                world:set(e, c, rand(100))
            end
        end
        if rand(2) == 1 then
            world:add(e, tags[rand(2)])
        end
        if rand(8) == 1 then
            for _ = 1, rand(80) do
                world:entity() -- empty entities between: scattered matches
            end
        end
    end
    for _ = 1, 600 do
        spawn()
    end

    local failures: { string } = {}
    local function fail(message: string)
        if #failures < 10 then
            table.insert(failures, message)
        end
    end

    local cached: { any } = {}
    for _ = 1, 6 do
        local q: any = world:query(comps[rand(3)])
        if rand(2) == 1 then
            q = q:with(tags[rand(2)])
        end
        if rand(3) == 1 then
            q = q:without(comps[rand(3)])
        end
        table.insert(cached, (q:cached()))
    end

    for round = 1, rounds do
        local q: any = if rand(2) == 1 then cached[rand(#cached)] else world:query(comps[rand(3)]):with(tags[rand(2)])
        local start: { [any]: boolean } = {}
        for e in q do
            start[e] = true
        end
        local touched: { [any]: boolean } = {}
        local seen: { [any]: number } = {}
        local function visit(e: any)
            seen[e] = (seen[e] or 0) + 1
            if seen[e] == 2 then
                fail(`loop {round}: {e} returned twice`)
            end
            local roll = rand(12)
            if roll == 1 then
                world:remove(e, comps[rand(3)])
                touched[e] = true
            elseif roll == 2 then
                world:delete(e)
                touched[e] = true
            elseif roll <= 5 and #entities > 0 then
                local other = entities[rand(#entities)]
                touched[other] = true
                local r = rand(4)
                if r == 1 then
                    world:delete(other)
                elseif r == 2 then
                    world:remove(other, comps[rand(3)])
                elseif r == 3 then
                    world:set(other, comps[rand(3)], rand(100))
                else
                    world:add(other, tags[rand(2)])
                end
            elseif roll == 6 then
                spawn()
                touched[entities[#entities]] = true
            elseif roll == 7 then
                for _ in q do -- a nested loop over the same query
                end
            end
        end
        if rand(2) == 1 then
            for e in q do
                visit(e)
            end
        else
            q:each(visit)
        end
        for e in start do
            if not touched[e] and seen[e] ~= 1 then
                fail(`loop {round}: {e} matched at the start, untouched, returned {seen[e] or 0} times`)
            end
        end
        for i = #entities, 1, -1 do
            if not world:contains(entities[i]) then
                table.remove(entities, i)
            end
        end
        while #entities < 400 do
            spawn()
        end
        if #failures > 0 then
            break
        end
    end
    return failures
end

local seeds: { number } = if args[1] then { tonumber(args[1]) :: number } else { 1, 2 }
local rounds = tonumber(args[2]) or 150
for _, seed in seeds do
    local failures = run(seed, rounds)
    if #failures > 0 then
        for _, message in failures do
            print("  " .. message)
        end
        error(`loops fuzz: {#failures} failures (seed {seed})`)
    end
end
print(`loops fuzz: ok ({#seeds} seeds, {rounds} loops)`)
