# mErCS 1.2.0 and 1.1.0

How mErCS 1.2.0 compares with the previous release, 1.1.0: on the reference workload that the
releases are accepted on, and on the matrix of single operations of the [jecs](jecs.md) page.
1.2.0 changes the errors: a debug world checks the arguments of every call and names the wrong
one, a change filter of an id that is not tracked raises its error at every use, `ecs.pair`
refuses a nil element, and every error raised for a mistake of the caller points at the line of
the call (see the [changelog](https://github.com/dubalda/mErCS/blob/main/CHANGELOG.md)). In the
code that these measurements run it changes only the paths that raise errors, which they do not
take, and adds the test of nil of `ecs.pair`.

## The reference workload

The reference workload is the model of the work that the library is released against: P1-P9
at the small and the target scale, both retained-agent variants, the client and the buffers
profiles, in the interpreter and in native code (`tools/workload.py`, Luau 0.740, `-O2`). Each
build and its second run are a process of their own, five times in each mode; the noise of a row
is measured on the two runs of 1.1.0 alone. The
[release report](https://github.com/dubalda/mErCS/blob/main/bench/results/1.2.0.md) has all 232
rows with their ranges, and the raw samples.

- Time: no row is slower than the noise. The release run flagged two rows of the client profile
  in the interpreter, which 15 more repeats put within the noise: the 15 usually empty marker
  queries of P4 (1.03× at first and with all repeats) and the client frame of P7 (1.05×, then
  1.01×). P6 and P7 at the target scale were measured 15 more times in both modes as well, their
  columns having split between two levels of time in both versions: with all repeats the frame
  of the model takes 0.99× of the time of 1.1.0 in native code. In the interpreter the lifecycle
  events at the target scale stay within the noise at 1.02–1.04× with all repeats; 10 more
  processes of each version, side by side, give 1.00–1.01×.
- Memory: a world takes 589 bytes more (56 586 instead of 55 997 bytes), a constant per world:
  the closures of the world that raise errors keep the function that raises them as an upvalue,
  and the one that takes the ticks of the change filters keeps the function that checks their
  ids. Nothing per entity, pair or query, and nothing accumulates over the lifecycle rounds and
  the long sessions. Three rows of P8 are flagged by its resolution of whole KiB: two heap rows
  at +2 KiB, and the bytes per distinct pair of the small scale in the interpreter, one step of
  1 KiB over its 594 pairs (+1.72 bytes; the scale without owned entities moved one step down).

A frame of the model (P7, µs) and the heap it leaves per frame (P9, bytes), medians [min–max] of
both runs of each version:

| Mode | Scale | P7, µs/frame: 1.1.0 → 1.2.0 | P9, bytes/frame: 1.1.0 → 1.2.0 |
|---|---|---|---|
| native | small | 101.26 [93.07–113.86] → 97.30 [92.27–113.36] | 4266.7 [4078.9–4386.1] → 4266.7 [4078.9–4386.1] |
| native | target | 358.23 [313.90–428.92] → 355.60 [326.02–518.40] | 7321.6 [6502.4–7714.1] → 7321.6 [6502.4–7714.1] |
| native | small-empty-retained | 104.37 [91.59–142.23] → 97.09 [92.08–121.39] | 4437.3 [4266.7–4522.7] → 4437.3 [4266.7–4522.7] |
| native | target-empty-retained | 321.44 [311.49–388.56] → 325.70 [305.53–412.91] | 6126.9 [5751.5–6963.2] → 6126.9 [5751.5–6963.2] |
| interpreter | small | 154.41 [147.00–180.29] → 158.73 [147.39–173.52] | 4266.7 [4078.9–4403.2] → 4266.7 [4078.9–4386.1] |
| interpreter | target | 491.59 [464.84–830.87] → 510.14 [465.45–656.87] | 7321.6 [6502.4–7714.1] → 7321.6 [6502.4–7714.1] |
| interpreter | small-empty-retained | 160.07 [151.65–215.78] → 156.85 [149.44–174.69] | 4437.3 [4266.7–4522.7] → 4437.3 [4266.7–4522.7] |
| interpreter | target-empty-retained | 506.51 [473.74–546.77] → 490.06 [468.67–537.55] | 6126.9 [5751.5–6963.2] → 6126.9 [5751.5–6963.2] |

The lifecycle events at the target scale (P6, µs per event):

| Mode | P6 target, µs per event: 1.1.0 → 1.2.0 | |
|---|---|---|
| native | a new agent with its owned entities | 922.0 [857.1–1078.8] → 908.2 [862.0–1506.0] |
| native | the end of the activity of an agent | 53.5 [49.7–60.7] → 52.9 [48.2–83.6] |
| native | the removal of a retained agent (cascade) | 1051.8 [971.4–1205.2] → 1034.6 [955.4–1566.1] |
| native | the cascade of the removal of an agent, isolated | 257.5 [244.8–397.5] → 263.6 [249.5–321.3] |
| interpreter | a new agent with its owned entities | 1500.7 [1470.9–2280.9] → 1558.9 [1475.0–2052.4] |
| interpreter | the end of the activity of an agent | 85.0 [81.0–119.7] → 88.7 [80.4–138.9] |
| interpreter | the removal of a retained agent (cascade) | 1503.1 [1446.0–2165.8] → 1566.2 [1444.1–1997.1] |
| interpreter | the cascade of the removal of an agent, isolated | 432.4 [413.3–647.4] → 439.0 [420.0–631.7] |

The same at the small scale:

| Mode | P6 small, µs per event: 1.1.0 → 1.2.0 | |
|---|---|---|
| native | a new agent with its owned entities | 43.75 [40.95–52.90] → 44.35 [41.40–52.45] |
| native | the end of the activity of an agent | 3.03 [2.30–5.30] → 3.30 [2.30–5.55] |
| native | the removal of a retained agent (cascade) | 49.43 [40.45–71.00] → 54.58 [43.75–70.45] |
| native | the cascade of the removal of an agent, isolated | 10.15 [9.80–13.00] → 10.00 [9.60–10.70] |
| interpreter | a new agent with its owned entities | 64.48 [61.80–80.60] → 66.45 [62.25–74.30] |
| interpreter | the end of the activity of an agent | 4.15 [3.40–7.70] → 5.10 [3.65–6.60] |
| interpreter | the removal of a retained agent (cascade) | 71.95 [61.95–101.85] → 76.72 [64.40–97.10] |
| interpreter | the cascade of the removal of an agent, isolated | 16.50 [15.30–19.30] → 16.55 [16.00–17.50] |

The target world (P8):

| Mode | P8 target | 1.1.0 → 1.2.0 |
|---|---|---|
| native | the heap of the world after it is built | 137.63 [137.62–145.61] → 137.63 [137.62–145.61] |
| native | the heap after 100 lifecycle rounds | 138.57 [138.56–146.56] → 138.57 [138.56–146.56] |
| native | bytes per distinct pair (and its holder) | 1527.808 [1527.808–1529.344] → 1527.808 [1527.808–1528.832] |
| native | bytes per holder of a pair | 37.139 [37.139–37.395] → 37.139 [36.882–37.395] |
| interpreter | the heap of the world after it is built | 137.63 [137.62–145.61] → 137.63 [137.62–145.61] |
| interpreter | the heap after 100 lifecycle rounds | 138.57 [138.56–146.56] → 138.57 [138.56–146.56] |
| interpreter | bytes per distinct pair (and its holder) | 1527.808 [1527.808–1529.344] → 1527.808 [1527.808–1528.832] |
| interpreter | bytes per holder of a pair | 37.139 [37.139–37.395] → 37.139 [36.882–37.395] |

## Single operations

`bench/run.luau` and the probes of the [jecs](jecs.md#performance) page, measured in the same
runs as that page (mErCS 1.1.0 from its git tag): every library in a process of its own, fifteen
times in each mode for the matrix and the synthetic frame and five for the other profiles, the
order rotated; medians. Cells read "interpreter / native"; the ratio is the time of 1.2.0 divided
by that of 1.1.0, lower is better. The
[complete measurements](https://github.com/dubalda/mErCS/blob/main/bench/results/1.2.0-comparison.md)
include the ranges.

The median ratio of the 99 rows that have one is 1.00× in both modes. `pair(R, T)` pays the test
of nil of `ecs.pair`: 22.7 instead of 20.8 ns in the interpreter (1.09×; the fastest process
22.0 instead of 19.4 ns); in native code its 9.67 against 8.73 ns (1.11×) lie within the range of
the row, 8.41–11.3 ns, and the two modules side by side take 12.7 ns per call each, loop
included. The other rows that move beyond a few percent move both ways within their ranges: in
the interpreter a usually empty query with 20 swaps per pass (1.30×, 12.2–23.0 µs in 1.1.0 and
12.4–25.1 µs in 1.2.0) and `query(A, pair(ChildOf, parent))` per parent (1.11×, 544–764 ns
against 547–892 ns, of which the test of nil of its pair is about 2 ns); the synthetic frame
takes 0.91–1.06× of the time of 1.1.0 by its median frame and 0.99–1.00× by its fastest one. The cost of an `OnRemove`
hook on a delete is 180 / 112 ns in 1.1.0 and 178 / 102 ns in 1.2.0 (the probe of the
[jecs](jecs.md#query-monitors) page).

### A synthetic game frame

| Mode / queries | mErCS 1.1.0 | mErCS 1.2.0 | ratio |
|---|---|---|---|
| interpreter, inline queries | 2.33 ms | 2.47 ms | 1.06× |
| interpreter, cached queries | 2.42 ms | 2.41 ms | 0.99× |
| native, inline queries | 1.71 ms | 1.61 ms | 0.94× |
| native, cached queries | 1.81 ms | 1.64 ms | 0.91× |

### A long session

| Mode | Frame | mErCS 1.1.0 | mErCS 1.2.0 | ratio |
|---|---|---|---|---|
| interpreter | 1000 | +0.33 MiB, 0.092 ms | +0.33 MiB, 0.099 ms | — |
| interpreter | 3000 | +0.33 MiB, 0.093 ms | +0.32 MiB, 0.097 ms | — |
| interpreter | 5000 | +0.32 MiB, 0.093 ms | +0.32 MiB, 0.094 ms | — |
| native | 1000 | +0.33 MiB, 0.064 ms | +0.33 MiB, 0.063 ms | — |
| native | 3000 | +0.33 MiB, 0.060 ms | +0.32 MiB, 0.061 ms | — |
| native | 5000 | +0.32 MiB, 0.059 ms | +0.32 MiB, 0.066 ms | — |

### Query cases

| Case | mErCS 1.1.0 | mErCS 1.2.0 | ratio |
|---|---|---|---|
| Scattered after recycling | 94.2 / 65.8 µs | 91.8 / 62.8 µs | 0.97× / 0.95× |
| Churn on a queried tag, 1 toggle per pass | 286 / 209 µs | 293 / 211 µs | 1.02× / 1.01× |
| Churn on a queried tag, 100 toggles per pass | 271 / 193 µs | 267 / 194 µs | 0.99× / 1.01× |
| Read 4 components | 1.33 ms / 672 µs | 1.33 ms / 672 µs | 0.99× / 1.00× |
| `(*, T)` with churn | 538 / 337 µs | 541 / 341 µs | 1.01× / 1.01× |
| Usually empty | 42.5 / 27.4 ns | 42.5 / 26.9 ns | 1.00× / 0.98× |

### A sparse world

| Pass | mErCS 1.1.0 | mErCS 1.2.0 | ratio | mErCS 1.1.0, pool | mErCS 1.2.0, pool | ratio, pool |
|---|---|---|---|---|---|---|
| Alive creatures, nothing changed | 5.6 / 4.02 µs | 5.53 / 4.11 µs | 0.99× / 1.02× | 6.77 / 4.02 µs | 6.57 / 3.9 µs | 0.97× / 0.97× |
| Alive creatures, `Dead` added to one and removed | 7.33 / 5.26 µs | 7.31 / 5.21 µs | 1.00× / 0.99× | 7.37 / 4.31 µs | 7.23 / 4.2 µs | 0.98× / 0.97× |
| Running creatures, `Run` toggled on one | 4.84 / 3.48 µs | 4.73 / 3.49 µs | 0.98× / 1.00× | 2.89 / 1.8 µs | 2.86 / 1.78 µs | 0.99× / 0.99× |
| A tag added to one creature, a pass, removed, a pass | 2.04 / 1.38 µs | 2.11 / 1.33 µs | 1.03× / 0.97× | 1.74 / 1.03 µs | 1.7 / 1.01 µs | 0.98× / 0.98× |
| A tag nobody has | 44 / 29.9 ns | 43.6 / 29.8 ns | 0.99× / 1.00× | 43.4 / 29.6 ns | 42.6 / 30.5 ns | 0.98× / 1.03× |
| All with `Model` (creatures and corpses) | 19.4 / 13.9 µs | 19.5 / 14.1 µs | 1.00× / 1.01× | 15.6 / 8.98 µs | 15.6 / 8.7 µs | 1.00× / 0.97× |
| A skill changes state, 10 queries over skills in `Cast` | 114 / 67.7 µs | 109 / 66.5 µs | 0.96× / 0.98× | 112 / 71.8 µs | 111 / 70.3 µs | 1.00× / 0.98× |

### State tags

| Frame of 1200 skills, 5 inline queries | mErCS 1.1.0 | mErCS 1.2.0 | ratio |
|---|---|---|---|
| 10 skills change state | 40.1 / 24.7 µs | 41.8 / 24.1 µs | 1.04× / 0.98× |
| 200 skills change state | 171 / 97 µs | 166 / 95.6 µs | 0.97× / 0.99× |
| 800 skills change state | 374 / 218 µs | 367 / 218 µs | 0.98× / 1.00× |

### The strengths of jecs

| # | Case | mErCS 1.1.0 | mErCS 1.2.0 | ratio |
|---|---|---|---|---|
| 1 | `(*, T)` values, 32 data relations, a pass over 20 000 | 562 / 316 µs | 553 / 317 µs | 0.98× / 1.00× |
| 2 | `(R, *)` values, 8 targets, a pass over 20 000 | 551 / 323 µs | 556 / 316 µs | 1.01× / 0.98× |
| 3 | 15 cached queries over scattered entities, per query | 728 / 318 µs | 730 / 317 µs | 1.00× / 1.00× |
|  | the same, memory per query | 263 KiB | 263 KiB | 1.00× |
| 4 | usually empty, 20 swaps per pass (100 000 entities) | 13 / 7.51 µs | 16.9 / 7.47 µs | 1.30× / 1.00× |
|  | 5 queries, 100 matches each, 40 toggles per frame | 32.2 / 17.5 µs | 33.9 / 17.8 µs | 1.06× / 1.02× |
| 5 | 20 small queries, a shared tag toggled on 30 per frame | 22.8 / 14.6 µs | 22.2 / 14.9 µs | 0.97× / 1.02× |
| 6 | `query(A, pair(ChildOf, parent))` per parent (1000 × 5) | 572 / 484 ns | 634 / 504 ns | 1.11× / 1.04× |
|  | 2 inline queries per new caster | 4.34 / 3.69 µs | 4.29 / 3.63 µs | 0.99× / 0.98× |
|  | the same, memory per caster | 377 B | 377 B | 1.00× |
| 7 | `world:each` over 100 000, per entity | 32 / 24.7 ns | 31.9 / 25.1 ns | 1.00× / 1.02× |
|  | `world:children`, 1000 children, per child | 32.5 / 26 ns | 33.1 / 26 ns | 1.02× / 1.00× |
| 8 | 8 kinds in turn, 3 values, for-in, per match | 85.9 / 78.8 ns | 89.4 / 77 ns | 1.04× / 0.98× |
|  | the same, `each` | 64.4 / 51.6 ns | 61.5 / 50.8 ns | 0.95× / 0.98× |
|  | the same, `each`, the kind from a slot pool | 35.6 / 20.2 ns | 35.8 / 20 ns | 1.01× / 0.99× |
| 9 | delete entities with 100 targets, per pair | 61.5 / 44.7 ns | 62 / 44.5 ns | 1.01× / 0.99× |
| 10 | 8 components on 1 entity in 64 of 131 072, memory per entity | 661 B | 661 B | 1.00× |
|  | the same, time per entity | 2.38 / 1.57 µs | 2.41 / 1.55 µs | 1.01× / 0.99× |

### Query monitors

| Case | mErCS 1.1.0 | mErCS 1.2.0 | ratio |
|---|---|---|---|
| a tag of the query added and removed, per cycle (an entry and an exit) | 798 / 541 ns | 794 / 536 ns | 0.99× / 0.99× |
| members of the query deleted, per entity | 654 / 388 ns | 660 / 392 ns | 1.01× / 1.01× |
| children moved to another parent, `(ChildOf, *)` monitored, per move | 728 / 441 ns | 724 / 448 ns | 0.99× / 1.02× |

#### Entities

| Scenario | mErCS 1.1.0 | mErCS 1.2.0 | ratio |
|---|---|---|---|
| create an entity | 41.7 / 27.7 ns | 42.6 / 28.4 ns | 1.02× / 1.03× |
| delete an entity with 4 components | 432 / 234 ns | 441 / 232 ns | 1.02× / 0.99× |

#### Components

| Scenario | mErCS 1.1.0 | mErCS 1.2.0 | ratio |
|---|---|---|---|
| add a first component | 173 / 107 ns | 178 / 111 ns | 1.03× / 1.03× |
| set an existing component | 60.2 / 36 ns | 60.7 / 36.7 ns | 1.01× / 1.02× |
| remove a component | 115 / 58 ns | 116 / 58.5 ns | 1.00× / 1.01× |
| add when the entity has 5 | 122 / 61.3 ns | 122 / 61.5 ns | 1.00× / 1.00× |
| remove when the entity has 6 | 113 / 56.5 ns | 111 / 57.1 ns | 0.98× / 1.01× |
| add when the entity has 20 | 122 / 58.3 ns | 119 / 60.8 ns | 0.98× / 1.04× |
| remove when the entity has 21 | 109 / 55.4 ns | 109 / 55.8 ns | 1.00× / 1.01× |
| add when the entity has 40 | 118 / 56 ns | 116 / 57 ns | 0.99× / 1.02× |
| remove when the entity has 41 | 109 / 54.6 ns | 109 / 55.9 ns | 1.00× / 1.02× |

#### Tags

| Scenario | mErCS 1.1.0 | mErCS 1.2.0 | ratio |
|---|---|---|---|
| add a tag | 93.8 / 51.1 ns | 94.3 / 51.1 ns | 1.01× / 1.00× |
| remove a tag | 109 / 61.1 ns | 107 / 61.9 ns | 0.98× / 1.01× |
| toggle a tag on 10 % of the entities per frame | 174 / 94.1 ns | 176 / 92.3 ns | 1.01× / 0.98× |

#### Access

| Scenario | mErCS 1.1.0 | mErCS 1.2.0 | ratio |
|---|---|---|---|
| `get` 1 id | 45.9 / 27.6 ns | 45.8 / 26.6 ns | 1.00× / 0.97× |
| `get` 2 ids | 58.2 / 32.9 ns | 57.8 / 32.4 ns | 0.99× / 0.99× |
| `get` 4 ids | 91.2 / 44.3 ns | 87.2 / 43.3 ns | 0.96× / 0.98× |
| `get` 8 ids (jecs: at most 4) | 231 / 110 ns | 229 / 109 ns | 0.99× / 1.00× |
| `has` 1 id | 49.7 / 29.7 ns | 50.8 / 30 ns | 1.02× / 1.01× |
| `has` 4 ids | 102 / 42.1 ns | 98.5 / 42.5 ns | 0.96× / 1.01× |
| `has` 8 ids (jecs: at most 4) | 187 / 69.9 ns | 186 / 70.1 ns | 1.00× / 1.00× |

#### Pairs

| Scenario | mErCS 1.1.0 | mErCS 1.2.0 | ratio |
|---|---|---|---|
| `pair(R, T)` | 20.8 / 8.73 ns | 22.7 / 9.67 ns | 1.09× / 1.11× |
| add a pair | 271 / 167 ns | 277 / 172 ns | 1.02× / 1.02× |
| set the value of an existing pair | 67.4 / 43.5 ns | 67.7 / 44.7 ns | 1.00× / 1.03× |
| remove a pair | 200 / 110 ns | 200 / 111 ns | 1.00× / 1.01× |
| `target` (4 pairs) | 62.9 / 35.2 ns | 61.6 / 36.2 ns | 0.98× / 1.03× |
| `ChildOf` children, per child (10 000 parents × 5) | 139 / 98.6 ns | 139 / 103 ns | 1.01× / 1.05× |
| add a pair with a target of its own | 3.26 / 2.93 µs | 3.32 / 2.93 µs | 1.02× / 1.00× |
| delete a target: `Remove` (1000 × 100 sources, per source) | 151 / 83.3 ns | 152 / 82.7 ns | 1.01× / 0.99× |
| delete a parent: `ChildOf` cascade (per child) | 403 / 236 ns | 402 / 241 ns | 1.00× / 1.02× |

#### Queries (per entity or match)

| Scenario | mErCS 1.1.0 | mErCS 1.2.0 | ratio |
|---|---|---|---|
| for-in, 4 values, 8192 entities per archetype | 47.2 / 33.5 ns | 47.4 / 33.6 ns | 1.00× / 1.00× |
| `query:each`, the same (ratio: against the jecs for-in) | 31.5 / 15.4 ns | 31 / 15.5 ns | 0.99× / 1.00× |
| manual loop (`spans` / jecs archetypes), the same | 14.1 / 5.08 ns | 14.5 / 4.96 ns | 1.03× / 0.98× |
| for-in, 4 values, 256 entities per archetype | 52.3 / 35.1 ns | 52.1 / 35.5 ns | 1.00× / 1.01× |
| `query:each`, the same (against the jecs for-in) | 35.2 / 16.9 ns | 34.5 / 17.3 ns | 0.98× / 1.03× |
| manual loop, the same | 16.8 / 6.27 ns | 17.4 / 6.19 ns | 1.03× / 0.99× |
| for-in, 4 values, 16 entities per archetype | 68.8 / 41 ns | 68.9 / 41.5 ns | 1.00× / 1.01× |
| `query:each`, the same (against the jecs for-in) | 48.9 / 21.6 ns | 48.2 / 21.2 ns | 0.98× / 0.98× |
| manual loop, the same | 31.4 / 9.59 ns | 30.7 / 9.65 ns | 0.98× / 1.01× |
| for-in, 4 values, 1 entity per archetype | 74.3 / 45.5 ns | 74.9 / 45.8 ns | 1.01× / 1.00× |
| `query:each`, the same (against the jecs for-in) | 54.4 / 25.4 ns | 54.4 / 26.6 ns | 1.00× / 1.05× |
| manual loop, the same | 36 / 14.3 ns | 35.9 / 13.9 ns | 1.00× / 0.97× |
| a query created and iterated once | 48.6 / 33.3 ns | 49.1 / 32.9 ns | 1.01× / 0.99× |
| for-in, 1 value of an entity with 4 | 35.9 / 27.5 ns | 36 / 27.7 ns | 1.00× / 1.01× |
| for-in with `without` (half excluded) | 36.9 / 30.3 ns | 36.4 / 30.1 ns | 0.99× / 1.00× |
| `query:each`, the same (against the jecs for-in) | 21.5 / 12.6 ns | 20.8 / 12.7 ns | 0.97× / 1.01× |
| for-in over a sparse match (1 %) | 63.4 / 57.7 ns | 63 / 57.4 ns | 0.99× / 0.99× |
| `query:each`, the same (against the jecs for-in) | 40.1 / 30.9 ns | 39.7 / 28.9 ns | 0.99× / 0.94× |
| the first loop of a new query (2000 archetypes), per query | 406 / 349 ns | 406 / 349 ns | 1.00× / 1.00× |
| a small query created on every call (15 of 1000), per query | 1.21 / 1.07 µs | 1.18 / 1.06 µs | 0.97× / 0.99× |
| a query of a concrete pair created on every call (15 of 1000), per query | 1.04 µs / 881 ns | 1.03 µs / 874 ns | 1.00× / 0.99× |
| the same, nothing matches (0 of 1000) | 166 / 148 ns | 165 / 146 ns | 1.00× / 0.99× |
| an entity used as a term in 4 inline queries, then deleted, per entity | 5.76 / 5.18 µs | 5.76 / 5.21 µs | 1.00× / 1.01× |
| a query with 10 terms | 97.6 / 59.6 ns | 95.8 / 58.1 ns | 0.98× / 0.97× |

#### Batch operations (per match; jecs: a collect-and-change loop)

| Scenario | mErCS 1.1.0 | mErCS 1.2.0 | ratio |
|---|---|---|---|
| add a tag to the matches (half of the entities) | 35.2 / 12.5 ns | 35.4 / 13.2 ns | 1.01× / 1.06× |
| set a component on the matches | 70.3 / 26.3 ns | 69.7 / 26.7 ns | 0.99× / 1.02× |
| remove a component from the matches | 37.2 / 12.1 ns | 37.5 / 12.4 ns | 1.01× / 1.03× |
| delete the matches | 480 / 243 ns | 483 / 251 ns | 1.01× / 1.03× |
| count the matches | 6.93 / 2.41 ns | 7.02 / 2.51 ns | 1.01× / 1.04× |

#### Churn (per cycle)

| Scenario | mErCS 1.1.0 | mErCS 1.2.0 | ratio |
|---|---|---|---|
| spawn and despawn (10 components, 2 tags) | 2.38 / 1.16 µs | 2.41 / 1.19 µs | 1.01× / 1.03× |
| a hierarchy of 1 + 5 `ChildOf`, spawned and deleted | 10.7 / 7.12 µs | 10.8 / 7.18 µs | 1.01× / 1.01× |

### Memory and garbage

| Kept per unit | mErCS 1.1.0 | mErCS 1.2.0 | ratio |
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
| Loop | mErCS 1.1.0 | mErCS 1.2.0 | ratio |
|---|---|---|---|
| Inline two-component query | 80 B | 80 B | 1.00× |
| Stored query | 0 B | 0 B | — |
| `world:each` | 152 B | 152 B | 1.00× |
