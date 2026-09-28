# jecs compatibility tests

`tests.luau` is the test suite of jecs 0.11.0 (`test/tests.luau`) run against mErCS: `.luaurc`
maps `@jecs` to `shim.luau`. The shim returns the module of the jabby
adapter (`src/jabby.luau`), whose worlds come attached: the suite uses `query:iter()`,
`query:archetypes()`, `world.entity_index` and `entity_index_try_get`, which only the adapter
has. It also adds `bulk_insert` / `bulk_remove`, which the library does not have, as loops of
`world:set` / `world:remove` (as the migration guide says), so the `bulk` cases still run.

Run from the repository root:

    luau test/jecs_compat/tests.luau

Not applicable (they inspect jecs internals that mErCS does not have) and disabled
in the copy (`TEST` -> `SKIP_TEST`, `do CASE` -> `if NOT_APPLICABLE then CASE`):

| Test / case | Internal it uses |
|---|---|
| migrating to real records | `jecs.record` |
| reproduce idr_t nil archetype bug | `jecs.record`, `archetype_traverse_remove` |
| Ensure archetype edges get cleaned | `archetype_edges` |
| world:add: idempotent, archetype move | entity visualiser (archetypes) |
| world:clear: remove all components on entity | `jecs.record` |
| world:range: delete outside partitioned range | `entity_index.max_id` |
| world:range: sparse_array remains optimized with non-contiguous entity IDs | `entity_index.sparse_array` |
| world:query: query:archetypes(override), cached | identity of `query:archetypes()` results, `archetype_index` |
| world:remove: archetype move | entity visualiser (archetypes) |
| world:target: nth index | `entity_index_try_get`, `component_record` |
| world:targets: should properly handle rapid add/remove calls | `entity_index.sparse_array` |
| #repro | entity visualiser (archetypes) |

Intentional differences (the expectation in the copy is changed and marked with a comment):

- world:query: query single component — an uncached query can be iterated again; jecs drains
  it after the first loop.

`modules/entity_visualiser.luau` is a stub that raises an error; `modules/testkit.luau` is a
copy of `vendor/testkit.luau`.
