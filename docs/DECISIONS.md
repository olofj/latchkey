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
`init()` in `ThirdParty/libtailscale/latchkey_nologs.go` calls
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
  `example` in the test config, and **warns** when host Tailscale is up.
  It is up on chonk (a `utun` holds `100.104.128.67`). Accepted per D7: leak
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
