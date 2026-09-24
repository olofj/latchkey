#!/bin/bash
# Host tests for the R10 fixture-tailnet allow-list (App/Testing/FixtureTailnetCheck.swift).
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
cp scripts/test-fixture-tailnets.swift "$OUT/main.swift"
xcrun swiftc -O -DLATCHKEY_TEST_HOOKS App/Testing/FixtureTailnetCheck.swift "$OUT/main.swift" \
    -o "$OUT/fixture-tailnet-tests"
"$OUT/fixture-tailnet-tests"
