--!strict
--!nolint DeprecatedApi
--[[
    Garbage collector access for the tests and benchmarks, in the luau CLI and in Roblox.

    - gc.full(): a full collection in the luau CLI. Roblox allows only collectgarbage("count"),
      so there it yields one frame instead (which also keeps long runs under the script
      timeout).
    - gc.kb(): the heap size in KB.
    - gc.allocated(body): net heap growth in bytes, after a full collection. A weak witness
      rejects intervals in which a GC cycle clears it. This is an allocation proxy, not a
      counter of allocator traffic: table resizing releases old storage, and a partial
      incremental GC cycle might not clear the witness yet.

    Usage:
        local gc = require("./gc")
        gc.full()
        local before = gc.kb()
]]

-- one untyped reference: the Roblox type definitions allow only the "count" option
local collect = collectgarbage :: any
-- the Roblox task library, nil in the luau CLI
local roblox_task = task :: any

local function full()
    if roblox_task then
        roblox_task.wait()
    else
        collect("collect")
    end
end

local function kb(): number
    return collect("count")
end

local function witness(): { {} }
    return setmetatable({ {} }, { __mode = "v" })
end

local function allocated(body: () -> ...any): number
    assert(roblox_task == nil, "allocation measurements require the standalone Luau CLI")
    full()
    local guard = witness()
    local before = kb()
    body()
    local bytes = (kb() - before) * 1024
    assert(guard[1] ~= nil, "GC crossed the allocation interval; reduce the batch and rerun")
    return bytes
end

return {
    full = full,
    kb = kb,
    allocated = allocated,
}
