#!/usr/bin/env bash
# Runs the isolated reference workload suite. Python extracts and verifies the baseline tag,
# runs both controls in fresh Luau processes, and writes tmp/workload/report.md and samples.json.
#
# Run from anywhere; the arguments go to tools/workload.py (Python 3.11+):
#     bash tools/workload.sh
#     bash tools/workload.sh release=yes
#     bash tools/workload.sh runs=5 tests=P1,P7 scales=sparse,target
set -euo pipefail
cd "$(dirname "$0")/.."

# python3, or python where python3 does not run (the Windows store alias)
if python3 -c "" >/dev/null 2>&1; then
    exec python3 tools/workload.py "$@"
fi
exec python tools/workload.py "$@"
