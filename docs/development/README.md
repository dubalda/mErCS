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
test/core.luau         core semantics, run against jecs and this library
test/lib.luau          library features, the model tests
test/types.luau        typed API usage (must type-check)
test/fuzz.luau         random operations against a model
test/jabby.luau        the jabby adapter: what jabby reads from its jecs module and a world
test/jecs_compat/      the jecs test suite run against this library (125/125 applicable)
examples/basics.luau   a runnable tour of the API
bench/run.luau         the benchmark matrix (harness.luau, scenarios.luau, impls.luau, impl_defs.luau)
bench/frame.luau       a synthetic game frame for both libraries (frame_scene.luau)
bench/leak.luau        a long session with changing relationship targets (memory growth)
bench/gc.luau          garbage collector access that works in the luau CLI and in Roblox
bench/visual/          Benchmarker plugin files (*.bench.luau): jecs against this library
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
(records beyond the shared signature tables), `hooks` adds hooks that change the entity:

```sh
luau test/fuzz.luau -a 42 400 wide hooks
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
luau -O2 bench/run.luau -a impls=jecs,lib reps=7          # the matrix, interpreter
luau -O2 --codegen bench/run.luau -a filter=query,pair     # native code, some groups
luau -O2 bench/frame.luau                                  # the synthetic frame
luau -O2 bench/leak.luau                                   # a long session
```

`bench/run.luau` arguments: `filter` (substrings of "group.name"), `impls`, `reps`, `n`.
Time is the minimum over the runs divided by the operations; memory is the heap growth kept
after the run and a full collection.

## Benchmarker (Roblox Studio)

`bench/visual/*.bench.luau` follow the format of the Benchmarker plugin (the same as
`jecs/test/benches/visual`): `ParameterGenerator`, `BeforeAll` / `AfterAll` /
`BeforeEach` / `AfterEach` and `Functions` with a `Jecs` and a `mErCS` entry. The
parameters are generated before every call and give each function its own fresh world.

| File | What |
|---|---|
| `spawn.bench.luau` | 1000 entities with 4 components |
| `insertion.bench.luau` | 8 components into 500 existing entities |
| `query.bench.luau` | 10 passes of a 4-component query over 4096 entities with random components (also `query:each`) |
| `despawn.bench.luau` | delete 1000 entities with 4 components and a tag |
| `remove.bench.luau` | remove one of 5 components from 1000 entities |
| `pairs.bench.luau` | 100 parents with 10 `ChildOf` children that also target a parent through a relation, then the parents are deleted |
| `batch.bench.luau` | add and remove a tag on half of 2000 entities: batch operations against a jecs collect-and-change loop |

They live in the Studio check place (below); open the Benchmarker plugin and run the files
from `ReplicatedStorage.mErCSCheck.bench.visual`. The plugin requires a clone of each
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
| `ci.yml` | every pull request and push to `main` | `tools/check.sh`; `tools/test.sh` in the interpreter and with native code, plus 3 fuzz runs of 400 rounds (`wide hooks`); the model `mercs.rbxm` and the Wally package as artifacts; the documentation site is built, not published |
| `release.yml` | a pushed tag `vX.Y.Z` | the tag must match `version` in `wally.toml`; checks and tests; `wally publish`; a GitHub release with `mercs.rbxm` |
| `docs.yml` | a push to `main` that changes `src/`, `docs/`, `README.md` or `moonwave.toml` | builds the documentation site and publishes it to GitHub Pages |

To release a version, set it in `wally.toml`, commit, then push the tag:

```sh
git tag v0.2.0
git push origin v0.2.0
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
