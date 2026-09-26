#!/usr/bin/env bash
# L1: the offline harness suite (PLAN M2.9; revisions R9, R10, R11, R13).
#
#   scripts/test-offline.sh [--build] [--serial | --shards N]
#
# By default L1 runs across 4 simulators at once (F14 stage 2):
# scripts/test-offline-shards.py builds once, creates and boots "Latchkey
# Shard 1..N" if they are not booted, runs this script on each as a worker
# with its share of the tests, and gives one verdict. The shard simulators
# stay booted between runs; `scripts/test-offline-shards.py sims down` shuts
# them down (`sims delete` removes them). --shards N or LATCHKEY_SHARDS=N
# picks N (2-9).
#
# --serial runs everything on one simulator, SIM_NAME (default "iPhone 17"),
# as before F14; use it on a host with room for one simulator. Naming a
# simulator (SIM_NAME) or an instance (LATCHKEY_INSTANCE) also means serial.
#
# Runs the real app, a real WKWebView and the production proxy path against a
# stub SOCKS5 proxy and a fake dashboard on loopback. Needs no Tailscale
# account, no tailnet and no network. Steps:
#
#   1. preflight   R10: refuse if the test config names the real tailnet; warn
#                  (not fail) when the host's own Tailscale is up
#   2. certs       mint the test CA + leaf if needed
#   3. simulator   boot it, trust the test CA
#   4. harness     self-test the harness host-side (make check: R10's curl
#                  mechanics, the silent-client lesson, page_check.js), then
#                  start the fake dashboard + stub proxy (controlled per test)
#   5. tests       xcodebuild test-without-building, OfflineHarnessTests
#   6. R1 check    no sign-in token anywhere in the app container's logs
#   7. teardown    stop the harness, whatever happened
#
# --build runs build-for-testing first (Testing configuration, R15). Without
# it, the last test build is reused, which is what the < 4 min budget assumes.
#
# On failure: a screenshot and the harness logs are left under
# app/build/offline-logs/<timestamp>/.
#
# LATCHKEY_INSTANCE=k (0-9, default 0) runs against harness instance k, on
# its own ports (testing/harness/Makefile, F14), so two runs can share the
# host. Give each its own simulator with SIM_NAME, and build once beforehand:
# two --build runs at once would race in one DerivedData.
#
# As a shard worker (test-offline-shards.py sets these): LATCHKEY_SHARD_TESTS
# names the tests to run, LATCHKEY_XCTESTRUN the built .xctestrun to run them
# from, LATCHKEY_LOG_DIR where the logs go. --build-only builds and exits.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/app"
HARNESS="$ROOT/testing/harness"
BUILD=0; BUILD_ONLY=0; SHARDS="${LATCHKEY_SHARDS:-4}"
[[ -n "${SIM_NAME:-}${LATCHKEY_INSTANCE:-}" ]] && SHARDS=1
while [[ $# -gt 0 ]]; do
    case $1 in
        --build) BUILD=1 ;;
        --build-only) BUILD=1; BUILD_ONLY=1 ;;
        --serial) SHARDS=1 ;;
        --shards) SHARDS=${2:-}; shift ;;
        *) echo "usage: $0 [--build] [--serial | --shards N]" >&2; exit 2 ;;
    esac
    shift
done
[[ "$SHARDS" =~ ^[1-9]$ ]] || { echo "error: the shard count must be 1-9, not '$SHARDS'" >&2; exit 1; }
SHARD_TESTS="${LATCHKEY_SHARD_TESTS:-}"
if [[ $SHARDS -gt 1 && -z "$SHARD_TESTS" && $BUILD_ONLY -eq 0 ]]; then
    exec python3 "$ROOT/scripts/test-offline-shards.py" --shards "$SHARDS" \
        $([[ $BUILD -eq 1 ]] && echo --build)
fi
SIM_NAME="${SIM_NAME:-iPhone 17}"
BUNDLE="net.lixom.latchkey"
INSTANCE="${LATCHKEY_INSTANCE:-0}"
[[ "$INSTANCE" =~ ^[0-9]$ ]] || { echo "error: LATCHKEY_INSTANCE must be 0-9, not '$INSTANCE'" >&2; exit 1; }
HMAKE=(make -C "$HARNESS" --no-print-directory INSTANCE="$INSTANCE")
XCTESTRUN="${LATCHKEY_XCTESTRUN:-}"
if [[ -n "$SHARD_TESTS" && ( $BUILD -eq 1 || -z "$XCTESTRUN" ) ]]; then
    echo "error: a shard worker runs a prebuilt LATCHKEY_XCTESTRUN and never builds" >&2; exit 1
fi

LOG_DIR="${LATCHKEY_LOG_DIR:-$APP/build/offline-logs/$(date +%Y%m%d-%H%M%S)}"
[[ -n "${LATCHKEY_LOG_DIR:-}" || "$INSTANCE" == 0 ]] || LOG_DIR+="-i$INSTANCE"
mkdir -p "$LOG_DIR"
START=$(date +%s)
say() { printf '::: %s\n' "$*"; }

# ---------------------------------------------------------------- preflight --
say "preflight"
# R10: a real tailnet name in a test config is how a leak turns into a pass.
# The check allow-lists the fixture tailnets rather than naming one real one,
# so it protects every checkout and not just its author's.
"$ROOT/scripts/check-fixture-tailnets.sh" \
    "$APP/UITests/OfflineHarnessTests.swift" "$HARNESS"/*.py \
    "$HARNESS/Makefile" "$HARNESS/leaf.cnf"
if [[ -n "$SHARD_TESTS" ]]; then
    read -ra TESTS <<< "$SHARD_TESTS"
    EXPECTED=${#TESTS[@]}
else
    EXPECTED=$(grep -cE '^\s*func test[A-Za-z0-9_]*\(' "$APP/UITests/OfflineHarnessTests.swift")
fi
if ifconfig 2>/dev/null | grep -A4 '^utun' | grep -qE 'inet 100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.'; then
    say "WARNING: the host's Tailscale is up (a utun interface holds a 100.64/10 address)."
    say "         Accepted (decision D7): the tests use no tailnet names or addresses,"
    say "         but leak coverage for tailnet *IP* destinations is limited on this host."
fi

# -------------------------------------------------------------------- certs --
say "certs"
"${HMAKE[@]}" certs >/dev/null

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
    # The commit, stamped as make tf stamps it (F12), so Status has a row to
    # show; -dirty when the tree is, since a test build is taken from disk.
    GIT_SHA=$(git -C "$ROOT" rev-parse --short=12 HEAD)
    [[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=all)" ]] || GIT_SHA+=-dirty
    say "build-for-testing (Testing configuration, commit $GIT_SHA)"
    (cd "$APP" && xcodebuild build-for-testing -project Latchkey.xcodeproj -scheme Latchkey \
        -configuration Testing -destination "platform=iOS Simulator,id=$UDID" \
        -derivedDataPath build/DerivedData LATCHKEY_GIT_SHA="$GIT_SHA" \
        "${SANDBOX_FLAGS[@]}" > "$LOG_DIR/build.log" 2>&1) \
        || { echo "error: build failed; see $LOG_DIR/build.log" >&2; exit 1; }
    if [[ $BUILD_ONLY -eq 1 ]]; then
        say "built in $(( $(date +%s) - START ))s"
        exit 0
    fi
fi

# ------------------------------------------------------------------ harness --
teardown() {
    "${HMAKE[@]}" harness-down >/dev/null 2>&1 || true
}
trap teardown EXIT
# The harness's own self-test first. It proves the fixtures the tests below
# lean on -- that a blackholed CONNECT fails and a direct load of the leak
# origin succeeds (R10's positive control), that a silent client stalls
# nobody, that the page reconnects the way KiroCrew's does -- and until
# 2026-09-23 nothing ran it (review): it existed, and the suite went straight
# to harness-up. It costs about a second, so it runs every time; the cost is
# printed so it stays honest. (The tsnet harness's self-test in
# test-tailnet.sh is minutes, which is why that one is stamped and skipped.)
say "harness self-test (make check)"
T0=$(date +%s)
"${HMAKE[@]}" check > "$LOG_DIR/harness-check.log" 2>&1 \
    || { cat "$LOG_DIR/harness-check.log" >&2; echo "error: the offline harness's self-test failed" >&2; exit 1; }
CHECKS=$(grep -c '^==>' "$LOG_DIR/harness-check.log" || true)
if [[ "$CHECKS" -lt 1 ]]; then
    echo "error: the harness self-test ran no checks (its log is $LOG_DIR/harness-check.log)" >&2; exit 1
fi
echo "    ok ($CHECKS checks in $(( $(date +%s) - T0 ))s; log: harness-check.log)"
say "harness"
"${HMAKE[@]}" harness-up
# The tests find this instance's ports in their environment: xcodebuild hands
# TEST_RUNNER_<NAME> to the test runner as <NAME> (UITestSupport.swift,
# HarnessInstance).
HARNESS_RUN_DIR=
while IFS='=' read -r name value; do
    [[ "$name" == RUN_DIR ]] && { HARNESS_RUN_DIR=$value; continue; }
    [[ "$name" == INSTANCE ]] && name=HARNESS_INSTANCE
    export "TEST_RUNNER_LATCHKEY_$name=$value"
done < <("${HMAKE[@]}" -s ports)
[[ -n "$HARNESS_RUN_DIR" ]] || { echo "error: make ports named no RUN_DIR" >&2; exit 1; }

# -------------------------------------------------------------------- tests --
# Two passes. The sign-in test runs LAST and alone, so R1's disk scan below
# sees the state it left: every other test launches with
# -UITestResetWorkspaces, which deletes the workspace data, and XCTest runs
# tests alphabetically, so a later test would erase the evidence (M2 review).
# A shard runs the sign-in pass and R1's scan only if the test is its own.
CLASS="LatchkeyUITests/OfflineHarnessTests"
SIGNIN="$CLASS/testSignInTokenIsStrippedFromTheAddress"
# run_tests: one pass, with the watchdog for a runner relaunch's idle wait.
TEST_ALLOWANCE=120
source "$ROOT/scripts/lib-run-tests.sh"
SUITE_ARGS=(-only-testing:"$CLASS" -skip-testing:"$SIGNIN")
RUN_SIGNIN=1
if [[ -n "$SHARD_TESTS" ]]; then
    SUITE_ARGS=(); RUN_SIGNIN=0
    for t in "${TESTS[@]}"; do
        if [[ "$CLASS/$t" == "$SIGNIN" ]]; then RUN_SIGNIN=1
        else SUITE_ARGS+=(-only-testing:"$CLASS/$t"); fi
    done
fi
say "OfflineHarnessTests${LATCHKEY_SHARD:+ (shard $LATCHKEY_SHARD, $EXPECTED tests)}"
set +e
SUITE_RC=0; SIGNIN_RC=0
: > "$LOG_DIR/suite.log"; : > "$LOG_DIR/signin.log"
SUITE_WANT=$(( EXPECTED - RUN_SIGNIN ))
if [[ $SUITE_WANT -gt 0 ]]; then run_tests suite "$SUITE_WANT" "${SUITE_ARGS[@]}"; SUITE_RC=$?; fi
if [[ $RUN_SIGNIN -eq 1 ]]; then run_tests signin 1 -only-testing:"$SIGNIN"; SIGNIN_RC=$?; fi
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
# A test build from before F14 ignores the ports above and talks to instance
# 0, whatever this run started. So beside another run, show that this
# instance's own fake dashboard is the one that served the suite.
if [[ "$INSTANCE" != 0 ]]; then
    SERVED=$(grep -c '^\[dash\] ' "$HARNESS_RUN_DIR/dashboard.log" || true)
    if [[ "$SERVED" -lt 1 ]]; then
        echo "error: harness instance $INSTANCE's dashboard served nothing, so the suite ran against" >&2
        echo "       another instance (a test build from before F14? try --build)" >&2
        TEST_RC=1
    else
        echo "    ok (harness instance $INSTANCE's own dashboard served $SERVED requests)"
    fi
fi

# ----------------------------------------------------------------- R1 check --
# testSignInTokenIsStrippedFromTheAddress loads /?token=OFFLINE-TEST-TOKEN-7f3a
# through the real app, so after the suite a token has genuinely passed
# through. Nothing written by the app may contain it, or any `token=`.
say "R1: no sign-in token in the app container's logs"
CONTAINER=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data 2>/dev/null || true)
LEAK_RC=0
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
if [[ $RUN_SIGNIN -eq 0 ]]; then
    echo "    not this shard's: the sign-in test and its scan run on another"
elif [[ -n "$CONTAINER" ]]; then
    # Everything the app can write: all of Library (Application Support,
    # WebKit's website data and caches, Cookies, HTTPStorages, Preferences)
    # and tmp. -a so binary stores (SQLite, the HTTP cache) are searched too;
    # the page no longer carries the token as a literal, so a hit is real.
    SCAN_RC=0
    scan "$LOG_DIR/token-leaks.txt" -rla -e "OFFLINE-TEST-TOKEN" -e "token=" \
        "$CONTAINER/Library" "$CONTAINER/tmp" || SCAN_RC=$?
    if [[ -s "$LOG_DIR/token-leaks.txt" ]]; then
        echo "error: a sign-in token was written to disk:" >&2
        sed "s|$CONTAINER/|    |" "$LOG_DIR/token-leaks.txt" >&2
        LEAK_RC=1
    fi
    if [[ $SCAN_RC -ge 2 ]]; then
        echo "error: the disk scan is incomplete, so 'no token on disk' is not established" >&2
        LEAK_RC=1
    elif [[ $SCAN_RC -eq 1 ]]; then
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
    SCAN_RC=0
    scan "$LOG_DIR/token-in-os-log.txt" -e "OFFLINE-TEST-TOKEN" -e "token=" "$LOG_DIR/unified.log" || SCAN_RC=$?
    if [[ -s "$LOG_DIR/token-in-os-log.txt" ]]; then
        echo "error: a sign-in token reached the unified log:" >&2
        sed 's/^/    /' "$LOG_DIR/token-in-os-log.txt" | head -5 >&2
        LEAK_RC=1
    fi
    if [[ $SCAN_RC -ge 2 ]]; then
        echo "error: the unified-log scan is incomplete" >&2
        LEAK_RC=1
    elif [[ $SCAN_RC -eq 1 ]]; then
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
    cp "$HARNESS_RUN_DIR/"*.log "$LOG_DIR/" 2>/dev/null || true
    say "FAILED in ${ELAPSED}s — logs, screenshot and xcresult in $LOG_DIR"
    exit 1
fi
if [[ -n "$SHARD_TESTS" ]]; then
    say "shard $LATCHKEY_SHARD passed in ${ELAPSED}s"
    exit 0
fi
# 240s, up from M2's 180s: F4 added three tests, one of which deliberately
# stalls a dial for 22 s (and WebKit's own second dial takes it to ~39 s) --
# there is no shorter way to hold a connecting state long enough to assert
# anything about it. A budget that is always exceeded stops being read, so it
# moved rather than being left to warn on every green run. Since F14 it is the
# sharded default's budget: serially L1 cannot get under ~400 s (F14 §9).
say "passed in ${ELAPSED}s (serial; the 240s budget is the sharded default's)"
