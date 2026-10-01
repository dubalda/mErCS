--!strict
-- Checks that the reference model stays within its expiry-pair bound during changes and
-- lifecycle churn, that its states keep their average members through the frames, that a
-- burst of activity and the stress case go back to the averages, and that allocation
-- measurements reject a completed GC cycle.
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

for _, scale in { model.SMALL, model.TARGET } do
    local m = model.new(ecs, scale, 1001)
    -- the members of each state where the walks of a frame see them: after its transitions
    local sums: { number } = table.create(7, 0)
    local frames = 300
    for _ = 1, frames do
        m.frame()
        m.transitions(scale.transitions)
        for k = 2, 7 do
            sums[k] += m.state_count(k)
        end
    end
    for k = 2, 7 do
        local average, members = sums[k] / frames, scale.members[k - 1]
        assert(math.abs(average - members) <= 1, `{scale.name}: state {k} has {average} members, {members} expected`)
    end
    m.burst(true)
    assert(m.deferred_count() == scale.burst_deferred, "a burst of activity keeps its deferred messages")
    for _ = 1, 30 do
        m.frame()
    end
    m.burst(false)
    assert(m.deferred_count() == scale.deferred, "the end of a burst goes back to the average")
    m.stress(true)
    assert(m.state_count(model.PASSING) == scale.stress_members, "the stress case fills the passing state")
    m.stress(false)
    m.transitions(scale.transitions)
    local passing = m.state_count(model.PASSING)
    local members = scale.members[model.PASSING - 1]
    assert(passing >= members - 1 and passing <= members, "the passing state goes back to its average")
end
print("workload model: the states keep their members; bursts and the stress case go back")
