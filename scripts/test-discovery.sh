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
# app/build/discovery-logs/<timestamp>/.
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
# R10: only the fixture tailnets may be named (allow-list, not deny-list).
"$ROOT/scripts/check-fixture-tailnets.sh" \
    "$APP/UITests/DiscoveryTests.swift" "$TSNET"/*.go \
    "$TSNET/Makefile" "$HARNESS/leaf.cnf" "$APP/App/Discovery"
EXPECTED=$(grep -cE '^\s*func test[A-Za-z0-9_]*\(' "$APP/UITests/DiscoveryTests.swift" || true)
[[ "$EXPECTED" -gt 0 ]] || { echo "error: no tests found in DiscoveryTests.swift" >&2; exit 1; }
# ONLY_TESTS="testX testY" runs just those, while iterating. The R26 timing
# check needs the whole class's sweeps, so it is skipped, and a pass says so.
ONLY_ARGS=(-only-testing:LatchkeyUITests/DiscoveryTests)
if [[ -n "${ONLY_TESTS:-}" ]]; then
    read -ra PICKED <<< "$ONLY_TESTS"
    EXPECTED=${#PICKED[@]}
    ONLY_ARGS=()
    for t in "${PICKED[@]}"; do ONLY_ARGS+=("-only-testing:LatchkeyUITests/DiscoveryTests/$t"); done
fi
# REPEAT=N runs each chosen test N times, for chasing a flake; every
# iteration must pass. With ONLY_TESTS only, for the same reason.
REPEAT_ARGS=()
if [[ -n "${REPEAT:-}" ]]; then
    [[ -n "${ONLY_TESTS:-}" && "$REPEAT" =~ ^[1-9][0-9]*$ ]] \
        || { echo "error: REPEAT=N needs ONLY_TESTS and N >= 1" >&2; exit 1; }
    REPEAT_ARGS=(-test-iterations "$REPEAT")
    EXPECTED=$(( EXPECTED * REPEAT ))
fi

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
say "DiscoveryTests"
# The log window starts HERE, so sweeps from an earlier run or suite can
# never be counted (M5 review).
LOG_START=$(date '+%Y-%m-%d %H:%M:%S')
set +e
(cd "$APP" && xcodebuild test-without-building -project Latchkey.xcodeproj -scheme Latchkey \
    -configuration Testing -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath build/DerivedData -resultBundlePath "$LOG_DIR/tests.xcresult" \
    -parallel-testing-enabled NO -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 180 \
    "${ONLY_ARGS[@]}" ${REPEAT_ARGS[@]+"${REPEAT_ARGS[@]}"}) > "$LOG_DIR/test.log" 2>&1
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
# R26's instrument: the app logs each sweep's timings, and what it probed.
# Every sweep must match one of the three peer sets this suite runs --
#   gw present:  probing 4 of 4 -> 1 gateway, 2 answered (gw, dash), 2 failed
#   gw=0:        probing 3 of 3 -> 0 gateways, 1 answered (dash), 2 failed
#   purgatory:   probing 4 of 4 -> 0 gateways, 0 answered, 4 failed (every
#                peer drops the node's SYNs: the device-check rehearsal)
# (plain refuses, slow stalls) -- and take at least 4 s, the slow peer's
# timeout (in purgatory, every probe's), which proves it was waited for. The
# first gateway must appear within 5 s of the picker appearing (the wait for
# the node's status included), and a sweep must end within 15 s: the sweep
# deadline is 12 s since the first device run showed 1.5 s losing the race
# against a relayed intercontinental gateway. At least
# one sweep must have found the gateway, or this measured nothing; and the
# purgatory sweep happens exactly once (the rehearsal's first run), so a
# sweep in which every peer failed for some other reason cannot pass as it.
if [[ -n "${ONLY_TESTS:-}" ]]; then
    say "passed in ${ELAPSED}s (ONLY_TESTS: not the whole suite; R26 timing not checked)"
    exit 0
fi
say "R26 sweeps, from the app's own log"
xcrun simctl spawn "$UDID" log show --start "$LOG_START" \
    --predicate 'subsystem == "net.lixom.latchkey"' --style compact 2>/dev/null \
    | grep -E "Discovery: (probing|[0-9]+ gateway|probed=|continuing at)|Status request abandoned after|LocalAPI loopback (failure|recovered)" \
    > "$LOG_DIR/sweeps.log" || true
if ! python3 - "$LOG_DIR/sweeps.log" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().splitlines()
purgatory_sig = (4, 4, 0, 0, 4)
# The small fixed tailnet's sweeps, enumerated. (3, 4, 0, 1, 2) is F7's
# skipped-peer tests: four peers, gw declined for its OS or its owner, so three
# probed -- dash answers, plain and slow do not.
expected = {(4, 4, 1, 2, 2), (3, 3, 0, 1, 2), (3, 4, 0, 1, 2), purgatory_sig}
# F16's stalled loopback (testAStalledLoopbackEndsTheSearchWithinSeconds and
# testAStalledLoopbackIsReplacedAndTheSearchThenFindsTheGateway): the node's own
# listener accepts and never answers, so every probe fails and none answers --
# the same signature as purgatory. It is told apart by what only a silent
# loopback logs inside the sweep's window, the bounded status request being
# abandoned, and counted on its own: exactly one per F16 test. The purgatory
# count stays exactly one.
stalled_sig = purgatory_sig
STALLED_SWEEPS = 2
abandoned_re = re.compile(r"Status request abandoned after 3 s \(([12]) of 2 before loopback recovery\)$")
# F7's large-tailnet tests present 40+ synthetic peers, and how many of those a
# 12 s sweep reaches varies by a dozen from run to run. Enumerating those
# signatures would be enumerating the scheduler. Above this many peers the
# invariants below are checked instead -- and they are the ones that matter for
# a truncated sweep: that it says it was truncated, and that what it claims to
# have probed is what it reports.
SMALL_TAILNET = 5
bad, found, probing, purgatory, continuing = [], 0, None, 0, False
stalled, abandoned_in_sweep, abandoned_lines, recoveries = 0, False, 0, 0
pending = None   # a summary awaiting its `probed=` line
def close(p):
    """Check a summary once its probed= line is in (or turned out to be absent).

    Note the two lines have different SCOPES, deliberately: the summary's
    `answered`/`failed` describe the sweep that just ran, as its elapsed time
    does, while `probed=`/`truncated=` describe the whole chain of continuations
    (F7 §4.3) -- `probedCount` counts distinct hosts across it. So the two agree
    exactly only for a sweep that is not a continuation, and a continuation is
    identified by the `continuing at candidate` line.
    """
    if p is None:
        return
    sig, sweep, answered, failed, counters, cont, l = p
    small = sig[1] <= SMALL_TAILNET
    if small and not cont and sig not in expected:
        bad.append("unexpected sweep %s: %s" % (sig, l))
    if counters is None:
        bad.append("sweep %s logged no probed=/truncated= line: %s" % (sig, l))
        return
    probed, candidates, truncated = counters
    if probed > candidates:
        bad.append("sweep %s probed %d of %d candidates: %s" % (sig, probed, candidates, l))
    if answered + failed > probed:
        bad.append("sweep %s reports %d answered + %d failed, more than probed=%d: %s"
                   % (sig, answered, failed, probed, l))
    if not cont and answered + failed != probed:
        bad.append("sweep %s reports %d answered + %d failed but probed=%d: %s"
                   % (sig, answered, failed, probed, l))
    # The rule F7 turns on, and the one the picker's wording leans on.
    if truncated and probed >= candidates:
        bad.append("sweep %s says truncated but probed all %d: %s" % (sig, candidates, l))
    if not truncated and probed != candidates:
        bad.append("sweep %s says it was not truncated but probed %d of %d: %s"
                   % (sig, probed, candidates, l))
for l in lines:
    if "Status request abandoned after" in l:
        if not abandoned_re.search(l):
            bad.append("an abandoned status request logged in an unexpected form: %s" % l)
        abandoned_lines += 1
        if probing is not None:
            abandoned_in_sweep = True
        continue
    if re.search(r"LocalAPI loopback recovered", l):
        recoveries += 1
        continue
    if "LocalAPI loopback failure" in l:
        continue
    m = re.search(r"Discovery: probing (\d+) of (\d+) peer", l)
    if m:
        close(pending); pending = None
        probing = (int(m.group(1)), int(m.group(2)))
        continuing = False
        abandoned_in_sweep = False
        continue
    if re.search(r"Discovery: continuing at candidate \d+ of \d+", l):
        continuing = True
        continue
    m = re.search(r"Discovery: probed=(\d+)/(\d+) truncated=(yes|no)", l)
    if m and pending is not None:
        sig, sweep, answered, failed, _, cont, sl = pending
        pending = (sig, sweep, answered, failed,
                   (int(m.group(1)), int(m.group(2)), m.group(3) == "yes"), cont, sl)
        close(pending); pending = None
        continue
    m = re.search(r"Discovery: (\d+) gateway\(s\); first after (\S+?)(?: ms)?, sweep (\d+) ms; "
                  r"(\d+) answered, (\d+) failed; shown to first (\S+?)(?: ms)?$", l)
    if not m:
        continue
    close(pending); pending = None
    n, sweep, answered, failed = int(m.group(1)), int(m.group(3)), int(m.group(4)), int(m.group(5))
    shown = m.group(6)
    sig = (probing or (0, 0)) + (n, answered, failed)
    is_stalled = abandoned_in_sweep and sig == stalled_sig
    if abandoned_in_sweep and not is_stalled:
        bad.append("a status request was abandoned during a sweep that is not F16's stalled one %s: %s" % (sig, l))
    print("    probed %s of %s: %d gateway(s), %d answered, %d failed; sweep %d ms; picker to first %s"
          % (sig[0], sig[1], n, answered, failed, sweep, shown + (" ms" if shown != "—" else "")))
    if sweep < 4000 or sweep > 15000:
        bad.append("sweep %d ms outside 4-15 s: %s" % (sweep, l))
    if n and (shown == "—" or int(shown) > 5000):
        bad.append("first gateway %s after the picker appeared (budget 5 s): %s" % (shown, l))
    found += n > 0
    stalled += is_stalled
    purgatory += sig == purgatory_sig and not is_stalled
    pending = (sig, sweep, answered, failed, None, continuing, l)
    probing = None
close(pending)
if not found:
    print("error: no sweep that found a gateway was logged; this measured nothing")
    sys.exit(1)
if purgatory != 1:
    print("error: %d sweeps in which every peer failed; the rehearsal's purgatory sweep is exactly one" % purgatory)
    sys.exit(1)
# F16 §4.1's instrument, by the app's own words: each stalled sweep ended on an
# abandoned status request, and the two-strike trigger replaced the loopback.
if stalled != STALLED_SWEEPS:
    print("error: %d stalled-loopback sweeps (every probe failed, a status request abandoned); expected %d, one per F16 test"
          % (stalled, STALLED_SWEEPS))
    sys.exit(1)
if recoveries < 1:
    print("error: the stalled loopback was never replaced: no 'LocalAPI loopback recovered' line")
    sys.exit(1)
print("    F16: %d stalled sweep(s), %d abandoned status request(s), %d loopback recovery(ies)"
      % (stalled, abandoned_lines, recoveries))
if bad:
    print("error:")
    for b in bad:
        print("  " + b)
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
