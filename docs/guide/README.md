# Guide

How mErCS works and how to use it. Every function is described in the API reference, which
is generated from the doc comments of `src/`: [mErCS](https://dubalda.github.io/mErCS/api/mErCS)
(the module, the builtin ids and types), [World](https://dubalda.github.io/mErCS/api/World),
[Query](https://dubalda.github.io/mErCS/api/Query) and the
[jabby adapter](https://dubalda.github.io/mErCS/api/jabby). The names follow
[jecs](https://github.com/Ukendio/jecs); [the comparison](../jecs-comparison/README.md) lists the
differences.

```luau
local ecs = require(ReplicatedStorage.mErCS)
local world = ecs.world()
```

## Contents

- [Worlds, entities and ids](#worlds-entities-and-ids)
- [Slot pools](#slot-pools)
- [Components and tags](#components-and-tags)
- [Queries](#queries)
- [Batch operations](#batch-operations)
- [Relationships](#relationships)
- [Hooks and signals](#hooks-and-signals)
- [Change tracking](#change-tracking)
- [Disabled entities](#disabled-entities)
- [Introspection and jabby](#introspection-and-jabby)
- [Types](#types)
- [Coming from jecs](#coming-from-jecs)

## Worlds, entities and ids

A world holds entities and the components, tags and pairs on them. `ecs.world(true)` makes a
debug world: changes of entities or ids that are not alive raise errors instead of being
ignored, which helps while code is written or migrated; every match list that a cached query
updates after a change (see [Queries](#queries)) is checked against a scan of the bitsets, and
a query that takes its list as it is checks that none of its ids changed.

Entity ids are numbers: slot + generation × 2^24. A deleted slot is reused with the next
generation, so an old handle of it is not alive anymore — `world:contains(e)` tells.
`world:delete(e)` removes every id of the entity, applies the cleanup policies of `e` used as
an id or a target (see [Relationships](#relationships)) and frees the slot; `world:clear(e)`
removes the ids and keeps the entity.

`world:component()` makes an id that can hold data (an entity with the `Component` trait);
the first 256 are the ids 1..256, then any entity id: there is no limit. Networked worlds can
split the id space with `world:range(first, last)`.

## Slot pools

Every component, tag and pair keeps a bitset over the entity slots, and a query reads 32 slots
per word. When a kind of entities is created among many others (creatures, each followed by
its hundreds of skills and effects), each creature sits alone in its word and its value page,
and a query over the creatures reads a word per creature. A slot pool keeps such a kind
together:

```luau
local creatures = world:pool()
local npc = creatures:entity() -- world:entity() for the skills does not scatter the creatures
world:set(npc, Model, model)
```

- `pool:entity()` takes a slot from blocks of 256 slots (one value page) reserved for the pool;
  `world:delete` gives the slot back to the pool, with the next generation.
- Pool entities are ordinary entities: every world call and every query accepts them.
- Each pool takes at least one block of 256 slots: pools are for kinds with many entities.
- The slots of a reserved block count as used for `world:exists`; `world:range` bounds the
  blocks as well.

## Components and tags

```luau
local Position = world:component() :: ecs.Component<Vector3>
local Frozen = world:entity() -- any entity can be used as a tag

local e = world:entity()
world:set(e, Position, Vector3.zero) -- adds the component, or replaces its value
world:add(e, Frozen)                 -- adds an id without a value
print(world:get(e, Position), world:has(e, Position, Frozen))
world:remove(e, Frozen)
```

- Adding or removing an id sets a bit and a value: the entity never moves, and nothing is
  created per combination of components.
- Only ids with the `Component` trait hold data; setting a value on a tag raises an error.
- `get` and `has` take up to 8 ids; `get_list` and `has_all` take any number.
- `world:each(id)` iterates the entities that have an id, and `world:remove_all(id)` removes
  it from all of them at once (about 20 ns per entity when the id has no `OnRemove` hook).

## Queries

```luau
local q = world:query(Position, Velocity) -- returned values: Position, Velocity
    :with(Alive)                            -- must also have
    :without(Frozen)                        -- must not have
    :any(Burning, Poisoned)                 -- must have at least one of these

for entity, position, velocity in q do end        -- for-in
q:each(function(entity, position, velocity) end) -- faster: a plain callback
local ok = q:has(entity)                          -- the entity matches the query
```

- A query never goes stale: the ids in it may be created and deleted at any time.
- `world:query(...)` inside a system is cheap. Queries of the same shape (returned ids,
  `with` and `without` ids) share one internal state, so a query written inline allocates
  only a small handle.
- A cached query whose matches are scattered keeps a list of them (up to 65 536 entities),
  grouped by value page, and iterates that. Between two loops it notes the slots whose ids
  changed and updates only those in the list, so a tag toggled on a few entities costs a few
  list edits, not a scan of the bitsets; many changes at once (batch operations, `remove_all`,
  hundreds of edits) make it scan again. A query that matches nothing keeps an empty list.
- Before a loop, a query with a list checks whether its ids changed since its previous loop.
  When no id of any cached query changed anywhere in the world since then, it skips that check
  as well: a loop over an empty list then costs a comparison.
- Queries with change filters or on pairs with a concrete target get their own state: call
  `q:cached()` on such a query when it is stored and iterated many times. `q:cached()` also
  prepares a query that has not been iterated yet (picks how it iterates and builds its list),
  so that its first loop costs no more than the next ones. An iteration of a stored query
  allocates nothing.
- Changing the current entity inside the loop is allowed, deleting it too. Changes of other
  entities may or may not be seen by the running loop; an entity deleted ahead of the loop
  (for example by a `ChildOf` cascade) may still be returned once, as a dead id with nil
  values: loops that delete other entities should check `world:contains(e)`.
- Loops over the same query may be nested, also when the inner loop changes the world, and a
  for-in loop may be left with `break` (the next update of the list copies it once). The
  iteration order is ascending by entity slot.

### The fast path: `spans` and `column`

`q:spans()` yields runs of matching slots: when `mask == 0xFFFFFFFF` every slot of
`first..last` matches, otherwise `first..last` is one 32-slot word and the set bits of `mask`
are the matching slots (`first + bit index`). `world:column(id)` returns the value pages of a
component: page `slot // ecs.PAGE_SIZE + 1`, index `slot % ecs.PAGE_SIZE + 1`;
`world:alive_table()[slot]` is the entity of a slot.

```luau
local positions = world:column(Position)
for first, last, mask in q:spans() do
    local page = positions[first // ecs.PAGE_SIZE + 1]
    local offset = (first // ecs.PAGE_SIZE) * ecs.PAGE_SIZE - 1
    if mask == 0xFFFFFFFF then
        for slot = first, last do
            local position = page[slot - offset]
        end
    else
        repeat
            local slot = first + bit32.countrz(mask)
            mask = bit32.band(mask, mask - 1)
            local position = page[slot - offset]
        until mask == 0
    end
end
```

A complete example with four columns is the `fast4` helper in `bench/impl_defs.luau`.

## Batch operations

One change to every entity that matches a query at the time of the call:

```luau
local n = world:query(Enemy):without(Dead):count()
world:query(Enemy):with(InExplosion):add_all(Stunned)
world:query(Enemy):with(Stunned):set_all(Velocity, ZERO) -- the same value for every match
world:query(Projectile):with(Expired):remove_all(Velocity)
world:query(Projectile):with(Expired):delete_all()
```

A component or tag without hooks is added, set or removed 32 entities at a time. Pairs and
ids with hooks (tracked ids included) go entity by entity, and every hook runs. Like an
iteration, a batch operation on a query with change filters consumes the changes it saw;
`count` does not.

## Relationships

```luau
local Likes = world:entity()
world:add(alice, ecs.pair(Likes, bob))
world:add(child, ecs.pair(ecs.ChildOf, parent))

print(world:target(alice, Likes), world:parent(child))
for liked in world:targets(alice, Likes) do end
for entity in world:query(ecs.pair(Likes, ecs.Wildcard)) do end -- any target of Likes
```

- A pair holds data when the relation is a component, or, for a tag relation, when the
  target is one. `world:target(e, R, index)` counts targets from 0, ordered by entity slot.
- `world:add(R, ecs.Exclusive)`: an entity has at most one target of `R`; adding another
  replaces it. `ChildOf` is exclusive.
- Cleanup policies decide what happens to the users of a deleted entity:
  `world:add(R, ecs.pair(ecs.OnDelete, ecs.Delete))` deletes the entities that have `R` when
  `R` is deleted, and `world:add(R, ecs.pair(ecs.OnDeleteTarget, ecs.Delete))` deletes the
  sources of a deleted target (`ChildOf` does this). The default is `Remove`: they lose the id
  or the pair.
- The record of a pair lives while an entity has the pair. The records that no entity has
  are freed in batches, once there are more than 256 of them and they are more than a quarter
  of all pair records (a pair added again before that keeps its record), and the records of
  a relation or a target are freed when it is deleted: nothing accumulates.
- Cascading deletes of any depth work. Past 100 nested levels the rest is queued: the queued
  entities lose the id being deleted at once (its `OnRemove` runs for them with
  `deleting = true`) and are deleted after the cascade.
- `ecs.pair(ecs.Wildcard, T)` (any relation to `T`) is built from the pairs of `T` the first
  time a query, `has`, `world:each` or `remove` reads it, and kept up to date from then on;
  until then the pairs of `T` cost nothing more. It returns the value of a pair only when a
  pair of `T` holds data.

## Hooks and signals

```luau
world:set(Health, ecs.OnAdd, function(entity, id, value) end)
world:set(Health, ecs.OnChange, function(entity, id, value) end)
world:set(Health, ecs.OnRemove, function(entity, id, deleting) end)

local disconnect = world:added(Health, function(entity, id, value) end) -- also changed / removed
disconnect()
```

- Hooks may be set and removed at any time; hooks set on a relation apply to all its pairs.
- A hook and the signal listeners of an id (change tracking included) all run, the hook
  first, whatever the order they were set in. They run after what the library itself does
  for its builtin ids (`Exclusive`, `OnAdd`, `OnChange`, `OnRemove`), which they cannot
  replace.
- Signals and change tracking take a component, a tag or a relation, which covers all its
  pairs: `world:added(Likes, fn)` runs for every pair of `Likes`. A pair (`ecs.pair(Likes, bob)`
  or a wildcard pair) raises an error.
- A listener may connect or disconnect listeners, itself included, while it runs: the change
  applies from the next event.
- `OnRemove` runs before anything is removed, so the other values of the entity can still be
  read; `deleting` is true when the entity itself is being deleted. When a hook removes
  another id of the entity, the `OnRemove` of that id runs once, from the removal.
- An error raised by a hook or a listener is not caught: the call that ran it stops half
  done. When it interrupts a delete, the cascade stops, and the world may no longer finish
  the cascades deeper than 100 levels queued afterwards or run the hooks of that entity
  again. Treat such an error as fatal for the world.

## Change tracking

Records additions, value changes and removals of an id per tick:

```luau
world:track(Health)

-- a system: sees what changed since its previous run (a new query sees the previous tick)
local damaged = world:query(Health):changed(Health):cached()
for entity, health in damaged do end

world:tick() -- once per frame: this frame's changes become visible
```

- `:added(id)`, `:changed(id)` and `:removed(id)` filter a query by what happened to a tracked
  id: added, its value set again (`world:set` of an existing value), or removed from an
  entity that stays alive.
- Each query keeps the first tick it has not seen yet: a system that runs less often sees
  the changes of every tick since its previous run, up to the last 8 ticks.
- A deleted entity is gone from every filter, and a new entity that reuses its slot starts
  clean.
- Untracked ids cost nothing. A tracked id costs a call per add, change or remove; deleting
  an entity costs extra only when it changed during the last 8 ticks.

## Disabled entities

`world:add(e, ecs.Disabled)` hides `e` from every query that does not name `Disabled` itself
(`:with(ecs.Disabled)` lists the disabled ones). The components stay in place;
`world:remove(e, ecs.Disabled)` shows the entity again.

## Introspection and jabby

`world:ids(e)` lists every id of an entity (components, tags and pairs), sorted. `ecs.Name`
names entities; the builtins are named (`"mercs.ChildOf"`).

[jabby](https://github.com/alicesaidhi/jabby), a debugger written against jecs internals,
connects through the adapter `mErCS.jabby` (`src/jabby.luau`, a child module that the library
itself never requires):

1. Replace the source of the `jecs` module of the jabby package (with Wally:
   `Packages/_Index/alicesaidhi_jabby@<version>/jecs`) with

   ```luau
   local mErCS = game:GetService("ReplicatedStorage").mErCS -- the ModuleScript
   return require(mErCS.jabby)(require(mErCS))
   ```

2. Attach every world before registering it:

   ```luau
   require(mErCS.jabby)(ecs).attach(world)
   jabby.register({ applet = jabby.applets.world, name = "World", configuration = { world = world } })
   ```

With Wally, `Packages.mercs` is only a link module without children: take the ModuleScript
of the library (the one with the `jabby` child) from the package folder in `Packages._Index`.

## Types

`world:component()` returns `Component<unknown>`; a cast gives it the data type, and then
`get`, `set` and queries are typed:

```luau
local Position = world:component() :: ecs.Component<Vector3>
local Health = world:component() :: ecs.Component<number>

local position: Vector3? = world:get(e, Position)
for entity, position, health in world:query(Position, Health) do end -- Vector3, number
```

Exported types: `ecs.Id<T>`, `ecs.Entity<T>`, `ecs.Component<T>`, `ecs.Pair<R, T>` (the
data of the relation, or of the target for a tag relation), `ecs.Query<T...>`, `ecs.World`,
`ecs.Pool`.
`test/types.luau` shows the typed API as a whole.

## Coming from jecs

The library has no functions that exist only for jecs code: the jecs helpers and the calls
that would do nothing here are not provided, and
[Migrating from jecs](../jecs-comparison/README.md#migrating-from-jecs) lists what to write instead.
What jabby reads from jecs internals lives in the [jabby adapter](#introspection-and-jabby).

`world:query(...)` returns a state that is cached already for a shared query (without a
concrete pair and without change filters); `query:cached()` on it only prepares it, like jecs
matches its archetypes in `cached()`. Hooks do not receive the `oldarchetype` argument of jecs
(there are no archetypes).
