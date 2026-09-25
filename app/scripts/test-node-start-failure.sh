#!/bin/bash
# Host tests for App/Tailnet Status/NodeStartFailure.swift (F8 §6.2): the
# cause sentence for each errno -- and from tsnet's message when there is
# none -- the backoff schedule, that only a successful start clears the
# failure, and that a logging refusal never counts down.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
cp scripts/test-node-start-failure.swift "$OUT/main.swift"
# -O and the app's isolation flags, as the other host tests (AGENTS.md).
if ! xcrun swiftc -O -swift-version 6 -strict-concurrency=complete -default-isolation MainActor \
        "App/Tailnet Status/NodeStartFailure.swift" \
        "$OUT/main.swift" -o "$OUT/node-start-failure-tests" > "$OUT/build.log" 2>&1; then
    cat "$OUT/build.log" >&2
    echo "error: the node start failure host tests do not compile" >&2
    exit 1
fi
"$OUT/node-start-failure-tests"
