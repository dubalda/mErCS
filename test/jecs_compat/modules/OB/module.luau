--!strict
--[[
    The addon modules/OB of jecs 0.11.0 for its tests (ob.luau): its monitor is query:monitor
    of mErCS, which returns the same object (added, removed, disconnect). Observers are not
    provided (see ob.luau).
]]
local mercs = require("../../../../src")

local function monitor(query: any): mercs.Monitor
    return query:monitor()
end

return {
    monitor = monitor,
}
