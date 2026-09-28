--!strict
--!optimize 2
--[[
    A synthetic game frame, the same for every implementation: entities move, projectiles
    live for a while and despawn, spawners create new ones, units switch AI states through
    tags, damage marks entities with a one-frame tag, and attachments follow their parents.

    The module is a function of the implementations to compare, a list of { name, module }
    (the names carry the versions, see bench/versions.luau):
    it prints the time per frame (minimum and median over the measured frames), once with the
    queries written inline in every frame and once with queries created before the loop and
    marked :cached() (the recommended jecs style), and returns the times. The implementations
    are passed in because the luau CLI (bench/frame.luau) and Roblox (studio/runner.luau)
    reach jecs by different paths.

    Usage:
        local frame_scene = require("./frame_scene")
        local report = frame_scene({ { "jecs 0.11.0", jecs }, { "mErCS 0.2.0", lib } })
]]

local gc = require("./gc")

export type Report = { [string]: { [string]: { number } } }

local UNITS = 3000
local PROJECTILES_PER_FRAME = 60
local FRAMES = 300
local WARMUP = 60

local function frames(ecs: any, stored: boolean): (number, number)
    local world = ecs.world()
    local pair = ecs.pair
    local ChildOf = ecs.ChildOf

    local Position = world:component()
    local Velocity = world:component()
    local Health = world:component()
    local Lifetime = world:component()
    local Owner = world:component()
    local Offset = world:component()
    local Idle = world:entity()
    local Chasing = world:entity()
    local Attacking = world:entity()
    local Projectile = world:entity()
    local Damaged = world:entity()
    local Unit = world:entity()

    local seed = 12345
    local function rand(n: number): number
        seed = seed * 16807 % 2147483647
        return seed % n
    end

    local units = {}
    for i = 1, UNITS do
        local e = world:entity()
        world:set(e, Position, { x = rand(1000), y = rand(1000) })
        world:set(e, Velocity, { x = 0, y = 0 })
        world:set(e, Health, 100)
        world:add(e, Unit)
        world:add(e, Idle)
        -- two attachments per unit (weapon, effect), following the unit
        for _ = 1, 2 do
            local a = world:entity()
            world:set(a, Position, { x = 0, y = 0 })
            world:set(a, Offset, { x = 1, y = 1 })
            world:add(a, pair(ChildOf, e))
        end
        units[i] = e
    end

    local function make_queries()
        local q = {
            move = world:query(Position, Velocity),
            follow = world:query(Position, Offset),
            lifetime = world:query(Lifetime):with(Projectile),
            damage = world:query(Health):with(Damaged),
            damaged = world:query(Damaged),
            chasing = world:query(Velocity):with(Chasing),
            idle = world:query(Velocity):with(Idle),
        }
        if stored then
            for _, query in { q.move, q.follow, q.lifetime, q.damage, q.damaged, q.chasing, q.idle } do
                query:cached()
            end
        end
        return q
    end
    local stored_queries = if stored then make_queries() else nil

    local times: { number } = {}
    for frame = 1, WARMUP + FRAMES do
        local q = stored_queries or make_queries()
        local t = os.clock()

        -- spawn projectiles owned by random units
        for _ = 1, PROJECTILES_PER_FRAME do
            local p = world:entity()
            world:set(p, Position, { x = rand(1000), y = rand(1000) })
            world:set(p, Velocity, { x = rand(5) - 2, y = rand(5) - 2 })
            world:set(p, Lifetime, 30 + rand(30))
            world:set(p, Owner, units[rand(UNITS) + 1])
            world:add(p, Projectile)
        end

        -- movement
        for _e, position, velocity in q.move do
            position.x += velocity.x
            position.y += velocity.y
        end

        -- attachments follow their parents
        for e, position, offset in q.follow do
            local parent = world:parent(e)
            if parent then
                local p = world:get(parent, Position)
                if p then
                    position.x = p.x + offset.x
                    position.y = p.y + offset.y
                end
            end
        end

        -- projectile lifetime and hits
        local expired = {}
        for e, lifetime in q.lifetime do
            if lifetime <= 1 then
                table.insert(expired, e)
            else
                world:set(e, Lifetime, lifetime - 1)
                if lifetime % 17 == 0 then
                    local target = units[rand(UNITS) + 1]
                    if not world:has(target, Damaged) then
                        world:add(target, Damaged)
                    end
                end
            end
        end
        for _, e in expired do
            world:delete(e)
        end

        -- damage
        for e, health in q.damage do
            world:set(e, Health, if health > 5 then health - 5 else 100)
        end
        for e in q.damaged do
            world:remove(e, Damaged)
        end

        -- AI state machine: 5 % of the units switch state each frame
        for _ = 1, UNITS // 20 do
            local e = units[rand(UNITS) + 1]
            if world:has(e, Idle) then
                world:remove(e, Idle)
                world:add(e, Chasing)
            elseif world:has(e, Chasing) then
                world:remove(e, Chasing)
                world:add(e, Attacking)
            else
                world:remove(e, Attacking)
                world:add(e, Idle)
            end
        end
        for _e, velocity in q.chasing do
            velocity.x = 1
        end
        for _e, velocity in q.idle do
            velocity.x = 0
        end

        local dt = os.clock() - t
        if frame > WARMUP then
            table.insert(times, dt)
        end
    end
    table.sort(times)
    return times[1], times[#times // 2]
end

-- Runs the frame for every implementation; per mode ("inline", "cached") and implementation
-- the report holds { best, median } frame time in seconds.
local function run(impls: { { any } }): Report
    print(`synthetic frame: {UNITS} units, {UNITS * 2} attachments, {PROJECTILES_PER_FRAME} projectiles per frame`)
    local report: Report = {}
    for _, stored in { false, true } do
        local results: { [string]: { number } } = {}
        report[if stored then "cached" else "inline"] = results
        for _ = 1, 3 do
            for _, entry in impls do
                local best, median = frames(entry[2], stored)
                local r = results[entry[1]]
                if r == nil or best < r[1] then
                    results[entry[1]] = { best, median }
                end
                gc.full()
            end
        end
        print(if stored then "queries created once, :cached()" else "queries written inline")
        for _, entry in impls do
            local r = results[entry[1]]
            print(string.format("  %-12s min %.3f ms  median %.3f ms", entry[1], r[1] * 1e3, r[2] * 1e3))
        end
    end
    return report
end

return run
