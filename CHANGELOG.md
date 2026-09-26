# Changelog

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
