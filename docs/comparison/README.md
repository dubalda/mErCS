# Comparison

How mErCS 1.0.1 compares with its previous release and with two other ECS libraries for Luau.
Every number of these pages was measured with the standalone `luau` 0.740 CLI on one machine,
each library in a process of its own, in the interpreter and in native code; the screenshots
come from the Benchmarker plugin in Roblox Studio (captured with 1.0.0).

- [Benchmarker](benchmarker.md): the benchmarks of `bench/visual/` in Roblox Studio, with
  their screenshots.
- [1.0.1 and 1.0.0](previous-release.md): the reference workload and the matrix of single
  operations, against the previous release.
- [jecs](jecs.md): the design, the differences in behaviour, the numbers and the migration from
  [jecs](https://github.com/Ukendio/jecs) 0.11.0, the library whose API mErCS follows.
- [ecr](ecr.md): the design, the differences, four basic benchmarks and the migration from
  [ecr](https://github.com/centau/ecr) 0.9.0, a sparse-set ECS.
