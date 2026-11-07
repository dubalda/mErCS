# mErCS 1.3.0 and 1.2.0

How mErCS 1.3.0 compares with the previous release, 1.2.0: on the reference workload that the
releases are accepted on, and on the matrix of single operations of the [jecs](jecs.md) page.
1.3.0 fixes the for-in loops of queries that pass over the bitsets when their body deletes
entities ahead of them (1.0.0–1.2.0 returned the mark of the free slot, and in a run of full
words did not end), at the cost of a comparison per returned entity, and gives `OnChange` hooks
and `changed` listeners the value that the change replaced (see the
[changelog](https://github.com/dubalda/mErCS/blob/main/CHANGELOG.md)). Roblox Studio and the
Roblox player were open on the machine during these measurements, which widens the noise of
every row.

## The reference workload

The reference workload is the model of the work that the library is released against: P1-P9
at the small and the target scale, both retained-agent variants, the client and the buffers
profiles, in the interpreter and in native code (`tools/workload.py`, Luau 0.740, `-O2`). Each
build and its second run are a process of their own, five times in each mode; the noise of a row
is measured on the two runs of 1.2.0 alone. The
[release report](https://github.com/dubalda/mErCS/blob/main/bench/results/1.3.0.md) has all 232
rows with their ranges, and the raw samples.

- Time: no row is slower than the noise. The release run flagged the stored queries at their
  periods (P4) at the target scale without owned entities in the interpreter (1.049×); P4 and the
  frame model (P7) were measured 15 more times at the four scales of the server in the
  interpreter, and with all repeats that row takes 1.041×, within the noise. These are the loops
  whose step 1.3.0 changes: in the interpreter P4 takes 1.025–1.041× and P7 1.015–1.025× of the
  time of 1.2.0, within the noise of each row; in native code the frame model takes 1.003–1.027×
  (1.014× at the target scale), and the client profile 1.00–1.03× in both modes.
- Memory: the same. A world takes 56 586 bytes in both versions, the target world 137.63 MB after
  it is built and 138.57 MB after 100 lifecycle rounds, a distinct pair 1 527.8 bytes with its
  holder, and nothing accumulates over the lifecycle rounds and the long sessions. One row of P8
  is flagged by its resolution of whole KiB: the bytes per distinct pair of the small scale in
  native code, one step of 1 KiB over its 594 pairs (+1.72 bytes; the same row moved one step
  down in the interpreter).

A frame of the model (P7, µs) and the heap it leaves per frame (P9, bytes), medians [min–max] of
both runs of each version:

| Mode | Scale | P7, µs/frame: 1.2.0 → 1.3.0 | P9, bytes/frame: 1.2.0 → 1.3.0 |
|---|---|---|---|
| native | small | 99.34 [97.25–101.30] → 102.03 [98.46–111.24] | 4266.7 [4078.9–4386.1] → 4266.7 [4078.9–4386.1] |
| native | target | 338.89 [331.14–342.11] → 343.71 [338.49–361.42] | 7321.6 [6502.4–7714.1] → 7321.6 [6502.4–7714.1] |
| native | small-empty-retained | 100.18 [96.29–104.14] → 101.16 [99.27–106.58] | 4437.3 [4266.7–4522.7] → 4437.3 [4266.7–4522.7] |
| native | target-empty-retained | 324.88 [316.72–383.50] → 325.89 [316.38–343.18] | 6126.9 [5751.5–6963.2] → 6126.9 [5751.5–6963.2] |
| interpreter | small | 158.06 [155.05–179.14] → 160.41 [156.68–182.35] | 4266.7 [4078.9–4386.1] → 4266.7 [4078.9–4386.1] |
| interpreter | target | 496.31 [485.18–529.37] → 508.52 [489.84–541.46] | 7321.6 [6502.4–7714.1] → 7321.6 [6502.4–7714.1] |
| interpreter | small-empty-retained | 157.12 [154.62–161.79] → 159.71 [155.88–229.24] | 4437.3 [4266.7–4522.7] → 4437.3 [4249.6–4522.7] |
| interpreter | target-empty-retained | 485.89 [474.93–509.91] → 496.10 [484.60–742.41] | 6126.9 [5751.5–6963.2] → 6126.9 [5751.5–6963.2] |

The lifecycle events at the target scale (P6, µs per event):

| Mode | P6 target, µs per event: 1.2.0 → 1.3.0 | |
|---|---|---|
| native | a new agent with its owned entities | 893.6 [880.3–965.2] → 904.4 [881.7–930.9] |
| native | the end of the activity of an agent | 52.8 [50.9–57.1] → 52.2 [51.3–54.2] |
| native | the removal of a retained agent (cascade) | 1042.7 [1020.8–1148.6] → 1048.6 [1029.7–1073.7] |
| native | the cascade of the removal of an agent, isolated | 263.0 [257.7–277.3] → 267.9 [256.1–273.2] |
| interpreter | a new agent with its owned entities | 1531.9 [1505.9–1601.4] → 1534.3 [1499.0–1565.0] |
| interpreter | the end of the activity of an agent | 87.6 [85.2–93.0] → 86.7 [85.9–90.7] |
| interpreter | the removal of a retained agent (cascade) | 1570.1 [1541.4–1648.4] → 1563.2 [1515.2–1646.0] |
| interpreter | the cascade of the removal of an agent, isolated | 444.0 [430.4–470.0] → 437.7 [422.7–446.0] |

The same at the small scale:

| Mode | P6 small, µs per event: 1.2.0 → 1.3.0 | |
|---|---|---|
| native | a new agent with its owned entities | 43.62 [42.55–48.00] → 44.12 [42.70–47.95] |
| native | the end of the activity of an agent | 2.93 [2.70–3.45] → 3.10 [2.80–3.65] |
| native | the removal of a retained agent (cascade) | 48.57 [44.00–56.45] → 52.15 [49.60–56.80] |
| native | the cascade of the removal of an agent, isolated | 10.10 [10.00–10.90] → 10.20 [10.00–12.10] |
| interpreter | a new agent with its owned entities | 66.10 [64.35–67.80] → 67.30 [63.50–68.95] |
| interpreter | the end of the activity of an agent | 4.20 [3.90–5.35] → 4.80 [3.70–5.85] |
| interpreter | the removal of a retained agent (cascade) | 73.25 [70.55–79.10] → 75.47 [67.70–82.65] |
| interpreter | the cascade of the removal of an agent, isolated | 16.85 [16.50–19.80] → 17.05 [16.20–23.50] |

The target world (P8):

| Mode | P8 target | 1.2.0 → 1.3.0 |
|---|---|---|
| native | the heap of the world after it is built | 137.63 [137.62–145.61] → 137.63 [137.62–145.61] |
| native | the heap after 100 lifecycle rounds | 138.57 [138.56–146.56] → 138.57 [138.56–146.56] |
| native | bytes per distinct pair (and its holder) | 1527.808 [1527.808–1528.832] → 1527.808 [1527.808–1528.832] |
| native | bytes per holder of a pair | 37.139 [36.882–37.395] → 37.139 [37.139–37.395] |
| interpreter | the heap of the world after it is built | 137.63 [137.62–145.61] → 137.63 [137.62–145.61] |
| interpreter | the heap after 100 lifecycle rounds | 138.57 [138.56–146.56] → 138.57 [138.56–146.56] |
| interpreter | bytes per distinct pair (and its holder) | 1527.808 [1527.808–1528.832] → 1528.320 [1527.808–1528.832] |
| interpreter | bytes per holder of a pair | 37.139 [36.882–37.395] → 37.139 [36.882–37.395] |

## Single operations

`bench/run.luau` and the probes of the [jecs](jecs.md#performance) page, measured in the same
runs as that page (mErCS 1.2.0 from its git tag): every library in a process of its own, fifteen
times in each mode for the matrix and the synthetic frame and five for the other profiles, the
order rotated; medians. Cells read "interpreter / native"; the ratio is the time of 1.3.0 divided
by that of 1.2.0, lower is better. The
[complete measurements](https://github.com/dubalda/mErCS/blob/main/bench/results/1.3.0-comparison.md)
include the ranges.

The median ratio of the 95 rows that have one is 1.00× in both modes. The for-in loops of
queries over dense matches pay the comparison per returned entity: a query of one value of an
entity with 4 takes 40.1 / 29.2 instead of 36.9 / 27.9 ns per match (1.09× / 1.05×), four values
over 8192, 256 and 16 entities per archetype 1.04–1.06× in the interpreter and 0.98–1.04× in
native code, a query created and iterated once 1.06× / 1.06×, a query with 10 terms 1.04× /
0.99×; `query:each` and the loops over a match list or a sparse match run the code of 1.2.0
(0.95–1.01×). The other rows that move beyond a few percent move both ways within their ranges
(`pair(R, T)` in native code, 0.86×). The cost of an `OnRemove` hook on a delete is 176 / 104 ns
in 1.2.0 and 172 / 108 ns in 1.3.0 (the probe of the [jecs](jecs.md#query-monitors) page).

### A synthetic game frame

| Mode / queries | mErCS 1.2.0 | mErCS 1.3.0 | ratio |
|---|---|---|---|
| interpreter, inline queries | 2.53 ms | 2.54 ms | 1.01× |
| interpreter, cached queries | 2.49 ms | 2.54 ms | 1.02× |
| native, inline queries | 1.74 ms | 1.76 ms | 1.01× |
| native, cached queries | 1.75 ms | 1.78 ms | 1.02× |

### A long session

| Mode | Frame | mErCS 1.2.0 | mErCS 1.3.0 | ratio |
|---|---|---|---|---|
| interpreter | 1000 | +0.33 MiB, 0.094 ms | +0.33 MiB, 0.094 ms | — |
| interpreter | 3000 | +0.32 MiB, 0.095 ms | +0.32 MiB, 0.094 ms | — |
| interpreter | 5000 | +0.32 MiB, 0.094 ms | +0.32 MiB, 0.093 ms | — |
| native | 1000 | +0.33 MiB, 0.062 ms | +0.33 MiB, 0.064 ms | — |
| native | 3000 | +0.32 MiB, 0.062 ms | +0.32 MiB, 0.062 ms | — |
| native | 5000 | +0.32 MiB, 0.063 ms | +0.32 MiB, 0.063 ms | — |

### Query cases

| Case | mErCS 1.2.0 | mErCS 1.3.0 | ratio |
|---|---|---|---|
| Scattered after recycling | 93.3 / 65.8 µs | 93 / 66.1 µs | 1.00× / 1.01× |
| Churn on a queried tag, 1 toggle per pass | 296 / 213 µs | 297 / 214 µs | 1.00× / 1.01× |
| Churn on a queried tag, 100 toggles per pass | 280 / 198 µs | 277 / 196 µs | 0.99× / 0.99× |
| Read 4 components | 1.34 ms / 678 µs | 1.35 ms / 679 µs | 1.00× / 1.00× |
| `(*, T)` with churn | 545 / 339 µs | 543 / 335 µs | 1.00× / 0.99× |
| Usually empty | 43.9 / 28.4 ns | 43.3 / 28.3 ns | 0.99× / 1.00× |

### A sparse world

| Pass | mErCS 1.2.0 | mErCS 1.3.0 | ratio | mErCS 1.2.0, pool | mErCS 1.3.0, pool | ratio, pool |
|---|---|---|---|---|---|---|
| Alive creatures, nothing changed | 5.75 / 4.31 µs | 5.76 / 4.31 µs | 1.00× / 1.00× | 6.93 / 4.11 µs | 6.94 / 4.16 µs | 1.00× / 1.01× |
| Alive creatures, `Dead` added to one and removed | 7.62 / 5.46 µs | 7.53 / 5.46 µs | 0.99× / 1.00× | 7.48 / 4.38 µs | 7.43 / 4.42 µs | 0.99× / 1.01× |
| Running creatures, `Run` toggled on one | 4.92 / 3.61 µs | 4.88 / 3.62 µs | 0.99× / 1.00× | 2.97 / 1.84 µs | 2.93 / 1.89 µs | 0.99× / 1.03× |
| A tag added to one creature, a pass, removed, a pass | 2.17 / 1.39 µs | 2.09 / 1.42 µs | 0.97× / 1.02× | 1.73 / 1.07 µs | 1.71 / 1.05 µs | 0.99× / 0.98× |
| A tag nobody has | 45.1 / 30.4 ns | 45.1 / 30.1 ns | 1.00× / 0.99× | 44.8 / 30.3 ns | 45.5 / 30.5 ns | 1.02× / 1.01× |
| All with `Model` (creatures and corpses) | 19.9 / 14.9 µs | 20 / 14.9 µs | 1.00× / 1.00× | 16 / 9.11 µs | 15.9 / 9.13 µs | 1.00× / 1.00× |
| A skill changes state, 10 queries over skills in `Cast` | 110 / 69.9 µs | 112 / 71.7 µs | 1.02× / 1.03× | 112 / 71.4 µs | 118 / 71.6 µs | 1.06× / 1.00× |

### State tags

| Frame of 1200 skills, 5 inline queries | mErCS 1.2.0 | mErCS 1.3.0 | ratio |
|---|---|---|---|
| 10 skills change state | 41.9 / 24.4 µs | 40.7 / 24.7 µs | 0.97× / 1.01× |
| 200 skills change state | 168 / 97.7 µs | 165 / 97.8 µs | 0.98× / 1.00× |
| 800 skills change state | 371 / 222 µs | 369 / 221 µs | 0.99× / 0.99× |

### The strengths of jecs

| # | Case | mErCS 1.2.0 | mErCS 1.3.0 | ratio |
|---|---|---|---|---|
| 1 | `(*, T)` values, 32 data relations, a pass over 20 000 | 559 / 319 µs | 552 / 318 µs | 0.99× / 1.00× |
| 2 | `(R, *)` values, 8 targets, a pass over 20 000 | 552 / 319 µs | 546 / 317 µs | 0.99× / 1.00× |
| 3 | 15 cached queries over scattered entities, per query | 740 / 329 µs | 754 / 334 µs | 1.02× / 1.01× |
|  | the same, memory per query | 263 KiB | 263 KiB | 1.00× |
| 4 | usually empty, 20 swaps per pass (100 000 entities) | 13.7 / 8.12 µs | 14.1 / 7.62 µs | 1.03× / 0.94× |
|  | 5 queries, 100 matches each, 40 toggles per frame | 32.9 / 17.6 µs | 33.6 / 17.8 µs | 1.02× / 1.01× |
| 5 | 20 small queries, a shared tag toggled on 30 per frame | 23.2 / 14.8 µs | 22.7 / 14.9 µs | 0.98× / 1.01× |
| 6 | `query(A, pair(ChildOf, parent))` per parent (1000 × 5) | 590 / 488 ns | 594 / 498 ns | 1.01× / 1.02× |
|  | 2 inline queries per new caster | 4.37 / 3.73 µs | 4.43 / 3.74 µs | 1.01× / 1.00× |
|  | the same, memory per caster | 377 B | 377 B | 1.00× |
| 7 | `world:each` over 100 000, per entity | 31.6 / 25.2 ns | 31.7 / 24.8 ns | 1.00× / 0.98× |
|  | `world:children`, 1000 children, per child | 32.9 / 26.3 ns | 32.9 / 25.8 ns | 1.00× / 0.98× |
| 8 | 8 kinds in turn, 3 values, for-in, per match | 90.4 / 85 ns | 87.7 / 83 ns | 0.97× / 0.98× |
|  | the same, `each` | 66.8 / 54.3 ns | 64.8 / 54.7 ns | 0.97× / 1.01× |
|  | the same, `each`, the kind from a slot pool | 36.9 / 21.6 ns | 37.3 / 21.2 ns | 1.01× / 0.98× |
| 9 | delete entities with 100 targets, per pair | 64.8 / 46.4 ns | 64.8 / 46.4 ns | 1.00× / 1.00× |
| 10 | 8 components on 1 entity in 64 of 131 072, memory per entity | 661 B | 661 B | 1.00× |
|  | the same, time per entity | 2.49 / 1.58 µs | 2.49 / 1.56 µs | 1.00× / 0.99× |

### Query monitors

| Case | mErCS 1.2.0 | mErCS 1.3.0 | ratio |
|---|---|---|---|
| a tag of the query added and removed, per cycle (an entry and an exit) | 803 / 540 ns | 803 / 541 ns | 1.00× / 1.00× |
| members of the query deleted, per entity | 671 / 398 ns | 675 / 395 ns | 1.01× / 0.99× |
| children moved to another parent, `(ChildOf, *)` monitored, per move | 743 / 453 ns | 738 / 453 ns | 0.99× / 1.00× |

#### Entities

| Scenario | mErCS 1.2.0 | mErCS 1.3.0 | ratio |
|---|---|---|---|
| create an entity | 43.6 / 28.6 ns | 43.3 / 28.6 ns | 0.99× / 1.00× |
| delete an entity with 4 components | 455 / 240 ns | 451 / 240 ns | 0.99× / 1.00× |

#### Components

| Scenario | mErCS 1.2.0 | mErCS 1.3.0 | ratio |
|---|---|---|---|
| add a first component | 177 / 109 ns | 172 / 109 ns | 0.97× / 1.00× |
| set an existing component | 61.4 / 36.7 ns | 61.8 / 36.7 ns | 1.01× / 1.00× |
| remove a component | 118 / 59.5 ns | 118 / 59.7 ns | 1.00× / 1.00× |
| add when the entity has 5 | 128 / 62.2 ns | 127 / 61.8 ns | 0.99× / 0.99× |
| remove when the entity has 6 | 115 / 58.6 ns | 116 / 59 ns | 1.01× / 1.01× |
| add when the entity has 20 | 124 / 61.9 ns | 125 / 63.1 ns | 1.00× / 1.02× |
| remove when the entity has 21 | 115 / 59.3 ns | 116 / 59.4 ns | 1.01× / 1.00× |
| add when the entity has 40 | 123 / 59.4 ns | 123 / 60.2 ns | 1.00× / 1.01× |
| remove when the entity has 41 | 116 / 59.1 ns | 116 / 58.9 ns | 1.01× / 1.00× |

#### Tags

| Scenario | mErCS 1.2.0 | mErCS 1.3.0 | ratio |
|---|---|---|---|
| add a tag | 95.2 / 52.7 ns | 95 / 52.7 ns | 1.00× / 1.00× |
| remove a tag | 108 / 64.1 ns | 109 / 64.2 ns | 1.00× / 1.00× |
| toggle a tag on 10 % of the entities per frame | 176 / 95.5 ns | 178 / 96.4 ns | 1.01× / 1.01× |

#### Access

| Scenario | mErCS 1.2.0 | mErCS 1.3.0 | ratio |
|---|---|---|---|
| `get` 1 id | 47 / 28 ns | 47.1 / 28.2 ns | 1.00× / 1.01× |
| `get` 2 ids | 58.7 / 33.7 ns | 59.1 / 33.7 ns | 1.01× / 1.00× |
| `get` 4 ids | 89.1 / 45.8 ns | 89.7 / 44.9 ns | 1.01× / 0.98× |
| `get` 8 ids (jecs: at most 4) | 243 / 112 ns | 244 / 112 ns | 1.00× / 1.00× |
| `has` 1 id | 51.1 / 31.8 ns | 51.4 / 31.7 ns | 1.01× / 1.00× |
| `has` 4 ids | 102 / 44.3 ns | 101 / 44.9 ns | 0.99× / 1.01× |
| `has` 8 ids (jecs: at most 4) | 186 / 72.6 ns | 186 / 72.5 ns | 1.00× / 1.00× |

#### Pairs

| Scenario | mErCS 1.2.0 | mErCS 1.3.0 | ratio |
|---|---|---|---|
| `pair(R, T)` | 23.1 / 10.4 ns | 22.9 / 8.95 ns | 0.99× / 0.86× |
| add a pair | 275 / 171 ns | 278 / 172 ns | 1.01× / 1.00× |
| set the value of an existing pair | 68.3 / 45.7 ns | 68.3 / 45.3 ns | 1.00× / 0.99× |
| remove a pair | 200 / 112 ns | 201 / 112 ns | 1.00× / 1.00× |
| `target` (4 pairs) | 63.1 / 36.6 ns | 62.6 / 36.1 ns | 0.99× / 0.98× |
| `ChildOf` children, per child (10 000 parents × 5) | 140 / 104 ns | 140 / 101 ns | 1.00× / 0.98× |
| add a pair with a target of its own | 3.17 / 2.84 µs | 3.16 / 2.85 µs | 1.00× / 1.00× |
| delete a target: `Remove` (1000 × 100 sources, per source) | 156 / 82.5 ns | 154 / 83.2 ns | 0.99× / 1.01× |
| delete a parent: `ChildOf` cascade (per child) | 407 / 240 ns | 401 / 238 ns | 0.98× / 0.99× |

#### Queries (per entity or match)

| Scenario | mErCS 1.2.0 | mErCS 1.3.0 | ratio |
|---|---|---|---|
| for-in, 4 values, 8192 entities per archetype | 48.2 / 33.7 ns | 51.1 / 35.2 ns | 1.06× / 1.04× |
| `query:each`, the same (ratio: against the jecs for-in) | 32.3 / 16 ns | 32.1 / 16.1 ns | 0.99× / 1.01× |
| manual loop (`spans` / jecs archetypes), the same | 14.2 / 5.23 ns | 14.2 / 5.12 ns | 1.00× / 0.98× |
| for-in, 4 values, 256 entities per archetype | 52.1 / 35.8 ns | 54.5 / 36.7 ns | 1.05× / 1.03× |
| `query:each`, the same (against the jecs for-in) | 35.5 / 17.7 ns | 35.3 / 17.6 ns | 1.00× / 1.00× |
| manual loop, the same | 17.6 / 6.57 ns | 17.4 / 6.51 ns | 0.99× / 0.99× |
| for-in, 4 values, 16 entities per archetype | 68.1 / 42.5 ns | 70.8 / 41.9 ns | 1.04× / 0.98× |
| `query:each`, the same (against the jecs for-in) | 49.7 / 21.4 ns | 49.2 / 21.5 ns | 0.99× / 1.00× |
| manual loop, the same | 32 / 9.79 ns | 32 / 9.88 ns | 1.00× / 1.01× |
| for-in, 4 values, 1 entity per archetype | 74.3 / 47 ns | 76.6 / 46.1 ns | 1.03× / 0.98× |
| `query:each`, the same (against the jecs for-in) | 53.9 / 26.4 ns | 54.3 / 26.6 ns | 1.01× / 1.00× |
| manual loop, the same | 37.4 / 14.6 ns | 37.5 / 14.5 ns | 1.00× / 0.99× |
| a query created and iterated once | 48.8 / 33.8 ns | 51.8 / 35.8 ns | 1.06× / 1.06× |
| for-in, 1 value of an entity with 4 | 36.9 / 27.9 ns | 40.1 / 29.2 ns | 1.09× / 1.05× |
| for-in with `without` (half excluded) | 37.3 / 31.2 ns | 37.4 / 30.9 ns | 1.00× / 0.99× |
| `query:each`, the same (against the jecs for-in) | 22.1 / 13.3 ns | 22 / 13.2 ns | 0.99× / 1.00× |
| for-in over a sparse match (1 %) | 69 / 58.5 ns | 65.9 / 57.3 ns | 0.95× / 0.98× |
| `query:each`, the same (against the jecs for-in) | 45.2 / 31.1 ns | 45 / 30.8 ns | 0.99× / 0.99× |
| the first loop of a new query (2000 archetypes), per query | 430 / 338 ns | 421 / 339 ns | 0.98× / 1.00× |
| a small query created on every call (15 of 1000), per query | 1.2 / 1.07 µs | 1.21 / 1.06 µs | 1.00× / 1.00× |
| a query of a concrete pair created on every call (15 of 1000), per query | 1.05 µs / 890 ns | 1.05 µs / 881 ns | 1.00× / 0.99× |
| the same, nothing matches (0 of 1000) | 172 / 149 ns | 169 / 149 ns | 0.99× / 1.00× |
| an entity used as a term in 4 inline queries, then deleted, per entity | 5.87 / 5.21 µs | 5.82 / 5.27 µs | 0.99× / 1.01× |
| a query with 10 terms | 98.3 / 61.4 ns | 103 / 60.6 ns | 1.04× / 0.99× |

#### Batch operations (per match; jecs: a collect-and-change loop)

| Scenario | mErCS 1.2.0 | mErCS 1.3.0 | ratio |
|---|---|---|---|
| add a tag to the matches (half of the entities) | 37.1 / 13.4 ns | 37.7 / 13.5 ns | 1.01× / 1.01× |
| set a component on the matches | 72.5 / 27.3 ns | 72.2 / 27.5 ns | 1.00× / 1.01× |
| remove a component from the matches | 39.4 / 12.9 ns | 38.6 / 12.8 ns | 0.98× / 0.99× |
| delete the matches | 482 / 251 ns | 487 / 246 ns | 1.01× / 0.98× |
| count the matches | 7.18 / 2.52 ns | 7.16 / 2.49 ns | 1.00× / 0.99× |

#### Churn (per cycle)

| Scenario | mErCS 1.2.0 | mErCS 1.3.0 | ratio |
|---|---|---|---|
| spawn and despawn (10 components, 2 tags) | 2.4 / 1.21 µs | 2.43 / 1.19 µs | 1.01× / 0.98× |
| a hierarchy of 1 + 5 `ChildOf`, spawned and deleted | 10.9 / 7.29 µs | 11 / 7.31 µs | 1.01× / 1.00× |

### Memory and garbage

| Kept per unit | mErCS 1.2.0 | mErCS 1.3.0 | ratio |
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
| Loop | mErCS 1.2.0 | mErCS 1.3.0 | ratio |
|---|---|---|---|
| Inline two-component query | 80 B | 80 B | 1.00× |
| Stored query | 0 B | 0 B | — |
| `world:each` | 152 B | 152 B | 1.00× |
