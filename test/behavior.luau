--!strict
--[[
    The behavior specification of the library: what code that uses it can observe, one case per
    behavior, in groups by subject (the modules of test/cases/):

    - changes: changes of the ids of one entity (world:toggle);
    - queries: the terms of queries on five entities through every way of reading a query, a
      query without terms that select entities, world:each / world:children over disabled
      members, and the arity and nil values of queries;
    - loops: world:each and world:children snapshots at the boundaries of words, pages and
      blocks, their buffers across two worlds, and a frame of messages changed by hooks;
    - hooks: hooks and signals in reentrant operations, and errors raised by hooks;
    - relations: relations kept in sync by their own hooks, and a cascade that reaches an entity
      twice;
    - tracking: what one tick of change tracking records, batch operations on tracked ids, the
      depth of the change history, and creation tracking;
    - batches: batch operations whose matches cascade or leave the query, nested batch
      operations, and toggle_all;
    - worlds: two worlds in one process, and world:entity(id) over a live slot;
    - workload: the behavior that the reference workload relies on.

    A release passes every case; a change of one of them is a changed behavior of the release
    notes. A group is a module that returns function(spec: support.Spec) and adds its TESTs to
    the kit of the run (see test/cases/support.luau); a new group is added to `groups`.

    Run from the repository root: every group, the named ones, or against a saved release (a
    module path, which runs the same cases on it). "debug" makes every world that a case makes
    with ecs.world() a debug world, which checks every call (a case about a world without these
    checks asks for one with ecs.world(false)):
        luau test/behavior.luau
        luau test/behavior.luau -a tracking batches
        luau test/behavior.luau -a debug
        luau test/behavior.luau -a ../tmp/previous/mercs
]]

local api = require("@lib")
local testkit = require("@testkit")
local support = require("./cases/support")

local groups: { { name: string, run: (spec: support.Spec) -> () } } = {
    { name = "changes", run = require("./cases/changes") },
    { name = "queries", run = require("./cases/queries") },
    { name = "loops", run = require("./cases/loops") },
    { name = "hooks", run = require("./cases/hooks") },
    { name = "relations", run = require("./cases/relations") },
    { name = "tracking", run = require("./cases/tracking") },
    { name = "batches", run = require("./cases/batches") },
    { name = "worlds", run = require("./cases/worlds") },
    { name = "workload", run = require("./cases/workload") },
}

-- the arguments: names of groups, "debug", and a module path of the library to run them on
local ecs: support.Ecs = api
local selected: { [string]: boolean } = {}
local debug_worlds = false
for _, argument in { ... } do
    local name = tostring(argument)
    local group = false
    for _, entry in groups do
        if entry.name == name then
            group = true
        end
    end
    if group then
        selected[name] = true
    elseif name == "debug" then
        debug_worlds = true
    else
        ecs = (require :: any)(name)
    end
end
if debug_worlds then
    local library = ecs
    ecs = setmetatable({
        world = function(debug: boolean?): any
            return library.world(if debug == nil then true else debug)
        end,
    }, { __index = library }) :: any
end

local it = testkit.test()
local spec: support.Spec = {
    ecs = ecs,
    TEST = it.TEST,
    CASE = it.CASE,
    CHECK = it.CHECK,
    CHECK_EXPECT_ERR = it.CHECK_EXPECT_ERR,
}
for _, entry in groups do
    if next(selected) == nil or selected[entry.name] then
        entry.run(spec)
    end
end

-- a failed case must fail the process (CI reads the exit code)
assert(it.FINISH() == 0, "some behavior cases failed")
