# mErCS and ecr

How mErCS 1.0.1 differs from [ecr](https://github.com/centau/ecr) 0.9.0, a sparse-set ECS for
Luau inspired by [EnTT](https://github.com/skypjack/entt): the design, the behaviour, the four
basic benchmarks of jecs measured in both, and how to move code over.

## Contents

- [Design](#design)
- [Differences in behaviour](#differences-in-behaviour)
- [Beyond ecr](#beyond-ecr)
- [When ecr is the better choice](#when-ecr-is-the-better-choice)
- [Performance](#performance)
- [Migrating from ecr](#migrating-from-ecr)

## Design

ecr keeps a pool per component type: a sparse array from the entity to an index, and dense
arrays of the entities and of the values. Adding or removing a component is a swap inside one
pool; a view walks the smallest pool of its components and checks the others for each entity;
a group (`registry:group(A, B)`) reorders the pools of its components so that the entities that
have all of them come first, in the same order, and its loop reads one dense range. A component
belongs to at most one group.

mErCS keeps, for every component, tag or pair, a bitset of the entities that have it, and the
values in pages indexed by the entity slot. A query ANDs the bitsets 32 entities at a time and
reads the values of the matches by slot.

| | ecr 0.9.0 | mErCS 1.0.1 |
|---|---|---|
| storage of a component | a pool: sparse array, dense entities, dense values | a bitset and value pages by entity slot |
| add / remove a component | a swap inside the pool: O(1) | a bit and a value: O(1) |
| a loop over several components | the smallest pool, the others checked per entity; a group: one dense range | the bitsets ANDed 32 entities at a time |
| entities alive at once | at most 65 535 | 2^24 slots |
| component types | declared before the registry, shared by all registries | `world:component()` per world, or `ecs.component()` before the worlds |
| relationships | none (an entity id may be stored as a value) | pairs, wildcards, `ChildOf`, `Exclusive`, cleanup policies |

## Differences in behaviour

- `registry:get` raises an error when the entity lacks the component (`try_get` returns nil);
  `world:get` returns nil.
- A component value cannot be nil in ecr; `world:set(e, C, nil)` keeps the component without a
  value in mErCS, and `world:add(e, C)` adds it without one.
- The listeners of ecr (`on_add`, `on_change`, `on_remove`) cannot change the registry or
  disconnect other listeners. The hooks and listeners of mErCS may change the world, other
  entities and the entity of their event; every addition and removal is notified once (see
  [Hooks and signals](../guide/README.md#hooks-and-signals)).
- During a loop over a view or a group, adding or removing components of other entities may
  invalidate the iterator in ecr. A query loop of mErCS may change the current entity and
  others (see [Queries](../guide/README.md#queries)).
- An observer of ecr (`registry:track`) returns the entities whose components were added or
  changed since its previous loop, and clears itself after the loop. mErCS tracks additions,
  changes and removals per tick (`world:track`, `world:tick`, the filters `:added`, `:changed`,
  `:removed`, and `:created` for new entities), and a query monitor reports the entities that
  enter or leave a query.
- `registry:clear(C)` removes a component from every entity, `registry:clear()` destroys every
  entity; `world:remove_all(C)` removes an id from every entity, and the batch operations of a
  query (`add_all`, `set_all`, `remove_all`, `delete_all`, `toggle_all`) change its matches.
- A component type of ecr is created before the registry and is the same in every registry; the
  ids of mErCS belong to their world, and pre-registered components (`ecs.component()`) are the
  same ids in every world made after them.
- ecr has handles (`registry:handle`), a context entity, queues (`ecr.queue`) and helpers that
  pack ids into buffers; mErCS has none of them.

## Beyond ecr

- Relationships: pairs `(R, T)` with data, wildcards `(R, *)` and `(*, T)`, `ChildOf` with its
  cascade, `Exclusive`, cleanup policies (`OnDelete`, `OnDeleteTarget`).
- Hooks and listeners that may change the world, query monitors.
- Change tracking by ticks, with the history of the last 7 ticks for systems that run less
  often.
- Batch operations on the matches of a query, `world:toggle`, OR terms (`query:any`),
  `ecs.Disabled`.
- Slot pools (`world:pool()`), explicit ids and id ranges for networked worlds
  (`world:entity(id)`, `world:range`).
- The API of jecs: code written for jecs, its test suite and the jabby debugger work with mErCS
  (see [jecs](jecs.md)).

## When ecr is the better choice

- A loop over a fixed set of components that a group serves: the group keeps the members in one
  dense range of every pool, which is the layout a loop reads fastest.
- Code built on EnTT idioms: registries, views, groups, handles, observers, queues.
- Networking that sends entity ids in buffers with the helpers of ecr.
- Worlds that never need relationships, hooks that change the world or change tracking by ticks.

## Performance

The four basic benchmarks that jecs ships with, in the luau CLI (`bench/basic.luau`, Luau 0.740,
measured on 2026-10-02): every library in a process of its own, five times in each mode, the
order of the libraries rotated; a case makes 300 calls, and a cell is the median of the five
medians of a call. Cells read "interpreter / native": `-O2` / `-O2 --codegen`. The ratio is the
time of mErCS divided by that of ecr; lower is better.

| Benchmark | ecr 0.9.0 | mErCS 1.0.1 | jecs 0.11.0 | mErCS / ecr |
|---|---|---|---|---|
| spawn: 1000 entities with 4 components | 844 / 369 µs | 679 / 440 µs | 867 / 706 µs | 0.80× / 1.19× |
| despawn: 1000 entities with 4 components and a tag | 870 / 349 µs | 500 / 247 µs | 380 / 373 µs | 0.57× / 0.71× |
| insertion: 8 components into 500 entities | 617 / 297 µs | 683 / 466 µs | 914 / 801 µs | 1.11× / 1.57× |
| query: 10 passes of a 4-component query over 4096 entities | 1.73 / 1.56 ms | 113 / 109 µs | 107 / 92.4 µs | 0.07× / 0.07× |
| the same, `query:each` | — | 59.2 / 34.8 µs | — | 0.03× / 0.02× |

- In native code ecr makes entities and gives them components faster: a component added is an
  append to the dense arrays of its pool, where mErCS sets a bit, a value in a page and the
  signature of the entity.
- mErCS deletes faster, and its query takes a fifteenth of the time of an ecr view: a view walks
  the smallest pool and checks the other pools for each of its entities, where mErCS ANDs the
  bitsets 32 entities at a time.

The [complete measurements](https://github.com/dubalda/mErCS/blob/main/bench/results/1.0.1-comparison.md)
include the ranges and the raw samples. The same four benchmarks in Roblox Studio are on
[Benchmarker](benchmarker.md). There ecr runs as bytecode: Roblox compiles a script to native
code only when it has the `--!native` comment, which the module of ecr 0.9.0 does not have and
those of jecs and mErCS do; the CLI compiles all three with `--codegen`.

## Migrating from ecr

| ecr | mErCS |
|---|---|
| `ecr.registry()` | `ecs.world()` |
| `local Health = ecr.component<<number>>()` | `local Health = world:component() :: ecs.Component<number>` (or `ecs.component()` before the worlds) |
| `local Stunned = ecr.tag()` | `local Stunned = world:entity()`: any entity is a tag |
| `registry:create()`, `registry:create(id)` | `world:entity()`, `world:entity(id)` |
| `registry:destroy(id)` | `world:delete(id)` |
| `registry:contains(id)` | `world:contains(id)` |
| `registry:set(id, C, value)` | `world:set(id, C, value)` |
| `registry:add(id, C)` (with a constructor) | `world:set(id, C, constructor())`; a tag: `world:add(id, Tag)` |
| `registry:patch(id, C, fn)` | `world:set(id, C, fn(world:get(id, C)))` |
| `registry:has(id, A, B)` | `world:has(id, A, B)` (up to 8 ids; `world:has_all` for more) |
| `registry:get(id, A, B)`, `registry:try_get(id, C)` | `world:get(id, A, B)`, `world:get(id, C)`: nil for a missing component |
| `registry:remove(id, A, B)` | `world:remove(id, A)`, `world:remove(id, B)` |
| `registry:clear(C)` | `world:remove_all(C)` |
| `registry:has_none(id)` | `#world:ids(id) == 0` |
| `registry:view(A, B):exclude(C)` | `world:query(A, B):without(C)` |
| `#registry:view(A)` | `world:query(A):count()` |
| `registry:group(A, B)` | `world:query(A, B)`: a query is shared and keeps its matches |
| `registry:track(A)` (an observer) | `world:track(A)` once, `world:query(A):added(A)` / `:changed(A)`, `world:tick()` every frame |
| `registry:on_add(C):connect(fn)` | `world:added(C, fn)`; `on_change`: `world:changed`, `on_remove`: `world:removed` |
| `registry:find(C, value)` | a loop over `world:query(C)` |
| `registry:storage(C)` | `world:column(C)` with `query:spans()` for the hottest loops |
| `ecr.name(components)` | `world:set(C, ecs.Name, "Health")` |

The listeners of mErCS run after the change for additions and before it for removals, like
those of ecr; they may change the world, so the work that ecr defers out of a listener (into a
queue or a later system) may stay in it.
