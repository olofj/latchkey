#!/bin/bash
# Compile and run the gateway row's chip-state tests on the host (F22 §4).
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

cp scripts/test-gateway-row.swift "$OUT/main.swift"
# -O and the app's isolation flags, as the other host tests (AGENTS.md).
xcrun swiftc -O -swift-version 6 -strict-concurrency=complete -default-isolation MainActor \
    App/Browser/GatewayChipState.swift \
    "$OUT/main.swift" \
    -o "$OUT/gateway-row-tests"
"$OUT/gateway-row-tests"
