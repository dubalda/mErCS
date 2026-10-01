--!strict
--!optimize 2
--# selene: allow(empty_loop) -- iteration is measured for its cost
--[[
    Additional reference profiles used by workload.luau: the small interpreter client with
    usually empty marker queries, and module-level snapshot buffers after temporary worlds.
    Run each profile in its own process so retained buffers are included in the heap delta.
    run(ecs, profile, emit) reports rows through emit(test, case, scale, unit, value).
]]

local gc = require("./gc")
type Emit = (test: string, case: string, scale: string, unit: string, value: number) -> ()

local function client(ecs: any, emit: Emit)
    gc.full()
    local base = gc.kb()
    local world = ecs.world()
    local tag = world:entity()
    local markers: { any } = {}
    local queries: { any } = {}
    local entities: { any } = {}
    local changes = 0
    for i = 1, 15 do
        local marker = world:component()
        markers[i] = marker
        queries[i] = world:query(marker):with(tag):cached()
        if i <= 3 then
            world:added(marker, function()
                changes += 1
            end)
            world:removed(marker, function()
                changes += 1
            end)
        end
    end
    for i = 1, 300 do
        entities[i] = world:entity()
        world:add(entities[i], tag)
    end
    local frame = 0
    local function stored(): number
        local visits = 0
        for _, query in queries do
            for _ in query do
                visits += 1
            end
        end
        return visits
    end
    local function tick()
        frame += 1
        -- Five replicated entities per second; one marker present for every other frame.
        if frame % 12 == 0 then
            local at = frame // 12 % #entities + 1
            world:delete(entities[at])
            entities[at] = world:entity()
            world:add(entities[at], tag)
        end
        local e = entities[1]
        if frame % 2 == 0 then
            world:remove(e, markers[1])
        else
            world:add(e, markers[1])
        end
        stored()
    end
    gc.full()
    emit("P8", "client heap after build", "client", "MB", (gc.kb() - base) / 1024)
    for _ = 1, 120 do
        tick()
    end
    local loops = 12000
    local started = os.clock()
    for _ = 1, loops do
        stored()
    end
    emit("P4", "15 usually empty marker queries", "client", "µs per frame", (os.clock() - started) / loops * 1e6)
    started = os.clock()
    for _ = 1, 6000 do
        tick()
    end
    emit("P7", "client frame with replication", "client", "µs per frame", (os.clock() - started) / 6000 * 1e6)
    local bytes = gc.allocated(function()
        for _ = 1, 60 do
            tick()
        end
    end)
    emit("P9", "client frame heap growth (GC checked)", "client", "bytes", bytes / 60)
    for window = 1, 3 do
        for _ = 1, 3000 do
            tick()
        end
        gc.full()
        emit("P8", `client heap after {window * 3000} more frames`, "client", "MB", (gc.kb() - base) / 1024)
    end
    assert(changes > 0, "the client profile must dispatch marker changes")
end

local function buffers(ecs: any, emit: Emit)
    gc.full()
    local base = gc.kb()
    local function temporary_world()
        local world = ecs.world()
        local tag = world:entity()
        for _ = 1, 100000 do
            world:add(world:entity(), tag)
        end
        local held: { () -> any } = {}
        local first_bytes = gc.allocated(function()
            held[1] = world:each(tag)
        end)
        emit("P9", "heap growth of first 100000-member snapshot", "buffers", "bytes", first_bytes)
        for i = 2, 17 do
            held[i] = world:each(tag)
        end
        for _, iterator in held do
            for _ in iterator do
            end
        end
    end
    temporary_world()
    gc.full()
    emit("P8", "retained after 17 dense snapshots and world GC", "buffers", "MB", (gc.kb() - base) / 1024)
    -- A second world uses the module's buffers, then abandons its loops (break).
    local function abandoned_world()
        local world = ecs.world()
        local tag = world:entity()
        for _ = 1, 100 do
            world:add(world:entity(), tag)
        end
        for _ = 1, 20 do
            for _ in world:each(tag) do
                break
            end
        end
    end
    abandoned_world()
    gc.full()
    emit("P8", "retained after abandoned snapshots and world GC", "buffers", "MB", (gc.kb() - base) / 1024)
end

local function run(ecs: any, profile: string, emit: Emit)
    if profile == "client" then
        client(ecs, emit)
    elseif profile == "buffers" then
        buffers(ecs, emit)
    else
        error(`unknown workload profile: {profile}`)
    end
end

return { run = run }
