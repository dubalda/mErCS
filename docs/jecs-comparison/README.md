# mErCS and jecs

How mErCS 0.2.0 differs from [jecs](https://github.com/Ukendio/jecs) 0.11.0: the design,
the behaviour, the numbers (with mErCS 0.1.2, the previous release, beside them), and how to
move code over.

## Contents

- [Design](#design)
- [Compatibility](#compatibility)
- [Differences in behaviour](#differences-in-behaviour)
- [Beyond jecs](#beyond-jecs)
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

| | jecs 0.11.0 | mErCS 0.2.0 |
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
- The jecs observer addon (`modules/OB`) depends on archetypes and does not work; use hooks,
  signals or change tracking.
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
  (`world:query(...)` without a concrete pair) it does nothing else: such a query is cached
  already.
- `world:exists(e)` is also true for a slot reserved by a slot pool and not handed out yet.

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

## Performance

Benchmarks in `bench/` with `luau` 0.740: jecs 0.11.0 (the Wally dev packages), mErCS 0.1.2
(the previous release: `bash tools/previous.sh` puts it into `tmp/previous`) and mErCS 0.2.0.
Cells read "interpreter / native": `-O2` (the Roblox client) / `-O2 --codegen` (the Roblox
server). The ratio columns give the time of mErCS 0.2.0 divided by the time of jecs 0.11.0
(lower is better). The timings vary by about ±10 % between runs of the same build.
[Roblox Studio: Benchmarker](#roblox-studio-benchmarker) compares jecs 0.11.0 and mErCS 0.2.0
inside Roblox Studio. mErCS 0.2.1, a patch release, changes what the notes marked **0.2.1**
below say (the memory table has a column for it); the other numbers are those of 0.2.0.

### A synthetic game frame

`bench/frame.luau`: 3000 units with 2 attachments each follow their parents, 60 projectiles
spawn and expire per frame, damage uses a one-frame tag, 5 % of the units switch AI state
tags; plain for-in loops, the same code for all three. The median frame time (the middle one
of 3 runs); the queries are written inline in every frame, or created once and `:cached()`
(the recommended jecs style):

| | jecs 0.11.0 | mErCS 0.1.2 | mErCS 0.2.0 | 0.2.0 / jecs |
|---|---|---|---|---|
| interpreter, inline queries | 6.70 ms | 3.11 ms | 3.16 ms | 0.47× |
| interpreter, cached queries | 6.24 ms | 3.18 ms | 3.20 ms | 0.51× |
| native, inline queries | 5.78 ms | 2.22 ms | 2.33 ms | 0.40× |
| native, cached queries | 5.43 ms | 2.12 ms | 2.46 ms | 0.45× |

mErCS 0.2.0 is 1–15 % slower than 0.1.2 here: several queries of the frame change by
hundreds of entities every frame, and 0.2.0 updates or rebuilds their match lists where 0.1.2
scanned the bitsets (see [Where mErCS is still slower](#where-mercs-is-still-slower)).
**0.2.1** passes over the bitsets of a query whose list changed by more than a quarter since
its previous loop, and is on par with 0.1.2 (medians of 3 runs of each: 0.93–0.98× of 0.1.2
in the interpreter, 1.02–1.04× in native code).

### A long session

`bench/leak.luau`: 5 of 200 enemies die and respawn every frame, 10 % of 500 units retarget
a living enemy through a pair `(Targeting, enemy)` and switch a state tag; interpreter. Heap
growth since the start and time per frame:

| frame | jecs 0.11.0 | jecs 0.11.0 + `world:cleanup()` every 600 frames | mErCS 0.1.2 | mErCS 0.2.0 |
|---|---|---|---|---|
| 1000 | +3.6 MB, 0.21 ms | +3.6 MB, 0.24 ms | +0.4 MB, 0.09 ms | +0.4 MB, 0.11 ms |
| 3000 | +9.0 MB, 0.23 ms | +8.8 MB, 0.23 ms | +0.4 MB, 0.09 ms | +0.4 MB, 0.12 ms |
| 5000 | +15.4 MB, 0.23 ms | +15.7 MB, 0.23 ms | +0.4 MB, 0.09 ms | +0.4 MB, 0.11 ms |

The archetypes of dead targets stay in jecs (cleanup does not release them all); in mErCS
nothing accumulates. The query of the frame changes by about 60 of its 250 entities every
frame: 0.2.0 updates its match list, which takes longer than the scan of 0.1.2. **0.2.1**:
0.09–0.10 ms per frame (0.1.2: 0.09 ms, 0.2.0: 0.10–0.11 ms in the same runs), and +0.33 MB:
the `(*, T)` records of the enemies, the targets of `(Targeting, enemy)`, stay small.

### Query cases

Five cases where an archetype ECS is expected to be at its best (`bench/query_cases.luau`,
and the `query cases` group of `bench/run.luau`). jecs runs for-in loops over cached queries;
mErCS builds the same worlds and runs the same loops through `query:each`, which replaces a
for-in loop fully when it does not break early. Time of one pass, the minimum of 18 runs:

| Case | jecs 0.11.0 | mErCS 0.1.2 | mErCS 0.2.0 | 0.2.0 / jecs |
|---|---|---|---|---|
| Scattered after recycling | 124 / 103 µs | 80.3 / 60.3 µs | 87.2 / 62.9 µs | 0.70× / 0.61× |
| Churn on a queried tag, 1 toggle per pass | 306 / 258 µs | 702 / 465 µs | 257 / 188 µs | 0.84× / 0.73× |
| Churn on a queried tag, 100 toggles per pass | 230 / 197 µs | 536 / 355 µs | 235 / 167 µs | 1.02× / 0.85× |
| Read 4 components | 1.92 / 1.42 ms | 1.22 ms / 643 µs | 1.28 ms / 662 µs | 0.67× / 0.47× |
| `(*, T)` with churn | 796 / 689 µs | 14.5 / 13.2 ms | 528 / 341 µs | 0.66× / 0.50× |
| Usually empty | 64 / 59 ns | 194 / 67.3 µs | 41 / 26 ns | 0.64× / 0.44× |

- Scattered after recycling: 50 000 entities with random subsets of 8 components, then
  100 000 deletes and respawns; a pass of a 4-component query (3125 matches).
- Churn on a queried tag: 70 000 entities with `Position`, every 7th with `Velocity`; the
  query of both without `Stunned`, `Stunned` toggled on 1 or 100 movers before each pass.
  0.1.2 scanned its bitsets again after every change; 0.2.0 re-checks the changed slots only.
  With 100 toggles the interpreter is on par with jecs (1.02–1.06× over runs): the list edits
  cost about what the cheaper toggles save.
- Read 4 components: 80 000 entities, the fourth component on half of them.
- `(*, T)` with churn: 20 000 entities with one of 64 pairs `(R, T)`; a pair toggled before
  each pass of `Health` and `(*, T)`. 0.1.2 rebuilt `(*, T)` from all its pairs after every
  change and read all 64 pairs of every match to find a value.
- Usually empty: 100 000 entities, each with `Stunned` or `Invulnerable`; the query of both.
  0.1.2 scanned its bitsets on every pass; 0.2.0 keeps an empty list, and a pass after which
  nothing changed costs a comparison.

`luau -O2 --codegen bench/query_cases.luau` runs the same cases with the test kit of jecs:
one run per case, first loops included.

### A sparse world

The shape of a game with many entities per creature (`bench/run.luau`, group `sparse world`):
700 creatures (200 alive, 500 dead), each created right before its 500 skills, 350 000
entities in all; a pass of each query of a frame after the changes the game makes. A
creature sits alone in its value page, so a query over creatures reads a word per creature;
in the "pool" columns the creatures come from a slot pool (`world:pool()`, new in mErCS 0.2.0),
which keeps them together. Time of one pass, the minimum of 18 runs:

| Pass | jecs 0.11.0 | mErCS 0.1.2 | mErCS 0.2.0 | 0.2.0 / jecs | mErCS 0.2.0, pool | pool / jecs |
|---|---|---|---|---|---|---|
| Alive creatures, nothing changed | 6.18 / 5.54 µs | 6.07 / 4.37 µs | 5.42 / 3.96 µs | 0.88× / 0.71× | 7.00 / 3.95 µs | 1.13× / 0.71× |
| Alive creatures, `Dead` added to one and removed | 7.08 / 6.36 µs | 94.5 / 60.4 µs | 7.28 / 4.91 µs | 1.03× / 0.77× | 7.47 / 4.32 µs | 1.06× / 0.68× |
| Running creatures, `Run` toggled on one | 3.46 / 3.09 µs | 22.5 / 16.1 µs | 4.74 / 3.37 µs | 1.37× / 1.09× | 2.73 / 1.78 µs | 0.79× / 0.58× |
| A tag added to one creature, a pass, removed, a pass | 1.21 / 1.09 µs | 8.24 / 6.36 µs | 2.10 / 1.34 µs | 1.74× / 1.23× | 1.59 / 1.02 µs | 1.31× / 0.94× |
| A tag nobody has | 65 / 60 ns | 246 / 216 ns | 44 / 31 ns | 0.67× / 0.51× | 44 / 31 ns | 0.68× / 0.51× |
| All with `Model` (creatures and corpses) | 21.2 / 18.6 µs | 21.2 / 14.8 µs | 18.8 / 13.2 µs | 0.89× / 0.71× | 15.7 / 8.82 µs | 0.74× / 0.47× |
| A skill changes state, 10 queries over skills in `Cast` | 152 / 117 µs | 309 / 196 µs | 105 / 66.2 µs | 0.69× / 0.56× | 108 / 68.1 µs | 0.71× / 0.58× |

Without a pool, a change of one creature before a pass (`Run` toggled, a tag added and
removed) costs a list edit: the creature is a group of its own in the match list of the query,
and the group is inserted or removed. jecs moves the creature to another archetype, and its
pass costs nothing more.

### Single operations

`bench/run.luau`, 131 072 entities, the minimum of 18 runs in each mode; ratios within ±10 %
of 1.0 vary between runs. jecs has no `query:each`: its rows compare `each` with the jecs
for-in loop over the same world.

#### Entities

| Scenario | jecs 0.11.0 | mErCS 0.1.2 | mErCS 0.2.0 | 0.2.0 / jecs |
|---|---|---|---|---|
| create an entity | 164 / 162 ns | 38 / 26 ns | 37 / 26 ns | 0.23× / 0.16× |
| delete an entity with 4 components | 353 / 346 ns | 353 / 190 ns | 378 / 218 ns | 1.07× / 0.63× |

#### Components

| Scenario | jecs 0.11.0 | mErCS 0.1.2 | mErCS 0.2.0 | 0.2.0 / jecs |
|---|---|---|---|---|
| add a first component | 121 / 93 ns | 163 / 109 ns | 172 / 110 ns | 1.43× / 1.19× |
| set an existing component | 61 / 56 ns | 61 / 42 ns | 61 / 42 ns | 1.00× / 0.75× |
| remove a component | 177 / 157 ns | 108 / 54 ns | 113 / 60 ns | 0.64× / 0.39× |
| add when the entity has 5 | 335 / 262 ns | 124 / 70 ns | 125 / 72 ns | 0.37× / 0.27× |
| remove when the entity has 6 | 315 / 298 ns | 107 / 54 ns | 111 / 56 ns | 0.35× / 0.19× |
| add when the entity has 20 | 1.34 / 1.10 µs | 118 / 66 ns | 123 / 67 ns | 0.09× / 0.06× |
| remove when the entity has 21 | 1.34 / 1.16 µs | 104 / 54 ns | 106 / 54 ns | 0.08× / 0.05× |
| add when the entity has 40 | 2.64 / 2.13 µs | 119 / 68 ns | 123 / 67 ns | 0.05× / 0.03× |
| remove when the entity has 41 | 2.58 / 2.24 µs | 103 / 55 ns | 106 / 57 ns | 0.04× / 0.03× |

#### Tags

| Scenario | jecs 0.11.0 | mErCS 0.1.2 | mErCS 0.2.0 | 0.2.0 / jecs |
|---|---|---|---|---|
| add a tag | 314 / 255 ns | 90 / 52 ns | 93 / 58 ns | 0.30× / 0.23× |
| remove a tag | 315 / 284 ns | 102 / 67 ns | 107 / 65 ns | 0.34× / 0.23× |
| toggle a tag on 10 % of the entities per frame | 889 / 599 ns | 153 / 92 ns | 159 / 99 ns | 0.18× / 0.16× |

#### Access

| Scenario | jecs 0.11.0 | mErCS 0.1.2 | mErCS 0.2.0 | 0.2.0 / jecs |
|---|---|---|---|---|
| `get` 1 id | 58 / 49 ns | 47 / 43 ns | 48 / 38 ns | 0.82× / 0.77× |
| `get` 2 ids | 65 / 59 ns | 59 / 51 ns | 59 / 40 ns | 0.91× / 0.68× |
| `get` 4 ids | 80 / 61 ns | 84 / 54 ns | 86 / 53 ns | 1.08× / 0.87× |
| `get` 8 ids (jecs: at most 4) | — | 220 / 116 ns | 215 / 117 ns | — |
| `has` 1 id | 56 / 39 ns | 51 / 30 ns | 49 / 30 ns | 0.88× / 0.79× |
| `has` 4 ids | 70 / 46 ns | 92 / 41 ns | 91 / 42 ns | 1.30× / 0.92× |
| `has` 8 ids (jecs: at most 4) | — | 166 / 70 ns | 166 / 69 ns | — |

#### Pairs

| Scenario | jecs 0.11.0 | mErCS 0.1.2 | mErCS 0.2.0 | 0.2.0 / jecs |
|---|---|---|---|---|
| `pair(R, T)` | 19 / 10 ns | 20 / 10 ns | 20 / 10 ns | 1.06× / 1.00× |
| add a pair | 260 / 180 ns | 256 / 163 ns | 263 / 164 ns | 1.01× / 0.91× |
| set the value of an existing pair | 71 / 65 ns | 69 / 51 ns | 68 / 52 ns | 0.95× / 0.80× |
| remove a pair | 224 / 202 ns | 180 / 101 ns | 187 / 104 ns | 0.84× / 0.52× |
| `target` (4 pairs) | 152 / 134 ns | 64 / 44 ns | 65 / 44 ns | 0.43× / 0.33× |
| `ChildOf` children, per child (10 000 parents × 5) | 139 / 133 ns | 152 / 116 ns | 147 / 106 ns | 1.06× / 0.79× |
| add a pair with a target of its own | 5.89 / 5.74 µs | 3.10 / 2.86 µs | 2.93 / 2.64 µs | 0.50× / 0.46× |
| delete a target: `Remove` (1000 × 100 sources, per source) | 165 / 165 ns | 132 / 70 ns | 132 / 72 ns | 0.80× / 0.43× |
| delete a parent: `ChildOf` cascade (per child) | 278 / 298 ns | 316 / 193 ns | 330 / 204 ns | 1.19× / 0.68× |

#### Queries (per entity or match)

| Scenario | jecs 0.11.0 | mErCS 0.1.2 | mErCS 0.2.0 | 0.2.0 / jecs |
|---|---|---|---|---|
| for-in, 4 values, 8192 entities per archetype | 43 / 34 ns | 45 / 32 ns | 46 / 33 ns | 1.06× / 0.98× |
| `query:each`, the same (ratio: against the jecs for-in) | — | 31 / 16 ns | 32 / 16 ns | 0.74× / 0.48× |
| manual loop (`spans` / jecs archetypes), the same | 12 / 4.7 ns | 13 / 4.9 ns | 12 / 4.5 ns | 1.05× / 0.96× |
| for-in, 4 values, 256 entities per archetype | 46 / 38 ns | 50 / 34 ns | 51 / 34 ns | 1.10× / 0.91× |
| `query:each`, the same (against the jecs for-in) | — | 33 / 17 ns | 36 / 17 ns | 0.77× / 0.45× |
| manual loop, the same | 15 / 7.2 ns | 16 / 6.5 ns | 16 / 5.8 ns | 1.08× / 0.81× |
| for-in, 4 values, 16 entities per archetype | 63 / 49 ns | 65 / 39 ns | 66 / 40 ns | 1.06× / 0.83× |
| `query:each`, the same (against the jecs for-in) | — | 47 / 20 ns | 47 / 21 ns | 0.75× / 0.44× |
| manual loop, the same | 44 / 29 ns | 29 / 9.4 ns | 30 / 9.0 ns | 0.69× / 0.31× |
| for-in, 4 values, 1 entity per archetype | 252 / 162 ns | 72 / 44 ns | 74 / 46 ns | 0.29× / 0.29× |
| `query:each`, the same (against the jecs for-in) | — | 53 / 25 ns | 54 / 26 ns | 0.22× / 0.16× |
| manual loop, the same | 166 / 97 ns | 34 / 14 ns | 36 / 14 ns | 0.22× / 0.14× |
| a query created and iterated once | 42 / 34 ns | 46 / 31 ns | 45 / 31 ns | 1.07× / 0.92× |
| for-in, 1 value of an entity with 4 | 32 / 27 ns | 36 / 26 ns | 35 / 28 ns | 1.09× / 1.03× |
| for-in with `without` (half excluded) | 32 / 27 ns | 35 / 32 ns | 36 / 29 ns | 1.12× / 1.07× |
| `query:each`, the same (against the jecs for-in) | — | 20 / 12 ns | 21 / 12 ns | 0.67× / 0.45× |
| for-in over a sparse match (1 %) | 38 / 31 ns | 58 / 51 ns | 64 / 52 ns | 1.67× / 1.66× |
| `query:each`, the same (against the jecs for-in) | — | 36 / 26 ns | 38 / 28 ns | 1.00× / 0.88× |
| the first loop of a new query (2000 archetypes), per query | 104 / 103 µs | 447 / 353 ns | 386 / 307 ns | 0.004× / 0.003× |
| a small query created on every call (15 of 1000), per query | 1.26 / 1.11 µs | 1.18 / 1.08 µs | 1.18 µs / 996 ns | 0.94× / 0.90× |
| a query with 10 terms | 95 / 65 ns | 89 / 57 ns | 87 / 56 ns | 0.92× / 0.86× |

#### Batch operations (per match; jecs: a collect-and-change loop)

| Scenario | jecs 0.11.0 | mErCS 0.1.2 | mErCS 0.2.0 | 0.2.0 / jecs |
|---|---|---|---|---|
| add a tag to the matches (half of the entities) | 286 / 244 ns | 33 / 11 ns | 34 / 11 ns | 0.12× / 0.05× |
| set a component on the matches | 291 / 241 ns | 62 / 21 ns | 63 / 21 ns | 0.22× / 0.09× |
| remove a component from the matches | 275 / 260 ns | 35 / 11 ns | 35 / 11 ns | 0.13× / 0.04× |
| delete the matches | 411 / 400 ns | 397 / 225 ns | 410 / 222 ns | 1.00× / 0.56× |
| count the matches | 34 / 27 ns | 6.8 / 2.3 ns | 6.6 / 2.4 ns | 0.19× / 0.09× |

#### Churn (per cycle)

| Scenario | jecs 0.11.0 | mErCS 0.1.2 | mErCS 0.2.0 | 0.2.0 / jecs |
|---|---|---|---|---|
| spawn and despawn (10 components, 2 tags) | 3.85 / 3.53 µs | 2.16 / 1.19 µs | 2.26 / 1.23 µs | 0.59× / 0.35× |
| a hierarchy of 1 + 5 `ChildOf`, spawned and deleted | 18.6 / 17.4 µs | 8.86 / 6.14 µs | 9.23 / 6.51 µs | 0.50× / 0.37× |

### Memory and garbage

Bytes kept per unit, the same in both modes:

| Kept per unit | jecs 0.11.0 | mErCS 0.1.2 | mErCS 0.2.0 | mErCS 0.2.1 |
|---|---|---|---|---|
| an empty entity | 240 B | 32 B | 32 B | 32 B |
| an entity with 4 components | 320 B | 131 B | 131 B | 131 B |
| an entity with 10 components and 5 tags | 417 B | 236 B | 236 B | 236 B |
| a `ChildOf` child (10 000 parents × 5) | 726 B | 457 B | 414 B | 344 B |
| an entity with a tag of its own | 1630 B | 946 B | 978 B | 978 B |
| a pair with a target of its own | 2264 B | 2033 B | 1809 B | 1457 B |
| a component of 1000 on 100 entities each, per add | 398 B | 162 B | 162 B | 162 B |
| growth per hierarchy spawn / despawn cycle | 218 B | 0 B | 0 B | 0 B |
| an entity used in 4 inline queries, then deleted | 0 B | 632 B | 492 B | 0 B |

In 0.2.1 the `(*, T)` record of a target is small until something reads it (a `ChildOf`
parent, a target of its own), and the shared query shapes of an entity are dropped when it is
deleted (0.1.2 and 0.2.0 kept them, and once 1024 shapes were used up no new shape was shared).

Garbage per loop of a 2-component query over 200 entities: a query written inline
(`for ... in world:query(A, B)`) allocates 922 bytes in jecs 0.11.0, 82 bytes in mErCS 0.1.2
and 72 bytes in mErCS 0.2.0 and 0.2.1 (the handle); a stored query allocates nothing in all of
them.

### Roblox Studio: Benchmarker

The files of `bench/visual/` run in Roblox Studio with the Benchmarker plugin (v7.3.1): Edit
mode, native code (the library and jecs are `--!native`), 1000 calls of each function,
jecs 0.11.0 against mErCS 0.2.0 (the functions are named with the versions). The place of
`benchmarker.project.json` holds only the libraries and these files
([Development](../development/README.md#benchmarker-roblox-studio)). The screenshots show
the results; compare the medians (50th percentile): the "Average" of Benchmarker is the
midpoint of the minimum and the maximum, not the mean.

| File | What |
|---|---|
| `spawn.bench.luau` | 1000 entities with 4 components |
| `insertion.bench.luau` | 8 components into 500 existing entities |
| `despawn.bench.luau` | delete 1000 entities with 4 components and a tag |
| `remove.bench.luau` | remove one of 5 components from 1000 entities |
| `pairs.bench.luau` | 100 parents with 10 `ChildOf` children that also target a parent through a relation, then the parents are deleted |
| `batch.bench.luau` | add and remove a tag on 1000 of 2000 entities: batch operations against a jecs collect-and-change loop |
| `query.bench.luau` | 10 passes of a 4-component query over 4096 entities: for-in, and `query:each` for mErCS |
| `query_scattered.bench.luau` | a query case: a 4-component query over 50 000 entities scattered by churn |
| `query_churn.bench.luau` | a query case: a tag of the query toggled on 1 or 100 entities before each pass |
| `query_read4.bench.luau` | a query case: 4 values read per match (80 000 entities) |
| `query_wildcard.bench.luau` | a query case: `(*, T)` with a pair toggled before each pass |
| `query_empty.bench.luau` | a query case: 100 passes of a query that never matches |

![Benchmarker: spawn](benchmarker-spawn.PNG)

![Benchmarker: insertion](benchmarker-insertion.PNG)

![Benchmarker: despawn](benchmarker-despawn.PNG)

![Benchmarker: remove](benchmarker-remove.PNG)

![Benchmarker: pairs](benchmarker-pairs.PNG)

![Benchmarker: batch](benchmarker-batch.PNG)

![Benchmarker: query](benchmarker-query.PNG)

![Benchmarker: query_scattered](benchmarker-query-scattered.PNG)

![Benchmarker: query_churn](benchmarker-query-churn.PNG)

![Benchmarker: query_read4](benchmarker-query-read4.PNG)

![Benchmarker: query_wildcard](benchmarker-query-wildcard.PNG)

![Benchmarker: query_empty](benchmarker-query-empty.PNG)

### Where mErCS is still slower

mErCS 0.2.0 against jecs 0.11.0:

- Native: a for-in over a sparse match (1.7×: the values of a sparse component sit in the
  hash part of their page; `each` 0.9×), adding a first component (1.2×), a for-in with
  `without` (1.07×), a for-in reading 1 value (1.03×). The sparse world without a slot pool:
  `Run` toggled on one creature (1.1×) and a tag added to one creature and removed (1.2×);
  with a pool both are faster than jecs.
- Interpreter: adding a first component (1.4×), `has` with 4 ids (1.3×), a `ChildOf` cascade
  (1.2×), the sparse for-in (1.7×; `each` on par), a for-in over dense data and `without`
  (1.05–1.12×), deleting an entity with 4 components (1.07×). The query case with 100
  toggles per pass is on par (1.02–1.06× over runs). The sparse world: a change of one
  creature before a pass (1.4–1.7× without a pool, 1.3× with a pool for the tag), and the
  alive creatures of a pool (1.1×: they lie in runs of full words, so the query scans the
  bitsets and plans the scan on every pass).

mErCS 0.2.0 against 0.1.2: a query whose entities change by many (dozens to hundreds) before
every loop updates its match list, which costs more than the scan of 0.1.2: the long session
takes 0.11 ms per frame against 0.09 ms, the synthetic frame 1–15 % longer. Deleting an entity
costs 3–15 % more (the change journals).

**0.2.1**: a query whose list changed by more than a quarter since its previous loop passes
over its bitsets, as 0.1.2 did: the synthetic frame is on par with 0.1.2, the long session
takes 0.09–0.10 ms per frame. Adding and removing a tag that a cached query observes still
costs 5–10 % more than in 0.1.2 (the change journals, the third level of bits): 1200 skills
whose state tags change by 200 or 800 between the loops of 5 inline queries (the group
`state tags` of `bench/run.luau`) take 1.06–1.15× the time of 0.1.2, and 0.81–0.88× the time
of 0.2.0. Against jecs 0.11.0, 0.2.1 is slower in two new rows of the matrix: a query of a
concrete pair written inline (2.9× / 2.4× with 15 matches: the query builds a new state on
every call; 0.2.0: 3.8× / 3.4×), and an entity used as a term in 4 inline queries and then
deleted (3.9× / 5.5×: the shared states of its shapes are created and dropped; 0.2.0 kept them
and used up the shared states).

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
   [Coming from jecs](../guide/README.md#coming-from-jecs)). A query with an entity as a term
   (`query:with(caster)`) shares a state per entity, up to 1024 shapes per world: for lookups
   over many live entities, a pair and `world:each(ecs.pair(Event, caster))` need no query
   state (see [Queries](../guide/README.md#queries)). Replace the observer addon with signals,
   hooks or `world:track` with the `:added` / `:changed` / `:removed` filters.
4. Replace "collect the matches, then change them" loops with batch operations
   (`query:add_all`, `set_all`, `remove_all`, `delete_all`, `count`), and state flags stored
   as components with tags (`Disabled` hides entities from queries without removing
   anything).
5. Code that depends on the iteration order of archetypes, or on the numbers of builtin ids
   after `Name` (`jecs.Rest` is 270 here), needs a look (see the differences above).
