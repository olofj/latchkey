#!/bin/bash
# Host tests for the SOCKS relay's housekeeping (R30): the session cap, the
# restart verdict and its budget, then the real relay over loopback against
# a fake upstream that accepts and never answers.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -r "$OUT"' EXIT
cp scripts/test-socks-relay-policy.swift "$OUT/main.swift"
# -O, as the other host tests: they catch optimizer-only bugs (AGENTS.md).
# The isolation flags are the app's (project.pbxproj): the relay runs off the
# main actor, and a missing `nonisolated` would otherwise only show up in
# xcodebuild.
if ! xcrun swiftc -O -swift-version 6 -strict-concurrency=complete -default-isolation MainActor \
        App/Network/SocksRelayPolicy.swift TSNet/SocksLogProxy.swift App/TestHooks.swift \
        scripts/test-socks-relay-stubs.swift \
        "$OUT/main.swift" -o "$OUT/socks-relay-tests" > "$OUT/build.log" 2>&1; then
    cat "$OUT/build.log" >&2
    echo "error: the SOCKS relay host tests do not compile" >&2
    exit 1
fi
"$OUT/socks-relay-tests"
