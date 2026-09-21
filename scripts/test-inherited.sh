#!/usr/bin/env bash
# The inherited XCUITests that need no tailnet (app/AGENTS.md): the launch
# smoke test and the two Settings tests. Full tier only (scripts/test-all.sh):
# the Settings ones overlap newer tests -- L2's diagnostics test opens Settings
# from the dashboard, and discovery's persistence test covers the gateway
# setting -- but they are the only ones on the connection gate's Settings path.
#
#   scripts/test-inherited.sh
#
# Reuses the last test build (any suite's --build makes it).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/app"
SIM_NAME="${SIM_NAME:-iPhone 17}"
LOG_DIR="$APP/build/inherited-logs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR"
TESTS=(testAppLaunchesAndShowsStatus testOpenAndCloseSettings testHomePageSettingPersistsAcrossSettingsReopen)

UDID=$(xcrun simctl list devices available -j | python3 -c "
import json, sys
for devs in json.load(sys.stdin)['devices'].values():
    for d in devs:
        if d['name'] == '$SIM_NAME':
            print(d['udid']); sys.exit(0)
sys.exit(1)") || { echo "error: no simulator named $SIM_NAME" >&2; exit 1; }
xcrun simctl bootstatus "$UDID" -b >/dev/null

ONLY=()
for t in "${TESTS[@]}"; do ONLY+=("-only-testing:LatchkeyUITests/LatchkeyUITests/$t"); done
set +e
(cd "$APP" && xcodebuild test-without-building -project Latchkey.xcodeproj -scheme Latchkey \
    -configuration Testing -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath build/DerivedData -resultBundlePath "$LOG_DIR/tests.xcresult" \
    -parallel-testing-enabled NO "${ONLY[@]}") > "$LOG_DIR/test.log" 2>&1
RC=$?
set -e
grep -E "Test Case .*(passed|failed)" "$LOG_DIR/test.log" | sed 's/^/    /' || true
PASSED=$(grep -cE "Test Case .*LatchkeyUITests.* passed" "$LOG_DIR/test.log" || true)
if [[ $RC -ne 0 || "$PASSED" -ne ${#TESTS[@]} ]]; then
    echo "error: $PASSED of ${#TESTS[@]} inherited tests passed; see $LOG_DIR" >&2
    exit 1
fi
echo "::: passed (${#TESTS[@]} tests)"
