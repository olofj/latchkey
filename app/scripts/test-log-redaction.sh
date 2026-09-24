#!/bin/bash
# Compile and run the log-redaction unit tests on the host (revision R1).
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

cp scripts/test-log-redaction.swift "$OUT/main.swift"
xcrun swiftc -O \
    App/Logging/LogRedaction.swift \
    "$OUT/main.swift" \
    -o "$OUT/log-redaction-tests"
"$OUT/log-redaction-tests"
