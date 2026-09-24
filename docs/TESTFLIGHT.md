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

   The key is what makes this work from a plain shell: Xcode's Apple ID
   sign-in is not readable from the command line ("No Accounts"), but
   xcodebuild's `-authenticationKey*` flags provision without it, and
   `altool` uploads with it.
5. **An Apple Distribution certificate in the login keychain.** Xcode →
   Settings → Accounts → your team → Manage Certificates… → + → Apple
   Distribution. See "Why a local certificate" below.

## What `make tf` does

- Rebuilds TailscaleKit if its sources or privacy manifest changed.
- Archives Release with `CURRENT_PROJECT_VERSION` set to a UTC timestamp
  (`YYYYMMDDHHMM`), so every upload has a new build number with nothing to
  commit. `MARKETING_VERSION` stays in the project. Override with
  `BUILD_NUMBER=`.
- Refuses to continue unless the archive carries **both** privacy manifests
  (below): App Store Connect reports a missing one only by email after upload.
- Exports with `ExportOptions.AppStore.plist` and uploads with
  `xcrun altool --upload-package`.

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

## Why a local certificate

From a shell outside the logged-in GUI session (an agent's, KiroCrew's),
`xcodebuild -exportArchive` cannot reach `com.apple.dt.Xcode.ITunesSoftwareService`
("Connection init failed at lookup with error 3 - No such process"), and the
same happens with the agent's own sandbox disabled. Without that service it
cannot use Xcode's cloud-managed distribution signing, so the export needs an
Apple Distribution certificate already in the keychain. `altool` does not use
that service, which is why the upload goes through it (measured 2026-09-24:
`altool --list-apps` with the API key lists the app record).

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
