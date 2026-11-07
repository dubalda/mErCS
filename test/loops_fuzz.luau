--!strict
--# selene: allow(empty_loop) -- a nested loop runs for its effect on the outer one
--[[
    Randomized test of loops that change the world: queries over scattered matches and over
    blocks of adjacent entities that have every component and tag (runs of full words), cached
    and written inline, looped with for-in and each; inside the loop the current entity is
    changed or deleted, other entities (often a few places ahead of the current one) are
    changed, deleted or created (a new one may take a slot ahead of the loop), and the same
    query is looped again, nested. What the running loop sees of the changes of other entities
    is not specified, but every loop ends, returns only entity ids (never a free-slot mark), only
    entities that matched at the start or that the loop touched or created, none of them twice,
    and every entity that matched when the loop started and that nothing touched during the loop
    exactly once.

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
    -- the entities made during the current loop, empty ones included
    local born: { [any]: boolean } = {}
    local function spawn()
        local e = world:entity()
        born[e] = true
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
                born[world:entity()] = true -- empty entities between: scattered matches
            end
        end
    end
    -- adjacent entities with every component and tag: runs of full words in every query
    local function spawn_block()
        for _ = 1, 32 + rand(64) do
            local e = world:entity()
            born[e] = true
            table.insert(entities, e)
            for _, c in comps do
                world:set(e, c, rand(100))
            end
            for _, t in tags do
                world:add(e, t)
            end
        end
    end
    for k = 1, 600 do
        spawn()
        if k % 100 == 0 then
            spawn_block()
        end
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
        local kind = rand(3)
        local start: { [any]: boolean } = {}
        local start_count = 0
        local q: any
        local excluded: any = nil
        if kind == 3 then
            -- a shape of its own (a new excluded id), looped once: a pass over the bitsets; the
            -- matches of the start are found without a query, which would make the shape shared
            local comp, tag = comps[rand(3)], tags[rand(2)]
            excluded = world:entity()
            q = world:query(comp):with(tag):without(excluded)
            for _, e in entities do
                if world:contains(e) and world:has(e, comp) and world:has(e, tag) then
                    start[e] = true
                    start_count += 1
                end
            end
        else
            q = if kind == 1 then cached[rand(#cached)] else world:query(comps[rand(3)]):with(tags[rand(2)])
            for e in q do
                start[e] = true
                start_count += 1
            end
        end
        local position: { [any]: number } = {}
        for i, e in entities do
            position[e] = i
        end
        table.clear(born)
        local touched: { [any]: boolean } = {}
        local seen: { [any]: number } = {}
        local visits = 0
        local function visit(e: any)
            visits += 1
            if visits > 2 * start_count + 1000 then
                error(`loops fuzz: loop {round} does not end ({visits} entities returned, {start_count} matched)`)
            end
            if type(e) ~= "number" or e <= 0 then
                fail(`loop {round}: {e} returned, not an entity`)
                return
            end
            if not (start[e] or touched[e] or born[e]) then
                fail(`loop {round}: {e} returned, it neither matched at the start nor was touched or made`)
            end
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
                -- half of the time an entity a few places ahead: the same word or run, often
                local at = position[e]
                local other = if at and rand(2) == 1
                    then entities[math.min(#entities, at + rand(40))]
                    else entities[rand(#entities)]
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
        if excluded ~= nil then
            world:delete(excluded) -- its shape goes with it
        end
        for i = #entities, 1, -1 do
            if not world:contains(entities[i]) then
                table.remove(entities, i)
            end
        end
        while #entities < 400 do
            spawn()
            if rand(50) == 1 then
                spawn_block()
            end
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
