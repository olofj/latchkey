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
# Picks the phone (DEVICE, or the one physical device) and checks what the
# owner would otherwise have to report or discover by a failed build: paired
# (Trust tapped), reachable now, Developer Mode on. Prints the iOS version,
# which the device check records. `properties` is devicectl's current layout;
# the older *Properties keys are read as a fallback.
DEVICE=$(python3 - "$DEVICES_JSON" "${DEVICE:-}" <<'EOF'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except (OSError, ValueError, KeyError):
    devices = []
wanted = sys.argv[2]

def get(d, new, old):
    for path in (new, old):
        v = d
        for k in path.split("."):
            v = v.get(k) if isinstance(v, dict) else None
        if v is not None:
            return v
    return None

def udid(d):
    return get(d, "properties.hardware.udid", "hardwareProperties.udid") or d.get("identifier")

def name_of(d):
    return str(get(d, "properties.state.name", "deviceProperties.name"))

# A real phone reports NO `reality` at all; only simulators say "simulated"
# (measured on Xcode 27 — the first `make device` found no phone because it
# asked for reality == "physical", which nothing is).
phones = [d for d in devices
          if get(d, "properties.hardware.reality", "hardwareProperties.reality") != "simulated"]
if wanted:
    phones = [d for d in phones
              if wanted in (udid(d), d.get("identifier")) or wanted == name_of(d)]
if len(phones) != 1:
    names = ", ".join(name_of(d) for d in phones) or "none"
    sys.exit("error: need exactly one paired iPhone%s, found: %s. Plug it into this Mac, "
             "unlock it and tap Trust (or pass DEVICE=<udid, or the name>)"
             % (" matching " + wanted if wanted else "", names))
d = phones[0]
name = get(d, "properties.state.name", "deviceProperties.name")
ios = get(d, "properties.software.osVersionNumber.stringValue", "deviceProperties.osVersionNumber")
pairing = get(d, "properties.connection.pairingState", "connectionProperties.pairingState")
state = get(d, "properties.connection.state", "connectionProperties.tunnelState")
transport = get(d, "properties.connection.transportType", "connectionProperties.transportType")
devmode = get(d, "properties.state.developerModeStatus", "deviceProperties.developerModeStatus")
print("::: %s: iOS %s, %s, connection %s (%s), Developer Mode %s"
      % (name, ios, pairing, state, transport, devmode or "not reported"), file=sys.stderr)
if pairing != "paired":
    sys.exit("error: %s is not paired with this Mac: unlock it and tap Trust" % name)
if devmode == "disabled":
    sys.exit("error: Developer Mode is off on %s: Settings -> Privacy & Security -> "
             "Developer Mode, then let it restart" % name)
# Only a definite no: an idle paired phone can read "available", and devicectl
# brings the tunnel up on demand. "disconnected" means the pairing is
# remembered from an earlier cable, which is what a hub or a charge-only cable
# leaves behind: `ioreg -p IOUSB -l | grep "USB Product Name"` then lists no
# iPhone at all.
if state in ("unavailable", "disconnected"):
    sys.exit("error: %s is paired but not connected now (%s over %s). Plug it straight "
             "into the Mac, not through a hub, with a cable that carries data, and unlock "
             "it. Check it is really there: ioreg -p IOUSB -l | grep 'USB Product Name'"
             % (name, state, transport))
print(udid(d))
EOF
)
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
