#!/bin/bash
# Host tests for the node log reader, the expiry clocks and the session
# cookie summary (M8.2, M8.3, R31, R33).
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
cp scripts/test-diagnostics.swift "$OUT/main.swift"
xcrun swiftc -O App/Diagnostics/NodeLog.swift App/Diagnostics/Expiry.swift App/Diagnostics/SessionCookies.swift \
    App/Logging/LogRedaction.swift \
    "$OUT/main.swift" -o "$OUT/diagnostics-tests" 2>&1 | grep -v "nonisolated(unsafe)' is unnecessary" | grep -E "error" || true
"$OUT/diagnostics-tests"
