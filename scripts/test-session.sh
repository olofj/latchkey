#!/usr/bin/env bash
# M4: the dashboard session against KiroCrew's REAL 0.6.0 frontend (R19).
#
#   scripts/test-session.sh [--build]
#
# The app reaches testing/harness/fake_gateway.py -- which serves the installed
# KiroCrew bundle, pinned, and emulates the server's auth contract -- through
# the offline harness's stub proxy, as in L1. Needs no Tailscale account and
# no real gateway, and mints nothing real: the fake's credentials are its own.
#
#   1. preflight   refuse a real tailnet name in the test config (R10)
#   2. gateway     the bundle pin/smoke test, then the fake's host-side
#                  contract self-test (make gateway-check)
#   3. harness     the stub proxy and the fake gateway, up
#   4. simulator   boot it, trust the test CA
#   5. tests       SessionTests (Testing configuration, R15); every test in
#                  the file must pass
#   6. teardown    whatever happened
#
# --build runs build-for-testing first.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/app"
HARNESS="$ROOT/testing/harness"
SIM_NAME="${SIM_NAME:-iPhone 17}"
BUILD=0
[[ "${1:-}" == "--build" ]] && BUILD=1

LOG_DIR="$APP/build/session-logs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR"
START=$(date +%s)
say() { printf '::: %s\n' "$*"; }

# ---------------------------------------------------------------- preflight --
say "preflight"
# R10: only the fixture tailnets may be named (allow-list, not deny-list).
"$ROOT/scripts/check-fixture-tailnets.sh" \
    "$APP/UITests/SessionTests.swift" "$HARNESS/fake_gateway.py" \
    "$HARNESS/gateway_check.py" "$HARNESS/Makefile" "$HARNESS/leaf.cnf"
EXPECTED=$(grep -cE '^\s*func test[A-Za-z0-9_]*\(' "$APP/UITests/SessionTests.swift")

# ------------------------------------------------------------------ gateway --
teardown() {
    make -C "$HARNESS" --no-print-directory gateway-down >/dev/null 2>&1 || true
    make -C "$HARNESS" --no-print-directory harness-down >/dev/null 2>&1 || true
}
trap teardown EXIT
say "bundle pin and smoke test (R19)"
python3 "$HARNESS/fake_gateway.py" --check-bundle | sed 's/^/    /'
say "fake gateway contract self-test"
make -C "$HARNESS" --no-print-directory gateway-check > "$LOG_DIR/gateway-check.log" 2>&1 \
    || { cat "$LOG_DIR/gateway-check.log" >&2; echo "error: the fake gateway's self-test failed" >&2; exit 1; }
tail -1 "$LOG_DIR/gateway-check.log" | sed 's/^/    /'

say "harness up"
make -C "$HARNESS" --no-print-directory harness-up
make -C "$HARNESS" --no-print-directory gateway-up

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
# A fresh app container, so the R1 scan below reads only this run's data.
xcrun simctl uninstall "$UDID" net.lixom.latchkey >/dev/null 2>&1 || true

# -------------------------------------------------------------------- build --
SANDBOX_FLAGS=()
if ! sandbox-exec -p '(version 1)(allow default)' /usr/bin/true >/dev/null 2>&1; then
    SANDBOX_FLAGS=("OTHER_SWIFT_FLAGS=\$(inherited) -disable-sandbox")
fi
if [[ $BUILD -eq 1 ]]; then
    # A vendored Go change is only in the app once the framework is rebuilt
    # (R29 shipped a stale one); a no-op when it is current.
    say "TailscaleKit framework (rebuilds only if libtailscale changed; minutes if so)"
    make -C "$APP" --no-print-directory framework > "$LOG_DIR/framework.log" 2>&1 \
        || { echo "error: TailscaleKit framework build failed; see $LOG_DIR/framework.log" >&2; exit 1; }
    say "build-for-testing (Testing configuration)"
    (cd "$APP" && xcodebuild build-for-testing -project Latchkey.xcodeproj -scheme Latchkey \
        -configuration Testing -destination "platform=iOS Simulator,id=$UDID" \
        -derivedDataPath build/DerivedData "${SANDBOX_FLAGS[@]}" > "$LOG_DIR/build.log" 2>&1) \
        || { echo "error: build failed; see $LOG_DIR/build.log" >&2; exit 1; }
fi

# -------------------------------------------------------------------- tests --
say "SessionTests"
set +e
(cd "$APP" && xcodebuild test-without-building -project Latchkey.xcodeproj -scheme Latchkey \
    -configuration Testing -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath build/DerivedData -resultBundlePath "$LOG_DIR/tests.xcresult" \
    -parallel-testing-enabled NO -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 240 \
    -only-testing:LatchkeyUITests/SessionTests) > "$LOG_DIR/test.log" 2>&1
TEST_RC=$?
set -e
grep -E "Test Case .*(passed|failed)" "$LOG_DIR/test.log" | sed 's/^/    /' || true
PASSED=$(grep -cE "Test Case .*SessionTests.* passed" "$LOG_DIR/test.log" || true)
if [[ $TEST_RC -eq 0 && "$PASSED" -ne "$EXPECTED" ]]; then
    echo "error: $PASSED of $EXPECTED SessionTests passed (a stale build? try --build)" >&2
    TEST_RC=1
fi

# ----------------------------------------------------------------- R1 check --
# The tests redeem sign-in links (the fake's are `fk1.…`) through the real
# SPA. A link is a credential for 300 s: nothing the app writes may hold one.
# (The session and refresh COOKIES are on disk by design -- that is the
# session.) Validated: the app must have logged at least one redemption, or
# the scan proved nothing.
say "R1: no sign-in link in the app container or its log"
LEAK_RC=0
CONTAINER=$(xcrun simctl get_app_container "$UDID" net.lixom.latchkey data 2>/dev/null || true)
xcrun simctl spawn "$UDID" log show --last "$(( $(date +%s) - START + 30 ))s" \
    --predicate 'subsystem == "net.lixom.latchkey"' --style compact > "$LOG_DIR/unified.log" 2>/dev/null || true
# grep exits 0 on a match, 1 on none and 2 on an error -- and `if grep ...;
# then leak; else ok` read 1 and 2 alike as ok, so an unreadable file or a
# missing directory printed "ok" over a real hit (review, 2026-09-23: grep
# returns 2 even when it also matched). scan keeps the three apart: matches
# go to the named file, errors are shown, and the status is grep's own.
scan() {  # outfile, grep args...
    local out=$1 rc=0; shift
    grep "$@" > "$out" 2> "$out.err" || rc=$?
    if [[ $rc -ge 2 ]]; then
        echo "error: the scan could not read everything it was asked to (grep exit $rc):" >&2
        sed 's/^/    /' "$out.err" | head -5 >&2
    fi
    return $rc
}
if [[ -z "$CONTAINER" ]]; then
    echo "error: app container not found" >&2; LEAK_RC=1
else
    SCAN_RC=0
    scan "$LOG_DIR/link-leaks.txt" -rla "fk1\." "$CONTAINER/Library" "$CONTAINER/tmp" || SCAN_RC=$?
    if [[ -s "$LOG_DIR/link-leaks.txt" ]]; then
        echo "error: a sign-in link was written to disk:" >&2
        sed "s|$CONTAINER/|    |" "$LOG_DIR/link-leaks.txt" >&2
        LEAK_RC=1
    fi
    if [[ $SCAN_RC -ge 2 ]]; then
        echo "error: the disk scan is incomplete, so 'no link on disk' is not established" >&2
        LEAK_RC=1
    elif [[ $SCAN_RC -eq 1 ]]; then
        # Not vacuous only if there is web data to search. SessionTests
        # launch with -UITestKeepWebData, so every test's data store is
        # still here, not only the last one's.
        WK_FILES=$(find "$CONTAINER/Library/WebKit" -type f 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$WK_FILES" -eq 0 ]]; then
            echo "error: no WebKit data in the container, so the disk scan searched nothing" >&2
            LEAK_RC=1
        else
            echo "    ok (disk: all of Library + tmp, $WK_FILES WebKit files among them)"
        fi
    fi
    SCAN_RC=0
    scan "$LOG_DIR/link-in-os-log.txt" -e "fk1\." -e "token=" "$LOG_DIR/unified.log" || SCAN_RC=$?
    if [[ -s "$LOG_DIR/link-in-os-log.txt" ]]; then
        echo "error: a sign-in link reached the unified log:" >&2
        head -5 "$LOG_DIR/link-in-os-log.txt" | sed 's/^/    /' >&2
        LEAK_RC=1
    fi
    if [[ $SCAN_RC -ge 2 ]]; then
        echo "error: the unified-log scan is incomplete" >&2
        LEAK_RC=1
    elif [[ $SCAN_RC -eq 1 ]]; then
        echo "    ok (unified log: $(wc -l < "$LOG_DIR/unified.log" | tr -d ' ') lines)"
    fi
    N=$(grep -c "Session: redeeming a token" "$LOG_DIR/unified.log" || true)
    if [[ "$N" -lt 1 ]]; then
        echo "error: no redemption was logged, so the scan proved nothing" >&2
        LEAK_RC=1
    else
        echo "    ok (validated: $N redemptions passed through the app)"
    fi
fi
[[ $LEAK_RC -eq 0 ]] || TEST_RC=1

# ------------------------------------------------------------------ summary --
ELAPSED=$(( $(date +%s) - START ))
curl -s http://127.0.0.1:8481/__state > "$LOG_DIR/gateway-state.json" 2>/dev/null || true
if [[ $TEST_RC -ne 0 ]]; then
    xcrun simctl io "$UDID" screenshot "$LOG_DIR/failure.png" >/dev/null 2>&1 || true
    cp "$HARNESS/.run/"*.log "$LOG_DIR/" 2>/dev/null || true
    say "FAILED in ${ELAPSED}s — logs, screenshot and xcresult in $LOG_DIR"
    exit 1
fi
say "passed in ${ELAPSED}s"
