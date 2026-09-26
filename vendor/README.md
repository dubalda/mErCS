# vendor

Third-party code kept in the repository, used only by the tests. Not part of the library.

| Path | Source | License |
|---|---|---|
| `testkit.luau` | `jecs/modules/testkit.luau` (testkit v0.7.3 by centau, modified by the jecs authors; strict types added here, see its header) | MIT, header of the file |

jecs (the reference for comparisons, the core tests and the benchmarks) comes from Wally:
`wally install` puts `ukendio/jecs@0.11.0` into `DevPackages/` (a dev dependency, see `wally.toml`).
