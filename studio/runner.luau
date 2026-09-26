--!strict
--[[
    The Roblox Studio check of mErCS: a smoke test against a model (test/fuzz.luau),
    the synthetic game frame (bench/frame_scene.luau, jecs and this library) and the matrix of
    single operations (bench/scenarios.luau). The place (studio/studio.project.json) mirrors
    the repository layout, so the same relative requires work in the luau CLI and in Roblox;
    jecs comes from the Wally dev packages (DevPackages/jecs).

    Build the place, open it and press Play: the server runs the check with native code (the
    library and jecs are --!native), then a client runs it. For the native code size run
    debug.dumpcodesize() from the Command Bar in the Server view.
]]

local RunService = game:GetService("RunService")

local lib = require("../src")
local jecs = require("../DevPackages/jecs")

return function()
    local side = if RunService:IsServer() then "server" else "client"
    print(`== mErCS check ({side}) ==`)

    -- the fuzz test runs when required
    local ok, problem = pcall(function()
        require("../test/fuzz")
    end)
    if not ok then
        warn(`fuzz: {problem}`)
    end
    task.wait()
    local frame_scene = require("../bench/frame_scene")
    frame_scene({ { "jecs", jecs }, { "lib", lib } })
    task.wait()

    local harness = require("../bench/harness")
    local defs = require("../bench/impl_defs")
    local build = require("../bench/scenarios")
    local impls = { defs.jecs(jecs), defs.library("lib", lib) }
    -- fewer entities than bench/run.luau (131 072) keep every step short enough for Studio
    local n = 32768
    print(`single operations: n = {n}, minimum of 3 runs (memory rows are approximate: no forced GC)`)
    harness.run(impls, build(n), { reps = 3 })
    print(`== mErCS check ({side}): done ==`)
end
