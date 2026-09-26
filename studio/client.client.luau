--!strict
-- Runs the mErCS check on the client once the server has finished (see
-- studio/runner.luau): both at once would share the CPU in a Studio play test. A Script with
-- the Client run context: it runs from ReplicatedStorage.
local run = require("./runner")

local folder = script.Parent
assert(folder, "the check folder")
local done = folder:WaitForChild("ServerDone")
assert(done:IsA("BoolValue"), "ServerDone is a BoolValue")
while not done.Value do
    done.Changed:Wait()
end
run()
