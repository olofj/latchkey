#!/bin/bash
# Host tests for the session layer's checks (M4, R30): every question
# SessionManager asks the page is bounded, and a page that answers nothing
# ends in "unanswered" -- which R30 acts on -- rather than in a check that
# never returns.
#
# Compiles the REAL App/Session/SessionManager.swift on the host: it needs
# only WebKit and Foundation, both of which macOS has. The page is a fake
# SessionHost whose fetch resolves only through the abort a timeout arms, so
# a caller that passes no timeout hangs exactly as the shipped connection
# did (open, answering nothing).
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
cp scripts/test-session-manager.swift "$OUT/main.swift"
# -O, as the other host tests (AGENTS.md); the isolation flags are the app's,
# so a `nonisolated` that is missing here is missing in xcodebuild too. The
# logger stub is the relay tests' (scripts/test-socks-relay-stubs.swift).
if ! xcrun swiftc -O -swift-version 6 -strict-concurrency=complete -default-isolation MainActor \
        App/Session/SessionManager.swift App/Session/TokenInput.swift App/Session/DashboardSignOut.swift \
        App/Browser/PageScriptSources.swift App/Logging/LogRedaction.swift scripts/test-socks-relay-stubs.swift \
        "$OUT/main.swift" -o "$OUT/session-manager-tests" > "$OUT/build.log" 2>&1; then
    cat "$OUT/build.log" >&2
    echo "error: the session manager host tests do not compile" >&2
    exit 1
fi
"$OUT/session-manager-tests"
