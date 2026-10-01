# mErCS
ECS (an entity component system) for Luau and Roblox built on inverted bitsets

Instead of archetypes, every component, tag and pair keeps a bitset of the entities that have
it. Adding or removing a component never moves an entity and never creates an archetype, so
frequent structural changes — state tags, relationships, spawning and despawning — stay O(1),
memory does not grow with the number of component combinations, and there is nothing to clean
up. The API follows [jecs](https://github.com/Ukendio/jecs); moving jecs code over takes a few
mechanical changes (see [Migrating from jecs](docs/jecs-comparison/README.md#migrating-from-jecs)).

Version 0.2.4 is validated with the standalone `luau` 0.740 CLI (interpreter and native code
generation). Earlier Roblox Studio checks with the Benchmarker plugin and jabby are recorded
in the comparison below; the full Studio check (`studio/`) is pending.

The [0.2.4 reference workload report](https://github.com/dubalda/mErCS/blob/main/bench/results/0.2.4.md)
compares this version with 0.2.3 and includes raw measurements, controls and reproduction commands.

## Why

| | jecs 0.11.0 | mErCS 0.2.4 |
|---|---|---|
| add / remove a component | moves the entity, copies all its columns | sets a bit and a value: O(1) |
| new combination of components | creates an archetype, kept until `world:cleanup()` | nothing to create |
| pair with many targets | an archetype per target | one small record per pair, freed when unused (in batches) or with its target |
| components per world | 256 via `world:component()` | no limit |
| a synthetic game frame (interpreter / native) | 7.42 / 5.48 ms | 2.69 / 1.88 ms |
| heap growth with changing targets after 5000 frames (interpreter) | +15.38 MiB | +0.32 MiB |
| memory per entity with 4 components | 320 B | 131 B |

On the [query cases](docs/jecs-comparison/README.md#query-cases) where an archetype ECS is
expected to be at its best, mErCS 0.2.4 takes 0.42–0.83× of the time of jecs 0.11.0 in native
code. The [comparison](docs/jecs-comparison/README.md#performance) includes freshly measured
mErCS 0.2.3 results, ranges and raw samples. Its Roblox Studio screenshots remain historical
0.2.3 results.

Beyond jecs: `query:each` (the fastest loop), OR terms, batch operations on query matches,
change tracking by ticks, disabled entities, hierarchies of any depth, slot pools. Query
monitors (`query:monitor()`) take the place of the monitors of the jecs addon `modules/OB`.

## Installation

Copy `src/init.luau` into your project as a ModuleScript (for example
`ReplicatedStorage.mErCS`; `src/jabby.luau` is an optional child module for the jabby
debugger), or sync the repository with Rojo (`default.project.json`), or depend on it through
Wally (`mercs = "dubalda/mercs@0.2.4"`). The module has no dependencies; `--!native` is enabled
at the top of the file.

## Quick start

```luau
local ecs = require(ReplicatedStorage.mErCS)
local world = ecs.world()

local Position = world:component() :: ecs.Component<Vector3>
local Velocity = world:component() :: ecs.Component<Vector3>
local Frozen = world:entity() -- any entity can be used as a tag

local e = world:entity()
world:set(e, Position, Vector3.zero)
world:set(e, Velocity, Vector3.xAxis)

-- the fastest loop: a callback per entity
world:query(Position, Velocity):without(Frozen):each(function(entity, position, velocity)
    world:set(entity, Position, position + velocity)
end)

-- or a for-in loop, as in jecs
for entity, position, velocity in world:query(Position, Velocity) do
    world:set(entity, Position, position + velocity)
end

-- relationships
local parent = world:entity()
world:add(e, ecs.pair(ecs.ChildOf, parent))
print(world:parent(e) == parent) --> true
world:delete(parent) -- deletes e as well (ChildOf cascades)

-- one change to every match of a query
world:query(Position):with(Frozen):remove_all(Velocity)
```

`examples/basics.luau` is a runnable tour: `luau examples/basics.luau`.

## Documentation

The [documentation site](https://dubalda.github.io/mErCS/) holds the API reference (built
from the doc comments of `src/`) and these pages:

- [Guide](docs/guide/README.md) — worlds, components, queries, batch operations, relationships,
  hooks, query monitors, change tracking, the jabby adapter, types.
- [Comparison with jecs](docs/jecs-comparison/README.md) — design, differences, benchmarks,
  migrating from jecs.
- [Development](docs/development/README.md) — layout, tests, checks, benchmarks, Roblox Studio,
  CI and releases.

## License

MIT
