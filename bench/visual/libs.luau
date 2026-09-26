--!strict
--[[
    The libraries compared by the Benchmarker files of this folder (*.bench.luau, for the
    Benchmarker plugin in Roblox Studio): jecs from the Wally dev packages and mErCS.
    The folder sits in the Studio check place (studio/check.project.json) at the same
    relative path as in the repository, so the requires below work there as written.

    The Benchmarker plugin requires a clone of each *.bench module (a clone has no parent),
    so the bench files reach this module from ReplicatedStorage:
        local libs = require(ReplicatedStorage:WaitForChild("mErCSCheck")
            :WaitForChild("bench"):WaitForChild("visual"):WaitForChild("libs")) :: any
        local world = libs.lib.world()
]]

return {
    jecs = require("../../DevPackages/jecs") :: any,
    lib = require("../../src") :: any,
}
