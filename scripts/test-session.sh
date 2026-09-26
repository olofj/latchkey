#!/usr/bin/env bash
# M4: the dashboard session against KiroCrew's REAL frontend, the pinned 0.7.1 wheel (R19).
#
#   scripts/test-session.sh [--build] [--serial | --shards N]
#
# By default the suite runs across 8 simulators at once (F14):
# scripts/test-session-shards.py builds once, boots "Latchkey Shard 1..N"
# (L1 shards onto the first 4), runs this script on each as a worker with
# its share of the tests, and gives one verdict. --shards N or
# LATCHKEY_SHARDS=N picks N (2-9).
#
# --serial runs everything on one simulator, SIM_NAME (default "iPhone 17"),
# against harness instance 0, as before F14. Naming a simulator (SIM_NAME) or
# an instance (LATCHKEY_INSTANCE), or picking tests (ONLY, ONLY_TESTS), also
# means serial. LATCHKEY_INSTANCE=k (0-9) puts the harness and both fake
# gateways on instance k's ports (testing/harness/Makefile), beside another run.
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
#
# As a shard worker (test-session-shards.py sets these): LATCHKEY_SHARD_TESTS
# names the tests to run (Class/test), LATCHKEY_XCTESTRUN the built
# .xctestrun, LATCHKEY_LOG_DIR where the logs go. The log checks after the
# tests (R1, F3, F6) then fail on anything they find in this shard's logs,
# but their positive controls -- a redemption, a share sent, a page under
# the rule list -- may have run on another shard: the worker writes what it
# found to evidence.txt, and the coordinator requires each across the
# shards. --build-only builds and exits.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/app"
HARNESS="$ROOT/testing/harness"
BUILD=0; BUILD_ONLY=0; SHARDS="${LATCHKEY_SHARDS:-8}"
[[ -n "${SIM_NAME:-}${LATCHKEY_INSTANCE:-}${ONLY:-}${ONLY_TESTS:-}" ]] && SHARDS=1
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
    exec python3 "$ROOT/scripts/test-session-shards.py" --shards "$SHARDS" \
        $([[ $BUILD -eq 1 ]] && echo --build)
fi
SIM_NAME="${SIM_NAME:-iPhone 17}"
INSTANCE="${LATCHKEY_INSTANCE:-0}"
[[ "$INSTANCE" =~ ^[0-9]$ ]] || { echo "error: LATCHKEY_INSTANCE must be 0-9, not '$INSTANCE'" >&2; exit 1; }
HMAKE=(make -C "$HARNESS" --no-print-directory INSTANCE="$INSTANCE")
XCTESTRUN="${LATCHKEY_XCTESTRUN:-}"
if [[ -n "$SHARD_TESTS" && ( $BUILD -eq 1 || -z "$XCTESTRUN" ) ]]; then
    echo "error: a shard worker runs a prebuilt LATCHKEY_XCTESTRUN and never builds" >&2; exit 1
fi

LOG_DIR="${LATCHKEY_LOG_DIR:-$APP/build/session-logs/$(date +%Y%m%d-%H%M%S)}"
[[ -n "${LATCHKEY_LOG_DIR:-}" || "$INSTANCE" == 0 ]] || LOG_DIR+="-i$INSTANCE"
mkdir -p "$LOG_DIR"
: > "$LOG_DIR/evidence.txt"
START=$(date +%s)
say() { printf '::: %s\n' "$*"; }

# ---------------------------------------------------------------- preflight --
say "preflight"
# R10: only the fixture tailnets may be named (allow-list, not deny-list).
"$ROOT/scripts/check-fixture-tailnets.sh" \
    "$APP/UITests/SessionTests.swift" "$APP/UITests/ShareTests.swift" "$HARNESS/fake_gateway.py" \
    "$HARNESS/gateway_check.py" "$HARNESS/Makefile" "$HARNESS/leaf.cnf"
# Both classes (F3 adds ShareTests); every test in both must pass.
# ONLY=ShareTests (or SessionTests) runs one class while iterating; the
# count is then that class's, and a pass says so.
CLASSES=(SessionTests ShareTests)
[[ -n "${ONLY:-}" ]] && CLASSES=("$ONLY")
EXPECTED=0
for c in "${CLASSES[@]}"; do
    EXPECTED=$(( EXPECTED + $(grep -cE '^\s*func test[A-Za-z0-9_]*\(' "$APP/UITests/$c.swift") ))
done
ONLY_ARGS=()
for c in "${CLASSES[@]}"; do ONLY_ARGS+=("-only-testing:LatchkeyUITests/$c"); done
# ONLY_TESTS="SessionTests/testX ShareTests/testY" runs just those, while
# iterating; a pass then says it was not the whole suite. A shard's tests
# arrive the same way.
PICK="${SHARD_TESTS:-${ONLY_TESTS:-}}"
if [[ -n "$PICK" ]]; then
    read -ra PICKED <<< "$PICK"
    EXPECTED=${#PICKED[@]}
    ONLY_ARGS=()
    for t in "${PICKED[@]}"; do ONLY_ARGS+=("-only-testing:LatchkeyUITests/$t"); done
fi

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
    # The commit, stamped as test-offline.sh stamps it (F12): the two suites
    # share one DerivedData, and L1's Status test reads it from this build.
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

# ------------------------------------------------------------------ gateway --
# F5: a second fake gateway, answering as dash.tail-scale.ts.net (a name the
# test certificate carries and this suite otherwise never loads), for the
# switch between two gateways.
#
# This instance's ports, from the Makefile, as P_<NAME>. The tests find them
# in their environment: xcodebuild hands TEST_RUNNER_<NAME> to the test
# runner as <NAME> (UITestSupport.swift, HarnessInstance).
HARNESS_RUN_DIR=
while IFS='=' read -r name value; do
    [[ "$name" == RUN_DIR ]] && { HARNESS_RUN_DIR=$value; continue; }
    [[ "$name" == INSTANCE ]] && name=HARNESS_INSTANCE
    printf -v "P_$name" '%s' "$value"
    export "TEST_RUNNER_LATCHKEY_$name=$value"
done < <("${HMAKE[@]}" -s ports)
[[ -n "$HARNESS_RUN_DIR" && -n "${P_GW2_CONTROL_PORT:-}" ]] \
    || { echo "error: make ports named no RUN_DIR or GW2_CONTROL_PORT" >&2; exit 1; }
GW2=(GW_NAME=gateway2 GW_HOST=dash.tail-scale.ts.net GW_PORT="$P_GW2_PORT" GW_CONTROL_PORT="$P_GW2_CONTROL_PORT")
teardown() {
    "${HMAKE[@]}" gateway-down "${GW2[@]}" >/dev/null 2>&1 || true
    "${HMAKE[@]}" gateway-down >/dev/null 2>&1 || true
    "${HMAKE[@]}" harness-down >/dev/null 2>&1 || true
}
trap teardown EXIT
say "bundle pin and smoke test (R19)"
# The fixture is one released wheel, pinned by version and sha256 in
# fake_gateway.py and fetched once into testing/harness/.cache -- not the
# venv's or the desktop app's install, which KiroCrew upgrades under us (the
# old 0.6.0 pin stopped the suite from starting for a day unnoticed). Offline,
# an installed copy may stand in, but only if it passes the same pin.
DESKTOP_DIST=/Applications/KiroCrew.app/Contents/Resources/backend-dist/kirocrew-backend-arm64/lib/python3.12/site-packages/kiro_crew/static/dist
# A shard's coordinator has fetched it already (and chosen KIROCREW_DIST):
# several fetches at once would race on one .part file.
if [[ -z "${KIROCREW_DIST:-}" && -z "$SHARD_TESTS" ]] && ! "${HMAKE[@]}" bundle 2>&1 | sed 's/^/    /' \
        && [[ -d "$DESKTOP_DIST" ]] \
        && python3 "$HARNESS/fake_gateway.py" --check-bundle --dist "$DESKTOP_DIST" >/dev/null 2>&1; then
    export KIROCREW_DIST="$DESKTOP_DIST"
    echo "    the pinned wheel could not be fetched; serving the desktop app's copy, which matches the pin"
fi
if ! python3 "$HARNESS/fake_gateway.py" --check-bundle | sed 's/^/    /'; then
    echo "error: no pinned KiroCrew bundle to serve (make -C testing/harness bundle)" >&2; exit 1
fi
say "fake gateway contract self-test"
"${HMAKE[@]}" gateway-check > "$LOG_DIR/gateway-check.log" 2>&1 \
    || { cat "$LOG_DIR/gateway-check.log" >&2; echo "error: the fake gateway's self-test failed" >&2; exit 1; }
tail -1 "$LOG_DIR/gateway-check.log" | sed 's/^/    /'

say "harness up"
"${HMAKE[@]}" harness-up DASH_UPSTREAM="127.0.0.1:$P_GW2_PORT"
"${HMAKE[@]}" gateway-up
"${HMAKE[@]}" gateway-up "${GW2[@]}"
# Every server says it is this instance, as the tests' setUp will require.
for url in "http://127.0.0.1:$P_GW_CONTROL_PORT/__state" "http://127.0.0.1:$P_GW2_CONTROL_PORT/__state" \
           "http://127.0.0.1:$P_PROXY_CONTROL_PORT/state"; do
    curl -s "$url" | grep -q "\"instance\": *\"$INSTANCE\"" \
        || { echo "error: $url is not harness instance $INSTANCE" >&2; exit 1; }
done

# -------------------------------------------------------------------- tests --
# run_tests: one pass, with the watchdog for a runner relaunch's idle wait.
TEST_ALLOWANCE=240
source "$ROOT/scripts/lib-run-tests.sh"
say "${CLASSES[*]}${LATCHKEY_SHARD:+ (shard $LATCHKEY_SHARD, $EXPECTED tests)}"
set +e
run_tests test "$EXPECTED" "${ONLY_ARGS[@]}"
TEST_RC=$?
set -e
grep -E "Test Case .*(passed|failed)" "$LOG_DIR/test.log" | sed 's/^/    /' || true
PASSED=$(grep -cE "Test Case .*(SessionTests|ShareTests).* passed" "$LOG_DIR/test.log" || true)
if [[ $TEST_RC -eq 0 && "$PASSED" -ne "$EXPECTED" ]]; then
    echo "error: $PASSED of $EXPECTED SessionTests + ShareTests passed (a stale build? try --build)" >&2
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
# A positive control: how many of the things that make a check mean
# something this run's logs hold. A serial run fails here on none; a shard
# records the count in evidence.txt, and test-session-shards.py fails the
# run unless some shard found one (the line names the key it checks).
control() {  # key, count, what none means
    echo "$1 $2" >> "$LOG_DIR/evidence.txt"
    [[ "$2" -ge 1 ]] && return 0
    if [[ -n "$SHARD_TESTS" ]]; then
        echo "    none on this shard ($1): required on another"
        return 0
    fi
    echo "error: $3" >&2
    return 1
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
        if control webkit_files "$WK_FILES" "no WebKit data in the container, so the disk scan searched nothing"; then
            [[ "$WK_FILES" -eq 0 ]] || echo "    ok (disk: all of Library + tmp, $WK_FILES WebKit files among them)"
        else
            LEAK_RC=1
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
    if control redemptions "$N" "no redemption was logged, so the scan proved nothing"; then
        [[ "$N" -eq 0 ]] || echo "    ok (validated: $N redemptions passed through the app)"
    else
        LEAK_RC=1
    fi
fi
[[ $LEAK_RC -eq 0 ]] || TEST_RC=1

# ------------------------------------------------------------------ F3 / D1 --
# ShareTests share a link with XYZ in its URL, a note NOTE-XYZ and a file
# secret-XYZ.pdf. D1: no log line may carry a URL, title, note or filename.
# Validated by the share having been sent in this same log -- a scan of a log
# with no share in it would prove nothing. Then the log lines the spec names
# for the sweep and the capture refusal, which the UI cannot read.
# ONLY_TESTS picks tests whose log these lines may not be in.
if [[ -n "${ONLY_TESTS:-}" ]]; then
    say "F3 and F6 log checks: skipped (ONLY_TESTS)"
else
    say "F3: nothing about a share is logged (D1); the sweep and the capture refusal are"
    F3_RC=0
    if [[ -n "$CONTAINER" ]]; then
        LOGS=("$LOG_DIR/unified.log")
        while IFS= read -r d; do LOGS+=("$d"); done \
            < <(find "$CONTAINER/Library/Application Support" -type d -name Logs 2>/dev/null)
        # XCUITest's automation runs inside the app's process and logs, in
        # os_log's Default category, every element it reads and every tree
        # it prints -- labels included. Under XCTest os_log is mirrored to
        # stderr, which libtailscale's filch buffer (Logs/aperture.log1.txt,
        # .log2.txt) captures until it is drained, so a test that read a
        # shared link's row can leave its label there: the test reading the
        # screen, not the app logging. The app logs only as tsnet, timing and
        # share-extension. Found when sharding changed which test ran last
        # (F14); a serial run ended on a test that shows no XYZ. So the filch
        # files are scanned as copies without their [Default] records (the
        # header line and its continuation lines), and nothing else is set aside.
        FILCH=0
        for i in "${!LOGS[@]}"; do
            [[ -d "${LOGS[$i]}" ]] || continue
            for f in "${LOGS[$i]}"/aperture.log[12].txt; do
                [[ -f "$f" ]] || continue
                FILCH=$(( FILCH + 1 ))
                awk '/^20[0-9][0-9]-[0-9][0-9]-[0-9][0-9] / {
                         drop = ($0 ~ /^20[0-9-]+ [^ ]+ [^ ]+\[[0-9]+:[0-9]+\] \[Default\] /)
                         if (drop) n++
                     }
                     /^\{"/ { drop = 0 }
                     !drop { print }
                     END { print n + 0 > "/dev/stderr" }' "$f" \
                    > "$LOG_DIR/filch-$FILCH-$(basename "$f")" 2>> "$LOG_DIR/filch-set-aside.txt"
            done
        done
        SCAN_RC=0
        scan "$LOG_DIR/share-in-logs.txt" -rn "XYZ" --exclude 'aperture.log[12].txt' \
            "${LOGS[@]}" $(ls "$LOG_DIR"/filch-*-aperture.log[12].txt 2>/dev/null) || SCAN_RC=$?
        [[ $FILCH -eq 0 ]] || echo "    filch buffers scanned without XCUITest's own records:" \
            "$(awk '{s += $1} END {print s + 0}' "$LOG_DIR/filch-set-aside.txt") [Default] records set aside"
        if [[ -s "$LOG_DIR/share-in-logs.txt" ]]; then
            echo "error: shared content reached a log (D1):" >&2
            head -5 "$LOG_DIR/share-in-logs.txt" | sed 's/^/    /' >&2
            F3_RC=1
        elif [[ $SCAN_RC -ge 2 ]]; then
            echo "error: the D1 scan could not read everything" >&2; F3_RC=1
        fi
    fi
    for spec in "share_sent:Share: sent " "share_uploaded:Share: uploaded " \
                "share_swept:Share: swept [1-9][0-9]* item" "share_refused:Share: refused .* over 50 MB"; do
        key=${spec%%:*} want=${spec#*:}
        N=$(grep -cE "$want" "$LOG_DIR/unified.log" || true)
        if control "$key" "$N" "no \"$want\" line in the unified log"; then
            [[ "$N" -eq 0 ]] || echo "    ok ($want)"
        else
            F3_RC=1
        fi
    done
    [[ $F3_RC -eq 0 ]] && echo "    ok (D1: no XYZ in the unified log or the app's Logs)"
    [[ $F3_RC -eq 0 ]] || TEST_RC=1
fi

# ----------------------------------------------------------------------- F6 --
# The journal proves no connection to Google; the page proves the fonts did
# not arrive by another way. LOADED-PAGE (-UITestLogResponses) carries the
# Google Fonts preload's rel -- "stylesheet" once its onload has run -- and
# the faces loaded, and whether the run installed a list at all, so the
# control's lines are told apart. Validated by at least one line from a run
# with the list that found the link: a selector that matched nothing would
# otherwise pass.
if [[ " ${CLASSES[*]} " == *" SessionTests "* && -z "${ONLY_TESTS:-}" ]]; then
    say "F6: under the rule list the real bundle's fonts link stays preload, and no web font loads"
    F6_RC=0
    WITH_LIST=$(grep -F 'LOADED-PAGE: ' "$LOG_DIR/unified.log" | grep -F '"rules":"installed"' || true)
    N=$(grep -cF '"fontsLinkRel":"preload"' <<<"$WITH_LIST" || true)
    control fonts_preload "$N" \
        "no LOADED-PAGE line from a run with the list names the fonts link, so this check proved nothing" || F6_RC=1
    if grep -qF '"fontsLinkRel":"stylesheet"' <<<"$WITH_LIST"; then
        echo "error: with the list installed, the Google Fonts stylesheet loaded:" >&2
        grep -F '"fontsLinkRel":"stylesheet"' <<<"$WITH_LIST" | head -3 | cut -c1-300 | sed 's/^/    /' >&2
        F6_RC=1
    fi
    if grep -qE 'Space Grotesk|JetBrains Mono' <<<"$(grep -o '"webFonts":\[[^]]*\]' <<<"$WITH_LIST")"; then
        echo "error: with the list installed, a Google web font loaded" >&2
        F6_RC=1
    fi
    [[ $F6_RC -eq 0 ]] && echo "    ok ($(grep -cF '"fontsLinkRel":"preload"' <<<"$WITH_LIST") page loads under the list, fonts link still preload, no Google face)"
    [[ $F6_RC -eq 0 ]] || TEST_RC=1
fi

# ------------------------------------------------------------------ summary --
ELAPSED=$(( $(date +%s) - START ))
curl -s "http://127.0.0.1:$P_GW_CONTROL_PORT/__state" > "$LOG_DIR/gateway-state.json" 2>/dev/null || true
if [[ $TEST_RC -ne 0 ]]; then
    xcrun simctl io "$UDID" screenshot "$LOG_DIR/failure.png" >/dev/null 2>&1 || true
    cp "$HARNESS_RUN_DIR/"*.log "$LOG_DIR/" 2>/dev/null || true
    say "FAILED in ${ELAPSED}s — logs, screenshot and xcresult in $LOG_DIR"
    exit 1
fi
if [[ -n "$SHARD_TESTS" ]]; then
    say "shard $LATCHKEY_SHARD passed in ${ELAPSED}s"
    exit 0
fi
say "passed in ${ELAPSED}s${ONLY:+ (ONLY=$ONLY: not the whole suite)}${ONLY_TESTS:+ (ONLY_TESTS: not the whole suite)}"
