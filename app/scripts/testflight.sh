#!/bin/bash
# Archives Latchkey for the App Store and uploads it to App Store Connect,
# where it shows up in TestFlight after processing (usually 5-30 min).
#
#   make tf              archive, export and upload
#   make tf UPLOAD=0     archive and export an App Store .ipa, no upload
#
# Needs the paid Apple Developer Program (a free personal team cannot export
# for the App Store), an App Store Connect app record for the bundle id, and an
# App Store Connect API key:
#
#   app/.asc-key (gitignored)   ASC_KEY_ID=...  ASC_ISSUER_ID=...
#                               [ASC_KEY_PATH=...]
#   the key itself              ~/.appstoreconnect/private_keys/AuthKey_<ID>.p8
#
# The API key is what lets altool upload from a plain shell: Xcode's own Apple
# ID sign-in is not readable from the command line ("No Accounts"). It does not
# let xcodebuild provision there, so the export also needs an App Store profile
# already on disk, which one Distribute App from Xcode's Organizer installs.
# This script only passes the key's PATH to its tools and never reads it.
#
# Extra arguments go to `xcodebuild archive` (the Makefile passes the nested-
# sandbox Swift flag through this way).
set -euo pipefail

cd "$(dirname "$0")/.."

# ----- team: the same resolution as scripts/device-run.sh -----
XCCONFIG_TEAM=$(sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([A-Za-z0-9]+).*/\1/p' \
                    Local.xcconfig 2>/dev/null | tail -1 || true)
DOTFILE_TEAM=$(cat .dev-team 2>/dev/null | tr -d '[:space:]' || true)
if [[ -n "$XCCONFIG_TEAM" && -n "$DOTFILE_TEAM" && "$XCCONFIG_TEAM" != "$DOTFILE_TEAM" ]]; then
    echo "error: app/Local.xcconfig says team $XCCONFIG_TEAM but app/.dev-team says $DOTFILE_TEAM" >&2
    exit 1
fi
TEAM="${DEVELOPMENT_TEAM:-${XCCONFIG_TEAM:-$DOTFILE_TEAM}}"
if [[ -z "$TEAM" ]]; then
    echo "error: no team: put 'DEVELOPMENT_TEAM = <Team ID>' in app/Local.xcconfig" \
         "(docs/SETUP.md §3), or pass DEVELOPMENT_TEAM=<Team ID>" >&2
    exit 1
fi

# ----- App Store Connect API key -----
if [[ ! -f .asc-key ]]; then
    echo "error: no app/.asc-key. Create an App Store Connect API key (Users and" \
         "Access → Integrations, App Manager role), put the .p8 in" \
         "~/.appstoreconnect/private_keys/, and write ASC_KEY_ID=<Key ID> and" \
         "ASC_ISSUER_ID=<Issuer ID> to app/.asc-key (docs/TESTFLIGHT.md)" >&2
    exit 1
fi
# shellcheck source=/dev/null
source .asc-key
: "${ASC_KEY_ID:?app/.asc-key has no ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?app/.asc-key has no ASC_ISSUER_ID}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
if [[ ! -f "$ASC_KEY_PATH" ]]; then
    echo "error: no API key file at $ASC_KEY_PATH (from app/.asc-key's ASC_KEY_ID)" >&2
    exit 1
fi
AUTH=(-allowProvisioningUpdates
      -authenticationKeyPath "$ASC_KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID")

# ----- build number -----
# App Store Connect refuses a build number it has already seen for the same
# version. A UTC timestamp always increases and needs no file to bump; the
# marketing version (MARKETING_VERSION) stays in the project.
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"

UPLOAD="${UPLOAD:-1}"
ARCHIVE=build/Latchkey-appstore.xcarchive
EXPORT_DIR=build/appstore
EXPORT_OPTS=build/ExportOptions.AppStore.plist

echo "::: Archiving Latchkey for App Store Connect (team $TEAM, build $BUILD_NUMBER) :::"
rm -rf "$ARCHIVE"
set -o pipefail
xcodebuild archive \
    -project Latchkey.xcodeproj -scheme Latchkey \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" \
    -derivedDataPath build/DerivedData \
    DEVELOPMENT_TEAM="$TEAM" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    "${AUTH[@]}" "$@" | { command -v xcpretty >/dev/null && xcpretty || cat; }

# A missing privacy manifest is only caught by App Store Connect, minutes
# after the upload, by email (ITMS-91053). Check the archive for both first.
APP="$ARCHIVE/Products/Applications/Latchkey.app"
for manifest in "$APP/PrivacyInfo.xcprivacy" \
                "$APP/Frameworks/TailscaleKit.framework/PrivacyInfo.xcprivacy"; do
    if [[ ! -f "$manifest" ]]; then
        echo "error: the archive has no ${manifest#"$ARCHIVE"/}; App Store Connect would" \
             "reject it (ITMS-91053). For TailscaleKit, rebuild it: make -B framework" >&2
        exit 1
    fi
done
echo "privacy manifests: app and TailscaleKit both present"

# ----- App Store provisioning profile -----
# The export signs only with a profile already on disk: it runs without
# -allowProvisioningUpdates, because the cloud signing that would mint one
# cannot authenticate from a non-GUI shell ("Cloud signing permission error",
# docs/TESTFLIGHT.md). Check for one first, so a missing profile says what to
# do. An App Store profile: this team and bundle id, get-task-allow false, no
# device list, not expired, issued for a distribution certificate we hold.
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist")
IDENTITIES=$(security find-identity -v -p codesigning)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PROFILE_UUID="" PROFILE_NAME="" PROFILE_CERT="" PROFILE_CREATED=""
PROFILE_PLIST=$(mktemp)
trap 'rm -f "$PROFILE_PLIST"' EXIT
field() { plutil -extract "$1" raw -o - "$PROFILE_PLIST" 2>/dev/null; }
for f in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.mobileprovision \
         "$HOME/Library/MobileDevice/Provisioning Profiles"/*.mobileprovision; do
    [[ -f "$f" ]] || continue
    security cms -D -i "$f" > "$PROFILE_PLIST" 2>/dev/null || continue
    [[ "$(field Entitlements.application-identifier)" == "$TEAM.$BUNDLE_ID" ]] || continue
    [[ "$(field Entitlements.get-task-allow)" == false ]] || continue
    field ProvisionedDevices >/dev/null && continue
    [[ "$(field ExpirationDate)" > "$NOW" ]] || continue
    created=$(field CreationDate)
    [[ "$created" > "$PROFILE_CREATED" ]] || continue
    cert=""
    for ((i = 0; i < $(field DeveloperCertificates); i++)); do
        sha=$(field "DeveloperCertificates.$i" | base64 -D | shasum -a 1 | awk '{print toupper($1)}')
        if grep -q "$sha" <<< "$IDENTITIES"; then cert=$sha; break; fi
    done
    [[ -n "$cert" ]] || continue
    PROFILE_UUID=$(field UUID) PROFILE_NAME=$(field Name) PROFILE_CERT=$cert PROFILE_CREATED=$created
done
if [[ -z "$PROFILE_UUID" ]]; then
    echo "error: no App Store provisioning profile for $TEAM.$BUNDLE_ID whose" \
         "certificate is in the keychain. Distribute one build from Xcode's Organizer" \
         "(it installs the profile), then re-run: docs/TESTFLIGHT.md" >&2
    exit 1
fi
echo "profile: $PROFILE_NAME ($PROFILE_UUID), certificate $PROFILE_CERT"

mkdir -p build
cp ExportOptions.AppStore.plist "$EXPORT_OPTS"
/usr/libexec/PlistBuddy -c "Set :teamID $TEAM" "$EXPORT_OPTS"
echo "::: Exporting an App Store .ipa to $EXPORT_DIR :::"
rm -rf "$EXPORT_DIR"
# /usr/bin first: the export's /usr/bin/rsync (openrsync) passes -E and starts
# its other end as whatever `rsync` is on PATH. Homebrew's rsync 3.x rejects -E
# ("--extended-attributes: unknown option") and the export dies with only
# "Copy failed". Xcode.app never sees Homebrew's PATH (measured 2026-09-24).
PATH="/usr/bin:$PATH" xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTS"
IPA=$(ls -1 "$EXPORT_DIR"/*.ipa | head -1)

if [[ "$UPLOAD" == 0 ]]; then
    echo "✅ $IPA (build $BUILD_NUMBER, not uploaded)"
    exit 0
fi
# Upload with altool rather than the export's destination=upload: from a shell
# outside the GUI session (an agent's, KiroCrew's) xcodebuild cannot reach
# com.apple.dt.Xcode.ITunesSoftwareService ("Connection init failed at lookup
# with error 3"), while altool talks to App Store Connect with the API key
# directly (measured 2026-09-24).
echo "::: Uploading $IPA to App Store Connect :::"
xcrun altool --upload-package "$IPA" \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" --p8-file-path "$ASC_KEY_PATH"
echo "✅ Uploaded build $BUILD_NUMBER. It appears in App Store Connect → TestFlight" \
     "once processing finishes; the first build asks the export-compliance question there."
