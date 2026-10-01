--!strict
--[[
    Model-based fuzz of world:each and world:children snapshots. The model, independent of
    world:has and queries, tracks full entity ids, liveness, tags and parent relationships.
    Held iterators span mutations, cascades, slot reuse and more than sixteen nested loops.
    Failures include the seed, round and operation trace for deterministic reproduction.

    Run: luau test/snapshots_fuzz.luau [-a seed rounds]
]]

local ecs = require("@lib")
type Entity = ecs.Entity
type Entry = { entity: Entity, alive: boolean, tagged: boolean, child: boolean }
type Snapshot = { next: () -> Entity?, expected: { Entity }, at: number }
local args = { ... }

local function run(initial_seed: number, rounds: number)
    local seed = initial_seed
    local function rand(n: number): number
        seed = seed * 16807 % 2147483647
        return seed % n + 1
    end
    local world = ecs.world()
    local pool = world:pool()
    local tag, parent = world:entity(), world:entity()
    local entries: { Entry } = {}
    local pending: { Snapshot } = {}
    local trace: { string } = {}
    local function spawn(entity: Entity)
        local tagged, child = rand(2) == 1, rand(2) == 1
        if tagged then
            world:add(entity, tag)
        end
        if child then
            world:add(entity, ecs.pair(ecs.ChildOf, parent))
        end
        table.insert(entries, { entity = entity, alive = true, tagged = tagged, child = child })
    end
    for i = 1, 100 do
        spawn(world:entity(32768 + i * 33))
    end
    local function snapshot(children: boolean): Snapshot
        local expected: { Entity } = {}
        for _, entry in entries do
            if entry.alive and (if children then entry.child else entry.tagged) then
                table.insert(expected, entry.entity)
            end
        end
        table.sort(expected, function(a: Entity, b: Entity): boolean
            return ecs.ECS_ID(a) < ecs.ECS_ID(b)
        end)
        return {
            next = if children then world:children(parent) else world:each(tag),
            expected = expected,
            at = 0,
        }
    end
    local function advance(saved: Snapshot, round: number)
        saved.at += 1
        local actual = saved.next()
        local expected = saved.expected[saved.at]
        assert(
            actual == expected,
            `snapshot seed={initial_seed} round={round} index={saved.at}: expected {expected}, got {actual}; {table.concat(
                trace,
                "; "
            )}`
        )
    end
    local function finish(saved: Snapshot, round: number)
        while saved.at <= #saved.expected do
            advance(saved, round)
        end
        advance(saved, round) -- an exhausted iterator remains exhausted
    end
    for round = 1, rounds do
        table.clear(trace)
        for _ = 1, rand(5) do
            table.insert(pending, snapshot(rand(2) == 1))
        end
        for _ = 1, 12 do
            local entry = entries[rand(#entries)]
            local e, op = entry.entity, rand(10)
            table.insert(trace, `{op}:{e}`)
            if op == 1 then
                spawn(if rand(2) == 1 then pool:entity() else world:entity())
            elseif op == 2 then
                world:delete(parent)
                for _, other in entries do
                    if other.alive and other.child then
                        other.alive, other.tagged, other.child = false, false, false
                    end
                end
                parent = world:entity()
            elseif op == 3 then
                world:remove_all(tag)
                for _, other in entries do
                    other.tagged = false
                end
            elseif entry.alive then
                if op == 4 then
                    world:delete(e)
                    entry.alive, entry.tagged, entry.child = false, false, false
                    spawn(world:entity())
                elseif op == 5 then
                    world:clear(e)
                    entry.tagged, entry.child = false, false
                elseif op == 6 then
                    world:add(e, tag)
                    entry.tagged = true
                elseif op == 7 then
                    world:remove(e, tag)
                    entry.tagged = false
                elseif op == 8 then
                    world:add(e, ecs.pair(ecs.ChildOf, parent))
                    entry.child = true
                elseif op == 9 then
                    world:remove(e, ecs.pair(ecs.ChildOf, parent))
                    entry.child = false
                else
                    -- A completed inner loop returns its buffer while outer ones are held.
                    finish(snapshot(rand(2) == 1), round)
                end
            end
            if #pending > 0 then
                advance(pending[rand(#pending)], round)
            end
        end
        if #pending >= 24 then
            for i = #pending, 1, -1 do
                if i % 3 ~= 0 then
                    finish(pending[i], round)
                end -- the other iterators are abandoned, like a break
                pending[i] = nil :: any
            end
        end
        finish(snapshot(false), round)
        finish(snapshot(true), round)
    end
    for _, saved in pending do
        finish(saved, rounds)
    end
end

-- assert returns all its arguments: parentheses keep its message out of the seed array.
local seeds: { number } = if args[1] then { (assert(tonumber(args[1]), "invalid seed")) } else { 1, 42, 20260930 }
local rounds = if args[2] then assert(tonumber(args[2]), "invalid rounds") else 250
for _, seed in seeds do
    run(seed, rounds)
end
print(`snapshots fuzz: ok ({#seeds} seeds, {rounds} rounds)`)
