#!/bin/bash
# Compile and run the content-process recovery policy tests on the host (R7).
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

cp scripts/test-content-process-recovery.swift "$OUT/main.swift"
xcrun swiftc -O \
    App/Browser/ContentProcessRecovery.swift \
    "$OUT/main.swift" \
    -o "$OUT/content-process-recovery-tests"
"$OUT/content-process-recovery-tests"
