# mErCS 1.0.0 and 0.2.4

How mErCS 1.0.0 compares with the previous release, 0.2.4: on the reference workload that the
releases are accepted on, and on the matrix of single operations of the [jecs](jecs.md) page.
What 1.0.0 does differently is in the
[changelog](https://github.com/dubalda/mErCS/blob/main/CHANGELOG.md): its "Changed behavior"
lists every change that code can observe.

## The reference workload

The reference workload is the model of the work that the library is released against: P1-P9
at the small and the target scale, both retained-agent variants, the client and the buffers
profiles, in the interpreter and in native code (`tools/workload.py`, Luau 0.740, `-O2`). Each
build and its second run are a process of their own, five times in each mode, and ten times more
for the target profile in native code (a row that the first run flagged, within the noise with
all its samples); the noise of a row is measured on the two runs of 0.2.4 alone. The
[release report](https://github.com/dubalda/mErCS/blob/main/bench/results/1.0.0.md) has all 224
rows with their ranges, and the raw samples.

- Time: no row is slower than the noise; one case is faster in both modes, the small world of P1
  (4 members among 1 500 entities after 40 transitions): 0.585 → 0.447 µs per loop in native
  code, 0.826 → 0.663 in the interpreter.
- Memory: a world takes 2 529 bytes more (54 533 instead of 52 004 bytes), a constant per world;
  nothing per entity, pair or query, and nothing accumulates over the lifecycle rounds and the
  long sessions.

A frame of the model (P7, µs) and the heap it leaves per frame (P9, bytes), medians [min–max] of
both runs of each version:

| Mode | Scale | P7, µs/frame: 0.2.4 → 1.0.0 | P9, bytes/frame: 0.2.4 → 1.0.0 |
|---|---|---|---|
| native | small | 102.11 [98.35–116.80] → 99.88 [95.28–109.30] | 4266.7 [4078.9–4403.2] → 4266.7 [4061.9–4386.1] |
| native | target | 354.48 [319.45–527.89] → 349.23 [320.94–622.74] | 7321.6 [5990.4–7714.1] → 7321.6 [6007.5–7731.2] |
| native | small-empty-retained | 100.09 [93.38–115.22] → 98.29 [94.48–107.09] | 4437.3 [4266.7–4522.7] → 4437.3 [4249.6–4522.7] |
| native | target-empty-retained | 325.38 [312.98–385.92] → 320.19 [309.75–379.06] | 6126.9 [5751.5–6963.2] → 6126.9 [5734.4–6963.2] |
| interpreter | small | 153.51 [148.23–161.19] → 153.57 [149.46–161.11] | 4266.7 [4078.9–4386.1] → 4266.7 [4078.9–4386.1] |
| interpreter | target | 490.63 [466.34–502.69] → 481.62 [468.92–556.86] | 7321.6 [6502.4–7714.1] → 7321.6 [6502.4–7714.1] |
| interpreter | small-empty-retained | 154.46 [151.01–158.54] → 155.82 [150.42–185.22] | 4437.3 [4266.7–4522.7] → 4437.3 [4249.6–4522.7] |
| interpreter | target-empty-retained | 485.27 [473.61–506.39] → 490.41 [474.40–506.29] | 6126.9 [5751.5–6963.2] → 6126.9 [5734.4–6963.2] |

The lifecycle events at the target scale (P6, µs per event):

| Mode | P6 target, µs per event: 0.2.4 → 1.0.0 | |
|---|---|---|
| native | a new agent with its owned entities | 1010.8 [952.9–1384.9] → 1010.3 [941.9–1438.0] |
| native | the end of the activity of an agent | 56.8 [52.3–75.0] → 54.0 [49.8–82.7] |
| native | the removal of a retained agent (cascade) | 1127.5 [1055.8–1483.8] → 1089.8 [1029.8–1545.9] |
| interpreter | a new agent with its owned entities | 1550.2 [1529.6–1570.0] → 1558.0 [1522.4–1613.7] |
| interpreter | the end of the activity of an agent | 85.9 [81.7–93.1] → 85.0 [79.9–89.4] |
| interpreter | the removal of a retained agent (cascade) | 1553.0 [1511.2–1610.0] → 1530.2 [1478.1–1623.1] |

The target world (P8):

| Mode | P8 target | 0.2.4 → 1.0.0 |
|---|---|---|
| native | the heap of the world after it is built | 137.64 [137.62–145.61] → 137.64 [137.62–145.61] |
| native | the heap after 100 lifecycle rounds | 138.58 [138.56–146.58] → 138.58 [138.56–146.58] |
| native | bytes per distinct pair (and its holder) | 1528.320 [1526.272–1529.344] → 1527.808 [1526.272–1528.832] |
| native | bytes per holder of a pair | 37.139 [35.090–37.395] → 37.139 [35.090–37.395] |
| interpreter | the heap of the world after it is built | 137.63 [137.62–145.61] → 137.63 [137.62–145.61] |
| interpreter | the heap after 100 lifecycle rounds | 138.56 [138.56–146.55] → 138.57 [138.56–146.55] |
| interpreter | bytes per distinct pair (and its holder) | 1528.320 [1527.808–1529.344] → 1528.320 [1527.808–1528.832] |
| interpreter | bytes per holder of a pair | 37.139 [37.139–37.395] → 37.139 [36.882–37.395] |

## Single operations

`bench/run.luau` and the probes of the [jecs](jecs.md#performance) page, measured in the same
runs as that page (mErCS 0.2.4 from its git tag): every library in a process of its own, five
times in each mode, the order rotated; medians. Cells read "interpreter / native"; the ratio
is the time of 1.0.0 divided by that of 0.2.4, lower is better. The
[complete measurements](https://github.com/dubalda/mErCS/blob/main/bench/results/1.0.0-comparison.md)
include the ranges.

Most rows stay within a few percent of 0.2.4. Deletes cost more where the fixes of nested hooks
and of monitors added work: an entity with four components 1.05× / 1.06×, a `ChildOf` cascade
1.05× / 1.11× per child, an entity with an `OnRemove` hook 1.12× / 1.19× (the clear keeps the
place of the running hook for the clears and removals that hooks start), a member of a monitored
query 1.21× / 1.33× and a child moved under a monitor 1.12× / 1.06× (a monitor also sees an
entity leave when its slot is freed). The reference workload does not show it: its lifecycle
events, which delete hundreds of entities with listeners, stay within the noise.

### A synthetic game frame

| Mode / queries | mErCS 0.2.4 | mErCS 1.0.0 | ratio |
|---|---|---|---|
| interpreter, inline queries | 2.25 ms | 2.2 ms | 0.98× |
| interpreter, cached queries | 2.25 ms | 2.21 ms | 0.98× |
| native, inline queries | 1.73 ms | 1.65 ms | 0.95× |
| native, cached queries | 1.65 ms | 1.59 ms | 0.96× |

### A long session

| Mode | Frame | mErCS 0.2.4 | mErCS 1.0.0 | ratio |
|---|---|---|---|---|
| interpreter | 1000 | +0.33 MiB, 0.089 ms | +0.33 MiB, 0.091 ms | — |
| interpreter | 3000 | +0.32 MiB, 0.087 ms | +0.32 MiB, 0.090 ms | — |
| interpreter | 5000 | +0.32 MiB, 0.086 ms | +0.32 MiB, 0.088 ms | — |
| native | 1000 | +0.33 MiB, 0.059 ms | +0.33 MiB, 0.061 ms | — |
| native | 3000 | +0.32 MiB, 0.060 ms | +0.32 MiB, 0.060 ms | — |
| native | 5000 | +0.32 MiB, 0.058 ms | +0.32 MiB, 0.062 ms | — |

### Query cases

| Case | mErCS 0.2.4 | mErCS 1.0.0 | ratio |
|---|---|---|---|
| Scattered after recycling | 90.3 / 63 µs | 91.2 / 63.1 µs | 1.01× / 1.00× |
| Churn on a queried tag, 1 toggle per pass | 286 / 204 µs | 282 / 208 µs | 0.99× / 1.02× |
| Churn on a queried tag, 100 toggles per pass | 255 / 176 µs | 262 / 179 µs | 1.03× / 1.02× |
| Read 4 components | 1.31 ms / 673 µs | 1.3 ms / 657 µs | 0.99× / 0.98× |
| `(*, T)` with churn | 524 / 334 µs | 531 / 331 µs | 1.01× / 0.99× |
| Usually empty | 43.3 / 27.1 ns | 43.9 / 27.7 ns | 1.01× / 1.02× |

### A sparse world

| Pass | mErCS 0.2.4 | mErCS 1.0.0 | ratio | mErCS 0.2.4, pool | mErCS 1.0.0, pool | ratio, pool |
|---|---|---|---|---|---|---|
| Alive creatures, nothing changed | 5.48 / 4.08 µs | 5.44 / 4.07 µs | 0.99× / 1.00× | 6.58 / 3.91 µs | 6.54 / 3.9 µs | 0.99× / 1.00× |
| Alive creatures, `Dead` added to one and removed | 7.05 / 5.16 µs | 7.23 / 5.18 µs | 1.03× / 1.00× | 7.15 / 4.23 µs | 7.01 / 4.31 µs | 0.98× / 1.02× |
| Running creatures, `Run` toggled on one | 4.69 / 3.46 µs | 4.69 / 3.4 µs | 1.00× / 0.98× | 2.87 / 1.74 µs | 2.78 / 1.81 µs | 0.97× / 1.04× |
| A tag added to one creature, a pass, removed, a pass | 1.99 / 1.28 µs | 2.06 / 1.31 µs | 1.04× / 1.02× | 1.64 µs / 982 ns | 1.63 µs / 984 ns | 0.99× / 1.00× |
| A tag nobody has | 46.1 / 29.6 ns | 44.8 / 30.7 ns | 0.97× / 1.04× | 43.8 / 27.8 ns | 43 / 28 ns | 0.98× / 1.01× |
| All with `Model` (creatures and corpses) | 18.7 / 14.1 µs | 19.1 / 14.1 µs | 1.02× / 1.00× | 15.2 / 8.63 µs | 15.2 / 8.58 µs | 1.00× / 0.99× |
| A skill changes state, 10 queries over skills in `Cast` | 110 / 65.8 µs | 106 / 66.6 µs | 0.96× / 1.01× | 109 / 67 µs | 107 / 67.7 µs | 0.98× / 1.01× |

### State tags

| Frame of 1200 skills, 5 inline queries | mErCS 0.2.4 | mErCS 1.0.0 | ratio |
|---|---|---|---|
| 10 skills change state | 41.1 / 24.1 µs | 40 / 24.5 µs | 0.97× / 1.02× |
| 200 skills change state | 165 / 98.4 µs | 162 / 95.2 µs | 0.98× / 0.97× |
| 800 skills change state | 356 / 224 µs | 363 / 219 µs | 1.02× / 0.97× |

### The strengths of jecs

| # | Case | mErCS 0.2.4 | mErCS 1.0.0 | ratio |
|---|---|---|---|---|
| 1 | `(*, T)` values, 32 data relations, a pass over 20 000 | 539 / 313 µs | 551 / 313 µs | 1.02× / 1.00× |
| 2 | `(R, *)` values, 8 targets, a pass over 20 000 | 539 / 315 µs | 540 / 309 µs | 1.00× / 0.98× |
| 3 | 15 cached queries over scattered entities, per query | 721 / 308 µs | 707 / 289 µs | 0.98× / 0.94× |
|  | the same, memory per query | 263 KiB | 263 KiB | 1.00× |
| 4 | usually empty, 20 swaps per pass (100 000 entities) | 12.8 / 7.21 µs | 13.1 / 7.24 µs | 1.02× / 1.00× |
|  | 5 queries, 100 matches each, 40 toggles per frame | 31.2 / 17.2 µs | 31 / 16.9 µs | 1.00× / 0.98× |
| 5 | 20 small queries, a shared tag toggled on 30 per frame | 22.2 / 14.6 µs | 22 / 14.5 µs | 0.99× / 1.00× |
| 6 | `query(A, pair(ChildOf, parent))` per parent (1000 × 5) | 572 / 523 ns | 568 / 482 ns | 0.99× / 0.92× |
|  | 2 inline queries per new caster | 4.09 / 3.44 µs | 4.05 / 3.48 µs | 0.99× / 1.01× |
|  | the same, memory per caster | 376 B | 376 B | 1.00× |
| 7 | `world:each` over 100 000, per entity | 32.7 / 25.3 ns | 31 / 24.9 ns | 0.95× / 0.98× |
|  | `world:children`, 1000 children, per child | 32.5 / 25.9 ns | 32.1 / 25.5 ns | 0.99× / 0.99× |
| 8 | 8 kinds in turn, 3 values, for-in, per match | 77.4 / 72.3 ns | 83.9 / 73.8 ns | 1.08× / 1.02× |
|  | the same, `each` | 57.7 / 45.5 ns | 58.3 / 51.2 ns | 1.01× / 1.12× |
|  | the same, `each`, the kind from a slot pool | 36.5 / 19.9 ns | 34.9 / 19.9 ns | 0.96× / 1.00× |
| 9 | delete entities with 100 targets, per pair | 64.1 / 43.5 ns | 60.9 / 44.5 ns | 0.95× / 1.03× |
| 10 | 8 components on 1 entity in 64 of 131 072, memory per entity | 660 B | 660 B | 1.00× |
|  | the same, time per entity | 2.44 / 1.53 µs | 2.38 / 1.53 µs | 0.97× / 1.00× |

### Query monitors

| Case | mErCS 0.2.4 | mErCS 1.0.0 | ratio |
|---|---|---|---|
| a tag of the query added and removed, per cycle (an entry and an exit) | 745 / 512 ns | 794 / 540 ns | 1.07× / 1.05× |
| members of the query deleted, per entity | 570 / 334 ns | 689 / 444 ns | 1.21× / 1.33× |
| children moved to another parent, `(ChildOf, *)` monitored, per move | 656 / 433 ns | 734 / 457 ns | 1.12× / 1.06× |

#### Entities

| Scenario | mErCS 0.2.4 | mErCS 1.0.0 | ratio |
|---|---|---|---|
| create an entity | 40.1 / 27 ns | 42.2 / 28 ns | 1.05× / 1.04× |
| delete an entity with 4 components | 417 / 227 ns | 437 / 240 ns | 1.05× / 1.06× |

#### Components

| Scenario | mErCS 0.2.4 | mErCS 1.0.0 | ratio |
|---|---|---|---|
| add a first component | 189 / 114 ns | 174 / 111 ns | 0.92× / 0.98× |
| set an existing component | 65.8 / 42.8 ns | 64.3 / 42.9 ns | 0.98× / 1.00× |
| remove a component | 115 / 57.1 ns | 115 / 58.1 ns | 1.00× / 1.02× |
| add when the entity has 5 | 129 / 69.5 ns | 126 / 71.8 ns | 0.97× / 1.03× |
| remove when the entity has 6 | 116 / 55.1 ns | 111 / 57 ns | 0.95× / 1.04× |
| add when the entity has 20 | 127 / 69.7 ns | 127 / 69.8 ns | 1.00× / 1.00× |
| remove when the entity has 21 | 114 / 54.8 ns | 110 / 56.3 ns | 0.96× / 1.03× |
| add when the entity has 40 | 121 / 66.6 ns | 121 / 66.8 ns | 1.00× / 1.00× |
| remove when the entity has 41 | 109 / 54.5 ns | 108 / 57 ns | 0.99× / 1.05× |

#### Tags

| Scenario | mErCS 0.2.4 | mErCS 1.0.0 | ratio |
|---|---|---|---|
| add a tag | 94.8 / 57.3 ns | 96.3 / 53.6 ns | 1.02× / 0.94× |
| remove a tag | 110 / 65.9 ns | 109 / 65 ns | 1.00× / 0.99× |
| toggle a tag on 10 % of the entities per frame | 163 / 101 ns | 160 / 96.1 ns | 0.98× / 0.95× |

#### Access

| Scenario | mErCS 0.2.4 | mErCS 1.0.0 | ratio |
|---|---|---|---|
| `get` 1 id | 48.7 / 37.3 ns | 48.5 / 36.5 ns | 1.00× / 0.98× |
| `get` 2 ids | 60.3 / 38.2 ns | 59.5 / 38.5 ns | 0.99× / 1.01× |
| `get` 4 ids | 89.7 / 50.1 ns | 87.6 / 50.3 ns | 0.98× / 1.00× |
| `get` 8 ids (jecs: at most 4) | 246 / 116 ns | 238 / 116 ns | 0.97× / 0.99× |
| `has` 1 id | 49.5 / 29.5 ns | 49.2 / 29.9 ns | 0.99× / 1.02× |
| `has` 4 ids | 97.3 / 41.7 ns | 100 / 42.9 ns | 1.03× / 1.03× |
| `has` 8 ids (jecs: at most 4) | 170 / 69.6 ns | 186 / 70.5 ns | 1.09× / 1.01× |

#### Pairs

| Scenario | mErCS 0.2.4 | mErCS 1.0.0 | ratio |
|---|---|---|---|
| `pair(R, T)` | 20.5 / 8.54 ns | 20.5 / 10.2 ns | 1.00× / 1.19× |
| add a pair | 274 / 169 ns | 274 / 175 ns | 1.00× / 1.03× |
| set the value of an existing pair | 71.5 / 51.9 ns | 70.8 / 51.2 ns | 0.99× / 0.99× |
| remove a pair | 201 / 107 ns | 195 / 113 ns | 0.97× / 1.05× |
| `target` (4 pairs) | 65.5 / 43.5 ns | 66.7 / 42.2 ns | 1.02× / 0.97× |
| `ChildOf` children, per child (10 000 parents × 5) | 135 / 91.9 ns | 132 / 92.5 ns | 0.98× / 1.01× |
| add a pair with a target of its own | 3.18 / 2.66 µs | 3.01 / 2.66 µs | 0.95× / 1.00× |
| delete a target: `Remove` (1000 × 100 sources, per source) | 150 / 78 ns | 147 / 80.1 ns | 0.98× / 1.03× |
| delete a parent: `ChildOf` cascade (per child) | 368 / 229 ns | 384 / 255 ns | 1.05× / 1.11× |

#### Queries (per entity or match)

| Scenario | mErCS 0.2.4 | mErCS 1.0.0 | ratio |
|---|---|---|---|
| for-in, 4 values, 8192 entities per archetype | 47.1 / 32.3 ns | 46.6 / 31.9 ns | 0.99× / 0.99× |
| `query:each`, the same (ratio: against the jecs for-in) | 30.7 / 15.2 ns | 31 / 15.3 ns | 1.01× / 1.01× |
| manual loop (`spans` / jecs archetypes), the same | 13.4 / 4.66 ns | 13 / 4.63 ns | 0.97× / 0.99× |
| for-in, 4 values, 256 entities per archetype | 51.1 / 34.3 ns | 51.6 / 33.7 ns | 1.01× / 0.98× |
| `query:each`, the same (against the jecs for-in) | 34.3 / 16.4 ns | 32.9 / 16.2 ns | 0.96× / 0.99× |
| manual loop, the same | 16.6 / 5.92 ns | 16.4 / 5.92 ns | 0.99× / 1.00× |
| for-in, 4 values, 16 entities per archetype | 65.3 / 40.7 ns | 66.3 / 39.9 ns | 1.02× / 0.98× |
| `query:each`, the same (against the jecs for-in) | 49.3 / 20 ns | 45.9 / 20.8 ns | 0.93× / 1.04× |
| manual loop, the same | 31.3 / 9.1 ns | 30.5 / 9.13 ns | 0.97× / 1.00× |
| for-in, 4 values, 1 entity per archetype | 72.5 / 44.4 ns | 73 / 44.5 ns | 1.01× / 1.00× |
| `query:each`, the same (against the jecs for-in) | 54.1 / 25.2 ns | 53.6 / 25.5 ns | 0.99× / 1.01× |
| manual loop, the same | 35.3 / 13.7 ns | 35.2 / 13.8 ns | 1.00× / 1.00× |
| a query created and iterated once | 46.5 / 31.6 ns | 46.6 / 31.9 ns | 1.00× / 1.01× |
| for-in, 1 value of an entity with 4 | 36 / 26.2 ns | 35.4 / 26.3 ns | 0.98× / 1.00× |
| for-in with `without` (half excluded) | 36.1 / 29.3 ns | 35.6 / 29.3 ns | 0.99× / 1.00× |
| `query:each`, the same (against the jecs for-in) | 21 / 12.4 ns | 20.5 / 13 ns | 0.98× / 1.04× |
| for-in over a sparse match (1 %) | 61.2 / 52.5 ns | 61.7 / 55.1 ns | 1.01× / 1.05× |
| `query:each`, the same (against the jecs for-in) | 38.5 / 29 ns | 40.6 / 27.6 ns | 1.05× / 0.95× |
| the first loop of a new query (2000 archetypes), per query | 398 / 312 ns | 388 / 328 ns | 0.97× / 1.05× |
| a small query created on every call (15 of 1000), per query | 1.18 / 1.05 µs | 1.19 / 1.06 µs | 1.01× / 1.01× |
| a query of a concrete pair created on every call (15 of 1000), per query | 1.03 µs / 908 ns | 1.05 µs / 895 ns | 1.02× / 0.99× |
| the same, nothing matches (0 of 1000) | 177 / 156 ns | 171 / 152 ns | 0.96× / 0.98× |
| an entity used as a term in 4 inline queries, then deleted, per entity | 5.42 / 4.82 µs | 5.53 / 5.02 µs | 1.02× / 1.04× |
| a query with 10 terms | 96.5 / 56.7 ns | 95.4 / 58.8 ns | 0.99× / 1.04× |

#### Batch operations (per match; jecs: a collect-and-change loop)

| Scenario | mErCS 0.2.4 | mErCS 1.0.0 | ratio |
|---|---|---|---|
| add a tag to the matches (half of the entities) | 34.9 / 12.6 ns | 35.2 / 12.5 ns | 1.01× / 1.00× |
| set a component on the matches | 68.1 / 25.5 ns | 69.7 / 26 ns | 1.02× / 1.02× |
| remove a component from the matches | 36.8 / 12 ns | 36.4 / 11.6 ns | 0.99× / 0.97× |
| delete the matches | 444 / 240 ns | 466 / 253 ns | 1.05× / 1.06× |
| count the matches | 6.96 / 2.37 ns | 6.76 / 2.35 ns | 0.97× / 0.99× |

#### Churn (per cycle)

| Scenario | mErCS 0.2.4 | mErCS 1.0.0 | ratio |
|---|---|---|---|
| spawn and despawn (10 components, 2 tags) | 2.38 / 1.28 µs | 2.39 / 1.32 µs | 1.01× / 1.03× |
| a hierarchy of 1 + 5 `ChildOf`, spawned and deleted | 10.3 / 6.82 µs | 10.3 / 7.44 µs | 0.99× / 1.09× |

### Memory and garbage

| Kept per unit | mErCS 0.2.4 | mErCS 1.0.0 | ratio |
|---|---|---|---|
| an empty entity | 32 B | 32 B | 1.00× |
| an entity with 4 components | 131 B | 131 B | 1.00× |
| an entity with 10 components and 5 tags | 236 B | 236 B | 1.00× |
| a `ChildOf` child (10 000 parents × 5) | 344 B | 344 B | 1.00× |
| an entity with a tag of its own | 978 B | 978 B | 1.00× |
| a pair with a target of its own | 1457 B | 1457 B | 1.00× |
| a component of 1000 on 100 entities each, per add | 162 B | 162 B | 1.00× |
| growth per hierarchy spawn / despawn cycle | 0 B | 0 B | — |
| an entity used in 4 inline queries, then deleted | 1 B | 1 B | 0.91× |
| Loop | mErCS 0.2.4 | mErCS 1.0.0 | ratio |
|---|---|---|---|
| Inline two-component query | 80 B | 81 B | 1.01× |
| Stored query | 0 B | 0 B | — |
| `world:each` | 153 B | 152 B | 0.99× |
