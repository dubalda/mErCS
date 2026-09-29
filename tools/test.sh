#!/usr/bin/env bash
# Runs every test file, the example and the default fuzz run with the luau CLI; exits with a
# non-zero code on the first failure. `--codegen` runs them with native code generation.
#
# jecs comes from the Wally packages: run `wally install` once before the tests.
#
# Run from anywhere:
#     bash tools/test.sh
#     bash tools/test.sh --codegen
set -euo pipefail
cd "$(dirname "$0")/.."

flags=()
if [ "${1:-}" = "--codegen" ]; then
    flags+=(--codegen)
fi

for file in test/core.luau test/lib.luau test/types.luau test/fuzz.luau test/jabby.luau \
    test/jecs_compat/tests.luau test/jecs_compat/ob.luau test/monitors_fuzz.luau test/queries_fuzz.luau \
    test/loops_fuzz.luau test/workload_cases.luau examples/basics.luau; do
    echo "== $file"
    luau "${flags[@]}" "$file"
done
echo "== all tests passed${flags[*]:+ (${flags[*]})}"
