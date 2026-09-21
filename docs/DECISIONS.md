# Decisions

Append-only. Newest at the bottom. One entry per decision that a future reader
would otherwise have to reverse-engineer: why a divergence from upstream exists,
what was measured, what was rejected and why.

Format:

```
## YYYY-MM-DD — short title
**Decision:** what was decided.
**Why:** the reasoning, including what was rejected.
**Evidence:** measurements, file references, links.
```

---

## 2026-09-20 — Fork aperture-plus rather than build fresh

**Decision:** base the app on [tailscale/aperture-plus](https://github.com/tailscale/aperture-plus)
@ `dba0555`, keeping `upstream` as a remote and tracking it.

**Why:** aperture-plus already solves the parts that are genuinely hard on iOS —
the split-tunnel `matchDomains` computation, the `NSURLErrorBadURL (-1000)` proxy
semantics, the `node.up()` actor-starvation workaround, and failure-driven
recovery when iOS reclaims the loopback listener. Building on `tunnelless` (MIT,
~250 lines) was considered; it would mean rediscovering those by hitting the same
bugs. The cost is carrying code we delete once, plus upstream tracking.

**Evidence:** `docs/PLAN.md` §2.2, and the file map in §10.

## 2026-09-20 — Do not build a native session-refresh loop

**Decision:** the app will not call `POST /api/auth/refresh`. The dashboard's own
JS client already does, single-flight, triggered by HTTP 403 + `X-Auth-Required: true`.
The app hooks the page's `mc-auth-required` / `mc-auth-cleared` events instead.

**Why:** reusing a rotated refresh token outside its grace window revokes the
entire 30-day chain. A native loop racing the page's would eventually do exactly
that. There is also no durable token to cache — the link window is 300 seconds —
so the refresh chain is the only long-lived credential and must not be endangered.

**Evidence:** `dashboard/token_auth.py:3097-3111` (the 403 + header pair),
`client-oM83i081.js` (memoised single-flight refresh, 401 terminal latch);
`docs/PLAN.md` §3.3.

---

# M0 — Bootstrap

## 2026-09-20 — M0 baseline (task 0.7)

**Decision:** record the exact toolchain and upstream state this fork starts
from, so a later failure can be told apart from an inherited one.

**Pinned commits**

| What | SHA |
|---|---|
| `tailscale/aperture-plus` (fork point, branch `latchkey`) | `dba05551d3577825ecc44ca8dd0645c9eaca1f8c` |
| `ThirdParty/libtailscale` | `f55900d2efb7ccc327a9ac07779b92767c1e48ab` |
| `ThirdParty/libtailscale/tailscale-patched` | `b5adfd852c01a53025cbacc0727789984ffbf427` |

**Toolchain as built**

| Tool | Upstream asks for | `chonk` has | Result |
|---|---|---|---|
| Xcode | 26.x, iOS 26 SDK | **27.0 (27A266a)**, iOS 27.0 SDK (24A430) | builds |
| iOS simulator runtime | — | 27.0 (24A434), iPhone 17 / 18 Pro / Air present | boots |
| Go | 1.26.5 (`go.mod` declares `go 1.25.0`; libtailscale's declares `go 1.26.5`) | **1.27.1 darwin/arm64** | builds |

`make framework` completed on Go 1.27.1 with no toolchain pin and no
`GOTOOLCHAIN` override, producing a 183 MB `TailscaleKit.xcframework` with
`ios-arm64` and `ios-arm64_x86_64-simulator` slices. **Risk §7.1 (Xcode 27 vs
the required 26) did not materialise for the framework or the app**; no
side-by-side Xcode 26 install is needed.

**Verified green**

- `make framework` — succeeds from a clean clone.
- `make test-policy` — 102/102 split-tunnel checks, 17/17 hostname-qualifier
  checks. Green on Xcode 27 with no changes.

**Inherited test baseline (NOT run here, and why)**

`TODO.failing-tests.md` records iOS 23/29 and macOS 2/3 passing upstream, with
the failures in three buckets: five iOS tests on the cold-node 60 s page-load
timeout (→ M6.8), one exit-node test needing a working exit-node peer (removed
by M1.8), one macOS-only `ASWebAuthenticationSession` test (removed by M1.1).

Those numbers are taken from upstream's own file and **were not reproduced
here**: every one of the 29 iOS UI tests needs a real tailnet plus an auth key
staged at `~/.aperture-ios-authkey`, which this project deliberately does not
have (§6.1). That is the whole reason M2 and M3 exist. The upstream suite is
therefore an inherited *claim*, not an inherited *measurement*, and the real
regression net starts at `scripts/test-offline.sh`.

**Signing state:** `security find-identity -v -p codesigning` reports **0 valid
identities** and no Xcode account is configured on this machine. Simulator work
is unaffected (it needs no signing), but every device step — the M1 AC device
check for KiroCrew #9399, and all of M7 — is blocked until an Apple ID is added
in Xcode → Settings → Accounts. See the identity decision below.

## 2026-09-20 — Submodule URLs rewritten to an absolute URL

**Decision:** change `.gitmodules` from upstream's `url = .` to
`url = https://github.com/tailscale/aperture-plus`, and set the same URL for
the nested `tailscale-patched` submodule via local git config.

**Why:** upstream stores the libtailscale and tailscale-patched commits as
unreferenced objects **inside the aperture-plus repository itself** — that is
what `url = .` means here, not "some sibling repo". Git resolves a relative
submodule URL against the superproject's `origin` remote; §4.2 has us rename
`origin` → `upstream`, after which `.` falls back to a local filesystem path
and `git submodule update --init --recursive` dies with
`fatal: transport 'file' not allowed`.

Verified the commits are genuinely only in aperture-plus:
`git fetch libtailscale f55900d2…` → `upload-pack: not our ref`;
`git fetch aperture-plus f55900d2…` → succeeds. So the absolute URL is the
correct one, not a workaround.

The nested submodule's `.gitmodules` lives inside libtailscale's own working
tree, so it is fixed with `git -C ThirdParty/libtailscale config
submodule.tailscale-patched.url …` rather than by diverging a second
repository. `scripts/bootstrap.sh` does both.

**Evidence:** `app/.gitmodules`; `scripts/bootstrap.sh`.

## 2026-09-20 — Build under a shell that forbids nested sandboxes

**Decision:** auto-detect the condition in `app/Makefile` and add
`OTHER_SWIFT_FLAGS=-disable-sandbox` only when it is present. Do not commit the
flag unconditionally.

**Why:** this project is being implemented by an AI agent whose shell already
runs under a seatbelt profile, and `sandbox_apply` cannot nest. Xcode calls
`sandbox-exec` in **two independent places**, so the failure shows up twice
wearing different masks:

1. **Swift macro plugins.** `swift-frontend` sandboxes `swift-plugin-server`.
   When that fails, every `@State` / `@Model` / `@Query` expansion fails with
   *"external macro implementation type 'SwiftUIMacros.StateMacro' could not be
   found … produced malformed response"*, and the build then emits hundreds of
   downstream errors — `cannot find '$showingSettings' in scope`, `cannot assign
   to property: 'self' is immutable` — that look like Swift 6 concurrency
   breakage on the newer SDK and are nothing of the kind. **This is the trap:
   the visible errors point at the wrong layer entirely.**
2. **SwiftPM manifest evaluation** for the one local package,
   `Packages/ApertureVM`. Fails as
   `xcodebuild: error: Could not resolve package dependencies:
   sandbox-exec: sandbox_apply: Operation not permitted`, before any compile.

Measured: with the package reference removed **and** `-disable-sandbox`, the
iOS app builds clean (`** BUILD SUCCEEDED **`). With `-disable-sandbox` alone
and the package restored, it still fails at resolution. So the two causes are
independent, and (2) has no flag-level workaround.

`Packages/ApertureVM` is macOS-only and M1.2 deletes it outright, so (2)
resolves itself one milestone later — it is not carried as debt.
`SWIFTPM_DISABLE_SANDBOX=1`, `-disableAutomaticPackageResolution` and
`launchctl submit` were each tried and do not help.

The detection probe runs `sandbox-exec -p '(version 1)(allow default)'
/usr/bin/true`; on an ordinary Mac it succeeds, `SWIFT_SANDBOX_FLAGS` stays
empty, and macro sandboxing is left exactly as upstream has it. Force either
way with `make app NESTED_SANDBOX=1` / `NESTED_SANDBOX=0`.

**Evidence:** `app/Makefile` (the `NESTED_SANDBOX` block).

## 2026-09-20 — Identity: blank the development team rather than guess one

**Decision:** set `DEVELOPMENT_TEAM = ""` at all ten `project.pbxproj` sites
and put `REPLACE_WITH_YOUR_TEAM_ID` in `ExportOptions.plist`, instead of
substituting a team ID.

**Why:** §4.3 says "your personal team", but no Apple ID is signed into Xcode
on this machine and there are no codesigning identities, so the free personal
team's ID does not exist yet — it is minted when the account is added. An empty
`DEVELOPMENT_TEAM` with automatic signing makes Xcode prompt for a team on the
first Run, which is exactly the documented free-personal-team install path
(§4.3: "the reliable install path is Xcode's Run button, not `make ipa`").
Simulator builds need no signing and are unaffected.

A guessed or placeholder team ID would have been worse than an empty one: it
fails at code-signing time with `errSecInternalComponent` rather than at team
selection, which is a much harder error to read.

**Applied:** `DEVELOPMENT_TEAM` ×10; `PRODUCT_BUNDLE_IDENTIFIER`
`io.tailscale.Aperture` → `net.lixom.latchkey` ×4 (§4.3 predicted 2 — the Mac
app target shares the iOS bundle id, as `AGENTS.md` states; both are changed
and the Mac ones vanish with M1.1); `io.tailscale.Aperture.UITests` →
`net.lixom.latchkey.UITests` ×2; `CFBundleDisplayName` → `Latchkey`;
`CFBundleName` → `Latchkey`.

## 2026-09-20 — `app/` is a separate git repository, not a submodule

**Decision:** the parent repo gitignores `app/`. The fork keeps its own history
on branch `latchkey` with `upstream` pointing at aperture-plus, and each
milestone is committed in **both** repos: the code in `app/`, the docs and
harness in the parent.

**Why:** §4.2 allows a local-only fork, and there is no fork URL yet. Committing
`app/` into the parent as a bare gitlink (no `.gitmodules`) would leave the
parent permanently showing `modified: app (new commits)` and would not survive a
re-clone. Gitignoring keeps both trees honest.

**Consequence to know about:** the parent does not pin which `app/` commit it
describes. Each milestone entry below therefore records the `app/` SHA, and
pushing `app/` to a private remote is a real (small) follow-up before this is
backed up anywhere.

**M0 landed as `app/` commit `3cc8d5f94`.**

---

# M1 — Strip to single purpose

## 2026-09-20 — Also remove TestFlight/App Store, not just macOS

**Decision:** delete the `tf*` Makefile targets, `ExportOptions.AppStore.plist`,
`ExportOptions.MacAppStore.plist`, `scripts/tf-check-creds.sh` and
`README.testflight.md` along with the macOS target. Keep `make ipa`.

**Why:** §1.3 lists App Store/TestFlight as a non-goal, and the route is not
merely unwanted but closed: the vendored `TailscaleKit.xcframework` fails App
Store validation for a missing privacy manifest
([libtailscale#57](https://github.com/tailscale/libtailscale/pull/57), open and
blocked). Leaving the targets in place invites someone to spend forty minutes
on an archive that cannot be uploaded. `make ipa` is dev-signed for a real
device, which *is* the install path, so it stays.

**Evidence:** `app/Makefile`; `app/scripts/strip-mac-makefile.py`.

## 2026-09-20 — `proxyEverythingRequested()` no longer reads `prefs.ExitNodeID`

**Decision:** the split tunnel's "proxy everything" mode is now reachable only
through the `-ProxyEverything` launch override. A non-empty `ExitNodeID` in
prefs is logged and ignored.

**Why:** upstream tied the two together deliberately — an exit node is the one
legitimate reason to push public traffic through the tailnet — and the Exit
Node toggle doubled as the on-device routing control. §1.8 removes that toggle
because exit nodes are broken under tsnet (§7.4). That leaves a trap: nothing
can clear an `ExitNodeID` any more, so one arriving from restored prefs or a
tailnet policy would silently route every public request through a proxy with
nothing carrying it, and the user would have no way to turn it off. The
symptom would be "the whole internet is broken in this app", with no control
to undo it.

`TailnetProxyPolicy` itself is untouched, and `make test-policy` still covers
the proxies-everything case — `-ProxyEverything` still reaches it.

**Evidence:** `TSNet/TSNetManager.swift`, `proxyEverythingRequested()`.

## 2026-09-20 — A floating gear on the dashboard

**Decision:** `DashboardRootView` draws one small, semi-transparent gear in the
top-trailing corner, carrying the same `settings-button` identifier the
connection gate uses.

**Why:** this was a bug introduced by §1.5, caught by the UI tests. Deleting
the browser toolbar also deleted the only Settings entry point that exists
*after* connecting — the gate's gear is gone by then. Settings owns the log
viewer and the routing diagnostic, which §1.9 explicitly says to keep, so
without this they were reachable only by ⌘, on a hardware keyboard: that is to
say, not at all on an iPhone.

Rejected: leaving it keyboard-only (unusable on the target device); a
swipe/long-press gesture (undiscoverable, and it would fight the dashboard's
own gestures); restoring a toolbar (defeats §1.4/§1.5).

**Evidence:** `App/Browser/DashboardRootView.swift`, `settingsAffordance`.

## 2026-09-20 — The log viewer moved into Settings

**Decision:** `LogViewer` is presented from `SettingsView` → Diagnostics rather
than from the browser view.

**Why:** the same §1.5 fallout. Its only entry point was the compact toolbar's
"more" menu. Settings is reachable from both the gate and the dashboard, so
putting it there also makes the logs readable *before* the tailnet connects —
which is when a connection failure most needs reading.

**Evidence:** `App/Settings/SettingsView.swift`, the `Diagnostics` section.

## 2026-09-20 — UI test suite: 29 tests → 13, and what that costs

**Decision:** delete the 16 tests whose features no longer exist; re-point the
survivors at the UI that does.

**Removed as dead:** exit node (1), tabs (3), bookmarks (1), address bar (1),
workspace switcher (2), the connection-type indicator that lived in the deleted
toolbar (1), and two keyboard-layout tests that assert against the Aperture
chat UI's own input field — KiroCrew's dashboard is a different page.

**Removed as a real coverage loss (4), and worth naming:**
`testBadURLShowsErrorOverlay`, `testNavErrorOverlayShowsEscapedURLAndCategory`,
`testHTTPSCertMismatchShowsError`, `testValidHTTPSURLDoesNotShowInvalidError`.
The navigation-error overlay they cover still exists and still matters — it is
what the user sees when the gateway is unreachable. They are gone only because
every one of them navigated by typing into the deleted address bar. **M2 must
re-establish this coverage at L1**, where the harness can serve a bad response
or a bad certificate directly and no URL bar is needed. Cheaper and more
deterministic there than it ever was here.

**Re-pointed:** the "is the browser up" anchor moved from the toolbar's More
button to `connected-browser`; reload moved from a toolbar button to ⌘R;
`openSettings` collapsed from two paths (gear on iPad, More menu on iPhone) to
one gear in both; the Logs path now goes through Settings; the brand-header
identifier changed with the rename; and the default-gateway URL became a single
fixture constant rather than four copies of `http://ai/chat`, so M5 changes it
in one place.

**Evidence:** `scripts/prune-uitests.py`, `scripts/repoint-uitests*.py`.

## 2026-09-20 — Branding is a placeholder, and looks like one

**Decision:** the brand header is an SF Symbol plus the text "Latchkey". The
`ApertureIcon` and `ApertureWordmark` image assets are deleted.

**Why:** they are Tailscale's marks and this is not Tailscale's app. A
deliberately plain placeholder is also honest about M8.1 being unfinished,
where a borrowed logo that looks finished would not be. The `AppIcon` set is
left alone for now — it is what the installer needs to not be a blank tile, and
M8.1 replaces it.

**Evidence:** `App/LatchkeyBrandHeader.swift`.

## 2026-09-20 — Commit directly to `main`; no topic branches

**Decision:** all work is committed straight to the main line: `main` in
`app/`, `master` in the parent (its only branch). No topic branches, pull
requests or merges of our own. Supersedes PLAN §4.2's
`git checkout -b latchkey` and the two mentions of a `latchkey` branch
earlier in this log.

**Why:** Olof's instruction, 2026-09-20: this is a single-developer repository
with no outside contributors, so branch-and-merge ceremony buys nothing. If
that changes, the approach changes with it.

**Applied:** in `app/`, local `main` was fast-forwarded to the tip of the old
`latchkey` branch (a straight line on top of the fork point, so no merge was
involved) and `latchkey` was deleted. No history was rewritten. `main` no
longer tracks `upstream/main`, so pulling cannot silently bring upstream in and
pushing does not aim at tailscale/aperture-plus. Upstream merges stay
deliberate: fetch `upstream`, then merge `upstream/main`. `scripts/bootstrap.sh`
and the "Git workflow" section of `app/AGENTS.md` now say the same thing.

PLAN.md itself is not edited in place. A separate revisions document for it is
on its way, and this log is where divergences from the plan are recorded.
