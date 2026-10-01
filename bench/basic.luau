--!strict
--# selene: allow(empty_loop) -- the query loops iterate for their cost only
--!optimize 2
--[[
    The four basic benchmarks that jecs ships with, for mErCS, jecs and ecr, in the luau CLI:
    the work of the Benchmarker files of bench/visual/ (spawn, despawn, insertion, query).

    - spawn: 1000 entities with 4 components, in a fresh world per call;
    - despawn: delete 1000 entities with 4 components and a tag;
    - insertion: 8 components into 500 entities that have none, in a fresh world per call;
    - query: 10 passes of a 4-component query over 4096 entities with random subsets of 8
      components (the same layout in every library; a cached query, an ecr view made once).

    A case runs CALLS times (each spawn, despawn and insertion with a world prepared outside the
    timed part) and prints the median and the minimum time of a call, in microseconds:
        SAMPLE <tab> basic <tab> <case> <tab> µs per call <tab> <median> <tab> <min>

    Run from the repository root with one library per process: lib (this library), jecs or ecr
    (the Wally dev packages):
        luau -O2 --codegen bench/basic.luau -a lib
        luau -O2 bench/basic.luau -a ecr
]]

local name = tostring(({ ... })[1] or "lib")
local CALLS = 300

local clock = os.clock

local function median(list: { number }): number
    table.sort(list)
    return list[(#list + 1) // 2]
end

local function report(case: string, times: { number })
    local sorted = table.clone(times)
    local fastest = math.huge
    for _, t in sorted do
        fastest = math.min(fastest, t)
    end
    print(string.format("SAMPLE\tbasic\t%s\tµs per call\t%.17g\t%.17g", case, median(sorted) * 1e6, fastest * 1e6))
end

-- one case: prepare (not timed), then run, CALLS times
local function measure(case: string, prepare: () -> any, run: (any) -> ())
    local times: { number } = table.create(CALLS, 0)
    for i = 1, CALLS do
        local state = prepare()
        local t0 = clock()
        run(state)
        times[i] = clock() - t0
    end
    report(case, times)
end

-- the random layout of the query case, the same for every library
local function layout(): { { boolean } }
    local seed = 12345
    local rows: { { boolean } } = {}
    for e = 1, 4096 do
        local row: { boolean } = table.create(8, false)
        for i = 1, 8 do
            seed = seed * 16807 % 2147483647
            row[i] = seed % 2 == 0
        end
        rows[e] = row
    end
    return rows
end

if name == "lib" or name == "jecs" then
    -- the API of jecs, which this library follows
    local ecs: any = if name == "jecs" then require("@jecs") else require("../src")

    measure("spawn 1000 entities with 4 components", function(): any
        local world = ecs.world()
        return { world, world:component(), world:component(), world:component(), world:component() }
    end, function(s: any)
        local world, a, b, c, d = s[1], s[2], s[3], s[4], s[5]
        for i = 1, 1000 do
            local e = world:entity()
            world:set(e, a, i)
            world:set(e, b, i)
            world:set(e, c, i)
            world:set(e, d, i)
        end
    end)

    measure("despawn 1000 entities with 4 components and a tag", function(): any
        local world = ecs.world()
        local a, b, c, d = world:component(), world:component(), world:component(), world:component()
        local tag = world:entity()
        local list = table.create(1000)
        for i = 1, 1000 do
            local e = world:entity()
            world:set(e, a, i)
            world:set(e, b, i)
            world:set(e, c, i)
            world:set(e, d, i)
            world:add(e, tag)
            list[i] = e
        end
        return { world, list }
    end, function(s: any)
        local world = s[1]
        for _, e in s[2] do
            world:delete(e)
        end
    end)

    measure("insert 8 components into 500 entities", function(): any
        local world = ecs.world()
        local components = table.create(8)
        for i = 1, 8 do
            components[i] = world:component()
        end
        local list = table.create(500)
        for i = 1, 500 do
            list[i] = world:entity()
        end
        return { world, components, list }
    end, function(s: any)
        local world = s[1]
        local c1, c2, c3, c4, c5, c6, c7, c8 = table.unpack(s[2], 1, 8)
        for _, e in s[3] do
            world:set(e, c1, true)
            world:set(e, c2, true)
            world:set(e, c3, true)
            world:set(e, c4, true)
            world:set(e, c5, true)
            world:set(e, c6, true)
            world:set(e, c7, true)
            world:set(e, c8, true)
        end
    end)

    local world = ecs.world()
    local components = table.create(8)
    for i = 1, 8 do
        components[i] = world:component()
    end
    for _, row in layout() do
        local e = world:entity()
        for i = 1, 8 do
            if row[i] then
                world:set(e, components[i], { value = i })
            end
        end
    end
    local query = world:query(components[1], components[2], components[3], components[4]):cached()
    measure("10 passes of a 4-component query over 4096 entities", function(): any
        return query
    end, function(q: any)
        for _ = 1, 10 do
            for _entity, _a, _b, _c, _d in q do
            end
        end
    end)
    if name == "lib" then
        local function visit(_entity: any, _a: any, _b: any, _c: any, _d: any) end
        measure("the same with query:each", function(): any
            return query
        end, function(q: any)
            for _ = 1, 10 do
                q:each(visit)
            end
        end)
    end
else
    assert(name == "ecr", "the library is lib, jecs or ecr")
    local ecr: any = require("@ecr")
    -- the component types come before the registries that use them
    local A, B, C, D = ecr.component(), ecr.component(), ecr.component(), ecr.component()
    local Tag = ecr.tag()
    local Components = table.create(8)
    for i = 1, 8 do
        Components[i] = ecr.component()
    end

    measure("spawn 1000 entities with 4 components", function(): any
        return ecr.registry()
    end, function(registry: any)
        for i = 1, 1000 do
            local e = registry:create()
            registry:set(e, A, i)
            registry:set(e, B, i)
            registry:set(e, C, i)
            registry:set(e, D, i)
        end
    end)

    measure("despawn 1000 entities with 4 components and a tag", function(): any
        local registry = ecr.registry()
        local list = table.create(1000)
        for i = 1, 1000 do
            local e = registry:create()
            registry:set(e, A, i)
            registry:set(e, B, i)
            registry:set(e, C, i)
            registry:set(e, D, i)
            registry:add(e, Tag)
            list[i] = e
        end
        return { registry, list }
    end, function(s: any)
        local registry = s[1]
        for _, e in s[2] do
            registry:destroy(e)
        end
    end)

    measure("insert 8 components into 500 entities", function(): any
        local registry = ecr.registry()
        local list = table.create(500)
        for i = 1, 500 do
            list[i] = registry:create()
        end
        return { registry, list }
    end, function(s: any)
        local registry = s[1]
        local c1, c2, c3, c4, c5, c6, c7, c8 = table.unpack(Components, 1, 8)
        for _, e in s[2] do
            registry:set(e, c1, true)
            registry:set(e, c2, true)
            registry:set(e, c3, true)
            registry:set(e, c4, true)
            registry:set(e, c5, true)
            registry:set(e, c6, true)
            registry:set(e, c7, true)
            registry:set(e, c8, true)
        end
    end)

    local registry = ecr.registry()
    for _, row in layout() do
        local e = registry:create()
        for i = 1, 8 do
            if row[i] then
                registry:set(e, Components[i], { value = i })
            end
        end
    end
    local view = registry:view(Components[1], Components[2], Components[3], Components[4])
    measure("10 passes of a 4-component query over 4096 entities", function(): any
        return view
    end, function(v: any)
        for _ = 1, 10 do
            for _entity, _a, _b, _c, _d in v do
            end
        end
    end)
end
