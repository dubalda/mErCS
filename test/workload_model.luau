--!strict
-- Checks that the reference model stays within its expiry-pair bound during changes and
-- lifecycle churn, and that allocation measurements reject a completed GC cycle.
-- Run with tools/test.sh, or luau [--codegen] test/workload_model.luau.

local ecs = require("@lib")
local model = require("../bench/workload_model")
local gc = require("../bench/gc")

local measured, problem = pcall(function()
    gc.allocated(function()
        gc.full()
    end)
end)
assert(not measured and string.find(tostring(problem), "GC crossed", 1, true), "a completed GC must reject the sample")

for _, retain_owned in { true, false } do
    local scale = table.clone(model.SMALL)
    scale.retain_owned = retain_owned
    local m = model.new(ecs, scale, 1001)
    m.verify_expiry()
    for _ = 1, 100 do
        for _ = 1, 50 do
            m.agent_changes()
        end
        m.verify_expiry()
        m.end_activity()
        m.remove_retained()
        m.new_agent()
    end
    m.verify_expiry()
end
print("workload model: expiry pairs stay bounded in both lifecycle profiles")
