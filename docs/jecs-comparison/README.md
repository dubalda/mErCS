# mErCS and jecs

How mErCS 0.2.3 differs from [jecs](https://github.com/Ukendio/jecs) 0.11.0: the design,
the behaviour, when jecs is the better choice, the numbers (with mErCS 0.2.2, the previous
release, beside them), and how to move code over.

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
and the values in pages indexed by the entity slot (the model of the C# library
[StaticEcs](https://github.com/Felid-Force-Studios/StaticEcs), adapted to Luau). A query ANDs
the bitsets 32 entities at a time and walks the set bits.

| | jecs 0.11.0 | mErCS 0.2.3 |
|---|---|---|
| add / remove a component | moves the entity, copies all its columns: O(components) | sets a bit and a value: O(1) |
| new combination of components | creates an archetype (kept until `world:cleanup()`) | nothing to create |
| pair with many targets | an archetype per target | one small record per pair, freed when unused (in batches) or with its target |
| components per world | 256 via `world:component()` | no limit |
| ids per `get` / `has` call | 4 | 8, any number with `get_list` / `has_all` |
| memory per entity with 4 components | 320 B | 131 B |
| deep hierarchies | the cascade recurses: stack overflow at about 6000 levels | any depth (past 100 levels the rest is queued) |

## Compatibility

The API follows jecs: worlds, entities, components, tags, pairs, wildcards, `Exclusive`,
cleanup policies, hooks, signals, `Name`, pre-registration (`jecs.component()` /
`jecs.tag()` / `jecs.meta()`), the `ECS_*` helpers and the builtin ids.

The jecs test suite (`test/jecs_compat/`) runs against this library: 125 of 125 applicable
cases pass (its `bulk_insert` / `bulk_remove` come from a test shim, as loops of `set` /
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
- `world:remove(e, ecs.pair(R, ecs.Wildcard))` removes every pair `(R, *)` of the entity, and
  `ecs.pair(ecs.Wildcard, T)` every pair with the target `T`; `add` and `set` raise an error for
  a wildcard pair. jecs forbids a wildcard pair in all three: `jecs.world(true)` raises an
  error, and a world without the check leaves the pairs in place and breaks the row of the
  entity in its archetype.

## Beyond jecs

- `query:each(fn)` — a callback per match, 30–60 % faster than the for-in loop.
- `query:any(...)` — OR terms.
- Batch operations: `query:count`, `add_all`, `set_all`, `remove_all`, `delete_all`, and
  `world:remove_all(id)`.
- Change tracking by ticks: `world:track`, `world:tick`, the `:added` / `:changed` /
  `:removed` filters.
- `ecs.Disabled`: entities hidden from queries without removing their components.
- Slot pools: `world:pool()` and `pool:entity()` keep a kind of entities created among many
  others (creatures among their skills) in slots of its own, so the bitsets and value pages of
  what only they have stay dense.
- `world:ids(e)`, a debug world (`ecs.world(true)`, which also checks the match lists of
  cached queries against their bitsets), `query:spans()` with `world:column(id)`.

## When jecs is the better choice

jecs keeps the entities of one set of ids together, in the rows of an archetype; mErCS keeps a
bitset per id and the values in pages indexed by the entity slot. Each layout has cases that
the other cannot match. The numbers compare jecs 0.11.0 and mErCS 0.2.3: the time or memory of
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

### Where jecs is always stronger

These cases follow from the layouts: a bitset ECS can narrow them, not close them (a slot pool
avoids the third one where the code can use one).

| Case | jecs | mErCS | mErCS / jecs |
|---|---|---|---|
| The memory of a cached query over scattered entities | a list of the archetypes it matches | a list of its matches, two numbers each | 46× (263 KB against 5.7 KB per query) |
| The memory of sparse components in a large world | a row of an archetype per entity | per entity and component, a word of the bitset and a quarter of a value page of 256 slots | 3.9× (660 B against 170 B per entity: 8 components on 1 entity in 64) |
| Entities of several kinds created in turn, without a slot pool | each kind lies in archetypes of its own | the layout follows the order of creation, so the entities of a kind are scattered | for-in 2.1× / 2.2×, `each` 1.46× / 1.55× (from a slot pool: 0.88× / 0.63×) |
| Deleting entities with many pairs of one relation | one row of one archetype | one bit in the record of each pair | 100 targets: 2.1× / 1.6× |

### Where jecs is faster in mErCS 0.2.3

These depend on the implementation rather than on the layout (the benchmark matrix and
[The strengths of jecs](#the-strengths-of-jecs)):

- Queries built on every call with a new entity as a term: jecs looks up the archetypes of the
  ids, mErCS builds a query state for the new shape. Two queries per new caster: 2.4× / 1.9×,
  and 376 B kept per caster (jecs: 0 B); an entity used in 4 inline queries and then deleted:
  2.9× / 3.0×. A shape requested again (an entity or a pair used as a term in every frame) is
  shared and faster than in jecs: a concrete pair per call 0.78× / 0.70×,
  `query(A, pair(ChildOf, parent))` per parent 0.66× / 0.55×.
- A cached query over scattered entities, built and passed once: 2.5× / 1.3×.
- A for-in over a sparse match (1 %): 1.64× / 1.68× (`each`: 1.04× / 0.93×).
- A for-in with `without`: 1.17× / 1.09×.
- Adding the first component to an entity: 1.45× / 1.20×.
- Moving a child to another parent (an exclusive relation replaces its pair): 1.43× / 1.20× (see
  [Query monitors](#query-monitors)).
- In [a sparse world](#a-sparse-world) without a slot pool, a change of one creature before a
  pass: `Run` toggled 1.30× / 1.09×, a tag added and removed 1.64× / 1.14×.
- Query monitors in the interpreter: 1.09–1.28× (in native code faster, on par when children
  move: 1.04×; see [Query monitors](#query-monitors)).
- In the interpreter only (the Roblox client): `has` with 4 ids (1.31×), twenty small cached
  queries over a tag toggled on 30 entities per frame (1.28×: each query tests the words of its
  smallest term against the changed bits, jecs moves the entities once), a `ChildOf` cascade
  (1.28×), deleting an entity with 4 components (1.15×), `get` with 4 ids (1.13×), `world:each`
  and `world:children` (1.08–1.13×; in native code 0.98–0.99×), loops over dense data (a for-in,
  a manual loop over spans, a query created and iterated once: 1.09–1.12×), deleting the matches
  of a query (1.07×), and with a slot pool, a tag added to one creature and removed (1.33×) and
  a pass over the alive creatures (1.06×). On par (1.03–1.06×): adding a pair, setting an
  existing component, the query case with 100 toggles per pass, 200 skills changing state.

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

In the other cases (components and tags added and removed every frame, relationships with many
targets, long sessions, memory per entity, deep hierarchies) mErCS is faster and smaller: see
[Design](#design), [Beyond jecs](#beyond-jecs) and [Performance](#performance).

## Performance

Benchmarks in `bench/` with `luau` 0.740: jecs 0.11.0 (the Wally dev packages), mErCS 0.2.2 (the
previous release: `bash tools/previous.sh` puts it into `tmp/previous`) and mErCS 0.2.3. Cells
read "interpreter / native": `-O2` (the Roblox client) / `-O2 --codegen` (the Roblox server).
The ratio columns give the time of mErCS 0.2.3 divided by the time of jecs 0.11.0 (lower is
better). Each implementation runs in a process of its own, 5 times in each mode, and a table
gives the median of the runs; a run of `bench/run.luau` takes the minimum of 3 repetitions. Runs
of the same build vary by about ±10 %. [Roblox Studio: Benchmarker](#roblox-studio-benchmarker)
compares jecs 0.11.0 and mErCS 0.2.3 inside Roblox Studio.

mErCS 0.2.3 against 0.2.2: `world:each` and `world:children` collect the members of the id at
the start of the loop into a buffer that the world reuses, where 0.2.2 walked the bitsets during
the loop: a loop over 100 000 entities or 1000 children takes 19–26 % less, the children of
10 000 parents with 5 children each 15–23 % less. The other rows, the synthetic frame, the long
session and the memory are where they were.

### A synthetic game frame

`bench/frame.luau`: 3000 units with 2 attachments each follow their parents, 60 projectiles
spawn and expire per frame, damage uses a one-frame tag, 5 % of the units switch AI state
tags; plain for-in loops, the same code for all three. The median frame time; the queries are
written inline in every frame, or created once and `:cached()` (the recommended jecs style):

|  | jecs 0.11.0 | mErCS 0.2.2 | mErCS 0.2.3 | 0.2.3 / jecs |
|---|---|---|---|---|
| interpreter, inline queries | 4.71 ms | 2.26 ms | 2.22 ms | 0.47× |
| interpreter, cached queries | 4.46 ms | 2.25 ms | 2.21 ms | 0.50× |
| native, inline queries | 4.16 ms | 1.66 ms | 1.72 ms | 0.41× |
| native, cached queries | 3.81 ms | 1.70 ms | 1.72 ms | 0.45× |

### A long session

`bench/leak.luau`: 5 of 200 enemies die and respawn every frame, 10 % of 500 units retarget
a living enemy through a pair `(Targeting, enemy)` and switch a state tag; interpreter, the
median of 3 runs. Heap growth since the start and time per frame:

| frame | jecs 0.11.0 | jecs 0.11.0 + `world:cleanup()` every 600 frames | mErCS 0.2.2 | mErCS 0.2.3 |
|---|---|---|---|---|
| 1000 | +3.6 MB, 0.206 ms | +3.6 MB, 0.219 ms | +0.33 MB, 0.095 ms | +0.33 MB, 0.092 ms |
| 3000 | +9.0 MB, 0.230 ms | +8.8 MB, 0.243 ms | +0.32 MB, 0.090 ms | +0.32 MB, 0.093 ms |
| 5000 | +15.4 MB, 0.234 ms | +15.7 MB, 0.231 ms | +0.32 MB, 0.094 ms | +0.32 MB, 0.094 ms |

The archetypes of dead targets stay in jecs (cleanup does not release them all); in mErCS
nothing accumulates: the `(*, T)` records of the enemies, the targets of `(Targeting, enemy)`,
stay small.

### Query cases

Five cases where an archetype ECS is expected to be at its best (`bench/query_cases.luau`,
and the `query cases` group of `bench/run.luau`). jecs runs for-in loops over cached queries;
mErCS builds the same worlds and runs the same loops through `query:each`, which replaces a
for-in loop fully when it does not break early. Time of one pass:

| Case | jecs 0.11.0 | mErCS 0.2.2 | mErCS 0.2.3 | 0.2.3 / jecs |
|---|---|---|---|---|
| Scattered after recycling | 126 / 106 µs | 91.1 / 63.2 µs | 90.8 / 64.7 µs | 0.72× / 0.61× |
| Churn on a queried tag, 1 toggle per pass | 336 / 293 µs | 285 / 203 µs | 290 / 207 µs | 0.86× / 0.71× |
| Churn on a queried tag, 100 toggles per pass | 250 / 206 µs | 268 / 185 µs | 257 / 187 µs | 1.03× / 0.91× |
| Read 4 components | 1.88 / 1.44 ms | 1.38 ms / 659 µs | 1.31 ms / 662 µs | 0.70× / 0.46× |
| `(*, T)` with churn | 780 / 712 µs | 526 / 329 µs | 533 / 332 µs | 0.68× / 0.47× |
| Usually empty | 67 / 61 ns | 43 / 28 ns | 43 / 27 ns | 0.65× / 0.45× |

- Scattered after recycling: 50 000 entities with random subsets of 8 components, then
  100 000 deletes and respawns; a pass of a 4-component query (3125 matches).
- Churn on a queried tag: 70 000 entities with `Position`, every 7th with `Velocity`; the
  query of both without `Stunned`, `Stunned` toggled on 1 or 100 movers before each pass. The
  query re-checks the changed slots only. With 100 toggles the interpreter is on par with jecs
  (1.03×): the list edits cost about what the cheaper toggles save.
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

| Pass | jecs 0.11.0 | mErCS 0.2.2 | mErCS 0.2.3 | 0.2.3 / jecs | mErCS 0.2.2, pool | mErCS 0.2.3, pool | pool / jecs |
|---|---|---|---|---|---|---|---|
| Alive creatures, nothing changed | 6.21 / 5.70 µs | 5.64 / 4.13 µs | 5.52 / 4.08 µs | 0.89× / 0.72× | 6.70 / 3.99 µs | 6.61 / 3.98 µs | 1.06× / 0.70× |
| Alive creatures, `Dead` added to one and removed | 7.09 / 6.60 µs | 7.31 / 5.24 µs | 7.15 / 5.30 µs | 1.01× / 0.80× | 7.21 / 4.22 µs | 7.31 / 4.30 µs | 1.03× / 0.65× |
| Running creatures, `Run` toggled on one | 3.55 / 3.25 µs | 4.72 / 3.37 µs | 4.63 / 3.55 µs | 1.30× / 1.09× | 2.90 / 1.77 µs | 2.85 / 1.80 µs | 0.80× / 0.55× |
| A tag added to one creature, a pass, removed, a pass | 1.25 / 1.16 µs | 2.01 / 1.37 µs | 2.05 / 1.32 µs | 1.64× / 1.14× | 1.64 µs / 997 ns | 1.68 / 1.01 µs | 1.34× / 0.87× |
| A tag nobody has | 69 / 63 ns | 44 / 30 ns | 45 / 29 ns | 0.65× / 0.46× | 43 / 30 ns | 44 / 28 ns | 0.63× / 0.45× |
| All with `Model` (creatures and corpses) | 22.0 / 19.8 µs | 19.3 / 14.0 µs | 19.2 / 14.3 µs | 0.87× / 0.72× | 15.9 / 8.87 µs | 15.6 / 8.58 µs | 0.71× / 0.43× |
| A skill changes state, 10 queries over skills in `Cast` | 138 / 122 µs | 105 / 69.0 µs | 106 / 67.3 µs | 0.77× / 0.55× | 110 / 69.9 µs | 109 / 68.0 µs | 0.79× / 0.56× |

Without a pool, a change of one creature before a pass (`Run` toggled, a tag added and
removed) costs a list edit: the creature is a group of its own in the match list of the query,
and the group is inserted or removed. jecs moves the creature to another archetype, and its
pass costs nothing more.

### State tags

The group `state tags` of `bench/run.luau` (`bench/shapes.luau`): 1200 skills in 5 state tags;
10, 200 or 800 of them move to the next state, then 5 queries written inline pass over the
skills of each state (`query:each` in mErCS, for-in in jecs). Time per frame:

| Frame of 1200 skills, 5 inline queries | jecs 0.11.0 | mErCS 0.2.2 | mErCS 0.2.3 | 0.2.3 / jecs |
|---|---|---|---|---|
| 10 skills change state | 52.8 / 46.9 µs | 40.6 / 24.2 µs | 40.3 / 23.8 µs | 0.76× / 0.51× |
| 200 skills change state | 155 / 138 µs | 164 / 98.4 µs | 161 / 97.3 µs | 1.04× / 0.71× |
| 800 skills change state | 481 / 428 µs | 356 / 229 µs | 363 / 225 µs | 0.75× / 0.53× |

### The strengths of jecs

Ten cases where an archetype ECS is at its best, in time or in memory (the group
`jecs strengths` of `bench/run.luau`, `bench/strengths.luau`). An archetype keeps the entities
of one set of ids together, a query caches the archetypes it matches, and a wildcard pair is
resolved per archetype, while a bitset ECS pays per entity, per changed slot or per value page.
Time of one pass or per unit; memory is what a unit keeps:

| # | Case | jecs 0.11.0 | mErCS 0.2.2 | mErCS 0.2.3 | 0.2.3 / jecs |
|---|---|---|---|---|---|
| 1 | `(*, T)` values, 32 data relations, a pass over 20 000 | 739 / 617 µs | 556 / 314 µs | 543 / 311 µs | 0.74× / 0.50× |
| 2 | `(R, *)` values, 8 targets, a pass over 20 000 | 743 / 620 µs | 547 / 315 µs | 546 / 313 µs | 0.74× / 0.50× |
| 3 | 15 cached queries over scattered entities, per query | 288 / 247 µs | 739 / 319 µs | 727 / 323 µs | 2.52× / 1.31× |
|  | the same, memory per query | 5.7 KB | 263 KB | 263 KB | 46× |
| 4 | usually empty, 20 swaps per pass (100 000 entities) | 15.9 / 15.3 µs | 13.7 / 7.37 µs | 13.1 / 7.50 µs | 0.82× / 0.49× |
|  | 5 queries, 100 matches each, 40 toggles per frame | 45.7 / 44.0 µs | 31.5 / 17.1 µs | 32.5 / 17.3 µs | 0.71× / 0.39× |
| 5 | 20 small queries, a shared tag toggled on 30 per frame | 17.3 / 17.5 µs | 22.4 / 14.7 µs | 22.2 / 14.5 µs | 1.28× / 0.83× |
| 6 | `query(A, pair(ChildOf, parent))` per parent (1000 × 5) | 891 / 884 ns | 587 / 507 ns | 586 / 483 ns | 0.66× / 0.55× |
|  | 2 inline queries per new caster | 1.65 / 1.78 µs | 4.19 / 3.50 µs | 4.04 / 3.46 µs | 2.45× / 1.94× |
|  | the same, memory per caster | 0 B | 376 B | 376 B | — |
| 7 | `world:each` over 100 000, per entity | 29 / 25 ns | 40 / 32 ns | 31 / 24 ns | 1.08× / 0.99× |
|  | `world:children`, 1000 children, per child | 29 / 25 ns | 40 / 33 ns | 33 / 25 ns | 1.13× / 0.98× |
| 8 | 8 kinds in turn, 3 values, for-in, per match | 41 / 33 ns | 87 / 72 ns | 86 / 74 ns | 2.10× / 2.22× |
|  | the same, `each` | 41 / 33 ns | 64 / 46 ns | 60 / 51 ns | 1.46× / 1.55× |
|  | the same, `each`, the kind from a slot pool | 41 / 33 ns | 37 / 21 ns | 36 / 21 ns | 0.88× / 0.63× |
| 9 | delete entities with 100 targets, per pair | 29 / 29 ns | 64 / 45 ns | 62 / 46 ns | 2.12× / 1.56× |
| 10 | 8 components on 1 entity in 64 of 131 072, memory per entity | 170 B | 660 B | 660 B | 3.9× |
|  | the same, time per entity | 2.72 / 2.07 µs | 2.50 / 1.69 µs | 2.58 / 1.65 µs | 0.95× / 0.80× |

1. `(*, T)` values. jecs reads the column of the first pair of `T` in each archetype. mErCS
   keeps a mirror for a wildcard whose values a query returns: value pages with the value of one
   pair of each entity (the lowest relation slot for `(*, T)`, the lowest target slot for
   `(R, *)`), updated by every change of its pairs; the query reads it like the column of a
   component. A mirror keeps about 17 B per member (a `(*, T)` mirror also notes the pair that
   gives the value of a slot with several pairs of `T`): the world of this case with its query
   takes 254 B per entity (jecs: 315 B).
2. `(R, *)` values: the same mirror; the world with its query takes 157 B per entity (jecs:
   312 B).
3. The memory of cached queries. A query of an archetype ECS keeps a list of archetypes; a
   cached query of mErCS over scattered matches keeps a list of its matches (the entity and its
   index in the value page), which keeps its loops fast over scattered matches. The arrays of
   the list have their exact size, and the first list of a query is built from the spans that
   the choice of its iteration mode found. A list of words or of one number per match would take
   2–30× less memory, but its loops would be 20–250 % slower.
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
   a buffer that the world reuses: the words of an id with at most 64 words of members by their
   sorted keys, a larger id through the levels of its bitset, a full word copied at once. 0.2.2
   walked the bitsets during the loop.
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

| Case | jecs 0.11.0 + OB | mErCS 0.2.2 | mErCS 0.2.3 | 0.2.3 / jecs |
|---|---|---|---|---|
| a tag of the query added and removed, per cycle (an entry and an exit) | 652 / 597 ns | 738 / 510 ns | 758 / 512 ns | 1.16× / 0.86× |
| members of the query deleted, per entity | 537 / 532 ns | 566 / 334 ns | 584 / 340 ns | 1.09× / 0.64× |
| children moved to another parent, `(ChildOf, *)` monitored, per move | 497 / 422 ns | 649 / 434 ns | 634 / 437 ns | 1.28× / 1.04× |

The monitor itself costs about what the monitor of the addon costs on top of the signals of the
ids; in the interpreter the difference comes from the operations under it. Deleting an entity
whose ids have `OnRemove` hooks or signals runs its hooks before any id goes, which jecs does in
its loop over the columns: one hook adds about 170 ns per delete in the interpreter and 90 ns in
native code (jecs: 24 ns and 35 ns). A delete runs the listener of one required id of a monitor,
the others are quiet then. A child moved to another parent takes 398 / 253 ns without any
monitor, 1.43× / 1.20× the time of jecs (278 / 210 ns). In native code mErCS is faster than jecs
in two of the three cases and on par in the third (1.04×).

### Single operations

`bench/run.luau`, 131 072 entities. jecs has no `query:each`: its rows compare `each` with the
jecs for-in loop over the same world.

#### Entities

| Scenario | jecs 0.11.0 | mErCS 0.2.2 | mErCS 0.2.3 | 0.2.3 / jecs |
|---|---|---|---|---|
| create an entity | 179 / 155 ns | 40 / 27 ns | 38 / 26 ns | 0.21× / 0.17× |
| delete an entity with 4 components | 369 / 356 ns | 417 / 228 ns | 425 / 232 ns | 1.15× / 0.65× |

#### Components

| Scenario | jecs 0.11.0 | mErCS 0.2.2 | mErCS 0.2.3 | 0.2.3 / jecs |
|---|---|---|---|---|
| add a first component | 123 / 97 ns | 189 / 114 ns | 178 / 116 ns | 1.45× / 1.20× |
| set an existing component | 63 / 59 ns | 65 / 44 ns | 65 / 44 ns | 1.04× / 0.76× |
| remove a component | 181 / 164 ns | 116 / 58 ns | 115 / 58 ns | 0.64× / 0.35× |
| add when the entity has 5 | 336 / 274 ns | 130 / 71 ns | 128 / 72 ns | 0.38× / 0.26× |
| remove when the entity has 6 | 356 / 312 ns | 113 / 57 ns | 113 / 57 ns | 0.32× / 0.18× |
| add when the entity has 20 | 1.50 / 1.22 µs | 130 / 73 ns | 131 / 74 ns | 0.09× / 0.06× |
| remove when the entity has 21 | 1.40 / 1.16 µs | 116 / 57 ns | 115 / 55 ns | 0.08× / 0.05× |
| add when the entity has 40 | 2.81 / 2.37 µs | 128 / 66 ns | 128 / 70 ns | 0.05× / 0.03× |
| remove when the entity has 41 | 2.82 / 2.34 µs | 113 / 55 ns | 111 / 57 ns | 0.04× / 0.02× |

#### Tags

| Scenario | jecs 0.11.0 | mErCS 0.2.2 | mErCS 0.2.3 | 0.2.3 / jecs |
|---|---|---|---|---|
| add a tag | 330 / 269 ns | 94 / 58 ns | 94 / 58 ns | 0.28× / 0.21× |
| remove a tag | 324 / 296 ns | 108 / 65 ns | 108 / 66 ns | 0.33× / 0.22× |
| toggle a tag on 10 % of the entities per frame | 978 / 636 ns | 165 / 99 ns | 168 / 99 ns | 0.17× / 0.16× |

#### Access

| Scenario | jecs 0.11.0 | mErCS 0.2.2 | mErCS 0.2.3 | 0.2.3 / jecs |
|---|---|---|---|---|
| `get` 1 id | 60 / 51 ns | 49 / 38 ns | 49 / 38 ns | 0.82× / 0.75× |
| `get` 2 ids | 66 / 58 ns | 60 / 40 ns | 61 / 41 ns | 0.92× / 0.70× |
| `get` 4 ids | 82 / 64 ns | 95 / 51 ns | 93 / 52 ns | 1.13× / 0.81× |
| `get` 8 ids (jecs: at most 4) | — | 243 / 117 ns | 239 / 118 ns | — |
| `has` 1 id | 60 / 42 ns | 51 / 31 ns | 50 / 31 ns | 0.84× / 0.73× |
| `has` 4 ids | 76 / 47 ns | 94 / 44 ns | 99 / 43 ns | 1.31× / 0.91× |
| `has` 8 ids (jecs: at most 4) | — | 183 / 71 ns | 188 / 71 ns | — |

#### Pairs

| Scenario | jecs 0.11.0 | mErCS 0.2.2 | mErCS 0.2.3 | 0.2.3 / jecs |
|---|---|---|---|---|
| `pair(R, T)` | 20 / 8.6 ns | 20 / 8.8 ns | 21 / 8.8 ns | 1.04× / 1.02× |
| add a pair | 261 / 185 ns | 282 / 173 ns | 278 / 175 ns | 1.06× / 0.95× |
| set the value of an existing pair | 75 / 65 ns | 72 / 52 ns | 72 / 52 ns | 0.96× / 0.81× |
| remove a pair | 228 / 216 ns | 198 / 109 ns | 200 / 108 ns | 0.88× / 0.50× |
| `target` (4 pairs) | 153 / 138 ns | 67 / 45 ns | 68 / 44 ns | 0.44× / 0.32× |
| `ChildOf` children, per child (10 000 parents × 5) | 153 / 153 ns | 153 / 119 ns | 130 / 92 ns | 0.85× / 0.60× |
| add a pair with a target of its own | 7.17 / 6.54 µs | 3.15 / 2.66 µs | 3.19 / 2.80 µs | 0.44× / 0.43× |
| delete a target: `Remove` (1000 × 100 sources, per source) | 172 / 168 ns | 145 / 78 ns | 147 / 77 ns | 0.85× / 0.46× |
| delete a parent: `ChildOf` cascade (per child) | 286 / 299 ns | 364 / 227 ns | 366 / 231 ns | 1.28× / 0.77× |

#### Queries (per entity or match)

| Scenario | jecs 0.11.0 | mErCS 0.2.2 | mErCS 0.2.3 | 0.2.3 / jecs |
|---|---|---|---|---|
| for-in, 4 values, 8192 entities per archetype | 43 / 34 ns | 47 / 33 ns | 47 / 32 ns | 1.09× / 0.95× |
| `query:each`, the same (ratio: against the jecs for-in) | — | 31 / 15 ns | 30 / 16 ns | 0.70× / 0.46× |
| manual loop (`spans` / jecs archetypes), the same | 12 / 4.9 ns | 14 / 4.8 ns | 14 / 4.9 ns | 1.11× / 1.00× |
| for-in, 4 values, 256 entities per archetype | 47 / 38 ns | 52 / 34 ns | 52 / 34 ns | 1.11× / 0.91× |
| `query:each`, the same (against the jecs for-in) | — | 35 / 17 ns | 35 / 17 ns | 0.74× / 0.44× |
| manual loop, the same | 20 / 6.9 ns | 17 / 6.1 ns | 17 / 6.3 ns | 0.84× / 0.91× |
| for-in, 4 values, 16 entities per archetype | 65 / 51 ns | 67 / 40 ns | 67 / 41 ns | 1.03× / 0.79× |
| `query:each`, the same (against the jecs for-in) | — | 48 / 21 ns | 48 / 21 ns | 0.73× / 0.41× |
| manual loop, the same | 46 / 30 ns | 31 / 9.1 ns | 31 / 9.0 ns | 0.67× / 0.30× |
| for-in, 4 values, 1 entity per archetype | 256 / 169 ns | 74 / 45 ns | 73 / 45 ns | 0.29× / 0.27× |
| `query:each`, the same (against the jecs for-in) | — | 54 / 25 ns | 54 / 26 ns | 0.21× / 0.15× |
| manual loop, the same | 173 / 105 ns | 36 / 14 ns | 36 / 14 ns | 0.21× / 0.13× |
| a query created and iterated once | 42 / 35 ns | 48 / 32 ns | 47 / 33 ns | 1.12× / 0.95× |
| for-in, 1 value of an entity with 4 | 33 / 28 ns | 36 / 28 ns | 36 / 27 ns | 1.11× / 0.97× |
| for-in with `without` (half excluded) | 31 / 27 ns | 37 / 30 ns | 36 / 30 ns | 1.17× / 1.09× |
| `query:each`, the same (against the jecs for-in) | — | 21 / 13 ns | 21 / 13 ns | 0.67× / 0.46× |
| for-in over a sparse match (1 %) | 38 / 33 ns | 62 / 57 ns | 62 / 56 ns | 1.64× / 1.68× |
| `query:each`, the same (against the jecs for-in) | — | 39 / 28 ns | 39 / 31 ns | 1.04× / 0.93× |
| the first loop of a new query (2000 archetypes), per query | 125 / 118 µs | 423 / 322 ns | 407 / 326 ns | 0.003× / 0.003× |
| a small query created on every call (15 of 1000), per query | 1.30 / 1.12 µs | 1.17 / 1.04 µs | 1.17 / 1.05 µs | 0.90× / 0.94× |
| a query of a concrete pair created on every call (15 of 1000), per query | 1.30 / 1.21 µs | 1.02 µs / 884 ns | 1.01 µs / 853 ns | 0.78× / 0.70× |
| the same, nothing matches (0 of 1000) | 301 / 280 ns | 165 / 147 ns | 165 / 148 ns | 0.55× / 0.53× |
| an entity used as a term in 4 inline queries, then deleted, per entity | 1.90 / 1.69 µs | 5.80 / 4.89 µs | 5.45 / 5.05 µs | 2.87× / 2.99× |
| a query with 10 terms | 95 / 66 ns | 99 / 60 ns | 97 / 57 ns | 1.02× / 0.86× |

#### Batch operations (per match; jecs: a collect-and-change loop)

| Scenario | jecs 0.11.0 | mErCS 0.2.2 | mErCS 0.2.3 | 0.2.3 / jecs |
|---|---|---|---|---|
| add a tag to the matches (half of the entities) | 295 / 241 ns | 37 / 13 ns | 37 / 12 ns | 0.13× / 0.05× |
| set a component on the matches | 291 / 243 ns | 70 / 26 ns | 69 / 26 ns | 0.24× / 0.11× |
| remove a component from the matches | 274 / 266 ns | 38 / 13 ns | 39 / 13 ns | 0.14× / 0.05× |
| delete the matches | 417 / 419 ns | 446 / 243 ns | 447 / 249 ns | 1.07× / 0.59× |
| count the matches | 31 / 27 ns | 7.0 / 2.6 ns | 7.2 / 2.4 ns | 0.23× / 0.09× |

#### Churn (per cycle)

| Scenario | jecs 0.11.0 | mErCS 0.2.2 | mErCS 0.2.3 | 0.2.3 / jecs |
|---|---|---|---|---|
| spawn and despawn (10 components, 2 tags) | 3.98 / 3.61 µs | 2.40 / 1.30 µs | 2.39 / 1.33 µs | 0.60× / 0.37× |
| a hierarchy of 1 + 5 `ChildOf`, spawned and deleted | 21.2 / 18.8 µs | 11.2 / 6.98 µs | 10.5 / 6.90 µs | 0.49× / 0.37× |

### Memory and garbage

Bytes kept per unit, the same in both modes:

| Kept per unit | jecs 0.11.0 | mErCS 0.2.2 | mErCS 0.2.3 |
|---|---|---|---|
| an empty entity | 240 B | 32 B | 32 B |
| an entity with 4 components | 320 B | 131 B | 131 B |
| an entity with 10 components and 5 tags | 417 B | 236 B | 236 B |
| a `ChildOf` child (10 000 parents × 5) | 725 B | 344 B | 344 B |
| an entity with a tag of its own | 1629 B | 978 B | 978 B |
| a pair with a target of its own | 2263 B | 1457 B | 1457 B |
| a component of 1000 on 100 entities each, per add | 397 B | 162 B | 162 B |
| growth per hierarchy spawn / despawn cycle | 218 B | 0 B | 0 B |
| an entity used in 4 inline queries, then deleted | 0 B | 1 B | 1 B |

Garbage per loop over 200 entities: a query written inline (`for ... in world:query(A, B)`)
allocates 921 bytes in jecs 0.11.0 and 80 bytes in mErCS 0.2.2 and 0.2.3; a stored query
allocates nothing in all of them. A loop of `world:each` allocates 289 bytes in jecs, 736 bytes
in mErCS 0.2.2 and 176 bytes in 0.2.3 (its iterator: the buffer of the members is reused).

### Roblox Studio: Benchmarker

The files of `bench/visual/` run in Roblox Studio with the Benchmarker plugin (v7.3.1): Edit
mode, native code (the library and jecs are `--!native`), 1000 calls of each function,
jecs 0.11.0 against mErCS 0.2.3 (the functions are named with the versions). The place of
`benchmarker.project.json` holds only the libraries and these files
([Development](../development/README.md#benchmarker-roblox-studio)). The screenshots show
the results; compare the medians (50th percentile): the "Average" of Benchmarker is the
midpoint of the minimum and the maximum, not the mean.

| File | What |
|---|---|
| `batch.bench.luau` | add and remove a tag on 1000 of 2000 entities: batch operations against a jecs collect-and-change loop |
| `despawn.bench.luau` | delete 1000 entities with 4 components and a tag |
| `insertion.bench.luau` | 8 components into 500 existing entities |
| `pairs.bench.luau` | 100 parents with 10 `ChildOf` children that also target a parent through a relation, then the parents are deleted |
| `query.bench.luau` | 10 passes of a 4-component query over 4096 entities: for-in, and `query:each` for mErCS |
| `query_churn.bench.luau` | a query case: a tag of the query toggled on 1 or 100 entities before each pass |
| `query_empty.bench.luau` | a query case: 100 passes of a query that never matches |
| `query_read4.bench.luau` | a query case: 4 values read per match (80 000 entities) |
| `query_scattered.bench.luau` | a query case: a 4-component query over 50 000 entities scattered by churn |
| `query_wildcard.bench.luau` | a query case: `(*, T)` with a pair toggled before each pass |
| `remove.bench.luau` | remove one of 5 components from 1000 entities |
| `spawn.bench.luau` | 1000 entities with 4 components |

![Benchmarker: batch](benchmarker-batch.PNG)

![Benchmarker: despawn](benchmarker-despawn.PNG)

![Benchmarker: insertion](benchmarker-insertion.PNG)

![Benchmarker: pairs](benchmarker-pairs.PNG)

![Benchmarker: query](benchmarker-query.PNG)

![Benchmarker: query_churn](benchmarker-query-churn.PNG)

![Benchmarker: query_empty](benchmarker-query-empty.PNG)

![Benchmarker: query_read4](benchmarker-query-read4.PNG)

![Benchmarker: query_scattered](benchmarker-query-scattered.PNG)

![Benchmarker: query_wildcard](benchmarker-query-wildcard.PNG)

![Benchmarker: remove](benchmarker-remove.PNG)

![Benchmarker: spawn](benchmarker-spawn.PNG)

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
