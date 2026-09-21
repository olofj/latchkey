#!/bin/bash
# Host tests for the token sheet's parser (M4.4, R23).
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
cp scripts/test-token-input.swift "$OUT/main.swift"
xcrun swiftc -O App/Session/TokenInput.swift "$OUT/main.swift" -o "$OUT/token-input-tests"
"$OUT/token-input-tests"
