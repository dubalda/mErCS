#!/usr/bin/env bash
# Runs the performance suite of the reference workload (bench/workload.luau) in the interpreter
# and in native code, against the previous release (run tools/previous.sh first) and the library
# itself, and writes the report to tmp/workload-report.md (and to the output).
#
# Run from anywhere; the arguments go to bench/workload.luau:
#     bash tools/workload.sh
#     bash tools/workload.sh runs=5 tests=P1,P7 scales=target
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p tmp
report=tmp/workload-report.md
{
    echo "# The reference workload"
    echo
    echo "## Interpreter (luau -O2)"
    echo
    luau -O2 bench/workload.luau -a "$@"
    echo
    echo "## Native code (luau -O2 --codegen)"
    echo
    luau -O2 --codegen bench/workload.luau -a "$@"
} | tee "$report"
echo
echo "report: $report"
