--!strict
--# selene: allow(empty_loop) -- benchmark loops iterate for their cost only
--# selene: allow(shadowing)
--!optimize 2
--[[
	Benchmark scenarios: the matrix from NOTES.md (section 4.4).

	Every scenario is written against the jecs-compatible API (ecs.world(), world:entity(),
	world:set/get/has/add/remove/delete, world:query(...), ecs.pair, ...), so the same code
	runs for every implementation. Implementation-specific code lives in bench/impls.luau
	(`component` helper and `fast4` iteration).

	Usage:
		local scenarios = require("./scenarios")(131072)
]]

local harness = require("./harness")
local shapes = require("./shapes")
local strengths = require("./strengths")
local monitors = require("./monitors")

type Impl = harness.Impl
type Scenario = harness.Scenario

local function components(impl: Impl, world: any, count: number): { any }
    local list = table.create(count)
    for i = 1, count do
        list[i] = impl.component(world)
    end
    return list
end

local function entities(world: any, count: number): { any }
    local list = table.create(count)
    for i = 1, count do
        list[i] = world:entity()
    end
    return list
end

local function expect(actual: number, expected: number): string?
    if actual ~= expected then
        return `visited {actual}, expected {expected}`
    end
    return nil
end

local function build(N: number): { Scenario }
    local list: { Scenario } = {}
    local function add(scenario: Scenario)
        table.insert(list, scenario)
    end

    ---------------------------------------------------------------------------
    -- entity
    ---------------------------------------------------------------------------
    add({
        group = "entity",
        name = "create",
        ops = N,
        memory = true,
        setup = function(impl)
            return { world = impl.ecs.world() }
        end,
        run = function(_, state)
            local world = state.world
            for _ = 1, N do
                world:entity()
            end
        end,
    })

    add({
        group = "entity",
        name = "delete (4 components)",
        ops = N,
        setup = function(impl)
            local world = impl.ecs.world()
            local c = components(impl, world, 4)
            local list = entities(world, N)
            for _, e in list do
                world:set(e, c[1], 1)
                world:set(e, c[2], 1)
                world:set(e, c[3], 1)
                world:set(e, c[4], 1)
            end
            return { world = world, list = list }
        end,
        run = function(_, state)
            local world = state.world
            for _, e in state.list do
                world:delete(e)
            end
        end,
    })

    ---------------------------------------------------------------------------
    -- component
    ---------------------------------------------------------------------------
    add({
        group = "component",
        name = "add",
        ops = N,
        memory = true,
        setup = function(impl)
            local world = impl.ecs.world()
            return { world = world, a = impl.component(world), list = entities(world, N) }
        end,
        run = function(_, state)
            local world, a = state.world, state.a
            for _, e in state.list do
                world:set(e, a, 1)
            end
        end,
    })

    add({
        group = "component",
        name = "set existing",
        ops = N,
        setup = function(impl)
            local world = impl.ecs.world()
            local a = impl.component(world)
            local list = entities(world, N)
            for _, e in list do
                world:set(e, a, 1)
            end
            return { world = world, a = a, list = list }
        end,
        run = function(_, state)
            local world, a = state.world, state.a
            for _, e in state.list do
                world:set(e, a, 2)
            end
        end,
    })

    add({
        group = "component",
        name = "remove",
        ops = N,
        setup = function(impl)
            local world = impl.ecs.world()
            local a = impl.component(world)
            local list = entities(world, N)
            for _, e in list do
                world:set(e, a, 1)
            end
            return { world = world, a = a, list = list }
        end,
        run = function(_, state)
            local world, a = state.world, state.a
            for _, e in state.list do
                world:remove(e, a)
            end
        end,
    })

    for _, k in { 5, 20, 40 } do
        local count = N // 4
        local function prepare(impl: Impl, with_extra: boolean)
            local world = impl.ecs.world()
            local c = components(impl, world, k)
            local extra = impl.component(world)
            local list = entities(world, count)
            for _, e in list do
                for i = 1, k do
                    world:set(e, c[i], i)
                end
                if with_extra then
                    world:set(e, extra, 0)
                end
            end
            return { world = world, extra = extra, list = list }
        end
        add({
            group = "component",
            name = `add (entity has {k})`,
            ops = count,
            setup = function(impl)
                return prepare(impl, false)
            end,
            run = function(_, state)
                local world, extra = state.world, state.extra
                for _, e in state.list do
                    world:set(e, extra, 0)
                end
            end,
        })
        add({
            group = "component",
            name = `remove (entity has {k + 1})`,
            ops = count,
            setup = function(impl)
                return prepare(impl, true)
            end,
            run = function(_, state)
                local world, extra = state.world, state.extra
                for _, e in state.list do
                    world:remove(e, extra)
                end
            end,
        })
    end

    ---------------------------------------------------------------------------
    -- tag
    ---------------------------------------------------------------------------
    local function tagged_world(impl: Impl, with_tag: boolean)
        local world = impl.ecs.world()
        local c = components(impl, world, 4)
        local tag = world:entity()
        local list = entities(world, N)
        for _, e in list do
            world:set(e, c[1], 1)
            world:set(e, c[2], 1)
            world:set(e, c[3], 1)
            world:set(e, c[4], 1)
            if with_tag then
                world:add(e, tag)
            end
        end
        return { world = world, tag = tag, list = list }
    end

    add({
        group = "tag",
        name = "add (entity has 4)",
        ops = N,
        setup = function(impl)
            return tagged_world(impl, false)
        end,
        run = function(_, state)
            local world, tag = state.world, state.tag
            for _, e in state.list do
                world:add(e, tag)
            end
        end,
    })

    add({
        group = "tag",
        name = "remove (entity has 5)",
        ops = N,
        setup = function(impl)
            return tagged_world(impl, true)
        end,
        run = function(_, state)
            local world, tag = state.world, state.tag
            for _, e in state.list do
                world:remove(e, tag)
            end
        end,
    })

    add({
        group = "tag",
        name = "toggle 10% per frame",
        ops = N,
        setup = function(impl)
            return tagged_world(impl, false)
        end,
        run = function(_, state)
            local world, tag, list = state.world, state.tag, state.list
            for frame = 1, 10 do
                for i = frame, N, 10 do
                    local e = list[i]
                    if world:has(e, tag) then
                        world:remove(e, tag)
                    else
                        world:add(e, tag)
                    end
                end
            end
        end,
    })

    ---------------------------------------------------------------------------
    -- access
    ---------------------------------------------------------------------------
    local function access_world(impl: Impl, count: number)
        local world = impl.ecs.world()
        local c = components(impl, world, count)
        local list = entities(world, N)
        for _, e in list do
            for i = 1, count do
                world:set(e, c[i], i)
            end
        end
        return { world = world, c = c, list = list }
    end

    add({
        group = "access",
        name = "get 1",
        ops = N,
        reuse = true,
        setup = function(impl)
            return access_world(impl, 4)
        end,
        run = function(_, state)
            local world, a = state.world, state.c[1]
            for _, e in state.list do
                world:get(e, a)
            end
        end,
    })

    add({
        group = "access",
        name = "get 2",
        ops = N,
        reuse = true,
        setup = function(impl)
            return access_world(impl, 4)
        end,
        run = function(_, state)
            local world, c = state.world, state.c
            local a, b = c[1], c[2]
            for _, e in state.list do
                world:get(e, a, b)
            end
        end,
    })

    add({
        group = "access",
        name = "get 4",
        ops = N,
        reuse = true,
        setup = function(impl)
            return access_world(impl, 4)
        end,
        run = function(_, state)
            local world, c = state.world, state.c
            local a, b, cc, d = c[1], c[2], c[3], c[4]
            for _, e in state.list do
                world:get(e, a, b, cc, d)
            end
        end,
    })

    add({
        group = "access",
        name = "has 1",
        ops = N,
        reuse = true,
        setup = function(impl)
            return access_world(impl, 4)
        end,
        run = function(_, state)
            local world, a = state.world, state.c[1]
            for _, e in state.list do
                world:has(e, a)
            end
        end,
    })

    add({
        group = "access",
        name = "has 4",
        ops = N,
        reuse = true,
        setup = function(impl)
            return access_world(impl, 4)
        end,
        run = function(_, state)
            local world, c = state.world, state.c
            local a, b, cc, d = c[1], c[2], c[3], c[4]
            for _, e in state.list do
                world:has(e, a, b, cc, d)
            end
        end,
    })

    add({
        group = "access",
        name = "get 8",
        ops = N // 4,
        reuse = true,
        requires = { "many_ids" },
        setup = function(impl)
            local world = impl.ecs.world()
            local c = components(impl, world, 8)
            local list = entities(world, N // 4)
            for _, e in list do
                for i = 1, 8 do
                    world:set(e, c[i], i)
                end
            end
            return { world = world, c = c, list = list }
        end,
        run = function(_, state)
            local world, c = state.world, state.c
            local c1, c2, c3, c4, c5, c6, c7, c8 = c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8]
            for _, e in state.list do
                world:get(e, c1, c2, c3, c4, c5, c6, c7, c8)
            end
        end,
    })

    add({
        group = "access",
        name = "has 8",
        ops = N // 4,
        reuse = true,
        requires = { "many_ids" },
        setup = function(impl)
            local world = impl.ecs.world()
            local c = components(impl, world, 8)
            local list = entities(world, N // 4)
            for _, e in list do
                for i = 1, 8 do
                    world:set(e, c[i], i)
                end
            end
            return { world = world, c = c, list = list }
        end,
        run = function(_, state)
            local world, c = state.world, state.c
            local c1, c2, c3, c4, c5, c6, c7, c8 = c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8]
            for _, e in state.list do
                world:has(e, c1, c2, c3, c4, c5, c6, c7, c8)
            end
        end,
    })

    ---------------------------------------------------------------------------
    -- pair
    ---------------------------------------------------------------------------
    add({
        group = "pair",
        name = "pair()",
        ops = N,
        requires = { "pairs" },
        setup = function(impl)
            local world = impl.ecs.world()
            return { pair = impl.ecs.pair, a = impl.component(world), b = world:entity() }
        end,
        run = function(_, state)
            local pair, a, b = state.pair, state.a, state.b
            for _ = 1, N do
                pair(a, b)
            end
        end,
    })

    local function pair_world(impl: Impl, with_pair: boolean)
        local world = impl.ecs.world()
        local a = impl.component(world)
        local target = world:entity()
        local p = impl.ecs.pair(a, target)
        local list = entities(world, N)
        for _, e in list do
            world:set(e, a, 1)
            if with_pair then
                world:set(e, p, 1)
            end
        end
        return { world = world, p = p, list = list }
    end

    add({
        group = "pair",
        name = "add",
        ops = N,
        requires = { "pairs" },
        setup = function(impl)
            return pair_world(impl, false)
        end,
        run = function(_, state)
            local world, p = state.world, state.p
            for _, e in state.list do
                world:set(e, p, 1)
            end
        end,
    })

    add({
        group = "pair",
        name = "set existing",
        ops = N,
        requires = { "pairs" },
        setup = function(impl)
            return pair_world(impl, true)
        end,
        run = function(_, state)
            local world, p = state.world, state.p
            for _, e in state.list do
                world:set(e, p, 2)
            end
        end,
    })

    add({
        group = "pair",
        name = "remove",
        ops = N,
        requires = { "pairs" },
        setup = function(impl)
            return pair_world(impl, true)
        end,
        run = function(_, state)
            local world, p = state.world, state.p
            for _, e in state.list do
                world:remove(e, p)
            end
        end,
    })

    add({
        group = "pair",
        name = "target (4 pairs)",
        ops = N,
        reuse = true,
        requires = { "pairs" },
        setup = function(impl)
            local world = impl.ecs.world()
            local pair = impl.ecs.pair
            local c = components(impl, world, 4)
            local a = c[1]
            local list = entities(world, N)
            for _, e in list do
                world:add(e, pair(a, c[1]))
                world:add(e, pair(a, c[2]))
                world:add(e, pair(a, c[3]))
                world:add(e, pair(a, c[4]))
            end
            return { world = world, a = a, list = list }
        end,
        run = function(_, state)
            local world, a = state.world, state.a
            for _, e in state.list do
                world:target(e, a, 0)
            end
        end,
    })

    add({
        group = "pair",
        name = "children (10k parents x 5)",
        ops = 50000,
        unit = "child",
        reuse = true,
        requires = { "pairs" },
        setup = function(impl)
            local world = impl.ecs.world()
            local pair, ChildOf = impl.ecs.pair, impl.ecs.ChildOf
            local parents = entities(world, 10000)
            for _, p in parents do
                for _ = 1, 5 do
                    world:add(world:entity(), pair(ChildOf, p))
                end
            end
            return { world = world, parents = parents, visited = 0 }
        end,
        run = function(_, state)
            local world = state.world
            local n = 0
            for _, p in state.parents do
                for _ in world:children(p) do
                    n += 1
                end
            end
            state.visited = n
        end,
        check = function(_, state)
            return expect(state.visited, 50000)
        end,
    })

    add({
        group = "pair",
        name = "add unique targets",
        ops = N // 4,
        memory = true,
        requires = { "pairs" },
        setup = function(impl)
            local world = impl.ecs.world()
            local relation = world:entity()
            return {
                world = world,
                pair = impl.ecs.pair,
                relation = relation,
                sources = entities(world, N // 4),
                targets = entities(world, N // 4),
            }
        end,
        run = function(_, state)
            local world, pair, relation, targets = state.world, state.pair, state.relation, state.targets
            for i, e in state.sources do
                world:add(e, pair(relation, targets[i]))
            end
        end,
    })

    add({
        group = "pair",
        name = "delete target, Remove (1000 x 100)",
        ops = 100000,
        unit = "source",
        requires = { "pairs" },
        setup = function(impl)
            local world = impl.ecs.world()
            local pair = impl.ecs.pair
            local relation = world:entity()
            local targets = entities(world, 1000)
            for _, t in targets do
                local p = pair(relation, t)
                for _ = 1, 100 do
                    world:add(world:entity(), p)
                end
            end
            return { world = world, targets = targets }
        end,
        run = function(_, state)
            local world = state.world
            for _, t in state.targets do
                world:delete(t)
            end
        end,
    })

    add({
        group = "pair",
        name = "delete parent, ChildOf cascade (1000 x 100)",
        ops = 100000,
        unit = "child",
        requires = { "pairs" },
        setup = function(impl)
            local world = impl.ecs.world()
            local pair, ChildOf = impl.ecs.pair, impl.ecs.ChildOf
            local parents = entities(world, 1000)
            for _, p in parents do
                local link = pair(ChildOf, p)
                for _ = 1, 100 do
                    world:add(world:entity(), link)
                end
            end
            return { world = world, parents = parents }
        end,
        run = function(_, state)
            local world = state.world
            for _, p in state.parents do
                world:delete(p)
            end
        end,
    })

    ---------------------------------------------------------------------------
    -- query
    ---------------------------------------------------------------------------
    for _, per in { 8192, 256, 16, 1 } do
        local function fragmented(impl: Impl)
            local world = impl.ecs.world()
            local c = components(impl, world, 4)
            local a, b, cc, d = c[1], c[2], c[3], c[4]
            for _ = 1, N, per do
                local group = world:entity()
                for _ = 1, per do
                    local e = world:entity()
                    world:set(e, a, true)
                    world:set(e, b, true)
                    world:set(e, cc, true)
                    world:set(e, d, true)
                    world:add(e, group)
                end
            end
            local query = world:query(a, b, cc, d):cached()
            for _ in query do
            end
            return { world = world, query = query, a = a, b = b, c = cc, d = d, visited = 0 }
        end
        local fragment_state: { [Impl]: any } = {}
        local function shared(impl: Impl)
            local state = fragment_state[impl]
            if state == nil then
                state = fragmented(impl)
                fragment_state[impl] = state
            end
            return state
        end

        add({
            group = "query",
            name = `iter 4, {per} per archetype`,
            ops = N,
            unit = "entity",
            reuse = true,
            setup = shared,
            run = function(_, state)
                local n = 0
                for _e, _a, _b, _c, _d in state.query do
                    n += 1
                end
                state.visited = n
            end,
            check = function(_, state)
                return expect(state.visited, N)
            end,
        })

        add({
            group = "query",
            name = `each 4, {per} per archetype`,
            ops = N,
            unit = "entity",
            reuse = true,
            requires = { "each" },
            setup = shared,
            run = function(_, state)
                local n = 0
                state.query:each(function(_e, _a, _b, _c, _d)
                    n += 1
                end)
                state.visited = n
            end,
            check = function(_, state)
                return expect(state.visited, N)
            end,
        })

        add({
            group = "query",
            name = `fast 4, {per} per archetype`,
            ops = N,
            unit = "entity",
            reuse = true,
            setup = shared,
            release = function(impl)
                fragment_state[impl] = nil
            end,
            run = function(impl, state)
                state.visited = impl.fast4(state.world, state.query, state.a, state.b, state.c, state.d)
            end,
            check = function(_, state)
                return expect(state.visited, N)
            end,
        })
    end

    add({
        group = "query",
        name = "uncached iter 4 (create + full pass)",
        ops = N,
        unit = "entity",
        reuse = true,
        setup = function(impl)
            local state: any = access_world(impl, 4)
            state.visited = 0
            return state
        end,
        run = function(_, state)
            local world, c = state.world, state.c
            local n = 0
            for _e, _a, _b, _c, _d in world:query(c[1], c[2], c[3], c[4]) do
                n += 1
            end
            state.visited = n
        end,
        check = function(_, state)
            return expect(state.visited, N)
        end,
    })

    add({
        group = "query",
        name = "iter 1 of 4",
        ops = N,
        unit = "entity",
        reuse = true,
        setup = function(impl)
            local state: any = access_world(impl, 4)
            state.query = state.world:query(state.c[1]):cached()
            state.visited = 0
            return state
        end,
        run = function(_, state)
            local n = 0
            for _e, _a in state.query do
                n += 1
            end
            state.visited = n
        end,
        check = function(_, state)
            return expect(state.visited, N)
        end,
    })

    add({
        group = "query",
        name = "without (half excluded)",
        ops = N // 2,
        unit = "match",
        reuse = true,
        setup = function(impl)
            local world = impl.ecs.world()
            local a, b = impl.component(world), impl.component(world)
            for i = 1, N do
                local e = world:entity()
                world:set(e, a, i)
                if i % 2 == 0 then
                    world:set(e, b, i)
                end
            end
            return { world = world, query = world:query(a):without(b):cached(), visited = 0 }
        end,
        run = function(_, state)
            local n = 0
            for _e, _a in state.query do
                n += 1
            end
            state.visited = n
        end,
        check = function(_, state)
            return expect(state.visited, N // 2)
        end,
    })

    add({
        group = "query",
        name = "without, each (half excluded)",
        ops = N // 2,
        unit = "match",
        reuse = true,
        requires = { "each" },
        setup = function(impl)
            local world = impl.ecs.world()
            local a, b = impl.component(world), impl.component(world)
            for i = 1, N do
                local e = world:entity()
                world:set(e, a, i)
                if i % 2 == 0 then
                    world:set(e, b, i)
                end
            end
            return { world = world, query = world:query(a):without(b):cached(), visited = 0 }
        end,
        run = function(_, state)
            local n = 0
            state.query:each(function(_e, _a)
                n += 1
            end)
            state.visited = n
        end,
        check = function(_, state)
            return expect(state.visited, N // 2)
        end,
    })

    add({
        group = "query",
        name = "sparse, each (1% match)",
        ops = N // 100,
        unit = "match",
        reuse = true,
        requires = { "each" },
        setup = function(impl)
            local world = impl.ecs.world()
            local a, b = impl.component(world), impl.component(world)
            local matches = 0
            for i = 1, N do
                local e = world:entity()
                world:set(e, a, i)
                if i % 100 == 0 then
                    world:set(e, b, i)
                    matches += 1
                end
            end
            return { world = world, query = world:query(a, b):cached(), visited = 0, matches = matches }
        end,
        run = function(_, state)
            local n = 0
            state.query:each(function(_e, _a, _b)
                n += 1
            end)
            state.visited = n
        end,
        check = function(_, state)
            return expect(state.visited, state.matches)
        end,
    })

    add({
        group = "query",
        name = "sparse (1% match)",
        ops = N // 100,
        unit = "match",
        reuse = true,
        setup = function(impl)
            local world = impl.ecs.world()
            local a, b = impl.component(world), impl.component(world)
            local matches = 0
            for i = 1, N do
                local e = world:entity()
                world:set(e, a, i)
                if i % 100 == 0 then
                    world:set(e, b, i)
                    matches += 1
                end
            end
            return { world = world, query = world:query(a, b):cached(), visited = 0, matches = matches }
        end,
        run = function(_, state)
            local n = 0
            for _e, _a, _b in state.query do
                n += 1
            end
            state.visited = n
        end,
        check = function(_, state)
            return expect(state.visited, state.matches)
        end,
    })

    add({
        group = "query",
        name = "create + first match (2000 archetypes)",
        ops = 1000,
        unit = "query",
        reuse = true,
        setup = function(impl)
            local world = impl.ecs.world()
            local a, b = impl.component(world), impl.component(world)
            for _ = 1, 2000 do
                local group = world:entity()
                for _ = 1, 10 do
                    local e = world:entity()
                    world:set(e, a, 1)
                    world:set(e, b, 1)
                    world:add(e, group)
                end
            end
            return { world = world, a = a, b = b }
        end,
        run = function(_, state)
            local world, a, b = state.world, state.a, state.b
            for _ = 1, 1000 do
                for _ in world:query(a, b) do
                    break
                end
            end
        end,
    })

    add({
        group = "query",
        name = "small query per call (15 of 1000)",
        ops = 10000,
        unit = "query",
        reuse = true,
        setup = function(impl)
            local world = impl.ecs.world()
            local c = components(impl, world, 3)
            for i = 1, 1000 do
                local e = world:entity()
                world:set(e, c[1], i)
                if i % 64 == 0 then
                    world:set(e, c[2], i)
                    world:set(e, c[3], i)
                end
            end
            return { world = world, c = c, visited = 0 }
        end,
        run = function(_, state)
            local world, c = state.world, state.c
            local n = 0
            for _ = 1, 10000 do
                for _e, _a, _b in world:query(c[2], c[3]) do
                    n += 1
                end
            end
            state.visited = n
        end,
        check = function(_, state)
            return expect(state.visited, 10000 * 15)
        end,
    })

    -- a pair with a concrete target, written inline: the query is shared by shape from its
    -- second call
    for _, matches in { 15, 0 } do
        add({
            group = "query",
            name = `a concrete pair per call ({matches} of 1000)`,
            ops = 10000,
            unit = "query",
            reuse = true,
            requires = { "pairs" },
            setup = function(impl)
                local world = impl.ecs.world()
                local a = impl.component(world)
                local link = impl.ecs.pair(world:entity(), world:entity())
                for i = 1, 1000 do
                    local e = world:entity()
                    world:set(e, a, i)
                    if matches > 0 and i % 64 == 0 then
                        world:add(e, link)
                    end
                end
                return { world = world, a = a, link = link, visited = 0 }
            end,
            run = function(_, state)
                local world, a, link = state.world, state.a, state.link
                local n = 0
                for _ = 1, 10000 do
                    for _e, _a in world:query(a, link) do
                        n += 1
                    end
                end
                state.visited = n
            end,
            check = function(_, state)
                return expect(state.visited, 10000 * matches)
            end,
        })
    end

    add({
        group = "query",
        name = "iter 10 terms",
        ops = N // 4,
        unit = "entity",
        reuse = true,
        setup = function(impl)
            local world = impl.ecs.world()
            local c = components(impl, world, 10)
            for _ = 1, N // 4 do
                local e = world:entity()
                for i = 1, 10 do
                    world:set(e, c[i], i)
                end
            end
            return { world = world, query = world:query(table.unpack(c)):cached(), visited = 0 }
        end,
        run = function(_, state)
            local n = 0
            for _e in state.query do
                n += 1
            end
            state.visited = n
        end,
        check = function(_, state)
            return expect(state.visited, N // 4)
        end,
    })

    ---------------------------------------------------------------------------
    -- batch: one change to every match of a query. A library with batch operations
    -- (query:add_all and co.) uses them; others collect the matches and change them one by one.
    ---------------------------------------------------------------------------
    local function batch_world(impl: Impl)
        local world = impl.ecs.world()
        local c = components(impl, world, 4)
        local marked, extra = world:entity(), world:entity()
        local list = entities(world, N)
        for i, e in list do
            world:set(e, c[1], 1)
            world:set(e, c[2], 1)
            world:set(e, c[3], 1)
            if i % 2 == 0 then
                world:add(e, marked)
            end
        end
        -- whether the library has batch operations
        local batch = (world:query(c[1]) :: any).add_all ~= nil
        return { world = world, c = c, marked = marked, extra = extra, list = list, batch = batch }
    end
    local function collect(query: any): { any }
        local matched: { any } = {}
        local n = 0
        for e in query do
            n += 1
            matched[n] = e
        end
        return matched
    end

    add({
        group = "batch",
        name = "add a tag to matches (half)",
        ops = N // 2,
        unit = "match",
        setup = batch_world,
        run = function(_, state)
            local world, query: any = state.world, state.world:query(state.c[1]):without(state.marked)
            if state.batch then
                query:add_all(state.extra)
            else
                for _, e in collect(query) do
                    world:add(e, state.extra)
                end
            end
        end,
    })

    add({
        group = "batch",
        name = "set a component on matches (half)",
        ops = N // 2,
        unit = "match",
        setup = batch_world,
        run = function(_, state)
            local world, query: any = state.world, state.world:query(state.c[1]):with(state.marked)
            local id = state.c[4]
            if state.batch then
                query:set_all(id, 0)
            else
                for _, e in collect(query) do
                    world:set(e, id, 0)
                end
            end
        end,
    })

    add({
        group = "batch",
        name = "remove a component from matches (half)",
        ops = N // 2,
        unit = "match",
        setup = batch_world,
        run = function(_, state)
            local world, query: any = state.world, state.world:query(state.c[2]):with(state.marked)
            local id = state.c[1]
            if state.batch then
                query:remove_all(id)
            else
                for _, e in collect(query) do
                    world:remove(e, id)
                end
            end
        end,
    })

    add({
        group = "batch",
        name = "delete matches (half)",
        ops = N // 2,
        unit = "match",
        setup = batch_world,
        run = function(_, state)
            local world, query: any = state.world, state.world:query(state.c[1]):with(state.marked)
            if state.batch then
                query:delete_all()
            else
                for _, e in collect(query) do
                    world:delete(e)
                end
            end
        end,
    })

    add({
        group = "batch",
        name = "count matches (half)",
        ops = N // 2,
        unit = "match",
        reuse = true,
        setup = batch_world,
        run = function(_, state)
            local query: any = state.world:query(state.c[1]):with(state.marked)
            local n = 0
            if state.batch then
                n = query:count()
            else
                for _ in query do
                    n += 1
                end
            end
            state.visited = n
        end,
        check = function(_, state)
            return expect(state.visited, N // 2)
        end,
    })

    ---------------------------------------------------------------------------
    -- churn
    ---------------------------------------------------------------------------
    add({
        group = "churn",
        name = "spawn+despawn (10 comps, 2 tags)",
        ops = 20000,
        unit = "cycle",
        memory = true,
        setup = function(impl)
            local world = impl.ecs.world()
            local c = components(impl, world, 10)
            local t1, t2 = world:entity(), world:entity()
            local alive = table.create(5000)
            for i = 1, 5000 do
                local e = world:entity()
                for k = 1, 10 do
                    world:set(e, c[k], k)
                end
                world:add(e, t1)
                world:add(e, t2)
                alive[i] = e
            end
            return { world = world, c = c, t1 = t1, t2 = t2, alive = alive }
        end,
        run = function(_, state)
            local world, c, t1, t2, alive = state.world, state.c, state.t1, state.t2, state.alive
            for i = 1, 20000 do
                local e = world:entity()
                for k = 1, 10 do
                    world:set(e, c[k], k)
                end
                world:add(e, t1)
                world:add(e, t2)
                local slot = (i - 1) % 5000 + 1
                world:delete(alive[slot])
                alive[slot] = e
            end
        end,
    })

    add({
        group = "churn",
        name = "hierarchy spawn+despawn (1+5 ChildOf)",
        ops = 5000,
        unit = "cycle",
        memory = true,
        requires = { "pairs" },
        setup = function(impl)
            local world = impl.ecs.world()
            local c = components(impl, world, 3)
            local pair, ChildOf = impl.ecs.pair, impl.ecs.ChildOf
            local parents = table.create(500)
            local function spawn()
                local p = world:entity()
                world:set(p, c[1], 1)
                local link = pair(ChildOf, p)
                for _ = 1, 5 do
                    local child = world:entity()
                    world:set(child, c[1], 1)
                    world:set(child, c[2], 2)
                    world:set(child, c[3], 3)
                    world:add(child, link)
                end
                return p
            end
            for i = 1, 500 do
                parents[i] = spawn()
            end
            return { world = world, parents = parents, spawn = spawn }
        end,
        run = function(_, state)
            local world, parents, spawn = state.world, state.parents, state.spawn
            for i = 1, 5000 do
                local slot = (i - 1) % 500 + 1
                world:delete(parents[slot])
                parents[slot] = spawn()
            end
        end,
    })

    ---------------------------------------------------------------------------
    -- memory
    ---------------------------------------------------------------------------
    add({
        group = "memory",
        name = "entities with 4 components",
        ops = N // 2,
        unit = "entity",
        memory = true,
        setup = function(impl)
            local world = impl.ecs.world()
            return { world = world, c = components(impl, world, 4) }
        end,
        run = function(_, state)
            local world, c = state.world, state.c
            local a, b, cc, d = c[1], c[2], c[3], c[4]
            for _ = 1, N // 2 do
                local e = world:entity()
                world:set(e, a, 1)
                world:set(e, b, 2)
                world:set(e, cc, 3)
                world:set(e, d, 4)
            end
        end,
    })

    add({
        group = "memory",
        name = "entities with 10 comps + 5 tags",
        ops = N // 4,
        unit = "entity",
        memory = true,
        setup = function(impl)
            local world = impl.ecs.world()
            local tags = entities(world, 5)
            return { world = world, c = components(impl, world, 10), tags = tags }
        end,
        run = function(_, state)
            local world, c, tags = state.world, state.c, state.tags
            for _ = 1, N // 4 do
                local e = world:entity()
                for k = 1, 10 do
                    world:set(e, c[k], k)
                end
                for k = 1, 5 do
                    world:add(e, tags[k])
                end
            end
        end,
    })

    add({
        group = "memory",
        name = "ChildOf 10k parents x 5",
        ops = 50000,
        unit = "child",
        memory = true,
        requires = { "pairs" },
        setup = function(impl)
            return { world = impl.ecs.world(), pair = impl.ecs.pair, ChildOf = impl.ecs.ChildOf }
        end,
        run = function(_, state)
            local world, pair, ChildOf = state.world, state.pair, state.ChildOf
            for _ = 1, 10000 do
                local link = pair(ChildOf, world:entity())
                for _ = 1, 5 do
                    world:add(world:entity(), link)
                end
            end
        end,
    })

    add({
        group = "memory",
        name = "unique tag per entity",
        ops = N // 4,
        unit = "entity",
        memory = true,
        setup = function(impl)
            local world = impl.ecs.world()
            return { world = world, tags = entities(world, N // 4) }
        end,
        run = function(_, state)
            local world = state.world
            for _, tag in state.tags do
                world:add(world:entity(), tag)
            end
        end,
    })

    add({
        group = "memory",
        name = "1000 components x 100 entities",
        ops = 100000,
        unit = "add",
        memory = true,
        setup = function(impl)
            local world = impl.ecs.world()
            return { world = world, c = components(impl, world, 1000), list = entities(world, 10000) }
        end,
        run = function(_, state)
            local world, c, list = state.world, state.c, state.list
            for i = 1, 1000 do
                local id = c[i]
                for k = 1, 100 do
                    world:set(list[(i * 7 + k * 97) % 10000 + 1], id, k)
                end
            end
        end,
    })

    -- an entity used as a query term, then deleted: what the queries on it keep
    add({
        group = "memory",
        name = "4 inline queries on an entity, deleted",
        ops = 20000,
        unit = "entity",
        memory = true,
        setup = function(impl)
            local world = impl.ecs.world()
            return { world = world, events = components(impl, world, 4) }
        end,
        run = function(_, state)
            local world, events = state.world, state.events
            for _ = 1, 20000 do
                local caster = world:entity()
                for i = 1, 4 do
                    for _ in world:query(events[i]):with(caster) do
                    end
                end
                world:delete(caster)
            end
        end,
    })

    ---------------------------------------------------------------------------
    -- query shapes: query cases and a sparse world (bench/shapes.luau)
    ---------------------------------------------------------------------------
    shapes(add, N)

    ---------------------------------------------------------------------------
    -- the strengths of an archetype ECS (bench/strengths.luau)
    ---------------------------------------------------------------------------
    strengths(add, N)

    ---------------------------------------------------------------------------
    -- query monitors (bench/monitors.luau)
    ---------------------------------------------------------------------------
    monitors(add, N)

    return list
end

return build
