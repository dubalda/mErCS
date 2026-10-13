# mErCS and jecs

How mErCS 1.1.0 differs from [jecs](https://github.com/Ukendio/jecs) 0.11.0: the design,
the behaviour, when jecs is the better choice, the numbers, and how to move code over. The
comparison of 1.1.0 with the previous release is on [its own page](previous-release.md), the
Benchmarker screenshots on [Benchmarker](benchmarker.md).

## Contents

- [Design](#design)
- [Compatibility](#compatibility)
- [Differences in behaviour](#differences-in-behaviour)
- [Beyond jecs](#beyond-jecs)
- [When jecs is the better choice](#when-jecs-is-the-better-choice)
- [Performance](#performance)
- [Migrating from jecs](#migrating-from-jecs)

## Design

An archetype ECS (jecs, flecs) stores the entities with the same set of components together.
That makes iteration fast, but every add or remove moves the entity to another archetype and
copies all its columns, every new combination of components creates an archetype that lives
until someone cleans it up, and relationships to many targets create an archetype per target.

mErCS keeps, for every component, tag or pair, a bitset of the entities that have it,
and the values in pages indexed by the entity slot. A query ANDs the bitsets 32 entities at a
time and walks the set bits.

|  | jecs 0.11.0 | mErCS 1.1.0 |
|---|---|---|
| add / remove a component | moves the entity, copies all its columns: O(components) | sets a bit and a value: O(1) |
| new combination of components | creates an archetype (kept until `world:cleanup()`) | nothing to create |
| pair with many targets | an archetype per target | one small record per pair, freed when unused (in batches) or with its target |
| ids per `get` / `has` call | 4 | 8, any number with `get_list` / `has_all` |
| memory per entity with 4 components | 320 B | 131 B |
| deep hierarchies | the cascade recurses: stack overflow at about 6000 levels | any depth (past 100 levels the rest is queued) |

## Compatibility

The API follows jecs: worlds, entities, components, tags, pairs, wildcards, `Exclusive`,
cleanup policies, hooks, signals, `Name`, pre-registration (`jecs.component()` /
`jecs.tag()` / `jecs.meta()`), the `ECS_*` helpers and the builtin ids.

The 1.1.0 CLI check passes the jecs test suite (`test/jecs_compat/`) in both modes:
125 of 125 applicable cases pass (its `bulk_insert` / `bulk_remove` come from a test shim, as loops of `set` /
`remove`). The cases that inspect jecs internals (archetype records, edges, the entity
visualiser) are not applicable and are listed in `test/jecs_compat/README.md`.

## Differences in behaviour

- No archetypes: `world:cleanup()`, `query:fini()` and the ids `ArchetypeCreate` /
  `ArchetypeDelete` do not exist (there is nothing for them to do), hooks do not get an
  `oldarchetype` argument.
- The jecs helpers `World.new`, `w`, `bulk_insert` / `bulk_remove`, `new` / `new_w_id` /
  `new_low_id`, `query:iter()` and `is_tag` are not provided: they would only repeat native
  calls (see [Migrating from jecs](#migrating-from-jecs)).
- jecs internals (`query:archetypes()`, `world.entity_index`, `entity_index_try_get`) are
  not provided either; the [jabby adapter](../guide/README.md#introspection-and-jabby) gives the debugger what it reads.
- An uncached query can be iterated again (jecs drains it after the first loop).
- `get` / `has` take up to 8 ids positionally (jecs: 4).
- The iteration order is ascending by entity slot, not by archetype.
- Builtin ids after `Name` have other numbers: `Exclusive` is 268 (jecs: 270), `Disabled`
  (not in jecs) 269, `Rest` 270 (jecs: 271).
- The jecs addon `modules/OB` reads archetypes and does not work here. Its monitors are
  `query:monitor()`, which returns the same `added` / `removed` / `disconnect` (the 42 monitor
  cases of the tests of the addon pass, `test/jecs_compat/ob.luau`), and its observers are
  signals with a check of the query (see the [guide](../guide/README.md#query-monitors)). A
  monitor of mErCS does not make an entity leave and enter a query with an exclusive relation
  and any target when the relation replaces a pair; it takes no term `(*, T)`.
- Setting a hook after connecting signals keeps the signals (in jecs the hook replaces them),
  and `world:get(id, ecs.OnAdd)` returns the hook, not the signal dispatcher.
- A signal listener that disconnects itself while it runs does not make the next listener
  miss the event (in jecs it does).
- Signals and change tracking take a component, a tag or a relation (for all its pairs); a
  pair raises an error (jecs does not support pairs there either).
- Changing the world during a loop: the current entity may be changed or deleted in both.
  jecs may visit an entity twice when others are removed from its archetype; here an entity
  deleted ahead of the loop may be returned once as a dead id with nil values.
- `query:cached()` on a query that has not been iterated yet prepares it (picks how it
  iterates and builds its match list), as jecs matches its archetypes there; on a shared query
  (`world:query(...)` without change filters) it does nothing else: such a query is cached
  already. A query shape is shared from its second request; the first request gets a state of
  its own, which becomes the shared one when it is used again (a second loop, a modifier,
  `cached()`).
- A wildcard returns the value of one pair of each entity: `(R, *)` the pair with the lowest
  target slot, `(*, T)` the pair with the lowest relation slot (jecs: the first such pair in
  the type of the archetype, which is sorted by id).
- `world:each` and `world:children` return the members of the id when the loop starts, in
  ascending slot order: an entity that gets the id during the loop is not visited, and one
  deleted before the loop reaches it is returned as a dead id (jecs walks the rows of its
  archetypes backwards).
- `world:exists(e)` is also true for a slot reserved by a slot pool and not handed out yet.
- A query with excluded ids alone (`world:query():without(A)`) raises an error when it is used:
  it would match nothing. A query needs a returned or required id, an OR term or a change
  filter.
- A removal that the hooks of the same removal start again (the same id removed from the same
  entity) does nothing, so a relation kept in sync by its hooks runs the hook of each side once
  (in jecs such hooks remove the pair back and forth until the stack overflows).
- The `Component` trait added to an id used already, or removed from a used one, raises an
  error and changes nothing. jecs also decides at the first use of an id whether it holds data,
  and keeps that decision without an error when the trait changes later.
- `world:remove(e, ecs.pair(R, ecs.Wildcard))` removes every pair `(R, *)` of the entity, and
  `ecs.pair(ecs.Wildcard, T)` every pair with the target `T`; `add` and `set` raise an error for
  a wildcard pair. jecs forbids a wildcard pair in all three: `jecs.world(true)` raises an
  error, and a world without the check leaves the pairs in place and breaks the row of the
  entity in its archetype.

## Beyond jecs

- `query:each(fn)` — a callback per match; see the measured [query loops](#queries-per-entity-or-match).
- `query:any(...)` — OR terms.
- Batch operations: `query:count`, `add_all`, `set_all`, `remove_all`, `delete_all`,
  `toggle_all`, and `world:remove_all(id)`.
- `world:toggle(e, id)`: adds an absent id, removes a present one, and tells which it did.
- `world:expect(e, id)`: the value of an id that the entity must have, typed without `nil`; when
  there is no value, an error that names the entity and the id instead of `nil`.
- Change tracking by ticks: `world:track`, `world:tick`, the `:added` / `:changed` /
  `:removed` filters, and new entities with `world:track_created` and `:created`.
- `ecs.Disabled`: entities hidden from queries without removing their components.
- Slot pools: `world:pool()` and `pool:entity()` keep a kind of entities created among many
  others (creatures among their skills) in slots of its own, so the bitsets and value pages of
  what only they have stay dense.
- `world:ids(e)`, a debug world (`ecs.world(true)`, which also checks the match lists of
  cached queries against their bitsets), `query:spans()` with `world:column(id)`.

## When jecs is the better choice

jecs keeps the entities of one set of ids together, in the rows of an archetype; mErCS keeps a
bitset per id and the values in pages indexed by the entity slot. Each layout has cases that
the other cannot match. The numbers compare jecs 0.11.0 and mErCS 1.1.0: the time or memory of
mErCS divided by that of jecs, "interpreter / native" (see [Performance](#performance)).

### What only jecs has

- roblox-ts: jecs has TypeScript declarations (`@rbxts/jecs`); mErCS is a Luau module only.
- An observer object: the observer of the addon `modules/OB` calls back for every add or value
  change of an id of a query on an entity that matches it. In mErCS a signal with
  `query:has` does that; the monitors of the addon are `query:monitor()`.
- Archetypes as an API: `query:archetypes()` with the columns of each archetype, the ids
  `ArchetypeCreate` / `ArchetypeDelete`, and the tools that read them (the entity visualiser
  of jecs, for one). mErCS gives the value pages of a query through `query:spans()` and
  `world:column(id)`.
- The original of the API: the documentation and examples of jecs, and the tools made for it,
  apply to it as they are. mErCS follows the API, runs the jecs test suite and adapts jabby,
  with the differences listed in [Differences in behaviour](#differences-in-behaviour).

### Where jecs has a layout advantage

These measurements expose costs of the layouts. A slot pool helps when entities of a kind
can be allocated together. Ratios are interpreter / native; memory medians agree across modes.

| Case | jecs | mErCS | mErCS / jecs |
|---|---|---|---|
| Cached queries over scattered entities, memory per query | 5803 B | 263 KiB | 46.37× |
| Sparse components: 8 on 1 entity in 64, memory per entity | 170 B | 660 B | 3.90× |
| Eight kinds created in turn, 3 values read | rows of each kind stay together | values follow slot layout | for-in 2.24× / 2.21×; `each` 1.52× / 1.49×; `each` with a pool 0.86× / 0.61× |
| Delete entities with 100 targets of a relation | remove one archetype row | clear the bit of each pair record | 2.08× / 1.49× |

### Where jecs is faster than mErCS 1.1.0

The cases below compare measured medians. Consult the ranges in the full report for small
differences; these ratios do not establish a statistically significant difference on their own.

- Two inline queries per new caster: 2.34× / 2.08×;
  memory retained per caster: 377 B
  in mErCS, 0 B in jecs.
  Four inline queries using an entity term followed by its deletion:
  3.05× / 3.09×.
- A cached query over scattered entities, built and passed once:
  2.37× / 1.35×.
- For-in over a sparse match (1%): 2.02× / 1.87×;
  `query:each` against the jecs for-in: 1.01× / 0.87×.
- For-in with `without`: 1.22× / 1.19×.
- Adding the first component: 1.46× / 1.18×.
- Moving a child to another parent without a monitor:
  1.46× / 1.21×.
- In the sparse world without a slot pool, `Run` toggled before a pass:
  1.26× / 1.10×; a tag added and removed around passes:
  1.62× / 1.19×.

Other interpreter costs, including multi-id access, entity deletion and query monitors,
are listed in the operation tables. Queries with a reused shape avoid the cost of a new
entity term: a concrete pair per call is 0.67× / 0.66×,
and `query(A, pair(ChildOf, parent))` per parent is
0.62× / 0.58×.

### When to choose jecs

- A roblox-ts project.
- Code built on `query:archetypes()` or on tools that read archetypes.
- Dozens of cached queries over entities whose composition rarely changes, with a tight memory
  budget: the query caches of jecs stay small whatever the number of entities.
- Many kinds of entities created together (a creature with its skills and items) when a slot
  pool per kind does not fit the code, and the systems loop with for-in.
- Components on a small share of the entities of a very large world, when memory matters more
  than the cost of adding and removing them.
- Queries built on every call with new entities as terms (a query per new entity), when they
  take a large part of the frame.

For the measured trade-offs in structural changes, relationships, long sessions and memory
per entity, see [Design](#design), [Beyond jecs](#beyond-jecs) and [Performance](#performance).

## Performance

Benchmarks in `bench/`, measured on 2026-10-13 with Luau 0.740: jecs 0.11.0 (the pinned
Wally dev package) and mErCS 1.1.0. Cells read "interpreter / native": `-O2` / `-O2 --codegen`.
Ratios are the median time of mErCS divided by that of jecs; lower is better.

Each library runs in its own process, five times in each mode (fifteen for the synthetic
frame), with the order rotated. The tables show medians of those runs. A matrix run takes the minimum of three timed
repetitions and the median retained-memory delta after full GC. The synthetic-frame helper
runs three batches per query style and returns the frame median from the batch with the
lowest minimum frame time. Small differences between medians should be read with their ranges.

The [complete measurements](https://github.com/dubalda/mErCS/blob/main/bench/results/1.1.0-comparison.md)
include min–max ranges, hashes, commands and
[raw samples](https://github.com/dubalda/mErCS/blob/main/bench/results/1.1.0-comparison.json),
with the previous release, 1.0.1, measured in the same runs (see
[1.1.0 and 1.0.1](previous-release.md)). The screenshots of the Benchmarker plugin in Roblox
Studio are on [Benchmarker](benchmarker.md).

### A synthetic game frame

`bench/frame.luau`: 3000 units with 2 attachments each follow their parents, 60 projectiles
spawn and expire per frame, damage uses a one-frame tag, 5 % of the units switch AI state
tags; plain for-in loops, the same code for all three. The median frame time; the queries are
written inline in every frame, or created once and `:cached()` (the recommended jecs style):

| Mode / queries | jecs 0.11.0 | mErCS 1.1.0 | 1.1.0 / jecs |
|---|---|---|---|
| interpreter, inline queries | 6.8 ms | 2.72 ms | 0.40× |
| interpreter, cached queries | 6.33 ms | 2.79 ms | 0.44× |
| native, inline queries | 5.93 ms | 1.95 ms | 0.33× |
| native, cached queries | 5.53 ms | 1.93 ms | 0.35× |

### A long session

`bench/leak.luau`: 5 of 200 enemies die and respawn every frame, 10 % of 500 units retarget
a living enemy through a pair `(Targeting, enemy)` and switch a state tag. Each cell is the
median of five isolated runs: heap growth since the start, and time per frame in the preceding
1000-frame window (including checkpoint GC). Both execution modes are measured:

| Mode | Frame | jecs 0.11.0 | jecs 0.11.0 + cleanup every 600 frames | mErCS 1.1.0 |
|---|---|---|---|---|
| interpreter | 1000 | +3.57 MiB, 0.216 ms | +3.60 MiB, 0.221 ms | +0.33 MiB, 0.097 ms |
| interpreter | 3000 | +8.98 MiB, 0.233 ms | +8.80 MiB, 0.240 ms | +0.33 MiB, 0.097 ms |
| interpreter | 5000 | +15.38 MiB, 0.230 ms | +15.66 MiB, 0.243 ms | +0.32 MiB, 0.099 ms |
| native | 1000 | +3.57 MiB, 0.198 ms | +3.60 MiB, 0.199 ms | +0.33 MiB, 0.066 ms |
| native | 3000 | +8.98 MiB, 0.210 ms | +8.80 MiB, 0.218 ms | +0.33 MiB, 0.065 ms |
| native | 5000 | +15.38 MiB, 0.212 ms | +15.66 MiB, 0.218 ms | +0.32 MiB, 0.063 ms |

The jecs heap continues to grow in this 5000-frame session, including with cleanup every
600 frames. The mErCS heap remains near its warmed checkpoint values. This describes the
measured session; it is not a guarantee for every entity layout or duration.

### Query cases

Five cases where an archetype ECS is expected to be at its best (`bench/query_cases.luau`,
and the `query cases` group of `bench/run.luau`). jecs runs for-in loops over cached queries;
mErCS builds the same worlds and runs the same loops through `query:each`, which replaces a
for-in loop fully when it does not break early. Time of one pass:

| Case | jecs 0.11.0 | mErCS 1.1.0 | 1.1.0 / jecs |
|---|---|---|---|
| Scattered after recycling | 131 / 111 µs | 95.9 / 67.9 µs | 0.73× / 0.61× |
| Churn on a queried tag, 1 toggle per pass | 398 / 303 µs | 320 / 213 µs | 0.80× / 0.70× |
| Churn on a queried tag, 100 toggles per pass | 279 / 240 µs | 284 / 196 µs | 1.02× / 0.82× |
| Read 4 components | 2.04 / 1.5 ms | 1.37 ms / 691 µs | 0.67× / 0.46× |
| `(*, T)` with churn | 840 / 722 µs | 558 / 350 µs | 0.66× / 0.48× |
| Usually empty | 72.9 / 64.4 ns | 44 / 28.8 ns | 0.60× / 0.45× |

- Scattered after recycling: 50 000 entities with random subsets of 8 components, then
  100 000 deletes and respawns; a pass of a 4-component query (3125 matches).
- Churn on a queried tag: 70 000 entities with `Position`, every 7th with `Velocity`; the
  query of both without `Stunned`, `Stunned` toggled on 1 or 100 movers before each pass. The
  query re-checks the changed slots only; list edits and the cost of the toggles are both
  included in the measurements above.
- Read 4 components: 80 000 entities, the fourth component on half of them.
- `(*, T)` with churn: 20 000 entities with one of 64 pairs `(R, T)`; a pair toggled before
  each pass of `Health` and `(*, T)`. The query reads the values of `(*, T)` from a mirror
  (see [The strengths of jecs](#the-strengths-of-jecs)).
- Usually empty: 100 000 entities, each with `Stunned` or `Invulnerable`; the query of both.
  The query keeps an empty list, and a pass after which nothing changed costs a comparison.

`luau -O2 --codegen bench/query_cases.luau` runs the same cases with the test kit of jecs:
one run per case, first loops included.

### A sparse world

The shape of a game with many entities per creature (`bench/run.luau`, group `sparse world`):
700 creatures (200 alive, 500 dead), each created right before its 500 skills, 350 000
entities in all; a pass of each query of a frame after the changes the game makes. A
creature sits alone in its value page, so a query over creatures reads a word per creature;
in the "pool" columns the creatures come from a slot pool (`world:pool()`), which keeps them
together. Time of one pass:

| Pass | jecs 0.11.0 | mErCS 1.1.0 | 1.1.0 / jecs | mErCS 1.1.0, pool | pool / jecs |
|---|---|---|---|---|---|
| Alive creatures, nothing changed | 6.49 / 5.99 µs | 5.82 / 4.44 µs | 0.90× / 0.74× | 7.48 / 4.16 µs | 1.15× / 0.70× |
| Alive creatures, `Dead` added to one and removed | 7.5 / 6.87 µs | 7.53 / 5.51 µs | 1.00× / 0.80× | 7.6 / 4.77 µs | 1.01× / 0.69× |
| Running creatures, `Run` toggled on one | 4.08 / 3.42 µs | 5.14 / 3.77 µs | 1.26× / 1.10× | 2.99 / 1.84 µs | 0.73× / 0.54× |
| A tag added to one creature, a pass, removed, a pass | 1.31 / 1.24 µs | 2.12 / 1.48 µs | 1.62× / 1.19× | 1.75 / 1.22 µs | 1.34× / 0.98× |
| A tag nobody has | 70.4 / 65 ns | 45.1 / 33.5 ns | 0.64× / 0.52× | 45.1 / 31.3 ns | 0.64× / 0.48× |
| All with `Model` (creatures and corpses) | 23.1 / 20.8 µs | 20 / 14.8 µs | 0.87× / 0.71× | 16 / 9.2 µs | 0.69× / 0.44× |
| A skill changes state, 10 queries over skills in `Cast` | 154 / 151 µs | 114 / 69.5 µs | 0.74× / 0.46× | 117 / 78.4 µs | 0.76× / 0.52× |

Without a pool, a change of one creature before a pass (`Run` toggled, a tag added and
removed) costs a list edit: the creature is a group of its own in the match list of the query,
and the group is inserted or removed. jecs moves the creature to another archetype, and its
pass costs nothing more.

### State tags

The group `state tags` of `bench/run.luau` (`bench/shapes.luau`): 1200 skills in 5 state tags;
10, 200 or 800 of them move to the next state, then 5 queries written inline pass over the
skills of each state (`query:each` in mErCS, for-in in jecs). Time per frame:

| Frame of 1200 skills, 5 inline queries | jecs 0.11.0 | mErCS 1.1.0 | 1.1.0 / jecs |
|---|---|---|---|
| 10 skills change state | 60.7 / 53.5 µs | 42.8 / 29.1 µs | 0.71× / 0.54× |
| 200 skills change state | 173 / 164 µs | 171 / 107 µs | 0.98× / 0.65× |
| 800 skills change state | 528 / 458 µs | 378 / 252 µs | 0.71× / 0.55× |

### The strengths of jecs

Ten cases where an archetype ECS is at its best, in time or in memory (the group
`jecs strengths` of `bench/run.luau`, `bench/strengths.luau`). An archetype keeps the entities
of one set of ids together, a query caches the archetypes it matches, and a wildcard pair is
resolved per archetype, while a bitset ECS pays per entity, per changed slot or per value page.
Time of one pass or per unit; memory is what a unit keeps:

| # | Case | jecs 0.11.0 | mErCS 1.1.0 | 1.1.0 / jecs |
|---|---|---|---|---|
| 1 | `(*, T)` values, 32 data relations, a pass over 20 000 | 777 / 642 µs | 573 / 320 µs | 0.74× / 0.50× |
| 2 | `(R, *)` values, 8 targets, a pass over 20 000 | 780 / 654 µs | 558 / 328 µs | 0.71× / 0.50× |
| 3 | 15 cached queries over scattered entities, per query | 314 / 300 µs | 746 / 405 µs | 2.37× / 1.35× |
|  | the same, memory per query | 5803 B | 263 KiB | 46.38× |
| 4 | usually empty, 20 swaps per pass (100 000 entities) | 16.9 / 18.2 µs | 16.8 / 9.73 µs | 0.99× / 0.53× |
|  | 5 queries, 100 matches each, 40 toggles per frame | 55.7 / 53.6 µs | 42.8 / 19.7 µs | 0.77× / 0.37× |
| 5 | 20 small queries, a shared tag toggled on 30 per frame | 23.2 / 26.1 µs | 26.5 / 16 µs | 1.14× / 0.61× |
| 6 | `query(A, pair(ChildOf, parent))` per parent (1000 × 5) | 982 ns / 1.14 µs | 613 / 661 ns | 0.62× / 0.58× |
|  | 2 inline queries per new caster | 2 / 1.94 µs | 4.67 / 4.02 µs | 2.34× / 2.08× |
|  | the same, memory per caster | 0 B | 377 B | inf× |
| 7 | `world:each` over 100 000, per entity | 34.2 / 25.6 ns | 32.5 / 25.1 ns | 0.95× / 0.98× |
|  | `world:children`, 1000 children, per child | 30.9 / 25.8 ns | 35.2 / 26.9 ns | 1.14× / 1.04× |
| 8 | 8 kinds in turn, 3 values, for-in, per match | 46.7 / 35.1 ns | 93.5 / 81.3 ns | 2.00× / 2.31× |
|  | the same, `each` | 46.7 / 35.1 ns | 74.7 / 62.1 ns | 1.60× / 1.77× |
|  | the same, `each`, the kind from a slot pool | 46.7 / 35.1 ns | 38.6 / 21.7 ns | 0.83× / 0.62× |
| 9 | delete entities with 100 targets, per pair | 30.5 / 31.1 ns | 65.5 / 46.3 ns | 2.15× / 1.48× |
| 10 | 8 components on 1 entity in 64 of 131 072, memory per entity | 170 B | 661 B | 3.90× |
|  | the same, time per entity | 2.84 / 2.32 µs | 2.62 / 1.66 µs | 0.92× / 0.72× |

1. `(*, T)` values. jecs reads the column of the first pair of `T` in each archetype. mErCS
   keeps a mirror for a wildcard whose values a query returns: value pages with the value of one
   pair of each entity (the lowest relation slot for `(*, T)`, the lowest target slot for
   `(R, *)`), updated by every change of its pairs; the query reads it like the column of a
   component. A mirror keeps about 17 B per member (a `(*, T)` mirror also notes the pair that
   gives the value of a slot with several pairs of `T`): the world of this case with its query
   takes 255 B per entity (jecs: 315 B).
2. `(R, *)` values: the same mirror; the world with its query takes 158 B per entity (jecs:
   312 B).
3. The memory of cached queries. A query of an archetype ECS keeps a list of archetypes; a
   cached query of mErCS over scattered matches keeps a list of its matches (the entity and its
   index in the value page), which keeps its loops fast over scattered matches. The arrays of
   the list have their exact size, and the first list of a query is built from the spans that
   the choice of its iteration mode found. A list of words or of one number per match would take
   less memory, but would change the iteration cost; those alternatives are not measured here.
4. Queries over two large terms after more than a few changes of a term: a query re-checks the
   noted slots while that costs less than a pass, up to half of the words of the smallest term,
   and drops at once a slot that an unchanged required term does not have.
5. Twenty small queries that share a changing tag: every query re-checks the changes of the tag
   (jecs moves the entity between archetypes once, at the change). The queries that saw the same
   versions of a record read its changes from the journal once, and each drops the slots that an
   unchanged required term does not have; a query whose smallest term has few words tests those
   words against the changed bits of each word, gathered once for all the queries, so that its
   cost does not grow with the number of changes.
6. Inline queries built per call. A query shape is shared from its second request: the first
   request gets a light state of its own and only marks the shape, so a query requested once (an
   entity used as a term) keeps no shared state. A query that is not cached and whose smallest
   term lies in at most 64 words gathers its matches in one loop over those words before the
   loop of the caller, instead of a call of the span generator per match. The queries with a
   pair of an entity target are shared by shape as well and go with the target; the queries of a
   new caster stay slower, as their shape is new on every call.
7. `world:each` and `world:children` collect the members of the id at the start of the loop into
   a buffer from the module pool: records with at most 64 word keys, including emptied
   words, use sorted non-empty keys; larger records use the levels of their bitsets. The pool
   retains at most 16 buffers and 4 MiB of charged array storage, plus table overhead. A buffer
   larger than the budget is collected and allocated again on its next use.
8. Entities of several kinds created in turn: a kind lies in one slot of eight, so its values
   sit in the hash parts of their pages and its queries keep match lists; jecs stores each kind
   in an archetype of its own. A slot pool (`world:pool()`) keeps a kind dense and makes it
   faster than jecs.
9. Deleting entities with many pairs of one relation: every pair record clears its bit (jecs
   removes the row of the entity from one archetype); the pairs of a relation are cleared in one
   inline loop.
10. Sparse components in a large world: a component on one entity in 64 keeps, per entity, a
    word of its bitset and a quarter of a value page of 256 slots, where jecs keeps a row of an
    archetype. This is the cost of the page layout that `world:column` exposes; adding the
    components is faster than in jecs.

### Query monitors

The group `query monitors` of `bench/run.luau` (`bench/monitors.luau`): jecs 0.11.0 with the
monitors of its addon `modules/OB` against `query:monitor()` of mErCS, 10 000 entities:

| Case | jecs 0.11.0 + OB | mErCS 1.1.0 | 1.1.0 / jecs |
|---|---|---|---|
| a tag of the query added and removed, per cycle (an entry and an exit) | 678 / 641 ns | 821 / 570 ns | 1.21× / 0.89× |
| members of the query deleted, per entity | 551 / 575 ns | 680 / 403 ns | 1.23× / 0.70× |
| children moved to another parent, `(ChildOf, *)` monitored, per move | 513 / 444 ns | 755 / 452 ns | 1.47× / 1.02× |

The monitor measurements include both the underlying changes and listener dispatch.
For comparison, a child moved without a monitor takes
433 / 260 ns in mErCS and
297 / 216 ns in jecs
(1.46× / 1.21×).

A separate probe deletes entities with four components, with and without one `OnRemove`
hook. The median additional cost is 174 / 109 ns in mErCS
and 5.17 / 22.3 ns in jecs. Each sample subtracts two minima
of nine batches, so small differences in this probe are sensitive to timing noise. The hook of
mErCS runs inside a frame that the hooks it starts consult (clears and removals of the same
entity), which jecs does not keep.

### Single operations

`bench/run.luau`, 131 072 entities. jecs has no `query:each`: its rows compare `each` with the
jecs for-in loop over the same world.

#### Entities

| Scenario | jecs 0.11.0 | mErCS 1.1.0 | 1.1.0 / jecs |
|---|---|---|---|
| create an entity | 203 / 169 ns | 46.1 / 31.5 ns | 0.23× / 0.19× |
| delete an entity with 4 components | 380 / 371 ns | 441 / 240 ns | 1.16× / 0.65× |

#### Components

| Scenario | jecs 0.11.0 | mErCS 1.1.0 | 1.1.0 / jecs |
|---|---|---|---|
| add a first component | 130 / 101 ns | 189 / 119 ns | 1.46× / 1.18× |
| set an existing component | 65.1 / 59.3 ns | 62 / 37.5 ns | 0.95× / 0.63× |
| remove a component | 186 / 169 ns | 118 / 58.8 ns | 0.63× / 0.35× |
| add when the entity has 5 | 365 / 285 ns | 129 / 65.1 ns | 0.35× / 0.23× |
| remove when the entity has 6 | 386 / 333 ns | 116 / 59.8 ns | 0.30× / 0.18× |
| add when the entity has 20 | 1.55 / 1.25 µs | 128 / 62 ns | 0.08× / 0.05× |
| remove when the entity has 21 | 1.53 / 1.33 µs | 115 / 58.4 ns | 0.08× / 0.04× |
| add when the entity has 40 | 2.88 / 2.48 µs | 124 / 59.8 ns | 0.04× / 0.02× |
| remove when the entity has 41 | 2.97 / 2.57 µs | 118 / 58.7 ns | 0.04× / 0.02× |

#### Tags

| Scenario | jecs 0.11.0 | mErCS 1.1.0 | 1.1.0 / jecs |
|---|---|---|---|
| add a tag | 357 / 282 ns | 99.4 / 53.1 ns | 0.28× / 0.19× |
| remove a tag | 366 / 318 ns | 111 / 63.4 ns | 0.30× / 0.20× |
| toggle a tag on 10 % of the entities per frame | 1.14 µs / 720 ns | 191 / 96.2 ns | 0.17× / 0.13× |

#### Access

| Scenario | jecs 0.11.0 | mErCS 1.1.0 | 1.1.0 / jecs |
|---|---|---|---|
| `get` 1 id | 62.5 / 53.4 ns | 47.9 / 29.1 ns | 0.77× / 0.54× |
| `get` 2 ids | 71.2 / 61.1 ns | 59.9 / 34.7 ns | 0.84× / 0.57× |
| `get` 4 ids | 90.8 / 67.3 ns | 93.3 / 46.7 ns | 1.03× / 0.69× |
| `get` 8 ids (jecs: at most 4) | — | 251 / 115 ns | — |
| `has` 1 id | 60.1 / 45.4 ns | 53 / 33.9 ns | 0.88× / 0.75× |
| `has` 4 ids | 82.1 / 48.5 ns | 102 / 43.6 ns | 1.25× / 0.90× |
| `has` 8 ids (jecs: at most 4) | — | 190 / 73.6 ns | — |

#### Pairs

| Scenario | jecs 0.11.0 | mErCS 1.1.0 | 1.1.0 / jecs |
|---|---|---|---|
| `pair(R, T)` | 20.9 / 9 ns | 21 / 9.13 ns | 1.00× / 1.02× |
| add a pair | 288 / 193 ns | 301 / 190 ns | 1.04× / 0.98× |
| set the value of an existing pair | 77.8 / 68.3 ns | 70.6 / 48.8 ns | 0.91× / 0.71× |
| remove a pair | 246 / 223 ns | 207 / 112 ns | 0.84× / 0.50× |
| `target` (4 pairs) | 159 / 142 ns | 63.5 / 37.2 ns | 0.40× / 0.26× |
| `ChildOf` children, per child (10 000 parents × 5) | 177 / 166 ns | 143 / 111 ns | 0.81× / 0.67× |
| add a pair with a target of its own | 7.17 / 7.11 µs | 3.52 / 3.23 µs | 0.49× / 0.46× |
| delete a target: `Remove` (1000 × 100 sources, per source) | 189 / 196 ns | 160 / 88.5 ns | 0.85× / 0.45× |
| delete a parent: `ChildOf` cascade (per child) | 303 / 306 ns | 410 / 246 ns | 1.35× / 0.80× |

#### Queries (per entity or match)

| Scenario | jecs 0.11.0 | mErCS 1.1.0 | 1.1.0 / jecs |
|---|---|---|---|
| for-in, 4 values, 8192 entities per archetype | 44 / 35.6 ns | 49.6 / 34.7 ns | 1.13× / 0.97× |
| `query:each`, the same (ratio: against the jecs for-in) | — | 35.4 / 16.3 ns | 0.70× / 0.45× |
| manual loop (`spans` / jecs archetypes), the same | 22.3 / 5 ns | 14.4 / 5.12 ns | 0.65× / 1.02× |
| for-in, 4 values, 256 entities per archetype | 49.7 / 39.4 ns | 54.5 / 36.7 ns | 1.10× / 0.93× |
| `query:each`, the same (against the jecs for-in) | — | 36.9 / 18.3 ns | 0.73× / 0.48× |
| manual loop, the same | 19.9 / 7.25 ns | 18 / 6.8 ns | 0.90× / 0.94× |
| for-in, 4 values, 16 entities per archetype | 69 / 54.3 ns | 70.5 / 42.8 ns | 1.02× / 0.79× |
| `query:each`, the same (against the jecs for-in) | — | 51.2 / 22 ns | 0.72× / 0.37× |
| manual loop, the same | 52.7 / 30.2 ns | 32.7 / 9.99 ns | 0.62× / 0.33× |
| for-in, 4 values, 1 entity per archetype | 282 / 178 ns | 76.1 / 48.4 ns | 0.27× / 0.27× |
| `query:each`, the same (against the jecs for-in) | — | 57.5 / 27.9 ns | 0.19× / 0.15× |
| manual loop, the same | 179 / 105 ns | 38.1 / 15 ns | 0.21× / 0.14× |
| a query created and iterated once | 45.7 / 36.4 ns | 49.3 / 34.3 ns | 1.08× / 0.94× |
| for-in, 1 value of an entity with 4 | 35.5 / 31 ns | 38 / 29.5 ns | 1.07× / 0.95× |
| for-in with `without` (half excluded) | 33.1 / 28.5 ns | 40.4 / 34 ns | 1.22× / 1.19× |
| `query:each`, the same (against the jecs for-in) | — | 21.9 / 13.6 ns | 0.64× / 0.48× |
| for-in over a sparse match (1 %) | 40.2 / 33.3 ns | 81.3 / 62.2 ns | 2.02× / 1.87× |
| `query:each`, the same (against the jecs for-in) | — | 45.9 / 31.6 ns | 1.01× / 0.87× |
| the first loop of a new query (2000 archetypes), per query | 130 / 128 µs | 520 / 359 ns | 0.004× / 0.003× |
| a small query created on every call (15 of 1000), per query | 1.43 / 1.27 µs | 1.23 / 1.09 µs | 0.86× / 0.86× |
| a query of a concrete pair created on every call (15 of 1000), per query | 1.59 / 1.37 µs | 1.06 µs / 906 ns | 0.67× / 0.66× |
| the same, nothing matches (0 of 1000) | 343 / 331 ns | 171 / 153 ns | 0.50× / 0.46× |
| an entity used as a term in 4 inline queries, then deleted, per entity | 2.08 / 1.84 µs | 6.35 / 5.67 µs | 3.05× / 3.09× |
| a query with 10 terms | 101 / 68.1 ns | 103 / 60.8 ns | 1.01× / 0.89× |

#### Batch operations (per match; jecs: a collect-and-change loop)

| Scenario | jecs 0.11.0 | mErCS 1.1.0 | 1.1.0 / jecs |
|---|---|---|---|
| add a tag to the matches (half of the entities) | 315 / 260 ns | 38.3 / 13.2 ns | 0.12× / 0.05× |
| set a component on the matches | 323 / 277 ns | 78 / 29.7 ns | 0.24× / 0.11× |
| remove a component from the matches | 301 / 290 ns | 39.8 / 13.1 ns | 0.13× / 0.05× |
| delete the matches | 460 / 453 ns | 490 / 249 ns | 1.07× / 0.55× |
| count the matches | 33.6 / 30.5 ns | 7.27 / 2.53 ns | 0.22× / 0.08× |

#### Churn (per cycle)

| Scenario | jecs 0.11.0 | mErCS 1.1.0 | 1.1.0 / jecs |
|---|---|---|---|
| spawn and despawn (10 components, 2 tags) | 4.18 / 3.96 µs | 2.46 / 1.23 µs | 0.59× / 0.31× |
| a hierarchy of 1 + 5 `ChildOf`, spawned and deleted | 23.2 / 22 µs | 11.3 / 7.55 µs | 0.49× / 0.34× |

### Memory and garbage

Bytes kept per unit after full GC. Equal interpreter/native medians are shown once:

| Kept per unit | jecs 0.11.0 | mErCS 1.1.0 |
|---|---|---|
| an empty entity | 240 B | 32 B |
| an entity with 4 components | 320 B | 131 B |
| an entity with 10 components and 5 tags | 417 B | 236 B |
| a `ChildOf` child (10 000 parents × 5) | 726 B | 344 B |
| an entity with a tag of its own | 1630 B | 978 B |
| a pair with a target of its own | 2264 B | 1457 B |
| a component of 1000 on 100 entities each, per add | 398 B | 162 B |
| growth per hierarchy spawn / despawn cycle | 218 B | 0 B |
| an entity used in 4 inline queries, then deleted | 0 B | 1 B |

Net heap growth per warmed loop over 200 entities, measured across 1000 loops after full GC:

| Loop | jecs 0.11.0 | mErCS 1.1.0 |
|---|---|---|
| Inline two-component query | 921 B | 80 B |
| Stored query | 0 B | 0 B |
| `world:each` | 288 B | 152 B |

A weak GC witness rejects a completed collection during the interval. This measures net heap
growth, not all allocator traffic; a partial incremental collection may not clear the witness.
The heap counter has 1 KiB resolution, or about 1 byte per loop in this batch; the 152 bytes of
`world:each` are its iterator, its buffer being reused.

## Migrating from jecs

1. Point the jecs require at this module (`local jecs = require(path.to.mErCS)`) and
   change the jecs calls that do not exist here (the type checker points at them):

   | jecs | mErCS |
   |---|---|
   | `jecs.World.new()` | `jecs.world()` |
   | `jecs.w` | `jecs.Wildcard` |
   | `jecs.bulk_insert(world, e, ids, values)` | `world:set(e, ids[i], values[i])` for each id |
   | `jecs.bulk_remove(world, e, ids)` | `world:remove(e, id)` for each id |
   | `jecs.new(world)` | `world:entity()` |
   | `jecs.new_w_id(world, id)` | `world:entity()`, then `world:add(e, id)` |
   | `jecs.new_low_id(world)` | `world:entity()`: a low id is not faster here |
   | `for e, a in query:iter() do`, `local step = query:iter()` | `for e, a in query do` (or `query:each(fn)`) |
   | `jecs.is_tag(world, id)` | `not world:has(id, jecs.Component)` (for a pair: neither element has it) |
   | `jecs.entity_index_try_get(world.entity_index, e)` | `world:contains(e)`; the ids of `e`: `world:ids(e)` |
   | `world:cleanup()`, `query:fini()` | delete the call: there is nothing to release |
   | `jecs.ArchetypeCreate`, `jecs.ArchetypeDelete` | delete: there are no archetypes |

   jabby needs the [adapter](../guide/README.md#introspection-and-jabby) instead of the plain module.

   Then run the game: the world API, pairs, wildcards, hooks, signals, cleanup policies,
   `Name`, `jecs.component()` / `jecs.tag()` / `jecs.meta()` and the `ECS_*` helpers keep their
   meaning. A debug world, `ecs.world(true)`, raises errors for dead entities and ids on
   every change while you migrate.
2. Rewrite what reads archetypes: loops over `query:archetypes()` with `columns` /
   `columns_map` become `query:each(fn)` (or `query:spans()` with `world:column(id)` for the
   hottest loops); hooks that use `oldarchetype` read the entity with `world:get` /
   `world:has`.
3. Remove most `:cached()` calls: shared queries are cached already (see
   [Coming from jecs](../guide/README.md#coming-from-jecs)). A query with an entity as a term,
   directly or as the target of a pair (`query:with(caster)`, `query(A, pair(ChildOf, parent))`),
   shares a state per entity, up to 1024 shapes per world: for lookups
   over many live entities, a pair and `world:each(ecs.pair(Event, caster))` need no query
   state (see [Queries](../guide/README.md#queries)). Replace `OB.monitor(query)` of the addon
   `modules/OB` with `query:monitor()`, and its observers with signals and a check of the
   query ([Query monitors](../guide/README.md#query-monitors)) or with `world:track` and the
   `:added` / `:changed` / `:removed` filters.
4. Replace "collect the matches, then change them" loops with batch operations
   (`query:add_all`, `set_all`, `remove_all`, `delete_all`, `count`), and state flags stored
   as components with tags (`Disabled` hides entities from queries without removing
   anything).
5. Code that depends on the iteration order of archetypes, or on the numbers of builtin ids
   after `Name` (`jecs.Rest` is 270 here), needs a look (see the differences above).
