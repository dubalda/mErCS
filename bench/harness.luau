--!strict
--!optimize 2
--[[
	Benchmark harness.

	Runs every scenario for every implementation and prints a comparison table.
	Time is the minimum over `reps` runs (setup is not timed), divided by the number of
	operations of the scenario. Memory is the heap growth retained after the timed run and a
	full garbage collection, divided by the number of operations (median over runs).

	Usage (from bench/run.luau):
		local harness = require("./harness")
		harness.run(impls, scenarios, { reps = 5, filter = "query" })
]]

local gc = require("./gc")

export type Impl = {
    -- the key of the `impls` option of bench/run.luau
    name: string,
    -- the column header, with the version (the name when absent)
    label: string?,
    ecs: any,
    features: { [string]: boolean },
    -- Creates a component id without hitting implementation limits.
    component: (world: any) -> any,
    -- Fastest idiomatic iteration over a prepared 4-component query; returns visited count.
    fast4: (world: any, query: any, a: any, b: any, c: any, d: any) -> number,
}

export type Scenario = {
    group: string,
    name: string,
    ops: number,
    unit: string?,
    requires: { string }?,
    memory: boolean?,
    -- The run does not change the world: setup runs once and the state is reused by all reps.
    reuse: boolean?,
    setup: (impl: Impl) -> any,
    run: (impl: Impl, state: any) -> (),
    check: ((impl: Impl, state: any) -> string?)?,
    -- Called after all reps of the scenario for an implementation (frees shared state).
    release: ((impl: Impl) -> ())?,
}

export type Options = {
    reps: number,
    filter: string?,
    impls: { string }?,
}

export type Result = {
    time: number?,
    memory: number?,
    error: string?,
    skipped: boolean?,
}

local function supports(impl: Impl, scenario: Scenario): boolean
    local requires = scenario.requires
    if requires == nil then
        return true
    end
    for _, feature in requires do
        if not impl.features[feature] then
            return false
        end
    end
    return true
end

local function median(values: { number }): number
    table.sort(values)
    local n = #values
    if n % 2 == 1 then
        return values[(n + 1) // 2]
    end
    return (values[n // 2] + values[n // 2 + 1]) / 2
end

local function measure(impl: Impl, scenario: Scenario, reps: number): Result
    local best = math.huge
    local memories: { number } = {}
    local shared: any = nil
    if scenario.reuse then
        local ok_setup, state = pcall(scenario.setup, impl)
        if not ok_setup then
            return { error = "setup: " .. tostring(state) }
        end
        shared = state
    end
    for _ = 1, reps do
        local state: any = shared
        if not scenario.reuse then
            local ok_setup, fresh = pcall(scenario.setup, impl)
            if not ok_setup then
                return { error = "setup: " .. tostring(fresh) }
            end
            state = fresh
        end
        gc.full()
        local memory_before = gc.kb()
        local time_before = os.clock()
        local ok_run, run_error = pcall(scenario.run, impl, state)
        local elapsed = os.clock() - time_before
        if not ok_run then
            return { error = "run: " .. tostring(run_error) }
        end
        gc.full()
        local memory_after = gc.kb()
        if scenario.check then
            local problem = scenario.check(impl, state)
            if problem then
                return { error = "check: " .. problem }
            end
        end
        if elapsed < best then
            best = elapsed
        end
        table.insert(memories, (memory_after - memory_before) * 1024)
        state = nil
        gc.full()
    end
    return {
        time = best / scenario.ops,
        memory = median(memories) / scenario.ops,
    }
end

local function format_time(seconds: number): string
    local ns = seconds * 1e9
    if ns < 1000 then
        return string.format("%.1f ns", ns)
    elseif ns < 1e6 then
        return string.format("%.2f us", ns / 1e3)
    end
    return string.format("%.2f ms", ns / 1e6)
end

local function format_bytes(bytes: number): string
    if math.abs(bytes) < 10000 then
        return string.format("%.0f B", bytes)
    end
    return string.format("%.1f KB", bytes / 1024)
end

local function pad(text: string, width: number): string
    local length = utf8.len(text) or #text
    if length >= width then
        return text
    end
    return text .. string.rep(" ", width - length)
end

local function selected(scenario: Scenario, filter: string?): boolean
    if filter == nil or filter == "" then
        return true
    end
    local full = scenario.group .. "." .. scenario.name
    for part in string.gmatch(filter, "[^,]+") do
        if string.find(full, part, 1, true) then
            return true
        end
    end
    return false
end

local NAME_WIDTH = 46
local CELL_WIDTH = 24

--[[
	Runs all selected scenarios and prints one row per scenario (time) and, for memory
	scenarios, a second row (retained bytes). The ratio in parentheses is relative to the
	first implementation that produced a result for the row.
]]
local function run(impls: { Impl }, scenarios: { Scenario }, options: Options)
    local active: { Impl } = {}
    for _, impl in impls do
        if options.impls == nil or table.find(options.impls, impl.name) then
            table.insert(active, impl)
        end
    end

    local header = pad("scenario", NAME_WIDTH)
    for _, impl in active do
        header ..= pad(impl.label or impl.name, CELL_WIDTH)
    end
    print(header)
    print(string.rep("-", NAME_WIDTH + CELL_WIDTH * #active))

    local current_group = ""
    for _, scenario in scenarios do
        if not selected(scenario, options.filter) then
            continue
        end
        if scenario.group ~= current_group then
            current_group = scenario.group
            print(`[{current_group}]`)
        end

        local results: { Result } = {}
        for index, impl in active do
            if supports(impl, scenario) then
                results[index] = measure(impl, scenario, options.reps)
            else
                results[index] = { skipped = true }
            end
            if scenario.release then
                scenario.release(impl)
            end
            gc.full()
        end

        local unit = scenario.unit or "op"
        local time_row = pad(`{scenario.name} (/{unit})`, NAME_WIDTH)
        local base_time: number? = nil
        for index = 1, #active do
            local result = results[index]
            local cell: string
            if result.skipped then
                cell = "n/a"
            elseif result.error then
                cell = "ERROR"
            else
                local time = result.time :: number
                cell = format_time(time)
                if base_time == nil then
                    base_time = time
                else
                    cell ..= string.format(" (%.2fx)", time / (base_time :: number))
                end
            end
            time_row ..= pad(cell, CELL_WIDTH)
        end
        print(time_row)

        if scenario.memory then
            local memory_row = pad("  retained memory", NAME_WIDTH)
            local base_memory: number? = nil
            for index = 1, #active do
                local result = results[index]
                local cell: string
                if result.skipped or result.error then
                    cell = ""
                else
                    local memory = result.memory :: number
                    cell = format_bytes(memory)
                    if base_memory == nil then
                        base_memory = memory
                    elseif (base_memory :: number) > 0 then
                        cell ..= string.format(" (%.2fx)", memory / (base_memory :: number))
                    end
                end
                memory_row ..= pad(cell, CELL_WIDTH)
            end
            print(memory_row)
        end

        for index, impl in active do
            local result = results[index]
            if result.error then
                print(`  ! {impl.label or impl.name}: {result.error}`)
            end
        end
    end
end

return {
    run = run,
    measure = measure,
    supports = supports,
}
