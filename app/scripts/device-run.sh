#!/bin/bash
# Builds Latchkey (Release) for a connected iPhone, installs it and launches
# it: the M1 device check's install step without Xcode's UI (DEVICE-CHECK.md).
#
#   make device [DEVICE=<udid>] [DEVELOPMENT_TEAM=<team id>]
#
# The team comes from DEVELOPMENT_TEAM, else app/.dev-team (gitignored; the
# project leaves DEVELOPMENT_TEAM blank on purpose). A free personal team is
# fine: automatic signing creates the certificate and a 7-day profile, and
# registers the phone, on the first build (-allowProvisioningUpdates, using the
# Apple ID in Xcode → Settings → Accounts).
#
# The phone must be paired with this Mac and reachable: a cable, or the same
# local network once paired. Without DEVICE, the one paired physical device is
# used.
set -euo pipefail

cd "$(dirname "$0")/.."
TEAM="${DEVELOPMENT_TEAM:-$(cat .dev-team 2>/dev/null || true)}"
if [[ -z "$TEAM" ]]; then
    echo "error: no team: set DEVELOPMENT_TEAM, or put the Team ID in app/.dev-team" >&2
    exit 1
fi

DEVICES_JSON=$(mktemp)
trap 'rm -f "$DEVICES_JSON"' EXIT
xcrun devicectl list devices --json-output "$DEVICES_JSON" >/dev/null 2>&1 || true
if [[ -z "${DEVICE:-}" ]]; then
    DEVICE=$(python3 - "$DEVICES_JSON" <<'EOF'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except (OSError, ValueError, KeyError):
    devices = []
phones = [d for d in devices if d.get("hardwareProperties", {}).get("reality") == "physical"]
if len(phones) != 1:
    names = ", ".join(d.get("deviceProperties", {}).get("name", "?") for d in phones) or "none"
    sys.exit("error: need exactly one paired iPhone, found: %s (pass DEVICE=<udid>)" % names)
print(phones[0]["hardwareProperties"]["udid"])
EOF
)
fi
echo "::: device $DEVICE, team $TEAM"

SANDBOX_FLAGS=()
if ! sandbox-exec -p '(version 1)(allow default)' /usr/bin/true >/dev/null 2>&1; then
    SANDBOX_FLAGS=("OTHER_SWIFT_FLAGS=\$(inherited) -disable-sandbox")
fi
DERIVED=build/DeviceDerivedData
echo "::: build (Release, signed for the device; the first one takes a few minutes)"
xcodebuild build -project Latchkey.xcodeproj -scheme Latchkey -configuration Release \
    -destination "platform=iOS,id=$DEVICE" -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" "${SANDBOX_FLAGS[@]}" \
    > build/device-build.log 2>&1 \
    || { grep -E "error:|Signing|provisioning" build/device-build.log | head -20 >&2
         echo "error: device build failed; see app/build/device-build.log" >&2; exit 1; }

APP_PATH="$DERIVED/Build/Products/Release-iphoneos/Latchkey.app"
echo "::: install"
xcrun devicectl device install app --device "$DEVICE" "$APP_PATH"
echo "::: launch"
xcrun devicectl device process launch --device "$DEVICE" net.lixom.latchkey \
    || echo "(not launched: the first time, trust the developer profile on the phone --" \
            "Settings → General → VPN & Device Management -- then open Latchkey)"
