#!/bin/bash
# Host tests for App/Browser/PageState.swift and PageFailureText.swift (F4 §6,
# tests 5 and 6): how a failed page load's cause is decided from the error
# code, the relay's reply and the elapsed time, and that every row of §4.4
# names what it says it names -- and never calls a SOCKS failure a URL error.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
cp scripts/test-page-failure-text.swift "$OUT/main.swift"
# -O and the app's isolation flags, as the other host tests (AGENTS.md): the
# types are nonisolated on purpose, and a missing `nonisolated` would
# otherwise only show up in xcodebuild.
if ! xcrun swiftc -O -swift-version 6 -strict-concurrency=complete -default-isolation MainActor \
        App/Browser/PageState.swift App/Browser/PageFailureText.swift \
        App/Network/SocksRelayPolicy.swift \
        "$OUT/main.swift" -o "$OUT/page-failure-text-tests" > "$OUT/build.log" 2>&1; then
    cat "$OUT/build.log" >&2
    echo "error: the page failure text host tests do not compile" >&2
    exit 1
fi
"$OUT/page-failure-text-tests"
