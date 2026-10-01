--!strict
--[[
    Behavior cases: batch operations on the matches of a query when the operation changes the
    matches themselves.

    - delete_all deletes every match once and runs its hooks once, also when matches go with
      the cascade of another match (children and parents, in any slot order) and when the hooks
      of a match delete other matches.
    - add_all of an id that the query excludes reaches every match of the call once, and the
      query is empty after it.
    - toggle_all removes the id from the matches that have it and adds it to the others, as
      they are at the call: word by word for a tag without hooks (also over scattered
      entities), entity by entity for a hooked id (each hook once) and for a pair; a component
      toggled off loses its value; a wildcard is an error.
    - batch operations keep the matches of their call when hooks make new matches, replace
      some, or run a nested batch operation (a nested remove_all cannot overwrite the rest).
    - add_all, set_all and toggle_all stop when a hook deletes their id, the relation or the
      target of their pair: the matches after it do not get a dead id.
]]

local api = require("@lib")
local support = require("./support")

type Entity = api.Entity

return function(spec: support.Spec)
    local ecs, TEST, CASE, CHECK = spec.ecs, spec.TEST, spec.CASE, spec.CHECK
    local pair = ecs.pair

    TEST("batch operations over matches that cascade or leave the query", function()
        -- whether every entity of the list is dead and ran the hook once
        local function all_gone(world: any, list: { any }, runs: { [any]: number }): boolean
            for _, e in list do
                if world:contains(e) or runs[e] ~= 1 then
                    return false
                end
            end
            return true
        end

        CASE("delete_all over parents and their children: each once, its hook once")
        do
            local world = ecs.world()
            local Kind = world:entity()
            local runs: { [any]: number } = {}
            world:set(Kind, ecs.OnRemove, function(e: any)
                runs[e] = (runs[e] or 0) + 1
            end)
            local list: { any } = {}
            -- children made after their parent
            for _ = 1, 5 do
                local parent = world:entity()
                world:add(parent, Kind)
                table.insert(list, parent)
                for _ = 1, 3 do
                    local child = world:entity()
                    world:add(child, Kind)
                    world:add(child, pair(ecs.ChildOf, parent))
                    table.insert(list, child)
                end
            end
            -- children made before their parent, and a grandchild
            local early: { any } = {}
            for _ = 1, 3 do
                local child = world:entity()
                world:add(child, Kind)
                table.insert(list, child)
                table.insert(early, child)
            end
            local late = world:entity()
            world:add(late, Kind)
            table.insert(list, late)
            for _, child in early do
                world:add(child, pair(ecs.ChildOf, late))
            end
            local grandchild = world:entity()
            world:add(grandchild, Kind)
            world:add(grandchild, pair(ecs.ChildOf, early[1]))
            table.insert(list, grandchild)
            world:query():with(Kind):delete_all()
            CHECK(all_gone(world, list, runs))
        end

        CASE("delete_all whose hooks delete other matches: each once, its hook once")
        do
            local world = ecs.world()
            local Kind = world:entity()
            local list: { any } = {}
            local runs: { [any]: number } = {}
            -- the hook of each match deletes the match 7 places ahead of it, wrapping around
            world:set(Kind, ecs.OnRemove, function(e: any)
                runs[e] = (runs[e] or 0) + 1
                local at = table.find(list, e) :: number
                world:delete(list[(at + 6) % #list + 1])
            end)
            for i = 1, 40 do
                list[i] = world:entity()
                world:add(list[i], Kind)
            end
            world:query():with(Kind):delete_all()
            CHECK(all_gone(world, list, runs))
        end

        CASE("add_all of an excluded id: every match of the call gets it once, the query is empty after")
        do
            local world = ecs.world()
            local A, X = world:component(), world:entity()
            local runs: { [any]: number } = {}
            world:set(X, ecs.OnAdd, function(e: any)
                runs[e] = (runs[e] or 0) + 1
            end)
            local list: { any } = {}
            for i = 1, 40 do
                list[i] = world:entity()
                world:set(list[i], A, i)
            end
            local query = world:query(A):without(X)
            query:add_all(X)
            local once = true
            for _, e in list do
                if runs[e] ~= 1 or not world:has(e, X) then
                    once = false
                end
            end
            CHECK(once and query:count() == 0)
        end
    end)

    TEST("toggle_all", function()
        -- entities with Base, scattered among others; every third one has the tag first
        local function scene(world: any, Base: any, Tag: any): { any }
            local list: { any } = {}
            for i = 1, 300 do
                local e = world:entity()
                if i % 4 ~= 0 then
                    world:set(e, Base, i)
                    table.insert(list, e)
                    if #list % 3 == 0 then
                        world:add(e, Tag)
                    end
                end
                for _ = 1, i % 7 do
                    world:entity() -- other entities between them
                end
            end
            return list
        end
        -- whether exactly the entities at the positions `pick` selects have the id
        local function holds(world: any, list: { any }, id: any, pick: (number) -> boolean): boolean
            for i, e in list do
                if world:has(e, id) ~= pick(i) then
                    return false
                end
            end
            return true
        end

        CASE("a tag without hooks: the matches that had it lose it, the others get it")
        do
            local world = ecs.world()
            local Base, Tag = world:component(), world:entity()
            local list = scene(world, Base, Tag)
            world:query(Base):toggle_all(Tag)
            CHECK(holds(world, list, Tag, function(i: number): boolean
                return i % 3 ~= 0
            end))
            CHECK(world:query(Base):with(Tag):count() == #list - #list // 3)
            world:query(Base):toggle_all(Tag)
            CHECK(holds(world, list, Tag, function(i: number): boolean
                return i % 3 == 0
            end))
        end

        CASE("a hooked id: entity by entity, each hook once")
        do
            local world = ecs.world()
            local Base, Tag = world:component(), world:entity()
            local list = scene(world, Base, Tag)
            local adds, removes = 0, 0
            world:set(Tag, ecs.OnAdd, function()
                adds += 1
            end)
            world:set(Tag, ecs.OnRemove, function()
                removes += 1
            end)
            world:query(Base):toggle_all(Tag)
            CHECK(holds(world, list, Tag, function(i: number): boolean
                return i % 3 ~= 0
            end))
            CHECK(adds == #list - #list // 3 and removes == #list // 3)
        end

        CASE("a component toggled off loses its value; toggled on it has none")
        do
            local world = ecs.world()
            local Base, Value = world:component(), world:component()
            local list = scene(world, Base, Value)
            world:query(Base):set_all(Value, 7) -- every match has a value now
            world:query(Base):toggle_all(Value)
            CHECK(holds(world, list, Value, function(): boolean
                return false
            end) and world:get(list[1], Value) == nil)
            world:query(Base):toggle_all(Value)
            CHECK(world:has(list[1], Value) and world:get(list[1], Value) == nil)
        end

        CASE("an excluded id: every match gets it, the query is empty after")
        do
            local world = ecs.world()
            local Base, Tag = world:component(), world:entity()
            local list = scene(world, Base, Tag)
            local query = world:query(Base):without(Tag)
            local before = query:count()
            query:toggle_all(Tag)
            CHECK(before == #list - #list // 3 and query:count() == 0)
            CHECK(world:query(Base):with(Tag):count() == #list)
        end

        CASE("a pair: entity by entity")
        do
            local world = ecs.world()
            local Base, Likes, bob = world:component(), world:entity(), world:entity()
            local list = scene(world, Base, pair(Likes, bob))
            world:query(Base):toggle_all(pair(Likes, bob))
            CHECK(holds(world, list, pair(Likes, bob), function(i: number): boolean
                return i % 3 ~= 0
            end))
        end

        CASE("a wildcard is an error")
        do
            local world = ecs.world()
            local Base, Likes = world:component(), world:entity()
            world:set(world:entity(), Base, 1)
            spec.CHECK_EXPECT_ERR(function()
                world:query(Base):toggle_all(pair(Likes, ecs.Wildcard))
            end)
        end
    end)

    TEST("batch snapshots survive nested operations", function()
        CASE("new matches and replacements from a hook are not added to the outer batch")
        local world = ecs.world()
        local match, out, nested = world:entity(), world:entity(), world:entity()
        local first, last = world:entity(), world:entity()
        world:add(first, match)
        world:add(last, match)
        local added: { Entity } = {}
        local replacement: Entity? = nil
        world:added(out, function(e)
            table.insert(added, e)
            if e == first then
                world:delete(last)
                local fresh = world:entity()
                replacement = fresh
                world:add(fresh, match)
                world:query():with(match):add_all(nested)
            end
        end)
        world:query():with(match):add_all(out)
        CHECK(support.same(added, { first }) and replacement ~= nil)
        CHECK(world:has(replacement :: Entity, nested) and not world:has(replacement :: Entity, out))
        CHECK(world:query():with(out):count() == 1)

        CASE("a nested remove_all cannot overwrite the remaining outer matches")
        local a, b = world:component(), world:component()
        for _ = 1, 70 do
            local e = world:entity()
            world:set(e, a, 1)
            world:set(e, b, 2)
        end
        local removed = 0
        world:removed(a, function()
            removed += 1
            world:query(b):remove_all(b)
        end)
        world:query(a):remove_all(a)
        CHECK(removed == 70 and world:query(a):count() == 0 and world:query(b):count() == 0)
    end)

    TEST("a hook that deletes the id of a batch operation", function()
        for _, debug in { false, true } do
            local kind = if debug then " (debug world)" else ""
            for _, operation in { "add_all", "set_all", "toggle_all" } do
                for _, form in { "the id", "the relation of the pair", "the target of the pair" } do
                    CASE(`{operation} stops when a hook deletes {form}{kind}`)
                    local world = ecs.world(debug)
                    local Base = world:entity()
                    local Value = world:component() :: api.Component<number>
                    local target = world:entity()
                    local id: any = if form == "the id" then Value else pair(Value, target)
                    local victim = if form == "the target of the pair" then target else Value
                    local members: { Entity } = {}
                    for i = 1, 3 do
                        local e = world:entity()
                        world:add(e, Base)
                        members[i] = e
                    end
                    local heard = 0
                    world:added(Value, function()
                        heard += 1
                        if world:contains(victim) then
                            world:delete(victim)
                        end
                    end)
                    local ok = pcall(function()
                        local query = world:query():with(Base)
                        if operation == "add_all" then
                            query:add_all(id)
                        elseif operation == "set_all" then
                            query:set_all(id, 17)
                        else
                            query:toggle_all(id)
                        end
                    end)
                    local holders = 0
                    for _, e in members do
                        if world:has(e, id) then
                            holders += 1
                        end
                    end
                    CHECK(ok and heard == 1 and not world:contains(victim) and holders == 0)
                end
            end
        end
    end)
end
