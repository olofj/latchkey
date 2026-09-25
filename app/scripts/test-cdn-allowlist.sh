#!/bin/bash
# Compile and run the CDN allowlist regex tests on the host (F6 §4.1a).
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

cp scripts/test-cdn-allowlist.swift "$OUT/main.swift"
xcrun swiftc -O \
    App/Browser/ContentRules.swift \
    "$OUT/main.swift" \
    -o "$OUT/cdn-allowlist-tests"
"$OUT/cdn-allowlist-tests"
