#!/bin/bash
# Host tests for App/Workspace/WorkspaceStore.swift: a damaged workspaces.json
# is preserved, never overwritten; a missing field decodes to a default; one
# bad entry does not discard the others. Table-driven, one document per row.
#
# Compiles the REAL store against four stubs (test-workspace-store-stubs.swift)
# and runs it in a mktemp directory only. It never touches an app container or
# this user's Application Support (the test checks that too).
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

sed 's/^import TailscaleKit$//' App/Workspace/WorkspaceStore.swift > "$OUT/store.swift"
cp scripts/test-workspace-store.swift "$OUT/main.swift"
# -O, as the other host tests: they catch optimizer-only bugs (AGENTS.md).
if ! xcrun swiftc -O "$OUT/store.swift" scripts/test-workspace-store-stubs.swift "$OUT/main.swift" \
        -o "$OUT/workspace-store-tests" > "$OUT/build.log" 2>&1; then
    cat "$OUT/build.log" >&2
    echo "error: the workspace store host tests do not compile" >&2
    exit 1
fi
"$OUT/workspace-store-tests"
