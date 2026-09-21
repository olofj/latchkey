#!/usr/bin/env bash
# M5: gateway discovery on the L2 harness (revision R26).
#
#   scripts/test-discovery.sh [--build]
#
# The app's real node joins testing/tsnet-harness started with two extra
# peers -- gw (forwarding to the fake KiroCrew gateway) and slow (accepts,
# never answers) -- beside dash and plain, and discovers, chooses and loads
# the gateway. Needs the installed KiroCrew bundle for the fake gateway (as
# scripts/test-session.sh does), so it is kept out of test-tailnet.sh.
#
#   1. preflight   refuse a real tailnet name in the test config (R10)
#   2. harness     the tsnet harness with gw and slow, the fake dashboard,
#                  and the fake gateway
#   3. simulator   boot it, trust the test CA
#   4. tests       DiscoveryTests (Testing configuration, R15)
#   5. teardown    stop everything, whatever happened
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

LOG_DIR="$APP/build/discovery-logs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR"
START=$(date +%s)
say() { printf '::: %s\n' "$*"; }

# ---------------------------------------------------------------- preflight --
say "preflight"
# grep exits 1 for "no match" and 2 for an error such as a missing file --
# and 2 must not read as "clean" (M3 review).
set +e
grep -rIl "example" "$APP/UITests/DiscoveryTests.swift" "$TSNET"/*.go \
    "$TSNET/Makefile" "$HARNESS/leaf.cnf" "$APP/App/Discovery"
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
EXPECTED=$(grep -cE '^\s*func test[A-Za-z0-9_]*\(' "$APP/UITests/DiscoveryTests.swift")

# ------------------------------------------------------------------ harness --
teardown() {
    make -C "$HARNESS" --no-print-directory gateway-down >/dev/null 2>&1 || true
    make -C "$TSNET" --no-print-directory down >/dev/null 2>&1 || true
}
trap teardown EXIT
say "bundle pin (the fake gateway serves the real KiroCrew bundle)"
python3 "$HARNESS/fake_gateway.py" --check-bundle | sed 's/^/    /'
say "harness up (tsnet harness with gw and slow peers, fake dashboard, fake gateway)"
make -C "$TSNET" --no-print-directory up HARNESS_ARGS="-gateway 127.0.0.1:8444 -slow-peer"
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
say "DiscoveryTests"
set +e
(cd "$APP" && xcodebuild test-without-building -project Latchkey.xcodeproj -scheme Latchkey \
    -configuration Testing -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath build/DerivedData -resultBundlePath "$LOG_DIR/tests.xcresult" \
    -parallel-testing-enabled NO -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 180 \
    -only-testing:LatchkeyUITests/DiscoveryTests) > "$LOG_DIR/test.log" 2>&1
TEST_RC=$?
set -e
grep -E "Test Case .*(passed|failed)" "$LOG_DIR/test.log" | sed 's/^/    /' || true
# A green xcodebuild is not enough: with a stale build or a wrong test name it
# runs NOTHING and exits 0 (M3 review). Every test in the file must pass.
PASSED=$(grep -cE "Test Case .*DiscoveryTests.* passed" "$LOG_DIR/test.log" || true)
if [[ $TEST_RC -eq 0 && "$PASSED" -ne "$EXPECTED" ]]; then
    echo "error: $PASSED of $EXPECTED DiscoveryTests passed (a stale build? try --build)" >&2
    TEST_RC=1
fi

# ------------------------------------------------------------------ summary --
ELAPSED=$(( $(date +%s) - START ))
if [[ $TEST_RC -ne 0 ]]; then
    xcrun simctl io "$UDID" screenshot "$LOG_DIR/failure.png" >/dev/null 2>&1 || true
    cp "$TSNET/.run/"*.log "$HARNESS/.run/"*.log "$LOG_DIR/" 2>/dev/null || true
    curl -s http://127.0.0.1:8491/state > "$LOG_DIR/harness-state.json" 2>/dev/null || true
    curl -s http://127.0.0.1:8481/__state > "$LOG_DIR/gateway-state.json" 2>/dev/null || true
    xcrun simctl spawn "$UDID" log show --last 10m --predicate 'subsystem == "net.lixom.latchkey"' \
        --style compact 2>/dev/null | grep -i "discovery" > "$LOG_DIR/discovery.log" || true
    say "FAILED in ${ELAPSED}s — logs, screenshot and xcresult in $LOG_DIR"
    exit 1
fi
# R26's instrument: the app logs each sweep's timings. Every sweep must end
# inside 10 s and find its first gateway inside 5 s; at least one sweep must
# have found a gateway, or the check measured nothing.
say "R26 timing, from the app's own log"
xcrun simctl spawn "$UDID" log show --last "$(( $(date +%s) - START + 30 ))s" \
    --predicate 'subsystem == "net.lixom.latchkey"' --style compact 2>/dev/null \
    | grep "Discovery: [0-9]* gateway" > "$LOG_DIR/sweeps.log" || true
if ! python3 - "$LOG_DIR/sweeps.log" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().splitlines()
bad, found = [], 0
for l in lines:
    m = re.search(r"Discovery: (\d+) gateway\(s\); first after (\S+?)(?: ms)?, sweep (\d+) ms", l)
    if not m:
        continue
    n, first, sweep = int(m.group(1)), m.group(2), int(m.group(3))
    print("    %d gateway(s), first %s, sweep %d ms" % (n, first + (" ms" if first != "—" else ""), sweep))
    if sweep > 10000 or (n and first != "—" and int(first) > 5000):
        bad.append(l)
    found += n > 0
if not lines or not found:
    print("error: no sweep that found a gateway was logged; the timing check measured nothing")
    sys.exit(1)
if bad:
    print("error: over R26's budget (first <= 5 s, sweep <= 10 s):")
    for l in bad:
        print("  " + l)
    sys.exit(1)
PY
then
    TIMING_RC=1
else
    TIMING_RC=0
fi
if [[ $TIMING_RC -ne 0 ]]; then
    say "FAILED: R26 timing"
    exit 1
fi
say "passed in ${ELAPSED}s"
