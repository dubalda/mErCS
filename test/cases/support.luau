--!strict
--[[
    Shared helpers of the behavior specification (test/behavior.luau): what a group of cases
    receives from the runner, and the ways to read what a loop returns.

    Usage (a group module of test/cases/):
        local support = require("./support")

        return function(spec: support.Spec)
            local ecs, TEST, CASE, CHECK = spec.ecs, spec.TEST, spec.CASE, spec.CHECK
            TEST("a subject", function()
                CASE("one behavior")
                CHECK(support.same(support.collect(world:each(tag)), { a, b }))
            end)
        end
]]

local api = require("@lib")

export type Ecs = typeof(api)
type Entity = api.Entity

-- What a group of cases receives: the library under test and the test kit.
export type Spec = {
    ecs: Ecs,
    TEST: (name: string, fn: () -> ()) -> (),
    CASE: (name: string) -> (),
    CHECK: <T>(value: T, stack: number?) -> T?,
    CHECK_EXPECT_ERR: (fn: (...any) -> ...any, ...any) -> (),
}

local support = {}

-- The entities that a loop (an iterator or a query) returns, in its order.
function support.collect(iterator: any): { Entity }
    local list: { Entity } = {}
    for entity in iterator do
        table.insert(list, entity)
    end
    return list
end

-- The entities in ascending slot order: the order of queries, world:each and world:children.
function support.in_slot_order(ecs: Ecs, list: { Entity }): { Entity }
    local sorted = table.clone(list)
    table.sort(sorted, function(a: Entity, b: Entity): boolean
        return ecs.ECS_ID(a) < ecs.ECS_ID(b)
    end)
    return sorted
end

-- Whether two lists hold the same entities in the same order.
function support.same(actual: { Entity }, expected: { Entity }): boolean
    if #actual ~= #expected then
        return false
    end
    for i, entity in expected do
        if actual[i] ~= entity then
            return false
        end
    end
    return true
end

return support
