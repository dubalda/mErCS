--!strict
--[[
    The libraries compared by the Benchmarker files of this folder (*.bench.luau, for the
    Benchmarker plugin in Roblox Studio): jecs and ecr from the Wally dev packages and mErCS, and
    the names of their functions in Benchmarker, which carry the versions. The versions of jecs
    and ecr are read from the folders of their Wally packages (ukendio_jecs@<version>,
    centau_ecr@<version>); the version of mErCS is written here: keep it in step with `version`
    in wally.toml. ecr takes part in the four basic benchmarks of jecs (spawn, despawn, insertion,
    query).

    The folder sits in the Studio check place (studio/check.project.json) and in the
    Benchmarker place (benchmarker.project.json) at the same relative path as in the
    repository, so the requires below work there as written.

    The Benchmarker plugin requires a clone of each *.bench module (a clone has no parent),
    so the bench files reach this module from ReplicatedStorage:
        local libs = require(ReplicatedStorage:WaitForChild("mErCSCheck")
            :WaitForChild("bench"):WaitForChild("visual"):WaitForChild("libs")) :: any
        local world = libs.lib.world()
        -- Functions = { [libs.jecs_label] = ..., [libs.lib_label] = ..., [libs.ecr_label] = ... }
]]

local LIBRARY_VERSION = "1.0.0"

-- "<name> <version>" of a Wally package, from the index next to this folder
-- (mErCSCheck.DevPackages._Index)
local function package_label(name: string, pattern: string): string
    local visual = script.Parent
    local bench = if visual then visual.Parent else nil
    local check = if bench then bench.Parent else nil
    local packages = if check then check:FindFirstChild("DevPackages") else nil
    local index = if packages then packages:FindFirstChild("_Index") else nil
    if index then
        for _, child in index:GetChildren() do
            local version = string.match(child.Name, pattern)
            if version then
                return `{name} {version}`
            end
        end
    end
    return name
end

return {
    jecs = require("../../DevPackages/jecs") :: any,
    ecr = require("../../DevPackages/ecr") :: any,
    lib = require("../../src") :: any,
    jecs_label = package_label("jecs", "^ukendio_jecs@(.+)$"),
    ecr_label = package_label("ecr", "^centau_ecr@(.+)$"),
    lib_label = `mErCS {LIBRARY_VERSION}`,
}
