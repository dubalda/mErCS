--!strict
--!optimize 2
--[[
    Query monitors (bench/scenarios.luau adds them as the group "query monitors"): the cost of
    the changes that a monitor watches, jecs 0.11.0 with its addon modules/OB against
    query:monitor (Impl.monitor). The implementations without monitors are skipped.

    - a tag of the query added and removed on 10 000 entities (an entry and an exit each);
    - 10 000 members of a query deleted (an exit each);
    - 10 000 children moved between two parents, a query with ChildOf and any target
      monitored (the exclusive relation replaces the pair: no entry and no exit in mErCS).

    Usage (from bench/scenarios.luau):
        require("./monitors")(add, n)
]]

local harness = require("./harness")

type Impl = harness.Impl
type Scenario = harness.Scenario

local function events(entered: number, left: number, expected: number): string?
    if entered ~= expected or left ~= expected then
        return `entered {entered}, left {left}, expected {expected} each`
    end
    return nil
end

return function(add: (Scenario) -> (), n: number)
    local count = math.max(1, math.floor(10000 * n / 131072))

    add({
        group = "query monitors",
        name = "a tag of the query added and removed",
        ops = count,
        unit = "cycle",
        requires = { "monitor" },
        setup = function(impl)
            local world = impl.ecs.world()
            local A = impl.component(world)
            local Tag = world:entity()
            local list = {}
            for i = 1, count do
                local e = world:entity()
                world:set(e, A, i)
                list[i] = e
            end
            local s = { world = world, Tag = Tag, list = list, entered = 0, left = 0 }
            local monitor = (impl.monitor :: (any) -> any)(world:query(A):with(Tag))
            monitor.added(function()
                s.entered += 1
            end)
            monitor.removed(function()
                s.left += 1
            end)
            return s
        end,
        run = function(_, s)
            local world, Tag = s.world, s.Tag
            for _, e in s.list do
                world:add(e, Tag)
                world:remove(e, Tag)
            end
        end,
        check = function(_, s)
            return events(s.entered, s.left, count)
        end,
    })

    add({
        group = "query monitors",
        name = "members deleted",
        ops = count,
        unit = "entity",
        requires = { "monitor" },
        setup = function(impl)
            local world = impl.ecs.world()
            local A, B = impl.component(world), impl.component(world)
            local list = {}
            for i = 1, count do
                local e = world:entity()
                world:set(e, A, i)
                world:set(e, B, i)
                list[i] = e
            end
            local s = { world = world, list = list, left = 0 }
            local monitor = (impl.monitor :: (any) -> any)(world:query(A, B))
            monitor.removed(function()
                s.left += 1
            end)
            return s
        end,
        run = function(_, s)
            local world = s.world
            for _, e in s.list do
                world:delete(e)
            end
        end,
        check = function(_, s)
            return events(count, s.left, count)
        end,
    })

    add({
        group = "query monitors",
        name = "children moved, (ChildOf, *) monitored",
        ops = count,
        unit = "move",
        requires = { "monitor", "pairs" },
        setup = function(impl)
            local ecs = impl.ecs
            local world = ecs.world()
            local A = impl.component(world)
            local p1, p2 = world:entity(), world:entity()
            local list = {}
            for i = 1, count do
                local e = world:entity()
                world:set(e, A, i)
                world:add(e, ecs.pair(ecs.ChildOf, p1))
                list[i] = e
            end
            local s = { world = world, list = list, to = ecs.pair(ecs.ChildOf, p2), events = 0 }
            local monitor = (impl.monitor :: (any) -> any)(world:query(A):with(ecs.pair(ecs.ChildOf, ecs.Wildcard)))
            monitor.added(function()
                s.events += 1
            end)
            monitor.removed(function()
                s.events += 1
            end)
            return s
        end,
        run = function(_, s)
            local world, to = s.world, s.to
            for _, e in s.list do
                world:add(e, to)
            end
        end,
    })
end
