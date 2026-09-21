#!/bin/bash
# Compile and run the navigation-policy unit tests on the host (revision R3).
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

cp scripts/test-navigation-policy.swift "$OUT/main.swift"
xcrun swiftc -O \
    App/Browser/NavigationPolicy.swift \
    App/Browser/GatewayAddress.swift \
    "$OUT/main.swift" \
    -o "$OUT/navigation-policy-tests"
"$OUT/navigation-policy-tests"
