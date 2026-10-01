--!strict
--# selene: allow(empty_loop) -- benchmark loops iterate for their cost only
--!optimize 2
--[[
    The performance suite of the reference workload: the tests P1–P9 of the release
    requirements of a game that uses the library (section 2), over a model of its server world
    (bench/workload_model.luau). Every release runs it against the previous release and against
    itself: the columns are the previous release (after tools/previous.sh), the library and the
    library again (the two runs of one build give the noise). Each run builds its worlds anew,
    with one seed for all the columns, and takes the columns in another order (the first one
    after a start is not favored); the report gives the median and the range of the runs.

    - P1 sparse walk: world:each over a tag whose members are spread evenly among 350 000
      entities (16 / 256 / 2 048 / 16 384), in runs of 8, and the dense case (100 000 of 100 000).
    - P2 intersection walks: 10 walks per frame over state tags with the members of a system tag,
      with the state transitions of a frame between: world:each with a check, and one stored
      query per system tag.
    - P3 relation-target lookup: world:each over the holders of (Trigger_k, agent).
    - P4 stored queries under changes: the 25 stored queries at their periods while agents change
      and owned entities change state.
    - P5 messages: the messages of a frame handled (the P3 walks) and deleted, new ones made, the
      deferred ones visited.
    - P6 lifecycle: the end of the activity of an agent, the removal of a retained agent (the
      cascade over its owned entities with removal listeners), a new agent with its owned
      entities (the median of the events of a run).
    - P7 frame model: the frames of the model with the lifecycle events at their rate.
    - P8 memory: the heap of the world after it is built, after 100 lifecycle rounds and after a
      3 000, 6 000 and 9 000 more frames; bytes per distinct pair and per holder.
    - P9 allocation proxy: net heap growth with a GC witness for a warmed frame and a loop
      over a stored query or world:each. It is not total allocator traffic (see gc.allocated).

    The heap includes the lists of the model (the same for every column).

    Run from the repository root, in the interpreter and in native code (the arguments are
    optional: runs, tests, scales, previous=no; implementation=<module> runs one build only,
    seed=<n> selects a replayable model, raw=yes emits machine-readable samples. The release
    runner tools/workload.py isolates builds, scales and control runs in separate processes.
    retained=empty selects retained agents without owned entities):
        luau -O2 bench/workload.luau
        luau -O2 --codegen bench/workload.luau -a runs=5 tests=P1,P7 scales=target
]]

local gc = require("./gc")
local model = require("./workload_model")
local versions = require("./versions")

type Scale = model.Scale

type Impl = { key: string, label: string, ecs: any }

type Row = {
    test: string,
    case: string,
    scale: string,
    unit: string,
    samples: { [string]: { number } },
}

local runs = 5
local only: { [string]: boolean }? = nil
local scales: { Scale } = { model.SMALL, model.TARGET }
local with_previous = true
local implementation: string? = nil
local first_seed = 1001
local raw = false
local retained_empty = false
local profile = "server"

for _, argument in { ... } do
    local key, value = string.match(tostring(argument), "^(%w+)=(.*)$")
    if key == "runs" then
        runs = tonumber(value) or runs
    elseif key == "tests" and value then
        local set: { [string]: boolean } = {}
        for name in string.gmatch(value, "[^,]+") do
            set[string.upper(name)] = true
        end
        only = set
    elseif key == "scales" and value then
        scales = {}
        for name in string.gmatch(value, "[^,]+") do
            if name == "small" then
                table.insert(scales, model.SMALL)
            elseif name == "target" then
                table.insert(scales, model.TARGET)
            end
        end
    elseif key == "previous" then
        with_previous = value ~= "no"
    elseif key == "implementation" then
        implementation = value
    elseif key == "seed" then
        first_seed = assert(tonumber(value), "invalid seed")
    elseif key == "raw" then
        raw = value == "yes"
    elseif key == "retained" then
        retained_empty = value == "empty"
    elseif key == "profile" then
        profile = value or profile
    end
end

assert(runs >= 1 and runs % 1 == 0, "runs must be a positive integer")
if retained_empty then
    for i, scale in scales do
        local alternate = table.clone(scale)
        alternate.retain_owned = false
        alternate.name ..= "-empty-retained"
        scales[i] = alternate
    end
end

local function wanted(test: string): boolean
    return only == nil or (only :: { [string]: boolean })[test] == true
end

local impls: { Impl } = {}
if implementation then
    table.insert(impls, { key = "single", label = implementation, ecs = (require :: any)(implementation) })
else
    if with_previous then
        local previous = require("./previous")
        assert(previous, "missing baseline: run tools/previous.sh, or select previous=no for exploration")
        table.insert(impls, { key = "previous", label = `mErCS {previous.version}`, ecs = previous.ecs })
    end
    local lib = require("@lib")
    table.insert(impls, { key = "lib", label = versions.library, ecs = lib })
    table.insert(impls, { key = "again", label = `{versions.library} again`, ecs = lib })
end

local rows: { Row } = {}
local row_at: { [string]: Row } = {}

local function record(test: string, case: string, scale: string, unit: string, impl: Impl, value: number)
    assert(value == value and math.abs(value) < math.huge, `non-finite measurement: {test} {case}`)
    if raw then
        print(string.format("SAMPLE\t%s\t%s\t%s\t%s\t%.17g", test, case, scale, unit, value))
    end
    local key = `{test}|{case}|{scale}`
    local row = row_at[key]
    if row == nil then
        local created: Row = { test = test, case = case, scale = scale, unit = unit, samples = {} }
        row = created
        row_at[key] = created
        table.insert(rows, created)
    end
    local samples = (row :: Row).samples
    local list = samples[impl.key]
    if list == nil then
        list = {}
        samples[impl.key] = list
    end
    table.insert(list :: { number }, value)
end

local function median(values: { number }): number
    local sorted = table.clone(values)
    table.sort(sorted)
    local n = #sorted
    if n % 2 == 1 then
        return sorted[(n + 1) // 2]
    end
    return (sorted[n // 2] + sorted[n // 2 + 1]) / 2
end

local function elapsed(body: () -> ...any): number
    local t = os.clock()
    body()
    return os.clock() - t
end

--------------------------------------------------------------------------------
-- P1: sparse walks (a world of their own)
--------------------------------------------------------------------------------

local P1_ENTITIES = 350000
local P1_MEMBERS = { 16, 256, 2048, 16384 }

local function sparse_walks(impl: Impl)
    local world = impl.ecs.world()
    local entities = table.create(P1_ENTITIES)
    for i = 1, P1_ENTITIES do
        entities[i] = world:entity()
    end
    local spread: { any } = {}
    local counts: { number } = {}
    for k, members in P1_MEMBERS do
        local tag = world:entity()
        local count = 0
        for member = 0, members - 1 do
            local i = member * P1_ENTITIES // members + 1
            world:add(entities[i], tag)
            count += 1
        end
        spread[k] = tag
        counts[k] = count
    end
    -- 2 048 members in runs of 8 adjacent slots, the runs spread evenly
    local in_runs = world:entity()
    local run_count = 2048 // 8
    for r = 0, run_count - 1 do
        local first = r * (P1_ENTITIES // run_count) + 1
        for i = first, first + 7 do
            world:add(entities[i], in_runs)
        end
    end
    local function loop_time(w: any, tag: any, members: number): number
        local loops = math.max(1, 2000000 // (members + 200))
        local best = math.huge
        for _ = 1, 3 do
            local t = os.clock()
            for _ = 1, loops do
                for _ in w:each(tag) do
                end
            end
            best = math.min(best, (os.clock() - t) / loops)
        end
        return best * 1e6
    end
    for k, members in P1_MEMBERS do
        record(
            "P1",
            `{members} members spread (world:each)`,
            "350 000",
            "µs per loop",
            impl,
            loop_time(world, spread[k], counts[k])
        )
    end
    record("P1", "2048 members in runs of 8", "350 000", "µs per loop", impl, loop_time(world, in_runs, 2048))
    local dense = impl.ecs.world()
    local dense_tag = dense:entity()
    for _ = 1, 100000 do
        dense:add(dense:entity(), dense_tag)
    end
    record("P1", "100 000 of 100 000 (dense)", "100 000", "µs per loop", impl, loop_time(dense, dense_tag, 100000))
    -- The same sparse layout, after words have been emptied by changes of state.
    local changed = world:entity()
    for i = 1, 16 do
        world:add(entities[i * 21000], changed)
    end
    world:add(entities[100], changed)
    world:remove(entities[100], changed)
    record("P1", "16 members after an emptied word", "350 000", "µs per loop", impl, loop_time(world, changed, 16))
end

--------------------------------------------------------------------------------
-- P2–P9 over the model
--------------------------------------------------------------------------------

local function model_tests(impl: Impl, scale: Scale, seed: number)
    local target = scale.owned == model.TARGET.owned
    -- the small scale runs 5 times the frames: its frames are short
    local repeat_frames = if target then 1 else 5
    gc.full()
    local base_kb = gc.kb()
    local m = model.new(impl.ecs, scale, seed)
    local world = m.world
    gc.full()
    if wanted("P8") then
        record("P8", "the heap of the world after it is built", scale.name, "MB", impl, (gc.kb() - base_kb) / 1024)
    end

    if wanted("P3") then
        local calls = if target then 2000 else 20000
        local time = elapsed(function()
            for _ = 1, calls do
                m.trigger_walk()
            end
        end)
        record("P3", "world:each over (Trigger_k, agent)", scale.name, "ns per call", impl, time / calls * 1e9)
    end

    if wanted("P2") then
        local frames = 300 * repeat_frames
        local each_time, query_time = 0, 0
        for _ = 1, frames do
            m.transitions(scale.transitions)
            each_time += elapsed(m.intersection_each)
            query_time += elapsed(m.intersection_queries)
        end
        record("P2", "10 walks: world:each with a check", scale.name, "µs per frame", impl, each_time / frames * 1e6)
        record(
            "P2",
            "10 walks: one stored query per system tag",
            scale.name,
            "µs per frame",
            impl,
            query_time / frames * 1e6
        )
    end

    if wanted("P4") then
        local frames = 600 * repeat_frames
        local time = 0
        for _ = 1, frames do
            m.frame_count += 1
            m.agent_changes()
            m.transitions(scale.transitions)
            time += elapsed(m.stored_queries)
        end
        record("P4", "25 stored queries at their periods", scale.name, "µs per frame", impl, time / frames * 1e6)
    end

    if wanted("P5") then
        local frames = 600 * repeat_frames
        local function work()
            m.messages()
            m.deferred_messages()
        end
        local time = 0
        for _ = 1, frames do
            time += elapsed(work)
        end
        record("P5", "messages and deferred messages", scale.name, "µs per frame", impl, time / frames * 1e6)
    end

    if wanted("P7") then
        local frames = 600 * repeat_frames
        local time = elapsed(function()
            for _ = 1, frames do
                m.frame()
            end
        end)
        record("P7", "a frame with the lifecycle events", scale.name, "µs per frame", impl, time / frames * 1e6)
        record(
            "P7",
            "the ECS work per second (60 frames)",
            scale.name,
            "ms per second",
            impl,
            time / frames * 60 * 1000
        )
    end

    if wanted("P9") then
        -- A weak witness rejects GC during the interval; see gc.allocated for the limits
        -- of measuring allocation by net heap growth. Warm the reusable frame buffers first.
        local frames = 60
        for _ = 1, frames do
            m.frame()
        end
        local bytes = gc.allocated(function()
            for _ = 1, frames do
                m.frame()
            end
        end)
        record("P9", "frame heap growth (GC checked)", scale.name, "bytes", impl, bytes / frames)
        local loops = 1000
        local query = m.sample_query
        bytes = gc.allocated(function()
            for _ = 1, loops do
                for _ in query do
                end
            end
        end)
        record("P9", "allocated by a loop over a stored query", scale.name, "bytes", impl, bytes / loops)
        local tag = m.sample_tag
        bytes = gc.allocated(function()
            for _ = 1, loops do
                for _ in world:each(tag) do
                end
            end
        end)
        record("P9", "allocated by a loop over world:each", scale.name, "bytes", impl, bytes / loops)
    end

    if wanted("P6") then
        -- the median of the events of the run: one event takes about a millisecond at the target
        -- scale, and a collection that falls into one would weigh on a mean
        local rounds = if target then 40 else 100
        local ended: { number } = {}
        local removed: { number } = {}
        local made: { number } = {}
        for i = 1, rounds do
            ended[i] = elapsed(m.end_activity)
            removed[i] = elapsed(m.remove_retained)
            made[i] = elapsed(m.new_agent)
        end
        record("P6", "the end of the activity of an agent", scale.name, "µs per event", impl, median(ended) * 1e6)
        record(
            "P6",
            "the removal of a retained agent (cascade)",
            scale.name,
            "µs per event",
            impl,
            median(removed) * 1e6
        )
        record("P6", "a new agent with its owned entities", scale.name, "µs per event", impl, median(made) * 1e6)
    end

    if wanted("P8") then
        for _ = 1, 100 do
            m.end_activity()
            m.remove_retained()
            m.new_agent()
        end
        m.verify_expiry()
        gc.full()
        record("P8", "the heap after 100 lifecycle rounds", scale.name, "MB", impl, (gc.kb() - base_kb) / 1024)
        for _ = 1, 3000 do
            m.frame()
        end
        m.verify_expiry()
        gc.full()
        record("P8", "the heap after 3 000 more frames", scale.name, "MB", impl, (gc.kb() - base_kb) / 1024)
        for checkpoint = 2, 3 do
            for _ = 1, 3000 do
                m.frame()
            end
            m.verify_expiry()
            gc.full()
            record(
                "P8",
                `the heap after {checkpoint * 3000} more frames`,
                scale.name,
                "MB",
                impl,
                (gc.kb() - base_kb) / 1024
            )
        end
        -- pairs: new distinct pairs with one holder each (up to 2 000), then the holders of one
        -- pair (up to 4 000)
        local owned = m.owned_entities(4000)
        local half = #owned // 2
        local pair = impl.ecs.pair
        local relation, other = m.spare_relation(), m.spare_relation()
        gc.full()
        local kb = gc.kb()
        for i = 1, half do
            world:add(owned[i], pair(relation, owned[half + i]))
        end
        gc.full()
        record(
            "P8",
            "bytes per distinct pair (and its holder)",
            scale.name,
            "bytes",
            impl,
            (gc.kb() - kb) * 1024 / half
        )
        local target_entity = owned[1]
        world:add(owned[2], pair(other, target_entity))
        gc.full()
        kb = gc.kb()
        for i = 3, #owned do
            world:add(owned[i], pair(other, target_entity))
        end
        gc.full()
        record("P8", "bytes per holder of a pair", scale.name, "bytes", impl, (gc.kb() - kb) * 1024 / (#owned - 2))
    end
end

--------------------------------------------------------------------------------
-- runs and the report
--------------------------------------------------------------------------------

local labels: { string } = {}
for _, impl in impls do
    table.insert(labels, impl.label)
end
local scale_names: { string } = {}
for _, scale in scales do
    table.insert(scale_names, scale.name)
end
print(`mErCS workload suite: {table.concat(labels, ", ")}; {runs} runs; scales {table.concat(scale_names, ", ")}`)

local started = os.clock()
for run = 1, runs do
    for k = 1, #impls do
        local impl = impls[(run + k - 2) % #impls + 1]
        if profile ~= "server" then
            local extra = require("./workload_extra")
            extra.run(
                impl.ecs,
                profile,
                function(test: string, case: string, scale: string, unit: string, value: number)
                    if wanted(test) then
                        record(test, case, scale, unit, impl, value)
                    end
                end
            )
            continue
        end
        if wanted("P1") then
            sparse_walks(impl)
            gc.full()
        end
        for _, scale in scales do
            model_tests(impl, scale, first_seed + run - 1)
            gc.full()
        end
    end
    print(string.format("run %d of %d done (%.0f s)", run, runs, os.clock() - started))
end

local function format(value: number): string
    local magnitude = math.abs(value)
    if magnitude >= 1000 then
        return string.format("%.0f", value)
    elseif magnitude >= 100 then
        return string.format("%.0f", value)
    elseif magnitude >= 10 then
        return string.format("%.1f", value)
    end
    return string.format("%.2f", value)
end

local header = { "Test", "Case", "Scale", "Unit" }
for _, label in labels do
    table.insert(header, label)
end
local has_ratio = #impls >= 2 and impls[1].key == "previous"
if has_ratio then
    table.insert(header, `{impls[2].label} / {impls[1].label}`)
end
print()
print("| " .. table.concat(header, " | ") .. " |")
local rule: { string } = {}
for _ = 1, #header do
    table.insert(rule, "---")
end
print("|" .. table.concat(rule, "|") .. "|")
for _, row in rows do
    local cells = { row.test, row.case, row.scale, row.unit }
    local medians: { [string]: number } = {}
    for _, impl in impls do
        local samples = row.samples[impl.key]
        if samples then
            local sorted = table.clone(samples)
            table.sort(sorted)
            local mid = median(samples)
            medians[impl.key] = mid
            table.insert(cells, `{format(mid)} [{format(sorted[1])}–{format(sorted[#sorted])}]`)
        else
            table.insert(cells, "—")
        end
    end
    if has_ratio then
        local before, after = medians[impls[1].key], medians[impls[2].key]
        table.insert(cells, if before and after and before ~= 0 then string.format("%.2f×", after / before) else "—")
    end
    print("| " .. table.concat(cells, " | ") .. " |")
end
