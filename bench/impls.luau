--!strict
--!optimize 2
--[[
    Implementations compared by the benchmark matrix (bench/run.luau): jecs and this library.
    Each entry provides the module with the jecs-compatible API plus two helpers, see
    bench/impl_defs.luau.

    Usage:
        local impls = require("./impls")
]]

local harness = require("./harness")
local defs = require("./impl_defs")

type Impl = harness.Impl

local list: { Impl } = {
    defs.jecs(require("@jecs")),
    defs.library("lib", require("@lib")),
}

return list
