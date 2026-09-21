#!/usr/bin/env bash
# L2: the real tsnet node against a fake control plane (PLAN M3, revision R17).
#
#   scripts/test-tailnet.sh [--build]
#
# The app's embedded node joins testing/tsnet-harness -- testcontrol with
# MagicDNS, DERP/STUN on loopback and two tsnet peers -- and loads the fake
# dashboard over the tailnet. Needs no Tailscale account and no network.
#
#   1. preflight   refuse a real tailnet name in the test config (R10)
#   2. harness     self-test the tsnet harness host-side (make check), then
#                  start it with the fake dashboard
#   3. simulator   boot it, trust the test CA
#   4. tests       TailnetHarnessTests (Testing configuration, R15)
#   5. teardown    stop both harnesses, whatever happened
#
# --build runs build-for-testing first. Without it, the last test build is
# reused (scripts/test-offline.sh --build makes the same one).
#
# On failure: a screenshot, the harness logs and the xcresult are left under
# app/build/tailnet-logs/<timestamp>/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/app"
HARNESS="$ROOT/testing/harness"
TSNET="$ROOT/testing/tsnet-harness"
SIM_NAME="${SIM_NAME:-iPhone 17}"
BUILD=0
[[ "${1:-}" == "--build" ]] && BUILD=1

LOG_DIR="$APP/build/tailnet-logs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR"
START=$(date +%s)
say() { printf '::: %s\n' "$*"; }

# ---------------------------------------------------------------- preflight --
say "preflight"
# grep exits 1 for "no match" and 2 for an error such as a missing file --
# and 2 must not read as "clean" (M3 review).
set +e
grep -rIl "example" "$APP/UITests/TailnetHarnessTests.swift" "$TSNET"/*.go \
    "$TSNET/Makefile" "$HARNESS/leaf.cnf"
PRE_RC=$?
set -e
if [[ $PRE_RC -eq 0 ]]; then
    echo "error: the L2 test config references the real tailnet (example.ts.net)." >&2
    echo "       Use the fixture tailnet, tail-scale.ts.net." >&2
    exit 1
elif [[ $PRE_RC -ge 2 ]]; then
    echo "error: the preflight could not read a file it checks (renamed or missing?)" >&2
    exit 1
fi
EXPECTED=$(grep -cE '^\s*func test[A-Za-z0-9_]*\(' "$APP/UITests/TailnetHarnessTests.swift")

# ------------------------------------------------------------------ harness --
teardown() {
    make -C "$TSNET" --no-print-directory down >/dev/null 2>&1 || true
}
trap teardown EXIT
say "tsnet harness self-test"
make -C "$TSNET" --no-print-directory check > "$LOG_DIR/selftest.log" 2>&1 \
    || { cat "$LOG_DIR/selftest.log" >&2; echo "error: the harness self-test failed" >&2; exit 1; }
grep -E "^(==>|selftest)" "$LOG_DIR/selftest.log" | sed 's/^/    /'
say "harness up"
make -C "$TSNET" --no-print-directory up

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
say "TailnetHarnessTests"
set +e
(cd "$APP" && xcodebuild test-without-building -project Latchkey.xcodeproj -scheme Latchkey \
    -configuration Testing -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath build/DerivedData -resultBundlePath "$LOG_DIR/tests.xcresult" \
    -parallel-testing-enabled NO -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 180 \
    -only-testing:LatchkeyUITests/TailnetHarnessTests) > "$LOG_DIR/test.log" 2>&1
TEST_RC=$?
set -e
grep -E "Test Case .*(passed|failed)" "$LOG_DIR/test.log" | sed 's/^/    /' || true
# A green xcodebuild is not enough: with a stale build or a wrong test name it
# runs NOTHING and exits 0 (M3 review). Every test in the file must pass.
PASSED=$(grep -cE "Test Case .*TailnetHarnessTests.* passed" "$LOG_DIR/test.log" || true)
if [[ $TEST_RC -eq 0 && "$PASSED" -ne "$EXPECTED" ]]; then
    echo "error: $PASSED of $EXPECTED TailnetHarnessTests passed (a stale build? try --build)" >&2
    TEST_RC=1
fi

# ------------------------------------------------------------------ summary --
ELAPSED=$(( $(date +%s) - START ))
if [[ $TEST_RC -ne 0 ]]; then
    xcrun simctl io "$UDID" screenshot "$LOG_DIR/failure.png" >/dev/null 2>&1 || true
    cp "$TSNET/.run/"*.log "$HARNESS/.run/"*.log "$LOG_DIR/" 2>/dev/null || true
    curl -s http://127.0.0.1:8491/state > "$LOG_DIR/harness-state.json" 2>/dev/null || true
    say "FAILED in ${ELAPSED}s — logs, screenshot and xcresult in $LOG_DIR"
    exit 1
fi
say "passed in ${ELAPSED}s (budget: 300s)"
if [[ $ELAPSED -gt 300 ]]; then
    say "WARNING: over the L2 budget of 5 minutes"
fi
