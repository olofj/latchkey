#!/bin/bash
# Host tests for the token sheet's parser (M4.4, R23).
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
cp scripts/test-token-input.swift "$OUT/main.swift"
# Both optimization levels: -O once miscompiled this file's predicates while
# -Onone was fine (DECISIONS, M4), and Release builds with -O.
for opt in -O -Onone; do
    xcrun swiftc $opt App/Session/TokenInput.swift "$OUT/main.swift" -o "$OUT/token-input-tests"
    printf '%s: ' "$opt"
    "$OUT/token-input-tests" | tail -1
    "$OUT/token-input-tests" >/dev/null
done
