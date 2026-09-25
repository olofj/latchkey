#!/bin/bash
# Host tests for the bounded status request and the two-strike loopback
# recovery (F16 stage 1).
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -r "$OUT"' EXIT
cp scripts/test-loopback-stalls.swift "$OUT/main.swift"
# -O and the app's isolation flags, as the other host tests (AGENTS.md).
if ! xcrun swiftc -O -swift-version 6 -strict-concurrency=complete -default-isolation MainActor \
        App/Network/LoopbackHealth.swift \
        "$OUT/main.swift" -o "$OUT/loopback-stall-tests" > "$OUT/build.log" 2>&1; then
    cat "$OUT/build.log" >&2
    echo "error: the loopback stall host tests do not compile" >&2
    exit 1
fi
"$OUT/loopback-stall-tests"
