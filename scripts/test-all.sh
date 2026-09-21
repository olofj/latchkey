#!/usr/bin/env bash
# Runs the test suites by tier.
#
#   scripts/test-all.sh [--full] [--build]
#
# quick (the default, while iterating; about 4-5 min):
#   host tests (make test-policy), the vendored Go tests, L1 and L2 -- plus the
#   session and discovery suites when code THEY exercise changed since the
#   last full pass. Those two take 6 and 1.5 min and guard code most changes
#   do not touch.
# --full (before a milestone or review commit; about 13 min):
#   everything, including the inherited connection-independent tests. A full
#   pass that succeeds records the commits it tested, so quick runs know what
#   changed since.
# --build: build for testing once, in the first simulator suite.
#
# Each suite script still works on its own; this only chooses and sequences.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/app"
STAMP="$APP/build/test-all/last-full"
FULL=0; BUILD=0
for a in "$@"; do
    case "$a" in
        --full) FULL=1 ;;
        --build) BUILD=1 ;;
        *) echo "usage: $0 [--full] [--build]" >&2; exit 2 ;;
    esac
done
say() { printf '::: %s\n' "$*"; }

# ------------------------------------------------ what changed since last full --
# Paths changed since the last successful full pass (committed or not, and new
# files), as app/... or parent-relative. No record: everything counts as changed.
changed() {
    { git -C "$APP" diff --name-only "$1" -- ; git -C "$APP" ls-files -o --exclude-standard; } | sed 's|^|app/|'
    { git -C "$ROOT" diff --name-only "$2" -- ; git -C "$ROOT" ls-files -o --exclude-standard; }
}
if [[ $FULL -eq 0 && -f "$STAMP" ]] && read -r APP_BASE PARENT_BASE < "$STAMP" \
        && git -C "$APP" cat-file -e "$APP_BASE" 2>/dev/null && git -C "$ROOT" cat-file -e "$PARENT_BASE" 2>/dev/null; then
    CHANGED=$(changed "$APP_BASE" "$PARENT_BASE")
else
    CHANGED="(no successful full pass recorded)"
    [[ $FULL -eq 0 ]] && say "no full pass recorded yet: running every suite"
fi
touches() { [[ "$CHANGED" == "(no successful full pass recorded)" ]] || grep -qE "$1" <<< "$CHANGED"; }

# Code each optional suite exercises. The vendored library and TSNet are the
# network path under all of them.
SESSION_RE='^app/(App/(Session|Browser|Workspace)/|TSNet/|ThirdParty/|UITests/(SessionTests|UITestSupport)\.swift)|^testing/harness/(fake_gateway|tls_accept)\.py|^testing/harness/kirocrew|^scripts/test-session\.sh'
DISCOVERY_RE='^app/(App/(Discovery|Network|Browser)/|TSNet/|ThirdParty/|UITests/(DiscoveryTests|UITestSupport)\.swift)|^testing/tsnet-harness/|^testing/harness/(fake_gateway|tls_accept)\.py|^scripts/test-discovery\.sh'

RUN_SESSION=$FULL; RUN_DISCOVERY=$FULL
if [[ $FULL -eq 0 ]]; then
    touches "$SESSION_RE" && RUN_SESSION=1
    touches "$DISCOVERY_RE" && RUN_DISCOVERY=1
fi

# ------------------------------------------------------------------- suites --
RESULTS=(); FAILED=0
run() {  # name, command...
    local name=$1; shift
    local t0=$(date +%s)
    say "$name"
    if "$@"; then RESULTS+=("ok    $(( $(date +%s) - t0 ))s  $name")
    else RESULTS+=("FAIL  $(( $(date +%s) - t0 ))s  $name"); FAILED=1; fi
}
build_flag() { if [[ $BUILD -eq 1 ]]; then BUILD=0; echo --build; fi; }

run "host tests" make -C "$APP" --no-print-directory test-policy
run "vendored Go tests" bash -c "cd '$APP/ThirdParty/libtailscale' && go test -run 'LocalLog|OSLog' . \
    && cd tailscale-patched && go test ./logtail/ -run Latchkey"
run "L1 offline" "$ROOT/scripts/test-offline.sh" $(build_flag)
run "L2 tailnet" "$ROOT/scripts/test-tailnet.sh" $(build_flag)
if [[ $RUN_SESSION -eq 1 ]]; then run "session (M4)" "$ROOT/scripts/test-session.sh" $(build_flag)
else RESULTS+=("skip        session (M4): nothing it exercises changed since the last full pass"); fi
if [[ $RUN_DISCOVERY -eq 1 ]]; then run "discovery (M5)" "$ROOT/scripts/test-discovery.sh" $(build_flag)
else RESULTS+=("skip        discovery (M5): nothing it exercises changed since the last full pass"); fi
if [[ $FULL -eq 1 ]]; then
    run "inherited (connection-independent)" "$ROOT/scripts/test-inherited.sh"
fi

# ------------------------------------------------------------------ summary --
echo
say "summary ($([[ $FULL -eq 1 ]] && echo full || echo quick))"
printf '    %s\n' "${RESULTS[@]}"
if [[ $FAILED -ne 0 ]]; then exit 1; fi
if [[ $FULL -eq 1 ]]; then
    mkdir -p "$(dirname "$STAMP")"
    echo "$(git -C "$APP" rev-parse HEAD) $(git -C "$ROOT" rev-parse HEAD)" > "$STAMP"
    say "full pass recorded (quick runs now compare against it)"
fi
