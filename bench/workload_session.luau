--!strict
--!optimize 2
-- Long-session memory diagnostic for the reference model. Each invocation loads one build.
-- Run: luau -O2 [--codegen] bench/workload_session.luau -a ../src target 1001 60000 10000
-- Arguments: module path, scale (small/target), seed, frames, checkpoint interval.

local args = { ... }
local implementation = args[1] or "../src"
local ecs: any = (require :: any)(implementation)
local model = require("./workload_model")
local gc = require("./gc")
local scale = if args[2] == "small" then model.SMALL else model.TARGET
local seed = tonumber(args[3]) or 1001
local frames = tonumber(args[4]) or 60000
local interval = tonumber(args[5]) or 10000
gc.full()
local base = gc.kb()
local m = model.new(ecs, scale, seed)
local function checkpoint(frame: number)
    m.verify_expiry()
    local alive, slots = 0, 0
    for _, e in m.world:alive_table() do
        slots += 1
        if e > 0 then
            alive += 1
        end
    end
    gc.full()
    print(string.format("SESSION\t%d\t%.9f\t%d\t%d", frame, (gc.kb() - base) / 1024, alive, slots))
end
checkpoint(0)
for frame = 1, frames do
    m.frame()
    if frame % interval == 0 then
        checkpoint(frame)
    end
end
