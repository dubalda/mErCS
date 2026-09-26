--!strict
--!optimize 2
--[[
	Benchmark entry point.

	Run from the repository root (all arguments are optional):
		luau -O2 bench/run.luau -a filter=query,pair impls=jecs,lib,best reps=5 n=131072
		luau -O2 --codegen bench/run.luau -a ...

	`filter` is a comma-separated list of substrings matched against "<group>.<name>".
]]

local harness = require("./harness")
local impls = require("./impls")
local build = require("./scenarios")

local options: harness.Options = { reps = 5 }
local n = 2 ^ 17

for _, argument in { ... } do
    local key, value = string.match(tostring(argument), "^(%w+)=(.*)$")
    if key == "filter" then
        options.filter = value
    elseif key == "impls" and value then
        local names: { string } = {}
        for name in string.gmatch(value, "[^,]+") do
            table.insert(names, name)
        end
        options.impls = names
    elseif key == "reps" then
        options.reps = tonumber(value) or options.reps
    elseif key == "n" then
        n = tonumber(value) or n
    end
end

print(`mErCS benchmarks: n = {n}, reps = {options.reps}, filter = {options.filter or "*"}`)
harness.run(impls, build(n), options)
