#!/bin/bash
# Host tests for the node log reader, the expiry clocks and the session
# cookie summary (M8.2, M8.3, R31, R33).
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
cp scripts/test-diagnostics.swift "$OUT/main.swift"
# -O, as the other host tests: they catch optimizer-only bugs (AGENTS.md).
if ! xcrun swiftc -O App/Diagnostics/NodeLog.swift App/Diagnostics/Expiry.swift App/Diagnostics/SessionCookies.swift \
        App/Logging/LogRedaction.swift \
        "$OUT/main.swift" -o "$OUT/diagnostics-tests" > "$OUT/build.log" 2>&1; then
    cat "$OUT/build.log" >&2
    echo "error: the diagnostics host tests do not compile" >&2
    exit 1
fi
"$OUT/diagnostics-tests"
