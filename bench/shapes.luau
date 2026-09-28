--!strict
--# selene: allow(empty_loop) -- benchmark loops iterate for their cost only
--!optimize 2
--[[
    Query shapes of the benchmark matrix (bench/scenarios.luau adds them):

    - "query cases": five cases where an archetype ECS is expected to be at its best (the
      same as bench/query_cases.luau): entity ids scattered by churn, a tag of the query
      toggled between loops, four values read per match, a (*, T) wildcard over changing
      pairs, a query that almost never matches. The worlds have their full size at
      n = 131072 and shrink with a smaller n (the Roblox Studio check).
    - "sparse world": creatures scattered among many child entities (500 per creature at
      n = 131072: the skills of NPCs), the queries of a game over them after the changes it
      makes between two frames; the rows marked "pool" create the creatures from a slot pool
      (world:pool) where the implementation has one.

    A loop over matches is the for-in loop of jecs, or query:each where the implementation has
    it (it replaces the for-in loop fully when the loop does not break early). Every row times
    one pass of its loop ("pass"), with the changes it makes before it.

    Usage (from bench/scenarios.luau):
        require("./shapes")(add, n)
]]

local harness = require("./harness")

type Impl = harness.Impl
type Scenario = harness.Scenario

local function visit() end

-- One pass over the matches of a query: query:each where the implementation has it.
local function pass(impl: Impl, query: any)
    if impl.features.each then
        query:each(visit)
    else
        for _ in query do
        end
    end
end

local function flip(): boolean
    return math.random() >= 0.5
end

return function(add: (Scenario) -> (), n: number)
    local scale = n / 131072
    local function sized(count: number): number
        return math.max(1, math.floor(count * scale))
    end

    ---------------------------------------------------------------------------
    -- query cases
    ---------------------------------------------------------------------------
    add({
        group = "query cases",
        name = "scattered after recycling (4 of 8)",
        ops = 50,
        unit = "pass",
        reuse = true,
        setup = function(impl)
            local world = impl.ecs.world()
            local components = {}
            for i = 1, 8 do
                components[i] = impl.component(world)
            end
            math.randomseed(42)
            local function spawn(): any
                local entity = world:entity()
                for i, component in components do
                    if flip() then
                        world:set(entity, component, i)
                    end
                end
                return entity
            end
            local list = {}
            for i = 1, sized(50000) do
                list[i] = spawn()
            end
            for _ = 1, sized(100000) do
                local i = math.random(#list)
                world:delete(list[i])
                list[i] = spawn()
            end
            return { query = world:query(components[1], components[2], components[3], components[4]):cached() }
        end,
        run = function(impl, state)
            for _ = 1, 50 do
                pass(impl, state.query)
            end
        end,
    })

    local function churn_world(impl: Impl)
        local world = impl.ecs.world()
        local Position, Velocity = impl.component(world), impl.component(world)
        local Stunned = world:entity()
        math.randomseed(42)
        local movers = {}
        for i = 1, sized(70000) do
            local entity = world:entity()
            world:set(entity, Position, i)
            if i % 7 == 0 then
                world:set(entity, Velocity, 1)
                table.insert(movers, entity)
            end
        end
        local function toggle()
            local entity = movers[math.random(#movers)]
            if world:has(entity, Stunned) then
                world:remove(entity, Stunned)
            else
                world:add(entity, Stunned)
            end
        end
        return { query = world:query(Position, Velocity):without(Stunned):cached(), toggle = toggle }
    end

    for _, toggles in { 1, 100 } do
        add({
            group = "query cases",
            name = `churn on a queried tag, toggle {toggles}`,
            ops = 200,
            unit = "pass",
            reuse = true,
            setup = churn_world,
            run = function(impl, state)
                local toggle = state.toggle
                for _ = 1, 200 do
                    for _ = 1, toggles do
                        toggle()
                    end
                    pass(impl, state.query)
                end
            end,
        })
    end

    add({
        group = "query cases",
        name = "read 4 components",
        ops = 50,
        unit = "pass",
        reuse = true,
        setup = function(impl)
            local world = impl.ecs.world()
            local A, B, C, D =
                impl.component(world), impl.component(world), impl.component(world), impl.component(world)
            local Tag = world:entity()
            math.randomseed(42)
            for i = 1, sized(80000) do
                local entity = world:entity()
                world:set(entity, A, i)
                world:set(entity, B, i)
                world:set(entity, C, i)
                if flip() then
                    world:set(entity, D, i)
                end
                if flip() then
                    world:add(entity, Tag)
                end
            end
            return { query = world:query(A, B, C, D):cached(), acc = 0 }
        end,
        run = function(impl, state)
            local query = state.query
            if impl.features.each then
                local acc = 0
                local function read(_: any, a: number, b: number, c: number, d: number)
                    acc += a + b + c + d
                end
                for _ = 1, 50 do
                    acc = 0
                    query:each(read)
                end
                state.acc = acc
            else
                for _ = 1, 50 do
                    local acc = 0
                    for _, a, b, c, d in query do
                        acc += a + b + c + d
                    end
                    state.acc = acc
                end
            end
        end,
    })

    add({
        group = "query cases",
        name = "wildcard (*, T), toggle 1 pair",
        ops = 50,
        unit = "pass",
        reuse = true,
        requires = { "pairs" },
        setup = function(impl)
            local world = impl.ecs.world()
            local ecs = impl.ecs
            local Health = impl.component(world)
            local Target = world:entity()
            math.randomseed(42)
            local relations = {}
            for i = 1, 64 do
                relations[i] = ecs.pair(world:entity(), Target)
            end
            local list = {}
            for i = 1, sized(20000) do
                local entity = world:entity()
                world:set(entity, Health, 100)
                world:add(entity, relations[i % 64 + 1])
                list[i] = entity
            end
            local query = world:query(Health, ecs.pair(ecs.Wildcard, Target)):cached()
            return { world = world, query = query, list = list, relations = relations }
        end,
        run = function(impl, state)
            local world, list, relations = state.world, state.list, state.relations
            for _ = 1, 50 do
                local entity = list[math.random(#list)]
                local relation = relations[math.random(#relations)]
                if world:has(entity, relation) then
                    world:remove(entity, relation)
                else
                    world:add(entity, relation)
                end
                pass(impl, state.query)
            end
        end,
    })

    add({
        group = "query cases",
        name = "usually empty",
        ops = 1000,
        unit = "pass",
        reuse = true,
        setup = function(impl)
            local world = impl.ecs.world()
            local Stunned, Invulnerable = impl.component(world), impl.component(world)
            math.randomseed(42)
            for _ = 1, sized(100000) do
                local entity = world:entity()
                if flip() then
                    world:set(entity, Stunned, true)
                else
                    world:set(entity, Invulnerable, true)
                end
            end
            return { query = world:query(Stunned, Invulnerable):cached() }
        end,
        run = function(impl, state)
            for _ = 1, 1000 do
                pass(impl, state.query)
            end
        end,
    })

    ---------------------------------------------------------------------------
    -- sparse world: 700 creatures (200 alive, 500 dead), each followed by its children
    ---------------------------------------------------------------------------
    local CREATURES, DEAD = 200, 500
    local children = sized(500)

    local function sparse_world(impl: Impl, pooled: boolean)
        local world: any = impl.ecs.world()
        local s: any = { world = world }
        s.Model = impl.component(world)
        s.Creature = world:entity()
        s.Dead = world:entity()
        s.Run = world:entity()
        s.Near = world:entity() -- nobody has it
        s.Hit = world:entity() -- a tag for one frame
        s.Caster = impl.component(world)
        s.Power = impl.component(world)
        s.Cast = world:entity()
        s.Ready = world:entity()
        s.alive_list = {}
        s.skills = {}
        -- creatures come from a slot pool where the implementation has one (world:pool)
        local function new_creature(): any
            return world:entity()
        end
        local has_pool: boolean = world.pool ~= nil
        if pooled and has_pool then
            local pool: any = world:pool()
            new_creature = function(): any
                return pool:entity()
            end
        end
        math.randomseed(7)
        for c = 1, CREATURES + DEAD do
            local creature = new_creature()
            world:set(creature, s.Model, creature)
            world:add(creature, s.Creature)
            if c > CREATURES then
                world:add(creature, s.Dead)
            else
                table.insert(s.alive_list, creature)
                if math.random() < 0.3 then
                    world:add(creature, s.Run)
                end
            end
            for _ = 1, children do
                local skill = world:entity()
                world:set(skill, s.Caster, creature)
                world:set(skill, s.Power, 1)
                world:add(skill, s.Ready)
                table.insert(s.skills, skill)
            end
        end
        -- some skills are being cast
        for i = 1, 400 do
            local skill = s.skills[(i * 7919) % #s.skills + 1]
            world:remove(skill, s.Ready)
            world:add(skill, s.Cast)
        end
        s.alive = world:query(s.Model):with(s.Creature):without(s.Dead):cached()
        s.running = world:query(s.Model):with(s.Creature, s.Run):without(s.Dead):cached()
        s.near = world:query(s.Model):with(s.Creature, s.Near):cached()
        s.hit = world:query(s.Model):with(s.Hit):cached()
        s.all = world:query(s.Model):cached()
        s.casting = {}
        for i = 1, 10 do
            s.casting[i] = world:query(s.Caster):with(s.Cast):cached()
        end
        return s
    end

    -- one world per implementation and variant, shared by the rows of the group
    local worlds: { [any]: any } = {}
    local function shared(pooled: boolean): (impl: Impl) -> any
        return function(impl: Impl): any
            local key = `{impl.name}{pooled}`
            local s = worlds[key]
            if s == nil then
                s = sparse_world(impl, pooled)
                worlds[key] = s
            end
            return s
        end
    end

    type Row = { name: string, ops: number, run: (impl: Impl, s: any) -> () }
    local rows: { Row } = {
        {
            name = "alive creatures, stable",
            ops = 200,
            run = function(impl, s)
                for _ = 1, 200 do
                    pass(impl, s.alive)
                end
            end,
        },
        {
            name = "alive creatures, Dead added and removed",
            ops = 200,
            run = function(impl, s)
                local world, list = s.world, s.alive_list
                for _ = 1, 200 do
                    local creature = list[math.random(#list)]
                    world:add(creature, s.Dead)
                    world:remove(creature, s.Dead)
                    pass(impl, s.alive)
                end
            end,
        },
        {
            name = "running creatures, Run toggled",
            ops = 200,
            run = function(impl, s)
                local world, list = s.world, s.alive_list
                for _ = 1, 200 do
                    local creature = list[math.random(#list)]
                    if world:has(creature, s.Run) then
                        world:remove(creature, s.Run)
                    else
                        world:add(creature, s.Run)
                    end
                    pass(impl, s.running)
                end
            end,
        },
        {
            name = "a tag on one creature: add, pass, remove, pass",
            ops = 200,
            run = function(impl, s)
                local world, list = s.world, s.alive_list
                for _ = 1, 200 do
                    local creature = list[math.random(#list)]
                    world:add(creature, s.Hit)
                    pass(impl, s.hit)
                    world:remove(creature, s.Hit)
                    pass(impl, s.hit)
                end
            end,
        },
        {
            name = "a tag nobody has",
            ops = 1000,
            run = function(impl, s)
                for _ = 1, 1000 do
                    pass(impl, s.near)
                end
            end,
        },
        {
            name = "all with Model",
            ops = 200,
            run = function(impl, s)
                for _ = 1, 200 do
                    pass(impl, s.all)
                end
            end,
        },
        {
            name = "10 passes over casting skills, one changed",
            ops = 50,
            run = function(impl, s)
                local world, skills = s.world, s.skills
                for _ = 1, 50 do
                    local skill = skills[math.random(#skills)]
                    if world:has(skill, s.Cast) then
                        world:remove(skill, s.Cast)
                        world:add(skill, s.Ready)
                    else
                        world:remove(skill, s.Ready)
                        world:add(skill, s.Cast)
                    end
                    for _, query in s.casting do
                        pass(impl, query)
                    end
                end
            end,
        },
    }

    for _, pooled in { false, true } do
        for index, row in rows do
            add({
                group = "sparse world",
                name = if pooled then `{row.name} (pool)` else row.name,
                ops = row.ops,
                unit = "pass",
                reuse = true,
                setup = shared(pooled),
                run = row.run,
                release = if index == #rows
                    then function(impl: Impl)
                        worlds[`{impl.name}{pooled}`] = nil
                    end
                    else nil,
            })
        end
    end
end
