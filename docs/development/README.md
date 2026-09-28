# Development

How the repository is organized, how to test, check and benchmark the library, how to run
the checks and benchmarks in Roblox Studio, and how CI, releases and the documentation site
work.

## Setup

- Tools are pinned in `rokit.toml`: luau (CLI runtime), luau-lsp, StyLua, selene, Wally,
  wally-package-types, Rojo. Install them with `rokit install`.
- `wally install` puts the dev dependencies of `wally.toml` into `DevPackages/`: jecs (the
  reference for the comparisons, the core tests and the benchmarks) and jabby (the debugger,
  for the Studio check). The library itself has no dependencies.
- `.luaurc` aliases: `@lib` (the library), `@jecs` (the jecs package), `@testkit`, `@bench`,
  `@test`.

### Types through the Wally link modules (optional)

The link modules that Wally writes into `DevPackages/` (`jecs.lua`, and the ones inside
`_Index`) return the package but not its exported types. `wally-package-types` adds the
types to them, so an editor that resolves requires with a Rojo sourcemap sees `jecs.World`
and the other types through the links. Run from the repository root, after every
`wally install` (it rewrites the link modules):

```sh
rojo sourcemap studio/studio.project.json --absolute -o sourcemap.json
wally-package-types --sourcemap sourcemap.json DevPackages/
```

- The sourcemap has to include `DevPackages/`: `default.project.json` holds only the
  library, the Studio check project holds the packages too.
- The paths have to be absolute (`--absolute`): with relative ones (`../DevPackages/...`,
  relative to `studio/`) the tool finds no link module.
- Checked with Rojo 7.7.0 and wally-package-types 1.6.2: it rewrites 4 link modules (`jecs`,
  the `jecs` link of jabby, the two `vide` links); `jabby` exports no types.
- The code of the repository does not need it: the tests reach jecs through the `.luaurc`
  alias, the Studio files cast the packages to `any`, and `tools/check.sh` gives the same
  result with or without it.
- `sourcemap.json` is ignored by git.

## Layout

```
src/init.luau          the library (the specialized iterators are generated, see tools/) and its API reference (doc comments)
src/jabby.luau         the adapter for the jabby debugger (a child module the library never requires)
tools/generate.py      regenerates the iterator sections: python tools/generate.py && stylua src
tools/check.sh         formatting, lints and types, checked like the editor does
tools/test.sh          every test, the example and a fuzz run (--codegen: with native code)
tools/previous.sh      the previous release from its git tag into tmp/previous, for the benchmarks
test/core.luau         core semantics, run against jecs and this library
test/lib.luau          library features, the model tests
test/types.luau        typed API usage (must type-check)
test/fuzz.luau         random operations against a model (flags: wide, hooks, sparse, pool, verify, churn)
test/jabby.luau        the jabby adapter: what jabby reads from its jecs module and a world
test/jecs_compat/      the jecs test suite run against this library (125/125 applicable)
examples/basics.luau   a runnable tour of the API
bench/run.luau         the benchmark matrix (harness.luau, scenarios.luau, shapes.luau, impls.luau, impl_defs.luau)
bench/query_cases.luau query cases where an archetype ECS is at its best: jecs for-in against query:each
bench/frame.luau       a synthetic game frame (frame_scene.luau)
bench/leak.luau        a long session with changing relationship targets (memory growth)
bench/gc.luau          garbage collector access that works in the luau CLI and in Roblox
bench/versions.luau    the versions of jecs and the library in the output of the benchmarks
bench/previous.luau    the previous release (tmp/previous) when tools/previous.sh has extracted it
bench/visual/          Benchmarker plugin files (*.bench.luau): jecs against this library
benchmarker.project.json  a place with the libraries and bench/visual only, for the Benchmarker plugin
studio/                a Roblox place that runs the fuzz test, the frame and the matrix (check.project.json: its tree)
vendor/testkit.luau    the test kit of the jecs suite (MIT)
docs/                  the index (README.md) and a folder per page: guide/, jecs-comparison/, development/
moonwave.toml          the documentation site (Moonwave)
.github/workflows/     CI, releases and the documentation site
```

## Tests

```sh
bash tools/test.sh             # the interpreter
bash tools/test.sh --codegen   # native code
```

`tools/test.sh` runs `test/core.luau`, `test/lib.luau`, `test/types.luau`, `test/fuzz.luau`,
`test/jabby.luau`, `test/jecs_compat/tests.luau` and `examples/basics.luau`, and stops at the
first failure with a non-zero exit code (a failed case of the test kit fails its file).

`test/fuzz.luau` takes a seed, a number of rounds and flags: `wide` creates 300 ids first
(records beyond the shared signature tables), `hooks` adds hooks that change the entity,
`sparse` creates up to 300 empty entities after each entity of the model (the matches spread
over many value pages and every bitset level), `pool` creates half of the entities of the
model from a slot pool, `verify` uses a debug world, which checks every patched match list
of a cached query against a scan of its bitsets and, when a query takes its list as it is,
that none of its records changed, `churn` adds and removes pairs with 400 targets on an
entity outside the model after every operation, so that the pair records left empty (those
of the model too) are freed in batches between and inside the operations of the model, and
`shapes` checks queries that have entities of the model as terms after every batch (a shared
query shape per entity, dropped when the entity is deleted: a new shape of a live entity must
be shared) and keeps some of them across the rounds, after their entity is deleted too:

```sh
luau test/fuzz.luau -a 42 400 wide hooks shapes
luau test/fuzz.luau -a 7 400 sparse pool verify hooks wide churn shapes
```

## Checks

```sh
bash tools/check.sh
```

`tools/check.sh` runs StyLua, selene and `luau-lsp analyze` with the settings of the VS Code
workspace: the new type solver, the Roblox platform and the Roblox type definitions, with the
luau-lsp server of the installed VS Code extension (the version the editor uses), or
`luau-lsp` from `rokit.toml` without it. The Wally packages are not checked.

## Benchmarks in the luau CLI

```sh
bash tools/previous.sh                                      # the previous release, once (optional)
luau -O2 bench/run.luau -a reps=9                           # the matrix, interpreter
luau -O2 --codegen bench/run.luau -a filter=query,pair      # native code, some groups
luau -O2 --codegen bench/run.luau -a "filter=query cases,sparse,state tags" # the query shapes (bench/shapes.luau)
luau -O2 --codegen bench/query_cases.luau                   # the query cases, with the test kit of jecs
luau -O2 bench/frame.luau                                   # the synthetic frame
luau -O2 bench/leak.luau                                    # a long session
```

The benchmarks compare jecs (the Wally dev packages), the previous release of the library and
the current one, and print their versions (`bench/versions.luau`). `tools/previous.sh` puts the
previous release (the newest tag other than the version in `wally.toml`, or a tag given as its
argument) into `tmp/previous`; without it the benchmarks compare jecs and the current library.

`bench/run.luau` arguments: `filter` (substrings of "group.name"), `impls` (`jecs`, `previous`,
`lib`), `reps`, `n`. Time is the minimum over the runs divided by the operations; memory is the
heap growth kept after the run and a full collection.

The groups `query cases` and `sparse world` (`bench/shapes.luau`) time one pass of a query with
the changes a game makes before it: five cases where an archetype ECS is at its best (entity
ids scattered by churn, a tag of the query toggled between loops, four values read per match,
a `(*, T)` wildcard over changing pairs, a query that almost never matches), and creatures
scattered among their children (skills), also created from a slot pool. The group
`state tags` times a frame of 1200 skills in 5 state tags: 10, 200 or 800 of them move to
the next state, then 5 queries written inline pass over the skills of each state. A loop over
matches is the for-in loop for jecs and `query:each` for this library (it replaces the for-in
loop fully when the loop does not break). The worlds of the first two groups have fixed sizes
at `n = 131072` and shrink with a smaller `n`.

`bench/query_cases.luau` runs the same five cases with the test kit of jecs: one run per case,
first loops included; the matrix takes the minimum of several runs.

## Benchmarker (Roblox Studio)

`bench/visual/*.bench.luau` follow the format of the Benchmarker plugin (the same as
`jecs/test/benches/visual`): `ParameterGenerator`, `BeforeAll` / `AfterAll` /
`BeforeEach` / `AfterEach` and `Functions` with an entry for jecs and one for mErCS, named with
their versions (`jecs 0.11.0`, `mErCS 0.2.1`: `libs.luau` reads the version of jecs from its
Wally package and holds the version of mErCS). The parameters are generated before every call
and give each function its own fresh world.

| File | What |
|---|---|
| `spawn.bench.luau` | 1000 entities with 4 components |
| `insertion.bench.luau` | 8 components into 500 existing entities |
| `query.bench.luau` | 10 passes of a 4-component query over 4096 entities with random components (also `query:each`) |
| `despawn.bench.luau` | delete 1000 entities with 4 components and a tag |
| `remove.bench.luau` | remove one of 5 components from 1000 entities |
| `pairs.bench.luau` | 100 parents with 10 `ChildOf` children that also target a parent through a relation, then the parents are deleted |
| `batch.bench.luau` | add and remove a tag on half of 2000 entities: batch operations against a jecs collect-and-change loop |
| `query_scattered.bench.luau` | a query case: a 4-component query over 50 000 entities scattered by churn |
| `query_churn.bench.luau` | a query case: a tag of the query toggled on 1 or 100 entities before each pass (70 000 entities) |
| `query_read4.bench.luau` | a query case: 4 values read per match (80 000 entities) |
| `query_wildcard.bench.luau` | a query case: `(*, T)` over 64 relations with a pair toggled before each pass (20 000 entities) |
| `query_empty.bench.luau` | a query case: 100 passes of a query that never matches (100 000 entities) |

The `query_*` files share `query_worlds.luau` (the worlds of `bench/query_cases.luau`, built
when a file is required) and run the same loops: the for-in loop for jecs, `query:each` for
mErCS.

The template `benchmarker.project.json` builds a place with only what the bench files need
(the library, the Wally dev packages and `bench/visual`, at the same paths as in the Studio
check place) and no scripts that run on Play:

```sh
wally install
rojo build benchmarker.project.json -o benchmarker.rbxl   # or: rojo serve benchmarker.project.json
```

Open the place (or sync it into an open one), open the Benchmarker plugin and run the files
from `ReplicatedStorage.mErCSCheck.bench.visual`. The same files are in the Studio check place
(below). The plugin requires a clone of each
`*.bench` module, which has no parent, so the bench files reach `libs.luau` from
`ReplicatedStorage` (relative requires fail in a clone); `libs.luau` itself requires jecs from
the Wally dev packages and the library by relative paths.

How the plugin runs a bench file, which matters when writing a new one:

1. It requires a clone of the module.
2. It calls every function once to check it: the function must not yield and must finish
   within 40 ms. This happens before `BeforeAll`, so whatever a function reads must exist
   when the module is required or come from `ParameterGenerator` (`query.bench.luau` builds
   its worlds at the top of the module).
3. It calls `BeforeAll`.
4. It runs 1000 rounds of every function. `ParameterGenerator` is called before each call,
   outside the measured time, and `BeforeEach` / `AfterEach` around it.
5. It calls `AfterAll`.

The results, including an error message, are stored in the `BenchResults` attribute of the
bench module. Its "Average" is the midpoint of the minimum and the maximum, not the mean:
compare the medians (50th percentile). The results of these files, with screenshots, are in
[Roblox Studio: Benchmarker](../jecs-comparison/README.md#roblox-studio-benchmarker).

## Roblox Studio

```sh
wally install
rojo build studio/studio.project.json -o check.rbxl
```

Or sync into an open place: the workspace that contains this repository has a
`default.project.json` next to it (with a `rokit.toml` that pins rojo); run `rojo serve` there
and connect the Rojo plugin. Both projects include `studio/check.project.json`, the tree of
the check.

Open the place and press Play. The place mirrors the repository layout under
`ReplicatedStorage.mErCSCheck` (`src`, `DevPackages`, `bench`, `test`, `studio`), so
the tests and benchmarks run unchanged, with the same relative requires as in the luau CLI;
the check scripts are Scripts with the Server and Client run contexts.
The Output shows the fuzz result, the frame and the matrix for the server (native code) and
then for a client. For the native code size run `debug.dumpcodesize()` from the Command Bar
in the Server view. The library alone is built with `rojo build default.project.json -o
mErCS.rbxm`.

## Generated code

The specialized query iterators (0–8 returned values) are generated by `tools/generate.py`
between the `-- @generated <name> begin` / `end` markers of `src/init.luau`:

```sh
python tools/generate.py && stylua src
```

## CI and releases

The workflows of `.github/workflows/` get the tools from `rokit.toml` (the
`CompeyDev/setup-rokit` action):

| Workflow | When | What |
|---|---|---|
| `ci.yml` | every pull request and push to `main` | `tools/check.sh`; `tools/test.sh` in the interpreter and with native code, plus 3 fuzz runs of 400 rounds (`wide hooks`) and 2 with `sparse pool verify hooks wide churn shapes`; the model `mercs.rbxm` and the Wally package as artifacts; the documentation site is built, not published |
| `release.yml` | a pushed tag `vX.Y.Z` | the tag must match `version` in `wally.toml`; checks and tests; `wally publish`; a GitHub release with `mercs.rbxm`, whose text is the section of the tag in `CHANGELOG.md` (generated notes when there is none) |
| `docs.yml` | a push to `main` that changes `src/`, `docs/`, `README.md` or `moonwave.toml` | builds the documentation site and publishes it to GitHub Pages |

To release a version:

1. Add a section `## vX.Y.Z — date` at the top of `CHANGELOG.md`. It becomes the text of the
   GitHub release (up to the next `## ` heading), so write links as absolute URLs. The site
   shows `CHANGELOG.md` as its Changelog page.
2. Set the version (without the `v`) in `wally.toml`, and in the output of the benchmarks:
   `library` in `bench/versions.luau` and `LIBRARY_VERSION` in `bench/visual/libs.luau`.
3. Commit, wait for a green CI, then push the tag:

```sh
git tag -a v0.2.1 -m "mErCS v0.2.1"
git push origin v0.2.1
```

Settings of the GitHub repository:

- Settings → Pages → Source: **GitHub Actions**.
- Settings → Secrets and variables → Actions: `WALLY_AUTH_TOKEN` (see below).
- Settings → Rules → Rulesets: the rule for `main` (see below).

### The Wally token

The Wally registry accepts only a token that its own GitHub OAuth app issued: it checks the
token with GitHub (`GET /user` and the token check of the Wally app). Neither the automatic
`GITHUB_TOKEN` of the workflows nor a personal access token passes. Get the token once, with
the account that owns the `dubalda` scope:

1. Run `wally login` in the repository folder, open
   [github.com/login/device](https://github.com/login/device), enter the code and authorize
   Wally.
2. Copy the token (`gho_...`) from the `[tokens]` table of `~/.wally/auth.toml`
   (`%USERPROFILE%\.wally\auth.toml` on Windows).
3. Add it as the repository secret `WALLY_AUTH_TOKEN`.

The token does not expire by itself; it is revoked in the GitHub settings of the account
(Applications → Authorized OAuth Apps → Wally).

### The rule for `main`

`.github/rulesets/main.json` is a ruleset for the default branch. Import it in Settings →
Rules → Rulesets → New ruleset → **Import a ruleset**, review it and click Create. It makes
every change of `main` a pull request that merges only when:

- the CI jobs pass: "Format, lints and types", "Tests (interpreter)", "Tests (native)",
  "Model and Wally package", "Documentation site" (the job names of `ci.yml`: renaming a job
  means updating the ruleset);
- the branch is up to date with `main` (the "Update branch" button of the pull request);

and `main` cannot be deleted or force-pushed. No approvals are required (a pull request can be
merged by its author), and nobody bypasses the rule, administrators included. Tags are not
affected, so releases work as before.

Import it after CI has run once on GitHub, and check that the Checks tab shows these five
names: a required check that never reports keeps every pull request waiting.

The Wally package holds only the library: `wally.toml` excludes everything
(`exclude = ["**"]`) and includes `src`, `default.project.json`, `wally.toml`, `README.md` and
`LICENSE` (wally 0.3 packs every file that `include` alone does not override);
`wally package --list` shows the contents.

## The documentation site

[Moonwave](https://eryn.io/moonwave/) builds it: the API reference from the doc comments of
`src/` (the `--[=[ ]=]` blocks after the types of `src/init.luau`, and `src/jabby.luau`), the
pages of `docs/`, and `README.md` as the home page. It needs Node.js 18 or newer:

```sh
npx moonwave@1.4.2 dev     # a local preview that reloads on changes
npx moonwave@1.4.2 build   # the static site in build/
```

- `docs/` has an index, `docs/README.md`, and a folder per page with a `README.md`, which
  GitHub shows when the folder is opened. The index has `id: intro` in its front matter:
  Moonwave links the navigation bar to the doc `intro`. The `_category_.json` of a folder
  gives the label and the position of the page in the sidebar.
- The workflows rewrite the README links `docs/x/README.md` to `docs/x` before the build
  (the site serves a folder page at `docs/x`); a local preview shows these links as broken.
- The pages are MDX: `<https://...>` autolinks break the build, write `[text](url)`.
- Generics in the name of a `@type` break its page: write `@type Pair Id<First | Second>` and
  give `Pair<First, Second>` in the text. Parameters and returns may use generics.
- `[World:contains]`, `[mErCS.pair]` and the like in a doc comment become links to the
  reference.
- A broken link or a malformed doc comment fails the build, so `ci.yml` catches it in pull
  requests.
