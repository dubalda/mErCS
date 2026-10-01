# Guide

How mErCS works and how to use it. Every function is described in the API reference, which
is generated from the doc comments of `src/`: [mErCS](https://dubalda.github.io/mErCS/api/mErCS)
(the module, the builtin ids and types), [World](https://dubalda.github.io/mErCS/api/World),
[Query](https://dubalda.github.io/mErCS/api/Query) and the
[jabby adapter](https://dubalda.github.io/mErCS/api/jabby). The names follow
[jecs](https://github.com/Ukendio/jecs); [the comparison](../comparison/jecs.md) lists the
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
- [Query monitors](#query-monitors)
- [Change tracking](#change-tracking)
- [Disabled entities](#disabled-entities)
- [Introspection and jabby](#introspection-and-jabby)
- [Recipes](#recipes)
- [Types](#types)
- [Coming from jecs](#coming-from-jecs)

## Worlds, entities and ids

A world holds entities and the components, tags and pairs on them. `ecs.world(true)` makes a
debug world: changes of entities or ids that are not alive raise errors instead of being
ignored (a pair whose relation or target has a free slot raises an error in any world: a pair
keeps the slots of its elements), which helps while code is written or migrated; every match list that a cached query
updates after a change (see [Queries](#queries)) is checked against a scan of the bitsets, and
a query that takes its list as it is checks that none of its ids changed.

Entity ids are numbers: slot + generation × 2^24. A deleted slot is reused with the next
generation, so an old handle of it is not alive anymore — `world:contains(e)` tells.
`world:delete(e)` removes every id of the entity, applies the cleanup policies of `e` used as
an id or a target (see [Relationships](#relationships)) and frees the slot; `world:clear(e)`
removes the ids and keeps the entity.

`world:component()` makes an id that can hold data (an entity with the `Component` trait);
the first 256 are the ids 1..256, then any entity id: there is no limit. Networked worlds can
split the id space with `world:range(first, last)`: the new ids come after `first` (the first
one is `first + 1`, as in jecs) and stay below `last`. `world:entity(id)` makes any id alive,
also one of another world outside the range (a replicated entity); once deleted, its slot is not
given to a new entity of this world, so the ids of the two worlds never meet. A live entity of
another generation in the slot of `id` is deleted first (with a new entity that the hooks of
that delete make in the slot). An id made alive again starts without the components of its
old life and their hooks; its signal listeners hear it again. The next entity of the slot takes
the generation after `id`, or after the newest generation of the slot when `id` is an older
one: the ids of the newer generations stay dead. (A generation has 16 bits: a slot given
65 536 times gives its first ids again; they come without the hooks of their old life.)

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
  blocks as well, and the free slots that the pools hold already: a pool made before the range
  gives its new ids inside it, and its slots outside the range are not given again.

## Components and tags

```luau
local Position = world:component() :: ecs.Component<Vector3>
local Frozen = world:entity() -- any entity can be used as a tag

local e = world:entity()
world:set(e, Position, Vector3.zero) -- adds the component, or replaces its value
world:add(e, Frozen)                 -- adds an id without a value
print(world:get(e, Position), world:has(e, Position, Frozen))
world:remove(e, Frozen)
world:toggle(e, Frozen)              -- adds it when absent, removes it when present: true when added
```

- Adding or removing an id sets a bit and a value: the entity never moves, and nothing is
  created per combination of components.
- Only ids with the `Component` trait hold data; setting a value on a tag raises an error.
- The `Component` trait is given to an id before its first use (`world:component()` does it):
  whether the id holds data is decided when it is first used — as an id, a relation or a
  target. Adding `Component` to an id used already, or removing it from one (`world:remove`,
  `world:clear`), raises an error and changes nothing; `world:delete` deletes a used component
  as any id.
- `get` and `has` take up to 8 ids; `get_list` and `has_all` take any number.
- `world:toggle(e, id)` adds an id that the entity does not have (a component gets no value)
  and removes one that it has, with the hooks, signals and change tracking of `add` and
  `remove`, and returns true when it added the id; `query:toggle_all(id)` does it for every
  match (see [Batch operations](#batch-operations)).
- `world:each(id)` iterates the entities that have an id, and `world:remove_all(id)` removes
  it from all of them at once (about 20 ns per entity when the id has no `OnRemove` hook).
  `world:each` and `world:children` return the members of the id when the loop starts, in
  ascending slot order, whatever their number and their layout; they are collected into a
  buffer from a module pool, so a loop with a reusable buffer allocates only its iterator.
  The pool retains at most 16 buffers and 4 MiB of array values (plus table headers), shared
  across worlds; larger snapshots and excess concurrent buffers are collected after use.
  A loop abandoned with `break` leaves its buffer to GC. Nothing that changes
  during the loop changes what it returns: an entity that gets the id is not visited (the
  messages that a loop over messages makes wait for the next loop), one that loses it is
  visited, and one deleted before the loop reaches it is returned as a dead id: a loop that
  deletes other entities checks `world:contains`. Disabled entities are members too:
  `world:each` and `world:children` return them (see [Disabled entities](#disabled-entities)).

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
- A query selects its entities through its returned or required ids, an OR term (`any`) or a
  change filter. Excluded ids alone (`world:query():without(Dead)`) would match nothing, so
  using such a query — a loop, `each`, `count`, `has`, `cached`, a monitor or a batch
  operation — raises an error.
- `world:query(...)` inside a system is cheap. Queries of the same shape (returned ids,
  `with`, `without` and `any` ids) share one internal state from the second request of the
  shape on, so a query written inline allocates only a small handle. The first request of a
  shape gets a light state of its own and only marks the shape: a query requested once (an
  entity used as a term once, a query built at startup) keeps no shared state. A query that is
  kept and used again — iterated a second time, given a modifier or `:cached()` — takes the
  place of the mark and is shared from then on.
- A world shares the states of up to 1024 shapes. An entity used as a query term, directly or
  as the target of a pair (`world:query(Skill):with(caster)`,
  `world:query(Part, pair(ChildOf, model))`), makes a shape of its own (about 3 KB once it is
  shared); its shapes and marks are dropped when the entity is deleted, so they take no memory
  and no room afterwards. A pair with a target of a relation that is deleted keeps its shapes
  until the target is deleted: an entity that takes the slot of the relation has the same
  pairs. Many such entities alive at once can still use up the 1024 states: a query of a new
  shape then builds its own state on every call (several times the cost of a shared query),
  and a debug world (`ecs.world(true)`) warns once. For "the X of Y" lookups over many
  entities, prefer a pair and `world:each(ecs.pair(X, Y))`, which needs no query state.
- A cached query whose matches are scattered keeps a list of them (up to 65 536 entities),
  grouped by value page, and iterates that. Between two loops it notes the slots whose ids
  changed and updates only those in the list, so a tag toggled on a few entities costs a few
  list edits, not a scan of the bitsets. It re-checks the noted slots while that costs less than
  a pass over the bitsets: up to a quarter of the list or half of the words of its smallest
  term (at least 32, at most 1024 slots). A slot that a required id which did not change since
  the previous loop does not have is dropped at once, so the changes of a large tag cost the
  small queries that name it little; when that id has few words (a small tag), its words are
  tested against the changed bits of each word, gathered once for all the queries, so such a
  query costs a few word tests whatever the number of changes. More changes (and batch
  operations, `remove_all`) make the
  loop pass over the bitsets instead, and the list is built again at a loop after fewer
  changes. A query that matches nothing keeps an empty list.
- Before a loop, a query with a list checks whether its ids changed since its previous loop.
  When no id of any cached query changed anywhere in the world since then, it skips that check
  as well: a loop over an empty list then costs a comparison.
- Queries with change filters get their own state, and so do the first request of a shape
  and the shapes beyond the 1024: call `q:cached()` on such a query when it is stored and
  iterated many times. Written inline, such a query reuses the iterator of the world, so a call
  costs its state and its matches (under a
  microsecond when nothing matches); when its smallest term has at most 64 words (2048 slots),
  its matches are gathered in a loop over the words first, which costs far less than a pass
  of the span generator per match. `q:cached()` also prepares a query that has not been
  iterated yet (picks how it iterates and builds its list), so that its first loop costs no
  more than the next ones. An iteration of a stored query allocates nothing.
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
world:query(Enemy):with(InSight):toggle_all(Highlighted) -- removed where present, added elsewhere
```

A component or tag without hooks is added, set or removed 32 entities at a time. Pairs and
ids with hooks (tracked ids included) go entity by entity, and every hook runs; a hook that
deletes the id (or the relation or the target of the pair) of `add_all`, `set_all` or
`toggle_all` ends it, and the rest of the matches do not get it. Like an iteration, a batch
operation on a query with change filters consumes the changes it saw; `count` does not.

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
  replaces it. `ChildOf` is exclusive. Given to a relation that an entity has with several
  targets already, `Exclusive` raises an error and is not added. When a removal hook of the
  replaced pair adds yet another target, the outer add wins (a `set` with its value): that
  target is added and replaced in turn, with its hooks. A pair whose removal runs already (the
  pair of a deleted target) is left to that removal; the other pairs are replaced, so the
  entity keeps one target.
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
- A wildcard returns the value of one pair of each entity: `ecs.pair(R, ecs.Wildcard)` the value
  of the pair with the lowest target slot, `ecs.pair(ecs.Wildcard, T)` the value of the pair
  with the lowest relation slot (the order of the pair ids, as in jecs), also when that pair
  holds no value. The first query that returns the values of a wildcard gives it a copy of
  them in value pages of its own, kept up to date by every change of its pairs, so such a
  query reads them like a component, and `get` does too; the copy takes about 17 B per member
  and goes when no pair of the wildcard holds data any more.
- Memory (the luau CLI): a pair takes about 1 KB for its record (1.2 KB when it holds data),
  plus 85–115 B for each entity that has it; a target of pairs adds about 0.45 KB and a
  relation about 1.6 KB. The number of different pairs matters more than the number of
  entities that have them: 350 000 entities with one pair each keep about 18 MB with 700
  different pairs, and 50–65 MB with 22 400 (32 relations × 700 targets).

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
  applies from the next event, including the next holder removed while deleting a pair's
  target or relation.
- Once the last listener of an id disconnects (the listeners of a monitor too), the changes of
  the id cost what they cost before the first one connected.
- A listener of a deleted id hears nothing, not even the pairs of the relation that takes its
  slot, until the id is made alive again (`world:entity(id)`).
- `OnRemove` runs before anything is removed, so the other values of the entity can still be
  read; `deleting` is true when the entity itself is being deleted. When a hook removes
  another id of the entity, the `OnRemove` of that id runs once, from the removal. If a hook
  removes a pair from another holder or deletes that holder during target/relation cleanup,
  the outer cleanup skips that already removed membership. A holder that the cleanup has
  passed reads no value of the id; a hook that sets it again gives the holder the id anew (an
  addition, which the cleanup removes too). A hook that deletes the id itself ends its
  cleanup there: if a new entity takes the slot, its uses (its pairs, as the relation or the
  target) stay. The entities that the hooks give a
  deleted id while it is cleaned up are cleaned up too (they lose the id, or are deleted under
  a delete policy), and so are the uses of an entity that the hooks of its own delete or of
  its cascade make (the entity as an id for the first time, a pair with it as the relation or
  the target).
- A clear or a delete notifies every id of the entity once: the `OnRemove` hooks run for the
  ids the entity has, and a removal of an id whose hook has run in that clear does nothing (the
  clear removes it). An id that these hooks give the entity goes with the others, without its
  `OnRemove`; one that a hook of its cascade gives a deleted entity (a child that writes into
  its parent) is removed after the cascade, with its hooks. Hooks that never stop giving a
  deleted entity ids or uses raise an error after 100 rounds.
- A removal that the hooks of the same removal start again — the same id removed from the
  same entity, also by a delete or a clear of the entity — does nothing: the running removal
  completes it (an `OnRemove` that deletes its entity runs once, with `deleting` false). So a
  relation kept in sync by its hooks runs the hook of each side once, whichever side adds,
  removes, replaces (an exclusive relation) or is deleted:

  ```luau
  local Partner = world:entity()
  world:add(Partner, ecs.Exclusive)
  world:set(Partner, ecs.OnAdd, function(e, id)
      world:add(ecs.pair_second(world, id), ecs.pair(Partner, e)) -- added back: nothing runs
  end)
  world:set(Partner, ecs.OnRemove, function(e, id)
      local other = ecs.pair_second(world, id)
      if world:contains(other) then
          world:remove(other, ecs.pair(Partner, e)) -- removes the pair of e back: nothing runs
      end
  end)
  ```
- An error raised by a hook, a listener or a monitor callback is not caught: the call that
  ran it stops half done, and until the next `world:tick()` other calls of the same frame may
  be incomplete too (a removal of the id whose hook raised does nothing, a clear or a delete
  of that entity runs no hooks, a cascade deeper than 100 levels stops). `world:tick()` drops
  what the error left and deletes the entities that a stopped cascade had queued, so the
  frames after the error work again; a debug world reports it. What the frame of the error
  did half stays as it is: an entity whose delete raised is alive until it is deleted again,
  and a monitor or a `(*, T)` query may keep a member that left in that frame. Call
  `world:tick()` between frames, outside hooks, listeners and loops.

## Query monitors

```luau
local monitor = world:query(Model):with(Visible):without(Hidden):monitor()
monitor.added(function(entity) end) -- the entity started matching the query
monitor.removed(function(entity) end) -- it stops matching: its ids are still there
monitor.disconnect()
```

- A callback runs at the change that makes an entity enter or leave the query: an id of the
  query added or removed, an excluded id removed or added, `Disabled`, `world:clear`,
  `world:delete`, cleanup cascades and batch operations. There is one `added` per entry and one
  `removed` per exit. The entities that match when the monitor is made are members already:
  they get a `removed` when they leave.
- `removed` runs before the removal, so the values of the entity can still be read, in a
  delete too. `added` runs after the add; when the entity enters because an excluded id (or
  `Disabled`) is removed, it runs before that removal completes. An excluded id that a
  listener of its add removes again makes no exit and no entry. While an id is being removed
  (its listeners run), a monitor takes it as gone already: a term that a listener adds then
  makes the entry; an entity that a listener deletes leaves (at the latest when its slot is
  freed, its `removed` then getting the dead id), before a new entity can take the slot.
- An exclusive relation that replaces a pair (`ChildOf` moved to another parent) makes no exit
  and no entry in a query with the relation and any target (`ecs.pair(ecs.ChildOf, ecs.Wildcard)`).
- A monitor listens to the signals of the ids of its query (see [Hooks and signals](#hooks-and-signals)):
  a change of these ids, or the delete of an entity that has them, costs a listener call and a
  few bit tests; batch operations on them go entity by entity; changes of other ids cost
  nothing.
- The terms may be components, tags, pairs, `ecs.pair(R, ecs.Wildcard)`, OR terms and excluded
  ids. A term `ecs.pair(ecs.Wildcard, T)` and change filters raise an error.
- The monitor keeps the terms of the query as they are when it is made: `with`, `without` or
  `any` called on the query afterwards do not change it (the jecs addon copies the query too).
- A pair keeps the slots of its elements: when the relation of a pair term is deleted and
  another entity takes its slot, the query matches the pairs of that entity, but the monitor
  still listens to the deleted one. Make a new monitor after deleting a relation of its terms.
- A monitor made inside an `OnRemove` hook or a `removed` callback takes the entity being
  changed as it is before the removal: for the monitor it is a member that has left already.
- `added` and `removed` set one callback each (a new one replaces it, `nil` clears it);
  monitors of the same query are independent. The callbacks may change the world; an error in
  one stops the change that ran it, like an error in a hook.
- The functions are called with a dot, as in the jecs addon `modules/OB`: code that calls
  `OB.monitor(query)` calls `query:monitor()`.

The observer of `modules/OB` (a callback for every add or value change of an id of a query on
an entity that matches it) is a signal with a check of the query; the entries of other ids are
the `added` of a monitor:

```luau
local bars = world:query(Health):with(HealthBar)
local function update_bar(entity, id, health)
    if bars:has(entity) then
        -- show the health
    end
end
world:added(Health, update_bar)
world:changed(Health, update_bar)
```

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
  the changes of every tick since its previous run, up to the last 7 finished ticks (a ring
  of 8 ticks, the current one included). Older changes are gone: a system that runs less
  often than every 7 ticks (every 12, 30 or 60 frames) misses them; it collects the changes
  itself (see [Recipes](#recipes)).
- A deleted entity is gone from every filter, and a new entity that reuses its slot starts
  clean, also when a listener of the change deleted the entity.
- Untracked ids cost nothing. A tracked id costs a call per add, change or remove; deleting
  an entity costs extra only when it changed during the last 8 ticks (the current one
  included).

New entities are tracked for the whole world:

```luau
world:track_created()
local spawned = world:query(Model):created():cached() -- made since the previous loop, with Model now
for entity, model in spawned do end
```

- `world:track_created()` records the entities made from then on: `world:entity()`, a slot
  pool, and `world:entity(id)` when it makes an id alive. `:created()` filters a query by them
  with the ticks of the other change filters; `world:query():created()` returns all of them.
- A deleted entity is gone from the filter; a new entity in its slot is a new creation.
- A world that does not track creations pays a test per new entity; one that does pays a bit.

## Disabled entities

`world:add(e, ecs.Disabled)` hides `e` from every query that does not name `Disabled` itself
(`:with(ecs.Disabled)` lists the disabled ones), and so from the batch operations, monitors
and change filters of such queries. The components stay in place;
`world:remove(e, ecs.Disabled)` shows the entity again, and `world:toggle(e, ecs.Disabled)`
does either.

Only queries skip disabled entities: the calls about one entity or one id see them as they
are. `has`, `get`, `target` and `parent` read them, and `world:each(id)` and
`world:children(parent)` return them among the members of the id, so that a hierarchy can be
walked whole (to disable or delete a subtree). A loop that must skip them is a query:
`world:query():with(id)` or `world:query(ecs.pair(ecs.ChildOf, parent))`.

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

## Recipes

Small patterns built from the API, kept in the code that needs them.

**Changes collected until a system runs**, whatever the time between its runs (change filters
see the last 7 ticks): a set filled by signals, emptied by the system.

```luau
local dirty: { [ecs.Entity]: true } = {}
local function mark(entity) dirty[entity] = true end
world:added(Health, mark)
world:changed(Health, mark)

local bars = world:query(Health):with(HealthBar)
local function update_bars() -- every 30 frames
    for entity in dirty do
        if world:contains(entity) and bars:has(entity) then
            local health = world:get(entity, Health)
        end
    end
    table.clear(dirty)
end
```

The signals run for every change, so a set costs a call and an insert per change; changes made
while the set is walked are kept for the next run only if the loop walks a copy.

**A query over a list of entities** (the result of a spatial search, a selection): the matches
of the list, with their values.

```luau
local movers = world:query(Position, Velocity):without(Frozen)
for _, entity in nearby do
    if movers:has(entity) then
        local position, velocity = world:get(entity, Position, Velocity)
    end
end
```

`has` checks the entity is alive, has the required ids and none of the excluded ones, and is
not disabled, as an iteration of the query would.

**A value made when it is missing** (a table of its own per entity):

```luau
local function ensure<T>(entity: ecs.Entity, id: ecs.Component<T>, make: () -> T): T
    local value = world:get(entity, id)
    if value == nil then
        value = make()
        world:set(entity, id, value)
    end
    return value :: T
end

local inventory = ensure(player, Inventory, function() return { items = {} } end)
```

A component that is present with no value (`world:add`) also gets one here.

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
`test/types.luau` shows the typed API as a whole, and `test/typecheck/errors.luau` the misuses
that the types reject: a value of another type than the component's (also `nil` where the type
does not allow it), values read into variables or callbacks of another type, a string or a
number where an id goes, a typed id widened to take any value.

Two limits of the analyzer (the new solver) remain:

- A table literal passes where an untyped id goes: `world:add(e, {})` is not reported.
- `world:entity(id)` with an `id` typed `any` is reported as matching none of its overloads:
  give the id a type (`id :: ecs.Entity`).

## Coming from jecs

The library has no functions that exist only for jecs code: the jecs helpers and the calls
that would do nothing here are not provided, and
[Migrating from jecs](../comparison/jecs.md#migrating-from-jecs) lists what to write instead.
What jabby reads from jecs internals lives in the [jabby adapter](#introspection-and-jabby).

`world:query(...)` returns a state that is cached already for a shared query (without change
filters, from the second request of its shape, or kept and used again); `query:cached()` on it
only prepares it, like jecs matches its archetypes in
`cached()`. Hooks do not receive the `oldarchetype` argument of jecs
(there are no archetypes). The monitors of the jecs addon `modules/OB` are
[query monitors](#query-monitors) here (`query:monitor()` for `OB.monitor(query)`); its
observers are signals with a check of the query.
