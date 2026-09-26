--!strict
--[[
    Compatibility shim: the jecs test suite (tests.luau, copied from vendor jecs) requires
    "@jecs"; this module maps it onto mErCS and re-exports the types the suite names.
    - It is the module of the jabby adapter (src/jabby.luau), and its worlds come attached:
      the suite uses query:iter(), query:archetypes(), world.entity_index and
      entity_index_try_get, which the library leaves to the adapter.
    - mErCS has no bulk_insert / bulk_remove: they are written here as loops of
      world:set / world:remove (the replacement the migration guide gives), so the bulk cases
      of the suite keep checking set and remove.
]]
local lib = require("../../src")
local adapter = require("../../src/jabby")

export type Id<T = any> = lib.Id<T>
export type Entity<T = nil> = lib.Entity<T>
export type Component<T = any> = lib.Component<T>
export type Pair<First = any, Second = any> = lib.Pair<First, Second>
export type World = lib.World
-- jecs internals that only disabled tests use
export type Record = any

local jecs = adapter(lib)

local function new_world(debug: boolean?): World
    return jecs.attach(lib.world(debug))
end

local function bulk_insert(world: World, entity: Id<any>, ids: { Id<any> }, values: { any })
    for i, id in ids do
        world:set(entity, id, values[i])
    end
end

local function bulk_remove(world: World, entity: Id<any>, ids: { Id<any> })
    for _, id in ids do
        world:remove(entity, id)
    end
end

jecs.world = new_world
jecs.bulk_insert = bulk_insert
jecs.bulk_remove = bulk_remove

return jecs :: typeof(lib) & {
    bulk_insert: typeof(bulk_insert),
    bulk_remove: typeof(bulk_remove),
    is_tag: (world: World, id: Id<any>) -> boolean,
    entity_index_try_get: (entity_index: any, entity: Id<any>) -> any,
}
