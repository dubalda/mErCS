# mErCS 1.0.1 and 1.0.0

How mErCS 1.0.1 compares with the previous release, 1.0.0: on the reference workload that the
releases are accepted on, and on the matrix of single operations of the [jecs](jecs.md) page.
1.0.1 changes no behavior; what it does differently is in the
[changelog](https://github.com/dubalda/mErCS/blob/main/CHANGELOG.md): deletes of entities with
removal hooks or listeners, and the fields that adds, sets and clears read.

## The reference workload

The reference workload is the model of the work that the library is released against: P1-P9
at the small and the target scale, both retained-agent variants, the client and the buffers
profiles, in the interpreter and in native code (`tools/workload.py`, Luau 0.740, `-O2`). Each
build and its second run are a process of their own, five times in each mode; the noise of a row
is measured on the two runs of 1.0.0 alone. The
[release report](https://github.com/dubalda/mErCS/blob/main/bench/results/1.0.1.md) has all 232
rows with their ranges, and the raw samples.

- Time: no row is slower than the noise. The cascade of the removal of an agent alone (a new
  case of P6: the owned entities of an agent, each with a removal listener, deleted with it in a
  world of its own) is faster beyond the noise at the target scale in both modes and in native
  code in the small-empty-retained profile: 294.8 → 260.0 µs per event in native code and
  467.2 → 441.0 µs in the interpreter at the target scale; its other rows are faster within the
  noise. The other lifecycle events and the frame model run the cascade a few times a second
  among their other work and stay within the noise.
- Memory: a world takes 318 bytes more (54 856 instead of 54 538 bytes), a constant per world;
  nothing per entity, pair or query, and nothing accumulates over the lifecycle rounds and the
  long sessions.

A frame of the model (P7, µs) and the heap it leaves per frame (P9, bytes), medians [min–max] of
both runs of each version:

| Mode | Scale | P7, µs/frame: 1.0.0 → 1.0.1 | P9, bytes/frame: 1.0.0 → 1.0.1 |
|---|---|---|---|
| native | small | 97.78 [94.07–106.50] → 95.45 [92.48–97.42] | 4266.7 [4061.9–4386.1] → 4266.7 [4078.9–4386.1] |
| native | target | 336.23 [321.08–450.26] → 332.83 [324.37–377.05] | 7321.6 [6502.4–7731.2] → 7321.6 [6502.4–7714.1] |
| native | small-empty-retained | 98.36 [93.63–105.78] → 95.44 [92.60–106.73] | 4437.3 [4249.6–4522.7] → 4437.3 [4249.6–4522.7] |
| native | target-empty-retained | 327.58 [315.20–404.65] → 313.93 [306.59–340.39] | 6126.9 [5734.4–6980.3] → 6126.9 [5734.4–6963.2] |
| interpreter | small | 149.31 [145.53–180.86] → 151.80 [147.78–163.85] | 4266.7 [4078.9–4386.1] → 4266.7 [4078.9–4386.1] |
| interpreter | target | 480.73 [473.96–515.11] → 483.99 [472.49–530.27] | 7321.6 [6502.4–7714.1] → 7321.6 [6502.4–7714.1] |
| interpreter | small-empty-retained | 148.78 [145.93–161.07] → 148.29 [144.98–156.25] | 4437.3 [4249.6–4522.7] → 4437.3 [4249.6–4522.7] |
| interpreter | target-empty-retained | 469.91 [463.22–508.19] → 465.49 [459.35–482.31] | 6126.9 [5734.4–6963.2] → 6126.9 [5734.4–6963.2] |

The lifecycle events at the target scale (P6, µs per event):

| Mode | P6 target, µs per event: 1.0.0 → 1.0.1 | |
|---|---|---|
| native | a new agent with its owned entities | 959.9 [941.9–1198.6] → 943.1 [903.2–1020.3] |
| native | the end of the activity of an agent | 52.3 [48.4–63.2] → 53.6 [48.9–58.8] |
| native | the removal of a retained agent (cascade) | 1039.9 [1010.7–1274.0] → 1026.4 [982.9–1123.0] |
| native | the cascade of the removal of an agent, isolated | 294.8 [287.6–316.9] → 260.0 [249.0–261.6] |
| interpreter | a new agent with its owned entities | 1547.0 [1503.1–1646.1] → 1501.5 [1469.5–2022.4] |
| interpreter | the end of the activity of an agent | 84.6 [82.4–91.7] → 84.4 [80.0–109.8] |
| interpreter | the removal of a retained agent (cascade) | 1612.4 [1553.8–1790.8] → 1596.0 [1554.0–1976.2] |
| interpreter | the cascade of the removal of an agent, isolated | 467.2 [457.4–507.5] → 441.0 [424.9–566.6] |

The same at the small scale:

| Mode | P6 small, µs per event: 1.0.0 → 1.0.1 | |
|---|---|---|
| native | a new agent with its owned entities | 46.40 [41.85–50.60] → 43.15 [41.90–44.45] |
| native | the end of the activity of an agent | 3.13 [2.20–4.45] → 2.43 [2.20–3.00] |
| native | the removal of a retained agent (cascade) | 51.63 [42.40–69.00] → 44.10 [40.05–50.95] |
| native | the cascade of the removal of an agent, isolated | 11.05 [10.70–11.40] → 10.00 [9.30–12.00] |
| interpreter | a new agent with its owned entities | 64.80 [63.05–72.00] → 64.73 [62.90–69.75] |
| interpreter | the end of the activity of an agent | 4.05 [3.40–5.50] → 3.98 [3.45–5.45] |
| interpreter | the removal of a retained agent (cascade) | 72.05 [65.80–85.50] → 70.72 [65.80–83.10] |
| interpreter | the cascade of the removal of an agent, isolated | 17.45 [16.40–18.70] → 16.60 [15.90–29.70] |

The target world (P8):

| Mode | P8 target | 1.0.0 → 1.0.1 |
|---|---|---|
| native | the heap of the world after it is built | 137.63 [137.62–145.61] → 137.63 [137.62–145.61] |
| native | the heap after 100 lifecycle rounds | 138.57 [138.56–146.55] → 138.57 [138.56–146.56] |
| native | bytes per distinct pair (and its holder) | 1527.808 [1527.296–1529.344] → 1527.808 [1527.296–1529.344] |
| native | bytes per holder of a pair | 37.139 [37.139–37.395] → 37.139 [37.139–37.395] |
| interpreter | the heap of the world after it is built | 137.63 [137.62–145.61] → 137.63 [137.62–145.61] |
| interpreter | the heap after 100 lifecycle rounds | 138.57 [138.56–146.55] → 138.57 [138.56–146.56] |
| interpreter | bytes per distinct pair (and its holder) | 1527.808 [1527.296–1529.344] → 1527.808 [1527.296–1529.344] |
| interpreter | bytes per holder of a pair | 37.139 [37.139–37.395] → 37.139 [36.882–37.395] |

## Single operations

`bench/run.luau` and the probes of the [jecs](jecs.md#performance) page, measured in the same
runs as that page (mErCS 1.0.0 from its git tag): every library in a process of its own, five
times in each mode (fifteen for the synthetic frame), the order rotated; medians. Cells read
"interpreter / native"; the ratio is the time of 1.0.1 divided by that of 1.0.0, lower is better.
The [complete measurements](https://github.com/dubalda/mErCS/blob/main/bench/results/1.0.1-comparison.md)
include the ranges.

Most rows stay within a few percent of 1.0.0, both ways. Deletes and removals are faster in
native code: a member of a monitored query 0.92× / 0.85×, a `ChildOf` cascade 1.02× / 0.89× per
child, a tag removed 0.98× / 0.92×, an entity with four components 0.99× / 0.96×; the cost of an
`OnRemove` hook on a delete is 205 / 127 ns in 1.0.0 and 190 / 103 ns in 1.0.1 (the probe of
the [jecs](jecs.md#query-monitors) page). The interpreter rows of the eight kinds created in turn
(1.19× for the for-in loop, 1.09× for `each`) vary by up to 40 % between the processes of one
version: 24 more processes of each give 1.02× for the for-in loop.

### A synthetic game frame

| Mode / queries | mErCS 1.0.0 | mErCS 1.0.1 | ratio |
|---|---|---|---|
| interpreter, inline queries | 2.23 ms | 2.26 ms | 1.01× |
| interpreter, cached queries | 2.27 ms | 2.31 ms | 1.02× |
| native, inline queries | 1.66 ms | 1.66 ms | 1.00× |
| native, cached queries | 1.66 ms | 1.69 ms | 1.01× |

### A long session

| Mode | Frame | mErCS 1.0.0 | mErCS 1.0.1 | ratio |
|---|---|---|---|---|
| interpreter | 1000 | +0.33 MiB, 0.089 ms | +0.33 MiB, 0.092 ms | — |
| interpreter | 3000 | +0.32 MiB, 0.089 ms | +0.32 MiB, 0.089 ms | — |
| interpreter | 5000 | +0.32 MiB, 0.090 ms | +0.32 MiB, 0.093 ms | — |
| native | 1000 | +0.33 MiB, 0.061 ms | +0.33 MiB, 0.063 ms | — |
| native | 3000 | +0.32 MiB, 0.060 ms | +0.32 MiB, 0.061 ms | — |
| native | 5000 | +0.32 MiB, 0.060 ms | +0.32 MiB, 0.059 ms | — |

### Query cases

| Case | mErCS 1.0.0 | mErCS 1.0.1 | ratio |
|---|---|---|---|
| Scattered after recycling | 88.2 / 62.6 µs | 89.2 / 61.6 µs | 1.01× / 0.98× |
| Churn on a queried tag, 1 toggle per pass | 282 / 209 µs | 285 / 205 µs | 1.01× / 0.98× |
| Churn on a queried tag, 100 toggles per pass | 261 / 183 µs | 261 / 177 µs | 1.00× / 0.96× |
| Read 4 components | 1.29 ms / 663 µs | 1.29 ms / 656 µs | 1.00× / 0.99× |
| `(*, T)` with churn | 519 / 335 µs | 532 / 332 µs | 1.02× / 0.99× |
| Usually empty | 44.5 / 27.3 ns | 42.2 / 27.1 ns | 0.95× / 0.99× |

### A sparse world

| Pass | mErCS 1.0.0 | mErCS 1.0.1 | ratio | mErCS 1.0.0, pool | mErCS 1.0.1, pool | ratio, pool |
|---|---|---|---|---|---|---|
| Alive creatures, nothing changed | 5.62 / 4.06 µs | 5.39 / 4.03 µs | 0.96× / 0.99× | 6.66 / 3.84 µs | 6.83 / 3.95 µs | 1.03× / 1.03× |
| Alive creatures, `Dead` added to one and removed | 7.23 / 5.13 µs | 7.26 / 5.02 µs | 1.00× / 0.98× | 6.96 / 4.2 µs | 7.2 / 4.18 µs | 1.03× / 1.00× |
| Running creatures, `Run` toggled on one | 4.71 / 3.51 µs | 4.63 / 3.34 µs | 0.98× / 0.95× | 2.77 / 1.76 µs | 2.83 / 1.75 µs | 1.02× / 0.99× |
| A tag added to one creature, a pass, removed, a pass | 1.98 / 1.32 µs | 2.04 / 1.29 µs | 1.03× / 0.98× | 1.63 µs / 997 ns | 1.62 µs / 989 ns | 0.99× / 0.99× |
| A tag nobody has | 45.2 / 31.1 ns | 42.1 / 28.8 ns | 0.93× / 0.93× | 44.3 / 28.5 ns | 42.6 / 28.3 ns | 0.96× / 0.99× |
| All with `Model` (creatures and corpses) | 19.1 / 14.4 µs | 18.9 / 13.9 µs | 0.99× / 0.96× | 15.6 / 8.52 µs | 15.2 / 8.58 µs | 0.97× / 1.01× |
| A skill changes state, 10 queries over skills in `Cast` | 103 / 72.7 µs | 106 / 64 µs | 1.02× / 0.88× | 111 / 68.7 µs | 109 / 66.5 µs | 0.98× / 0.97× |

### State tags

| Frame of 1200 skills, 5 inline queries | mErCS 1.0.0 | mErCS 1.0.1 | ratio |
|---|---|---|---|
| 10 skills change state | 40.3 / 24.2 µs | 39.7 / 24.2 µs | 0.99× / 1.00× |
| 200 skills change state | 163 / 94.9 µs | 160 / 94 µs | 0.99× / 0.99× |
| 800 skills change state | 362 / 219 µs | 355 / 214 µs | 0.98× / 0.98× |

### The strengths of jecs

| # | Case | mErCS 1.0.0 | mErCS 1.0.1 | ratio |
|---|---|---|---|---|
| 1 | `(*, T)` values, 32 data relations, a pass over 20 000 | 535 / 313 µs | 540 / 311 µs | 1.01× / 0.99× |
| 2 | `(R, *)` values, 8 targets, a pass over 20 000 | 547 / 314 µs | 540 / 310 µs | 0.99× / 0.99× |
| 3 | 15 cached queries over scattered entities, per query | 715 / 320 µs | 733 / 318 µs | 1.03× / 0.99× |
|  | the same, memory per query | 263 KiB | 263 KiB | 1.00× |
| 4 | usually empty, 20 swaps per pass (100 000 entities) | 13.2 / 7.6 µs | 13.3 / 7.07 µs | 1.01× / 0.93× |
|  | 5 queries, 100 matches each, 40 toggles per frame | 32.2 / 17.1 µs | 31.4 / 17.1 µs | 0.98× / 1.00× |
| 5 | 20 small queries, a shared tag toggled on 30 per frame | 22.2 / 14.8 µs | 22.6 / 14.3 µs | 1.02× / 0.97× |
| 6 | `query(A, pair(ChildOf, parent))` per parent (1000 × 5) | 577 / 495 ns | 604 / 479 ns | 1.05× / 0.97× |
|  | 2 inline queries per new caster | 4.23 / 3.74 µs | 4.11 / 3.49 µs | 0.97× / 0.93× |
|  | the same, memory per caster | 376 B | 376 B | 1.00× |
| 7 | `world:each` over 100 000, per entity | 32.7 / 24.9 ns | 31.7 / 24.4 ns | 0.97× / 0.98× |
|  | `world:children`, 1000 children, per child | 32.5 / 25.9 ns | 32.5 / 26 ns | 1.00× / 1.00× |
| 8 | 8 kinds in turn, 3 values, for-in, per match | 77.5 / 78.8 ns | 91.8 / 72.8 ns | 1.19× / 0.92× |
|  | the same, `each` | 57.1 / 52.4 ns | 62.5 / 49.1 ns | 1.09× / 0.94× |
|  | the same, `each`, the kind from a slot pool | 35.8 / 20.4 ns | 35.3 / 20 ns | 0.99× / 0.98× |
| 9 | delete entities with 100 targets, per pair | 61.4 / 44.3 ns | 62.1 / 43.8 ns | 1.01× / 0.99× |
| 10 | 8 components on 1 entity in 64 of 131 072, memory per entity | 661 B | 660 B | 1.00× |
|  | the same, time per entity | 2.42 / 1.58 µs | 2.44 / 1.59 µs | 1.01× / 1.01× |

### Query monitors

| Case | mErCS 1.0.0 | mErCS 1.0.1 | ratio |
|---|---|---|---|
| a tag of the query added and removed, per cycle (an entry and an exit) | 837 / 554 ns | 845 / 552 ns | 1.01× / 1.00× |
| members of the query deleted, per entity | 713 / 450 ns | 659 / 383 ns | 0.92× / 0.85× |
| children moved to another parent, `(ChildOf, *)` monitored, per move | 725 / 467 ns | 726 / 439 ns | 1.00× / 0.94× |

#### Entities

| Scenario | mErCS 1.0.0 | mErCS 1.0.1 | ratio |
|---|---|---|---|
| create an entity | 44 / 27.7 ns | 41.9 / 27.3 ns | 0.95× / 0.99× |
| delete an entity with 4 components | 468 / 240 ns | 463 / 231 ns | 0.99× / 0.96× |

#### Components

| Scenario | mErCS 1.0.0 | mErCS 1.0.1 | ratio |
|---|---|---|---|
| add a first component | 175 / 117 ns | 177 / 112 ns | 1.01× / 0.96× |
| set an existing component | 66.6 / 42.9 ns | 65.7 / 42.9 ns | 0.99× / 1.00× |
| remove a component | 115 / 58.2 ns | 117 / 57.6 ns | 1.01× / 0.99× |
| add when the entity has 5 | 131 / 70.7 ns | 127 / 67.1 ns | 0.97× / 0.95× |
| remove when the entity has 6 | 113 / 56.9 ns | 115 / 55.4 ns | 1.01× / 0.97× |
| add when the entity has 20 | 126 / 69.5 ns | 129 / 68.2 ns | 1.02× / 0.98× |
| remove when the entity has 21 | 115 / 57.1 ns | 115 / 55.7 ns | 1.00× / 0.98× |
| add when the entity has 40 | 123 / 67.3 ns | 127 / 63.6 ns | 1.03× / 0.94× |
| remove when the entity has 41 | 113 / 55.5 ns | 111 / 54.5 ns | 0.99× / 0.98× |

#### Tags

| Scenario | mErCS 1.0.0 | mErCS 1.0.1 | ratio |
|---|---|---|---|
| add a tag | 95.2 / 55.1 ns | 94.2 / 51.1 ns | 0.99× / 0.93× |
| remove a tag | 108 / 65.8 ns | 106 / 60.4 ns | 0.98× / 0.92× |
| toggle a tag on 10 % of the entities per frame | 168 / 97.7 ns | 165 / 92.7 ns | 0.98× / 0.95× |

#### Access

| Scenario | mErCS 1.0.0 | mErCS 1.0.1 | ratio |
|---|---|---|---|
| `get` 1 id | 48.9 / 37.5 ns | 48 / 38.6 ns | 0.98× / 1.03× |
| `get` 2 ids | 60.4 / 39.7 ns | 63.8 / 40.7 ns | 1.06× / 1.03× |
| `get` 4 ids | 86 / 51.1 ns | 91.8 / 51.8 ns | 1.07× / 1.01× |
| `get` 8 ids (jecs: at most 4) | 250 / 117 ns | 240 / 116 ns | 0.96× / 1.00× |
| `has` 1 id | 50.4 / 29.9 ns | 49.3 / 29.7 ns | 0.98× / 0.99× |
| `has` 4 ids | 98.1 / 42.7 ns | 95.9 / 41.8 ns | 0.98× / 0.98× |
| `has` 8 ids (jecs: at most 4) | 189 / 70.2 ns | 164 / 69.5 ns | 0.87× / 0.99× |

#### Pairs

| Scenario | mErCS 1.0.0 | mErCS 1.0.1 | ratio |
|---|---|---|---|
| `pair(R, T)` | 20.6 / 10.2 ns | 20.3 / 8.55 ns | 0.99× / 0.84× |
| add a pair | 283 / 173 ns | 286 / 175 ns | 1.01× / 1.01× |
| set the value of an existing pair | 72.2 / 51.9 ns | 71.8 / 51.2 ns | 0.99× / 0.99× |
| remove a pair | 194 / 110 ns | 197 / 110 ns | 1.02× / 0.99× |
| `target` (4 pairs) | 67.5 / 42.9 ns | 65.2 / 43.4 ns | 0.97× / 1.01× |
| `ChildOf` children, per child (10 000 parents × 5) | 132 / 100 ns | 134 / 95.2 ns | 1.02× / 0.95× |
| add a pair with a target of its own | 3.24 / 2.93 µs | 3.27 / 2.84 µs | 1.01× / 0.97× |
| delete a target: `Remove` (1000 × 100 sources, per source) | 153 / 82.3 ns | 148 / 81.2 ns | 0.96× / 0.99× |
| delete a parent: `ChildOf` cascade (per child) | 408 / 262 ns | 415 / 232 ns | 1.02× / 0.89× |

#### Queries (per entity or match)

| Scenario | mErCS 1.0.0 | mErCS 1.0.1 | ratio |
|---|---|---|---|
| for-in, 4 values, 8192 entities per archetype | 46.9 / 32.8 ns | 46.2 / 32.5 ns | 0.98× / 0.99× |
| `query:each`, the same (ratio: against the jecs for-in) | 31.2 / 15.2 ns | 30.6 / 15.3 ns | 0.98× / 1.00× |
| manual loop (`spans` / jecs archetypes), the same | 13.6 / 4.71 ns | 13.2 / 4.88 ns | 0.97× / 1.04× |
| for-in, 4 values, 256 entities per archetype | 51.9 / 34.7 ns | 50.3 / 34.4 ns | 0.97× / 0.99× |
| `query:each`, the same (against the jecs for-in) | 33.6 / 16.6 ns | 33.8 / 16.5 ns | 1.00× / 1.00× |
| manual loop, the same | 16.8 / 6.09 ns | 16.3 / 6.03 ns | 0.97× / 0.99× |
| for-in, 4 values, 16 entities per archetype | 67.6 / 41.2 ns | 66.8 / 40.6 ns | 0.99× / 0.99× |
| `query:each`, the same (against the jecs for-in) | 47.5 / 20.2 ns | 46.1 / 20.2 ns | 0.97× / 1.00× |
| manual loop, the same | 30.4 / 9.24 ns | 31.8 / 9.25 ns | 1.05× / 1.00× |
| for-in, 4 values, 1 entity per archetype | 72.3 / 45.4 ns | 73.1 / 45.3 ns | 1.01× / 1.00× |
| `query:each`, the same (against the jecs for-in) | 53.2 / 25 ns | 54.8 / 25.3 ns | 1.03× / 1.01× |
| manual loop, the same | 35.3 / 13.9 ns | 35.1 / 14 ns | 1.00× / 1.00× |
| a query created and iterated once | 49.1 / 33.5 ns | 46.8 / 32.5 ns | 0.95× / 0.97× |
| for-in, 1 value of an entity with 4 | 35.9 / 27.8 ns | 35.8 / 27.4 ns | 1.00× / 0.98× |
| for-in with `without` (half excluded) | 36.3 / 29.8 ns | 36.2 / 29.3 ns | 1.00× / 0.98× |
| `query:each`, the same (against the jecs for-in) | 21.5 / 12.6 ns | 21.2 / 12.4 ns | 0.99× / 0.98× |
| for-in over a sparse match (1 %) | 63.7 / 56.5 ns | 62.1 / 54.6 ns | 0.97× / 0.97× |
| `query:each`, the same (against the jecs for-in) | 39.9 / 27.5 ns | 38.9 / 28.9 ns | 0.97× / 1.05× |
| the first loop of a new query (2000 archetypes), per query | 384 / 343 ns | 406 / 333 ns | 1.06× / 0.97× |
| a small query created on every call (15 of 1000), per query | 1.17 / 1.08 µs | 1.17 / 1.05 µs | 1.00× / 0.98× |
| a query of a concrete pair created on every call (15 of 1000), per query | 1.02 µs / 883 ns | 1.01 µs / 891 ns | 0.99× / 1.01× |
| the same, nothing matches (0 of 1000) | 173 / 152 ns | 173 / 156 ns | 1.00× / 1.03× |
| an entity used as a term in 4 inline queries, then deleted, per entity | 5.56 / 5.03 µs | 5.58 / 5.04 µs | 1.00× / 1.00× |
| a query with 10 terms | 96.8 / 58.8 ns | 96.8 / 62.5 ns | 1.00× / 1.06× |

#### Batch operations (per match; jecs: a collect-and-change loop)

| Scenario | mErCS 1.0.0 | mErCS 1.0.1 | ratio |
|---|---|---|---|
| add a tag to the matches (half of the entities) | 35.7 / 12.4 ns | 35.3 / 12.5 ns | 0.99× / 1.01× |
| set a component on the matches | 69.5 / 26.8 ns | 69.8 / 26.8 ns | 1.00× / 1.00× |
| remove a component from the matches | 36.8 / 11.8 ns | 37.5 / 11.7 ns | 1.02× / 0.99× |
| delete the matches | 475 / 252 ns | 485 / 239 ns | 1.02× / 0.95× |
| count the matches | 6.8 / 2.41 ns | 6.97 / 2.49 ns | 1.03× / 1.03× |

#### Churn (per cycle)

| Scenario | mErCS 1.0.0 | mErCS 1.0.1 | ratio |
|---|---|---|---|
| spawn and despawn (10 components, 2 tags) | 2.43 / 1.32 µs | 2.38 / 1.27 µs | 0.98× / 0.96× |
| a hierarchy of 1 + 5 `ChildOf`, spawned and deleted | 10.5 / 7.28 µs | 10.6 / 7.1 µs | 1.00× / 0.97× |

### Memory and garbage

| Kept per unit | mErCS 1.0.0 | mErCS 1.0.1 | ratio |
|---|---|---|---|
| an empty entity | 32 B | 32 B | 1.00× |
| an entity with 4 components | 131 B | 131 B | 1.00× |
| an entity with 10 components and 5 tags | 236 B | 236 B | 1.00× |
| a `ChildOf` child (10 000 parents × 5) | 344 B | 344 B | 1.00× |
| an entity with a tag of its own | 978 B | 978 B | 1.00× |
| a pair with a target of its own | 1457 B | 1457 B | 1.00× |
| a component of 1000 on 100 entities each, per add | 162 B | 162 B | 1.00× |
| growth per hierarchy spawn / despawn cycle | 0 B | 0 B | — |
| an entity used in 4 inline queries, then deleted | 1 B | 1 B | 1.00× |
| Loop | mErCS 1.0.0 | mErCS 1.0.1 | ratio |
|---|---|---|---|
| Inline two-component query | 81 B | 80 B | 0.99× |
| Stored query | 0 B | 0 B | — |
| `world:each` | 152 B | 152 B | 1.00× |
