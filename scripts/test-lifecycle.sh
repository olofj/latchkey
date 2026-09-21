#!/usr/bin/env bash
# M6: lifecycle hardening on the L2 harness (PLAN M6.5, M6.7).
#
#   scripts/test-lifecycle.sh [--build]
#
# The app's real tsnet node joins testing/tsnet-harness and loads the fake
# dashboard; then its sockets are damaged by the app's own chaos hooks
# (-UITestShutdownTCPConnections, -UITestDefunctLoopback), and its process is
# frozen from the host with SIGSTOP while it sits in the background -- the
# closest a simulator gets to a suspended app (after app/scripts/
# test-lock-resume.sh, which needed a real tailnet). Needs no account.
#
#   1. preflight   refuse a real tailnet name in the test config (R10)
#   2. harness     self-test the tsnet harness host-side (make check), then
#                  start it with the fake dashboard
#   3. simulator   boot it, trust the test CA, fresh app container
#   4. freezer     stream the app's log; on each "Background:" line, with a
#                  freeze request from the test, SIGSTOP the app for the
#                  requested seconds, SIGCONT it, and report back
#   5. tests       LifecycleHarnessTests (Testing configuration, R15)
#   6. timings     what the app logged about each recovery, for the record
#   7. teardown    continue anything still frozen; stop everything
#
# The freezer and the tests meet in /tmp/latchkey-lifecycle: the test writes
# request.json ({id, seconds}) before pressing Home, the freezer writes
# result.json ({id, pid, seconds, stopped_at, continued_at}) after SIGCONT.
# The pid comes from the log line itself (compact style: Latchkey[<pid>:…]),
# so nothing here depends on ps or pgrep.
#
# --build runs build-for-testing first. Without it, the last test build is
# reused (scripts/test-offline.sh --build makes the same one).
#
# On failure: a screenshot, the harness logs, the app's log and the xcresult
# are left under app/build/lifecycle-logs/<timestamp>/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/app"
HARNESS="$ROOT/testing/harness"
TSNET="$ROOT/testing/tsnet-harness"
SIM_NAME="${SIM_NAME:-iPhone 17}"
FREEZER_DIR=/tmp/latchkey-lifecycle
BUILD=0
[[ "${1:-}" == "--build" ]] && BUILD=1

LOG_DIR="$APP/build/lifecycle-logs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR"
START=$(date +%s)
say() { printf '::: %s\n' "$*"; }

# ---------------------------------------------------------------- preflight --
say "preflight"
set +e
grep -rIl "example" "$APP/UITests/LifecycleHarnessTests.swift" "$TSNET"/*.go \
    "$TSNET/Makefile" "$HARNESS/leaf.cnf"
PRE_RC=$?
set -e
if [[ $PRE_RC -eq 0 ]]; then
    echo "error: the lifecycle test config references the real tailnet (example.ts.net)." >&2
    echo "       Use the fixture tailnet, tail-scale.ts.net." >&2
    exit 1
elif [[ $PRE_RC -ge 2 ]]; then
    echo "error: the preflight could not read a file it checks (renamed or missing?)" >&2
    exit 1
fi
EXPECTED=$(grep -cE '^\s*func test[A-Za-z0-9_]*\(' "$APP/UITests/LifecycleHarnessTests.swift" || true)
[[ "$EXPECTED" -gt 0 ]] || { echo "error: no tests found in LifecycleHarnessTests.swift" >&2; exit 1; }

# ------------------------------------------------------------------ harness --
LOG_PID=""; FREEZER_PID=""; XCODEBUILD_PID=""; WATCHDOG_PID=""
teardown() {
    for p in "$FREEZER_PID" "$WATCHDOG_PID" "$XCODEBUILD_PID"; do
        [[ -z "$p" ]] || { kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; } || true
    done
    # Never leave the app stopped: a frozen process outlives the test run.
    if [[ -f "$FREEZER_DIR/frozen.pid" ]]; then
        kill -CONT "$(cat "$FREEZER_DIR/frozen.pid")" 2>/dev/null || true
    fi
    [[ -z "$LOG_PID" ]] || kill "$LOG_PID" 2>/dev/null || true
    rm -f "$FREEZER_DIR/request.json" "$FREEZER_DIR/result.json" "$FREEZER_DIR/result.json.tmp" \
          "$FREEZER_DIR/frozen.pid"
    rmdir "$FREEZER_DIR" 2>/dev/null || true
    make -C "$TSNET" --no-print-directory down >/dev/null 2>&1 || true
}
trap teardown EXIT
# The self-test proves the harness, not the app: it reruns only when the
# harness changed since it last passed (shared with test-tailnet.sh).
VENDORED="$APP/ThirdParty/libtailscale/tailscale-patched"
SELFTEST_STAMP="$TSNET/.run/selftest.sha"
SELFTEST_HASH=$( { cat "$TSNET"/*.go "$TSNET"/go.mod "$TSNET"/go.sum "$TSNET"/Makefile
                   git -C "$APP" rev-parse HEAD:ThirdParty/libtailscale/tailscale-patched; } | shasum -a 256 | cut -d' ' -f1)
if [[ "${SELFTEST:-auto}" != always && -z "$(git -C "$APP" status --porcelain -- "$VENDORED")" \
      && -f "$SELFTEST_STAMP" && "$(cat "$SELFTEST_STAMP")" == "$SELFTEST_HASH" ]]; then
    say "tsnet harness self-test: skipped (unchanged since it last passed; SELFTEST=always forces it)"
else
    say "tsnet harness self-test"
    make -C "$TSNET" --no-print-directory check > "$LOG_DIR/selftest.log" 2>&1 \
        || { cat "$LOG_DIR/selftest.log" >&2; echo "error: the harness self-test failed" >&2; exit 1; }
    grep -E "^(==>|selftest)" "$LOG_DIR/selftest.log" | sed 's/^/    /'
    mkdir -p "$TSNET/.run" && echo "$SELFTEST_HASH" > "$SELFTEST_STAMP"
fi
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
# A fresh app container: the state each test starts from is the cold join.
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

# ------------------------------------------------------------------ freezer --
say "freezer (SIGSTOP on the app's Background log line, for the seconds the test asks)"
rm -f "$FREEZER_DIR/request.json" "$FREEZER_DIR/result.json" "$FREEZER_DIR/frozen.pid"
mkdir -p "$FREEZER_DIR"
UNIFIED="$LOG_DIR/unified.log"
FREEZER_LOG="$LOG_DIR/freezer.log"
: > "$UNIFIED"; : > "$FREEZER_LOG"
xcrun simctl spawn "$UDID" log stream --predicate 'subsystem == "net.lixom.latchkey"' \
    --level debug --style compact > "$UNIFIED" 2>&1 &
LOG_PID=$!
BACKGROUND_LINE='Background: leaving tsnet, proxy, and observers unchanged'
now() { python3 -c 'import time; print(time.time())'; }
freezer() {
    local seen=0 n line pid id seconds t0 t1
    while true; do
        n=$(grep -c "$BACKGROUND_LINE" "$UNIFIED" 2>/dev/null || true)
        if [[ "${n:-0}" -gt "$seen" ]]; then
            seen=$((seen + 1))
            line=$(grep "$BACKGROUND_LINE" "$UNIFIED" | sed -n "${seen}p")
            pid=$(sed -E 's/.*Latchkey\[([0-9]+):[0-9a-fA-F]+\].*/\1/' <<< "$line")
            if [[ ! -f "$FREEZER_DIR/request.json" ]]; then
                echo "$(now) background of pid $pid with no freeze request; ignored" >> "$FREEZER_LOG"
                continue
            fi
            if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
                echo "$(now) no pid in: $line" >> "$FREEZER_LOG"
                continue
            fi
            read -r id seconds < <(python3 -c 'import json, sys
r = json.load(open(sys.argv[1])); print(r["id"], int(r["seconds"]))' "$FREEZER_DIR/request.json")
            if ! kill -STOP "$pid" 2>>"$FREEZER_LOG"; then
                echo "$(now) SIGSTOP $pid failed" >> "$FREEZER_LOG"
                continue
            fi
            echo "$pid" > "$FREEZER_DIR/frozen.pid"
            t0=$(now)
            echo "$t0 pid $pid stopped for ${seconds}s (request $id)" >> "$FREEZER_LOG"
            sleep "$seconds"
            kill -CONT "$pid" 2>>"$FREEZER_LOG" || true
            t1=$(now)
            rm -f "$FREEZER_DIR/frozen.pid"
            python3 -c 'import json, sys
json.dump({"id": sys.argv[1], "pid": int(sys.argv[2]), "seconds": int(sys.argv[3]),
           "stopped_at": float(sys.argv[4]), "continued_at": float(sys.argv[5])}, open(sys.argv[6], "w"))' \
                "$id" "$pid" "$seconds" "$t0" "$t1" "$FREEZER_DIR/result.json.tmp"
            mv "$FREEZER_DIR/result.json.tmp" "$FREEZER_DIR/result.json"
            rm -f "$FREEZER_DIR/request.json"
            echo "$t1 pid $pid continued" >> "$FREEZER_LOG"
        fi
        sleep 0.1
    done
}
freezer &
FREEZER_PID=$!

# -------------------------------------------------------------------- tests --
say "LifecycleHarnessTests"
# A watchdog around xcodebuild: after an app crash mid-test it has sat for
# over ten minutes past the last test, past the per-test allowance, which
# would hang test-all.sh. The suite takes about four minutes.
SUITE_TIMEOUT=${SUITE_TIMEOUT:-480}
set +e
(cd "$APP" && exec xcodebuild test-without-building -project Latchkey.xcodeproj -scheme Latchkey \
    -configuration Testing -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath build/DerivedData -resultBundlePath "$LOG_DIR/tests.xcresult" \
    -parallel-testing-enabled NO -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 300 \
    -only-testing:LatchkeyUITests/LifecycleHarnessTests) > "$LOG_DIR/test.log" 2>&1 &
XCODEBUILD_PID=$!
( sleep "$SUITE_TIMEOUT"; echo "error: xcodebuild exceeded ${SUITE_TIMEOUT}s; killing it" >&2; kill "$XCODEBUILD_PID" 2>/dev/null ) &
WATCHDOG_PID=$!
wait "$XCODEBUILD_PID"
TEST_RC=$?
{ kill "$WATCHDOG_PID" 2>/dev/null; wait "$WATCHDOG_PID" 2>/dev/null; } || true
XCODEBUILD_PID=""; WATCHDOG_PID=""
set -e
grep -E "Test Case .*(passed|failed)" "$LOG_DIR/test.log" | sed 's/^/    /' || true
# A green xcodebuild is not enough: with a stale build or a wrong test name it
# runs NOTHING and exits 0 (M3 review). Every test in the file must pass.
PASSED=$(grep -cE "Test Case .*LifecycleHarnessTests.* passed" "$LOG_DIR/test.log" || true)
if [[ $TEST_RC -eq 0 && "$PASSED" -ne "$EXPECTED" ]]; then
    echo "error: $PASSED of $EXPECTED LifecycleHarnessTests passed (a stale build? try --build)" >&2
    TEST_RC=1
fi

# ------------------------------------------------------------------ timings --
# What each test measured (join, recovery, resume-to-fresh-request), and what
# the app logged about the recoveries and the freezes. For the record; the
# tests hold the budgets.
say "timings"
grep -h "^LIFECYCLE " "$LOG_DIR/test.log" | sed 's/^/    /' || true
grep -E "LocalAPI loopback (failure|recovered|replacement)|TCP chaos test|sockslog: restarting|sockslog: relay listener|proxyConfig: endpoint replaced|Proxy endpoint republished" "$UNIFIED" \
    | sed -E 's/^([^ ]+ [^ ]+) .*\] /    \1  /' || true
sed 's/^/    freezer: /' "$FREEZER_LOG" || true
# R30's instrument: the relay test must have made the app restart its relay
# listener, republish the endpoint and retry the failed page, by the app's own
# log. Without those lines the test passed on something else (a plain reload,
# say). Substrings only -- the exact wording is the app's to change.
if [[ $TEST_RC -eq 0 ]] && { ! grep -q "sockslog: restarting the relay listener" "$UNIFIED" \
        || ! grep -q "proxyConfig: endpoint replaced" "$UNIFIED" \
        || ! grep -q "retrying the failed page" "$UNIFIED"; }; then
    echo "error: the app's log shows no relay listener restart, endpoint republication and page retry (R30)" >&2
    TEST_RC=1
fi

# ------------------------------------------------------------------ summary --
ELAPSED=$(( $(date +%s) - START ))
if [[ $TEST_RC -ne 0 ]]; then
    xcrun simctl io "$UDID" screenshot "$LOG_DIR/failure.png" >/dev/null 2>&1 || true
    cp "$TSNET/.run/"*.log "$HARNESS/.run/"*.log "$LOG_DIR/" 2>/dev/null || true
    curl -s http://127.0.0.1:8491/state > "$LOG_DIR/harness-state.json" 2>/dev/null || true
    curl -s http://127.0.0.1:8480/__state > "$LOG_DIR/dashboard-state.json" 2>/dev/null || true
    say "FAILED in ${ELAPSED}s — logs, screenshot and xcresult in $LOG_DIR"
    exit 1
fi
say "passed in ${ELAPSED}s (budget: 300s)"
if [[ $ELAPSED -gt 300 ]]; then
    say "WARNING: over the 5-minute budget"
fi
