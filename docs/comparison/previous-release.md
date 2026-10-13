# mErCS 1.1.0 and 1.0.1

How mErCS 1.1.0 compares with the previous release, 1.0.1: on the reference workload that the
releases are accepted on, and on the matrix of single operations of the [jecs](jecs.md) page.
1.1.0 changes no behavior; it adds a method, `world:expect` (see the
[changelog](https://github.com/dubalda/mErCS/blob/main/CHANGELOG.md)), and changes no code that
these measurements run.

## The reference workload

The reference workload is the model of the work that the library is released against: P1-P9
at the small and the target scale, both retained-agent variants, the client and the buffers
profiles, in the interpreter and in native code (`tools/workload.py`, Luau 0.740, `-O2`). Each
build and its second run are a process of their own, five times in each mode; the noise of a row
is measured on the two runs of 1.0.1 alone. The
[release report](https://github.com/dubalda/mErCS/blob/main/bench/results/1.1.0.md) has all 232
rows with their ranges, and the raw samples.

- Time: no row is slower than the noise. Two rows are faster beyond it in native code at the
  target scale with retained agents that keep no owned entities: P2 with one stored query per
  system tag (0.93×) and P5, the messages of a frame on average (0.89×); 1.1.0 does not change
  the code that they run. The frame model and the lifecycle events stay within the noise.
- Memory: a world takes 1 131 bytes more (55 992 instead of 54 861 bytes), a constant per world:
  the closure of `world:expect`, and the hash part of the table of the world, which doubles with
  its 33rd field. Nothing per entity, pair or query, and nothing accumulates over the lifecycle
  rounds and the long sessions; one heap row of P8 is flagged for the constant (+2 KiB).

A frame of the model (P7, µs) and the heap it leaves per frame (P9, bytes), medians [min–max] of
both runs of each version:

| Mode | Scale | P7, µs/frame: 1.0.1 → 1.1.0 | P9, bytes/frame: 1.0.1 → 1.1.0 |
|---|---|---|---|
| native | small | 108.88 [101.65–125.30] → 105.90 [99.28–122.02] | 4266.7 [4078.9–4386.1] → 4266.7 [4078.9–4386.1] |
| native | target | 366.83 [349.42–466.06] → 359.42 [345.75–408.82] | 7321.6 [6502.4–7714.1] → 7321.6 [6502.4–7714.1] |
| native | small-empty-retained | 104.30 [102.02–119.51] → 107.23 [103.30–117.07] | 4437.3 [4249.6–4522.7] → 4437.3 [4266.7–4522.7] |
| native | target-empty-retained | 355.92 [333.93–415.20] → 342.58 [324.46–367.51] | 6126.9 [5734.4–6963.2] → 6126.9 [5751.5–6963.2] |
| interpreter | small | 172.42 [162.41–187.42] → 168.66 [159.70–195.57] | 4266.7 [4078.9–4386.1] → 4266.7 [4078.9–4403.2] |
| interpreter | target | 564.54 [520.22–827.88] → 531.89 [503.52–655.72] | 7321.6 [6502.4–7714.1] → 7321.6 [6502.4–7714.1] |
| interpreter | small-empty-retained | 165.47 [159.51–195.98] → 170.18 [156.58–185.36] | 4437.3 [4249.6–4522.7] → 4437.3 [4266.7–4522.7] |
| interpreter | target-empty-retained | 531.90 [486.56–616.10] → 527.34 [495.73–632.36] | 6126.9 [5734.4–6963.2] → 6126.9 [5751.5–6963.2] |

The lifecycle events at the target scale (P6, µs per event):

| Mode | P6 target, µs per event: 1.0.1 → 1.1.0 | |
|---|---|---|
| native | a new agent with its owned entities | 987.8 [949.0–1128.1] → 937.0 [897.4–1027.8] |
| native | the end of the activity of an agent | 56.7 [49.6–62.7] → 55.3 [50.9–58.8] |
| native | the removal of a retained agent (cascade) | 1108.9 [1055.0–1188.1] → 1095.4 [1069.3–1190.4] |
| native | the cascade of the removal of an agent, isolated | 268.5 [265.3–281.0] → 262.3 [252.3–275.5] |
| interpreter | a new agent with its owned entities | 1925.5 [1583.8–2225.8] → 1647.3 [1572.2–1849.2] |
| interpreter | the end of the activity of an agent | 95.9 [89.6–113.0] → 90.5 [86.1–111.2] |
| interpreter | the removal of a retained agent (cascade) | 1829.5 [1565.5–2006.5] → 1652.0 [1590.6–2008.9] |
| interpreter | the cascade of the removal of an agent, isolated | 466.6 [460.4–609.2] → 462.8 [455.0–484.8] |

The same at the small scale:

| Mode | P6 small, µs per event: 1.0.1 → 1.1.0 | |
|---|---|---|
| native | a new agent with its owned entities | 47.35 [44.05–56.45] → 45.78 [43.10–51.10] |
| native | the end of the activity of an agent | 3.65 [2.85–5.90] → 3.65 [2.90–4.75] |
| native | the removal of a retained agent (cascade) | 57.60 [50.15–75.45] → 53.95 [51.50–68.75] |
| native | the cascade of the removal of an agent, isolated | 10.35 [10.00–11.20] → 10.30 [10.00–10.50] |
| interpreter | a new agent with its owned entities | 73.17 [67.40–95.80] → 69.00 [65.95–79.85] |
| interpreter | the end of the activity of an agent | 5.78 [4.60–7.90] → 5.27 [4.00–7.70] |
| interpreter | the removal of a retained agent (cascade) | 89.55 [74.40–119.70] → 84.15 [72.30–105.65] |
| interpreter | the cascade of the removal of an agent, isolated | 17.30 [16.60–23.30] → 17.10 [16.50–28.50] |

The target world (P8):

| Mode | P8 target | 1.0.1 → 1.1.0 |
|---|---|---|
| native | the heap of the world after it is built | 137.63 [137.62–145.61] → 137.63 [137.62–145.61] |
| native | the heap after 100 lifecycle rounds | 138.57 [138.56–146.56] → 138.57 [138.56–146.56] |
| native | bytes per distinct pair (and its holder) | 1527.808 [1527.296–1529.344] → 1527.808 [1527.808–1529.344] |
| native | bytes per holder of a pair | 37.139 [37.139–37.395] → 37.139 [37.139–37.395] |
| interpreter | the heap of the world after it is built | 137.63 [137.62–145.61] → 137.63 [137.62–145.61] |
| interpreter | the heap after 100 lifecycle rounds | 138.57 [138.56–146.56] → 138.57 [138.56–146.56] |
| interpreter | bytes per distinct pair (and its holder) | 1527.808 [1527.296–1529.344] → 1527.808 [1527.808–1529.344] |
| interpreter | bytes per holder of a pair | 37.139 [37.139–37.395] → 37.139 [37.139–37.395] |

## Single operations

`bench/run.luau` and the probes of the [jecs](jecs.md#performance) page, measured in the same
runs as that page (mErCS 1.0.1 from its git tag): every library in a process of its own, five
times in each mode (fifteen for the synthetic frame), the order rotated; medians. Cells read
"interpreter / native"; the ratio is the time of 1.1.0 divided by that of 1.0.1, lower is better.
The [complete measurements](https://github.com/dubalda/mErCS/blob/main/bench/results/1.1.0-comparison.md)
include the ranges.

The median ratio of the 113 rows is 0.99× in both modes. 1.1.0 does not change the code of these
operations, and the rows that move beyond a few percent move both ways: in native code `get` of
one id (0.72×), `target` (0.79×) and a set of an existing value (0.84×) are faster in these runs,
and 15 cached queries over scattered entities (1.20×) and `query(A, pair(ChildOf, parent))` per
parent (1.24×) slower; in the interpreter a for-in over a sparse match is 1.19× and the first
loop of a new query 1.21×. The cost of an `OnRemove` hook on a delete is 184 / 106 ns in 1.0.1
and 174 / 109 ns in 1.1.0 (the probe of the [jecs](jecs.md#query-monitors) page).

### A synthetic game frame

| Mode / queries | mErCS 1.0.1 | mErCS 1.1.0 | ratio |
|---|---|---|---|
| interpreter, inline queries | 2.86 ms | 2.72 ms | 0.95× |
| interpreter, cached queries | 2.86 ms | 2.79 ms | 0.97× |
| native, inline queries | 1.97 ms | 1.95 ms | 0.99× |
| native, cached queries | 2.09 ms | 1.93 ms | 0.92× |

### A long session

| Mode | Frame | mErCS 1.0.1 | mErCS 1.1.0 | ratio |
|---|---|---|---|---|
| interpreter | 1000 | +0.33 MiB, 0.097 ms | +0.33 MiB, 0.097 ms | — |
| interpreter | 3000 | +0.33 MiB, 0.097 ms | +0.33 MiB, 0.097 ms | — |
| interpreter | 5000 | +0.32 MiB, 0.100 ms | +0.32 MiB, 0.099 ms | — |
| native | 1000 | +0.33 MiB, 0.065 ms | +0.33 MiB, 0.066 ms | — |
| native | 3000 | +0.33 MiB, 0.068 ms | +0.33 MiB, 0.065 ms | — |
| native | 5000 | +0.32 MiB, 0.067 ms | +0.32 MiB, 0.063 ms | — |

### Query cases

| Case | mErCS 1.0.1 | mErCS 1.1.0 | ratio |
|---|---|---|---|
| Scattered after recycling | 98.2 / 68.8 µs | 95.9 / 67.9 µs | 0.98× / 0.99× |
| Churn on a queried tag, 1 toggle per pass | 301 / 221 µs | 320 / 213 µs | 1.06× / 0.96× |
| Churn on a queried tag, 100 toggles per pass | 316 / 201 µs | 284 / 196 µs | 0.90× / 0.98× |
| Read 4 components | 1.41 ms / 704 µs | 1.37 ms / 691 µs | 0.97× / 0.98× |
| `(*, T)` with churn | 569 / 349 µs | 558 / 350 µs | 0.98× / 1.00× |
| Usually empty | 43.9 / 28.1 ns | 44 / 28.8 ns | 1.00× / 1.02× |

### A sparse world

| Pass | mErCS 1.0.1 | mErCS 1.1.0 | ratio | mErCS 1.0.1, pool | mErCS 1.1.0, pool | ratio, pool |
|---|---|---|---|---|---|---|
| Alive creatures, nothing changed | 5.82 / 4.3 µs | 5.82 / 4.44 µs | 1.00× / 1.03× | 7.08 / 4.16 µs | 7.48 / 4.16 µs | 1.06× / 1.00× |
| Alive creatures, `Dead` added to one and removed | 7.47 / 5.48 µs | 7.53 / 5.51 µs | 1.01× / 1.00× | 7.51 / 4.53 µs | 7.6 / 4.77 µs | 1.01× / 1.05× |
| Running creatures, `Run` toggled on one | 5.08 / 3.7 µs | 5.14 / 3.77 µs | 1.01× / 1.02× | 2.92 / 1.88 µs | 2.99 / 1.84 µs | 1.02× / 0.98× |
| A tag added to one creature, a pass, removed, a pass | 2.21 / 1.56 µs | 2.12 / 1.48 µs | 0.96× / 0.94× | 1.81 / 1.08 µs | 1.75 / 1.22 µs | 0.97× / 1.13× |
| A tag nobody has | 45.2 / 32.4 ns | 45.1 / 33.5 ns | 1.00× / 1.03× | 44.6 / 31.1 ns | 45.1 / 31.3 ns | 1.01× / 1.01× |
| All with `Model` (creatures and corpses) | 20.7 / 14.7 µs | 20 / 14.8 µs | 0.97× / 1.01× | 17.1 / 10.5 µs | 16 / 9.2 µs | 0.94× / 0.88× |
| A skill changes state, 10 queries over skills in `Cast` | 120 / 94.3 µs | 114 / 69.5 µs | 0.95× / 0.74× | 126 / 81.5 µs | 117 / 78.4 µs | 0.93× / 0.96× |

### State tags

| Frame of 1200 skills, 5 inline queries | mErCS 1.0.1 | mErCS 1.1.0 | ratio |
|---|---|---|---|
| 10 skills change state | 42.5 / 27.7 µs | 42.8 / 29.1 µs | 1.01× / 1.05× |
| 200 skills change state | 178 / 109 µs | 171 / 107 µs | 0.96× / 0.98× |
| 800 skills change state | 396 / 268 µs | 378 / 252 µs | 0.95× / 0.94× |

### The strengths of jecs

| # | Case | mErCS 1.0.1 | mErCS 1.1.0 | ratio |
|---|---|---|---|---|
| 1 | `(*, T)` values, 32 data relations, a pass over 20 000 | 569 / 329 µs | 573 / 320 µs | 1.01× / 0.97× |
| 2 | `(R, *)` values, 8 targets, a pass over 20 000 | 566 / 344 µs | 558 / 328 µs | 0.99× / 0.95× |
| 3 | 15 cached queries over scattered entities, per query | 822 / 337 µs | 746 / 405 µs | 0.91× / 1.20× |
|  | the same, memory per query | 263 KiB | 263 KiB | 1.00× |
| 4 | usually empty, 20 swaps per pass (100 000 entities) | 18.8 / 8.45 µs | 16.8 / 9.73 µs | 0.89× / 1.15× |
|  | 5 queries, 100 matches each, 40 toggles per frame | 36.5 / 23.5 µs | 42.8 / 19.7 µs | 1.17× / 0.84× |
| 5 | 20 small queries, a shared tag toggled on 30 per frame | 25.1 / 16.6 µs | 26.5 / 16 µs | 1.06× / 0.97× |
| 6 | `query(A, pair(ChildOf, parent))` per parent (1000 × 5) | 598 / 534 ns | 613 / 661 ns | 1.03× / 1.24× |
|  | 2 inline queries per new caster | 4.5 / 3.96 µs | 4.67 / 4.02 µs | 1.04× / 1.02× |
|  | the same, memory per caster | 376 B | 377 B | 1.00× |
| 7 | `world:each` over 100 000, per entity | 32.1 / 25.6 ns | 32.5 / 25.1 ns | 1.01× / 0.98× |
|  | `world:children`, 1000 children, per child | 34 / 27.4 ns | 35.2 / 26.9 ns | 1.04× / 0.98× |
| 8 | 8 kinds in turn, 3 values, for-in, per match | 95.3 / 99.1 ns | 93.5 / 81.3 ns | 0.98× / 0.82× |
|  | the same, `each` | 67.8 / 56 ns | 74.7 / 62.1 ns | 1.10× / 1.11× |
|  | the same, `each`, the kind from a slot pool | 38.6 / 22.1 ns | 38.6 / 21.7 ns | 1.00× / 0.98× |
| 9 | delete entities with 100 targets, per pair | 69.6 / 46.8 ns | 65.5 / 46.3 ns | 0.94× / 0.99× |
| 10 | 8 components on 1 entity in 64 of 131 072, memory per entity | 660 B | 661 B | 1.00× |
|  | the same, time per entity | 2.66 / 1.82 µs | 2.62 / 1.66 µs | 0.98× / 0.92× |

### Query monitors

| Case | mErCS 1.0.1 | mErCS 1.1.0 | ratio |
|---|---|---|---|
| a tag of the query added and removed, per cycle (an entry and an exit) | 851 / 575 ns | 821 / 570 ns | 0.97× / 0.99× |
| members of the query deleted, per entity | 705 / 403 ns | 680 / 403 ns | 0.96× / 1.00× |
| children moved to another parent, `(ChildOf, *)` monitored, per move | 774 / 457 ns | 755 / 452 ns | 0.98× / 0.99× |

#### Entities

| Scenario | mErCS 1.0.1 | mErCS 1.1.0 | ratio |
|---|---|---|---|
| create an entity | 46.4 / 35.1 ns | 46.1 / 31.5 ns | 0.99× / 0.90× |
| delete an entity with 4 components | 443 / 240 ns | 441 / 240 ns | 0.99× / 1.00× |

#### Components

| Scenario | mErCS 1.0.1 | mErCS 1.1.0 | ratio |
|---|---|---|---|
| add a first component | 190 / 129 ns | 189 / 119 ns | 0.99× / 0.92× |
| set an existing component | 68.7 / 44.9 ns | 62 / 37.5 ns | 0.90× / 0.84× |
| remove a component | 118 / 58.8 ns | 118 / 58.8 ns | 1.00× / 1.00× |
| add when the entity has 5 | 131 / 70.7 ns | 129 / 65.1 ns | 0.99× / 0.92× |
| remove when the entity has 6 | 115 / 59.2 ns | 116 / 59.8 ns | 1.01× / 1.01× |
| add when the entity has 20 | 134 / 70.6 ns | 128 / 62 ns | 0.96× / 0.88× |
| remove when the entity has 21 | 115 / 58.3 ns | 115 / 58.4 ns | 1.00× / 1.00× |
| add when the entity has 40 | 129 / 67.4 ns | 124 / 59.8 ns | 0.96× / 0.89× |
| remove when the entity has 41 | 116 / 58.1 ns | 118 / 58.7 ns | 1.02× / 1.01× |

#### Tags

| Scenario | mErCS 1.0.1 | mErCS 1.1.0 | ratio |
|---|---|---|---|
| add a tag | 97.7 / 54.1 ns | 99.4 / 53.1 ns | 1.02× / 0.98× |
| remove a tag | 112 / 63.1 ns | 111 / 63.4 ns | 0.99× / 1.01× |
| toggle a tag on 10 % of the entities per frame | 193 / 97 ns | 191 / 96.2 ns | 0.99× / 0.99× |

#### Access

| Scenario | mErCS 1.0.1 | mErCS 1.1.0 | ratio |
|---|---|---|---|
| `get` 1 id | 50.7 / 40.4 ns | 47.9 / 29.1 ns | 0.95× / 0.72× |
| `get` 2 ids | 62.1 / 43 ns | 59.9 / 34.7 ns | 0.96× / 0.81× |
| `get` 4 ids | 98.6 / 54 ns | 93.3 / 46.7 ns | 0.95× / 0.87× |
| `get` 8 ids (jecs: at most 4) | 232 / 124 ns | 251 / 115 ns | 1.08× / 0.93× |
| `has` 1 id | 52.9 / 33.6 ns | 53 / 33.9 ns | 1.00× / 1.01× |
| `has` 4 ids | 107 / 44.1 ns | 102 / 43.6 ns | 0.96× / 0.99× |
| `has` 8 ids (jecs: at most 4) | 192 / 72.7 ns | 190 / 73.6 ns | 0.99× / 1.01× |

#### Pairs

| Scenario | mErCS 1.0.1 | mErCS 1.1.0 | ratio |
|---|---|---|---|
| `pair(R, T)` | 20.9 / 8.89 ns | 21 / 9.13 ns | 1.00× / 1.03× |
| add a pair | 305 / 205 ns | 301 / 190 ns | 0.99× / 0.93× |
| set the value of an existing pair | 76.4 / 53.9 ns | 70.6 / 48.8 ns | 0.92× / 0.91× |
| remove a pair | 209 / 115 ns | 207 / 112 ns | 0.99× / 0.97× |
| `target` (4 pairs) | 67.9 / 47.1 ns | 63.5 / 37.2 ns | 0.94× / 0.79× |
| `ChildOf` children, per child (10 000 parents × 5) | 149 / 104 ns | 143 / 111 ns | 0.96× / 1.07× |
| add a pair with a target of its own | 3.49 / 3.12 µs | 3.52 / 3.23 µs | 1.01× / 1.04× |
| delete a target: `Remove` (1000 × 100 sources, per source) | 159 / 91.7 ns | 160 / 88.5 ns | 1.01× / 0.97× |
| delete a parent: `ChildOf` cascade (per child) | 412 / 241 ns | 410 / 246 ns | 1.00× / 1.02× |

#### Queries (per entity or match)

| Scenario | mErCS 1.0.1 | mErCS 1.1.0 | ratio |
|---|---|---|---|
| for-in, 4 values, 8192 entities per archetype | 51.1 / 34.3 ns | 49.6 / 34.7 ns | 0.97× / 1.01× |
| `query:each`, the same (ratio: against the jecs for-in) | 33.5 / 16.6 ns | 35.4 / 16.3 ns | 1.06× / 0.98× |
| manual loop (`spans` / jecs archetypes), the same | 14.5 / 5.28 ns | 14.4 / 5.12 ns | 1.00× / 0.97× |
| for-in, 4 values, 256 entities per archetype | 54.7 / 36.5 ns | 54.5 / 36.7 ns | 1.00× / 1.00× |
| `query:each`, the same (against the jecs for-in) | 36.5 / 18.9 ns | 36.9 / 18.3 ns | 1.01× / 0.97× |
| manual loop, the same | 18.9 / 6.87 ns | 18 / 6.8 ns | 0.95× / 0.99× |
| for-in, 4 values, 16 entities per archetype | 74.8 / 43.4 ns | 70.5 / 42.8 ns | 0.94× / 0.99× |
| `query:each`, the same (against the jecs for-in) | 50.8 / 21.9 ns | 51.2 / 22 ns | 1.01× / 1.00× |
| manual loop, the same | 35 / 10.2 ns | 32.7 / 9.99 ns | 0.94× / 0.98× |
| for-in, 4 values, 1 entity per archetype | 77.7 / 48.3 ns | 76.1 / 48.4 ns | 0.98× / 1.00× |
| `query:each`, the same (against the jecs for-in) | 57.4 / 27.3 ns | 57.5 / 27.9 ns | 1.00× / 1.02× |
| manual loop, the same | 38.9 / 14.8 ns | 38.1 / 15 ns | 0.98× / 1.02× |
| a query created and iterated once | 50.6 / 34.7 ns | 49.3 / 34.3 ns | 0.97× / 0.99× |
| for-in, 1 value of an entity with 4 | 38 / 29.5 ns | 38 / 29.5 ns | 1.00× / 1.00× |
| for-in with `without` (half excluded) | 38.4 / 32 ns | 40.4 / 34 ns | 1.05× / 1.06× |
| `query:each`, the same (against the jecs for-in) | 22.6 / 13.6 ns | 21.9 / 13.6 ns | 0.97× / 1.01× |
| for-in over a sparse match (1 %) | 68.2 / 58.5 ns | 81.3 / 62.2 ns | 1.19× / 1.06× |
| `query:each`, the same (against the jecs for-in) | 48.3 / 34.7 ns | 45.9 / 31.6 ns | 0.95× / 0.91× |
| the first loop of a new query (2000 archetypes), per query | 430 / 387 ns | 520 / 359 ns | 1.21× / 0.93× |
| a small query created on every call (15 of 1000), per query | 1.21 / 1.1 µs | 1.23 / 1.09 µs | 1.02× / 0.99× |
| a query of a concrete pair created on every call (15 of 1000), per query | 1.07 µs / 906 ns | 1.06 µs / 906 ns | 0.99× / 1.00× |
| the same, nothing matches (0 of 1000) | 181 / 158 ns | 171 / 153 ns | 0.95× / 0.97× |
| an entity used as a term in 4 inline queries, then deleted, per entity | 6.12 / 5.79 µs | 6.35 / 5.67 µs | 1.04× / 0.98× |
| a query with 10 terms | 104 / 61.5 ns | 103 / 60.8 ns | 0.99× / 0.99× |

#### Batch operations (per match; jecs: a collect-and-change loop)

| Scenario | mErCS 1.0.1 | mErCS 1.1.0 | ratio |
|---|---|---|---|
| add a tag to the matches (half of the entities) | 37.9 / 14 ns | 38.3 / 13.2 ns | 1.01× / 0.94× |
| set a component on the matches | 75.4 / 29 ns | 78 / 29.7 ns | 1.04× / 1.03× |
| remove a component from the matches | 39.5 / 13.9 ns | 39.8 / 13.1 ns | 1.01× / 0.94× |
| delete the matches | 494 / 275 ns | 490 / 249 ns | 0.99× / 0.91× |
| count the matches | 7.55 / 2.58 ns | 7.27 / 2.53 ns | 0.96× / 0.98× |

#### Churn (per cycle)

| Scenario | mErCS 1.0.1 | mErCS 1.1.0 | ratio |
|---|---|---|---|
| spawn and despawn (10 components, 2 tags) | 2.52 / 1.33 µs | 2.46 / 1.23 µs | 0.98× / 0.92× |
| a hierarchy of 1 + 5 `ChildOf`, spawned and deleted | 12.2 / 7.7 µs | 11.3 / 7.55 µs | 0.92× / 0.98× |

### Memory and garbage

| Kept per unit | mErCS 1.0.1 | mErCS 1.1.0 | ratio |
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
| Loop | mErCS 1.0.1 | mErCS 1.1.0 | ratio |
|---|---|---|---|
| Inline two-component query | 80 B | 80 B | 1.00× |
| Stored query | 0 B | 0 B | — |
| `world:each` | 152 B | 152 B | 1.00× |
