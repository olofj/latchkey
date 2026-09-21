#!/usr/bin/env bash
# L1: the offline harness suite (PLAN M2.9; revisions R9, R10, R11, R13).
#
#   scripts/test-offline.sh [--build]
#
# Runs the real app, a real WKWebView and the production proxy path against a
# stub SOCKS5 proxy and a fake dashboard on loopback. Needs no Tailscale
# account, no tailnet and no network. Steps:
#
#   1. preflight   R10: refuse if the test config names the real tailnet; warn
#                  (not fail) when the host's own Tailscale is up
#   2. certs       mint the test CA + leaf if needed
#   3. simulator   boot it, trust the test CA
#   4. harness     start the fake dashboard + stub proxy (controlled per test)
#   5. tests       xcodebuild test-without-building, OfflineHarnessTests
#   6. R1 check    no sign-in token anywhere in the app container's logs
#   7. teardown    stop the harness, whatever happened
#
# --build runs build-for-testing first (Testing configuration, R15). Without
# it, the last test build is reused, which is what the < 3 min budget assumes.
#
# On failure: a screenshot and the harness logs are left under
# app/build/offline-logs/<timestamp>/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/app"
HARNESS="$ROOT/testing/harness"
SIM_NAME="${SIM_NAME:-iPhone 17}"
BUNDLE="net.lixom.latchkey"
BUILD=0
[[ "${1:-}" == "--build" ]] && BUILD=1

LOG_DIR="$APP/build/offline-logs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR"
START=$(date +%s)
say() { printf '::: %s\n' "$*"; }

# ---------------------------------------------------------------- preflight --
say "preflight"
# R10: a real tailnet name in a test config is how a leak turns into a pass.
# grep exits 2 on a missing file, which must not read as "clean" (M3 review).
set +e
grep -rIl "example" "$APP/UITests/OfflineHarnessTests.swift" "$HARNESS"/*.py \
    "$HARNESS/Makefile" "$HARNESS/leaf.cnf"
PRE_RC=$?
set -e
if [[ $PRE_RC -eq 0 ]]; then
    echo "error: the offline test config references the real tailnet (example.ts.net)." >&2
    echo "       On this Mac those names route through the host's own VPN, so a leak" >&2
    echo "       would SUCCEED instead of failing. Use tail-scale.ts.net / localtest.me." >&2
    exit 1
elif [[ $PRE_RC -ge 2 ]]; then
    echo "error: the preflight could not read a file it checks (renamed or missing?)" >&2
    exit 1
fi
EXPECTED=$(grep -cE '^\s*func test[A-Za-z0-9_]*\(' "$APP/UITests/OfflineHarnessTests.swift")
if ifconfig 2>/dev/null | grep -A4 '^utun' | grep -qE 'inet 100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.'; then
    say "WARNING: the host's Tailscale is up (a utun interface holds a 100.64/10 address)."
    say "         Accepted (decision D7): the tests use no tailnet names or addresses,"
    say "         but leak coverage for tailnet *IP* destinations is limited on this host."
fi

# -------------------------------------------------------------------- certs --
say "certs"
make -C "$HARNESS" --no-print-directory certs >/dev/null

# ---------------------------------------------------------------- simulator --
say "simulator: $SIM_NAME"
UDID=$(xcrun simctl list devices available -j | python3 -c "
import json, sys
for devs in json.load(sys.stdin)['devices'].values():
    for d in devs:
        if d['name'] == '$SIM_NAME':
            print(d['udid']); sys.exit(0)
sys.exit(1)") || { echo "error: no simulator named $SIM_NAME" >&2; exit 1; }
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl keychain "$UDID" add-root-cert "$HARNESS/ca.der"
# A fresh app container, so R1's disk scan below reads only what THIS run
# wrote. Other suites (M4's session tests serve the real KiroCrew bundle,
# whose cached JS contains `?token=` in code) share the container otherwise.
# test-without-building installs the app again.
xcrun simctl uninstall "$UDID" "$BUNDLE" >/dev/null 2>&1 || true

# ------------------------------------------------------------------ harness --
teardown() {
    make -C "$HARNESS" --no-print-directory harness-down >/dev/null 2>&1 || true
}
trap teardown EXIT
say "harness"
make -C "$HARNESS" --no-print-directory harness-up

# -------------------------------------------------------------------- build --
SANDBOX_FLAGS=()
if ! sandbox-exec -p '(version 1)(allow default)' /usr/bin/true >/dev/null 2>&1; then
    SANDBOX_FLAGS=("OTHER_SWIFT_FLAGS=\$(inherited) -disable-sandbox")
fi
if [[ $BUILD -eq 1 ]]; then
    say "build-for-testing (Testing configuration)"
    (cd "$APP" && xcodebuild build-for-testing -project Latchkey.xcodeproj -scheme Latchkey \
        -configuration Testing -destination "platform=iOS Simulator,id=$UDID" \
        -derivedDataPath build/DerivedData "${SANDBOX_FLAGS[@]}" > "$LOG_DIR/build.log" 2>&1) \
        || { echo "error: build failed; see $LOG_DIR/build.log" >&2; exit 1; }
fi

# -------------------------------------------------------------------- tests --
# Two passes. The sign-in test runs LAST and alone, so R1's disk scan below
# sees the state it left: every other test launches with
# -UITestResetWorkspaces, which deletes the workspace data, and XCTest runs
# tests alphabetically, so a later test would erase the evidence (M2 review).
SIGNIN="LatchkeyUITests/OfflineHarnessTests/testSignInTokenIsStrippedFromTheAddress"
run_tests() {   # $1 = label, rest = -only-testing/-skip-testing args
    local label=$1; shift
    (cd "$APP" && xcodebuild test-without-building -project Latchkey.xcodeproj -scheme Latchkey \
        -configuration Testing -destination "platform=iOS Simulator,id=$UDID" \
        -derivedDataPath build/DerivedData -resultBundlePath "$LOG_DIR/$label.xcresult" \
        -parallel-testing-enabled NO -test-timeouts-enabled YES \
        -default-test-execution-time-allowance 120 "$@") > "$LOG_DIR/$label.log" 2>&1
}
say "OfflineHarnessTests"
set +e
run_tests suite -only-testing:LatchkeyUITests/OfflineHarnessTests -skip-testing:"$SIGNIN"
SUITE_RC=$?
run_tests signin -only-testing:"$SIGNIN"
SIGNIN_RC=$?
set -e
TEST_RC=$(( SUITE_RC | SIGNIN_RC ))
cat "$LOG_DIR/suite.log" "$LOG_DIR/signin.log" > "$LOG_DIR/test.log"
grep -E "Test Case .*(passed|failed)" "$LOG_DIR/test.log" | sed 's/^/    /' || true
# Both passes together must pass every test in the file: a stale build or a
# wrong name runs nothing and still exits 0 (M3 review).
PASSED=$(grep -cE "Test Case .*OfflineHarnessTests.* passed" "$LOG_DIR/test.log" || true)
if [[ $TEST_RC -eq 0 && "$PASSED" -ne "$EXPECTED" ]]; then
    echo "error: $PASSED of $EXPECTED OfflineHarnessTests passed (a stale build? try --build)" >&2
    TEST_RC=1
fi

# ----------------------------------------------------------------- R1 check --
# testSignInTokenIsStrippedFromTheAddress loads /?token=OFFLINE-TEST-TOKEN-7f3a
# through the real app, so after the suite a token has genuinely passed
# through. Nothing written by the app may contain it, or any `token=`.
say "R1: no sign-in token in the app container's logs"
CONTAINER=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data 2>/dev/null || true)
LEAK_RC=0
if [[ -n "$CONTAINER" ]]; then
    # Everything the app can write: all of Library (Application Support,
    # WebKit's website data and caches, Cookies, HTTPStorages, Preferences)
    # and tmp. -a so binary stores (SQLite, the HTTP cache) are searched too;
    # the page no longer carries the token as a literal, so a hit is real.
    if grep -rla -e "OFFLINE-TEST-TOKEN" -e "token=" "$CONTAINER/Library" "$CONTAINER/tmp" \
            2>/dev/null > "$LOG_DIR/token-leaks.txt"; then
        echo "error: a sign-in token was written to disk:" >&2
        sed "s|$CONTAINER/|    |" "$LOG_DIR/token-leaks.txt" >&2
        LEAK_RC=1
    else
        # Not vacuous only if the sign-in run left WebKit data to search.
        WK_FILES=$(find "$CONTAINER/Library/WebKit" -type f 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$WK_FILES" -eq 0 ]]; then
            echo "error: no WebKit data on disk after the sign-in test, so the disk scan" >&2
            echo "       searched nothing. Did the sign-in test run last?" >&2
            LEAK_RC=1
        else
            echo "    ok (disk: all of Library + tmp, $WK_FILES WebKit files among them)"
        fi
    fi
    # The unified log is the other place the app writes. Scan this run's.
    xcrun simctl spawn "$UDID" log show --last "$(( $(date +%s) - START + 30 ))s" \
        --predicate "subsystem == \"$BUNDLE\"" --style compact > "$LOG_DIR/unified.log" 2>/dev/null || true
    if grep -e "OFFLINE-TEST-TOKEN" -e "token=" "$LOG_DIR/unified.log" > "$LOG_DIR/token-in-os-log.txt"; then
        echo "error: a sign-in token reached the unified log:" >&2
        sed 's/^/    /' "$LOG_DIR/token-in-os-log.txt" | head -5 >&2
        LEAK_RC=1
    else
        echo "    ok (unified log: $(wc -l < "$LOG_DIR/unified.log" | tr -d ' ') lines scanned)"
    fi
    # Validate the instrument: a grep that finds nothing proves nothing unless
    # the token URL was actually logged. The sign-in test runs with
    # -UITestLogResponses, which logs every navigation URL, so its REDACTED
    # form must be present. If it is missing, the check above was vacuous.
    if grep -q 'RESP-LOG action: https://dash.tail-scale.ts.net/?…' "$LOG_DIR/unified.log"; then
        echo "    ok (validated: the sign-in URL was logged, in redacted form)"
    else
        echo "error: the redacted sign-in navigation is not in the log, so the token" >&2
        echo "       check proved nothing. Did testSignInTokenIsStrippedFromTheAddress run" >&2
        echo "       with -UITestLogResponses?" >&2
        LEAK_RC=1
    fi
else
    echo "    skipped: app container not found (was the app installed?)"
fi

# ------------------------------------------------------------------ summary --
ELAPSED=$(( $(date +%s) - START ))
if [[ $TEST_RC -ne 0 || $LEAK_RC -ne 0 ]]; then
    xcrun simctl io "$UDID" screenshot "$LOG_DIR/failure.png" >/dev/null 2>&1 || true
    cp "$HARNESS/.run/"*.log "$LOG_DIR/" 2>/dev/null || true
    say "FAILED in ${ELAPSED}s — logs, screenshot and xcresult in $LOG_DIR"
    exit 1
fi
say "passed in ${ELAPSED}s (budget: 180s)"
if [[ $ELAPSED -gt 180 ]]; then
    say "WARNING: over the M2 budget of 3 minutes"
fi
