--!strict
--!optimize 2
--[[
    The synthetic game frame (bench/frame_scene.luau) for jecs and this library in the luau
    CLI. Run from the repository root:
        luau -O2 bench/frame.luau
        luau -O2 --codegen bench/frame.luau
]]

local frame_scene = require("./frame_scene")

frame_scene({
    { "jecs", require("@jecs") },
    { "lib", require("@lib") },
})
