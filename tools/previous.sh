#!/usr/bin/env bash
# Extracts the previous release of the library from its git tag into tmp/previous, where the
# benchmarks (bench/run.luau, bench/frame.luau, bench/leak.luau, bench/query_cases.luau) find
# it and add it to their comparison. Without it they compare jecs and the current library only.
#
# The previous release is the newest tag vX.Y.Z whose version is not the one in wally.toml;
# a tag given as the argument is taken instead.
#
# Run from anywhere:
#     bash tools/previous.sh           # the previous release, for example v0.1.2
#     bash tools/previous.sh v0.1.1    # another release
set -euo pipefail
cd "$(dirname "$0")/.."

current=$(sed -n 's/^version = "\(.*\)"$/\1/p' wally.toml)
tag=${1:-}
if [ -z "$tag" ]; then
    tag=$(git tag --list 'v*' --sort=-v:refname | grep -v -x "v$current" | head -n 1 || true)
fi
if [ -z "$tag" ]; then
    echo "error: no release tag other than v$current" >&2
    exit 1
fi
if ! git rev-parse --quiet --verify "refs/tags/$tag" >/dev/null; then
    echo "error: there is no tag $tag" >&2
    exit 1
fi

rm -rf tmp/previous
mkdir -p tmp/previous/mercs
git show "$tag:src/init.luau" >tmp/previous/mercs/init.luau
# the version and the module, read by bench/previous.luau
cat >tmp/previous/init.luau <<EOF
return { version = "${tag#v}", ecs = require("@self/mercs") }
EOF
echo "tmp/previous: mErCS ${tag#v} (the current version is $current)"
