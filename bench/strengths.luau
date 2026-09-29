--!strict
--# selene: allow(empty_loop) -- benchmark loops iterate for their cost only
--!optimize 2
--[[
    The strengths of an archetype ECS (bench/scenarios.luau adds them as the group
    "jecs strengths"): ten cases where an archetype ECS is at its best, in time or in memory.
    An archetype keeps the entities of one set of ids together, a query caches the
    archetypes it matches, and a wildcard pair is resolved per archetype, so these cases cost
    jecs little, while a bitset ECS pays per entity, per changed slot or per page:

    1.  (*, T) values: a query returns the value of a pair with a given target (32 data
        relations point at T).
    2.  (R, *) values: a query returns the value of a data relation, whatever its target.
    3.  The memory of cached queries over entities scattered by churn (the match lists).
    4.  Queries over two large terms after more than a few changes of a term between two loops:
        a query that matches nothing, and five queries with about a hundred matches each.
    5.  Twenty small queries that share a tag toggled on thirty entities per frame.
    6.  Inline queries built per call: a query with a concrete pair per parent, and two
        queries per new caster with the caster as a term (time and memory).
    7.  world:each over 100 000 entities, and the children of a parent with 1000 children.
    8.  Entities of eight kinds created in turn: a pass over one kind (for-in and each), and the
        same with the kind created from a slot pool where the implementation has one.
    9.  Deleting entities that have 100 targets of a relation.
    10. The memory of eight components on one entity in 64 of a large world.

    A loop over matches is the for-in loop of jecs, or query:each where the implementation has
    it (as in bench/shapes.luau), except in the rows marked "for-in". The worlds have their
    full size at n = 131072 and shrink with a smaller n (the Roblox Studio check).

    Usage (from bench/scenarios.luau):
        require("./strengths")(add, n)
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

-- The sum of the second value of every match (the value of a wildcard pair).
local function sum_second(impl: Impl, query: any): number
    local acc = 0
    if impl.features.each then
        query:each(function(_: any, _: any, value: number)
            acc += value
        end)
    else
        for _, _, value in query do
            acc += value
        end
    end
    return acc
end

local function expect(actual: number, expected: number): string?
    if actual ~= expected then
        return `got {actual}, expected {expected}`
    end
    return nil
end

return function(add: (Scenario) -> (), n: number)
    local scale = n / 131072
    local function sized(count: number): number
        return math.max(1, math.floor(count * scale))
    end

    ---------------------------------------------------------------------------
    -- 1, 2: wildcard pairs that return values
    ---------------------------------------------------------------------------
    local wild_count = sized(20000)
    local function wild_sum(): number
        local total = 0
        for i = 1, wild_count do
            total += i
        end
        return total
    end

    add({
        group = "jecs strengths",
        name = "(*, T) values, 32 data relations",
        ops = 20,
        unit = "pass",
        reuse = true,
        requires = { "pairs" },
        setup = function(impl)
            local ecs = impl.ecs
            local world = ecs.world()
            local Health = impl.component(world)
            local T = world:entity()
            local relations = {}
            for i = 1, 32 do
                relations[i] = impl.component(world)
            end
            for i = 1, wild_count do
                local e = world:entity()
                world:set(e, Health, 100)
                world:set(e, ecs.pair(relations[i % 32 + 1], T), i)
            end
            return { query = world:query(Health, ecs.pair(ecs.Wildcard, T)):cached(), sum = 0 }
        end,
        run = function(impl, s)
            for _ = 1, 20 do
                s.sum = sum_second(impl, s.query)
            end
        end,
        check = function(_, s)
            return expect(s.sum, wild_sum())
        end,
    })

    add({
        group = "jecs strengths",
        name = "(R, *) values, 8 targets",
        ops = 20,
        unit = "pass",
        reuse = true,
        requires = { "pairs" },
        setup = function(impl)
            local ecs = impl.ecs
            local world = ecs.world()
            local Health = impl.component(world)
            local Damage = impl.component(world)
            local targets = {}
            for i = 1, 8 do
                targets[i] = world:entity()
            end
            for i = 1, wild_count do
                local e = world:entity()
                world:set(e, Health, 100)
                world:set(e, ecs.pair(Damage, targets[i % 8 + 1]), i)
            end
            return { query = world:query(Health, ecs.pair(Damage, ecs.Wildcard)):cached(), sum = 0 }
        end,
        run = function(impl, s)
            for _ = 1, 20 do
                s.sum = sum_second(impl, s.query)
            end
        end,
        check = function(_, s)
            return expect(s.sum, wild_sum())
        end,
    })

    ---------------------------------------------------------------------------
    -- 3: the memory of cached queries over scattered entities
    ---------------------------------------------------------------------------
    add({
        group = "jecs strengths",
        name = "15 cached queries over scattered entities",
        ops = 15,
        unit = "query",
        memory = true,
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
                    if math.random() >= 0.5 then
                        world:set(entity, component, i)
                    end
                end
                return entity
            end
            local list = {}
            for i = 1, sized(30000) do
                list[i] = spawn()
            end
            for _ = 1, sized(60000) do
                local i = math.random(#list)
                world:delete(list[i])
                list[i] = spawn()
            end
            return { world = world, components = components, queries = {} }
        end,
        run = function(impl, s)
            local world, c = s.world, s.components
            for i = 1, 5 do
                for j = i + 1, 6 do
                    local query = world:query(c[i], c[j]):cached()
                    pass(impl, query)
                    table.insert(s.queries, query)
                end
            end
        end,
    })

    ---------------------------------------------------------------------------
    -- 4: queries over two large terms after more than a few changes of a term
    ---------------------------------------------------------------------------
    add({
        group = "jecs strengths",
        name = "usually empty, 20 swaps per pass",
        ops = 200,
        unit = "pass",
        reuse = true,
        setup = function(impl)
            local world = impl.ecs.world()
            local Stunned, Invulnerable = impl.component(world), impl.component(world)
            math.randomseed(42)
            local list = {}
            for i = 1, sized(100000) do
                local e = world:entity()
                if math.random() >= 0.5 then
                    world:set(e, Stunned, true)
                else
                    world:set(e, Invulnerable, true)
                end
                list[i] = e
            end
            return {
                world = world,
                list = list,
                Stunned = Stunned,
                Invulnerable = Invulnerable,
                query = world:query(Stunned, Invulnerable):cached(),
            }
        end,
        run = function(impl, s)
            local world, list, Stunned, Invulnerable = s.world, s.list, s.Stunned, s.Invulnerable
            for _ = 1, 200 do
                -- 20 entities move from one state to the other: 40 changes of the terms
                for _ = 1, 20 do
                    local e = list[math.random(#list)]
                    if world:has(e, Stunned) then
                        world:remove(e, Stunned)
                        world:set(e, Invulnerable, true)
                    else
                        world:remove(e, Invulnerable)
                        world:set(e, Stunned, true)
                    end
                end
                pass(impl, s.query)
            end
        end,
    })

    add({
        group = "jecs strengths",
        name = "5 queries, 100 matches each, 40 toggles",
        ops = 200,
        unit = "frame",
        reuse = true,
        setup = function(impl)
            local world = impl.ecs.world()
            local Position = impl.component(world)
            local Visible, Enemy = world:entity(), world:entity()
            local groups = {}
            for k = 1, 5 do
                groups[k] = world:entity()
            end
            -- enemies are the even entities; the odd ones and one enemy in 83 are visible (about
            -- 100 visible enemies in each group)
            local odd = {}
            math.randomseed(3)
            for i = 1, sized(80000) do
                local e = world:entity()
                world:set(e, Position, i)
                world:add(e, groups[i % 5 + 1])
                if i % 2 == 0 then
                    world:add(e, Enemy)
                    if (i // 2) % 83 == 0 then
                        world:add(e, Visible)
                    end
                else
                    world:add(e, Visible)
                    table.insert(odd, e)
                end
            end
            local queries = {}
            for k = 1, 5 do
                queries[k] = world:query(Position):with(Visible, Enemy, groups[k]):cached()
            end
            return { world = world, Visible = Visible, odd = odd, queries = queries }
        end,
        run = function(impl, s)
            local world, Visible, odd = s.world, s.Visible, s.odd
            for _ = 1, 200 do
                -- visibility changes on 40 entities that are not enemies
                for _ = 1, 40 do
                    local e = odd[math.random(#odd)]
                    if world:has(e, Visible) then
                        world:remove(e, Visible)
                    else
                        world:add(e, Visible)
                    end
                end
                for _, query in s.queries do
                    pass(impl, query)
                end
            end
        end,
    })

    ---------------------------------------------------------------------------
    -- 5: twenty small queries that share a tag toggled on thirty entities per frame
    ---------------------------------------------------------------------------
    add({
        group = "jecs strengths",
        name = "20 small queries, a shared tag toggled on 30",
        ops = 200,
        unit = "frame",
        reuse = true,
        setup = function(impl)
            local world = impl.ecs.world()
            local Moving = world:entity()
            local Position = impl.component(world)
            local kinds = {}
            for k = 1, 20 do
                kinds[k] = world:entity()
            end
            local list = {}
            math.randomseed(9)
            for i = 1, sized(50000) do
                local e = world:entity()
                world:set(e, Position, i)
                if math.random() < 0.5 then
                    world:add(e, Moving)
                end
                if i % 500 == 0 then
                    world:add(e, kinds[(i // 500) % 20 + 1])
                end
                list[i] = e
            end
            local queries = {}
            for k = 1, 20 do
                queries[k] = world:query(Position):with(Moving, kinds[k]):cached()
            end
            return { world = world, Moving = Moving, list = list, queries = queries }
        end,
        run = function(impl, s)
            local world, Moving, list = s.world, s.Moving, s.list
            for _ = 1, 200 do
                for _ = 1, 30 do
                    local e = list[math.random(#list)]
                    if world:has(e, Moving) then
                        world:remove(e, Moving)
                    else
                        world:add(e, Moving)
                    end
                end
                for _, query in s.queries do
                    pass(impl, query)
                end
            end
        end,
    })

    ---------------------------------------------------------------------------
    -- 6: inline queries built per call
    ---------------------------------------------------------------------------
    add({
        group = "jecs strengths",
        name = "query(A, pair(ChildOf, parent)) per parent",
        ops = 1000,
        unit = "query",
        reuse = true,
        requires = { "pairs" },
        setup = function(impl)
            local ecs = impl.ecs
            local world = ecs.world()
            local A = impl.component(world)
            local parents = {}
            for i = 1, 1000 do
                local parent = world:entity()
                parents[i] = parent
                for _ = 1, 5 do
                    local e = world:entity()
                    world:set(e, A, i)
                    world:add(e, ecs.pair(ecs.ChildOf, parent))
                end
            end
            return { world = world, A = A, parents = parents, pair = ecs.pair, ChildOf = ecs.ChildOf, visited = 0 }
        end,
        run = function(_, s)
            local world, A, pair, ChildOf = s.world, s.A, s.pair, s.ChildOf
            local visited = 0
            for _, parent in s.parents do
                for _e, _a in world:query(A, pair(ChildOf, parent)) do
                    visited += 1
                end
            end
            s.visited = visited
        end,
        check = function(_, s)
            return expect(s.visited, 5000)
        end,
    })

    add({
        group = "jecs strengths",
        name = "2 inline queries per new caster",
        ops = 1000,
        unit = "caster",
        memory = true,
        setup = function(impl)
            local world = impl.ecs.world()
            local Skill, Cooldown = impl.component(world), impl.component(world)
            local casters = {}
            for i = 1, 1000 do
                local caster = world:entity()
                casters[i] = caster
                for _ = 1, 3 do
                    local e = world:entity()
                    world:set(e, Skill, i)
                    world:set(e, Cooldown, 0)
                    world:add(e, caster)
                end
            end
            return { world = world, Skill = Skill, Cooldown = Cooldown, casters = casters, visited = 0 }
        end,
        run = function(_, s)
            local world, Skill, Cooldown = s.world, s.Skill, s.Cooldown
            local visited = 0
            for _, caster in s.casters do
                for _ in world:query(Skill):with(caster) do
                    visited += 1
                end
                for _ in world:query(Cooldown):with(caster) do
                    visited += 1
                end
            end
            s.visited = visited
        end,
        check = function(_, s)
            return expect(s.visited, 6000)
        end,
    })

    ---------------------------------------------------------------------------
    -- 7: world:each and world:children over many entities
    ---------------------------------------------------------------------------
    local each_count = sized(100000)
    add({
        group = "jecs strengths",
        name = "world:each over 100 000",
        ops = each_count,
        unit = "entity",
        reuse = true,
        setup = function(impl)
            local world = impl.ecs.world()
            local Tag = world:entity()
            for _ = 1, each_count do
                world:add(world:entity(), Tag)
            end
            return { world = world, Tag = Tag, visited = 0 }
        end,
        run = function(_, s)
            local visited = 0
            for _ in s.world:each(s.Tag) do
                visited += 1
            end
            s.visited = visited
        end,
        check = function(_, s)
            return expect(s.visited, each_count)
        end,
    })

    add({
        group = "jecs strengths",
        name = "world:children, 1000 children, 100 loops",
        ops = 100000,
        unit = "child",
        reuse = true,
        requires = { "pairs" },
        setup = function(impl)
            local ecs = impl.ecs
            local world = ecs.world()
            local parent = world:entity()
            for _ = 1, 1000 do
                world:add(world:entity(), ecs.pair(ecs.ChildOf, parent))
            end
            return { world = world, parent = parent, visited = 0 }
        end,
        run = function(_, s)
            local world, parent = s.world, s.parent
            local visited = 0
            for _ = 1, 100 do
                for _ in world:children(parent) do
                    visited += 1
                end
            end
            s.visited = visited
        end,
        check = function(_, s)
            return expect(s.visited, 100000)
        end,
    })

    ---------------------------------------------------------------------------
    -- 8: entities of eight kinds created in turn, a pass over one kind
    ---------------------------------------------------------------------------
    local kind_count = sized(131072) // 8
    local function kinds_world(impl: Impl, pooled: boolean)
        local world: any = impl.ecs.world()
        local kinds = {}
        for k = 1, 8 do
            kinds[k] = { impl.component(world), impl.component(world), impl.component(world) }
        end
        -- the first kind comes from a slot pool where the implementation has one
        local first_kind = function(): any
            return world:entity()
        end
        local has_pool: boolean = world.pool ~= nil
        if pooled and has_pool then
            local pool: any = world:pool()
            first_kind = function(): any
                return pool:entity()
            end
        end
        for i = 1, kind_count * 8 do
            local k = i % 8 + 1
            local e = if k == 1 then first_kind() else world:entity()
            local kind = kinds[k]
            world:set(e, kind[1], i)
            world:set(e, kind[2], i)
            world:set(e, kind[3], i)
        end
        local first = kinds[1]
        return { query = world:query(first[1], first[2], first[3]):cached(), acc = 0 }
    end
    local kind_worlds: { [any]: any } = {}
    local function shared_kinds(pooled: boolean): (impl: Impl) -> any
        return function(impl: Impl): any
            local key = `{impl.name}{pooled}`
            local s = kind_worlds[key]
            if s == nil then
                s = kinds_world(impl, pooled)
                kind_worlds[key] = s
            end
            return s
        end
    end
    local function kinds_sum(): number
        local total = 0
        for i = 8, kind_count * 8, 8 do
            total += 3 * i
        end
        return total
    end
    for _, variant in { "for-in", "each", "each (pool)" } do
        local pooled = variant == "each (pool)"
        add({
            group = "jecs strengths",
            name = `8 kinds in turn, 3 values, {variant}`,
            ops = kind_count,
            unit = "match",
            reuse = true,
            setup = shared_kinds(pooled),
            run = function(impl, s)
                local acc = 0
                if variant ~= "for-in" and impl.features.each then
                    s.query:each(function(_: any, a: number, b: number, c: number)
                        acc += a + b + c
                    end)
                else
                    for _, a, b, c in s.query do
                        acc += a + b + c
                    end
                end
                s.acc = acc
            end,
            check = function(_, s)
                return expect(s.acc, kinds_sum())
            end,
            release = if variant ~= "for-in"
                then function(impl: Impl)
                    kind_worlds[`{impl.name}{pooled}`] = nil
                end
                else nil,
        })
    end

    ---------------------------------------------------------------------------
    -- 9: deleting entities that have 100 targets of a relation
    ---------------------------------------------------------------------------
    add({
        group = "jecs strengths",
        name = "delete entities with 100 targets",
        ops = 2000,
        unit = "pair",
        requires = { "pairs" },
        setup = function(impl)
            local ecs = impl.ecs
            local world = ecs.world()
            local Knows = world:entity()
            local targets = {}
            for i = 1, 100 do
                targets[i] = world:entity()
            end
            local holders = {}
            for h = 1, 20 do
                local e = world:entity()
                for i = 1, 100 do
                    world:add(e, ecs.pair(Knows, targets[i]))
                end
                holders[h] = e
            end
            return { world = world, holders = holders }
        end,
        run = function(_, s)
            local world = s.world
            for _, e in s.holders do
                world:delete(e)
            end
        end,
    })

    ---------------------------------------------------------------------------
    -- 10: the memory of sparse components in a large world
    ---------------------------------------------------------------------------
    local sparse_total = sized(131072)
    local sparse_count = sparse_total // 64
    add({
        group = "jecs strengths",
        name = "8 components on 1 entity in 64",
        ops = sparse_count,
        unit = "entity",
        memory = true,
        setup = function(impl)
            local world = impl.ecs.world()
            local Position = impl.component(world)
            local list = table.create(sparse_total)
            for i = 1, sparse_total do
                local e = world:entity()
                world:set(e, Position, i)
                list[i] = e
            end
            local components = {}
            for k = 1, 8 do
                components[k] = impl.component(world)
            end
            return { world = world, list = list, components = components }
        end,
        run = function(_, s)
            local world, list, components = s.world, s.list, s.components
            for i = 1, sparse_count do
                local e = list[i * 64]
                for k = 1, 8 do
                    world:set(e, components[k], k)
                end
            end
        end,
    })
end
