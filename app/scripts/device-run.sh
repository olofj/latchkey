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
# The bundle id is a build setting from Latchkey.xcconfig (default) or
# Local.xcconfig (yours), which an xcconfig outranks in xcodebuild's layering,
# so an exported value changes nothing here -- and must not: Xcode's Run never
# sees the shell, and two ids would mean two apps and a second, empty node.
if [[ -n "${LATCHKEY_BUNDLE_ID:-}" ]]; then
    echo "note: LATCHKEY_BUNDLE_ID in the environment is ignored; the bundle id comes" \
         "from app/Local.xcconfig so that Xcode and this script install the same app" >&2
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
import json, re, sys
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
# `list devices` does not carry the Developer Mode status for a phone it
# cannot reach; `ddiServicesAvailable: false` is the hint that it is off (or
# its disk image is not mounted), and asking for details names the reason.
ddi = get(d, "properties.state.ddiServicesAvailable", "deviceProperties.ddiServicesAvailable")
reason = None
# Once devicectl has reached the phone, the status is a one-key object,
# {"disabled": {}}, not a string. Take the key.
if isinstance(devmode, dict):
    devmode = next(iter(devmode), None)
if isinstance(devmode, str):
    devmode = devmode.lower()
# `list devices` answers from CoreDevice's cache, and the cache is stale in
# exactly the case that matters: a phone whose Developer Mode was just
# switched on still reads "disabled", and a connected phone still reads
# "disconnected" (measured 2026-09-23 on the first real install). So when the
# cache says anything short of ready, ask the phone itself -- a few seconds,
# and it names its own reason when it refuses.
if devmode != "enabled" or state != "connected":
    import subprocess
    try:
        out = subprocess.run(["xcrun", "devicectl", "device", "info", "details",
                              "--device", udid(d)], capture_output=True, text=True,
                             timeout=90).stdout
    except (OSError, subprocess.SubprocessError):
        out = ""
    m = re.search(r"Developer Mode Status: *(\w+)", out)
    if m:
        devmode = m.group(1).lower()
    m = re.search(r"^\s*Error: *(.+)$", out, re.M)
    if m:
        reason = m.group(1).strip()
    # It answered and has a tunnel: it is reachable, whatever the cache said.
    if "Tunnel IP Address" in out:
        state = "connected"
print("::: %s: iOS %s, %s, connection %s (%s), Developer Mode %s"
      % (name, ios, pairing, state, transport, devmode or "not reported"), file=sys.stderr)
if pairing != "paired":
    sys.exit("error: %s is not paired with this Mac: unlock it and tap Trust" % name)
if devmode == "disabled":
    sys.exit("error: Developer Mode is off on %s. On the phone: Settings -> Privacy & "
             "Security -> Developer Mode, switch it on, let it restart, then unlock it "
             "and allow the prompt. (The menu only appears once the phone has been "
             "connected to a Mac with Xcode, which it now has.)" % name)
# Only a definite no: an idle paired phone can read "available", and devicectl
# brings the tunnel up on demand. "disconnected" means the pairing is
# remembered from an earlier cable, which is what a hub or a charge-only cable
# leaves behind: `ioreg -p IOUSB -l | grep "USB Product Name"` then lists no
# iPhone at all.
if state in ("unavailable", "disconnected"):
    sys.exit("error: %s is paired but not connected now (%s over %s)%s. If it is not on "
             "the bus at all (ioreg -p IOUSB -l | grep 'USB Product Name'), plug it "
             "straight into the Mac, not through a hub, with a cable that carries data. "
             "Otherwise unlock it and allow the prompt."
             % (name, state, transport, ": " + reason if reason else ""))
print(udid(d))
EOF
)
echo "::: device $DEVICE, team $TEAM"

SANDBOX_FLAGS=()
if ! sandbox-exec -p '(version 1)(allow default)' /usr/bin/true >/dev/null 2>&1; then
    SANDBOX_FLAGS=("OTHER_SWIFT_FLAGS=\$(inherited) -disable-sandbox")
fi
DERIVED=build/DeviceDerivedData
build() {  # extra xcodebuild arguments
    xcodebuild build -project Latchkey.xcodeproj -scheme Latchkey -configuration Release \
        -destination "platform=iOS,id=$DEVICE" -derivedDataPath "$DERIVED" \
        DEVELOPMENT_TEAM="$TEAM" "${SANDBOX_FLAGS[@]}" "$@" > build/device-build.log 2>&1
}
echo "::: build (Release, signed for the device; the first one takes a few minutes)"
# -allowProvisioningUpdates lets Xcode mint the certificate and the profile,
# which needs the Apple ID to be usable from here. It is not always: an
# account added in Xcode's UI can leave xcodebuild saying "No Accounts" while
# Xcode itself is signed in (2026-09-23). A profile Xcode already made is
# enough on its own, so that case is retried without the flag rather than
# reported as a signing failure.
if ! build -allowProvisioningUpdates; then
    if grep -q "No Accounts" build/device-build.log && build; then
        echo "::: (built against the profile Xcode already made; this shell has no usable Apple ID)"
    else
        grep -E "error:|Signing|provisioning" build/device-build.log | sort -u | head -20 >&2
        if grep -q "No Accounts" build/device-build.log; then
            echo "note: no usable Apple ID here and no matching profile yet. Open Xcode," \
                 "check Settings -> Accounts lists $(cat .dev-team 2>/dev/null), pick the" \
                 "team under Latchkey -> Signing & Capabilities, and press Run once with" \
                 "the phone selected. After that this script works on its own." >&2
        fi
        echo "error: device build failed; see app/build/device-build.log" >&2; exit 1
    fi
fi

APP_PATH="$DERIVED/Build/Products/Release-iphoneos/Latchkey.app"
echo "::: install"
xcrun devicectl device install app --device "$DEVICE" "$APP_PATH"
echo "::: launch"
xcrun devicectl device process launch --device "$DEVICE" net.lixom.latchkey \
    || echo "(not launched: the first time, trust the developer profile on the phone --" \
            "Settings → General → VPN & Device Management -- then open Latchkey)"
