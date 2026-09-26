--!strict
--!optimize 2
--[[
    A long session: enemies spawn and die all the time, units target living enemies through a
    pair (Targeting, enemy), and switch state tags. In an archetype ECS every target makes an
    archetype that outlives the enemy until the world is cleaned up. Prints the heap size and
    the time per frame every 1000 frames, for jecs (without and with world:cleanup() every 600
    frames) and for mErCS.

    Run from the repository root:
        luau -O2 bench/leak.luau
]]

local gc = require("./gc")
local jecs = require("@jecs")
local lib = require("@lib")

local UNITS = 500
local ENEMIES = 200
local FRAMES = 5000

local function session(name: string, ecs: any, cleanup_every: number?)
    local world = ecs.world()
    local pair = ecs.pair
    local Health = world:component()
    local Targeting = world:entity()
    local Idle = world:entity()
    local Chasing = world:entity()

    local seed = 777
    local function rand(n: number): number
        seed = seed * 16807 % 2147483647
        return seed % n
    end

    local enemies: { any } = {}
    for i = 1, ENEMIES do
        local e = world:entity()
        world:set(e, Health, 100)
        enemies[i] = e
    end
    local units: { any } = {}
    local targets: { any } = {}
    for i = 1, UNITS do
        local u = world:entity()
        world:set(u, Health, 100)
        world:add(u, Idle)
        units[i] = u
    end

    gc.full()
    local start_kb = gc.kb()
    local t = os.clock()
    local line: { string } = {}
    for frame = 1, FRAMES do
        -- 5 enemies die and 5 new ones spawn every frame
        for _ = 1, 5 do
            local k = rand(ENEMIES) + 1
            world:delete(enemies[k])
            local e = world:entity()
            world:set(e, Health, 100)
            enemies[k] = e
        end
        -- 10 % of the units pick a new target and switch state (jecs does not support
        -- removing a wildcard pair, so the previous target is remembered)
        for _ = 1, UNITS // 10 do
            local k = rand(UNITS) + 1
            local u = units[k]
            local previous = targets[k]
            if previous then
                world:remove(u, pair(Targeting, previous))
            end
            local target = enemies[rand(ENEMIES) + 1]
            world:add(u, pair(Targeting, target))
            targets[k] = target
            if world:has(u, Idle) then
                world:remove(u, Idle)
                world:add(u, Chasing)
            else
                world:remove(u, Chasing)
                world:add(u, Idle)
            end
        end
        -- a system over the chasing units
        local n = 0
        for _u, _health in world:query(Health):with(Chasing) do
            n += 1
        end
        if cleanup_every and frame % cleanup_every == 0 then
            world:cleanup()
        end
        if frame % 1000 == 0 then
            gc.full()
            local kb = gc.kb() - start_kb
            local ms = (os.clock() - t) / 1000 * 1e3
            table.insert(line, string.format("%5.0f KB %5.3f ms", kb, ms))
            t = os.clock()
        end
    end
    print(string.format("%-22s %s", name, table.concat(line, " | ")))
end

print(`heap growth and time per frame at frames 1000..{FRAMES} ({UNITS} units, {ENEMIES} enemies)`)
session("jecs", jecs, nil)
session("jecs + cleanup / 600", jecs, 600)
session("mErCS", lib, nil)
