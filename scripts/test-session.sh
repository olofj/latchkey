#!/usr/bin/env bash
# M4: the dashboard session against KiroCrew's REAL frontend, the pinned 0.7.1 wheel (R19).
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

# ------------------------------------------------------------------ gateway --
teardown() {
    make -C "$HARNESS" --no-print-directory gateway-down >/dev/null 2>&1 || true
    make -C "$HARNESS" --no-print-directory harness-down >/dev/null 2>&1 || true
}
trap teardown EXIT
say "bundle pin and smoke test (R19)"
# The fixture is one released wheel, pinned by version and sha256 in
# fake_gateway.py and fetched once into testing/harness/.cache -- not the
# venv's or the desktop app's install, which KiroCrew upgrades under us (the
# old 0.6.0 pin stopped the suite from starting for a day unnoticed). Offline,
# an installed copy may stand in, but only if it passes the same pin.
DESKTOP_DIST=/Applications/KiroCrew.app/Contents/Resources/backend-dist/kirocrew-backend-arm64/lib/python3.12/site-packages/kiro_crew/static/dist
if [[ -z "${KIROCREW_DIST:-}" ]] && ! make -C "$HARNESS" --no-print-directory bundle 2>&1 | sed 's/^/    /' \
        && [[ -d "$DESKTOP_DIST" ]] \
        && python3 "$HARNESS/fake_gateway.py" --check-bundle --dist "$DESKTOP_DIST" >/dev/null 2>&1; then
    export KIROCREW_DIST="$DESKTOP_DIST"
    echo "    the pinned wheel could not be fetched; serving the desktop app's copy, which matches the pin"
fi
if ! python3 "$HARNESS/fake_gateway.py" --check-bundle | sed 's/^/    /'; then
    echo "error: no pinned KiroCrew bundle to serve (make -C testing/harness bundle)" >&2; exit 1
fi
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
say "${CLASSES[*]}"
set +e
(cd "$APP" && xcodebuild test-without-building -project Latchkey.xcodeproj -scheme Latchkey \
    -configuration Testing -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath build/DerivedData -resultBundlePath "$LOG_DIR/tests.xcresult" \
    -parallel-testing-enabled NO -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 240 \
    "${ONLY_ARGS[@]}") > "$LOG_DIR/test.log" 2>&1
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

# ------------------------------------------------------------------ F3 / D1 --
# ShareTests share a link with XYZ in its URL, a note NOTE-XYZ and a file
# secret-XYZ.pdf. D1: no log line may carry a URL, title, note or filename.
# Validated by the share having been sent in this same log -- a scan of a log
# with no share in it would prove nothing. Then the log lines the spec names
# for the sweep and the capture refusal, which the UI cannot read.
say "F3: nothing about a share is logged (D1); the sweep and the capture refusal are"
F3_RC=0
if [[ -n "$CONTAINER" ]]; then
    LOGS=("$LOG_DIR/unified.log")
    while IFS= read -r d; do LOGS+=("$d"); done \
        < <(find "$CONTAINER/Library/Application Support" -type d -name Logs 2>/dev/null)
    SCAN_RC=0
    scan "$LOG_DIR/share-in-logs.txt" -rn "XYZ" "${LOGS[@]}" || SCAN_RC=$?
    if [[ -s "$LOG_DIR/share-in-logs.txt" ]]; then
        echo "error: shared content reached a log (D1):" >&2
        head -5 "$LOG_DIR/share-in-logs.txt" | sed 's/^/    /' >&2
        F3_RC=1
    elif [[ $SCAN_RC -ge 2 ]]; then
        echo "error: the D1 scan could not read everything" >&2; F3_RC=1
    fi
fi
for want in "Share: sent " "Share: uploaded " "Share: swept [1-9][0-9]* item" "Share: refused .* over 50 MB"; do
    if grep -qE "$want" "$LOG_DIR/unified.log"; then
        echo "    ok ($want)"
    else
        echo "error: no \"$want\" line in the unified log" >&2; F3_RC=1
    fi
done
[[ $F3_RC -eq 0 ]] && echo "    ok (D1: no XYZ in the unified log or the app's Logs, and shares were sent)"
[[ $F3_RC -eq 0 ]] || TEST_RC=1

# ----------------------------------------------------------------------- F6 --
# The journal proves no connection to Google; the page proves the fonts did
# not arrive by another way. LOADED-PAGE (-UITestLogResponses) carries the
# Google Fonts preload's rel -- "stylesheet" once its onload has run -- and
# the faces loaded, and whether the run installed a list at all, so the
# control's lines are told apart. Validated by at least one line from a run
# with the list that found the link: a selector that matched nothing would
# otherwise pass.
if [[ " ${CLASSES[*]} " == *" SessionTests "* ]]; then
    say "F6: under the rule list the real bundle's fonts link stays preload, and no web font loads"
    F6_RC=0
    WITH_LIST=$(grep -F 'LOADED-PAGE: ' "$LOG_DIR/unified.log" | grep -F '"rules":"installed"' || true)
    if ! grep -qF '"fontsLinkRel":"preload"' <<<"$WITH_LIST"; then
        echo "error: no LOADED-PAGE line from a run with the list names the fonts link, so this check proved nothing" >&2
        F6_RC=1
    fi
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
curl -s http://127.0.0.1:8481/__state > "$LOG_DIR/gateway-state.json" 2>/dev/null || true
if [[ $TEST_RC -ne 0 ]]; then
    xcrun simctl io "$UDID" screenshot "$LOG_DIR/failure.png" >/dev/null 2>&1 || true
    cp "$HARNESS/.run/"*.log "$LOG_DIR/" 2>/dev/null || true
    say "FAILED in ${ELAPSED}s — logs, screenshot and xcresult in $LOG_DIR"
    exit 1
fi
say "passed in ${ELAPSED}s${ONLY:+ (ONLY=$ONLY: not the whole suite)}"
