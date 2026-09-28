--!strict
--!optimize 2
--!native
--# selene: allow(empty_loop) -- the loops iterate for their cost only
--[[
    Query cases where an archetype ECS is expected to be at its best: entity ids scattered by
    churn, a tag of the query toggled between loops, four values read per match, a (*, T)
    wildcard over pairs that change, a query that almost never matches.

    The jecs part runs plain for-in loops over cached queries. The mErCS part builds the same
    worlds and runs the same loops with query:each, which fully replaces these for-in loops
    (none of them breaks early): for the current library and, when tools/previous.sh has
    extracted it, for the previous release.

    Run from the repository root (native code is the Roblox server, the interpreter the client);
    each BENCH line is the time of one pass of the loop and the memory it allocates:
        luau -O2 --codegen bench/query_cases.luau
        luau -O2 bench/query_cases.luau

    bench/run.luau has the same cases in its "query cases" group, measured as the minimum of
    several runs, and bench/visual/query_*.bench.luau for the Benchmarker plugin in Studio.
]]

local testkit = require("@testkit")
local BENCH, START = testkit.benchmark()
local function TITLE(title: string)
    print()
    print(testkit.color.white(title))
end

local jecs = require("@jecs")
local mercs = require("@lib")
local previous = require("./previous")
local versions = require("./versions")

do
    TITLE(testkit.color.white_underline(`{versions.jecs}, for-in`))
    do
        TITLE("scattered after recycling")
        local ecs = jecs.world() :: jecs.World

        local function view_bench(world: jecs.World, A: jecs.Id, B: jecs.Id, C: jecs.Id, D: jecs.Id)
            local query = world:query(A, B, C, D):cached()
            BENCH("4 component", function()
                for _ = 1, START(50) do
                    for _ in query do
                    end
                end
            end)
        end

        local D1 = ecs:component()
        local D2 = ecs:component()
        local D3 = ecs:component()
        local D4 = ecs:component()
        local D5 = ecs:component()
        local D6 = ecs:component()
        local D7 = ecs:component()
        local D8 = ecs:component()
        local components = { D1, D2, D3, D4, D5, D6, D7, D8 }

        math.randomseed(42)
        local function flip()
            return math.random() >= 0.5
        end

        local function spawn()
            local entity = ecs:entity()
            for i, component in components do
                if flip() then
                    ecs:set(entity, component, i)
                end
            end
            return entity
        end

        local entities = {}
        for i = 1, 50000 do
            entities[i] = spawn()
        end
        for _ = 1, 100000 do
            local i = math.random(#entities)
            ecs:delete(entities[i])
            entities[i] = spawn()
        end

        view_bench(ecs, D1, D2, D3, D4)
    end

    do
        TITLE("churn on a queried tag")
        local ecs = jecs.world() :: jecs.World

        local function view_bench(world: jecs.World, A: jecs.Id, B: jecs.Id, T: jecs.Id, movers: { jecs.Entity })
            local query = world:query(A, B):without(T):cached()
            local function toggle()
                local entity = movers[math.random(#movers)]
                if world:has(entity, T) then
                    world:remove(entity, T)
                else
                    world:add(entity, T)
                end
            end
            BENCH("toggle 1", function()
                for _ = 1, START(200) do
                    toggle()
                    for _ in query do
                    end
                end
            end)
            BENCH("toggle 100", function()
                for _ = 1, START(200) do
                    for _ = 1, 100 do
                        toggle()
                    end
                    for _ in query do
                    end
                end
            end)
        end

        local Position = ecs:component()
        local Velocity = ecs:component()
        local Stunned = ecs:entity()

        math.randomseed(42)
        local movers = {}
        for i = 1, 70000 do
            local entity = ecs:entity()
            ecs:set(entity, Position, i)
            if i % 7 == 0 then
                ecs:set(entity, Velocity, 1)
                table.insert(movers, entity)
            end
        end

        view_bench(ecs, Position, Velocity, Stunned, movers)
    end

    do
        TITLE("read 4 components")
        local ecs = jecs.world() :: jecs.World

        local function view_bench(world: jecs.World, A: jecs.Id, B: jecs.Id, C: jecs.Id, D: jecs.Id)
            local query = world:query(A, B, C, D):cached()
            BENCH("4 component", function()
                for _ = 1, START(50) do
                    local acc = 0
                    for _, a, b, c, d in query do
                        acc += a + b + c + d
                    end
                end
            end)
        end

        local A = ecs:component()
        local B = ecs:component()
        local C = ecs:component()
        local D = ecs:component()
        local Tag = ecs:entity()

        math.randomseed(42)
        local function flip()
            return math.random() >= 0.5
        end

        for i = 1, 80000 do
            local entity = ecs:entity()
            ecs:set(entity, A, i)
            ecs:set(entity, B, i)
            ecs:set(entity, C, i)
            if flip() then
                ecs:set(entity, D, i)
            end
            if flip() then
                ecs:add(entity, Tag)
            end
        end

        view_bench(ecs, A, B, C, D)
    end

    do
        TITLE("wildcard target with churn")
        local ecs = jecs.world() :: jecs.World

        local function view_bench(
            world: jecs.World,
            Health: jecs.Id,
            Target: jecs.Entity,
            relations: { jecs.Id },
            entities: { jecs.Entity }
        )
            local query = world:query(Health, jecs.pair(jecs.Wildcard, Target)):cached()
            BENCH("toggle 1 pair", function()
                for _ = 1, START(50) do
                    local entity = entities[math.random(#entities)]
                    local relation = relations[math.random(#relations)]
                    if world:has(entity, relation) then
                        world:remove(entity, relation)
                    else
                        world:add(entity, relation)
                    end
                    for _ in query do
                    end
                end
            end)
        end

        local Health = ecs:component()
        local Target = ecs:entity()

        math.randomseed(42)
        local relations = {}
        for i = 1, 64 do
            relations[i] = jecs.pair(ecs:entity(), Target)
        end

        local entities = {}
        for i = 1, 20000 do
            local entity = ecs:entity()
            ecs:set(entity, Health, 100)
            ecs:add(entity, relations[i % 64 + 1])
            entities[i] = entity
        end

        view_bench(ecs, Health, Target, relations, entities)
    end

    do
        TITLE("usually empty")
        local ecs = jecs.world() :: jecs.World

        local function view_bench(world: jecs.World, A: jecs.Id, B: jecs.Id)
            local query = world:query(A, B):cached()
            BENCH("2 component", function()
                for _ = 1, START(1000) do
                    for _ in query do
                    end
                end
            end)
        end

        local Stunned = ecs:component()
        local Invulnerable = ecs:component()

        math.randomseed(42)
        local function flip()
            return math.random() >= 0.5
        end

        for _ = 1, 100000 do
            local entity = ecs:entity()
            if flip() then
                ecs:set(entity, Stunned, true)
            else
                ecs:set(entity, Invulnerable, true)
            end
        end

        view_bench(ecs, Stunned, Invulnerable)
    end
end

-- The same worlds and loops for mErCS; the loops go through query:each. The types are those of
-- the current library; `lib` may be the previous release.
local function visit() end

local function library_cases(lib: any, label: string)
    TITLE(testkit.color.white_underline(`{label}, each`))
    do
        TITLE("scattered after recycling")
        local ecs = lib.world()

        local function view_bench(world: mercs.World, A: mercs.Id, B: mercs.Id, C: mercs.Id, D: mercs.Id)
            local query = world:query(A, B, C, D):cached()
            BENCH("4 component", function()
                for _ = 1, START(50) do
                    query:each(visit)
                end
            end)
        end

        local D1 = ecs:component()
        local D2 = ecs:component()
        local D3 = ecs:component()
        local D4 = ecs:component()
        local D5 = ecs:component()
        local D6 = ecs:component()
        local D7 = ecs:component()
        local D8 = ecs:component()
        local components = { D1, D2, D3, D4, D5, D6, D7, D8 }

        math.randomseed(42)
        local function flip()
            return math.random() >= 0.5
        end

        local function spawn()
            local entity = ecs:entity()
            for i, component in components do
                if flip() then
                    ecs:set(entity, component, i)
                end
            end
            return entity
        end

        local entities = {}
        for i = 1, 50000 do
            entities[i] = spawn()
        end
        for _ = 1, 100000 do
            local i = math.random(#entities)
            ecs:delete(entities[i])
            entities[i] = spawn()
        end

        view_bench(ecs, D1, D2, D3, D4)
    end

    do
        TITLE("churn on a queried tag")
        local ecs = lib.world()

        local function view_bench(world: mercs.World, A: mercs.Id, B: mercs.Id, T: mercs.Id, movers: { mercs.Entity })
            local query = world:query(A, B):without(T):cached()
            local function toggle()
                local entity = movers[math.random(#movers)]
                if world:has(entity, T) then
                    world:remove(entity, T)
                else
                    world:add(entity, T)
                end
            end
            BENCH("toggle 1", function()
                for _ = 1, START(200) do
                    toggle()
                    query:each(visit)
                end
            end)
            BENCH("toggle 100", function()
                for _ = 1, START(200) do
                    for _ = 1, 100 do
                        toggle()
                    end
                    query:each(visit)
                end
            end)
        end

        local Position = ecs:component()
        local Velocity = ecs:component()
        local Stunned = ecs:entity()

        math.randomseed(42)
        local movers = {}
        for i = 1, 70000 do
            local entity = ecs:entity()
            ecs:set(entity, Position, i)
            if i % 7 == 0 then
                ecs:set(entity, Velocity, 1)
                table.insert(movers, entity)
            end
        end

        view_bench(ecs, Position, Velocity, Stunned, movers)
    end

    do
        TITLE("read 4 components")
        local ecs = lib.world()

        local function view_bench(world: mercs.World, A: mercs.Id, B: mercs.Id, C: mercs.Id, D: mercs.Id)
            local query = world:query(A, B, C, D):cached()
            local acc = 0
            local function read(_: any, a: number, b: number, c: number, d: number)
                acc += a + b + c + d
            end
            BENCH("4 component", function()
                for _ = 1, START(50) do
                    acc = 0
                    query:each(read)
                end
            end)
        end

        local A = ecs:component()
        local B = ecs:component()
        local C = ecs:component()
        local D = ecs:component()
        local Tag = ecs:entity()

        math.randomseed(42)
        local function flip()
            return math.random() >= 0.5
        end

        for i = 1, 80000 do
            local entity = ecs:entity()
            ecs:set(entity, A, i)
            ecs:set(entity, B, i)
            ecs:set(entity, C, i)
            if flip() then
                ecs:set(entity, D, i)
            end
            if flip() then
                ecs:add(entity, Tag)
            end
        end

        view_bench(ecs, A, B, C, D)
    end

    do
        TITLE("wildcard target with churn")
        local ecs = lib.world()

        local function view_bench(
            world: mercs.World,
            Health: mercs.Id,
            Target: mercs.Entity,
            relations: { mercs.Id },
            entities: { mercs.Entity }
        )
            local wildcard = lib.pair(lib.Wildcard, Target) :: mercs.Id
            local query = world:query(Health, wildcard):cached()
            BENCH("toggle 1 pair", function()
                for _ = 1, START(50) do
                    local entity = entities[math.random(#entities)]
                    local relation = relations[math.random(#relations)]
                    if world:has(entity, relation) then
                        world:remove(entity, relation)
                    else
                        world:add(entity, relation)
                    end
                    query:each(visit)
                end
            end)
        end

        local Health = ecs:component()
        local Target = ecs:entity()

        math.randomseed(42)
        local relations = {}
        for i = 1, 64 do
            relations[i] = lib.pair(ecs:entity(), Target)
        end

        local entities = {}
        for i = 1, 20000 do
            local entity = ecs:entity()
            ecs:set(entity, Health, 100)
            ecs:add(entity, relations[i % 64 + 1])
            entities[i] = entity
        end

        view_bench(ecs, Health, Target, relations, entities)
    end

    do
        TITLE("usually empty")
        local ecs = lib.world()

        local function view_bench(world: mercs.World, A: mercs.Id, B: mercs.Id)
            local query = world:query(A, B):cached()
            BENCH("2 component", function()
                for _ = 1, START(1000) do
                    query:each(visit)
                end
            end)
        end

        local Stunned = ecs:component()
        local Invulnerable = ecs:component()

        math.randomseed(42)
        local function flip()
            return math.random() >= 0.5
        end

        for _ = 1, 100000 do
            local entity = ecs:entity()
            if flip() then
                ecs:set(entity, Stunned, true)
            else
                ecs:set(entity, Invulnerable, true)
            end
        end

        view_bench(ecs, Stunned, Invulnerable)
    end
end

library_cases(mercs, versions.library)
if previous then
    library_cases(previous.ecs, `mErCS {previous.version}`)
end
