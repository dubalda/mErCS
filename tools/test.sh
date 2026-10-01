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
release_luau=${MERCS_LUAU:-luau}

flags=()
if [ "${1:-}" = "--codegen" ]; then
    flags+=(--codegen)
fi

# The behavior specification, with the worlds of its cases as they ask (`plain`) or debug worlds
# wherever a case does not ask for a world without checks (`debug`). The library reports through
# print in the CLI: count the actual warning (made by the last case of the workload group), not
# just the number of shared states. Keep the failing program's output and exit status.
behavior() {
    local output status warnings
    if output=$("$release_luau" "${flags[@]}" test/behavior.luau "$@" 2>&1); then
        printf '%s\n' "$output"
    else
        status=$?
        printf '%s\n' "$output"
        exit "$status"
    fi
    warnings=$(printf '%s\n' "$output" | grep -c '^mErCS: 1024 query shapes are shared' || true)
    if [ "$warnings" != 1 ]; then
        echo "expected one shared-query warning, got $warnings" >&2
        exit 1
    fi
}

for file in test/core.luau test/lib.luau test/types.luau test/fuzz.luau test/jabby.luau \
    test/jecs_compat/tests.luau test/jecs_compat/ob.luau test/monitors_fuzz.luau test/queries_fuzz.luau \
    test/loops_fuzz.luau test/snapshots_fuzz.luau test/reentrant_fuzz.luau test/workload_model.luau \
    test/behavior.luau examples/basics.luau; do
    if [ "$file" = test/behavior.luau ]; then
        echo "== $file"
        behavior
        echo "== $file (debug worlds)"
        behavior -a debug
    else
        echo "== $file"
        "$release_luau" "${flags[@]}" "$file"
    fi
done
echo "== all tests passed${flags[*]:+ (${flags[*]})}"
