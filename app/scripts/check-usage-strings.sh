#!/bin/bash
# F23 T1: the built app declares a purpose string for every TCC-guarded
# resource it can reach. Without NSMicrophoneUsageDescription, the first
# getUserMedia({audio:true}) in the dashboard makes TCC kill the app
# (issue #9: EXC_CRASH SIGABRT, __TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__).
# The check reads the built Info.plist, not project.pbxproj, so a key that
# a configuration drops on its way into the bundle is caught too.
#
#   scripts/check-usage-strings.sh [path/to/Latchkey.app]
#
# Default: the last Testing build for the simulator.
set -euo pipefail

cd "$(dirname "$0")/.."
APP_PATH="${1:-build/DerivedData/Build/Products/Testing-iphonesimulator/Latchkey.app}"
PLIST="$APP_PATH/Info.plist"
[[ -f "$PLIST" ]] || { echo "error: no Info.plist at $PLIST (build the app first)" >&2; exit 1; }

failures=0
for key in NSCameraUsageDescription NSMicrophoneUsageDescription; do
    value=$(/usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" 2>/dev/null || true)
    if [[ -z "${value//[[:space:]]/}" ]]; then
        echo "  FAIL: $key is missing or empty in $PLIST"
        failures=$((failures + 1))
    else
        echo "  ok: $key"
    fi
done
[[ $failures -eq 0 ]] || { echo "usage strings: $failures missing"; exit 1; }
echo "usage strings: all present"
