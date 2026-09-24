#!/bin/bash
# Host tests for sign-out and reset's pure parts (R32): how the gateway's
# logout answer is read, and the LocalAPI logout request.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
cp scripts/test-signout.swift "$OUT/main.swift"
# -O, as the other host tests: they catch optimizer-only bugs (AGENTS.md).
if ! xcrun swiftc -O App/Session/DashboardSignOut.swift App/Workspace/TailnetLogout.swift \
        "$OUT/main.swift" -o "$OUT/signout-tests" > "$OUT/build.log" 2>&1; then
    cat "$OUT/build.log" >&2
    echo "error: the sign-out host tests do not compile" >&2
    exit 1
fi
"$OUT/signout-tests"
