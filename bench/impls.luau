--!strict
--!optimize 2
--[[
    Implementations compared by the benchmark matrix (bench/run.luau): jecs, the previous
    release of the library when tools/previous.sh has extracted it (bench/previous.luau), and
    the current library. Each entry provides the module with the jecs-compatible API plus a few
    helpers, see bench/impl_defs.luau (jecs gets its addon modules/OB for the monitors); the
    keys for the `impls` option are jecs, previous and lib, the column headers carry the
    versions.

    Usage:
        local impls = require("./impls")
]]

local harness = require("./harness")
local defs = require("./impl_defs")
local previous = require("./previous")
local versions = require("./versions")

type Impl = harness.Impl

local list: { Impl } = { defs.jecs(require("@jecs"), versions.jecs, require("@jecs_ob")) }
if previous then
    table.insert(list, defs.library("previous", previous.ecs, `mErCS {previous.version}`))
end
table.insert(list, defs.library("lib", require("@lib"), versions.library))

return list
