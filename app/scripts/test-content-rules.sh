#!/bin/bash
# Compile and run the content-rule-list host tests (F6 §4.1, §4.1a): the
# list's shape, then the exact JSON through macOS WebKit's rule compiler, so
# a bad escape fails at make test-policy and not on the phone.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

cp scripts/test-content-rules.swift "$OUT/main.swift"
xcrun swiftc -O \
    App/Browser/ContentRules.swift \
    "$OUT/main.swift" \
    -o "$OUT/content-rules-tests"
"$OUT/content-rules-tests"
