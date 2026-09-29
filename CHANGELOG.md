# Changelog

## v0.2.2 — 2026-09-29

The strengths of jecs: ten cases where an archetype ECS is at its best and jecs 0.11.0 was far
ahead of mErCS 0.2.1 (the group `jecs strengths` of the benchmarks). Wildcards that return
values, queries over large terms that change and inline queries with a pair are now faster
than in jecs, the other cases are closer; the rest of the benchmarks is on par with 0.2.1
(see the table below and
[the comparison](https://github.com/dubalda/mErCS/tree/main/docs/jecs-comparison#the-strengths-of-jecs)).
New: query monitors, callbacks for the entities that enter and leave a query, in place of the
monitors of the jecs addon `modules/OB`.

### Fixed

- `(*, T)` returned the value of a pair picked by the iteration order of a hash table when an
  entity had several pairs of `T`, an order that changes with the pairs of other entities. It
  is now the pair with the lowest relation slot, the order of jecs (the first pair in the type
  of an archetype); `(R, *)` keeps the pair with the lowest target slot.
- `world:each` and `world:children` returned the members of an id out of ascending slot order
  when they lay in words of its bitset in different blocks of 1024 slots (the order of a hash
  table); they are now in ascending slot order, like queries.
- An id deleted inside its own `world:each` loop kept the loop returning all its members: a
  freed record kept its bitsets. They are cleared now, as `remove_all` clears them.
- `world:set` of a value on a tag (or on a tag pair) raises an error and leaves the tag added;
  its `OnAdd` hook, the signals, the monitors and change tracking did not see that add. The
  hooks run now (without the value) before the error.

### Query monitors

- `query:monitor()` returns `added(fn)`, `removed(fn)` and `disconnect()`: callbacks at the
  change that makes an entity enter or leave the query (an id of the query added or removed, an
  excluded id removed or added, `Disabled`, `clear`, `delete`, cleanup cascades, batch
  operations), one `added` per entry and one `removed` per exit. `removed` runs before the ids
  are removed, so the values of the entity can still be read. An exclusive relation that
  replaces a pair (`ChildOf` moved to another parent) makes no exit and no entry in a query with
  the relation and any target. A monitor listens to the signals of the ids of its query; a term
  `(*, T)` and change filters raise an error. A monitor keeps the terms of the query as they are
  when it is made (modifiers called on the query afterwards do not change it). It still listens
  to a deleted relation of a pair term, whose slot another entity may take (the query then
  matches the pairs of that entity): a new monitor is needed then.
- The object has the shape of the monitors of the jecs addon `modules/OB`: `OB.monitor(query)`
  becomes `query:monitor()`, and the 42 monitor cases of the tests of the addon pass
  (`test/jecs_compat/ob.luau`). The observers of the addon are signals with `query:has` (see
  [the guide](https://github.com/dubalda/mErCS/tree/main/docs/guide#query-monitors)).
- A delete runs the listener of one required id of a monitor; the others are quiet then (the
  delete of a member makes one check, not one per id).

### Hooks

- Deleting or clearing an entity whose ids have `OnRemove` hooks or signals costs less: the
  entities whose hooks run are a short stack instead of a table keyed by the entity, the first
  word of the signature with hooked ids is read once, the hooked records of the shared
  signature tables are collected inline (a relation with one pair of the entity without a new
  table), and the bit of each hooked id is tested inline. A delete of an entity with two
  components, one of them hooked, takes 460–490 / 260–275 ns instead of 525 / 330 ns
  (interpreter / native); with a hook on `ChildOf`, 625–670 / 400–420 ns instead of
  710 / 500 ns.
- A removal that runs an `OnRemove` hook tests the bit of the entity again without a call.

### Queries

- Queries with a pair of an entity target (`world:query(A, pair(ChildOf, parent))`,
  `:with(pair(Likes, bob))`) are shared by shape like the other queries, from the second
  request of the shape, and their shapes go when the target is deleted, as the shapes of an
  entity used as a term (those of `(*, T)` too). A pair whose target is not alive is not
  shared. 0.2.1 built a new state for such a query on every call. A query of a concrete pair
  per call takes 1.01 µs / 895 ns instead of 4.37 / 3.15 µs (15 matches of 1000; jecs:
  1.43 / 1.31 µs), 167 / 149 ns when nothing matches (0.2.1: 963 / 822 ns; jecs:
  367 / 353 ns), and `query(A, pair(ChildOf, parent))` per parent 580 / 516 ns (0.2.1:
  1.97 / 1.58 µs; jecs: 885 / 821 ns). A shared shape keeps about 3.2 KB while its target
  lives, and the shapes of pairs share the 1024 shared states of a world with the others.
- A query whose smallest required term has few words tests those words against the changed
  bits of each word, gathered once for all the queries, instead of each changed slot against
  its terms: small queries that share a large term which changes often pay a few word tests
  whatever the number of changes. 20 small queries over a tag toggled on 30 entities per frame
  take 22.0 / 14.7 µs (0.2.1: 120 / 61.4 µs; jecs: 19.3 / 15.9 µs).
- A query shape is shared from its second request. The first request gets a light state of
  its own and only marks the shape; kept and used again (a second loop, a modifier,
  `cached()`), it becomes the shared state. A query requested once (an entity used as a term)
  keeps no shared state: 2 inline queries per new caster keep 376 B instead of 3156 B, and
  take less than half the time.
- A cached query patches its match list while that costs less than a pass over the bitsets:
  up to a quarter of the list or half of the words of its smallest term (at least 32, at most
  1024 slots; 0.2.1: a quarter of the list). The noted slots of a record with more than 8
  changes are dropped at once when one of the three smallest required terms, whose own
  changes are re-checked, does not have them, and the queries that saw the same versions of a
  record read its changes from the journal once.
- A small query that is not cached (up to 4 required terms and 2 excluded ones, the smallest
  term in at most 64 words of its bitset) gathers its matches in one loop over those words
  before the loop of the caller: the first request of a shape, the inline queries of a new
  entity.
- The arrays of a match list have their exact size (30 % less memory per list), and the first
  list of a query is built from the spans that the choice of its iteration mode found, without
  a second pass over the bitsets.

### Relationships

- A wildcard whose values a query returns keeps a mirror: value pages with the value of one
  pair of each member, updated by every change of its pairs, which the queries read like the
  column of a component (and `get` too). 0.2.1 looked for the pair of every match on every
  loop. A mirror takes about 17 B per member and goes when no pair of the wildcard holds data.
- Deleting an entity clears the pairs of each of its relations in one inline loop.
- An entity with many pairs of one relation: a new pair goes to the end of the list of the
  pairs of the relation (ordered by target slot) when its target is the highest one, as when
  targets are added in the order they were created, and any other one finds its place by a
  binary search; a removal searches the same way beyond 16 pairs. 0.2.1 read the list from its
  start. 1000 targets of one relation on one entity: 1.49 / 1.02 µs per add instead of
  7.25 / 4.33 µs (in the order of creation), 0.97 / 0.67 µs per remove instead of
  2.95 / 2.87 µs (in the reverse order).

### Iteration

- `world:each` and `world:children` walk the bitsets of the id instead of collecting its
  members first, and allocate only their iterator. An entity that loses the id or is deleted
  before the loop reaches it is skipped (0.2.1 returned it, a deleted one as a dead id); an
  entity that gets the id during the loop is visited only when its slot lies ahead of the loop
  and existed when the loop started. The members of an id in at most two words of its bitset
  (up to 64, like the children of a parent created together) are still collected first.

### Tests and benchmarks

- `test/lib.luau`: wildcard values through mirrors (the transitions of a slot between one and
  several pairs of a target), match lists that skip the changes outside their smallest term,
  `world:each` and `world:children` over large records (changes during the loop, the order of
  the members), the sharing of query shapes from their second request, queries that are not
  cached and gather their matches first, queries that share a changing tag, and query monitors
  (every kind of term, exclusive relations, an exclusive replacement whose new pair is not
  added, clear, delete, cascades, batch operations, disconnect, callbacks that change the
  world, the terms that are refused).
- `test/jecs_compat/ob.luau`: the tests of the jecs addon `modules/OB` against the monitors
  (`tools/test.sh` runs them).
- `test/monitors_fuzz.luau`: random queries and changes of the world; the members that each
  monitor reports must be the matches of its query (`tools/test.sh` runs five seeds).
- `test/queries_fuzz.luau`: random queries (wildcard values, OR terms, pairs, `Disabled`,
  cached and inline, loops left early and nested) against brute force after bursts of changes;
  `test/loops_fuzz.luau`: loops that change the world (no entity twice, the untouched ones once).
- The documentation of change tracking says 7 finished ticks (it said 8: the ring of 8 ticks
  holds the current one), and `world:range(first, last)` gives `first + 1` first, as in jecs.
- `test/fuzz.luau`: pairs of a third relation with the anchor as the target (slots with
  several pairs of one target), stored queries of `(R3, *)` and `(*, anchor)`, the values of
  `(*, t)` checked against the model, every query shape requested twice, and the flag
  `monitors` (monitors of the stored queries and of an exclusive relation, `ChildOf` and
  `Disabled`, checked against the model; CI runs it with the flags of the debug world).
- `test/lib.luau`: queries with a pair shared by shape and dropped with its target (the room
  of the shared states, a target made anew in the slot of a deleted one, the pair of a slot
  that no entity had), many targets of a relation added and removed in any order, and small
  queries that share a large term changed many times between loops (a debug world). The tests
  that need a query that is not shared give it a dead id among its excluded ids.
- `test/fuzz.luau`: the flag `shapes` also checks queries with a pair whose target is an entity
  of the model. `test/monitors_fuzz.luau`: every third query is not shared (a dead id), so
  that a modifier after its monitor changes its state in place.
- `bench/strengths.luau`: the group `jecs strengths` of `bench/run.luau`.
- `bench/monitors.luau`: the group `query monitors`, against jecs with its addon `modules/OB`
  (the `jecs_ob` alias of `.luaurc`).

### Performance

The group `jecs strengths` in the luau 0.740 CLI, cells read "interpreter / native", the
median of 5 runs of the minimum of 3; memory is what a unit keeps:

| | jecs 0.11.0 | mErCS 0.2.1 | mErCS 0.2.2 |
|---|---|---|---|
| `(*, T)` values, 32 data relations, a pass over 20 000 | 722 / 601 µs | 16.0 / 7.46 ms | 539 / 310 µs |
| `(R, *)` values, 8 targets, a pass over 20 000 | 722 / 590 µs | 4.19 / 3.20 ms | 530 / 305 µs |
| 15 cached queries over scattered entities, per query | 280 / 238 µs, 5.7 KB | 843 / 584 µs, 374 KB | 714 / 335 µs, 263 KB |
| a query that is usually empty, 20 swaps per pass | 16.4 / 16.5 µs | 224 / 80.9 µs | 14.5 / 8.74 µs |
| 5 queries with 100 matches each, 40 toggles per frame | 46.8 / 44.3 µs | 968 / 328 µs | 30.6 / 17.7 µs |
| 20 small queries, a shared tag toggled on 30 per frame | 19.3 / 15.9 µs | 120 / 61.4 µs | 22.0 / 14.7 µs |
| `query(A, pair(ChildOf, parent))` per parent | 885 / 821 ns | 1.97 / 1.58 µs | 580 / 516 ns |
| 2 inline queries per new caster | 2.32 / 2.24 µs, 0 B | 10.7 / 9.50 µs, 3156 B | 4.67 / 4.25 µs, 377 B |
| `world:each` over 100 000, per entity | 27.7 / 24.7 ns | 61.5 / 36.2 ns | 38.6 / 31.5 ns |
| `world:children`, 1000 children, per child | 28.1 / 25.0 ns | 57.3 / 32.6 ns | 39.3 / 32.5 ns |
| 8 kinds created in turn, a pass over one, for-in, per match | 41.3 / 33.0 ns | 119 / 106 ns | 114 / 103 ns |
| the same, `each` | 41.9 / 33.3 ns | 90.8 / 78.1 ns | 63.1 / 47.1 ns |
| the same, `each`, the kind from a slot pool | 40.2 / 32.7 ns | 35.9 / 20.1 ns | 36.1 / 20.4 ns |
| delete entities with 100 targets, per pair | 29.2 / 29.4 ns | 83.5 / 52.3 ns | 62.2 / 44.1 ns |
| 8 components on 1 entity in 64, per entity | 2.85 / 2.26 µs, 170 B | 2.53 / 1.73 µs, 660 B | 2.50 / 1.71 µs, 660 B |

Query monitors (the group `query monitors`), jecs 0.11.0 with its addon `modules/OB` against
`query:monitor()`, 10 000 entities, medians of 5 runs:

| | jecs 0.11.0 + OB | mErCS 0.2.2 |
|---|---|---|
| a tag of the query added and removed, per cycle | 658 / 602 ns | 739 / 509 ns |
| members of the query deleted, per entity | 526 / 534 ns | 595 / 344 ns |
| children moved to another parent, `(ChildOf, *)` monitored, per move | 517 / 449 ns | 649 / 427 ns |

Three rows of the matrix gain: a query of a concrete pair per call takes 1.01 µs / 895 ns
with 15 matches of 1000 (0.2.1: 4.37 / 3.15 µs, jecs: 1.43 / 1.31 µs) and 167 / 149 ns when
nothing matches (0.2.1: 963 / 822 ns, jecs: 367 / 353 ns), an entity used in 4 inline queries
and then deleted 5.61 / 5.04 µs (0.2.1: 10.6 / 10.6 µs, jecs: 2.22 / 1.97 µs). The
other rows of the matrix, the synthetic frame (`bench/frame.luau`) and the long session
(`bench/leak.luau`: 0.08–0.09 ms per frame, +0.33 MB) are within the noise of the runs (±10 %)
of 0.2.1.

## v0.2.1 — 2026-09-28

Fixes and memory for games that moved to 0.2.0: the shared query shapes of deleted entities,
match lists that change by many entities between loops, queries that are not shared, and the
`(*, T)` records of targets.

### Fixed

- The shared query shapes of entity ids were never freed. A query with an entity id as a term
  (`world:query(Skill):with(caster)`) is shared by shape like any other, but its path in the
  tree of shapes (created even when no state was cached) and its state stayed after the entity
  was deleted, and such shapes used up the 1024 shared states: every new shape of the world,
  of components too, then built a new state on every `world:query` call (~3 µs instead of
  ~0.2 µs), with no warning. 20 000 deleted entities with 4 such queries each kept +8 MB. Now
  the path of a shape is created with its state only, the shapes of an entity leave the tree
  when it is deleted (also the ones that its own hooks make while it is deleted; a handle that
  keeps one keeps a working query, whose modifiers return queries of their own), and a shape
  with an entity id that is not alive is not shared. The problem was also in 0.1.2.

### Queries

- A cached query patches its match list only while the changes noted since its previous loop
  are at most a quarter of the list (and at least 32, at most 1024). After more, the loop
  passes over the bitsets, and the list is built again at a loop after fewer changes. 0.2.0
  rebuilt the list on every such loop, which took longer than the scan of 0.1.2 (the long
  session and the synthetic frame were slower than in 0.1.2). A journal no longer grows for
  more changes than the query that reads it patches.
- A query that is not shared (a pair with a concrete target, change filters, a shape beyond
  the 1024 shared ones) reuses the iteration contexts of the world instead of building its
  iterator on every call.

### Relationships

- A `(*, T)` record has 8 fields and no presence tables until a query, `has`, `world:each` or
  `remove` reads it: a pair with a target of its own keeps 1457 B instead of 1809 B, a
  `ChildOf` child (10 000 parents with 5 children) 344 B instead of 414 B.

### Debug worlds

- `ecs.world(true)` warns once (`warn` in Roblox, `print` in the luau CLI) when the 1024
  shared query states of the world are in use and a new shape cannot be shared.

### Tests and benchmarks

- `test/lib.luau`: the shared shapes of deleted entities (memory, the count of the shared
  states, kept handles, ids made alive again, a debug world at the limit), queries that are
  not cached (nested loops, `break`, errors in callbacks), match lists after many changes,
  and `(*, T)` records before their first read.
- `test/fuzz.luau`: the flag `shapes` (queries with the entities of the model as terms, and
  handles kept after their entity is deleted); CI runs it with the flags of the debug world.
- `bench/shapes.luau`: the group `state tags` (1200 skills in 5 state tags; 10, 200 or 800 of
  them change state between the loops of 5 inline queries). `bench/scenarios.luau`: a query
  of a concrete pair per call, and the memory of inline queries on deleted entities.

### Performance

mErCS 0.2.0 and 0.2.1 in the luau 0.740 CLI (`bench/run.luau`, `bench/leak.luau`); cells read
"interpreter / native", memory is what a unit keeps:

| | mErCS 0.2.0 | mErCS 0.2.1 |
|---|---|---|
| 1200 skills, 200 change state between the loops of 5 inline queries, per frame | 208 / 124 µs | 171 / 100 µs |
| the same, 800 change state | 430 / 266 µs | 363 / 233 µs |
| a query of a concrete pair per call, 15 matches of 1000 | 5.45 / 4.16 µs | 4.16 / 2.92 µs |
| the same, nothing matches | 1.86 / 1.71 µs | 612 / 510 ns |
| an entity used in 4 inline queries, then deleted | 18.1 / 15.8 µs, 492 B | 9.66 / 9.58 µs, 0 B |
| a pair with a target of its own | 3.56 / 3.24 µs, 1809 B | 3.21 / 2.84 µs, 1457 B |
| a `ChildOf` child (10 000 parents × 5) | 820 / 657 ns, 414 B | 720 / 567 ns, 344 B |
| the long session, per frame (interpreter) | 0.10–0.11 ms, +0.40 MB | 0.09–0.10 ms, +0.33 MB |

The synthetic frame (`bench/frame.luau`) is on par with 0.1.2 again: 0.93–0.98× of 0.1.2 in
the interpreter and 1.02–1.04× in native code, medians of 3 runs (0.2.0 was 1–15 % slower).
The state tags with 200 or 800 changes per frame still take 1.06–1.15× the time of 0.1.2: the
changes themselves cost more (the journals of the observed tags, the third level of bits),
the queries take the time of 0.1.2 again. The other rows of the matrix are within the noise
of the runs (±10 %).

## v0.2.0 — 2026-09-28

Queries after small changes, empty queries and `(*, T)` wildcards (the query cases where an
archetype ECS is expected to be at its best), plus slot pools. In native code (the Roblox
server) mErCS 0.2.0 is faster than jecs 0.11.0 in every query case; in the interpreter one case
is on par (see the tables below and
[the comparison](https://github.com/dubalda/mErCS/tree/main/docs/jecs-comparison#performance)).

### Queries

- A cached query keeps its match list after small changes. A record that a cached query
  observes notes the slots it changes in a journal; before its next loop the query re-checks
  only those slots and inserts or removes them in its list, instead of scanning its bitsets
  and building the list again. Each journal entry carries the version it belongs to, so a
  change that is not noted (a batch operation, `remove_all`) or was overwritten makes the
  query scan again: a missed change costs a scan, never a stale result.
- The match list is grouped by value page; a group of one match (an entity alone in its page)
  is read without its array.
- A query that matches nothing keeps an empty list: a loop costs a check of its ids, and
  nothing more while one of its required ids has no entity at all.
- A loop of a cached query uses its list without checking its records when, since its
  previous loop, no record that a cached query observes changed and no record was created or
  freed in the world (a stamp that every such change advances): a loop over an unchanged
  list, empty or not, starts with one comparison. A loop over an empty list takes 41 / 26 ns
  (interpreter / native; jecs: 64 / 59 ns).
- A for-in loop left with `break` no longer makes every later update of the list copy it (in
  0.1.2 every rebuild of the list allocated new tables): the list is copied once, at the next
  update, and a loop that is still running keeps the copy it started with.
- `query:cached()` prepares a query that has not been iterated yet (it picks how it iterates
  and builds its list), as jecs matches its archetypes there; the first loop of a new cached
  query no longer pays for it.
- A third level of presence bits (one bit per 32 768 slots): a scan skips the empty parts of
  a large world.
- Up to two excluded ids (`without`, `Disabled`) are tested inline in the bitset scan.

### Relationships

- `ecs.pair(ecs.Wildcard, T)` is built from the pairs of `T` the first time a query, `has`,
  `world:each` or `remove` reads it, and kept up to date from then on (with a count for the
  entities that have several pairs of `T`). Before, every change of a pair of `T` rebuilt it
  from all the pairs of `T`, and a query that returned it read every pair of `T` for every
  entity even when no pair held data.
- Deleting a target no longer updates its own `(*, T)` record, which is freed right after.
- The records of pairs that no entity has any more are freed in batches, once there are more
  than 256 of them and they are more than a quarter of all pair records (a pair added again
  before that keeps its record, so switching the target of a relation allocates nothing);
  a `(*, T)` record goes with the last pair record of `T`. Before, a pair record lived until
  its relation or its target was deleted: adding and removing 20 000 pairs with live targets
  kept 33 MB, now under 1 MB.

### Structural changes

- A tag added and removed on scattered entities no longer makes the bitset of its record
  rehash: an emptied word stays in the table as 0 until the emptied words outnumber the
  non-empty ones (Luau tables rehash all their keys when keys are removed and others added).
  Adding and removing a tag on a random creature of a world of 350 000 entities took 960 ns
  and takes 260 ns.
- Freeing a record no longer assigns nil to missing keys of the internal tables of ids: in
  Luau such an assignment inserts the key and can make the table rehash all its keys.

### Slot pools

- `world:pool()` makes a slot pool, and `pool:entity()` an entity with a slot from blocks of
  256 slots reserved for the pool; a deleted pool entity gives its slot back to the pool. A
  kind of entities created among many others (creatures among their skills) stays dense, so a
  query over it reads a few words instead of a word per entity. Pool entities are ordinary
  entities. New type: `ecs.Pool`.

### Debug worlds

- `ecs.world(true)` also checks every match list that a cached query updates after a change
  against a scan of its bitsets, and a loop that uses its list without checking its records
  checks them and raises an error when one changed (a library bug).

### Tests, benchmarks and tools

- `test/lib.luau`: patched match lists, empty queries, groups of one match, `(*, T)`, slot
  pools, large worlds and scattered members, and lists used as they are after every kind of
  change.
- `test/lib.luau`: the fixes below, and pair records freed in batches (with a model of pairs
  with many targets in a debug world).
- `test/fuzz.luau`: the flags `sparse` (entities spread over many pages and every bitset
  level), `pool`, `verify` (a debug world) and `churn` (pair records freed in batches between
  and inside the operations of the model); CI runs them.
- `bench/query_cases.luau`: five query cases where an archetype ECS is expected to be at its
  best, jecs for-in loops against `query:each`.
- `bench/shapes.luau`: the groups `query cases` and `sparse world` of the matrix.
- The benchmarks print the versions they compare (`bench/versions.luau`) and take the previous
  release when `tools/previous.sh` has extracted it from its git tag into `tmp/previous`.
- `bench/visual/query_*.bench.luau` for the Benchmarker plugin, whose functions are now named
  with the versions, and the Rojo template `benchmarker.project.json`: a place with only the
  libraries and the bench files.
- The toolchain uses `luau` 0.740.

### Fixed

The fixed problems were also in 0.1.2.

- `OnRemove` hooks ran twice on `world:delete` and `world:clear` when the entity had ids with
  hooks both among the first 256 records of the world and beyond them (a world with more than
  256 components, tags and relations).
- A cascade of deletes deeper than 100 levels through a tag or a relation with
  `(OnDelete, Delete)` raised an error (`attempt to index nil with 'kind'`) and left the rest
  of the cascade alive. The entities queued past 100 levels now lose the deleted id before its
  record is freed (its `OnRemove` runs for them with `deleting = true`); the children queued
  in a `ChildOf` cascade no longer keep a reference to the freed pair of their parent.
- A hook, a listener or tracking on `Exclusive`, `OnAdd`, `OnChange` or `OnRemove` replaced
  the internal hook of the library for that id: `Exclusive` stopped acting on a relation that
  already had pairs, and hooks set afterwards did not reach the ids that already had records.
- An entity that took the slot of another inside an `OnRemove` hook of that entity, and was
  deleted or cleared there, skipped its own `OnRemove` hooks.
- `world:set(e, pair, value)` with a tag pair that `e` already had ignored the value; it now
  raises the error it raises for a new tag pair and for a tag.
- `world:query():has(e)` (a query without terms) returned true for every entity, while the
  query matches nothing.

### Changed behaviour

- `world:exists(e)` is also true for a slot reserved by a pool and not handed out yet.
- A record observed by a cached query keeps a journal of 16 to 512 entries (0.5 to 16 KB).
- `world:added`, `world:changed`, `world:removed` and `world:track` raise an error for a pair:
  they take a component, a tag or a relation (which covers all its pairs). Before, a pair was
  accepted, but its listeners never ran when the pair had no record yet, and replaced the
  hook of the relation for that pair when it had one.
- The builtin `Disabled` is named `"mercs.Disabled"` like the other builtins (it was
  `"Disabled"`).

### Performance

jecs 0.11.0, mErCS 0.1.2 and mErCS 0.2.0 in the luau 0.740 CLI; cells read "interpreter /
native", the minimum of 18 runs in each mode.

The query cases (`bench/query_cases.luau` and the `query cases` group of `bench/run.luau`),
time of one pass:

| Case | jecs 0.11.0 | mErCS 0.1.2 | mErCS 0.2.0 | 0.2.0 / jecs |
|---|---|---|---|---|
| Scattered after recycling | 124 / 103 µs | 80.3 / 60.3 µs | 87.2 / 62.9 µs | 0.70× / 0.61× |
| Churn on a queried tag, 1 toggle per pass | 306 / 258 µs | 702 / 465 µs | 257 / 188 µs | 0.84× / 0.73× |
| Churn on a queried tag, 100 toggles per pass | 230 / 197 µs | 536 / 355 µs | 235 / 167 µs | 1.02× / 0.85× |
| Read 4 components | 1.92 / 1.42 ms | 1.22 ms / 643 µs | 1.28 ms / 662 µs | 0.67× / 0.47× |
| `(*, T)` with churn | 796 / 689 µs | 14.5 / 13.2 ms | 528 / 341 µs | 0.66× / 0.50× |
| Usually empty | 64 / 59 ns | 194 / 67.3 µs | 41 / 26 ns | 0.64× / 0.44× |

A world of 700 creatures with 500 skills each (the `sparse world` group), one pass after the
change a game makes before it:

| Pass | jecs 0.11.0 | mErCS 0.1.2 | mErCS 0.2.0 | 0.2.0 / jecs | mErCS 0.2.0, pool | pool / jecs |
|---|---|---|---|---|---|---|
| Alive creatures, nothing changed | 6.18 / 5.54 µs | 6.07 / 4.37 µs | 5.42 / 3.96 µs | 0.88× / 0.71× | 7.00 / 3.95 µs | 1.13× / 0.71× |
| Alive creatures, `Dead` added to one and removed | 7.08 / 6.36 µs | 94.5 / 60.4 µs | 7.28 / 4.91 µs | 1.03× / 0.77× | 7.47 / 4.32 µs | 1.06× / 0.68× |
| Running creatures, `Run` toggled on one | 3.46 / 3.09 µs | 22.5 / 16.1 µs | 4.74 / 3.37 µs | 1.37× / 1.09× | 2.73 / 1.78 µs | 0.79× / 0.58× |
| A tag added to one creature, a pass, removed, a pass | 1.21 / 1.09 µs | 8.24 / 6.36 µs | 2.10 / 1.34 µs | 1.74× / 1.23× | 1.59 / 1.02 µs | 1.31× / 0.94× |
| A tag nobody has | 65 / 60 ns | 246 / 216 ns | 44 / 31 ns | 0.67× / 0.51× | 44 / 31 ns | 0.68× / 0.51× |
| All with `Model` (creatures and corpses) | 21.2 / 18.6 µs | 21.2 / 14.8 µs | 18.8 / 13.2 µs | 0.89× / 0.71× | 15.7 / 8.82 µs | 0.74× / 0.47× |
| A skill changes state, 10 queries over skills in `Cast` | 152 / 117 µs | 309 / 196 µs | 105 / 66.2 µs | 0.69× / 0.56× | 108 / 68.1 µs | 0.71× / 0.58× |

Without a pool, a change of one creature before a pass costs an edit of the match list that
jecs does not have (it moves the creature to another archetype instead); with a pool every
pass is faster than in jecs in native code. In the interpreter three rows of the pool stay
at 1.06–1.3× of jecs: the alive creatures (with and without a change) and a tag on one of
them.

The synthetic game frame (`bench/frame.luau`, the median frame time, the middle one of 3 runs):

| | jecs 0.11.0 | mErCS 0.1.2 | mErCS 0.2.0 | 0.2.0 / jecs |
|---|---|---|---|---|
| interpreter, inline queries | 6.70 ms | 3.11 ms | 3.16 ms | 0.47× |
| interpreter, cached queries | 6.24 ms | 3.18 ms | 3.20 ms | 0.51× |
| native, inline queries | 5.78 ms | 2.22 ms | 2.33 ms | 0.40× |
| native, cached queries | 5.43 ms | 2.12 ms | 2.46 ms | 0.45× |

A query whose entities change by many (dozens to hundreds) before every loop updates its match
list, which costs more than the scan of 0.1.2: the synthetic frame takes 1–15 % longer than in
0.1.2, and the long session of `bench/leak.luau` 0.11 ms per frame against 0.09 ms (jecs
0.11.0: 0.23 ms).

### Installation

- Wally: `mercs = "dubalda/mercs@0.2.0"`.
- Roblox model: `mercs.rbxm`, attached to this release.

## v0.1.2 — 2026-09-26

### Fixed

- Deleting an entity whose cascade runs hooks that write into it (a child whose `OnRemove`
  hook sets a component of its parent while the parent is deleted) no longer leaves those ids
  on the freed slot: the deleted entity stayed in queries as a dead id, and the next entity
  that reused the slot inherited the ids.

### Installation

- Wally: `mercs = "dubalda/mercs@0.1.2"`.
- Roblox model: `mercs.rbxm`, attached to this release.

## v0.1.1 — 2026-09-26

The Wally package gets a description, a homepage and a repository link; the code is the same as
in v0.1.0.

### Installation

- Wally: `mercs = "dubalda/mercs@0.1.1"`.
- Roblox model: `mercs.rbxm`, attached to this release.

## v0.1.0 — 2026-09-26

The first release of mErCS, an entity component system for Luau and Roblox built on inverted
bitsets. Every component, tag and pair keeps a bitset of the entities that have it, and the
values sit in pages indexed by the entity slot: adding or removing a component sets a bit and a
value, never moves the entity and never creates anything per combination of components. The API
follows [jecs](https://github.com/Ukendio/jecs).

### Highlights

- **O(1) structural changes.** Tags for states, relationships, spawning and despawning cost the
  same whatever the entity has; memory does not grow with the number of component
  combinations, and there is nothing to clean up.
- **The jecs feature set.** Worlds, entities, components and tags, pairs and wildcards,
  `Exclusive`, cleanup policies (`OnDelete` / `OnDeleteTarget` with `Delete` / `Remove`),
  `ChildOf` hierarchies, hooks (`OnAdd`, `OnChange`, `OnRemove`), signals
  (`world:added` / `changed` / `removed`), `Name`, pre-registered ids.
- **Beyond jecs.**
  - `query:each(fn)`, the fastest loop, and `query:any(...)` OR terms.
  - Batch operations on the matches of a query: `count`, `add_all`, `set_all`, `remove_all`,
    `delete_all`, plus `world:remove_all(id)`.
  - Change tracking by ticks: `world:track`, `world:tick`, and the query filters `added`,
    `changed`, `removed`.
  - The `Disabled` tag, hierarchies of any depth, no limit on the number of components.
  - `get` / `has` with up to 8 ids (`get_list` / `has_all` for more), a fast path over the raw
    columns (`query:spans`, `world:column`), and debug worlds that raise errors for dead
    entities and ids.
- **Typed API.** `Component<T>` carries the data type into `get`, `set` and queries; the module
  is `--!strict` and `--!native`.
- **jabby.** The debugger connects through the adapter `mErCS.jabby`, a child module that the
  library itself never requires.

### Performance

Measured against jecs 0.11; time of mErCS relative to jecs, lower is better.

| Benchmark | jecs | mErCS | Ratio |
|---|---|---|---|
| Synthetic game frame, interpreter (luau CLI) | 5.22 ms | 2.46 ms | 0.47× |
| Synthetic game frame, native (luau CLI) | 4.58 ms | 1.62 ms | 0.35× |
| Spawn 1000 entities with 4 components (Roblox Studio, Benchmarker) | 1.116 ms | 0.589 ms | 0.53× |
| Remove one of 5 components from 1000 entities (Benchmarker) | 356 µs | 60 µs | 0.17× |
| Hierarchy with relationships, then delete the parents (Benchmarker) | 7.971 ms | 1.762 ms | 0.22× |
| Add and remove a tag on 1000 query matches (Benchmarker, batch operations) | 496 µs | 49 µs | 0.10× |

- A long session with changing relationship targets: the heap stays flat (+0.4 MB), while jecs
  grows by 15 MB in 5000 frames.
- An entity with 4 components takes 130 bytes (jecs: 320).
- Still slower than jecs: a for-in over sparse matches (about 1.2–1.5×; `query:each` is faster
  than the jecs loop), `has` with 4 ids in the interpreter, and many pairs of one relation with
  scattered targets.

All numbers, the benchmark sources and the Benchmarker screenshots are in the
[comparison with jecs](https://github.com/dubalda/mErCS/tree/main/docs/jecs-comparison).

### Coming from jecs

- 125 of the 125 applicable cases of the jecs test suite pass.
- A few jecs calls are not provided because they would do nothing here or only repeat native
  calls: `World.new`, `w`, `bulk_insert` / `bulk_remove`, `new` / `new_w_id` / `new_low_id`,
  `world:cleanup()`, `query:fini()`, `ArchetypeCreate` / `ArchetypeDelete`.
- `query:iter()`, `query:archetypes()`, `world.entity_index`, `entity_index_try_get` and
  `is_tag` exist only in the jabby adapter.
- The builtin ids after `Name` have other numbers: `Exclusive` is 268 (jecs: 270), `Rest` is
  270 (jecs: 271).
- The [migration guide](https://github.com/dubalda/mErCS/blob/main/docs/jecs-comparison/README.md#migrating-from-jecs)
  lists what to write instead of each call.

### Installation

- Wally: `mErCS = "dubalda/mercs@0.1.0"`.
- Roblox model: `mercs.rbxm`, attached to this release.
- Or copy `src/init.luau` into a ModuleScript (`src/jabby.luau` is the optional jabby adapter).

### Documentation

- [Documentation site](https://dubalda.github.io/mErCS/): the API reference and the guide.
- [Guide](https://github.com/dubalda/mErCS/tree/main/docs/guide) in the repository.

### Status

Pre-release (0.x): the API may still change. Tested with the standalone `luau` 0.703 CLI (the
interpreter and native code generation), in CI on Linux, and in Roblox Studio with the
Benchmarker plugin and the jabby debugger. A full check in a running Roblox place (server and
client) is still pending.
