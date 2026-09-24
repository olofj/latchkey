# TestFlight

`make tf` (in `app/`) archives Latchkey for the App Store, exports an App Store
`.ipa` and uploads it to App Store Connect, where it becomes a TestFlight build.
`make tf UPLOAD=0` stops after the export.

TestFlight is the only way to install without a Mac tethered to the phone, and
its builds last 90 days instead of a development profile's 7 (free team) or 1
year (paid). Sideloading with `make device` still works and is still the fast
loop; the two installs coexist only if they use different bundle ids.

## One-time setup

1. **Paid Apple Developer Program** membership. A free personal team cannot
   export for the App Store.
2. **App ID** for the bundle id (`net.lixom.latchkey` by default,
   `LATCHKEY_BUNDLE_ID` in `app/Local.xcconfig` for yours): Certificates,
   Identifiers & Profiles → Identifiers → +, Explicit, no capabilities.
3. **App Store Connect app record**: Apps → + → New App, with that bundle id.
   The store name must be unique across the whole store and is only what
   testers see in TestFlight; the home-screen name comes from the app.
4. **App Store Connect API key**: Users and Access → Integrations → +.
   Put the `.p8` at `~/.appstoreconnect/private_keys/AuthKey_<Key ID>.p8`
   (directory 700, file 600) and write the IDs to `app/.asc-key` (gitignored):

   ```
   ASC_KEY_ID=<Key ID>
   ASC_ISSUER_ID=<Issuer ID>
   # ASC_KEY_PATH=<elsewhere>.p8   optional
   ```

   The key is what lets `altool` upload from a plain shell: Xcode's Apple ID
   sign-in is not readable from the command line ("No Accounts"). It does **not**
   let `xcodebuild` provision there — an earlier version of this page claimed it
   did, and 2026-09-24 disproved it. See "Why a local certificate is not enough".
5. **An Apple Distribution certificate in the login keychain.** Xcode →
   Settings → Accounts → your team → Manage Certificates… → + → Apple
   Distribution.
6. **An App Store provisioning profile for the bundle id, already on disk.** The
   certificate alone is not enough, and this is the step that is easy to miss
   because nothing creates it for you from a shell. See below.

## What `make tf` does

- Rebuilds TailscaleKit if its sources or privacy manifest changed.
- Archives Release with `CURRENT_PROJECT_VERSION` set to a UTC timestamp
  (`YYYYMMDDHHMM`), so every upload has a new build number with nothing to
  commit. `MARKETING_VERSION` stays in the project. Override with
  `BUILD_NUMBER=`.
- Refuses to continue unless the archive carries **both** privacy manifests
  (below): App Store Connect reports a missing one only by email after upload.
- Exports with `ExportOptions.AppStore.plist` and uploads with
  `xcrun altool --upload-package`. The export is the step that needs signing
  assets this machine may not have — see "Why a local certificate is not enough".

## Privacy manifests

App Store Connect rejects an upload (ITMS-91053) if the app or an embedded
framework calls a
[required-reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
without declaring why. Two manifests cover it:

| File | Declares | Because |
|---|---|---|
| `app/App/PrivacyInfo.xcprivacy` | FileTimestamp `C617.1` | `Diagnostics/NodeLog.swift` reads its log files' modification dates |
| `app/ThirdParty/libtailscale/swift/PrivacyInfo.xcprivacy` | FileTimestamp `C617.1`, SystemBootTime `35F9.1` | the Go runtime imports `stat`/`fstat`/`fstatat`/`lstat` and `mach_absolute_time` |

The TailscaleKit manifest is copied into both xcframework slices by
libtailscale's `ios-fat` target, a vendored delta after the still-open
[libtailscale#57](https://github.com/tailscale/libtailscale/pull/57). That PR
ships an *empty* manifest, which would not pass: it declares none of the APIs
above. After a Go toolchain bump, re-run the scan:

```
nm -u app/ThirdParty/libtailscale/swift/build/Build/Products/Release-iphonefat/TailscaleKit.xcframework/ios-arm64/TailscaleKit.framework/TailscaleKit \
  | grep -E '_(f?stat(at|fs|vfs)?|lstat|getattrlist|mach_absolute_time)'
```

A symbol from a new category (`statfs` → DiskSpace) needs its own entry.

## Why a local certificate is not enough

From a shell outside the logged-in GUI session (an agent's, KiroCrew's),
`xcodebuild -exportArchive` cannot reach `com.apple.dt.Xcode.ITunesSoftwareService`
("Connection init failed at lookup with error 3 - No such process"), and the
same happens with the agent's own sandbox disabled. Without that service it
cannot use Xcode's cloud-managed distribution signing, so the export needs an
Apple Distribution certificate already in the keychain. `altool` does not use
that service, which is why the upload goes through it (measured 2026-09-24:
`altool --list-apps` with the API key lists the app record).

**And the certificate is necessary but not sufficient.** Signing also needs an
App Store *provisioning profile*, and cloud signing is what would create one —
so the same missing service blocks it. Measured 2026-09-24, with the Apple
Distribution certificate present in the keychain the whole time:

```
error: exportArchive Cloud signing permission error
    You haven't been given access to cloud-managed distribution certificates.
error: exportArchive No profiles for 'net.lixom.latchkey' were found
```

The first line is misleading — the account holder cannot lack access to their
own team's certificates. It is what cloud signing says after failing to
authenticate, and the second line is the real consequence.

So `make tf` cannot currently finish from a non-GUI shell on a machine that has
never distributed this bundle id. It archives (that part works), then stops at
the export. Two ways out, neither yet implemented:

* **Distribute the archive from Xcode once.** Xcode has the Apple ID session,
  mints the profile, uploads, and leaves the profile on disk — after which the
  CLI export has what it needs. Requires a human at the GUI, once per bundle id.
* **Create the profile through the App Store Connect REST API** (`POST
  /v1/profiles`, type `IOS_APP_STORE`) and export with `signingStyle: manual`.
  Removes the GUI dependency entirely. Needs an ES256 JWT, and neither PyJWT nor
  `cryptography` is installed here.

## Troubleshooting

**"There are no archives to select" in Xcode's Organizer.** `make tf` passes
`-archivePath app/build/Latchkey-appstore.xcarchive`, and Organizer only lists
archives under `~/Library/Developer/Xcode/Archives/<date>/`. The archive is real
and complete; Organizer simply does not look there. Copy it across to make the
Xcode fallback available:

```
cp -R app/build/Latchkey-appstore.xcarchive \
   ~/Library/Developer/Xcode/Archives/$(date +%F)/"Latchkey $(date +%F' '%H.%M).xcarchive"
```

**"You are not enrolled in the Apple Developer Program" when you are.** Xcode
caches each account's team list in `com.apple.dt.Xcode.plist` under
`IDEProvisioningTeamByIdentifier`, *including whether the team is free*, and does
not refresh it when the enrollment changes. Enrolling after Xcode has already
seen the same Apple ID leaves this behind:

```
teamID   = DX33PQ7J4A
teamName = Olof Johansson (Personal Team)
teamType = Personal Team
isFreeProvisioningTeam = true
```

Distribute App reads that and refuses, reporting Xcode's cache as Apple's
answer. **Xcode → Settings → Accounts → sign out, then sign back in**, which
re-fetches the team list; "Download Manual Profiles" refreshes profiles, not
team metadata, and does not clear it.

Seen 2026-09-24, hours after enrolling. The certificate dates are the tell, and
worth checking before believing the message — a free team cannot hold an Apple
Distribution certificate at all:

```
$ security find-certificate -c "Apple Distribution: <name>" -p | openssl x509 -noout -subject -dates
subject=UID=DX33PQ7J4A, CN=Apple Distribution: ... , OU=DX33PQ7J4A
notBefore=Sep 24 17:15:21 2026 GMT        # hours old: the enrollment is real
```

## Export compliance

The app uses encryption: WireGuard (Curve25519, ChaCha20-Poly1305, BLAKE2s),
TLS and Noise inside TailscaleKit, and the system's HTTPS in the web view. All
of it is standard, published cryptography, and securing the connection is the
app's main purpose, so no "incidental use" exemption applies; it is
mass-market software using standard encryption.

The owner answered App Store Connect's questions on 2026-09-24 (App
Information → App Encryption Documentation): uses encryption, qualifies for a
Category 5 Part 2 exemption, no proprietary algorithms, standard algorithms in
addition to the OS's, not distributed in France. App Store Connect concluded
that **no documentation is required**.

That matches `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO` in all three
configurations, so builds do not ask again. (The key arrived earlier than the
decision, as a template default in Xcode 27's project migration, 6cd80d0.)
Revisit it if the answers change: non-standard cryptography, or a release in
France.

## Testers

Internal testing (up to 100 members of the App Store Connect team) needs no
Beta App Review. Add yourself under TestFlight → Internal Testing, then
install from the TestFlight app on the phone.
