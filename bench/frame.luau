--!strict
--!optimize 2
--[[
    The synthetic game frame (bench/frame_scene.luau) for jecs, the previous release of the
    library when tools/previous.sh has extracted it, and the current library in the luau CLI.
    Run from the repository root:
        luau -O2 bench/frame.luau
        luau -O2 --codegen bench/frame.luau
]]

local frame_scene = require("./frame_scene")
local previous = require("./previous")
local versions = require("./versions")

local libraries: { { any } } = { { versions.jecs, require("@jecs") } }
if previous then
    table.insert(libraries, { `mErCS {previous.version}`, previous.ecs })
end
table.insert(libraries, { versions.library, require("@lib") })

frame_scene(libraries)
