#!/bin/bash
# Compile and run the app bar's retraction policy tests on the host (F15 §4a).
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

cp scripts/test-app-bar-retraction.swift "$OUT/main.swift"
# -O and the app's isolation flags, as the other host tests (AGENTS.md).
xcrun swiftc -O -swift-version 6 -strict-concurrency=complete -default-isolation MainActor \
    App/Browser/AppBarRetraction.swift \
    "$OUT/main.swift" \
    -o "$OUT/app-bar-retraction-tests"
"$OUT/app-bar-retraction-tests"
