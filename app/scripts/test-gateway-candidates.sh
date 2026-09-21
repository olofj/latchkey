#!/bin/bash
# Host tests for gateway discovery's peer filter and fingerprint (M5, R26).
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
cp scripts/test-gateway-candidates.swift "$OUT/main.swift"
xcrun swiftc -O App/Discovery/GatewayCandidates.swift "$OUT/main.swift" -o "$OUT/candidates-tests"
"$OUT/candidates-tests"
