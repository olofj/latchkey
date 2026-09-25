# TestFlight

`make tf` (in `app/`) archives Latchkey for the App Store, exports an App Store
`.ipa` and uploads it to App Store Connect, where it becomes a TestFlight build.
`make tf UPLOAD=0` stops after the export. Uploading needs a committed tree, and
every build names its commit in Settings → Status (F12).

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
   because nothing creates it for you from a shell. Distribute one build from
   Xcode's Organizer (Distribute App → App Store Connect) and it installs
   `iOS Team Store Provisioning Profile: <bundle id>`, valid for a year. `make tf`
   checks for it before exporting and stops with that instruction if it is
   missing. See below.

## What `make tf` does

- **Refuses a dirty working tree**, in under a second and before anything is
  built, naming every uncommitted path (F12). Untracked files count: `App/` and
  `UITests/` are synchronized folder groups, so an untracked `.swift` in either
  is compiled into the build while being in no commit. Gitignored files
  (`.asc-key`, `.dev-team`, `build/`) do not count. There is no override: commit,
  or use `UPLOAD=0`, which exports a dirty tree but can never upload it. The
  check first proves itself on a planted repository (a modified file and an
  untracked `App/…/Planted.swift` must both be caught) and aborts if it cannot.
- Rebuilds TailscaleKit if its sources or privacy manifest changed.
- Archives Release with `CURRENT_PROJECT_VERSION` set to a UTC timestamp
  (`YYYYMMDDHHMM`), so every upload has a new build number with nothing to
  commit. `MARKETING_VERSION` stays in the project. Override with
  `BUILD_NUMBER=`.
- Stamps the commit, `git rev-parse --short=12 HEAD`, into the app's
  `Info.plist` as `LatchkeyGitSHA`, passed to `xcodebuild` as
  `LATCHKEY_GIT_SHA=` (never into the build number, which App Store Connect
  needs numeric and increasing). An `UPLOAD=0` export of a dirty tree is
  stamped `<sha>-dirty`. Settings → Status shows it as **Commit**; a build
  made any other way (Xcode's Run, `make device`) shows `—`. After the archive
  it checks the stamp is in the archive's `Info.plist`, and, when uploading,
  that the tree is still clean and `HEAD` has not moved.
- Refuses to continue unless the archive carries **both** privacy manifests
  (below): App Store Connect reports a missing one only by email after upload.
- Looks for the App Store profile for the archive's bundle id: this team,
  `get-task-allow` false, no device list, not expired, issued for a
  distribution certificate in the keychain. Stops if there is none.
- Exports with `ExportOptions.AppStore.plist` (automatic signing, but without
  `-allowProvisioningUpdates`, so only on-disk profiles) and uploads with
  `xcrun altool --upload-package`, with altool's `TMPDIR` set to
  `app/build/altool-tmp`. See "Why a local certificate is not enough" and
  "The upload's temporary directory".

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
that service, which is why the upload goes through it. `altool --list-apps`
with the API key listing the app record (2026-09-24) proved only that it
authenticates. The first upload from `make tf` was accepted later that day,
after the fix in "The upload's temporary directory" below. Before that fix,
every altool upload was rejected.

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

**What fixed it: distribute from Xcode once.** Xcode has the Apple ID session,
mints the profile and leaves it on disk. After one Organizer upload on
2026-09-24, `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` held
`iOS Team Store Provisioning Profile: net.lixom.latchkey` (Xcode-managed,
`get-task-allow` false, no `ProvisionedDevices`, expires 2027-09-24, issued for
the keychain's Apple Distribution certificate). With it, automatic signing
signs locally and never needs the service. This needs a human at the GUI once
per bundle id, and again when the profile expires or the certificate changes.

`make tf` now exports **without** `-allowProvisioningUpdates` and the API key,
so a missing profile cannot send it back to cloud signing; its own preflight
reports the missing profile first. Two things that looked like better fixes did
not work:

* **`signingStyle: manual` with the profile pinned** fails: `Provisioning
  profile "iOS Team Store Provisioning Profile: net.lixom.latchkey" is Xcode
  managed, but signing settings require a manually managed profile.` Manual
  signing would need a profile made in the developer portal or through the App
  Store Connect REST API (`POST /v1/profiles`, type `IOS_APP_STORE`, which needs
  an ES256 JWT; neither PyJWT nor `cryptography` is installed here). The
  Xcode-managed one is enough, so that stays unimplemented.
* **The export's store-configuration request** still fails from a shell
  (`Unable to authenticate with App Store Connect … ITunesSoftwareService`)
  when the API key is passed. It is only logged, not fatal; without the key the
  export does not attempt it.

**And then an unrelated failure: `error: exportArchive Copy failed`.** With
signing solved, the export died building the `.ipa`. The distribution log
(`$TMPDIR/Latchkey_<date>.xcdistributionlogs/IDEDistributionPipeline.log`)
has the cause:

```
Running /usr/bin/rsync '-8aPhhE' …/Symbols '--link-dest' … …/Root
rsync: on remote machine: --extended-attributes: unknown option
rsync error: syntax or usage error (code 1) at main.c(1886) [server=3.5.0]
```

`/usr/bin/rsync` is Apple's openrsync, and it starts its other end as whatever
`rsync` comes first on `PATH`. In a shell with Homebrew that is GNU rsync 3.5.0,
which rejects openrsync's `-E`. Xcode.app is launched with launchd's `PATH`,
without Homebrew, so the Organizer never meets it. `testflight.sh` runs the
export with `/usr/bin` first on `PATH`.

## The upload's temporary directory

With the export working, the upload was rejected:

```
Missing or invalid signature. The bundle 'net.lixom.latchkey' at bundle path
'Payload/Latchkey.app' is not signed using an Apple submission certificate. (90034)
NSUnderlyingError : A server error occurred. (-19241)
```

That `.ipa` was correctly signed: Apple Distribution on both binaries,
`codesign --verify --deep --strict` clean, and the same certificate accepted
from the Organizer that morning. The cause was where altool ran. Before sending,
altool unpacks the `.ipa` into `$TMPDIR` and analyses it locally (`swinfo`,
which runs `tapi-analyze`, `codesign_allocate` and others). The upload ran from
an agent session, and there `$TMPDIR` is the agent's sandboxed scratch
directory (`~/.kiro/crew/scratch/…`). Inside it those tools fail with
`Operation not permitted`. Even `codesign -d` on an app unpacked there reports
"bundle format is ambiguous". altool still exits 0 from the analysis, uploads,
and the server returns 90034. Measured 2026-09-24, same `.ipa` (build
202609250001), same session:

| `TMPDIR` | invocation | result |
|---|---|---|
| agent scratch | `--upload-package <ipa>` (the script, and `make tf` at 17:02) | 90034 |
| agent scratch | `--upload-app -f <ipa> -t ios` | 90034 |
| `app/build/altool-tmp/` | `--upload-package <ipa>` | `UPLOAD SUCCEEDED`, delivery `b179ec1b-08db-48cc-a916-80a88f6b8965` |

So `testflight.sh` gives altool its own `TMPDIR` under `app/build/`
(gitignored), whoever calls it. The upload flag was not the problem.
`--upload-package` takes a bare `.ipa` in current altool (27.0.5; `altool
--help` shows exactly that), and `--upload-app` failed identically. The
Organizer, and presumably `make tf` from a plain Terminal (`TMPDIR` under
`/var/folders`, untested), never meet the sandbox.

The signing and the stamping were never involved. `LatchkeyGitSHA` is a plain
`Info.plist` key, and the accepted upload carries it.

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
