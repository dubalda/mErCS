# mErCS and jecs

How mErCS 1.0.0 differs from [jecs](https://github.com/Ukendio/jecs) 0.11.0: the design,
the behaviour, when jecs is the better choice, the numbers, and how to move code over. The
comparison of 1.0.0 with the previous release is on [its own page](previous-release.md), the
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

| | jecs 0.11.0 | mErCS 1.0.0 |
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

The 1.0.0 CLI check passes the jecs test suite (`test/jecs_compat/`) in both modes:
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
the other cannot match. The numbers compare jecs 0.11.0 and mErCS 1.0.0: the time or memory of
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
| Eight kinds created in turn, 3 values read | rows of each kind stay together | values follow slot layout | for-in 2.10× / 2.27×; `each` 1.46× / 1.57×; `each` with a pool 0.88× / 0.61× |
| Delete entities with 100 targets of a relation | remove one archetype row | clear the bit of each pair record | 2.10× / 1.53× |

### Where jecs is faster than mErCS 1.0.0

The cases below compare measured medians. Consult the ranges in the full report for small
differences; these ratios do not establish a statistically significant difference on their own.

- Two inline queries per new caster: 2.37× / 2.11×;
  memory retained per caster: 376 B
  in mErCS, 0 B in jecs.
  Four inline queries using an entity term followed by its deletion:
  2.97× / 3.04×.
- A cached query over scattered entities, built and passed once:
  2.52× / 1.20×.
- For-in over a sparse match (1%): 1.65× / 1.74×;
  `query:each` against the jecs for-in: 1.01× / 0.87×.
- For-in with `without`: 1.15× / 1.10×.
- Adding the first component: 1.40× / 1.15×.
- Moving a child to another parent without a monitor:
  1.53× / 1.19×.
- In the sparse world without a slot pool, `Run` toggled before a pass:
  1.35× / 1.04×; a tag added and removed around passes:
  1.67× / 1.13×.

Other interpreter costs, including multi-id access, entity deletion and query monitors,
are listed in the operation tables. Queries with a reused shape avoid the cost of a new
entity term: a concrete pair per call is 0.79× / 0.73×,
and `query(A, pair(ChildOf, parent))` per parent is
0.61× / 0.57×.

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

Benchmarks in `bench/`, measured on 2026-10-01 with Luau 0.740: jecs 0.11.0 (the pinned
Wally dev package) and mErCS 1.0.0. Cells read "interpreter / native": `-O2` / `-O2 --codegen`.
Ratios are the median time of mErCS divided by that of jecs; lower is better.

Each library runs in its own process, five times in each mode, with the order rotated. The
tables show medians of those five runs. A matrix run takes the minimum of three timed
repetitions and the median retained-memory delta after full GC. The synthetic-frame helper
runs three batches per query style and returns the frame median from the batch with the
lowest minimum frame time. Small differences between medians should be read with their ranges.

The [complete measurements](https://github.com/dubalda/mErCS/blob/main/bench/results/1.0.0-comparison.md)
include min–max ranges, hashes, commands and
[raw samples](https://github.com/dubalda/mErCS/blob/main/bench/results/1.0.0-comparison.json),
with the previous release, 0.2.4, measured in the same runs (see
[1.0.0 and 0.2.4](previous-release.md)). The screenshots of the Benchmarker plugin in Roblox
Studio are on [Benchmarker](benchmarker.md).

### A synthetic game frame

`bench/frame.luau`: 3000 units with 2 attachments each follow their parents, 60 projectiles
spawn and expire per frame, damage uses a one-frame tag, 5 % of the units switch AI state
tags; plain for-in loops, the same code for all three. The median frame time; the queries are
written inline in every frame, or created once and `:cached()` (the recommended jecs style):

| Mode / queries | jecs 0.11.0 | mErCS 1.0.0 | 1.0.0 / jecs |
|---|---|---|---|
| interpreter, inline queries | 4.82 ms | 2.2 ms | 0.46× |
| interpreter, cached queries | 4.15 ms | 2.21 ms | 0.53× |
| native, inline queries | 3.91 ms | 1.65 ms | 0.42× |
| native, cached queries | 3.58 ms | 1.59 ms | 0.44× |

### A long session

`bench/leak.luau`: 5 of 200 enemies die and respawn every frame, 10 % of 500 units retarget
a living enemy through a pair `(Targeting, enemy)` and switch a state tag. Each cell is the
median of five isolated runs: heap growth since the start, and time per frame in the preceding
1000-frame window (including checkpoint GC). Both execution modes are measured:

| Mode | Frame | jecs 0.11.0 | jecs 0.11.0 + cleanup every 600 frames | mErCS 1.0.0 |
|---|---|---|---|---|
| interpreter | 1000 | +3.57 MiB, 0.197 ms | +3.60 MiB, 0.211 ms | +0.33 MiB, 0.091 ms |
| interpreter | 3000 | +8.98 MiB, 0.212 ms | +8.80 MiB, 0.229 ms | +0.32 MiB, 0.090 ms |
| interpreter | 5000 | +15.38 MiB, 0.207 ms | +15.66 MiB, 0.220 ms | +0.32 MiB, 0.088 ms |
| native | 1000 | +3.57 MiB, 0.178 ms | +3.60 MiB, 0.184 ms | +0.33 MiB, 0.061 ms |
| native | 3000 | +8.98 MiB, 0.186 ms | +8.80 MiB, 0.191 ms | +0.32 MiB, 0.060 ms |
| native | 5000 | +15.38 MiB, 0.192 ms | +15.66 MiB, 0.196 ms | +0.32 MiB, 0.062 ms |

The jecs heap continues to grow in this 5000-frame session, including with cleanup every
600 frames. The mErCS heap remains near its warmed checkpoint values. This describes the
measured session; it is not a guarantee for every entity layout or duration.

### Query cases

Five cases where an archetype ECS is expected to be at its best (`bench/query_cases.luau`,
and the `query cases` group of `bench/run.luau`). jecs runs for-in loops over cached queries;
mErCS builds the same worlds and runs the same loops through `query:each`, which replaces a
for-in loop fully when it does not break early. Time of one pass:

| Case | jecs 0.11.0 | mErCS 1.0.0 | 1.0.0 / jecs |
|---|---|---|---|
| Scattered after recycling | 124 / 105 µs | 91.2 / 63.1 µs | 0.74× / 0.60× |
| Churn on a queried tag, 1 toggle per pass | 336 / 291 µs | 282 / 208 µs | 0.84× / 0.72× |
| Churn on a queried tag, 100 toggles per pass | 236 / 206 µs | 262 / 179 µs | 1.11× / 0.87× |
| Read 4 components | 1.91 / 1.46 ms | 1.3 ms / 657 µs | 0.68× / 0.45× |
| `(*, T)` with churn | 789 / 685 µs | 531 / 331 µs | 0.67× / 0.48× |
| Usually empty | 66 / 61.3 ns | 43.9 / 27.7 ns | 0.67× / 0.45× |

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

| Pass | jecs 0.11.0 | mErCS 1.0.0 | 1.0.0 / jecs | mErCS 1.0.0, pool | pool / jecs |
|---|---|---|---|---|---|
| Alive creatures, nothing changed | 6.25 / 5.54 µs | 5.44 / 4.07 µs | 0.87× / 0.74× | 6.54 / 3.9 µs | 1.05× / 0.70× |
| Alive creatures, `Dead` added to one and removed | 7.27 / 6.5 µs | 7.23 / 5.18 µs | 0.99× / 0.80× | 7.01 / 4.31 µs | 0.96× / 0.66× |
| Running creatures, `Run` toggled on one | 3.46 / 3.28 µs | 4.69 / 3.4 µs | 1.35× / 1.04× | 2.78 / 1.81 µs | 0.80× / 0.55× |
| A tag added to one creature, a pass, removed, a pass | 1.24 / 1.16 µs | 2.06 / 1.31 µs | 1.67× / 1.13× | 1.63 µs / 984 ns | 1.31× / 0.85× |
| A tag nobody has | 66.8 / 62.3 ns | 44.8 / 30.7 ns | 0.67× / 0.49× | 43 / 28 ns | 0.64× / 0.45× |
| All with `Model` (creatures and corpses) | 21.6 / 19.1 µs | 19.1 / 14.1 µs | 0.88× / 0.74× | 15.2 / 8.58 µs | 0.70× / 0.45× |
| A skill changes state, 10 queries over skills in `Cast` | 137 / 133 µs | 106 / 66.6 µs | 0.77× / 0.50× | 107 / 67.7 µs | 0.78× / 0.51× |

Without a pool, a change of one creature before a pass (`Run` toggled, a tag added and
removed) costs a list edit: the creature is a group of its own in the match list of the query,
and the group is inserted or removed. jecs moves the creature to another archetype, and its
pass costs nothing more.

### State tags

The group `state tags` of `bench/run.luau` (`bench/shapes.luau`): 1200 skills in 5 state tags;
10, 200 or 800 of them move to the next state, then 5 queries written inline pass over the
skills of each state (`query:each` in mErCS, for-in in jecs). Time per frame:

| Frame of 1200 skills, 5 inline queries | jecs 0.11.0 | mErCS 1.0.0 | 1.0.0 / jecs |
|---|---|---|---|
| 10 skills change state | 51.2 / 45.9 µs | 40 / 24.5 µs | 0.78× / 0.53× |
| 200 skills change state | 156 / 138 µs | 162 / 95.2 µs | 1.04× / 0.69× |
| 800 skills change state | 481 / 425 µs | 363 / 219 µs | 0.75× / 0.52× |

### The strengths of jecs

Ten cases where an archetype ECS is at its best, in time or in memory (the group
`jecs strengths` of `bench/run.luau`, `bench/strengths.luau`). An archetype keeps the entities
of one set of ids together, a query caches the archetypes it matches, and a wildcard pair is
resolved per archetype, while a bitset ECS pays per entity, per changed slot or per value page.
Time of one pass or per unit; memory is what a unit keeps:

| # | Case | jecs 0.11.0 | mErCS 1.0.0 | 1.0.0 / jecs |
|---|---|---|---|---|
| 1 | `(*, T)` values, 32 data relations, a pass over 20 000 | 739 / 617 µs | 551 / 313 µs | 0.75× / 0.51× |
| 2 | `(R, *)` values, 8 targets, a pass over 20 000 | 742 / 619 µs | 540 / 309 µs | 0.73× / 0.50× |
| 3 | 15 cached queries over scattered entities, per query | 281 / 242 µs | 707 / 289 µs | 2.52× / 1.20× |
|  | the same, memory per query | 5803 B | 263 KiB | 46.38× |
| 4 | usually empty, 20 swaps per pass (100 000 entities) | 15.5 / 15.1 µs | 13.1 / 7.24 µs | 0.84× / 0.48× |
|  | 5 queries, 100 matches each, 40 toggles per frame | 50.3 / 39.6 µs | 31 / 16.9 µs | 0.62× / 0.43× |
| 5 | 20 small queries, a shared tag toggled on 30 per frame | 17.6 / 15.7 µs | 22 / 14.5 µs | 1.25× / 0.93× |
| 6 | `query(A, pair(ChildOf, parent))` per parent (1000 × 5) | 927 / 846 ns | 568 / 482 ns | 0.61× / 0.57× |
|  | 2 inline queries per new caster | 1.71 / 1.65 µs | 4.05 / 3.48 µs | 2.37× / 2.11× |
|  | the same, memory per caster | 0 B | 376 B | inf× |
| 7 | `world:each` over 100 000, per entity | 27.6 / 23.8 ns | 31 / 24.9 ns | 1.12× / 1.04× |
|  | `world:children`, 1000 children, per child | 28.3 / 24.2 ns | 32.1 / 25.5 ns | 1.13× / 1.05× |
| 8 | 8 kinds in turn, 3 values, for-in, per match | 39.9 / 32.5 ns | 83.9 / 73.8 ns | 2.10× / 2.27× |
|  | the same, `each` | 39.9 / 32.5 ns | 58.3 / 51.2 ns | 1.46× / 1.57× |
|  | the same, `each`, the kind from a slot pool | 39.9 / 32.5 ns | 34.9 / 19.9 ns | 0.88× / 0.61× |
| 9 | delete entities with 100 targets, per pair | 28.9 / 29.1 ns | 60.9 / 44.5 ns | 2.10× / 1.53× |
| 10 | 8 components on 1 entity in 64 of 131 072, memory per entity | 170 B | 660 B | 3.90× |
|  | the same, time per entity | 2.75 / 2.15 µs | 2.38 / 1.53 µs | 0.86× / 0.71× |

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

| Case | jecs 0.11.0 + OB | mErCS 1.0.0 | 1.0.0 / jecs |
|---|---|---|---|
| a tag of the query added and removed, per cycle (an entry and an exit) | 643 / 598 ns | 794 / 540 ns | 1.23× / 0.90× |
| members of the query deleted, per entity | 529 / 532 ns | 689 / 444 ns | 1.30× / 0.84× |
| children moved to another parent, `(ChildOf, *)` monitored, per move | 496 / 423 ns | 734 / 457 ns | 1.48× / 1.08× |

The monitor measurements include both the underlying changes and listener dispatch.
For comparison, a child moved without a monitor takes
423 / 244 ns in mErCS and
277 / 205 ns in jecs
(1.53× / 1.19×).

A separate probe deletes entities with four components, with and without one `OnRemove`
hook. The median additional cost is 221 / 140 ns in mErCS
and 2.67 / 12.6 ns in jecs. Each sample subtracts two minima
of nine batches, so small differences in this probe are sensitive to timing noise. The hook of
mErCS runs inside a frame that the hooks it starts consult (clears and removals of the same
entity), which jecs does not keep.

### Single operations

`bench/run.luau`, 131 072 entities. jecs has no `query:each`: its rows compare `each` with the
jecs for-in loop over the same world.

#### Entities

| Scenario | jecs 0.11.0 | mErCS 1.0.0 | 1.0.0 / jecs |
|---|---|---|---|
| create an entity | 172 / 154 ns | 42.2 / 28 ns | 0.25× / 0.18× |
| delete an entity with 4 components | 378 / 354 ns | 437 / 240 ns | 1.16× / 0.68× |

#### Components

| Scenario | jecs 0.11.0 | mErCS 1.0.0 | 1.0.0 / jecs |
|---|---|---|---|
| add a first component | 124 / 96.6 ns | 174 / 111 ns | 1.40× / 1.15× |
| set an existing component | 62.9 / 56.9 ns | 64.3 / 42.9 ns | 1.02× / 0.75× |
| remove a component | 184 / 162 ns | 115 / 58.1 ns | 0.62× / 0.36× |
| add when the entity has 5 | 341 / 267 ns | 126 / 71.8 ns | 0.37× / 0.27× |
| remove when the entity has 6 | 346 / 304 ns | 111 / 57 ns | 0.32× / 0.19× |
| add when the entity has 20 | 1.38 / 1.16 µs | 127 / 69.8 ns | 0.09× / 0.06× |
| remove when the entity has 21 | 1.45 / 1.19 µs | 110 / 56.3 ns | 0.08× / 0.05× |
| add when the entity has 40 | 2.73 / 2.29 µs | 121 / 66.8 ns | 0.04× / 0.03× |
| remove when the entity has 41 | 2.71 / 2.31 µs | 108 / 57 ns | 0.04× / 0.02× |

#### Tags

| Scenario | jecs 0.11.0 | mErCS 1.0.0 | 1.0.0 / jecs |
|---|---|---|---|
| add a tag | 329 / 268 ns | 96.3 / 53.6 ns | 0.29× / 0.20× |
| remove a tag | 324 / 293 ns | 109 / 65 ns | 0.34× / 0.22× |
| toggle a tag on 10 % of the entities per frame | 991 / 652 ns | 160 / 96.1 ns | 0.16× / 0.15× |

#### Access

| Scenario | jecs 0.11.0 | mErCS 1.0.0 | 1.0.0 / jecs |
|---|---|---|---|
| `get` 1 id | 60.1 / 51.6 ns | 48.5 / 36.5 ns | 0.81× / 0.71× |
| `get` 2 ids | 66.3 / 57.8 ns | 59.5 / 38.5 ns | 0.90× / 0.67× |
| `get` 4 ids | 84.2 / 65.7 ns | 87.6 / 50.3 ns | 1.04× / 0.76× |
| `get` 8 ids (jecs: at most 4) | — | 238 / 116 ns | — |
| `has` 1 id | 57.4 / 39.8 ns | 49.2 / 29.9 ns | 0.86× / 0.75× |
| `has` 4 ids | 70.3 / 46.7 ns | 100 / 42.9 ns | 1.42× / 0.92× |
| `has` 8 ids (jecs: at most 4) | — | 186 / 70.5 ns | — |

#### Pairs

| Scenario | jecs 0.11.0 | mErCS 1.0.0 | 1.0.0 / jecs |
|---|---|---|---|
| `pair(R, T)` | 19.9 / 8.65 ns | 20.5 / 10.2 ns | 1.03× / 1.18× |
| add a pair | 264 / 183 ns | 274 / 175 ns | 1.04× / 0.95× |
| set the value of an existing pair | 71.4 / 66.2 ns | 70.8 / 51.2 ns | 0.99× / 0.77× |
| remove a pair | 230 / 206 ns | 195 / 113 ns | 0.85× / 0.55× |
| `target` (4 pairs) | 155 / 137 ns | 66.7 / 42.2 ns | 0.43× / 0.31× |
| `ChildOf` children, per child (10 000 parents × 5) | 144 / 146 ns | 132 / 92.5 ns | 0.92× / 0.63× |
| add a pair with a target of its own | 6.6 / 6.29 µs | 3.01 / 2.66 µs | 0.46× / 0.42× |
| delete a target: `Remove` (1000 × 100 sources, per source) | 173 / 172 ns | 147 / 80.1 ns | 0.85× / 0.47× |
| delete a parent: `ChildOf` cascade (per child) | 293 / 293 ns | 384 / 255 ns | 1.31× / 0.87× |

#### Queries (per entity or match)

| Scenario | jecs 0.11.0 | mErCS 1.0.0 | 1.0.0 / jecs |
|---|---|---|---|
| for-in, 4 values, 8192 entities per archetype | 42.6 / 34.2 ns | 46.6 / 31.9 ns | 1.09× / 0.93× |
| `query:each`, the same (ratio: against the jecs for-in) | — | 31 / 15.3 ns | 0.70× / 0.45× |
| manual loop (`spans` / jecs archetypes), the same | 17.8 / 4.72 ns | 13 / 4.63 ns | 0.73× / 0.98× |
| for-in, 4 values, 256 entities per archetype | 45.9 / 37.4 ns | 51.6 / 33.7 ns | 1.13× / 0.90× |
| `query:each`, the same (against the jecs for-in) | — | 32.9 / 16.2 ns | 0.73× / 0.48× |
| manual loop, the same | 16.3 / 6.89 ns | 16.4 / 5.92 ns | 1.01× / 0.86× |
| for-in, 4 values, 16 entities per archetype | 62.7 / 51.3 ns | 66.3 / 39.9 ns | 1.06× / 0.78× |
| `query:each`, the same (against the jecs for-in) | — | 45.9 / 20.8 ns | 0.72× / 0.37× |
| manual loop, the same | 45.6 / 27.2 ns | 30.5 / 9.13 ns | 0.67× / 0.34× |
| for-in, 4 values, 1 entity per archetype | 253 / 168 ns | 73 / 44.5 ns | 0.29× / 0.26× |
| `query:each`, the same (against the jecs for-in) | — | 53.6 / 25.5 ns | 0.19× / 0.15× |
| manual loop, the same | 169 / 98.5 ns | 35.2 / 13.8 ns | 0.21× / 0.14× |
| a query created and iterated once | 43.5 / 32.5 ns | 46.6 / 31.9 ns | 1.07× / 0.98× |
| for-in, 1 value of an entity with 4 | 31.9 / 27.7 ns | 35.4 / 26.3 ns | 1.11× / 0.95× |
| for-in with `without` (half excluded) | 30.9 / 26.7 ns | 35.6 / 29.3 ns | 1.15× / 1.10× |
| `query:each`, the same (against the jecs for-in) | — | 20.5 / 13 ns | 0.64× / 0.48× |
| for-in over a sparse match (1 %) | 37.4 / 31.6 ns | 61.7 / 55.1 ns | 1.65× / 1.74× |
| `query:each`, the same (against the jecs for-in) | — | 40.6 / 27.6 ns | 1.01× / 0.87× |
| the first loop of a new query (2000 archetypes), per query | 116 / 116 µs | 388 / 328 ns | 0.003× / 0.003× |
| a small query created on every call (15 of 1000), per query | 1.28 / 1.17 µs | 1.19 / 1.06 µs | 0.93× / 0.91× |
| a query of a concrete pair created on every call (15 of 1000), per query | 1.33 / 1.22 µs | 1.05 µs / 895 ns | 0.79× / 0.73× |
| the same, nothing matches (0 of 1000) | 319 / 290 ns | 171 / 152 ns | 0.54× / 0.52× |
| an entity used as a term in 4 inline queries, then deleted, per entity | 1.86 / 1.65 µs | 5.53 / 5.02 µs | 2.97× / 3.04× |
| a query with 10 terms | 95.7 / 63.7 ns | 95.4 / 58.8 ns | 1.00× / 0.92× |

#### Batch operations (per match; jecs: a collect-and-change loop)

| Scenario | jecs 0.11.0 | mErCS 1.0.0 | 1.0.0 / jecs |
|---|---|---|---|
| add a tag to the matches (half of the entities) | 282 / 239 ns | 35.2 / 12.5 ns | 0.12× / 0.05× |
| set a component on the matches | 300 / 246 ns | 69.7 / 26 ns | 0.23× / 0.11× |
| remove a component from the matches | 277 / 257 ns | 36.4 / 11.6 ns | 0.13× / 0.05× |
| delete the matches | 424 / 401 ns | 466 / 253 ns | 1.10× / 0.63× |
| count the matches | 30.9 / 26.8 ns | 6.76 / 2.35 ns | 0.22× / 0.09× |

#### Churn (per cycle)

| Scenario | jecs 0.11.0 | mErCS 1.0.0 | 1.0.0 / jecs |
|---|---|---|---|
| spawn and despawn (10 components, 2 tags) | 4.04 / 3.61 µs | 2.39 / 1.32 µs | 0.59× / 0.37× |
| a hierarchy of 1 + 5 `ChildOf`, spawned and deleted | 19.9 / 18.6 µs | 10.3 / 7.44 µs | 0.52× / 0.40× |

### Memory and garbage

Bytes kept per unit after full GC. Equal interpreter/native medians are shown once:

| Kept per unit | jecs 0.11.0 | mErCS 1.0.0 |
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

| Loop | jecs 0.11.0 | mErCS 1.0.0 |
|---|---|---|
| Inline two-component query | 921 B | 81 B |
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
