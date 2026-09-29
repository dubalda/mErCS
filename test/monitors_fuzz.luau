--!strict
--[[
    Randomized test of query monitors against the queries themselves: random queries over tags,
    components, pairs with a target, relations with any target, an exclusive relation, ChildOf
    and Disabled (with excluded ids and OR terms; a third of them not shared, see `gone`), and
    random changes of the world (add, set, remove, pairs added and removed, exclusive
    replacements, Disabled, delete with ChildOf cascades, clear, remove_all, batch operations,
    deleted targets, ids and relations, entities of a slot pool, monitors made on the way).
    After every change, the members that each monitor reported (the matches when it was made,
    plus the entries, less the exits) must be exactly the entities that its query matches
    (query:has), no entity may enter twice or leave without entering, and an entity must still
    be alive when it leaves. Hooks change the entities too.

    A deleted relation makes the monitors again: a pair keeps only the slots of its elements,
    so a query of a deleted relation matches the pairs of an entity that takes its slot, which
    its monitor does not see (see Query.monitor).

    Run from the repository root (a seed and a number of steps run one world; without them,
    five seeds, two of which reproduced bugs):
        luau test/monitors_fuzz.luau
        luau test/monitors_fuzz.luau -a 42 5000
]]

local ecs = require("../src")

local args = { ... }
local pair, W = ecs.pair, ecs.Wildcard

type Watch = { label: string, q: any, members: { [any]: boolean }, monitor: any }

local function run(first_seed: number, steps: number): { string }
    local seed = first_seed
    local function rand(n: number): number
        seed = seed * 16807 % 2147483647
        return seed % n + 1
    end

    local world = ecs.world()
    -- an id that is not alive: among the excluded ids of a query it excludes nothing and keeps
    -- the query from being shared, so that a modifier changes its state in place
    local gone = world:entity()
    world:delete(gone)
    local pool = world:pool()
    -- two components and two tags, a plain relation R, an exclusive relation X, targets
    local ids: { any } = { world:component(), world:component(), world:entity(), world:entity() }
    local R: any = world:entity()
    local X: any = world:entity()
    world:add(X, ecs.Exclusive)
    local targets: { any } = { world:entity(), world:entity(), world:entity() }

    local failures: { string } = {}
    local function fail(message: string)
        if #failures < 10 then
            table.insert(failures, message)
        end
    end

    local entities: { any } = {}
    local function spawn()
        table.insert(entities, if rand(3) == 1 then pool:entity() else world:entity())
    end
    for _ = 1, 12 do
        spawn()
    end

    local function name_of(term: any): string
        for i, id in ids do
            if id == term then
                return `id{i}`
            end
        end
        if term == ecs.Disabled then
            return "Disabled"
        end
        if ecs.IS_PAIR(term) then
            local function element(x: any): string
                if x == R then
                    return "R"
                elseif x == X then
                    return "X"
                elseif x == ecs.ChildOf then
                    return "ChildOf"
                elseif x == W then
                    return "*"
                end
                for i, t in targets do
                    if t == x then
                        return `t{i}`
                    end
                end
                return tostring(x)
            end
            return `({element(ecs.pair_first(world, term))},{element(ecs.pair_second(world, term))})`
        end
        return tostring(term)
    end

    -- the pairs of X come often: a pair and (X, *) in different roles of one query
    local function random_term(): any
        local roll = rand(12)
        if roll <= 4 then
            return ids[rand(#ids)]
        elseif roll == 5 then
            return pair(R, targets[rand(#targets)])
        elseif roll == 6 then
            return pair(R, W)
        elseif roll <= 8 then
            return pair(X, W)
        elseif roll <= 10 then
            return pair(X, targets[rand(#targets)])
        elseif roll == 11 then
            return pair(ecs.ChildOf, W)
        end
        return ecs.Disabled
    end

    local watches: { Watch } = {}
    local made = 0
    local function watch()
        made += 1
        local unshared = made % 3 == 0 -- (not drawn: the seeds make the same changes as before)
        local with = { random_term() }
        if rand(2) == 1 then
            table.insert(with, random_term())
        end
        local names: { string } = {}
        for _, term in with do
            table.insert(names, name_of(term))
        end
        local label = `[{table.concat(names, ",")}]`
        local excluded: any = if rand(3) == 1 then random_term() else nil
        local either: { any }? = if rand(4) == 1 then { random_term(), random_term() } else nil
        if excluded ~= nil then
            label ..= ` without {name_of(excluded)}`
        end
        if either then
            label ..= ` any {name_of(either[1])}|{name_of(either[2])}`
        end
        if unshared then
            label ..= " (not shared)"
        end
        local function build(): any
            local q: any = (world :: any):query(table.unpack(with))
            if unshared then
                q = if excluded ~= nil then q:without(excluded, gone) else q:without(gone)
            elseif excluded ~= nil then
                q = q:without(excluded)
            end
            if either then
                q = q:any(either[1], either[2])
            end
            return q
        end
        local q = build()
        local monitor = q:monitor()
        if rand(4) == 1 then
            -- a modifier after the monitor was made (a query that is not shared changes its
            -- state in place, a shared one gives a variant): the monitor keeps its terms, the
            -- checks use a query of them
            if rand(2) == 1 then
                q:any(random_term())
            else
                q:without(random_term())
            end
            q = build()
            label ..= " (modified after)"
        end
        local w: Watch = { label = label, q = q, members = {}, monitor = monitor }
        for e in q do
            w.members[e] = true -- the monitor starts with the same matches
        end
        w.monitor.added(function(e: any)
            if w.members[e] then
                fail(`{label}: {e} entered twice`)
            end
            w.members[e] = true
        end)
        w.monitor.removed(function(e: any)
            if not w.members[e] then
                fail(`{label}: {e} left without entering`)
            end
            if not world:contains(e) then
                fail(`{label}: {e} left after its delete`)
            end
            w.members[e] = nil
        end)
        table.insert(watches, w)
    end
    local function watch_all()
        for _, w in watches do
            w.monitor.disconnect()
        end
        table.clear(watches)
        for _ = 1, 12 do
            watch()
        end
    end
    watch_all()

    -- a hook that changes the entity while an id is removed
    world:set(ids[3], ecs.OnRemove, function(e: any, _: any, deleting: any)
        if not deleting and rand(2) == 1 then
            world:remove(e, ids[4])
        end
    end)

    for step = 1, steps do
        local e = if #entities > 0 then entities[rand(#entities)] else nil
        local roll = rand(26)
        local op = ""
        if e == nil or roll == 1 then
            spawn()
            op = "spawn"
        elseif roll <= 5 then
            local k = rand(#ids)
            if k <= 2 and rand(2) == 1 then
                world:set(e, ids[k], step)
            else
                world:add(e, ids[k])
            end
            op = "add"
        elseif roll <= 8 then
            world:remove(e, ids[rand(#ids)])
            op = "remove"
        elseif roll == 9 then
            world:add(e, pair(R, targets[rand(#targets)]))
            op = "add (R, t)"
        elseif roll == 10 then
            local target: any = if rand(3) == 1 then W else targets[rand(#targets)]
            world:remove(e, pair(R, target))
            op = "remove (R, t or *)"
        elseif roll == 11 then
            world:add(e, pair(X, targets[rand(#targets)])) -- exclusive: may replace a pair
            op = "add (X, t)"
        elseif roll == 12 then
            world:remove(e, pair(X, W))
            op = "remove (X, *)"
        elseif roll == 13 then
            local parent = entities[rand(#entities)]
            if parent ~= e then
                world:add(e, pair(ecs.ChildOf, parent))
            end
            op = "ChildOf"
        elseif roll == 14 then
            if world:has(e, ecs.Disabled) then
                world:remove(e, ecs.Disabled)
            else
                world:add(e, ecs.Disabled)
            end
            op = "Disabled"
        elseif roll == 15 then
            world:delete(e) -- its ChildOf children go too
            op = "delete"
        elseif roll == 16 then
            world:clear(e)
            op = "clear"
        elseif roll == 17 then
            world:remove_all(ids[2 + rand(2)])
            op = "remove_all"
        elseif roll == 18 then
            world:query(ids[rand(2)]):add_all(ids[2 + rand(2)])
            op = "add_all"
        elseif roll == 19 then
            world:query(ids[2 + rand(2)]):remove_all(ids[rand(#ids)])
            op = "query remove_all"
        elseif roll == 20 then
            -- a target goes: its pairs go from their entities, its ChildOf children with it
            local k = rand(#targets)
            world:delete(targets[k])
            targets[k] = world:entity()
            op = "delete target"
        elseif roll == 21 then
            -- an id goes from every entity; a new id takes its place in the new terms
            local k = rand(#ids)
            world:delete(ids[k])
            ids[k] = if k <= 2 then world:component() else world:entity()
            op = "delete id"
        elseif roll == 22 then
            world:delete(R)
            R = world:entity()
            watch_all()
            op = "delete relation"
        elseif roll == 23 then
            world:query(ids[rand(#ids)]):with(ids[rand(#ids)]):delete_all()
            op = "delete_all"
        elseif roll == 24 then
            world:query(ids[rand(#ids)]):set_all(ids[rand(2)], step)
            op = "set_all"
        elseif roll == 25 then
            world:remove_all(pair(R, W))
            op = "remove_all (R, *)"
        else
            watch()
            op = "new monitor"
        end
        -- the dead entities leave the list; no monitor may keep them
        for i = #entities, 1, -1 do
            local entity = entities[i]
            if not world:contains(entity) then
                for _, w in watches do
                    if w.members[entity] then
                        fail(`step {step} ({op}): {w.label}: {entity} is dead and still a member`)
                    end
                end
                table.remove(entities, i)
            end
        end
        for _, w in watches do
            for _, entity in entities do
                local matches = w.q:has(entity)
                if matches ~= (w.members[entity] == true) then
                    fail(
                        `step {step} ({op}): {w.label}: {entity} member {w.members[entity] == true}, matches {matches}`
                    )
                end
            end
        end
        if #failures > 0 then
            break
        end
    end
    return failures
end

-- seeds 24 and 29 reproduced two bugs of the first monitors (an exclusive relation that
-- replaced an excluded pair, and a pair that was a term in another role than (R, *) of its
-- relation); every seed reproduced a third (a modifier of the query after the monitor)
local seeds: { number } = if args[1] then { tonumber(args[1]) :: number } else { 1, 2, 3, 24, 29 }
local steps = tonumber(args[2]) or 2000
for _, seed in seeds do
    local failures = run(seed, steps)
    if #failures > 0 then
        for _, message in failures do
            print("  " .. message)
        end
        error(`monitors fuzz: {#failures} mismatches (seed {seed})`)
    end
end
print(`monitors fuzz: ok ({#seeds} seeds, {steps} steps)`)
