--!strict
--[[
    The libraries compared by the Benchmarker files of this folder (*.bench.luau, for the
    Benchmarker plugin in Roblox Studio): jecs from the Wally dev packages and mErCS, and the
    names of their functions in Benchmarker, which carry the versions. The version of jecs is
    read from the folder of its Wally package (ukendio_jecs@<version>); the version of mErCS is
    written here: keep it in step with `version` in wally.toml.

    The folder sits in the Studio check place (studio/check.project.json) and in the
    Benchmarker place (benchmarker.project.json) at the same relative path as in the
    repository, so the requires below work there as written.

    The Benchmarker plugin requires a clone of each *.bench module (a clone has no parent),
    so the bench files reach this module from ReplicatedStorage:
        local libs = require(ReplicatedStorage:WaitForChild("mErCSCheck")
            :WaitForChild("bench"):WaitForChild("visual"):WaitForChild("libs")) :: any
        local world = libs.lib.world()
        -- Functions = { [libs.jecs_label] = ..., [libs.lib_label] = ... }
]]

local LIBRARY_VERSION = "0.2.2"

-- "jecs <version>" from the Wally index next to this folder (mErCSCheck.DevPackages._Index)
local function jecs_label(): string
    local visual = script.Parent
    local bench = if visual then visual.Parent else nil
    local check = if bench then bench.Parent else nil
    local packages = if check then check:FindFirstChild("DevPackages") else nil
    local index = if packages then packages:FindFirstChild("_Index") else nil
    if index then
        for _, child in index:GetChildren() do
            local version = string.match(child.Name, "^ukendio_jecs@(.+)$")
            if version then
                return `jecs {version}`
            end
        end
    end
    return "jecs"
end

return {
    jecs = require("../../DevPackages/jecs") :: any,
    lib = require("../../src") :: any,
    jecs_label = jecs_label(),
    lib_label = `mErCS {LIBRARY_VERSION}`,
}
