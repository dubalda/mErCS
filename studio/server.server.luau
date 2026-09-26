--!strict
-- Runs the mErCS check on the server (see studio/runner.luau), then lets the client
-- run it. A Script with the Server run context: it runs from ReplicatedStorage.
local run = require("./runner")

run()
local folder = script.Parent
assert(folder, "the check folder")
local done = folder:WaitForChild("ServerDone")
assert(done:IsA("BoolValue"), "ServerDone is a BoolValue")
done.Value = true
