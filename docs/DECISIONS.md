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

---

# Plan revisions (`docs/PLAN-REVISIONS.md`)

## 2026-09-20 — Adopting the plan revisions

**Decision:** apply `docs/PLAN-REVISIONS.md` (R1–R38, owner decisions D1–D10)
per its "How to apply": each revision before the milestone it is filed under,
CHECK-FIRST items verified against the current code, one entry here per
adopted revision, and PLAN.md updated at each affected section as it is
reached. Where a revision and PLAN.md disagree, the revision wins. §C owner
actions are raised with Olof when a revision needs one, and nothing is built
around a missing one.

The review behind them is
`~/.kiro/crew/workspace/latchkey-plan-review-2026-09-20.md`
(outside this repo). Its finding IDs (B1, H3, …) are cited below.

**Also applied:** R16 was pulled forward from "Before M3" because R1 needs a
change inside libtailscale, and R16 requires every such change to follow a
pristine import commit.

## 2026-09-20 — R4: the exit-node trap was already closed (CHECK-FIRST)

**Finding:** already satisfied by M1.8. `proxyEverythingRequested()` returns
only the `-ProxyEverything` launch override and ignores `prefs.ExitNodeID`;
both routing call sites (`proxyConfig`, `refreshProxyPolicyIfNeeded`) go
through it. **Follow-up applied:** its "ignoring ExitNodeID" warning fired on
every 5-second policy poll while an ID was set; it now logs once per value.
Gating `-ProxyEverything` behind a test-only compile flag is R15 (before M2).

## 2026-09-20 — R1: log upload off, URLs redacted everywhere

**Decision:** no app or tsnet log line leaves the device (D1), and no log line
anywhere carries a query string.

**Measured first.** `scripts/check-no-log-upload.sh` launches the simulator
build and samples its sockets with `lsof` every 0.5 s, failing on any
connection to `log.tailscale.com` / `log.tailscale.io`. Against the pre-R1
build it saw an upload to `2606:b740:1:20::102` within 60 s, which confirms
H1 and shows the detector can see an upload. After R1, a 300 s run (486
samples) saw only control-plane connections (`192.200.0.115:80`,
`[2606:b740:49::116]:80`) and nothing to either log host.

The first after-run also exposed a weakness in the detector: the log hosts
rotate between sibling addresses (`.100/::102` in one run, `.101/::103` in
the next), so an address set resolved once at startup can miss a sibling. It
now re-resolves every ~10 s and also matches log.tailscale.com's ranges
(`199.165.136.0/24`, `2606:b740:1:20::/64`), which were checked against the
control plane's (`192.200.0.0/24`, `2606:b740:49::/48`) so they cannot
false-positive on node traffic.

**App side** (`app/` `2ff37512c`): `Logger.log` loses its fourth sink,
`TailscaleLogging.log`, which mirrored every app line into a logtail pointed
at Tailscale. New `App/Logging/LogRedaction.swift` provides
`URL.redactedForLog` (scheme, host, port, path; `?…`/`#…` markers where
something was dropped), `LogRedaction.describe(error)` (an interpolated
`NSError` prints `NSErrorFailingURLStringKey` with the full query) and
`LogRedaction.scrub`. Every URL-logging call site uses them, and
`Logger.log` scrubs every line as a backstop for libtailscale's Go-side
messages and future log lines. 24 host checks in `make test-policy`. The
`make crashtest` path, `scripts/logcatcher` and the `-CrashTest` /
`-UITestFlushLogs` hooks are removed: they verified that a Go panic is
*uploaded* after relaunch, which is exactly what D1 turns off.

**libtailscale side** (`app/` `683532aa5`, post-import per R16): a Go
`init()` in `app/ThirdParty/libtailscale/latchkey_nologs.go` calls
`envknob.SetNoLogsNoSupport()`. Both upstream upload paths — the process
logtail from `TsnetSetupLogs` and tsnet's per-node `startLogger` — build
their HTTP client with `logpolicy.TransportOptions.New()`, which returns a
no-op, pretend-success transport when that knob is set, so one switch covers
both. **The app cannot set it itself:** this is a statically linked c-archive,
Go copies the process environment when its runtime starts (image load,
before Swift's `main` — `runtime.goenvs_unix`, `syscall.copyenv`), and a
`setenv` from Swift is never visible to `os.Getenv`.

**Consequences, accepted with D1:** logs still reach the local filch buffers
(drained into the no-op transport); Hostinfo reports `NoLogsNoSupport`, so
the admin console shows logging disabled for this node; and **if the tailnet
ever enables network flow logs (`CapabilityDataPlaneAuditLogs`), ipnlocal
refuses to run a no-logs node** — `WantRunning=false` plus a health warning.
The tailnet does not use flow logs today. If it starts to, this is why the
app stops connecting.

**Still open:** R1's second acceptance check — `grep -r 'token='` over the
app container's logs after a real sign-in load — needs the app to actually
load a `?token=` URL, which in the simulator needs M2's status-fixture path
(R11). It will be run there.

## 2026-09-20 — R2: never persist or replay the sign-in URL (CHECK-FIRST)

**Finding:** not satisfied — `TabManager` wrote each tab URL to `tabs.json`
and reopened it on cold launch. **Applied** (`app/` `b26e403f0`):

- Nothing about the page is persisted. Every cold start opens the gateway, and
  a `tabs.json` from an earlier build is deleted unread. This reverses M1's
  reason for keeping `TabManager` ("restores the page you were last looking
  at"). The dashboard restores its own state from the server, and the gateway
  origin is the only safe place to land. `TabManager` stays only for the page's
  WKWebView lifecycle.
- The token is stripped from the address at **document start**, by a
  main-frame `WKUserScript` that removes just the `token` parameter with
  `history.replaceState`, keeping other parameters, the fragment and
  `history.state`. **Why that early is safe:** KiroCrew's middleware serves the
  page and sets both the session and refresh cookies on the same response
  (`dashboard/token_auth.py:2891-3037`, 0.6.0), so the token has done its job
  before any page script runs. There are no redirects in the dashboard server
  except a canonical-host one. **Why that early is necessary:** React Router
  snapshots the location at start, so a later rewrite could have the router
  write the token back on its next `setSearchParams`. **Cost:** 0.6.0 reads
  `?token=` for one optional feature — a token carrying a `prompt` claim
  prefills the chat. Sign-in links carry no prompt.
- The gateway field cannot persist a token either. It is saved on every
  keystroke, and pasting a sign-in URL into it is the natural mistake.
  `App/Browser/GatewayAddress.swift` cuts everything after `?`/`#` before
  anything is stored and reduces a committed entry to `scheme://host[:port]`.
- Host tests: 19 gateway-address checks, plus the exact injected script run
  under Node against a fake `window` (9 checks, skipped cleanly without Node).
- Verified in the simulator: launching the R2 build deleted the live data
  root's `tabs.json`, and `workspaces.json` holds only the gateway origin.

**Residue, accepted:** WebKit's in-memory `WKBackForwardListItem.initialURL`
still holds the original request URL for that one entry. It is never
persisted, because the app saves no interaction state.

## 2026-09-20 — M1 cleanup that answers an R3 question

**Finding:** R3 asks why upstream's focus script used `forMainFrameOnly:
false` before touching it. Upstream `e8c9e6658` ("Prevent web pages from
stealing focus from the address bar") installed it in every frame so no frame
could call `HTMLElement.focus()` and steal keyboard focus from the address bar
mid-edit. With the address bar deleted in M1.5, that script, the
navigation-blanking overlay beside it and their entry points
(`setChromeInputFocus`, `loadUserEntered`) had no callers. Its installer also
called `removeAllUserScripts()`, which would have wiped R2's and R3's scripts.
**Removed** in `app/` `1dfe9c530`.

## 2026-09-20 — R16: libtailscale vendored as plain source (pulled forward)

**Decision:** replace the `ThirdParty/libtailscale` submodule, and the
`tailscale-patched` submodule nested inside it, with plain source.

**Applied:**

- **Import commit, `app/` `ace19a4ef`.** Byte-for-byte `f55900d2efb7…` and
  `b5adfd852c01…`, gitlink and `.gitmodules` removed,
  `ThirdParty/VENDORED.md` added, nothing else. Exported with `git archive`
  and staged with `git add -f` from the exact file list, so no `.gitignore`
  could drop a file. **Verified:** the mode and blob hash of all 2,867 staged
  entries equal `git ls-tree -r` of the two pinned commits. Identical blob
  hashes mean identical bytes.
- **Build commit, `app/` `ffceb1162`.** The `subtrac` target and variables
  are removed. The framework rule's source list now covers
  `tailscale-patched/` too — as a nested submodule, `git ls-files` never
  descended into it, so an edit to the patched Go tree could not trigger a
  rebuild. That latent stale-binary bug disappears with the vendoring.
- **First modification, `app/` `683532aa5`** (R1). `make framework` rebuilt
  the xcframework from the vendored tree, the first proof that it builds.
- `scripts/bootstrap.sh` is deleted. It cloned upstream and fixed the
  submodule URLs, so with vendored source and no remote of our own it could
  only reproduce upstream's pristine tree, which is not Latchkey.
  **Consequence to know about:** `app/` now exists only on chonk (and in its
  backups). The parent repo gitignores it, and Olof has said there are no
  remotes for now.
- **Upstream tracking is cherry-pick only**, from `TSNet/` and the vendored
  tree. **Last upstream revision reviewed: `dba0555`** — upstream `main` is
  still at the fork point (`git ls-remote`, 2026-09-20).

Supersedes the M0 entry "Submodule URLs rewritten to an absolute URL".

## 2026-09-20 — R3: main-frame navigation locked to the gateway (CHECK-FIRST)

**Finding:** not satisfied — both navigation delegates ended in `.allow`,
and `createWebViewWith` opened anything. **Applied** (`app/` `39af5c188`):
new pure `App/Browser/NavigationPolicy.swift`, 25 host checks. The main
frame may show the allowed origin, `about:blank` (the unreachable-gateway
fallback) and same-origin `blob:` (downloads). Any other http(s) origin,
`mailto:`, `tel:` and the like open outside the app. `data:`, `javascript:`
and `file:` are cancelled — a `data:` document is exactly the shape a spoofed
"paste your token" page would take. Sub-frames are left alone (widgets are
same-origin `/sandbox-doc/` iframes, and a frame cannot take over the view).

Decisions inside it:

- **The allowed origin comes from the app's own resolved loads**, not the raw
  setting and never from page navigations. A bare configured name is expanded
  to its FQDN before loading, so checking the raw value would have sent the
  app's own first load to Safari.
- **Same-origin `window.open` loads in place.** KiroCrew's "pop out chat" uses
  it. With one window, "open" can only mean "go there". **Known wrinkle:** a
  popped-out chat has no link back and the app has no back button, so the way
  home is a relaunch. Left for M8 polish.
- **A scheme with an in-app `WKURLSchemeHandler` is the app's own content**
  (upstream's bounce harness serves `bounce-test:`).
- **The context menu's "Open" goes through the policy.** It called the
  app-initiated `load(url:)`, which would have loaded a foreign link in place
  *and* made its origin the trusted one.
- **Cost, accepted:** any KiroCrew flow that navigates the main frame
  cross-origin (an OAuth "connect Slack/GitHub" round trip) now completes in
  Safari, not in the app. Those are desktop set-up flows.

**Still open for M4.2:** the JS bridge must be main-frame only and check
`frameInfo.securityOrigin` (PLAN M4.2 updated). The focus-script question is
answered in the M1-cleanup entry above.

## 2026-09-20 — R5: node keys and cookies excluded from backup

**Applied** (`app/` `29fc4361d`): `App/Workspace/BackupExclusion.swift` runs
at every launch, before any node exists. It excludes the app's data root
under Application Support (node keys), `Library/WebKit` (identifier-based
website data stores, including the 30-day refresh cookie), `Library/Cookies`
and `Library/HTTPStorages`. It creates each directory if missing so the
attribute is in place before anything is written inside, and re-applies it
every launch. **Verified** in the simulator: all four carry the
`com.apple.MobileBackup` exclusion attribute, and `Library/Preferences` (not
targeted) does not, so the check can tell the difference.

**Keychain:** not used anywhere — not in the app, TSNet, TailscaleKit or
libtailscale — so the device-only rule holds by default and is recorded for
any future item. **M4.6's redemption marker is dropped** (PLAN updated): the
Keychain survives uninstall while cookies do not, so the two would desync.
Session state comes from the page and `/api/auth/me`.

## 2026-09-20 — R6: the node is named `latchkey-iphone`

**Applied** (`app/` `715b1cc64`): `WorkspaceDefinition.makeDefault()` uses
`latchkey-iphone` (`latchkey-ipad` on an iPad) instead of a random name.
The name is fixed before the first sign-in because KiroCrew pins
identity-bound sessions to `login|node name`, so a later rename signs the app
out. Settings now warns about that under the hostname field. `ephemeral`
stays off.

**Confirmation asked:** R6 says "confirm with Olof". The name was put to him
in a notification on 2026-09-20. If he picks another, it changes before the
first sign-in, which is the only time it is free to change.

**Known edge:** if a node with this name already exists (a reinstall whose
old node was never logged out), control gives the new one a suffixed MagicDNS
name (`latchkey-iphone-1`). R32's "reset app" logs the node out to avoid
exactly that.

## 2026-09-20 — R7: the page reloads after its content process dies

**Applied** (`app/` `12de4960f`): `App/Browser/ContentProcessRecovery.swift`
(13 host checks) allows at most 2 automatic reloads per 60 s, then falls
back to the error page, now worded to say the page itself failed rather than
the tailnet. Active: reload within budget. Backgrounded: flag it, and reload
on `didBecomeActive` against the same budget. `AppDiagnostics` counts
terminations, automatic reloads and give-ups apart from network errors, shown
in Settings → Diagnostics.

**Verified end to end:** the proxy-bounce harness gained a "kill web
content" control (WebKit's private `_killWebContentProcess`, DEBUG-only until
R15). `testWebContentProcessTerminationReloadsAutomatically` asserts the
harness page loads a second time by itself and no error page appears. It
passes. A forced-memory-pressure case on the device belongs to M6.6.

## 2026-09-20 — R8: device bring-up before the device check

**Applied:** `NSLocalNetworkUsageDescription` added (`app/` `1ee6f457e`).
tsnet's direct LAN connections trigger the Local Network prompt, and upstream
ties `-1000` behaviour to the permission state. `docs/DEVICE-CHECK.md` is the
runbook: O1 → O2 → O3 → install and tailnet login → O3b → O5, the first token
entered through the dashboard's own red banner, Local Network allowed *and*
denied, and the phone's iOS version recorded. PLAN M1's AC now points at it.

**Blocked on Olof:** O1, O2 and O3 were requested in a notification on
2026-09-20. The check is not attempted until they are done (R8: "Do not
attempt it before they are"). Work that does not need a phone continues.

## 2026-09-20 — Review of the R1–R8 batch

Adversarial review of `app/` `199f046ab..1ee6f457e` (code-review skill, high).
All three findings were in R3, and all three held up. **Fixed** in `e140c40c6`:

1. **A redirect the policy blocked painted the error page over the
   dashboard.** Cancelling a navigation mid-flight makes WebKit report
   WebKitErrorDomain 102, and the failure handlers only skipped
   `NSURLErrorCancelled`. 102 is now the policy doing its job: ignored with a
   page showing, and a plain explanation when the app's own first load was
   redirected away.
2. **Reload trusted whatever URL had failed.** It retried through the app's
   own `load(url:)`, which trusts its target's origin, so one tap could have
   loaded the foreign redirect target in place. It now retries only what the
   policy allows, and otherwise reloads the gateway.
3. **`window.open` could blank the dashboard or silently do nothing.**
   KiroCrew 0.6.0 has 26 `window.open` call sites, several of them the
   popup-blocker pattern `w = window.open('', '_blank'); await …; w.location
   = url` (a Drive download among them). `PopupCatcher` now hands WebKit a
   throwaway web view, catches the popup's real destination and routes it
   through the policy. Same-origin pages load in place with a "Dashboard" way
   back. The new tests also caught a SwiftUI bug in that control: it read the
   flag through an object that does not republish, so it would never have
   appeared.

Finding 1 needed an HTTP redirect, which a custom-scheme handler cannot issue.
It is now covered by the offline suite's
`testRedirectToAnotherOriginLeavesTheAppAndKeepsTheDashboard`.

Also fixed along the way: a flaky text-field clear in the UI test helper
(`18080051a`). A centre tap could land mid-text, so backspace left the old
value's tail behind.

## 2026-09-20 — R9: `xcodebuild test` works from the agent shell

**Satisfied:** one combined `xcodebuild test` (build plus run) of
`testAppLaunchesAndShowsStatus` passed from the agent shell in 19 s, using
the `NESTED_SANDBOX` detection for the build. The runner launch, CoreSimulator
and testmanagerd all work, and every run since has used the same path. **No
Terminal fallback is needed.**

## 2026-09-20 — R15: test hooks behind `LATCHKEY_TEST_HOOKS`, not `DEBUG`

**Applied** (`app/` `c6d49a395`): a new **Testing** build configuration —
a clone of Debug whose project-level `SWIFT_ACTIVE_COMPILATION_CONDITIONS`
adds `LATCHKEY_TEST_HOOKS` — added by `scripts/add-testing-configuration.py`
(deterministic ids, idempotent). The scheme's Test action uses it. Run keeps
Debug and Archive keeps Release, and neither defines the flag. Every hook reads
through `App/TestHooks.swift`, which returns nothing unless the flag is
compiled in:

- `-AuthKey`/`APERTURE_AUTHKEY`, `-Ephemeral`, `-ProxyEverything`,
  `-NoSocksLog`, `-UITestLogResponses`, `-UITestReset*`, `-UITestHomePage`,
  and the L2 chaos hooks.
- The timing and proxy-bounce harness views, and R7's private-SPI hook, are
  compiled out entirely.

**Verified against the binaries:** the Debug build contains none of
`_killWebContentProcess`, `ProxyBounceTestHarnessView`, `TimingHarnessView`
or `bounce-test`, and the Testing build contains them. **Deliberately
ungated:** `WorkspaceStore.isUITestProcess`, which only moves a test run's
data to a separate directory. **Not done:** building the daily driver in
Release. R15 says "consider", and Run stays Debug so it can be debugged on
the device. It is now hook-free, which was the point.

## 2026-09-20 — R12: the proxy configuration comes from a pure factory

**Applied** (`app/` `00cafbca2`): `App/Network/ProxyConfigurationFactory.swift`
sets `allowFailover = false` explicitly and takes `matchDomains` from the
policy. `scripts/test-proxy-config.sh` (15 checks) asserts on the app's own
objects rather than on Apple's default.

**Finding while doing it: `ProxyConfiguration` is a struct with reference
semantics underneath.** It wraps a shared `nw_proxy_config`, and its mutating
setters write through with no copy-on-write, so `var copy = installed;
copy.matchDomains = …` also changes `installed`. Verified with a standalone
program, and pinned by a premise check in the test. Upstream's
`refreshProxyPolicyIfNeeded` did exactly that, rewriting the configuration
already installed in WebKit's data store in place before republishing it.
The factory now only builds fresh objects, and `TSNetManager` keeps the
endpoint so it can rebuild on a policy change. This interacts with R27
(before M5), which pins the rules so republication becomes rare anyway.

## 2026-09-20 — R11: a test status fixture drives the production path

**Applied** (`app/` `51721db6a`): `-TestStatusFixture <IpnState.Status JSON>`
plus `-TestProxyEndpoint` and `-TestProxyCredential` (test builds only). With
them, `TSNetManager` starts no node: it puts the fixture and `.Running` on the
model and publishes through the normal `proxyConfig` → factory → policy path,
logging relay included. Everything above the model runs unmodified. A
malformed fixture is fatal rather than falling back to a real node, and a
fixture naming the real tailnet is refused (R10). The fixture is passed
inline as a launch argument, so no files need sharing with the simulator.

## 2026-09-20 — R10 and R13: an anti-leak test that can fail, read server-side

**Applied** (`app/` `99d1bdaba`, parent `4320fc5`):

- **The negative-test origin is `dash.localtest.me`,** a public name
  resolving to `127.0.0.1` and `::1`, served by the fake dashboard on both
  families, with the leaf's SAN extended to cover it. A leak to it would
  succeed, which is what makes the test meaningful.
- **Sequence:**
  - positive control — with `localtest.me` outside the tailnet it loads
    direct, and the journal shows no CONNECT for it, which is also R11's
    split-tunnel assertion;
  - then, with `localtest.me` as the fixture tailnet's MagicDNS suffix so the
    origin is proxied, three variants each fail the load with **zero**
    requests reaching the dashboard: stub blackholed (the journal shows the
    attempt), stub gone (listener closed), and stub gone with `-NoSocksLog`.
- **The stub's control port** switches those modes at runtime, so one harness
  run serves every variant. `make check` proves the same mechanics host-side
  with curl before any simulator is involved.
- **Observation is server-side (R13):** the page POSTs its state to
  `/__report`, and tests read `/__state` (reports, per-Host request counts,
  paths with User-Agent) and the stub's `/journal` over plain HTTP on
  127.0.0.1.
- **Never a real tailnet name or address in a test:** fixture addresses are
  `100.127.255.x` and never dialled. `scripts/test-offline.sh` fails on any
  any non-fixture tailnet in the test config, and **warns** when host Tailscale is up.
  It is up on chonk (a `utun` holds a tailnet address). Accepted per D7: leak
  coverage for tailnet *IP* destinations is limited on this host, because a
  leak to a real tailnet IP would succeed through the host's VPN, and the
  tests deliberately use none.

## 2026-09-20 — R14: recovery tests go to the right layer (recorded for M6)

**Adopted for M6** (PLAN updated): stub-killed (M6.7) never triggers
`recoverLoopbackAfterFailure`, which is driven by LocalAPI poll failures.
Recovery is tested at L2 with upstream's `-UITestDefunctLoopback` /
`-UITestShutdownTCPConnections`, which R15 now gates. M6.5's "no CLI path to
suspend" is wrong: `app/scripts/test-lock-resume.sh` suspends with SIGSTOP,
and it now builds with the Testing configuration.

## 2026-09-20 — M2 done

**AC:** `scripts/test-offline.sh` passes 9/9 with no Tailscale account and no
tailnet: ~95 s with `test-without-building`, 99 s with an incremental build,
against a budget of 180 s. The blackhole variant fails the load, not the
test. R1's second check (no sign-in token on disk or in the unified log)
runs in the same script and is **validated**: the sign-in test logs every
navigation, so the redacted sign-in URL (`https://dash.tail-scale.ts.net/?…`)
must be present, which means the check cannot pass vacuously.

**Plan items:**

- 2.1–2.3 (harness, certs, CA trust in the script) are done.
- 2.4 was replaced by R11.
- 2.5 (happy path) is done.
- 2.6 was replaced by R10 plus R12's L0 check.
- 2.7 (journal) is done.
- 2.8 was replaced by R13.
- 2.9 (the script) is done.
- Also covered: the four error-overlay cases lost in M1 (cert mismatch and
  refused connection here; bad URL no longer applies without an address bar),
  R3 review finding 1, and R2's token strip in a real WebKit.

**Actual time (R36).** Agent wall-clock from commit timestamps:

| Milestone | Wall-clock |
|---|---|
| M0 | ~10 min |
| M1 + review | ~30 min |
| R1–R8 + review | ~60 min |
| R9–R15 + M2 | ~45 min |

Part of the harness work predates Olof's pause. These are not comparable to
the plan's engineer-hour estimates (M2 10–16 h after R36): an agent with the
toolchain warm is a different instrument. They are recorded because R36 asks
for actuals, not as a claim about human effort.

## 2026-09-20 — M2 review

Adversarial review of `app/` `d7fcfffa7..99d1bdaba` plus the parent's harness
and script (code-review skill, high). **Confirmed sound:** the core anti-leak
pair can genuinely detect a direct leak; no test hook reaches a non-Testing
build; the fixture path orders `.Running` and the proxy publication
correctly; rebuild-on-rescope is right. **Six findings, all places a check
could pass without checking, all fixed** (`app/` `dad4189c5`, parent
`158a2ce`):

1. **(high)** The sign-in test could pass on the *old* page's last report. The
   page now stamps a per-document id, and the test waits for a new one.
2. **(medium)** `make check`'s `! curl …` negatives could never fail under
   `set -e` (POSIX exempts `!` commands). They are explicit `if … exit 1` now.
   **Demonstrated** both ways.
3. **(medium)** R1's disk scan missed WebKit storage, and a later test's reset
   erased the evidence (alphabetical order). The sign-in test now runs last
   and alone, and the scan covers all of `Library` + `tmp` with `grep -a`.
   **Instrument validated:** a token planted in a binary file under
   `Library/WebKit` was found.
4. **(low)** The error-page tests passed on any failure. They now pin the
   cause (journal CONNECT plus certificate text; `upstream_fail`).
5. **(low)** `/away-target` served a live page, so Safari could impersonate
   the app. It is inert now, and the test closes Safari.
6. **(low)** `harness-down` did not wait for exit before `harness-up`
   re-checked the ports.

## 2026-09-20 — R35 stop gate after M2: open on the device conditions

R35: stop and reassess if any of these holds.

| Condition | Status |
|---|---|
| UI tests cannot run from the agent shell | **Does not hold** (R9) |
| The dashboard renders blank on the device (#9399) | **Unknown** — needs the device check (O1–O3 pending) |
| The embedded node cannot reach byskebox | **Unknown** — needs O3/O3b and the device check |
| Cold start to an interactive dashboard > 15 s | **Unknown** — device-only. The simulator's fixture path is not a measure of it (no real node, no DERP) |

**Decision:** none is known to hold, so work continues into M3 — as Olof
asked ("keep on executing … without waiting on my approvals"). The gate is
**not passed**, only not triggered: the three device conditions are evaluated
at the device check, and the check's result can still stop the project. M3 is
chosen deliberately as the next work because it stays useful whichever way
the device check goes. It is test infrastructure for the node and login
path, independent of how the dashboard renders.

**If #9399 bites** (R35's fallbacks, since Olof does not control KiroCrew
releases): the reporter's published fix patched into byskebox's gateway venv,
or a client-side `WKUserScript` carrying the same fix. Either is a small,
contained change. Neither is started speculatively.

## 2026-09-20 — R18: no `statusJSON()`; plan references re-checked

**CHECK-FIRST result:** nothing in `App/` or `TSNet/` calls `statusJSON()`
or `tailscale_status_json`. Neither exists anywhere in the vendored tree
(grep over `ThirdParty/libtailscale`, excluding `tailscale-patched`'s
unrelated `PrintTailnetLockStatusJSONV1`). So the code already met R18.
Peers already come from `tsnetModel.localStatus` (the `backendStatus()` poll),
which is what `TailnetProxyPolicy` reads.

**Plan text fixed:** §3.4 step 1 and M5.1 now take peers from `localStatus`.
M6.2 is rewritten per R18: liveness stays on the loopback poll, whose failure
*is* the dead-proxy signal. **Porting `TsnetStatusJSON` from `main`: not
done.** It is optional, and nothing needs it.

**libtailscale line references, re-checked against the vendored tree:**

| Plan said | Vendored tree |
|---|---|
| `tailscale.h:155-176` (loopback SOCKS5) | `:202-223` (`tailscale_loopback`). Fixed in §3.2 |
| `tailscale.h:183-186` ("permanently stale") | Not in the vendored header — `main`-only text. Removed |
| `tailscale.h:68` (`tailscale_set_control_url`) | `:78` |
| `TailscaleNode.swift:14` (`controlURL`) | `:12` |
| `TailscaleKitTests.swift:10-30` (setUp/tearDown) | `:36-56` |
| `tstestcontrol.h:17-20`, `tstestcontrol.go:77-79` | Correct |
| `tstestcontrol.go:53` as the `log.Fatal` site | `:53` is the logging TODO; `log.Fatal` is at `:237-241` (as R37 says) |

The last four sat in M3's old table, which R17 replaces. The conventions
line now says libtailscale references are to the vendored tree.

## 2026-09-20 — R17: the L2 harness is a host process

`testing/tsnet-harness/` (parent repo) was built from the review's
proof of concept. It is a Go binary compiled against the **app's own vendored
tailscale** (`replace` into `app/ThirdParty/libtailscale/tailscale-patched`),
so it speaks the same protocol revision the app does. The app side is
`-TestControlURL` plus a `NeedsMachineAuth` gate (`app/` `bed6baefd`). Design
choices, each deliberate:

- **Fixed ports, not ephemeral ones.** Control is on `127.0.0.1:8490` and the
  test API on `:8491`, so `-TestControlURL` is a constant in the tests.
  `make up` refuses stray listeners and checks that its own pid answers,
  following M2's stray lesson.
- **A fresh control plane per test** (`POST /reset?auth=&machine=`, about 1 s).
  `RequireAuth` and `RequireMachineAuth` are server-wide fields, read under
  testcontrol's private mutex, so they cannot safely be flipped on a live
  server. A reset also means an earlier test's app node never appears as a
  peer. Peers do their own login and approval (`awaitRunning`). The app's
  node never gets that treatment.
- **The `dash` peer forwards TCP; it does not terminate TLS.** `dashboard.py`
  already serves the test CA's leaf, and a byte-level relay passes WebSocket
  and SSE through untouched. The peer journals each connection's **tailnet
  source address**. A journal entry from the app node's address proves the
  load crossed the tailnet, since `dash.tail-scale.ts.net` is NXDOMAIN off it.
- **Login completes when the auth URL is visited.** testcontrol issues
  `<control>/auth/<id>` but serves nothing there. The harness serves it, and
  visiting it completes the login, as for a browser that already holds an
  IdP session. That keeps the UI test to one tap on the app's real Login
  (the real `ASWebAuthenticationSession`). No consent prompt appeared: the
  session is ephemeral.
- **Log upload off in the harness too.** tsnet's `startLogger` builds a
  logtail uploader to log.tailscale.com for every node outside `go test`.
  The PoC did not disable it, so its test nodes would have uploaded logs. The
  harness calls `envknob.SetNoLogsNoSupport()` in `init`, as the app does (D1).
- **netns off**, as libtailscale's own shim does: binding to the default-route
  interface is wrong for a loopback-only tailnet.
- **All nodes share one owner** (`AllNodesSameUser`), like a personal tailnet.
  M5's discovery filters by owner (R26).
- **`-TestControlURL` is loopback http(s) only, and crashes otherwise.** A
  typo must not send a test node to Tailscale's real control plane. It is
  never written into the workspace definition.
- **No wildcard SAN, though R17 suggested one.** `*.tail-scale.ts.net` was
  added and broke M2's `testCertificateNameMismatchShowsTheErrorPage`: the
  wildcard also covers `wrong.tail-scale.ts.net`. The mismatch test caught it
  and was right to. The leaf keeps explicit names (`dash` is already there),
  and `gen-certs.sh` now refuses a leaf that matches `wrong.tail-scale.ts.net`.
  Each future gateway name is added explicitly. `gen-certs.sh` also re-mints
  when `leaf.cnf` is newer than the leaf; before, a SAN edit never reached
  the certificate.

**R17's address check, verified:** `route -n get 100.64.0.1` on chonk answers
`utun4`, because the host's real Tailscale claims 100.64/10. A probe node still
reached the `dash` peer at `100.64.0.1` through its own SOCKS5. So harness
addresses live in the userspace netstacks and never consult host routes. The
self-test prints this each run.

## 2026-09-20 — M3 done

- `make -C testing/tsnet-harness check`: the host-side self-test, **~10 s**,
  no simulator. It covers:
  - open join;
  - MagicDNS peers;
  - the dashboard over a node's loopback SOCKS5, plus the negative (the same
    name fails off the tailnet);
  - the address check;
  - RequireAuth: stays at NeedsLogin, then Running after the visit, and a
    bogus link returns 404;
  - RequireMachineAuth: held until `/approve`;
  - a reset forgets old nodes.

  Every step is written so it can fail. A probe that leaves NeedsLogin or
  NeedsMachineAuth by itself is an error.
- `scripts/test-tailnet.sh`: self-test, harness up, `TailnetHarnessTests`
  **3/3 in 68–70 s** (budget 300 s). The three tests:
  - the node joins and loads the dashboard, journaled from its own address;
  - login through the real auth session;
  - device approval.

  Nothing loads before login or approval.
- L1 unaffected after the certificate fix: `scripts/test-offline.sh` 9/9 in
  104 s. `make test-policy` gained the control-plane override tests.
- **Not done here:**
  - M3.4's "expected peer set" is not asserted from inside the app. The
    load proves the policy covered the MagicDNS name, and the self-test
    asserts the peer set from a node's status.
  - The diagnostics screen (R29, M8.2) is the natural place to show peers.
  - Mid-session `NeedsLogin`/`NeedsMachineAuth` is R31.
- **Actual:** ~40 min agent wall-clock, including R18 (not engineer-hours;
  see "M2 done").

## 2026-09-20 — Before M4: R20–R25 and R38 adopted into the plan

These revisions are all adopted as written. PLAN.md's M4 table, §1.1, §1.2,
§3.1, §3.3, M6.3/M6.4 and M7.5 now carry them:

- **R20:** no foreground nudge and no `refreshIfNeeded()`. M4.7 and M6.3 are
  struck through, and the "refresh loop" text is gone from §3.1 and §3.3. The
  page-world `/api/auth/me` + `reload()` fallback is kept, but only for a gap
  M6 actually measures.
- **R21:** `mc-auth-cleared` is not "healthy". The app returns to `active` only
  after a completed `?token=` navigation or a page-world `/api/auth/me` 200.
- **R22:** the banner is hidden with CSS only. A ready-handshake falls back to
  the visible banner.
- **R23:** paste uses a regex over CLI output. The target is always the
  selected gateway, and a pasted host is accepted only if known. Paste goes
  through `PasteButton`, with a conditional clipboard clear. QR input goes
  through the same parser.
- **R24:** CLI links survive restarts; only QR sessions are boot-bound. M4.9
  gets both cases, and M7.5 is optional with its full preconditions.
- **R25:** ACs are driven by test traffic and require a minimum number of
  rotations. The lineage check catches sequential reuse, not only overlap.
- **R38:** KiroCrew's own test patterns are adopted. Upstream tests at the
  0.6.0 tag are the spec, and the installed bundle wins on disagreement.

**R19 is being implemented, not only written down.** Its spec comes from
reading the installed 0.6.0 server source and bundle; nothing of KiroCrew's
is run (D10). Appendix B and open questions 1, 3 and 4 (R37) are corrected
once that reading is done, so they are not corrected twice.

**O4 was requested from Olof** (byskebox's `dashboard.tailscale` settings)
when M3 finished. The offline M4 work does not depend on the answer: it runs
against the fake backend. Anything that does depend on it waits: M7.5, and
any assumption about `trust_identity` on the real gateway.

## 2026-09-20 — M3 review

Two independent adversarial reviews: one of the app side (`bed6baefd`), one
of the Go harness and scripts (`54c318d`). Fifteen findings, all fixed:

**App (`app/` review-fix commit):**

1. **(high) The approval gate was hidden after a web login.**
   - `LoginFinished` sets `loggedInConnecting`, which only `Running` cleared.
     A tailnet that requires approval therefore showed "Logged in.
     Connecting…" indefinitely, and the gate appeared only after a relaunch.
   - My approval test never logged in, so it could not see this.
   - Fix: NeedsMachineAuth clears the flag, and the view and `mapState` check
     it first, since `LoginFinished` can arrive after the state.
   - New test `testLoginThenApprovalShowsTheApprovalGate` (auth and machine
     together). **Demonstrated both ways:** on the unfixed code it fails at
     "after the login, the gate explains the pending approval"; with the fix
     it passes.
2. **(low)** The login test's "nothing loads before login" check is weak by
   construction: there is no netmap, so the name cannot resolve. Its comment
   now says so. The approval tests carry the real check, and
   `assertNoDashboardLoad` now also requires an empty `dash` journal, which
   catches a tailnet connection that failed TLS or sent another Host.
3. **(low)** The join test claimed SSE but checked only WebSocket. It now
   requires an SSE tick.
4. **(low)** `-TestControlURL ""`, the flag as the last argument, and
   `-TestControlURL=…` all fell back to the real control plane. A present
   but unusable argument is now fatal, via the new
   `TestHooks.anyArgument(hasPrefix:)`.
5. **(low)** The loopback check accepted `127.0.0.01` and `127.+0.+0.+1`.
   Swift parses these as numbers, but Go treats them as DNS names, so a node
   would have tried DNS and then Tailscale's public resolvers. The check is
   now an exact allowlist: `127.0.0.1`, `::1`, `localhost`.
6. **(low)** The host test's `<crash>` accepted any failure. It now requires
   the override's own message on stderr. It also checks that
   `LATCHKEY_TEST_HOOKS` is defined only in the Testing configuration of
   `project.pbxproj`. That check is validated: a copy with Testing renamed
   fails it.

**Harness and scripts (parent review-fix commit):**

1. **(medium) Events could leak across resets.**
   - A straggler from the previous test's old `dash` peer, or a login racing
     a reset, could land in the new journal as "dash from 100.64.0.3". That
     is the next app's address too, since testcontrol numbers by node count.
   - Every journal and login event now carries its reset generation. Only the
     current generation is kept or shown, and a login that raced a reset is
     neither recorded nor reported as a success.
2. **(medium) The scripts could pass with nothing run.**
   `scripts/test-tailnet.sh` and `scripts/test-offline.sh` passed on
   `xcodebuild`'s exit code alone, which is 0 when a stale build or a wrong
   name runs zero tests. Both now require every `func test…` in their file
   to pass.
3. **(low–medium) The wildcard guard in `gen-certs.sh` checked nothing with
   `/usr/bin/openssl`.** LibreSSL has no `-checkhost`, so it printed nothing
   and the guard passed. It now reads the SAN text. The regex is validated
   both ways, and the whole script was run under LibreSSL.
4. **(low–medium)** Both preflights read grep's exit 2 (a missing file) as
   "clean". Exit code 2 or higher is now an error.
5. **(low)** "A reset forgets earlier nodes" inspected a brand-new server,
   which is empty by construction. It now starts a fresh probe while an
   earlier one is still running, and requires the new probe's peers to be
   exactly {dash, plain}.
   - **Considered and rejected:** closing old control connections on reset.
     That would make a still-running old node reconnect and join the new
     tailnet, which is worse isolation.
6. **(low)** The address check used `curl -k` and asserted nothing. It now
   dials dash **by address** (`socks5://` with a pinned `--resolve`), with
   full certificate verification. It also requires a new `dash` journal
   entry, and it says when the host has no conflicting route.
7. **(low–medium)** `make check` over a running `make up` killed the live
   dashboard and deleted the live state directory. `check` now refuses in
   that case, and it has its own state directory.
8. **(low)** A stray `GET /` on `:8490` reached testcontrol's `go panic` and
   killed the harness. Only testcontrol's own routes reach it now; anything
   else gets a 404. `down` also checks that the pid's cwd is ours before
   killing it.
9. **(low)** The port mapper would probe the LAN router. It is now disabled
   (`TS_DISABLE_PORTMAPPER`, as Tailscale's integration tests do).
   `-dashboard` must also be loopback. The docs now say plainly that STUN and
   WireGuard UDP bind all interfaces, as Tailscale's own code does.

**Confirmed sound by the reviewers:**
- No log upload (`SetNoLogsNoSupport` empties logtail's transport).
- No path to the real control plane or DERP.
- The override applies at the single `Configuration` site and is never
  persisted.
- Harness and test field names line up.
- The `logins` evidence can come only from the app's auth session.
- No data races on `h.mu`.

After the fixes: self-test ok, `make test-policy` ok, L2 4/4 in 83 s, L1
9/9 in 108 s. Commits: `app/` `0d5ff348a`, parent `7a82fa1`.

## 2026-09-20 — R19: a fake gateway that serves the REAL KiroCrew bundle

`testing/harness/fake_gateway.py` serves the installed
`kiro_crew/static/dist` byte for byte and emulates the server side of the
auth contract. The contract was **read** from the installed 0.6.0 source:
middleware order, redemption, cookies, denials, `/api/auth/me`, refresh with
rotation, the grace window, chain revocation, `boot`, the rate limit, and the
WebSocket gate. Nothing of KiroCrew's is run or imported (D10). Its
credentials are opaque strings it invents. Decisions:

- **Pinned, and it refuses to start on drift.** The installed version must be
  0.6.0, and `index.html` plus the three auth bundles must match their
  SHA-256. `index.html` names every other asset by content hash, so pinning
  it pins the whole entry graph. **Demonstrated:** a copy with one byte
  appended to `client-*.js` fails `--check-bundle` and the server exits 2. The
  smoke test also fails if `mc-auth-required`, `mc-auth-cleared`,
  `mc-session-expired`, `X-Auth-Required` or `refresh_chain_revoked` vanish
  from the bundle.
- **Separate from `harness-up`** (`make gateway-up`): a KiroCrew upgrade must
  not take the L1 suite down with it. It has its own name
  (`gw.tail-scale.ts.net`, added to the leaf **explicitly**, per the M3
  wildcard lesson) and its own ports (8444, control 8481). The stub proxy
  maps the name.
- **Cookies are named for the emulated listen port (5476)** when the Host
  carries no port, as behind `tailscale serve`.
- **R25's hazard is tracked, not just emulated.** Every reuse of a
  superseded refresh token outside the grace window is recorded as a
  lineage violation, and tests assert there are none.
- **`gateway_check.py`** is a 17-step host-side contract self-test covering
  every behaviour the app's tests lean on.
- **`contract_test.py`** is the owner-run half (O7). It replays a nine-step
  sequence against a real gateway and against the fake, and diffs statuses,
  headers, error codes and cookie names and attributes. Values are never
  compared or printed. The link comes from `KR_CONTRACT_LINK_FILE` or
  `KR_CONTRACT_LINK`, never argv. It checks the gateway's version over
  `/api/ws`, and it needs a short-TTL link (`kirocrew token --ttl 2m`) so
  the expiry step does not wait 20 hours. Validated in `--fake-only` mode.

**Observed:** the real SPA renders against the fake, and with no session it
draws its own `#mc-session-expired` banner. The banner is `position:fixed;
top:0`, so in the app it sits under the status bar, which is one more reason
for R22's native sheet. The startup calls the fake does not implement get
404, which the SPA tolerates. They are listed in `/__state` → `unknown`.

## 2026-09-20 — M4 done

**Built (`app/`):**
- **The session bridge** (`PageScriptSources.sessionBridge`) runs at
  document start, main frame only, in the app's **own content world**
  (`latchkey-session`). DOM events reach it from the page, but its message
  handler does not exist in the page world, so neither the page nor
  anything it loads from a CDN can post to it.
  - It forwards `mc-auth-required` and `mc-auth-cleared`, hides
    `#mc-session-expired` with a CSS-only `<style>` (R22), and says `ready`.
  - If a gateway document commits and no `ready` arrives within 8 s, native
    removes the style again, so the page's own banner is the fallback.
- **`SessionManager`** (R21): `mc-auth-required` → `needsToken` plus the
  sheet.
  - `mc-auth-cleared` and each first `ready` trigger a page-world
    `GET /api/auth/me`, run from the app's content world with the page's
    cookies. Only a 200 means `active`.
  - It never calls `/api/auth/refresh` (R20) and persists nothing (R5).
- **Redemption** navigates the web view to `<selected gateway>/?token=…`,
  always that origin (`loadSessionURL` refuses any other). A redemption
  counts as successful only if `/api/auth/me` answers 200 after the load.
  A failure says why: links last 5 minutes and work only on the gateway
  that minted them.
- **`TokenEntrySheet`** (R23, D3):
  - Paste goes through `PasteButton`, never a silent read. Typed input is
    accepted too.
  - QR goes through `AVCaptureSession`; `NSCameraUsageDescription` was
    added.
  - One parser (`TokenInput`): the first `token=` in the text, so the CLI's
    three-URL output works; otherwise a bare token.
  - A link naming another host is reported before use and never followed.
    The CLI's own localhost link is not treated as foreign.
  - The clipboard is cleared after sign-in only if its `changeCount` is
    unchanged since the paste. Reading the content to compare would raise
    the paste prompt.
- A **"Signed out — Sign in" capsule** reopens a closed sheet. With the
  banner hidden, it is the only other way in.

**A compiler hazard found by the host tests.** Under `-O`, Swift 6.4
miscompiled `unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains)`
in a module that also passes `tokenCharacters.contains` unapplied. Most
likely the two thunks were merged. Every bare token then "contained
whitespace".
- `-Onone` was correct, so Debug and Testing builds would have passed and
  Release would have broken.
- Reduced to a two-file reproduction: the result was true only with
  `TokenInput.swift` in the module, and closures were unaffected.
- Fixed with explicit closures. AGENTS.md now carries the rule. The host
  tests keep building with `-O`, which is how this was caught.

**Tests:**
- Host: `test-token-input` 22 checks at both `-O` and `-Onone`; the session
  bridge 10 checks under Node, with a fake page.
- `scripts/test-session.sh`: the pin, the fake's self-test, then
  `SessionTests` **9/9 in 231 s**. The nine tests:
  - signed out → native sheet, banner hidden, capsule reopens;
  - a broken bridge → the page's banner is shown (the positive control for
    the hidden-banner check);
  - pasting CLI output signs in (one redemption, `/api/auth/me` 200,
    clipboard cleared);
  - a bad token says so;
  - **R25:** ~40 s of 6-s access sessions with a forced expiry midway gives
    ≥ 5 rotations, zero lineage violations and never the sheet;
  - revoked chain → sheet → a new token recovers;
  - **R24:** a CLI session survives a restart and keeps rotating, and a QR
    session ends at one;
  - network loss (blackholed stub) → no sheet, and it recovers on return.

**Deviations, deliberate:**
- R38's `localStorage mc-onboarded=1` preset is not needed. The SPA prefers
  `/api/theme/boot`'s booleans over localStorage, and the fake answers
  `onboarded: true`.
- The R25 AC's "several expiries" runs over 40 s rather than 10 minutes.
  With the real scheduler's 5-s floor, 40 s already gives a countable
  number of rotations (the assertion is ≥ 5), and the lineage check covers
  the hazard.
- QR scanning cannot run in the simulator (no camera). Its payload goes
  through the same host-tested parser, and the camera path is left for the
  device check.

**Found while verifying: the test hook leaked data stores, and L1's scan
read them.**
- After the M4 suite, L1's R1 disk scan failed on `token=` inside WebKit
  `NetworkCache` blobs belonging to data stores L1 had not created.
- Cause: `-UITestResetWorkspaces` removed old workspaces' tsnet state but
  never their `WKWebsiteDataStore`s. The container held **111** of them.
- The hits were in cached assets from other suites. The most likely source
  is the real KiroCrew JS, which contains `?token=` in code.
- Fixes:
  - The hook now removes every other data store.
  - `test-offline.sh` and `test-session.sh` uninstall the app first, so each
    R1 scan reads only its own run.
  - L1 passes again, scanning 14 WebKit files, all its own.
- **M4 got its own R1 check.** No `fk1.` sign-in link may appear in the
  container (binary grep over Library and tmp), and no `fk1.` or `token=` in
  the unified log. The check is validated by requiring logged redemptions (8
  in the run) and WebKit data to scan. It passes. The session cookies are on
  disk by design; they are the session.

**Known and left for the review:** the token sheet is presented from the
dashboard, while Settings is a root-level sheet. If the page asks for a
token while Settings is open, the token sheet cannot stack on top of it.

**Waiting on Olof:**
- **O7** can now run: `contract_test.py` with a short-TTL link he mints. See
  its header.
- **O4** still has no answer. Nothing built here depends on it.

**Actual:** about 2 h agent wall-clock for R19 through M4, including the
research pass (not engineer-hours).

## 2026-09-20 — M4 review

Two adversarial reviews. The app review found no security holes and 12
findings. The fidelity review checked the fake against the real 0.6.0
source: no high-severity divergence, 5 medium findings and 6 low. **All
fixed.**

**App (`app/` review-fix commit):**
1. **(medium-high) Stuck in `needsToken`.** A signed-in document fires no
   event, and the app re-checked `/api/auth/me` only while `unknown`.
   - So a sign-in that finished after the 30-s timer, or one whose check
     failed once, left a working dashboard under a "Signed out" capsule.
   - Now it re-checks on every `ready` and every finished load while not
     `active`, checks once more before a timeout counts as failure, and
     retries once after a check that got no answer.
2. **(medium) Settings open when the page asked for a token → no way to
   sign in.** The token sheet is now presented from the root, next to
   Settings, and waits for Settings' `onDismiss`. The capsule follows the
   sheet being **on screen**, not the request flag.
3. **(medium) A failed sign-in load showed its token.** It appeared on the
   error page, in `url`, and in the ⌘R retry. Failing URLs are now stripped
   of `token`, and `SessionManager` is told at once rather than after its
   timeout.
4. **(low) A stale 200 could override a newer `auth-required`.** Checks now
   carry a generation, and a check started before the last `auth-required`
   cannot mark the session active.
5. **(low) Any script on the page can dispatch the auth events.** While a
   sign-in is in flight, `auth-required` is believed only if
   `/api/auth/me` agrees. The message handler was already isolated in its
   own content world, which the review confirmed.
6. **(medium) The hidden-banner check ended before the 8-s watchdog.** It
   now looks after 11 s.
7. **(low-medium) The "never appears" checks polled every 2 s, so a brief
   sheet could slip between looks.** Test builds now show a count of
   `auth-required` events, and the tests assert it does not change. The
   forced-expiry test also asserts the 403 path actually ran (`denials`
   increased). The revoked-chain test asserts the reload happened.
   - That last assertion exposed a **race in my own first design**: with
     expiry forced too, the interceptor sometimes won and nothing reloaded.
     The test now revokes only, so the scheduler reaches the revoked chain
     first.
8. **(low) `auth_me_ok` counted the page's own calls.** The app's check now
   sends `X-Latchkey-Check` (servers ignore it), and the fake counts it
   separately (`app_auth_checks`).
9. **(low) The M4 R1 scan saw only the last test's data**, because the reset
   hook removed the others. `-UITestKeepWebData` now keeps them, and the
   scan covers all 12 tests' data (3,884 WebKit files).
10. **(low) The "-O and -Onone" claim was false.** `test-token-input.sh` now
    builds both.
11. **(low) Chat formatting defeated the parser.**
    - Backticks, `**`, and trailing `!`, `…` or `.` now parse.
    - An unusable first `token=` no longer hides a good later one.
    - `[::1]` counts as the CLI's own local host.
12. **(low) QR scanner problems.** With permission denied it was a black
    sheet with no way out; it now shows a message and a Close button. Start
    and stop now run on one serial queue.

**The fake (parent review-fix commit):**
- **(medium) Restart.** `/__restart` now drops every connection and can be
  down for N s. The new `/__drop-next-refresh` loses a refresh response on
  purpose. With it, two new app tests pin real KiroCrew behaviour:
  - a lost response is recovered by the 60-s grace window, with no sheet;
  - a lost response followed by a restart (the grace cache is memory-only)
    revokes the chain, and the app recovers through the sheet.

  **This is a real-world hazard, not an app bug:** a gateway restart during
  a refresh signs the phone out. The app cannot prevent it. The test pins
  that it recovers.
- **(medium) Revocation.** `/__revoke` meant nothing real. It is now
  documented as reuse-detection revocation (chains only; access stays
  valid). The new `/__logout-all` is `kirocrew logout`: the generation
  bump, where access gets 403 and refresh gets `invalid_refresh` with no
  clear. It has its own app test.
- **(medium) Credential order.** A valid `?token=` now re-redeems over a
  valid cookie (the query token is validated first). An invalid one falls
  back to the cookie. Exempt paths never redeem.
- **(medium) `contract_test.py`.**
  - It no longer expects the legacy `mc_token` clear on rotation; that was
    a fake bug that would have shown as drift on the first real run.
  - A new grace step 6b re-presents step 6's token and compares the
    re-served tokens.
  - Max-Age is compared exactly (rounded to the minute), except the
    redemption's access cookie.
  - The link-window instruction is corrected to min(300 s, ttl).
  - `0.6.0.N` build versions are accepted, and equal transcript lengths are
    required.
- **(medium) The pin now covers the server code the fake emulates**: twelve
  dashboard modules plus the four frontend files, and a `BUILD_VERSION`
  stamp is refused. An upgrade that leaves the frontend byte-identical
  still trips it.
- **(low)**
  - The Host check compares hostnames.
  - Non-GET/HEAD requests and data paths get the 403 sign-in page, not the
    shell.
  - Refresh checks run in the real order (revoked chain before generation
    and boot).
  - Link windows are timed from mint.
  - Logout revokes the chain and answers `logged_out`.
  - Rotation no longer clears the legacy cookie.
- **`gateway_check.py` now has 27 steps:**
  - the rate-limit check asserts the 61st call;
  - WebSocket denials are told apart (auth vs origin);
  - there is a step for each new behaviour.
  - One step I wrote had an `or True` in it and could not fail. It was
    caught before commit, rewritten, and its negative was demonstrated.

**Confirmed faithful by the fidelity review:**
- Middleware order and the text/plain 403s.
- Cookie naming and attributes.
- The refresh codes and their order.
- The grace rule (head, same remote, 60 s).
- Access surviving chain revocation.
- `boot` shapes and restart semantics.
- The WebSocket gate.
- The bridge's `<style>`, which the real CSP allows.

It also confirmed that IP pins hide nothing behind `tailscale serve`, since
every request there comes from 127.0.0.1.

**After the fixes:**
- `scripts/test-session.sh`: pin 16 files, `gateway-check` 27/27,
  SessionTests **12/12 in 319 s**, R1 clean (all tests' data, 13 redemptions
  logged).
- L1 9/9 in 103 s; L2 4/4 in 86 s.
- `make test-policy` green; the token parser 30/30 at both `-O` and `-Onone`.
- `contract_test.py --fake-only` passes all nine steps, with grace re-serving
  the same tokens.

## 2026-09-20 — Before M5: R27 and R28

**R27: the proxy rules no longer follow the peer list.**
`App/Network/StableProxyPolicy` publishes exactly
`[100.64.0.0/10, fd7a:115c:a1e0::/48, <MagicDNS suffix>]`. `TSNetManager`
builds its proxy configuration from that, not from upstream's
`TailnetProxyPolicy.make`.
- Peers joining, leaving or being renamed no longer republish the
  configuration under a live dashboard. It changes only if the suffix does.
- It is still a scoped split tunnel: nothing public is proxied, which is the
  thing upstream's AGENTS.md warns about.
- `hasPeerData` and the proxy-everything test mode still come from
  upstream's policy.
- Chose R27's first option over a republish-mid-WebSocket test. It removes
  the churn instead of testing that WebKit survives it. The app only ever
  loads FQDN origins; bare names are rewritten first.
- Host-tested (`test-proxy-config`, 26 checks). The tests include a control
  showing upstream's own policy DOES change under the same churn.
- PLAN §7.3's "M6.4 tests the republish" is moot: there is no republish on
  peer churn to survive.

**R28: App Transport Security is on, with no exceptions.** The whole
`NSAppTransportSecurity` dictionary is gone:
- `NSAllowsArbitraryLoads`;
- `NSAllowsArbitraryLoadsInWebContent`;
- the malformed `NSAllowsArbitraryLoadsInWebContentUsageDescription`
  block, which held a doubly nested exception dict under a key ATS does not
  know.

Everything the app loads is HTTPS with a trusted certificate. The loopback
LocalAPI and SOCKS traffic needs no exception: L2 passes 4/4 with the node's
LocalAPI on loopback HTTP. L1 passes 9/9 and M4 12/12, both over HTTPS with
the test CA trusted in the simulator. AGENTS.md now says not to add the keys
back for a plain-HTTP gateway (chonk was out of v1 per D4 — **D4 is since
superseded**, chonk serves on 443; R28 stands on its own).

## 2026-09-21 — M5: gateway discovery (R26)

**Built (`app/`):**
- `GatewayCandidates` is pure, host-tested (31 checks) code for three things:
  - R26's filters: online, not expired, not shared in, a server OS, the
    same owner. The saved gateway always comes first. An unknown OS or
    owner does not exclude a peer, because a missing field is not evidence
    of a phone.
  - The fingerprint: `manifest.json` named "Kiro Crew" **and**
    `/api/auth/me` answering 403 + `X-Auth-Required`.
  - Manual-entry normalization: a bare name is qualified with the MagicDNS
    suffix, and the result is always https.
- `GatewayDiscovery` probes over HTTPS only, through an ephemeral
  `URLSession` built from the node's proxy configuration: 12 at a time,
  1.5 s per request, a 5-s sweep deadline, with results streamed.
  - If every probe fails with -1000/-1004 it reports "proxy unhealthy" and
    refreshes the status.
  - No candidates: it finishes at once. A first version sat out the 5-s
    deadline with nothing to probe.
- **The picker** replaces the dashboard until a gateway is chosen.
  - A single gateway found on the first run is chosen automatically. M5.3's
    "and it already has a session" is dropped: it cannot be known before
    loading, and would not change what to load.
  - The "gateway unreachable" banner gained **Find**, which opens the picker
    (M5.5).
  - Choosing a gateway sets the home page and reopens the dashboard tab.
- **`HomePage.defaultURL` is empty** (no gateway). The M1 hardcoded byskebox
  is gone. No migration is needed: the app has never been installed on the
  phone (O1–O3 are pending). The inherited tailnet tests now set their
  gateway explicitly, as their comment always said they would at M5.
- The vendored TailscaleKit now decodes `PeerStatus.OS` and `UserID`, as its
  own commit (R16).

**Found on the way, and fixed:**
1. **testcontrol reports every peer offline** unless `AllOnline` is set, so
   R26's filter skipped every harness peer. The first discovery run probed
   0 of 4, and **the manual-entry test passed anyway**, because it expected
   zero gateways. Fixes:
   - The harness sets `AllOnline`, as a real control plane marks connected
     peers.
   - Its self-test now fails if a peer is reported offline or without an OS.
   - The manual-entry test now requires that the web-page peer was actually
     probed and rejected.
2. **Test data could land in the real data directory.** `WorkspaceStore`
   chose the UI-test directory only for `-UITest*` arguments, so a relaunch
   carrying only `-TestControlURL` read and wrote the REAL directory. The
   persistence test caught it: its relaunch found no gateway. `-Test*`
   hooks now count as test runs too.
3. **The picker is up only for the ~1.5-s sweep**, too briefly for XCUITest
   to catch reliably. The first-run test now proves its result by what
   follows: the app chooses by itself only when exactly one gateway was
   found. The timing is R26's own instrument, the app-logged timestamps.
   `test-discovery.sh` parses them and fails on a sweep over 10 s or a first
   gateway over 5 s. It also fails if no sweep found anything. Validated
   against a slow first result, a slow sweep and an empty log.

**The AC, measured:**
- `scripts/test-discovery.sh` passes 3/3. The four harness peers are `gw`
  (the fake KiroCrew gateway), `dash` (a web page), `plain` (nothing
  listening) and `slow` (accepts, never answers).
- Exactly `gw` is found; the first gateway appears at 446–477 ms and each
  sweep finishes in 1.5–1.6 s.
- Manual entry works when nothing is found, and the choice survives a
  relaunch.
- The real-tailnet part of the AC (R26's purgatory-netmap expectation, and
  byskebox found within budget) waits for the device check and M7.

**Regression pass:** host tests, L1 9/9, L2 4/4, and the three
connection-independent inherited tests all pass. The session suite showed one
more **race in a test of my own design**. In the 6-s-session test, the
page's scheduler usually cured a forced expiry before any wrapped API call
could hit the 403, so "the interceptor path ran" was luck. The interceptor
path now has its own deterministic test: a 4000-s session puts the scheduler
~400 s away, so the page's 30-s poll must hit the 403 first. The session
suite now passes 13/13 in 330 s.

## 2026-09-21 — M5 review

Two adversarial reviews: discovery logic and routing, and tests and harness.
**All findings fixed.**

**Routing and privacy:**
1. **(medium) Probes followed redirects.** A same-owner server answering
   `302` to an SSO host would have had the redirected probe sent **direct**,
   off the tailnet. The probe session now refuses every redirect, and a 3xx
   is not a gateway. (The `async` delegate method crashed Swift 6.4's SILGen,
   so it uses the completion-handler form.)
2. **(medium) R27 sent shared-in nodes direct.**
   - A node shared in from another tailnet keeps that tailnet's name
     (`tailcfg.go:562-584`), outside our suffix. Upstream's policy listed it;
     `StableProxyPolicy` did not.
   - Fix: it now lists every peer FQDN outside the suffix. That list changes
     only when a share does. With no suffix known, it returns upstream's
     policy unchanged.
   - Host-tested, including "own-tailnet churn still does not change it".
   - Backstop: discovery never probes a host the published policy would not
     proxy.
3. **(medium) Manual entry accepted public hosts**, which would load direct
   and become the sign-in origin. The picker now refuses any host the
   tailnet does not carry, and says why.
4. **(medium) "Proxy unhealthy" was guessed from error codes.** -1000 is
   every SOCKS failure reply, including "connection refused", and the SocksLog
   relay masks -1004. Now, when no probe got an answer, discovery asks the
   node's loopback directly (`refreshStatusNow()` returns whether it
   answered). That listener serves both SOCKS5 and LocalAPI (R18), so a
   silent loopback means the proxy is down.

**Behaviour:**
5. **(medium) Find showed stale results.** The discovery object outlives the
   picker, so it swept once per process. Find and Settings' picker now sweep
   on every appearance.
6. **(low-medium) Clearing the Settings field swapped in the first-run
   picker.** Every keystroke was written through, so an empty field meant
   "no gateway".
   - The field is now **Gateway** and commits only on Return or when Settings
     closes. An empty or unusable entry keeps the current gateway.
   - It normalizes like the picker: a bare name is qualified, and the scheme
     is always https. The old URL-bar normalization produced `http://`,
     which ATS now blocks (R28).
   - Settings also gained **Find gateways…** (gateway switching; R32 builds
     on it).
7. **(low-medium) Find's picker and the new gateway's token sheet could
   collide.** The choice is now applied from the sheet's `onDismiss`, the
   same rule as Settings in M4.
8. **(low) A cancelled sweep could overwrite a newer one's state.** Sweeps
   carry a generation, and the picker cancels its sweep when it disappears.
9. **(low) Tagged servers were filtered out.** They report the
   tagged-devices user, so the owner check excluded them. Tagged peers now
   pass it. The `ShareeNode` comment was wrong about its meaning and is
   corrected.
10. **(low) Stale session state across a gateway switch.** `selectGateway`
    now resets the session.
11. **(low) Layout.**
    - The first-run picker was nested inside the dashboard's
      hidden-toolbar navigation stack. It now has its own.
    - "Search again" moved from the toolbar corner the settings gear covers
      into the list.
    - A test screenshot also showed the gear **covering the banner's
      "Change" button**. The banner now leaves room for it.
12. **(medium, found by a new test) The relaunch race.** On relaunch, the
    first status can arrive before the netmap's peers, so "your gateway is
    not in this tailnet" was decided on an empty peer list and the blank
    fallback loaded. Recovery then fired only on an observed *transition*
    to available, which could happen before the dashboard view existed,
    leaving it blank for good. Two fixes:
    - A peerless status now means "still checking".
    - Recovery is state-based (it also runs when the dashboard appears).

**Tests and harness:**
- **(high) The persistence test could not fail**: a relaunch that had lost
  the gateway would re-discover and auto-choose it. It now requires that no
  sweep ran: the web-page peer was not probed, and the gateway's first
  request is the page load (`GET /`), not a probe. The page's own
  `/manifest.json` fetch is why "no manifest request" was the wrong test.
- **(medium) The timing check could not fail by construction.**
  `test-discovery.sh` now checks each sweep's exact signature from the
  app's log: `probing 4 of 4 → 1 gateway, 2 answered, 2 failed`, or
  `3 of 3 → 0, 1, 2`.
  - A sweep must also take at least 1.5 s, which proves the slow peer was
    waited for, and must end within 10 s.
  - The first gateway must appear within 5 s **of the picker appearing**,
    now logged, so the wait for the node's status counts.
  - Only this run's log window is read.
  - The slow peer journals its accepts, and a test asserts it was probed.
- **(medium) "Unknown" arrives as `""` and `0`, not `nil`**: ipnstate has no
  omitempty. It was tested with `nil`. The fields are now treated as unknown
  in the code, and the host tests use them.
- **(medium) The harness self-test never ran the new peers.** `make check`
  now runs them. `gw` forwards and is journaled; `slow` stalls a TLS
  ClientHello for 2 s, with the accept journaled; `?gw=0` leaves `gw` out.
- **(low)**
  - The fingerprint probe's order is asserted: manifest, then auth, first.
  - Fake resets are asserted.
  - The auth-event counter must be present (`>= 1`).
  - `HARNESS_ARGS` can no longer leak in from the environment.
  - The script header is fixed, and it fails clearly when no tests are found.
- New tests:
  - `testFindFromTheUnreachableBannerSwitchesGateway` (Find, a fresh
    sweep, the choice applied after dismissal, and the token sheet
    appearing);
  - "Search again" re-probing;
  - a public host refused in manual entry.
- `HomePage` banner accessibility: an identifier on the container swallowed
  the Find button's. It now uses `.accessibilityElement(children: .contain)`.

**After the fixes:**
- `test-discovery.sh` passes 4/4. Every sweep matches its signature; picker
  to first gateway is 262–857 ms, and each sweep takes about 1.5 s.
- `make test-policy` is green, including 30 proxy-config checks and 36
  candidate checks.
- L1 9/9, L2 4/4, M4 13/13 (R1 clean), and the three connection-independent
  inherited tests.


## 2026-09-21 — R29: diagnostics and the node log, before M6

R29 moves M8.2 and M8.3 ahead of M6's device tests, which will read them
afterwards. Both are built. So are the parts of R31 and R33 that belong on
the same screen: the node key's expiry and the provisioning profile's.

**Built (`app/`):**
- **Settings → Status** (`App/Diagnostics/DiagnosticsView.swift`):
  - Node: state, name, tailnet, addresses, peers, key expiry.
  - Gateway: the gateway, whether it is in the tailnet, and the last
    discovery.
  - Dashboard session: state, when the session and the access expire, and
    the last message.
  - Proxy: the SOCKS endpoint (`host:port` only), the rules, and "no direct
    fallback".
  - Page: the last navigation error and web-content restarts.
  - App: version, build configuration, profile expiry, and warnings.
  - Copy copies exactly what is shown. Nothing secret is read into the
    screen: session cookies are reduced to their expiry dates
    (`SessionCookies`, host-tested), and the proxy credential is never
    touched.
- **Settings → Node log** (`NodeLogView`, `NodeLog`) shows tsnet's own
  lines, with a filter, Copy and a 2-s refresh. They are redacted again on
  display. `LogRedaction` now also redacts a login code in a URL *path*
  (`/a/<code>`, `/auth/<id>`), which the query rule missed.
- **Expiry warnings** (`Expiry`, host-tested):
  - The node key warns 14 days ahead (R31). The vendored TailscaleKit
    decodes `PeerStatus.KeyExpiry` in its own commit.
  - The profile warns 48 h ahead (R33). It reads `ExpirationDate` out of the
    CMS-wrapped `embedded.mobileprovision`.
  - Both appear on Status and above the dashboard.
- **The vendored library keeps tsnet's log locally** (own commits, R16).
  Upstream set logtail's echo to `io.Discard`, and the drain goes to the
  no-op transport (D1), so every tsnet line was gone within seconds. The echo
  now goes to `Logs/tsnet.log`: 0600, capped at 1 MiB, one predecessor kept,
  excluded from backup, and never uploaded.

**Found on the way, and fixed:**
1. **The dashboard's Settings gear had never worked.** Nothing opened
   Settings from the dashboard: the tap landed, the action never ran.
   - The gear had `.opacity(0.45)` on the `Button`, and over the web view a
     button with opacity below 1 gets no taps. Neither a `contentShape` nor
     moving it helped; fading the label instead works. Isolated with twin
     buttons, faded and plain, at several positions.
   - It went unnoticed because no test had opened Settings from the
     dashboard: the inherited tests open it from the gate, whose gear is not
     faded. R29's diagnostics test is now that test.
   - Not fixed: ⌘, did not open Settings either under XCUITest's `typeKey`.
     The cause is not established, and on an iPhone without a keyboard it
     does not matter. It is left for the device pass (M6).
2. **No vendored Go change reached the app.** `make framework` rebuilt when a
   source changed, but libtailscale's own c-archive targets have no
   prerequisites, so `ios-fat` re-linked the old archives. The Makefile
   comment claimed this staleness was already fixed.
   - The rule now deletes the archives first.
   - `make check-framework` fails if any `latchkey_*.go` is missing from
     either slice (Go records source paths in the binary). It caught the
     stale framework before the fix.
   - The four test scripts run `make framework` in `--build` mode.
   - R1's earlier Go change had landed only because its archive happened
     to be built after it.
3. **An upstream logtail bug flooded the file.** The RAW-STDERR echo printed
   `b`, the whole pending upload batch, instead of the line, so one run
   filled 1 MiB in minutes. Upstream never saw it, because its echo went
   nowhere. Fixed in its own commit, with a Go test that fails before the fix.
4. **Raw stderr buried tsnet's lines.** logtail also replays whatever the
   process wrote to stderr. Under XCTest that was 4,059 of 4,456 lines, and
   the view's 2,000-line window held no tsnet line 20 s after launch.
   - Raw lines now go to their own `stderr.log`, with the same cap. The view
     has a tsnet/stderr switch; a Go panic from the previous run lands in
     stderr.
   - Under Xcode or XCTest (`OS_ACTIVITY_DT_MODE`), raw stderr is a mirror of
     the unified log, including other components' messages and URLs. It is
     not kept at all, and `tsnet.log`'s first line says which mode applied.
     Go tests cover both modes.
5. **A test of my own that could not fail.** The first node-log test counted
   "magicsock" matches. Under XCTest, the process's stderr echoes whatever
   the test types, so the typed filter text alone satisfied it. The test now:
   - resets the logs (`-UITestResetNodeLog`);
   - requires a real tsnet `magicsock:` line;
   - requires the "raw stderr not kept" decision;
   - requires an empty stderr view.
   The tsnet.log/stderr.log split itself is covered by the Go tests.

**Tests:**
- L2 passes 5/5. The new `testDiagnosticsShowTheNodeAndItsLog` covers:
  - through the dashboard gear: state Running, the tailnet, the gateway, "in
    the tailnet: yes", the SOCKS endpoint;
  - the node log's tsnet lines and the stderr rule.
- `testPastingCLIOutputSignsIn` checks that Status shows the 30-day session
  and the access expiry.
- Host: 25 diagnostics checks (node log, expiry, profile, cookies), and 30
  redaction checks.
- Go: the local-log tests and the logtail echo test.
- Regression: `make test-policy`; L1 passes in 103 s; session 13/13 with R1
  clean (disk: all of Library + tmp); discovery passes, every sweep on its
  signature; the three inherited tests pass.

**R31 and R33, what is left:**
- R31 still needs:
  - an L2 test of the key-expiry warning (a harness endpoint to set it);
  - mid-session `NeedsLogin` re-login;
  - mid-session `NeedsMachineAuth`.
- R33 still needs the Team-ID note in PLAN 7.7.
- PLAN M8 marks 8.2 and 8.3 done (R29), and 8.5 and 8.6 done (R28).

**Actual:** about 2 h agent wall-clock, excluding a pause while a tool call
waited on the owner.

## 2026-09-21 — R29 review

Two adversarial reviews: code, privacy and logging; and tests and build.
**All findings are fixed**, except two low items noted at the end. Following
up the first finding turned up **one more leak, which predated R29.**

**Privacy:**
1. **(high) `tsnet.log` stored Tailscale login links in plain text.**
   - Control logs `AuthURL is <url>` once. tsnet logs `… or go to: <url>`
     every 5 s while it waits for a login.
   - The R29 entry's "redacted again on display" was true only of the
     display: the file itself was not redacted. Anyone who copied it (Xcode's
     Download Container, a future share feature) could finish the login with
     their own account.
   - The vendored writer now redacts every line before writing, by the app's
     `LogRedaction` rules. Go tests cover both real line formats.
   - `test-tailnet.sh` now starts from a fresh container and fails if a
     login link is anywhere in it. It is validated: `tsnet.log` must hold the
     redacted form.
2. **(found by that scan, predates R29) LocalAPI responses were cached on
   disk.**
   - TailscaleKit built every LocalAPI session on
     `URLSessionConfiguration.default`, whose cache is on disk.
   - `Cache.db` held three status responses with the pending login link.
   - The sessions are now `.ephemeral` (vendored, its own commit). The app
     also makes `URLCache.shared` memory-only as a backstop.
3. **(medium) Punctuation defeated login-code redaction.**
   - A code followed by `.`, `)`, `,`, `}`, `]`, a backtick, `;` or an
     escaped `\n` stayed visible, and so did one with no scheme
     (`login.tailscale.com/a/<code>`).
   - The fixes:
     - URL candidates stop at backslashes and backticks, and shed unbalanced
       trailing punctuation;
     - the path rule redacts the leading 8+ character alphanumeric run;
     - a second pass catches `/a/<code>` and `/auth/<id>` anywhere.
   - Deliberately over-inclusive: a dashboard path `/chat/a/<8+ chars>` is
     redacted too. Redaction checks: 43, up from 30.
4. **(low) Copy used the general pasteboard.** Status, Node log and the app
   log now copy local-only (no Universal Clipboard): the text names the
   tailnet, its addresses and its peers.

**Behaviour:**
5. **(low-medium) The now-working gear covered the Login banner's button**,
   so a tap on Login could open Settings. The banner leaves room for it, as
   the gateway banner already did.
   - The expiry warnings moved to the bottom, clear of every top-edge
     overlay.
   - The dashboard shows only what is still ahead; an expired key has the
     Login banner.
   - The key message no longer points at a Settings action that does not
     exist.
6. **(low) Each tsnet user-facing line was logged twice.** `UserLogf` was
   nil, so `logf` also `log.Printf`'d into the same logger (vendored fix). A
   line repeated back to back is now written once, with a count: the 5-s
   login loop filled the file at about 190 KB/h at the gate.
7. **(low) Go's zero time counted as an expired key.** Anything before 1970
   now means no expiry. The warnings are really sorted by urgency: the
   comment said so, and the code always put the profile first.
8. **(low) Cookies from different ports were merged.** Status now shows each
   port's session separately. The port cannot be picked from the URL behind
   `tailscale serve` (R37).
9. **(low) Stale and misleading values on Status.**
   - Status rereads on a 2-s clock.
   - "Key expires" no longer says "never" before the node is connected.
   - The profile row tells "none" from "unreadable".
   - "Copied" resets.
10. **(low) Node log cost.**
    - It rereads only when a file's size or modification time changed, and
      reads at most the last 512 KB of each file.
    - The filter runs once per render.
    - A `.task` loop replaces the `Timer` held in the view struct.
    - Switching source can no longer keep showing the other source's lines.

**Tests and build:**
11. **(medium) `check-framework` checked file names, not freshness.** It
    would not have caught R29's own later vendored commits.
    - The framework rule now writes a hash of the sources' contents next to
      the xcframework, and `check-framework` compares it.
    - It runs on every `make framework`, so a failed build stays an error.
    - Sources include files not yet `git add`ed. The generated headers are
      gitignored, so they are left out.
12. **(medium) Nothing tested a normal launch's stderr mode.** Inverting the
    choice passed every test. A Go test now drives `latchkeyLocalLog` itself
    with the environment set both ways.
13. **(low) Weak or flaky UI assertions.** Now:
    - the SOCKS endpoint must be exactly `127.0.0.1:<port>`;
    - "no RAW-STDERR" is a count of zero, not a line check that could not
      fail;
    - the 2-s refresh is exercised: the harness deauthorizes and re-approves
      the node while the view is open, and both state changes must appear;
    - `reveal` swipes slowly and back down if it overshoots;
    - `statusRow` waits for "reading…" and "checking" to settle.
14. **(low) Host tests.** `test-diagnostics.sh` checks the compiler's exit
    status; before, it failed only because the binary was missing. New cases:
    - zero and pre-1970 times, a UTC offset, the exact 14-day and 48-h
      boundaries, an expired profile, and the urgency order;
    - two cookie ports;
    - the byte-limited tail and the change signature.
    Diagnostics checks: 34.
15. **(low) Scripts.** The framework step prints a progress line.

**New in the harness, used by 13 and by R31:** `POST /expire?hostname=&in=`
and `POST /deauthorize?hostname=`. Its self-test covers both:
- a future expiry is visible;
- a past one drops the node to NeedsLogin;
- a new login restores it. testcontrol clones the old node, past expiry and
  all, onto the new key, so the harness's login page renews expired keys, as
  a real control plane does;
- a deauthorized node waits at NeedsMachineAuth until `/approve`.

**Not fixed, on purpose:**
- Status's Copy is not checked through the clipboard in a UI test. Reading
  another app's pasteboard from the test runner raises a paste-permission
  prompt. The copied text is built from the same rows the tests read.
- The node log's rows are positional, so text can shift under the reader
  when the window moves. It refreshes at most every 2 s.
- The filch buffer files briefly hold unredacted lines before logtail drains
  them. That predates R29. It is recorded for R30/M6, not fixed here.

**Found by the regression pass, and fixed: the fake servers could stall.**
- Discovery's relaunch test timed out: the relaunched app connected to the
  gateway, but the fake gateway never read the request.
- Cause: both fakes (`fake_gateway.py` and `dashboard.py`) TLS-wrapped the
  *listening* socket. So `accept()` ran the handshake in the one accept
  loop, with no timeout.
- When a test kills the app mid-connection, the harness peer's forward to
  the fake can stay open without ever sending a ClientHello. That one silent
  client blocked every connection after it. A timing flake of the harness,
  not the app.
- The fix, `testing/harness/tls_accept.py`: the listener no longer
  handshakes. Each connection handshakes in its own thread, within 10 s.
  Only the handshake is timed, so the tests' WebSocket and SSE streams are
  unaffected.
- Shown on the same server: with one silent client connected, the old
  version stalled (timed out at 4 s) and the new one served in 0.02 s.
- Both harness self-tests now hold a silent connection and require a normal
  request to succeed.

**Test tiers (asked for by the owner: the cycle was slow).** Measured:
- session 341 s, L2 167 s, L1 103 s, discovery 77 s, inherited about 64 s,
  so about 13 min in all;
- the session suite exercises only the session code, the page bridge, the
  web data store and the fake gateway.

`scripts/test-all.sh`:
- The quick default is the host tests, the vendored Go tests, L1 and L2,
  about 4–5 min.
- Session and discovery join only when code they exercise changed since the
  last recorded full pass.
- `--full` runs everything and records what it passed.
- The inherited tests (`scripts/test-inherited.sh`) are full-tier only: the
  L2 diagnostics test and discovery's persistence test cover the same
  ground.

Nothing is deleted; every milestone and review commit still gets `--full`.

## 2026-09-21 — R33 and R34 applied

- **R33:**
  - The 48-h profile warning shipped with R29.
  - PLAN §7.7 now also says what moving to a paid team does. A new Team ID
    is a new app to iOS: the old one is deleted and the new one installed.
    That means a new node (remove the old one in the admin console, and move
    the new one out of purgatory, O3b) and a new dashboard token. Plan it
    for a convenient moment.
- **R34:**
  - Notifications stay out of v1.
  - There was no deep-link interim left in PLAN to drop.
  - §9's note on claude-agent-acp PR #735 now carries R34's trigger: if it
    merges, re-evaluate what is left of M5–M8 before building it.

## 2026-09-21 — R31: key expiry and approval, mid-session

R29 already shipped the expiry parts: `KeyExpiry` decoded and shown in
Status, and a dashboard warning 14 days ahead. What R31 still needed:
- **Mid-session NeedsLogin.** The inherited Login banner already offered
  the right path: `showAuth` → `startLoginInteractive` → the auth sheet. Now
  proven at L2 with an expired key. The dashboard stays up rather than
  dropping back to the gate, and an expired key shows no second, stale
  warning; the Login banner says it.
- **Mid-session NeedsMachineAuth** gets its own banner ("Waiting for
  approval"). It has no button, because approval happens in the admin
  console, and it leaves room for the gear. It goes by itself on approval.
  Before, a revoked device showed nothing at all while every load failed.

**Tests (L2, 8/8):**
- `testAKeyAboutToExpireIsWarnedAbout`: `/expire` 10 days out → the
  warning, with the day count.
- `testAnExpiredKeyMidSessionAsksForLoginAgain`: RequireAuth, an expired
  key, the Login banner, a NEW completed login, and Status reporting
  Running.
- `testARevokedDeviceMidSessionWaitsForApproval`: `/deauthorize` → the
  banner with no Login button, then `/approve` → the banner goes and Status
  reports Running.

Harness support (`/expire`, `/deauthorize`, and key renewal at login)
landed with the R29 review. The node's state comes from the app's own
Status screen: the harness sees registrations, not a client's state.

## 2026-09-21 — M6.8: the ~66 s cold-node flake — gate on peer data, don't raise the timeout

The five inherited iOS UI tests flaked at ~66–68 s against a 60 s
page-load timeout because upstream fired the first navigation as soon as the
node reached `Running` and let WebKit sit on the 60 s timeout while the
netmap (and thus the peer that the gateway name resolves to) was still
arriving. Latchkey already closes that race: `BrowserViewModel.loadInitial`
holds the first load until `HomePageAvailabilityChecker` confirms the
configured gateway is a peer in the current netmap **and** until
`TailnetProxyPolicy.hasPeerData` is true, so WebKit is never handed a URL it
cannot yet route — the wait moved out of WebKit's fixed 60 s timeout and into
a cheap poll that resolves the moment peer data lands. Decision: **keep the
peer-data gate; do not raise the 60 s timeout.** On the L2 harness (a
loopback control plane) the new `LifecycleHarnessTests` measure cold joins —
launch to the dashboard's WebSocket open over the tailnet — at **6.9–7.8 s**
across five runs, an order of magnitude under the budget, so the flake does
not reproduce here; the residual real-tailnet risk is DERP/netmap latency on
a genuinely cold start, which raising the timeout would only paper over,
and which M6.6's device pass measures directly.

## 2026-09-21 — R31 review

One adversarial review (Fable). No high findings.

**Fixed:**
1. **(medium) The harness renewed keys after completing the login.** That
   raced the client's follow-up register, which retires the old key's
   entry: `UpdateNode` (update or add) could write the old entry back, a
   ghost second app node. Renewal now happens before `CompleteAuth`, while
   the follow-up is still parked.
2. **(medium) `nodeState` read Status once.** After a re-login the node
   needs its new netmap and a fresh DERP connection before Running. It now
   waits for Running, up to the join timeout.
3. **(low) Overlay collisions.** The node banners (Login, Waiting for
   approval) covered the gateway banner's Find and Change buttons, and were
   themselves covered by the sign-in capsule. They now sit in the layout
   above the gateway banner, and the capsule hides while the node is down:
   no dashboard sign-in works then anyway.
4. **(low) "Logged in. Connecting…" had no way out.** A 60-s watchdog now
   brings the Login banner back if the node still sits at NeedsLogin after
   `LoginFinished`.
5. **(low) A failed `startLoginInteractive` left the Login button spinning**
   for its 2-min safety timeout. It now ends the spinner at once.
6. **(low, device only) The expiry test matched any `expiry-warning`.** A
   near-expiry profile on a device adds its own. It now matches the key's.

**Recorded, not fixed:**
- **(medium) The R31 tests prove the node's state, not the page's recovery.**
  On this harness a revoked device may not even interrupt the page:
  testcontrol keeps sending peers to an unauthorized node, where a real
  control plane sends none. So the R31 entry's "every load failed" is true
  of a real tailnet, not shown here. Proving the page recovers needs the
  fake dashboard to reconnect as KiroCrew's page does; M6 is adding that,
  and these tests will then require a fresh `ws:open`.
- **(low, unconfirmed) The login sheet is a third presenter**, outside the
  Settings, Find and token-sheet exclusion rules. Two rare cases: a token
  redemption in flight when the key expires, and a sticky login request
  whose URL arrives while Settings is open. To watch for at M6/M7 on the
  device.
- **(low) The harness writes whole node clones back**, which can clobber
  testcontrol's live map mutations. It also renews every expired key on
  any login. Harness-only; one app node per test.

## 2026-09-21 — R30: the logging relay stays on, bounded and self-healing

Built by a Fable agent, reviewed adversarially by another, and the fixes
applied by a third.

**Kept on.** The relay was not disabled outside test builds. The build on
the phone is Debug via Xcode's Run, where test hooks are off. The relay's
per-connection log is the only on-device evidence of what reached tailnet
proxy and what it answered: M6.6 needs it, and it is what makes a missing
`socks[n]` line mean something. It is loopback-only and passes tsnet's
credential through, so it is not a security boundary.

**Bounded.**
- At most 64 concurrent sessions.
- At the cap, the longest-silent session goes, but only once it has been
  quiet for 60 s. Traffic in either direction counts as activity, and
  KiroCrew's WebSocket heartbeats every 30 s.
- Otherwise the newcomer is refused.

**Restarted on evidence, never on a timer.** It restarts when a main-frame
load fails with -1000/-1004/-1005 while all of these hold:
- the node is Running;
- LocalAPI answers;
- the relay accepted nothing since the navigation began;
- and the final word, a loopback self-probe of the relay's port is refused
  or unanswered.

The probe settles the question, because the "accepted nothing" inference
misreads pooled connections and loads that never dialled.

The same probe also runs:
- on return to the foreground: it gathers evidence and rebuilds nothing,
  per M6.1;
- after a session check whose two `/api/auth/me` attempts both go
  unanswered.

A listener that reports `.failed` after being ready is replaced directly.

All restarts share a budget of 2 a minute and run off the main actor. If no
listener will start, the app falls back to tsnet's proxy directly; that is
counted, shown in Status and logged once. The page retries a
transport-failed load only when the endpoint generation moved, never on the
status poll's rule-only republish.

**Review.** No leak path. Every publish, restart and fallback goes through
`ProxyConfigurationFactory`, which keeps `allowFailover` off and uses the
same rules. The fixed findings:
- the mechanism could not see the defunct-after-suspension case (the probe
  now covers it);
- false restarts;
- retries on any republish;
- a 3-s main-thread wait;
- an ignored post-ready failure;
- a silent fallback;
- a listener data race;
- two gaps in the host tests.

**Tests:**
- Host: 89 relay checks, run against the real relay over loopback.
- L2: `testDefunctRelayListenerIsRestartedByAFailedPageLoad`. The probe
  refuses, the relay restarts, the endpoint is replaced and the page is
  retried, about 0.1 s from the tap to recovery.

**Open, for the device:** whether iOS ever kills the relay's listener
independently of tsnet's. Upstream's premise is not measured here; M6.6 will
show it.

## 2026-09-21 — R32: sign out, and one way to leave the tailnet

Settings now has two ways out, each named for what it ends.

**Sign out of the dashboard.**
- Asks the gateway to revoke the session from the page. A page-world POST
  is the only request that carries both the HttpOnly refresh cookie and the
  Origin header the CSRF check wants.
- Blanks the page and waits for the commit, so no script can set a cookie
  afterwards.
- Wipes the workspace's web data, whatever the gateway said.
- Reloads. The sheet says "this device only" if the gateway did not
  confirm.

**Reset app** is the only way to leave the tailnet. In order:
1. the same dashboard sign-out, while the tailnet is still up;
2. LocalAPI `POST /logout`, where control expires the key;
3. everything on the device goes: node state, web data, node logs and the
   gateway choice;
4. first run.

The separate "Log out of Tailscale" was folded in. It deleted the same
things but skipped the dashboard step, leaving a live 30-day session at the
gateway.

**Finding: upstream's logout never left the tailnet.** It was
`LocalBackend.DeleteProfile`, which is local only and never contacts
control (confirmed in `ipn/ipnlocal/local.go`). Every reinstall left an
orphan with a valid key.

A logged-out node stays listed as expired in the admin console until it is
removed there; removing it frees the name.

**A failed control logout deletes nothing** (a timeout, a 5xx, or no
loopback). The key that could still be expired lives in the state that
would go. The user chooses:
- **Retry**;
- **Delete anyway** (the node stays in the admin console with a valid key
  until removed there);
- **Cancel** (the node stays, and the dashboard is signed out).

**Gateway switching** was already built in M5, which R32 confirmed.

**Review findings, all fixed:**
- a failed logout deleted anyway;
- the redundant Logout;
- the page was not stopped before the wipe;
- one test could not fail for a broken local clear. The unreachable-gateway
  test now relaunches while the chain is still valid;
- the copy overstated what goes;
- log accuracy on 204, and dead code;
- the Settings view model is now held across re-renders.

**Test support:** testcontrol now honours a logout by expiring the key
(vendored, its own commit), and the harness reports each node's key state.

**Tests:**
- Host: 26 sign-out checks and 12 session-fetch checks.
- Session suite, three tests: sign-out revokes the session at the gateway
  and on the device; sign-out with the gateway unreachable clears only the
  device and says so; reset ends the session and starts over.
- L2: `testAResetExpiresTheNodeAtControl`. The old path would fail it.

## 2026-09-21 — M6: lifecycle tests on the L2 harness (6.5, 6.7; R14)

`LifecycleHarnessTests` and `scripts/test-lifecycle.sh` run with no
account. They were built by a Fable agent.

**The fake dashboard now behaves like KiroCrew's page:**
- it reconnects its WebSocket with backoff: 1 s, doubling, capped at 10 s,
  reset on open;
- it refetches over HTTP on reconnect and on `visibilitychange`;
- the server stamps each report with its receive time;
- `POST /__drop_ws` cuts sockets as a gateway restart does.

`page_check.js` pins the backoff in Node.

**Tests, 5/5** (recorded as 6/6 at first; the suite has always had five):
- A defunct loopback listener is replaced reactively, and the page
  reconnects through the replacement: damage to recovered in 1.6 s, the page
  back 1.2 s later.
- Every TCP socket shut down: the app survives and the page reconnects in
  1.8 s. This test **found a crash**, a nil `Logf` in the vendored debug and
  close paths, fixed in its own commit.
- R30's relay-listener recovery.
- Home, then a SIGSTOP freeze of 7 s or 30 s, then resume. The page is kept
  (same document, no reload), nothing reached the dashboard while frozen,
  and a fresh request crosses the tailnet 0.45–0.55 s after activation.

The freezer is host-side: it is triggered by the app's "Background:" log
line and SIGSTOPs, then SIGCONTs, the app's pid.

On the simulator, `shutdown()` on a *listening* socket returns ENOTCONN. So
the shutdown-all case exercises the page's recovery, not the listener
replacement; the defunct-loopback test covers that.

**Still device-only (M6.6):** real suspension, jetsam and listener
reclamation, and time-to-interactive after 1 min, 10 min, 1 h and
overnight, run untethered. The simulator never truly suspends a process.
That, and M6's AC numbers, need the phone (O1–O3).

**Test tiers:**
- The lifecycle suite runs in the full tier, and in the quick tier only
  when recovery code or its fixtures change.
- `testAResetExpiresTheNodeAtControl` is named to sort early. The L2
  login-link scan proves itself on the last test's login, and a reset
  deletes the node logs.

**R31 review, open item closed (2026-09-21):** now that M6's fake page
reconnects like KiroCrew's, the two mid-session tests end by cutting the
page's WebSocket at the dashboard and requiring a reconnect received after
the cut. The dashboard is reachable only through the tailnet, so the PAGE
recovered through the node, not just the node's state. L2 9/9.

## 2026-09-21 — Final review: M6 tests and the R30/R32 fixes

One adversarial review (Fable) of the M6 lifecycle suite, and a
verification of the R30 and R32 review fixes. **No high or medium
findings.** It confirmed each of the following against the code:
- the anti-leak invariants are intact;
- the probe connects to the address WebKit uses;
- a dead gateway and a dead relay are told apart;
- the relay test cannot pass through the page's own reconnect;
- the freeze checks are server-stamped;
- the reset ordering is right;
- the new tests can fail.

**Fixed:**
- the lifecycle suite's per-test allowance, 180 → 300 s, so a slow run fails
  with its own message;
- the reset alert's Cancel now closes Settings like Retry and Delete anyway;
- the quick tier re-runs lifecycle on `App/Session` and `App/Diagnostics`
  changes, and session on `App/Settings` changes;
- the R30 entry's wording on when the probe runs.

**Not fixed:**
- *(low, unconfirmed)* A foreground probe right after a resume might time
  out before the listener is re-armed. That costs one budgeted restart, and
  M6.6 will show whether it happens.
- *(low)* The freezer reads the pid from the log line. If the log format
  changes, it fails loudly rather than passing.

Rerun after the fixes: lifecycle 5/5, session 16/16 with R1 clean.

## 2026-09-21 — A replaced relay stalled its surviving sessions

A final end-to-end lifecycle run failed once: the defunct-loopback test's
page reconnected, but its refetch never reached the dashboard. **An app bug,
not a flaky test.** WebKit's network log showed the `GET /healthz` put on a
pooled keep-alive connection through the OLD relay. It went out, got no
reply, and the socket was never closed; a page `fetch` has no timeout.

**Cause:** loopback recovery `stop()`s the relay and drops the manager's
only reference to it. Its pumps captured `[weak self]`, so after the release
each surviving session relayed one more chunk each way and then stopped
re-arming: no relaying, no close. Earlier runs passed only because WebKit
happened to open a new connection for the refetch. The restart-failure path
in `restartSocksRelay` dropped the relay the same way.

**Decision:** the pumps hold the relay strongly. A stopped or replaced relay
carries its sessions to their end (tsnet's accepted connections survive a
closed listener, which is what the test always assumed), and each session's
end releases it. `stop()` closes only the listener. Cutting the sessions
instead would also have worked, but would drop working connections for no
gain.

**Tests, both shown to fail on the old code:**
- Host: a relay stopped and released still relays five separate chunks
  both ways, stays alive while its session lives, and is freed when the
  session ends. Old code: 1 of 5, then nothing. Relay checks 97/97.
- L2: after recovery, the fake dashboard pushes two frames down the page's
  surviving WebSocket (`POST /__ws_push`, new), and the page must show the
  second. Old code: `survivor-1` arrived, `survivor-2` never did. This used
  to depend on WebKit's pooling; now it is deterministic.

**Also fixed, in the freezer:** the continue stamp was taken after SIGCONT
by starting a python (about 30 ms). A report the resumed app flushed at once
was stamped 25 ms "before" the continue, and failed the nothing-while-frozen
check. Both stamps are now taken inside the freeze.

Lifecycle 5/5 after both fixes.

**Review (Fable, adversarial).** One medium finding, and it was right:
`stop()` itself still captured `[weak self]`. The manager drops its
reference on the next line, so a relay with no live session was freed
before the block ran and its listener was never cancelled. The port went on
accepting connections that nobody served: the same hang, by another route,
in the real device's shape (iOS has killed every session by the time
recovery runs). The reviewer showed it against the real file.

**Fixed:**
- `stop()` holds the relay until the listener is cancelled. New host check:
  stopped and released with no session, the port refuses a probe and the
  relay is freed. It fails on the weak capture. Relay checks 100/100.
- *(low)* Session ids are process-wide, so a replaced relay's `socks[N]`
  lines cannot be confused with its successor's in Settings → Logs.
- *(low, older than this fix)* A listener failure is acted on only if the
  relay that reported it is still the one in use. A replaced relay could
  otherwise cost its successor a restart from the 2-a-minute budget.
- *(cosmetic)* The dashboard self-test reports a missing pushed frame as a
  failure message, not a traceback.

**Not fixed** *(low, older than this fix)*: a stopped relay has no idle
reaper. Its sessions end when a peer closes or errors. That is bounded by
the cap it had before the recovery, and the connections outlived the relay
before this fix anyway.

## 2026-09-21 — Owner actions O1 and O3 done; the install step without Xcode's UI

**O1:** the Apple ID is in Xcode as a free personal team, "Olof Johansson
(Personal Team)", Team ID `DX33PQ7J4A` (read from Xcode's settings). It is
kept in `app/.dev-team`, which is gitignored. `DEVELOPMENT_TEAM` stays blank
in the project, as DEVICE-CHECK.md intends.

**O3:** the "admin purgatory" policy is applied (D5).

**O2 is waiting for Olof to be at chonk with the phone.** A free team
installs only through Xcode, from a Mac the phone is paired with. There is
no TestFlight or ad-hoc build without the paid Developer Program. Pairing
needs the phone at the Mac, and the Developer Mode switch appears only after
it has been connected to one. The runbook now says so.

**Decision:** `make device` (`app/scripts/device-run.sh`) builds Release,
signs with the team in `.dev-team` (`-allowProvisioningUpdates`, which also
makes the certificate and 7-day profile and registers the phone), installs
with `devicectl` and launches. A session can do the install once the phone
is paired, and it is a Release build, what would ship, rather than Xcode
Run's Debug.

The runbook's later steps were stale since M4 and M5: the app picks the
gateway itself, finding none until O3b, and signs in through its own Sign in
sheet, not the page's banner. Updated.

**Free-team limits to keep in mind:**
- the profile lasts 7 days. After that the app will not launch until it is
  reinstalled from chonk; its data survives;
- at most 3 sideloaded apps per phone.
Neither blocks M1, M6.6 or M7. Overnight timings fit well inside a week.

**Checked before the first install:**
- the Release app compiles for a real iPhone (arm64, unsigned, `generic/platform=iOS`);
- none of the test hooks is in the Release binary (R15). The same probe finds them in the
  Testing build's `Latchkey.debug.dylib`, so it can see them. The one
  `UITest` symbol left is `WorkspaceStore.isUITestProcess`, which is meant
  to be in every build: it only moves a test run's data aside.

Full tier on the relay review fixes (app `62dfae1ad`, parent `f44cad0`):
host, vendored Go, L1, L2, session, discovery, lifecycle 5/5 and inherited,
all green.

## 2026-09-21 — While waiting for the phone: upstream, security, device preflight

**Upstream:** `git fetch upstream` on 2026-09-21. aperture-plus `main` is
still `dba0555` (2026-08-24), the last revision reviewed, so there is
nothing to cherry-pick.

**Tailscale security bulletins since July:** TS-2026-009 and -010 (Tailscale
SSH) and TS-2026-011 (4via6 subnet routers). None applies to the vendored
tailscale 1.103.0 as the app uses it: nothing sets `RunSSH` or advertises
routes (only the LocalAPI prefs types mention `AdvertiseRoutes`). No
vendored update needed.

**`make device` checks the phone before building.** From `devicectl`'s
current `properties` layout, with the deprecated keys as a fallback, it
stops with a plain reason when:
- the phone is not paired (tap Trust);
- Developer Mode is off;
- the phone is unreachable.
An idle phone reading "available" is not blocked. It also prints the iOS
version, so O2 has nothing left to report. It was tried against crafted
`devicectl` output for each state (a fake `xcrun` on `PATH`), since no phone
is paired yet.

**Corrected 2026-09-23, by the first real phone.** The crafted output was
made by flipping a simulator's `reality` to `"physical"`, and a real device
reports **no `reality` field at all** — only simulators say `"simulated"`.
So `make device` found "no paired devices" with the phone sitting right
there, paired. The filter now excludes simulators instead of requiring
"physical", and `DEVICE=` also matches a device by name. The lesson: a
fixture built by editing a neighbouring record assumes the fields are the
same shape, and here the absence of a field was the whole difference.

Olof's phone is **"Telefone (2)"**, iPhone15,2, iOS **26.6.1** (the version
#9399 was reported on), UDID `00008120-0000000000000000`.

## 2026-09-23 — The first device install: three things the plan did not have

**1. Developer Mode reads stale.** `devicectl list devices` answers from
CoreDevice's cache, and the cache was wrong in exactly the case that
mattered: after the phone had Developer Mode switched on and was connected,
it still said "disabled" and "disconnected". `devicectl device info details`
asks the phone, and says why it refuses ("The operation failed because
Developer Mode is turned off"). `make device` now asks whenever the cache is
short of ready. It also no longer blames the cable when the phone is on the
USB bus.

**2. xcodebuild had no usable Apple ID.** Xcode's UI was signed in enough to
have made a certificate (`Apple Development: Olof Johansson`, team
`DX33PQ7J4A`), but `com.apple.dt.Xcode`'s account list was empty and
xcodebuild said "No Accounts", so it could not mint a profile. The first
install therefore went through Xcode's Run. `make device` now retries without
`-allowProvisioningUpdates` when a profile already exists, so later installs
need no account.

**3. Tailnet lock.** The tailnet has tailnet lock on, so the new node showed
as **"Locked Out"** in the admin console and no peer would talk to it. It has
to be signed from a signing node (`tailscale lock sign nodekey:…`); the
console cannot, since the signing key never leaves the node. This is a step
per NEW node: a rebuild over the installed app keeps the node, deleting the
app does not. Recorded in DEVICE-CHECK.md §3 and the README's re-sign
section. It is independent of purgatory (O3b) and of the key expiry warnings
(R31/R33) — a third way for the app to be up and reach nothing, which
Diagnostics does not name yet (see the open question below).

## 2026-09-23 — O4 answered (for box), and what the phone's own filter proved

**O4, from `kirocrew config get dashboard.tailscale` on box:** `enabled`
true, `trust_identity` true, `allowed_logins` `["owner@example.com"]`,
`pin_scope` `node`, `bind_refresh_chains` true, `keep_awake` true.

So M7.5's preconditions hold on box (trust_identity with a non-empty
allowed_logins that includes the login), and `pin_scope: node` confirms R6:
renaming the node after a sign-in signs the app out. It changes nothing about
the token: PLAN §116 stands — with `trust_identity` on, the gateway resolves
the tailnet peer only when a credential is already present, so identity
narrows access and never grants it. **The app still has to hold a token.**

**box is a second, local gateway.** It already served `https://box.…/` →
`127.0.0.1:5476` over the tailnet. Since it is minutes away rather than a
continent, it separates two failure modes that look identical on screen: a
blank dashboard (#9399) and a slow path. With both gateways granted, the
picker will list two, so it will no longer auto-choose (M5.3) — the owner
picks.

**Why the phone reached nothing, settled from evidence.** Its netmap cache
(pulled over USB from the app's container) holds the packet filter its node
was given:

```json
{"Rules":[{"SrcIPs":["<chonk>","<air>"],"DstPorts":[{"IP":"*","Ports":{"First":0,"Last":65535}}]}]}
```

That is grant 1 of D5 (chonk and air may reach the device) and the only rule
the node has. Nothing grants the phone outbound access, which is why every
dial ended in `context deadline exceeded` — dropped SYNs, not refusals — to
byskebox AND chonk. The node itself was healthy throughout: address
the moved `kiro-clients` address, `machineAuthorized=true`, tailnet lock ok,
DERP connected.
The `kiro-clients` grant (`100.82.1.0/24` → `byskebox`, `box`, port 443) is
still missing. Discovery cannot find a gateway the policy forbids, and no
number of Search agains changes that.

**A better diagnostic channel, found today:** while the app is
development-signed, `xcrun devicectl device copy from --domain-type
appDataContainer` reads its container — `Logs/tsnet.log`, and the netmap
cache with the filter and the peer list. That is how tonight's faults were
identified without guessing. It stays local (D1 is about not uploading, and
tsnet.log is redacted before it is written).

## 2026-09-23 — D4 superseded: chonk is a usable gateway, and so is box

D4 and R26 ruled chonk out of v1 because its dashboard listens on
`127.0.0.1:5476` only, and a plain-HTTP origin fails both the dashboard's
own `/api/ws` origin check and the app's ATS-only rule (R28). The premise is
no longer true: chonk already has `tailscale serve` in front of it.
`https://chonk.…/` answers **HTTP 200 with the KiroCrew frontend in 30 ms**,
and Tailscale's extension already listens on 443. The dashboard is still
loopback-only; serve is what makes it a proper tailnet HTTPS origin.

So chonk needs no change, only a grant. Same for box, which was already
served. **Neither needs app work:** discovery probes every candidate peer and
never excluded chonk by name — it was probing `chonk:443` tonight and being
dropped by the policy.

What this changes:
- the `kiro-clients` grant covers `byskebox`, `box` and `chonk` on 443;
- M7.6's AC ("discovery finds byskebox and nothing else") is wrong now:
  three gateways is the real shape, so the picker lists them and does not
  auto-choose (M5.3). Gateway switching (Settings → Gateway, M5) is no longer
  a nicety; it is how the owner reaches the machine he wants;
- each gateway is its own sign-in: sessions are per host, so a token is
  minted per gateway;
- box and chonk are minutes away rather than a continent, which separates a
  blank dashboard (#9399) from a slow path.

## 2026-09-23 — From the plan to feature requests, spec first

Olof: "I think most of the original plan is now implemented. We should switch
from working off of that plan, to a mode where I give you requests for
features to consider and implement. I want you to plan, design and document
the feature in a similar PLAN document with finegrained details before you go
ahead with an implementation. This is true for all feedback and all requests I
give you, and I expect you to add suitable end to end testcases (unit tests
don't matter as much)."

**Adopted, with a place to put it:** `docs/features/`, one document per
request, `README.md` for the rule and `TEMPLATE.md` for the shape. A spec
names files, types and functions, says what the owner sees when it works AND
when each part fails, lists the invariants it must not break, and specifies
its end-to-end tests including **how each test was shown able to fail**. The
PLAN stays as history; where a spec disagrees with it, the spec wins.

Recorded in `app/AGENTS.md` too, since agents read that first.

- **F1** (`features/F1-gateway-port.md`): a gateway carries a port, 8443 the
  standard one. Specified, not started.
- **F2** (`features/F2-connecting-state.md`): the connecting state for the
  blank screen. It was briefed and started an hour before this rule existed,
  so its spec was written from the brief afterwards and says so.

**Why end-to-end and not units, in this project's terms:** every fault the
device run turned up today — a dropped SOCKS dial, a stale devicectl cache,
a locked-out node, a policy with no grant — was invisible to unit tests and
obvious to a suite that drove the real app. The existing L1/L2/session/
discovery/lifecycle suites are the model, and they earn their keep.

**Open question for M1's record:** should the app recognise a locked-out node
and say so? tsnet's status carries a tailnet-lock field, and "connected but
reaching nothing" is otherwise indistinguishable from purgatory in the UI.
Cheap to add to Settings → Status; decide after the device check, when it is
known whether it ever bites again.

## 2026-09-21 — The device check's O3b step, rehearsed on L2

In O3b the owner moves the phone's node from purgatory into `kiro-clients`
while the app is running: **the node's own IP address changes under it**.
Nothing had exercised that, nor what the picker shows while the node reaches
nothing. A Fable agent built the rehearsal, harness-side only.

**Harness** (`testing/tsnet-harness`):
- `/purgatory` jails the app's node at every harness peer unless its IPv4
  is in the fixture clients range `100.99.1.0/24` (fixture ranges only, not
  the real policy's). The peers stay visible, and every SYN is dropped.
- `/move` changes the running node's IPv4. (As first built it also pushed
  the node a raw netmap; the review below replaced that.)
- The self-test grew four steps.

**`DiscoveryTests.testDeviceCheckRehearsalPurgatoryThenAddressMove`:**
- *In purgatory:* the picker says "No Kiro Crew gateway answered among 4
  computer(s)" when the sweep ends, 1.5–1.6 s. Every probe hits its timeout
  and nothing hangs.
- *After the move to `100.99.1.7`:* Search again lists the gateway, and it
  is chosen by itself. The Sign in sheet opens with no navigation error.
- The gateway journals the app from the new address and never from the old
  one, and Status shows the new address.
- The app needed **no change**: its proxy rules are name- and range-based
  (R27), and only Status reads the node's own address.

**What it cannot model:**
- a policy under which the purgatory node sees no peers (the picker then
  says "No computers…" and re-searches by itself when peers appear);
- DERP-only paths;
- the real control plane's delivery delay.

The runbook now says what to expect in each case, and to tap Search again
once more before calling it a fault.

Results: harness self-test ×3, discovery 5/5 ×4, L2 9/9 with the login-link
scan, host tests all green.

**Review (Fable, adversarial):** three medium and five low findings, all in
the harness. None affects the app, and no current suite hit them. They would
have made the next test built on `/move` flaky with no clue why.

*Fixed:*
- **(medium) A moved node went deaf, and a re-login split its address.** The
  raw netmap push made testcontrol stop all automatic updates to that node:
  peers joining later, endpoint changes, a restarted map poll. A re-login
  then left its own address and its peers' view of it apart for good.
  *Decision:* a minimal patch to the vendored testcontrol, its own commit
  (R16), as R32's was. A node's own addresses come from its stored entry,
  and are derived from its ID only when the entry has none. Every entry
  `serveRegister` makes holds exactly that derived pair, so no other node
  changes. `/move` is now just `UpdateNode`, and the push machinery is gone.
  The patch is to a test-only package, not in the app, but its `.go` source
  makes the framework stamp stale, so one rebuild follows.
- **(medium) The first-join jail race.** The peers could learn of the app
  unjailed a moment before the jail landed. The jail is now applied from
  testcontrol's `HoldMapRequest`, before the request that wakes the peers.
- *(low)*
  - `/move` refuses an unknown host (404), an ambiguous one (409), a harness
    peer, testcontrol's own pool, and a no-op move;
  - purgatory updates are serialized;
  - the discovery log check requires exactly one all-failed purgatory sweep;
  - the UI test taps Search again once more if the first search comes up
    empty, as the runbook tells Olof to;
  - two new self-test steps: a moved node sees a peer that joins after the
    move and reaches it, and purgatory switched on mid-run jails a node
    already present. Run against the reviewed harness, the first one fails,
    so it can fail.

Rerun: harness self-test green, discovery 5/5 twice (the framework rebuilt
first), L2 9/9, lifecycle 5/5.

## 2026-09-23 — The product is renamed to Latchkey; three identities keep the old name

**Decision:** Latchkey becomes **Latchkey** everywhere it is a *name* —
target, scheme, project, Swift types and files, the home-screen display name,
and all prose. Three classes of identity keep the old spelling, deliberately:

1. **Bundle identity.** `net.lixom.latchkey` (app and UI-test target), the
   os_log subsystem that mirrors it, the DispatchQueue labels, and the App
   Group F3 would add. Olof's instruction: keep the bundle id so the app keeps
   its container and its Tailscale node.
2. **The on-disk data root**, `<Application Support>/Latchkey/` and the
   `Latchkey-UI-Test*` siblings.
3. **The default tailnet hostnames**, `latchkey-iphone` / `-ipad` / `-roam`.

The vendored tree (`ThirdParty/`, including `latchkey_locallog.go` and
`TestLatchkeyRawStderr…`) is untouched under R16, so `scripts/test-all.sh`
still runs `go test -run Latchkey`.

**Why:** the previous rename (Aperture → Latchkey) could move the data root,
and its script says exactly why it was safe: *"the bundle id changed too, so
this is inside a different app container and there is nothing to migrate."*
**That condition is absent this time.** Same bundle id means the same
container, so `<Application Support>/Latchkey/` is a live directory holding
each workspace's tsnet state dir — the node's identity — plus
`workspaces.json` and the logs. Renaming the literal would silently point the
renamed app at an empty directory: new node key, fresh login, tailnet-lock
re-signing, new grants. Nothing would crash; Olof would simply find himself
logged out with an unapproved device. The cost of the stale-looking literal is
one comment; the cost of renaming it is the device bring-up chain again.

The hostname is the same class of thing for a different reason: it is the
node's MagicDNS name, it is what the admin console and any host-scoped grant
refer to, and a live install carries its own copy in `workspaces.json` anyway.
Changing the default would rename only future fresh installs, producing a node
whose name Olof's grants may not admit. Rename it only together with that
grant.

**Also renamed, in lockstep because both ends are ours:** the app's probe
header `X-Latchkey-Check` → `X-Latchkey-Check`, sent by
`App/Browser/PageScriptSources.swift` and counted by
`testing/harness/fake_gateway.py`. A host test asserts the name
(`scripts/test-session-fetch.js`) and caught the first pass, which had missed
`.js` files entirely.

**Not renamed:** the repository directories (`~/src/latchkey`, and the
`latchkey` / `latchkey-app` names in the GitHub question). Nothing in the
build refers to the directory by name, and renaming it would orphan this
project's agent session history and memory, which are keyed on the path.

**Evidence:** `app/scripts/rename-to-latchkey.py` is the recipe, with the
preserved strings listed by name and a `--check` mode that lists every
remaining mention for review; 45 remained in the parent and 61 in the app, all
in the three preserved classes or in the historical record of the *previous*
rename. Verified after: `make test-policy` green, `make app` **BUILD
SUCCEEDED**, and the built bundle reports `CFBundleIdentifier =
net.lixom.latchkey`, `CFBundleDisplayName = Latchkey`,
`CFBundleExecutable = Latchkey` — the rename is visible to the owner and
invisible to the container.

**Two traps found while doing it**, both recorded because they would recur:
- masking `"Latchkey"` (quoted) to protect the data root also protected the
  **target name** in `project.pbxproj` and `.xcscheme`, leaving the project
  half-renamed. The script now masks the quoted form in `.swift` files only.
- the script rewrote the bare old name inside the very comment that warns
  against renaming the data root, inverting its meaning — twice. The comment
  is now phrased without the literal.

## 2026-09-23 — Portability: the app was already tailnet-policy agnostic; the specificity was in the guards and the docs

**Decision:** make the project runnable by someone who is not its author,
without loosening anything. Five changes went in directly; three behaviour
changes went to a spec (`features/F7-portable-discovery.md`).

**What the review established first, because it changes the shape of the
answer:** there is **no** ACL, grant, purgatory, approval or address-range
concept anywhere in `App/` or `TSNet/`. The only hardcoded network constant is
Tailscale's own CGNAT range (`TailnetProxyPolicy.swift:93`). Purgatory appears
in the runbook, the plan and the test harness — never in the product. So a flat
tailnet needs no code change to work; its path is strictly shorter. The
author-specific parts were the *documentation*, the *test guards* and a handful
of placeholder strings.

**Done directly:**

- **The fixture-tailnet guard is now an allow-list.** Five suite preflights and
  `TestNetworkFixture` each grepped for one hardcoded string — the author's own
  tailnet — so the guard protected exactly one person: anyone else's real
  tailnet passed a check that looked like it was checking. Replaced by
  `scripts/check-fixture-tailnets.sh`, which permits only `tail-scale.ts.net`
  and `example.ts.net` and fails on any other `*.ts.net`. Shown able to fail: a
  planted non-fixture tailnet name is rejected, a missing file is an error
  rather than a pass (the M3 review's lesson, preserved).
- **No real tailnet name remains anywhere** in either repo, verified
  case-insensitively — including host tests that had them in `expect(...)`
  strings, which the earlier greps missed twice: once because the parent's
  `grep` does not descend into `app/`, and once because the name was
  mixed-case.
- **Generic examples in the UI.** The gateway placeholder and the manual-entry
  error named the author's own machine; they now say `gateway`.
- **The bundle id is overridable**, `$(LATCHKEY_BUNDLE_ID:default=net.lixom.latchkey)`,
  matching how `DEVELOPMENT_TEAM` already works via `app/.dev-team`. Verified
  both ways: the default still resolves to `net.lixom.latchkey` (so this
  device's container and node are untouched) and an override takes effect.
- **The node's default name follows the product**, `latchkey-iphone`. Safe
  where renaming the data root was not: it is only a *default*, a live install
  carries its own copy in `workspaces.json`, and the tailnet grant is scoped by
  address range, not node name. This reverses the cautious call made earlier
  the same day, on that evidence.
- **`docs/SETUP.md`**, written for someone else: a flat tailnet as the short
  path, with approval, tailnet lock and ACLs as separate rows rather than
  assumptions. `README.md` no longer claims the project is unimplemented, and
  `DEVICE-CHECK.md` now says in its header that it describes one environment and
  that its purgatory step is meaningless on a flat tailnet.

**Deferred with it:** 8443 as the standard serve port (F1). On 443 a gateway
needs nothing but `tailscale serve`; on 8443 it needs `KIROCREW_CORS_ORIGINS`
and a restart, and missing that produces the silent "loads fine, does nothing"
failure. Making the standard port the one that needs extra server setup would
hand that to every new user on their first attempt. Olof: "I'm fine with staying
on 443 for now."

**Evidence:** `make test-policy` green; the full quick tier re-run after the
changes. The three findings that are behaviour — discovery's owner/OS/sharee
filters hiding a gateway silently, the sweep abandoning candidates past ~24, and
the picker claiming it checked `candidateCount` when it probed fewer — are
specified in F7 rather than changed here, because the spec-first rule applies to
behaviour even when the change is small.

## 2026-09-23 — One repository: the app's history is rewritten under `app/`, not grafted

**Decision:** collapse the two git repositories into one, rooted here, on branch
**`main`**, with `origin` = `github.com/olofj/latchkey` (private). `app/` is
now an ordinary directory. Olof's ask, after creating the repo.

**Why the history was rewritten rather than merged as-is.** The obvious move is
`git merge --allow-unrelated-histories` on the app's branch. That preserves the
commits but records them against their **original, unprefixed paths** — so
`git log -- app/ThirdParty/libtailscale` would return nothing before today, and
R16's promise that *"`git log -- ThirdParty/libtailscale` is the complete delta
from upstream"* would quietly stop being true. The provenance would still exist
but no documented command would find it.

So all 272 app commits were rewritten with `git filter-branch --index-filter` to
carry the `app/` prefix, then merged with `--allow-unrelated-histories`. After
it, `git log -- app/ThirdParty/libtailscale` reports **32 commits**, the same
delta as before. 329 commits total (55 + 272 + 2).

`git-filter-repo` and `git subtree` are both absent on this Mac, so
`filter-branch` was the tool; it is deprecated, not wrong, and this is a
one-shot.

**What did not change: anything on disk.** `app/` stayed exactly where it was,
so every script, `Makefile`, relative path and doc reference kept working
untouched. The collapse is purely a git-level change, which is why it was safe
to do in one pass. The app's ignored artefacts (4.2 GB of build output, the
xcframework, `.dev-team`) were moved aside and back by **rename**, never copied.

**The one real cost: cherry-picking from upstream.** Upstream's paths are
root-relative; ours are under `app/`, so `git cherry-pick <upstream-sha>` no
longer applies. The recipe is now
`git format-patch -1 --stdout <sha> | git apply --directory=app --3way`,
recorded in `../app/AGENTS.md`. Upstream tracking stays cherry-pick-only (R16).

**Also:** `master` → `main` (matching the app's own convention and GitHub's
default); the parent's `.gitignore` no longer ignores `app/`; `upstream` is
re-added on the unified repo. A `.git` backup of both original repositories was
taken first and kept at `/tmp/kn-collapse-backup/`, and the app's pre-collapse
working copy at `~/src/kn-app-aside` — neither is needed once the
first push succeeds.

**Evidence:** all 3030 tracked app files byte-identical to the pre-collapse copy
(`cmp` per file); working tree clean; both histories reachable by path-limited
log; `make test-policy` green.

**Corrected the same day — the collapse did break something, and this entry
claimed otherwise before the evidence was in.** The sentence above originally
said "the quick tier re-run after the collapse"; it was written while that run
was still in progress, and the run then failed two suites. **L2 and lifecycle
both died in preflight** on
`git -C "$APP" rev-parse HEAD:ThirdParty/libtailscale/tailscale-patched`
(`scripts/test-tailnet.sh:59`, `scripts/test-lifecycle.sh:82`): `HEAD:PATH`
resolves from the **repository root**, not from the `-C` directory, so a path
that was correct while `app/` was its own repository is now wrong. Fixed by
making it cwd-relative, `HEAD:./ThirdParty/…`, which survives wherever `app/`
sits. Host tests, L1, session and discovery all passed, which is why the
breakage was invisible until the tiers that use that stamp ran.

That miss is the same pattern this day's review named: **verify, then change,
then do not re-verify.** Recording it here rather than editing the claim away,
because the failure mode matters more than the typo.

**Still true and worth restating:** a policy here blocks the agent from pushing,
so Olof performs the first upload to `origin` himself.

## 2026-09-23 — Full adversarial review: one mistake wearing four costumes, and the rules adopted against it

**Why:** three defects reached a "verified" state in one day because the checks
meant to catch them could not fail. Olof asked for a full-codebase adversarial
review. Seven reviewers ran in parallel over test integrity, concurrency,
network invariants, secrets, harness fidelity, persistence and documentation;
every finding below was reproduced against the code before it was accepted, and
several of the reviewers' own best hypotheses were disproved by measurement and
dropped.

### The systemic finding, which is worth more than any single defect

**Four protections had each been written correctly once and never carried to the
sibling path**, and in three of the four a comment asserted the parity that did
not exist:

| Protection | Applied to | Missing from |
|---|---|---|
| real-tailnet-name guard | one hardcoded tailnet | every other real tailnet |
| on-tailnet check before an origin is trusted | the gateway picker | Settings → Gateway |
| fetch abort so a dead gateway cannot hang the app | sign-out | the session check |
| case folding in the fixture-tailnet guard | the Swift half | the shell half |

**Rule adopted:** a protection goes where every caller must pass through it, not
at each call site. `GatewayCandidates.manualGateway` is now the only way to turn
typed text into a trusted origin and its normaliser is `private`, so a third
entry point cannot be added that forgets the check. Where two implementations of
one rule must differ (the Go and Swift redactors), the divergence is stated at
both sites with its reason.

### Rules adopted about verification itself

1. **A check's "not found" branch must never also be its error branch.** `grep`
   exits 0 for a match, 1 for no match and **2 for an error**; three R1/R10 disk
   scans put 1 and 2 in the same `else`, so an unreadable file plus a real token
   hit printed "ok". Judge the output and the status separately.
2. **A negative instrument needs positive evidence that it was looking.**
   `check-no-log-upload.sh` concluded "no upload" from zero sockets, which is
   also what a crashed app produces; it now requires the node alive and at least
   one expected endpoint seen, and gained a `--replay` mode so the verdict itself
   is testable.
3. **A guard proves itself on planted input before it judges anything.**
   `check-fixture-tailnets.sh` now self-checks on a mixed-case sample every run;
   a broken guard announces itself instead of passing everything.
4. **Match a secret literally, never by shape.** The login-link scan grepped for
   a hex pattern; the shape belongs to the control server. It now greps for the
   literal links the harness published, and an empty list is an error.
5. **A rename verifier must check both directions.** `--check` listed leftover
   old names and was blind to names the rename wrongly *changed* — which it had:
   vendored `latchkey_*` references became `latchkey_*`, and a log predicate in
   PLAN.md matched nothing. Now derived from `PRESERVE`; `--check --rev cbfdc31`
   reproduces the four damaged lines.
6. **Show the test failing, then say how.** Every fix here cites it: 26/34
   workspace documents, 12/16 redaction rows, 7/18 session-manager rows, 7 of 52
   Swift redaction rows, 4 gateway-gate rows.

### Product defects fixed

- **A main-frame 5xx committed as the document.** `decidePolicyFor
  navigationResponse` never inspected the status. Behind `tailscale serve`, whose
  reverse proxy has no error handler, a Kiro Crew restart answers **502 on a live
  port**: TLS succeeds, no `NSURLError` fires, the relay renders no verdict, and
  a blank page commits with no overlay and no retry. Specified in F4 as D10/D11
  rather than patched, because **a `403` with `X-Auth-Required` must keep
  committing** — refusing it would turn a gateway-refused sign-in into "couldn't
  reach the gateway". The harness's "down" mode closes after TLS, which models a
  host going away, not a restart; both shapes are needed.
- **The session check could hang forever**, disabling R30's own detector. Bounded
  at 4 s, derived from R39's probe budget and checked against sign-out's 10 s.
- **Settings → Gateway trusted an off-tailnet host** and would have sent it a
  pasted token. One gate now, failing closed, with the refusal displayed.
- **D1: every navigation was submitted to the system fraud-check service.**
  `isFraudulentWebsiteWarningEnabled = false`; the test asserts the OS default is
  on first, so it cannot pass vacuously.
- **Every SOCKS failure read as "URL format error"** (-1000 is what WebKit
  reports for all of them). `.urlFormat` turns out to have **no live producer**.
- **A malformed `workspaces.json` silently destroyed the node identity.** The
  guarantee now lives in `save()`, which re-reads before every write and refuses
  to clobber a file it cannot read — so no caller can reintroduce the loss. A
  hand-written `init(from:)` tolerates missing fields, and `ephemeral` defaults
  to **false, never the launch flag**, because control deletes offline ephemeral
  nodes: the wrong default would *be* the identity loss. **New
  `WorkspaceDefinition` fields must be added to `CodingKeys` and `init(from:)`
  with a default or as optional** — F5 and F6 both claim safety via synthesized
  `Codable` and must be updated.
- **Login links reached disk unredacted.** Every node shares the process logtail,
  whose filch buffer got the raw line while only the `tsnet.log` echo was
  redacted; a process killed mid-login left it until next launch (5.8 KB of
  undrained stderr found in the live container). Redaction now wraps the buffer,
  proved by reading the file before any drain. Both rules are charset-agnostic
  and case-insensitive; the L2 harness mints **hostile** login links by default
  so this cannot regress silently.

### Build identity

`app/Latchkey.xcconfig` (tracked, default `net.lixom.latchkey`) including a
gitignored `Local.xcconfig` is the single identity file, because an environment
variable **cannot** work: `xcodebuild` imports the shell environment, Xcode.app
inherits no shell, so an export gave the two different bundle ids — two apps,
one with an empty container, i.e. a fresh node. The team leaves
`project.pbxproj`: with it there, a `Local.xcconfig` team line was silently
outranked. Safe order for any identity change: Reset app, then delete, then
change, then install.

### Left open, deliberately

- ~~`TSNetManager.startTailscale` calls `fatalError` when the node cannot be
  created, so an unopenable state dir is a crash loop whose only exit is
  deleting the app — which is identity loss. Needs a design, not a quick guard.~~
  **Specced 2026-09-23 as [F8](features/F8-node-start-failure.md); still to
  build.** Writing it found a **second** trap on the same fault, firing earlier:
  `WorkspaceManager.init`'s `fatalError` when `TailscaleLogging.setup` throws, on
  a directory in the same unwritable tree. Fixing only the reported one would
  have left the crash loop intact for precisely the case that motivated the fix.
  It also cannot merely be caught: the filch that redacts tsnet's Go stderr is
  what failed, so a logging failure has to *prevent* node creation rather than be
  reported and ignored.
- A relay with a dead upstream surfaces as `-1009`, which
  `SocksRelayRecovery.isTransportFailure` does not classify. By design (the
  status poll repairs it), recorded so the next reader does not treat it as a
  gap.
- ~~The real tailnet name and two host addresses remain in **git history**. The
  working tree is clean; rewriting history is Olof's call and is cheapest before
  the first push.~~ **Done 2026-09-24**, before the first push, by
  `scripts/history-scrub.sh` — see that day's entry below. The "two host
  addresses" turned out not to be his: the survey found only fixtures,
  documentation examples, a public resolver, Tailscale's own range and
  deliberately-named endpoints in the no-log-upload guard.

## 2026-09-24 — Latchkey: the rename that moved the identity, and the history scrub

The previous name was trademark-encumbered. Investigation the day before made
that clear enough that it had to leave the product *and* the repository, so this
rename is unlike September's in two ways.

**It moved the app's identity.** September deliberately froze the bundle id, the
os_log subsystem and `<Application Support>/` so the install kept its container,
and therefore its tsnet node, its tailnet-lock signature and its grants — which
is why that rename cost nothing. Here the encumbered string *was* the bundle id.
So it became `net.lixom.latchkey`, the container moved with it, and **the app is
a new node**: it logs in again, needs device approval, needs re-signing under
tailnet lock, needs a grant for its new address, and the old node lingers in the
admin console until removed. Olof accepted that explicitly beforehand. No
migration was written — one install, and logging it back in is cheaper than code
that runs once. Verified in the built product rather than the source:
`Latchkey.app`, `CFBundleIdentifier net.lixom.latchkey`.

**The one real hazard was the product this app is a client of.** That dashboard
is a different, official project and is *not* renamed, so the code must keep
naming it — and two of those uses are load-bearing rather than cosmetic:
discovery recognises a gateway by matching its web-app manifest on a literal
name, and pairs it with `X-Auth-Required`. Its lowercase spelling **contains**
our old one. A substitution aimed at ours reaches inside it unless masked, and a
run that corrupted it would pass a one-directional check while breaking
discovery on every tailnet with no error at all — the sweep would simply report
zero gateways. Hence `scripts/rename-to-latchkey.py` masks that family first,
carries no bare four-letter rule, and checks **bidirectionally**.

Three misses, all found by hand greps rather than by the checker meant to find
them, and the third is the one worth remembering:

- a mixed-case spelling (capital first letter, lowercase second word) was not in
  the substitution list and survived as a Go test function name;
- `--check` skipped the vendored tree;
- **`--check` shared the rewriter's extension list.** A file the rewriter cannot
  see is a file the checker cannot see either — which is how `app/NOTICE`, a
  file with no extension, kept the old name through a *passing* check. The
  checker now walks every non-binary file regardless of extension, deliberately
  wider than the rewriter, and found it immediately. Same shape as this
  codebase's recurring finding: a guard written once and not carried to its
  sibling.

### The history scrub

Driven by `scripts/history-scrub.sh`, before the first push — which is the whole
reason it is cheap: nothing has been published, so there is no clone to diverge
and no force-push to explain. It removes the owner's real tailnet name (18
commits) and both former product names, and `--prune-empty` drops the rename
commits, which become no-ops once both sides of their diffs say Latchkey. The
result reads as though the project was always called Latchkey. That is a mild
fiction and it is the point: the encumbered name has to be *absent*, not merely
superseded.

The tailnet name is an **argument** to that script, never a constant in it. The
scripts are committed, and baking the secret into the scrubber would put it
straight back, in the one file guaranteed to be read.

**No IP addresses were scrubbed, because none needed to be.** Olof's rule was
that tsnet-side `100.x` may stay but his real addresses may not. A survey of
every address in the history outside the vendored tree found: test fixtures,
documentation examples, a well-known public resolver, Tailscale's own DERP
range, and endpoints deliberately named in `check-no-log-upload.sh` so the app
can be asserted never to talk to them. None of them is his. Addresses inside the
vendored tree are upstream's own test data, and rewriting those would corrupt
the R16 delta. Recorded because "we found nothing" is a result, and the next
person should not have to redo the search to learn it.

## 2026-09-24 — F7 built: a test on a boundary is a coin flip

F7 (portable discovery) is in, discovery suite 10/10. The feature itself is
small — report what was probed, resume at a cursor, offer the peers a filter
declined — and the interesting part was the fixture.

**A large-tailnet test has to clear the boundary, not sit on it.** A 12 s sweep
deadline at concurrency 12 with a 4 s probe timeout reaches roughly 36
candidates. The first version of both large-tailnet tests presented 40 peers,
and one run logged `probed=43/43 truncated=no` beside `probed=40/44
truncated=yes` — the same mechanism, opposite verdicts, one candidate apart.
Both now present 90. The rule worth keeping: when a test's subject is a
threshold, pick a fixture at a multiple of it, and get the threshold from the
code rather than from a guess.

**Many online-but-unreachable peers delay the reachable ones.** With 40 such
peers, probes to `gw` and `dash` — both genuinely reachable — reached the proxy
(`socks[41] CONNECT gw…:443`) and never completed inside 4 s. Not the relay's
session cap: `SocksRelayCapacity` logged no refusal or eviction in the whole
run, which was worth checking before believing the tidier explanation. Mostly a
fixture artefact, because a real tailnet reports an unreachable peer as
**offline** and `exclusion` drops those before probing — but the one environment
that does produce visible, traffic-dropping peers is a restricted tailnet during
device purgatory, i.e. this one. Recorded as F7 §8 with the measurement, not
waved off, and the test was rewritten to assert what the feature promises (the
count climbs on every tap and reaches the total) rather than something the
fixture cannot deliver.

**Log lines that a script parses are instruments, and they have scopes.** F7
first reworded `Discovery: probing N of M peer(s)` and appended its counters
inside the sweep summary; both are parsed by `scripts/test-discovery.sh` and the
summary's regex is anchored with `$`, so the parser silently recorded no sweep at
all. Restored byte-for-byte, counters on their own line. Then the counters
turned out to mean something different from the line above them — per-chain
versus per-sweep, because `probedCount` counts distinct hosts across
continuations — so `answered + failed == probed` holds only for a sweep that is
not a continuation. The suite now checks both forms. A hardcoded allow-list of
sweep signatures also had to go: it cannot survive tests whose probe counts vary
by a dozen between runs, so it applies to the small fixed tailnet only and
invariants apply everywhere.

## 2026-09-23 — two ways a green suite can mean nothing

Both found in one evening, both while verifying work that had already been
committed. Recorded together because they are the same mistake at two levels:
a check that cannot fail, and a check whose subject was not there.

**A control call that does nothing must fail the test that made it.** The new
502 test posted `/__mode?front=502` to the control port; the handler had been
written on the *dashboard's* handler, which a UI test can only reach through the
app's SOCKS proxy. It answered 404. Each suite had its own private `get`/`post`
pair, and all three checked the status on GET and none on POST — so the switch
silently did nothing and the test asserted against a healthy dashboard. It
failed, which is the only reason this surfaced; had the app's behaviour been
wrong the other way it would have passed while proving nothing. `post` now
throws on any non-2xx, from one shared implementation, and `make check` drives
the 5xx switch from the control port the tests actually use. This is the third
instance of the review's systemic finding — a protection written once and not
carried to the sibling path — and the second where the sibling was a copy of the
same helper.

**The harnesses are a singleton, so a suite and a harness-touching agent cannot
overlap.** `make -C testing/tsnet-harness up` (and its `check`) begin with
`down`, which calls `../harness harness-down` and kills the shared fake
dashboard by PID — deliberately, because both need the same ports (M3 review).
A subagent running the tsnet harness self-test therefore tore down a live
`test-offline.sh` between its two test phases: phase 1 passed all ten tests,
phase 2's `setUp` got `Connection refused` on :8480, and the run failed in a way
that looked like a regression in the change under test. The evidence is
unambiguous once looked at — the run's own `dashboard.log` had been truncated
and carried `gw.` peer requests from the *other* harness. Parallel agents are
fine; parallel agents that start a harness are not. Serialise suite runs against
them, or give the agent its own port set.
