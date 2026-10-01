# Development

How the repository is organized, how to test, check and benchmark the library, how to run
the checks and benchmarks in Roblox Studio, and how CI, releases and the documentation site
work.

## Setup

- Tools are pinned in `rokit.toml`: luau (CLI runtime), luau-lsp, StyLua, selene, Wally,
  wally-package-types, Rojo. Install them with `rokit install`.
- `wally install` puts the dev dependencies of `wally.toml` into `DevPackages/`: jecs (the
  reference for the comparisons, the core tests and the benchmarks) and jabby (the debugger,
  for the Studio check). The library itself has no dependencies.
- Python 3.11+ runs the isolated reference workload and its report checks; only the standard
  library is used.
- `.luaurc` aliases: `@lib` (the library), `@jecs` (the jecs package), `@testkit`, `@bench`,
  `@test`.

### Types through the Wally link modules (optional)

The link modules that Wally writes into `DevPackages/` (`jecs.lua`, and the ones inside
`_Index`) return the package but not its exported types. `wally-package-types` adds the
types to them, so an editor that resolves requires with a Rojo sourcemap sees `jecs.World`
and the other types through the links. Run from the repository root, after every
`wally install` (it rewrites the link modules):

```sh
rojo sourcemap studio/studio.project.json --absolute -o sourcemap.json
wally-package-types --sourcemap sourcemap.json DevPackages/
```

- The sourcemap has to include `DevPackages/`: `default.project.json` holds only the
  library, the Studio check project holds the packages too.
- The paths have to be absolute (`--absolute`): with relative ones (`../DevPackages/...`,
  relative to `studio/`) the tool finds no link module.
- Checked with Rojo 7.7.0 and wally-package-types 1.6.2: it rewrites 4 link modules (`jecs`,
  the `jecs` link of jabby, the two `vide` links); `jabby` exports no types.
- The code of the repository does not need it: the tests reach jecs through the `.luaurc`
  alias, the Studio files cast the packages to `any`, and `tools/check.sh` gives the same
  result with or without it.
- `sourcemap.json` is ignored by git.

## Layout

```
src/init.luau          the library (the specialized iterators are generated, see tools/) and its API reference (doc comments)
src/jabby.luau         the adapter for the jabby debugger (a child module the library never requires)
tools/generate.py      regenerates the iterator sections: python tools/generate.py && stylua src
tools/check.sh         formatting, lints and types, checked like the editor does, and the type errors that must stay
tools/typecheck.py     the misuses of test/typecheck/errors.luau: the analyzer must reject each marked line, nothing else
tools/test.sh          every test, the example and a fuzz run (--codegen: with native code)
tools/previous.sh      the previous release from its git tag into tmp/previous, for the benchmarks
tools/workload.sh      the performance suite of the reference workload, interpreter and native code
tools/workload.py      isolated runs against a verified release tag, controls, raw samples and release gates
tools/test_workload.py tests of the report parser, controls and release selection
tools/test_typecheck.py tests of the comparison of tools/typecheck.py
test/core.luau         core semantics, run against jecs and this library
test/lib.luau          library features, the model tests
test/types.luau        typed API usage (must type-check)
test/typecheck/errors.luau misuses of the public types, each marked with the error it must get (not run)
test/fuzz.luau         random operations against a model (flags: wide, hooks, sparse, pool, verify, churn, shapes, monitors)
test/jabby.luau        the jabby adapter: what jabby reads from its jecs module and a world
test/jecs_compat/      the jecs test suite run against this library (125/125 applicable), and the tests of its addon modules/OB against the query monitors (ob.luau, 42/42 monitor cases)
test/monitors_fuzz.luau random queries and changes of the world against query monitors
test/queries_fuzz.luau random queries and changes of the world against brute force
test/loops_fuzz.luau   loops that change the world (no entity twice, untouched ones once)
test/behavior.luau     the behavior specification: the groups of cases in test/cases/ (a group per subject)
test/cases/           the groups of the behavior specification and support.luau (the kit type, the helpers)
test/snapshots_fuzz.luau independent model of exact each/children snapshots held across world changes
test/reentrant_fuzz.luau nested changes from hooks, listeners and monitor callbacks, checked against invariants (flags: debug, pool, range)
test/workload_model.luau verifies the model's bound of three expiry pairs per group during churn
examples/basics.luau   a runnable tour of the API
bench/run.luau         the benchmark matrix (harness.luau, scenarios.luau, shapes.luau, strengths.luau, monitors.luau, impls.luau, impl_defs.luau)
bench/query_cases.luau query cases where an archetype ECS is at its best: jecs for-in against query:each
bench/basic.luau       the four basic benchmarks of jecs (spawn, despawn, insertion, query) for this library, jecs and ecr
bench/frame.luau       a synthetic game frame (frame_scene.luau)
bench/leak.luau        a long session with changing relationship targets (memory growth)
bench/workload.luau    the performance suite of the reference workload, P1–P9 (workload_model.luau: the model of the world)
bench/workload_extra.luau client marker queries and memory retained by the module after temporary worlds
bench/workload_session.luau long-session diagnostic with live-entity and slot counts
bench/results/        release workload reports and raw samples
bench/gc.luau          garbage collector access that works in the luau CLI and in Roblox
bench/versions.luau    the versions of jecs and the library in the output of the benchmarks
bench/previous.luau    the previous release (tmp/previous) when tools/previous.sh has extracted it
bench/visual/          Benchmarker plugin files (*.bench.luau): jecs, ecr (the four basic ones) and this library
benchmarker.project.json  a place with the libraries and bench/visual only, for the Benchmarker plugin
studio/                a Roblox place that runs the fuzz test, the frame and the matrix (check.project.json: its tree)
vendor/testkit.luau    the test kit of the jecs suite (MIT)
docs/                  the index (README.md) and a folder per section: guide/, comparison/ (Benchmarker, previous release, jecs, ecr), development/
moonwave.toml          the documentation site (Moonwave)
.github/workflows/     CI, releases and the documentation site
```

## Tests

```sh
bash tools/test.sh             # the interpreter
bash tools/test.sh --codegen   # native code
```

`tools/test.sh` runs `test/core.luau`, `test/lib.luau`, `test/types.luau`, `test/fuzz.luau`,
`test/jabby.luau`, `test/jecs_compat/tests.luau`, `test/jecs_compat/ob.luau`,
`test/monitors_fuzz.luau`, `test/queries_fuzz.luau`, `test/loops_fuzz.luau`,
`test/snapshots_fuzz.luau`, `test/reentrant_fuzz.luau`, `test/workload_model.luau`,
`test/behavior.luau` (twice: with the worlds the cases ask for, then with `-a debug`) and
`examples/basics.luau`, and stops at the first failure with a non-zero exit code (a failed
case of the test kit fails its file). It also requires exactly one actual shared-query
warning from each run of `test/behavior.luau` (the last case of its `workload` group makes it).

`test/behavior.luau` runs the behavior specification: one case per behavior that code using the
library can observe, in groups by subject, one module per group in `test/cases/`:

| Group | What it holds |
|---|---|
| `changes` | `world:toggle`, the `Component` trait after the first use of an id |
| `queries` | the terms of a query through every way of reading it, a query without terms that select entities, `world:each` and `world:children` over disabled members, the arity and nil values of queries, several excluded ids |
| `loops` | `world:each` and `world:children` snapshots at word, page and block boundaries, after emptied words and recycled slots, while a few members move between words; buffers of held, exhausted and abandoned iterators across two worlds; a frame of messages changed by hooks |
| `hooks` | reentrant removal listeners during target and relation deletion, listener replacement, errors raised by hooks and the `world:tick` after them, the listeners that a signal reaches after others were disconnected, disconnected listeners and monitors that nothing keeps, listeners that delete the entity of their own event or take back an excluded id of a monitored query, a clear or a delete that notifies every id once, monitors and the changes made while an id is removed |
| `relations` | relations kept in sync by their own hooks, a cascade that reaches an entity through ownership and `ChildOf`, listeners that give a changing exclusive relation, a deleted id or the entities of a cascade new uses, hooks that never stop giving new uses |
| `tracking` | what one tick records, batch operations on tracked ids, the depth of the history, creation tracking, an entity that a listener of the change deletes |
| `batches` | batch operations whose matches cascade or leave the query, nested batch operations, `toggle_all` |
| `worlds` | two worlds in one process, `world:entity(id)` over a live slot, an old id of a slot that a new entity took (reads and changes, with and without debug), `world:range` with explicit ids and with a pool made before it |
| `workload` | the behavior cases of the reference workload (the next section): ids and liveness, hooks and signals, relations, loops, debugging aids |

A group returns a function
that adds its tests to the kit of the run (`test/cases/support.luau` holds the kit type and
the helpers); a new group is added to the list of the runner. Named groups run alone, and a
module path runs the cases on a saved release, which shows a changed behavior between two
releases:

```sh
luau test/behavior.luau -a tracking worlds
luau test/behavior.luau -a ../tmp/previous/mercs
```

A release passes every case; a change of one is a changed behavior of the release notes.

`test/snapshots_fuzz.luau` compares exact full-id snapshots with its own model of liveness,
tags and parents, independent of library queries. It holds iterators across deletes, cascades,
slot reuse and nested loops, including abandoned loops. Failures include seed, round and
operation trace. The default runs seeds 1, 42 and 20260930 for 250 rounds each; CI runs each
for 2 000 rounds (`luau test/snapshots_fuzz.luau -a 42 2000`).

`test/reentrant_fuzz.luau` makes hooks, signal listeners and monitor callbacks change the world
while it changes: the entity of their event or others, the id of the event or others (adds,
removals, toggles, values, pairs of a relation, of an exclusive relation and of `ChildOf`, an
entity given to others as an id, clears and deletes, also of ids and targets being deleted,
new entities, also in a slot freed a moment before, explicit ids over live entities, deleted
ids made alive again, batch operations with ids and pairs that the callbacks may delete,
`Disabled`), at most 3 levels deep and 12 times per operation; half of the entities used as
ids are components. It has no model of
their effects; after every operation the world must agree with itself: every addition and
removal heard once (for every entity and id, the additions less the removals are 1 when the
entity has the id, 0 otherwise; an id that the hooks give an entity during its own clear or
delete goes unheard), no live entity with a dead id, one target of an exclusive
relation, `has`, `world:each`, queries and counts in agreement, the members of the monitors
(two made before the other callbacks, two after) equal to the matches of their queries, the
change filters returning only live entities with that change in the tick, and with `range` the
new ids inside the range. `debug` uses a debug world, `pool` makes half of the entities from a
slot pool; an argument with a slash is the module of a saved release to run on (the toggles
of an older release are made of add and remove). A failure prints the seed, the round and the
last actions, nested ones indented. CI runs 3 seeds of 300 rounds in each mode
(`luau test/reentrant_fuzz.luau -a 7 300 debug pool range`).

The Python tools have tests of their own (the evidence validation of the workload runner and the
comparison of the type check):

```sh
python -B -m unittest discover -s tools -p 'test_*.py'
```

`test/typecheck/errors.luau` holds misuses of the public types, one per line, each marked with a
trailing comment `error: <text>`: a value of another type than the component's (also `nil` for a
component that does not allow it, and in data pairs), values read into variables of another type,
callbacks and loops that take another type, a string or a number where an id goes, a typed id
widened to accept any value. `tools/typecheck.py` (run by `tools/check.sh`) analyzes the file with
the same analyzer and flags as the rest of the repository and requires an error containing
`<text>` on every marked line and no error on any other line; the file is not run and not part of
the analysis of `test/*.luau`. `test/types.luau` holds the uses that must type-check.

`test/monitors_fuzz.luau` builds random queries (tags, components, pairs, relations with any
target, an exclusive relation, `ChildOf`, `Disabled`, excluded ids and OR terms, sometimes a
modifier of the query after its monitor; every third query has a dead id among its excluded
ones, which keeps it from being shared, so that the modifier changes its state in place) and
changes the world at random; after every change
the members that each monitor reported must be the matches of its query (`query:has`). It takes
a seed and a number of steps; without them it runs five seeds, two of which reproduced bugs
of the first monitors (`luau test/monitors_fuzz.luau -a 42 5000`).

`test/queries_fuzz.luau` checks queries against brute force over `world:has` / `world:get`:
random shapes (returned ids, `with`, `without`, OR terms, pairs, `(R, *)`, `(*, T)`, an
exclusive relation, `ChildOf`, `Disabled`, wildcard values), cached and inline, looped with
for-in, `each`, `break` and nested loops, after bursts of few or many changes (match lists
patched, filtered and built again), batch operations and deleted targets, over dense runs,
scattered entities and a slot pool; the matches, their order, their values, `count` and `has`
must agree (`luau test/queries_fuzz.luau -a 42 300 debug` with a debug world).
`test/loops_fuzz.luau` changes the world inside loops (the current entity, others, new ones,
nested loops): no entity may come twice, and the entities that matched at the start and that
nothing touched must come once (`luau test/loops_fuzz.luau -a 42 1000`).

`test/fuzz.luau` takes a seed, a number of rounds and flags: `wide` creates 300 ids first
(records beyond the shared signature tables), `hooks` adds hooks that change the entity,
`sparse` creates up to 300 empty entities after each entity of the model (the matches spread
over many value pages and every bitset level), `pool` creates half of the entities of the
model from a slot pool, `verify` uses a debug world, which checks every patched match list
of a cached query against a scan of its bitsets and, when a query takes its list as it is,
that none of its records changed, `churn` adds and removes pairs with 400 targets on an
entity outside the model after every operation, so that the pair records left empty (those
of the model too) are freed in batches between and inside the operations of the model, and
`shapes` checks queries that have entities of the model as terms, directly or as the target
of a pair, after every batch (a shared query shape per entity, dropped when the entity is
deleted: a new shape of a live entity must be shared) and keeps some of them across the
rounds, after their entity is deleted too, and
`monitors` gives the stored queries and a few more (an exclusive relation and `ChildOf` with
any target, `Disabled` named) query monitors: the members they report (the matches when the
monitor was made, plus the entries, less the exits) must be the matches of the model after
every batch, an entity must not enter twice or leave without entering, and it must be alive
when it leaves:

```sh
luau test/fuzz.luau -a 42 400 wide hooks shapes
luau test/fuzz.luau -a 7 400 sparse pool verify hooks wide churn shapes monitors
```

## Checks

```sh
bash tools/check.sh
```

`tools/check.sh` runs StyLua, selene and `luau-lsp analyze` with the settings of the VS Code
workspace: the new type solver, the Roblox platform and the Roblox type definitions, with the
luau-lsp server of the installed VS Code extension (the version the editor uses), or
`luau-lsp` from `rokit.toml` without it. The Wally packages are not checked.
Explicit executable paths can be supplied through `MERCS_LUAU_LSP`, `MERCS_STYLUA` and
`MERCS_SELENE`; `tools/test.sh` accepts `MERCS_LUAU`.

## The reference workload

The priority of the library is its reference workload, described by the kinds of
its entities, their numbers, rates and access patterns, at a small scale (the test places) and a
target scale (about 700 agents with 500 owned entities each, 350 000 entities, a heap of about
140 MB). Every release runs the performance suite of that workload against the previous release
and against itself, in the interpreter and in native code, and passes its gates: no test worse
than on the previous release beyond the noise (first at the target scale in native code), the
heap of the target world not larger, and the behavior cases passed. Its release notes list the
changed behavior, the results of the suite and the memory of the target world.

```sh
bash tools/workload.sh baseline=v0.2.4 release=yes          # full acceptance, both modes, 5 runs
python tools/workload.py runs=10 tests=P1,P7 scales=sparse,target modes=native
python tools/workload.py --luau /path/to/luau output=tmp/workload-custom
```

`tools/workload.py` extracts `src/init.luau` from the specified git tag, verifies the tag and
records its commit and source hash. It snapshots the candidate too. Each build, control,
profile and repeat runs in a fresh Luau process with `-O2`, with `--codegen` in native mode.
The four columns are baseline, baseline again, candidate and candidate again. Their order
rotates; corresponding repeats use identical seeds.

`tmp/workload/report.md` contains medians, min–max ranges and ratios. `samples.json` keeps
every raw sample, seeds, source/tool hashes and environment; `logs/` holds process output.
The noise allowance per row is the maximum of the baseline control median difference,
three times the median paired absolute control difference and the heap measurement
resolution; a difference of exactly the allowance (one step of the heap resolution) is within
it. Candidate variation never enlarges it. A disputed row needs another 10–20
repeats and investigation; overlapping ranges alone do not settle it.

The [1.0.0 report](https://github.com/dubalda/mErCS/blob/main/bench/results/1.0.0.md) keeps the
primary measurements and additional repeats together. It includes every initial flag,
the combined decision and commands to reproduce the runs or verify the saved comparisons.

The default profiles are `sparse`, `small`, `target`, `small-empty-retained`,
`target-empty-retained`, `client` and `buffers`. `release=yes` requires all profiles,
P1–P9, both modes and at least five repeats, fails on missing/non-finite/duplicate rows or a
missing baseline, and rejects regressions or a run without measured progress. A source
change during measurement invalidates the run. The benchmark loads only one implementation
per process; it does not use the potentially stale `tmp/previous` copy.

`bench/workload.luau` remains available for exploration (`previous=no`, or
`implementation=../src` for a single build). Its in-process comparison is not release
evidence. The measured tests are:

| Test | What is measured |
|---|---|
| P1 | `world:each` over a tag whose members are spread evenly among 350 000 entities (exactly 16, 256, 2 048, 16 384 members), in runs of 8, the dense case (100 000 of 100 000), and 16 members after an emptied word; the small world: a tag with 4 members among 1 500 entities, each transition moving a member to another entity, before any transition, after 40 (the emptied words still in the record) and after 3 000 |
| P2 | 10 walks per frame over the passing state with the members of a system tag, with the state transitions of a frame between: `world:each` with a check, and one stored query per system tag; with the members of the workload (4 at the small scale, 8 at the target one) and in the stress case (80) |
| P3 | `world:each` over the holders of `(Trigger_k, agent)`: about 60 at the target scale, 2 at the small one |
| P4 | the 25 stored queries at their periods (1 to 60 frames) while agents change and owned entities change state |
| P5 | the messages of a frame handled (the walks of P3 and of `(Extra, agent)`, 3 values read per holder) and deleted, new ones made, the deferred ones visited: on average (2 / 5 messages a frame, 1 / 3 deferred ones at the small / target scale) and in a burst of activity (30 messages a frame, 60 / 300 deferred ones) |
| P6 | the end of the activity of an agent, the removal of a retained agent (the cascade over its 500 owned entities, with removal listeners), a new agent with its owned entities; the median of the events of a run |
| P7 | the frames of the model with the lifecycle events at their rate: µs per frame and ms of ECS work per second of server time |
| P8 | the heap after build, after preceding measurement phases and 100 additional lifecycle rounds, then after 3 000, 6 000 and 9 000 more frames; bytes per distinct pair and per holder |
| P9 | net heap growth during warmed frames and loops over a stored query or `world:each`; the first large snapshot in a fresh module |

`bench/workload_model.luau` is the model of the world and of a frame: agents from a slot pool,
owned entities created in one burst after their agent, groups and anchors in `ChildOf` trees, 8
trigger relations and an ownership relation that deletes the owned entities with their agent, 7
states (a value and a mirror tag moved by hooks), 10 system tags, messages, timed effects,
modifiers, expiry data pairs removed with `remove_all`, about 85 components and 115 tags. The
states out of idle hold a few owned entities each, as in the reference workload: at the small scale 18
in the busiest state, 4 in the passing state that the intersection walks go over and 1 in each
of the other four, twice as many at the target scale. A frame works at the averages of the
reference workload; `burst` and `stress` switch the model to a burst of messages (P5) and to the
stress case of the intersection walks (P2) and back. Its header lists the choices that the
workload leaves open. The heap it reports includes the lists of the model (the same for every
column).
Each group keeps at most three expiry pairs: a refresh updates an existing pair or replaces
one removed when its agent ended activity. The old model chose a new random target on every
refresh, gradually increasing the number of pairs beyond the workload's bound.

The `empty-retained` variants delete owned entities when activity ends and build retained
agents without them. The client profile has 300 entities and 15 usually empty stored marker
queries, add/remove listeners and replication at five entities per second. The buffer profile
holds 17 snapshots of 100 000 members, exhausts them, drops the world and measures the memory
the module keeps after GC; it then checks abandoned snapshots in another world.

Memory values labelled MB are MiB. P9 uses a weak witness to reject a completed GC cycle
during each measured interval. It is a net heap growth proxy, not total allocator traffic:
table resizing frees storage, and an incomplete incremental cycle may not clear the witness.
Report warmed frames separately from the first large snapshot. Long-session memory should
settle across the three equal windows; compare corresponding seeds and both controls.
A longer diagnostic also reports live-entity and allocated-slot counts, to separate changes
in the modeled population from retained storage:

```sh
luau -O2 --codegen bench/workload_session.luau -a ../src target 1001 60000 10000
```

## Benchmarks in the luau CLI

```sh
bash tools/previous.sh                                      # the previous release, once (optional)
luau -O2 bench/run.luau -a reps=9                           # the matrix, interpreter
luau -O2 --codegen bench/run.luau -a filter=query,pair      # native code, some groups
luau -O2 --codegen bench/run.luau -a "filter=query cases,sparse,state tags" # the query shapes (bench/shapes.luau)
luau -O2 --codegen bench/query_cases.luau                   # the query cases, with the test kit of jecs
luau -O2 --codegen bench/basic.luau -a ecr                  # the four basic benchmarks: lib, jecs or ecr
luau -O2 bench/frame.luau                                   # the synthetic frame
luau -O2 bench/leak.luau                                    # a long session
```

The benchmarks compare jecs (the Wally dev packages), the previous release of the library and
the current one, and print their versions (`bench/versions.luau`). `tools/previous.sh` puts the
previous release (the newest tag other than the version in `wally.toml`, or a tag given as its
argument) into `tmp/previous`; without it the benchmarks compare jecs and the current library.

`bench/run.luau` arguments: `filter` (substrings of "group.name"), `impls` (`jecs`, `previous`,
`lib`), `reps`, `n`. Time is the minimum over the runs divided by the operations; memory is the
heap growth kept after the run and a full collection.

In one process the implementations run in turn, and the ones that run first change the timings
of the later ones: by up to 30 % in some rows. The numbers of
[the comparison](../comparison/jecs.md#performance) run each implementation in a process
of its own (`impls=jecs`, `impls=previous`, `impls=lib`), 5 times in each mode, and take the
medians. The
[1.0.0 comparison evidence](https://github.com/dubalda/mErCS/blob/main/bench/results/1.0.0-comparison.md)
includes the full ranges, raw samples, source hashes and isolated entry points for reproducing
the matrix, synthetic frame, long session and memory probes.

The group `jecs strengths` (`bench/strengths.luau`) holds ten cases where an archetype ECS is at
its best, in time or in memory: `(*, T)` and `(R, *)` wildcards that return values, the memory
of cached queries over scattered entities, queries over two large terms after more than a few
changes of a term, twenty small queries that share a tag toggled on thirty entities, inline
queries built per call (a concrete pair per parent, two queries per new caster with the caster
as a term), `world:each` and `world:children` over many entities, entities of eight kinds
created in turn (with a slot pool too), deleting entities that have 100 targets of a relation,
and the memory of sparse components in a large world. The results are in
[the comparison](../comparison/jecs.md#the-strengths-of-jecs).

The group `query monitors` (`bench/monitors.luau`) times the changes that a query monitor
watches, against jecs 0.11.0 with its addon `modules/OB` (the `jecs_ob` alias of `.luaurc`;
`Impl.monitor` in `bench/impl_defs.luau`): a tag of the query added and removed, members
deleted, and children moved between parents under a monitor of `ChildOf` with any target.

The groups `query cases` and `sparse world` (`bench/shapes.luau`) time one pass of a query with
the changes a game makes before it: five cases where an archetype ECS is at its best (entity
ids scattered by churn, a tag of the query toggled between loops, four values read per match,
a `(*, T)` wildcard over changing pairs, a query that almost never matches), and creatures
scattered among their children (skills), also created from a slot pool. The group
`state tags` times a frame of 1200 skills in 5 state tags: 10, 200 or 800 of them move to
the next state, then 5 queries written inline pass over the skills of each state. A loop over
matches is the for-in loop for jecs and `query:each` for this library (it replaces the for-in
loop fully when the loop does not break). The worlds of the first two groups have fixed sizes
at `n = 131072` and shrink with a smaller `n`.

`bench/query_cases.luau` runs the same five cases with the test kit of jecs: one run per case,
first loops included; the matrix takes the minimum of several runs.

## Benchmarker (Roblox Studio)

`bench/visual/*.bench.luau` follow the format of the Benchmarker plugin (the same as
`jecs/test/benches/visual`): `ParameterGenerator`, `BeforeAll` / `AfterAll` /
`BeforeEach` / `AfterEach` and `Functions` with an entry for jecs and one for mErCS, and one for
ecr in the four basic benchmarks of jecs, named with their versions (`jecs 0.11.0`,
`mErCS 1.0.0`, `ecr 0.9.0`: `libs.luau` reads the versions of jecs and ecr from their Wally
packages and holds the version of mErCS). The parameters are generated before every call and
give each function its own fresh world. ecr declares its component types before the registries
that use them, so its files make them once, when they are required. `bench/basic.luau` runs the
four basic benchmarks in the CLI, one library per process.

| File | What |
|---|---|
| `spawn.bench.luau` | 1000 entities with 4 components (also ecr) |
| `insertion.bench.luau` | 8 components into 500 existing entities (also ecr) |
| `query.bench.luau` | 10 passes of a 4-component query over 4096 entities with random components (also `query:each`, and an ecr view) |
| `despawn.bench.luau` | delete 1000 entities with 4 components and a tag (also ecr) |
| `remove.bench.luau` | remove one of 5 components from 1000 entities |
| `pairs.bench.luau` | 100 parents with 10 `ChildOf` children that also target a parent through a relation, then the parents are deleted |
| `batch.bench.luau` | add and remove a tag on half of 2000 entities: batch operations against a jecs collect-and-change loop |
| `query_scattered.bench.luau` | a query case: a 4-component query over 50 000 entities scattered by churn |
| `query_churn.bench.luau` | a query case: a tag of the query toggled on 1 or 100 entities before each pass (70 000 entities) |
| `query_read4.bench.luau` | a query case: 4 values read per match (80 000 entities) |
| `query_wildcard.bench.luau` | a query case: `(*, T)` over 64 relations with a pair toggled before each pass (20 000 entities) |
| `query_empty.bench.luau` | a query case: 100 passes of a query that never matches (100 000 entities) |

The `query_*` files share `query_worlds.luau` (the worlds of `bench/query_cases.luau`, built
when a file is required) and run the same loops: the for-in loop for jecs, `query:each` for
mErCS.

The template `benchmarker.project.json` builds a place with only what the bench files need
(the library, the Wally dev packages and `bench/visual`, at the same paths as in the Studio
check place) and no scripts that run on Play:

```sh
wally install
rojo build benchmarker.project.json -o benchmarker.rbxl   # or: rojo serve benchmarker.project.json
```

Open the place (or sync it into an open one), open the Benchmarker plugin and run the files
from `ReplicatedStorage.mErCSCheck.bench.visual`. The same files are in the Studio check place
(below). The plugin requires a clone of each
`*.bench` module, which has no parent, so the bench files reach `libs.luau` from
`ReplicatedStorage` (relative requires fail in a clone); `libs.luau` itself requires jecs from
the Wally dev packages and the library by relative paths.

How the plugin runs a bench file, which matters when writing a new one:

1. It requires a clone of the module.
2. It calls every function once to check it: the function must not yield and must finish
   within 40 ms. This happens before `BeforeAll`, so whatever a function reads must exist
   when the module is required or come from `ParameterGenerator` (`query.bench.luau` builds
   its worlds at the top of the module).
3. It calls `BeforeAll`.
4. It runs 1000 rounds of every function. `ParameterGenerator` is called before each call,
   outside the measured time, and `BeforeEach` / `AfterEach` around it.
5. It calls `AfterAll`.

The results, including an error message, are stored in the `BenchResults` attribute of the
bench module. Its "Average" is the midpoint of the minimum and the maximum, not the mean:
compare the medians (50th percentile). The results of these files, with screenshots, are in
[Benchmarker](../comparison/benchmarker.md).

## Roblox Studio

```sh
wally install
rojo build studio/studio.project.json -o check.rbxl
```

Or sync into an open place: the workspace that contains this repository has a
`default.project.json` next to it (with a `rokit.toml` that pins rojo); run `rojo serve` there
and connect the Rojo plugin. Both projects include `studio/check.project.json`, the tree of
the check.

Open the place and press Play. The place mirrors the repository layout under
`ReplicatedStorage.mErCSCheck` (`src`, `DevPackages`, `bench`, `test`, `studio`), so
the tests and benchmarks run unchanged, with the same relative requires as in the luau CLI;
the check scripts are Scripts with the Server and Client run contexts.
The Output shows the fuzz result, the frame and the matrix for the server (native code) and
then for a client. For the native code size run `debug.dumpcodesize()` from the Command Bar
in the Server view. The library alone is built with `rojo build default.project.json -o
mErCS.rbxm`.

## Generated code

The specialized query iterators (0–8 returned values) are generated by `tools/generate.py`
between the `-- @generated <name> begin` / `end` markers of `src/init.luau`: the direct for-in
iterators and loops over bitset spans, the iterators and loops over the match list of a cached
query, and the ones over the buffer of a small query that is not cached:

```sh
python tools/generate.py && stylua src
```

## CI and releases

The workflows of `.github/workflows/` get the tools from `rokit.toml` (the
`CompeyDev/setup-rokit` action):

| Workflow | When | What |
|---|---|---|
| `ci.yml` | every pull request and push to `main` | `tools/check.sh`; `tools/test.sh` in both modes; workload runner tests; 3 fuzz runs of 400 rounds (`wide hooks`), 2 with `sparse pool verify hooks wide churn shapes monitors`, 3 exact-snapshot seeds of 2 000 rounds and 3 nested-change seeds of 300 rounds; model/package artifacts; documentation build |
| `release.yml` | a pushed tag `vX.Y.Z` | the tag must match `version` in `wally.toml`; checks and tests; `wally publish`; a GitHub release with `mercs.rbxm`, whose text is the section of the tag in `CHANGELOG.md` (generated notes when there is none) |
| `docs.yml` | a push to `main` that changes `src/`, `docs/`, `README.md` or `moonwave.toml` | builds the documentation site and publishes it to GitHub Pages |

To release a version:

1. Add a section `## vX.Y.Z — date` at the top of `CHANGELOG.md`. It becomes the text of the
   GitHub release (up to the next `## ` heading), so write links as absolute URLs. The site
   shows `CHANGELOG.md` as its Changelog page.
2. Set the version (without the `v`) in `wally.toml`, and in the output of the benchmarks:
   `library` in `bench/versions.luau` and `LIBRARY_VERSION` in `bench/visual/libs.luau`.
3. Run `python tools/workload.py baseline=v0.2.4 release=yes` (the tag of the previous
   release). Review performance and long-session memory, and save the report and
   raw samples under `bench/results/`. Summarize both modes/scales and every observable
   behavior change in the release notes.
4. Commit, wait for a green CI, then push the tag:

```sh
git tag -a v1.0.0 -m "mErCS v1.0.0"
git push origin v1.0.0
```

Settings of the GitHub repository:

- Settings → Pages → Source: **GitHub Actions**.
- Settings → Secrets and variables → Actions: `WALLY_AUTH_TOKEN` (see below).
- Settings → Rules → Rulesets: the rule for `main` (see below).

### The Wally token

The Wally registry accepts only a token that its own GitHub OAuth app issued: it checks the
token with GitHub (`GET /user` and the token check of the Wally app). Neither the automatic
`GITHUB_TOKEN` of the workflows nor a personal access token passes. Get the token once, with
the account that owns the `dubalda` scope:

1. Run `wally login` in the repository folder, open
   [github.com/login/device](https://github.com/login/device), enter the code and authorize
   Wally.
2. Copy the token (`gho_...`) from the `[tokens]` table of `~/.wally/auth.toml`
   (`%USERPROFILE%\.wally\auth.toml` on Windows).
3. Add it as the repository secret `WALLY_AUTH_TOKEN`.

The token does not expire by itself; it is revoked in the GitHub settings of the account
(Applications → Authorized OAuth Apps → Wally).

### The rule for `main`

`.github/rulesets/main.json` is a ruleset for the default branch. Import it in Settings →
Rules → Rulesets → New ruleset → **Import a ruleset**, review it and click Create. It makes
every change of `main` a pull request that merges only when:

- the CI jobs pass: "Format, lints and types", "Tests (interpreter)", "Tests (native)",
  "Model and Wally package", "Documentation site" (the job names of `ci.yml`: renaming a job
  means updating the ruleset);
- the branch is up to date with `main` (the "Update branch" button of the pull request);

and `main` cannot be deleted or force-pushed. No approvals are required (a pull request can be
merged by its author), and nobody bypasses the rule, administrators included. Tags are not
affected, so releases work as before.

Import it after CI has run once on GitHub, and check that the Checks tab shows these five
names: a required check that never reports keeps every pull request waiting.

The Wally package holds only the library: `wally.toml` excludes everything
(`exclude = ["**"]`) and includes `src`, `default.project.json`, `wally.toml`, `README.md` and
`LICENSE` (wally 0.3 packs every file that `include` alone does not override);
`wally package --list` shows the contents.

## The documentation site

[Moonwave](https://eryn.io/moonwave/) builds it: the API reference from the doc comments of
`src/` (the `--[=[ ]=]` blocks after the types of `src/init.luau`, and `src/jabby.luau`), the
pages of `docs/`, and `README.md` as the home page. It needs Node.js 18 or newer:

```sh
npx moonwave@1.4.2 dev     # a local preview that reloads on changes
npx moonwave@1.4.2 build   # the static site in build/
```

- `docs/` has an index, `docs/README.md`, and a folder per section with a `README.md`, which
  GitHub shows when the folder is opened; a section of several pages (`docs/comparison/`) has
  a file per page beside it. The index has `id: intro` in its front matter: Moonwave links the
  navigation bar to the doc `intro`. The `_category_.json` of a folder gives the label and the
  position of the section in the sidebar.
- The workflows rewrite the README links before the build: `docs/x/README.md` to `docs/x` (the
  site serves a folder page at `docs/x`) and `docs/x/y.md` to `docs/x/y`. A local build fails
  on these links, and a local preview shows them as broken, unless the `sed` of `docs.yml` is
  applied to `README.md` first (and undone after).
- The pages are MDX: `<https://...>` autolinks break the build, write `[text](url)`.
- Generics in the name of a `@type` break its page: write `@type Pair Id<First | Second>` and
  give `Pair<First, Second>` in the text. Parameters and returns may use generics.
- `[World:contains]`, `[mErCS.pair]` and the like in a doc comment become links to the
  reference.
- A broken link or a malformed doc comment fails the build, so `ci.yml` catches it in pull
  requests.
