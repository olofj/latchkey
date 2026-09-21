# Latchkey — Implementation Plan

**A single-purpose iPhone app for reaching a self-hosted KiroCrew dashboard over Tailscale, with the Tailscale node embedded in the app binary.**

| | |
|---|---|
| Status | In implementation. M0–M5 done; M6's simulator-testable parts done (6.5, 6.7, 6.8 on the L2 harness; 6.6 and the AC numbers need the device); M8 done (8.1–8.6). Revisions R1–R38 applied. Remaining work needs the owner or the phone: the M1 device check (O1–O3, O3b, O5), O4, O7, M6.6, M7. Where a revision disagrees with this document, the revision wins. Progress and every divergence: `docs/DECISIONS.md`. |
| Author | Drafted 2026-09-20 from three parallel research passes |
| Repo | `~/src/latchkey` |
| Base | Fork of [tailscale/aperture-plus](https://github.com/tailscale/aperture-plus) @ `dba0555` (2026-08-24), BSD-3-Clause |
| Target | iOS 26.0+, iPhone (iPad secondary) |
| Owner | Olof (`owner@example.com`), tailnet `example.ts.net` |

---

## 0. How to read this document

Sections 1–4 are context and architecture: read once, in order. Section 5 is the
work breakdown — each milestone is a self-contained unit with tasks, exact file
paths, and acceptance criteria. Section 6 is the test strategy and is deliberately
detailed, because most of this project's risk lives in "can we test this without
the owner's personal tailnet?" Sections 7–9 are risks, open questions and
reference appendices.

Every factual claim about aperture-plus, KiroCrew or Tailscale internals in this
document was verified against source during planning. Where something is
**inferred** rather than verified, it says so. Do not treat inferred claims as
settled — verify them in the milestone that depends on them.

**Conventions used below**
- `path/to/file.swift:123` — a real file and line in the upstream repo at `dba0555`. Line numbers drift once you start editing; treat them as "where to look", not as addresses. **R18:** libtailscale references (`tailscale.h`, `tstestcontrol/`, `swift/TailscaleKit/`) are to the vendored tree in `app/ThirdParty/libtailscale` (R16, `f55900d2`), not libtailscale `main`; they were re-checked against it on 2026-09-20.
- **AC** — acceptance criteria. A milestone is done when all of its ACs pass.
- Effort estimates assume one engineer working with an AI pair, and are in focused hours, not calendar time.

---

## 1. Goal and non-goals

### 1.1 The problem

Long-running Claude Code sessions run under KiroCrew on two gateways (`byskebox`,
a Linux VM, and `chonk`, the Mac Studio). Reaching them from an iPhone today means:
open Safari, make sure the system Tailscale VPN is connected, load the dashboard,
and re-authenticate by pasting a token URL produced by `kirocrew token` on a
computer. That last step is the real friction — it needs a second device.

**Corrected (R24):** re-authentication is rarer than this suggests. CLI links
(`kirocrew token` → `GET /api/token/local`) carry no `boot` claim, so their
sessions and 30-day refresh chains **already survive gateway restarts**; only
QR-minted sessions are boot-bound by default. The remaining friction is getting
the *first* token onto the phone — which the app addresses with paste and QR
entry (M4.4) — not restarts.

### 1.2 Goals

1. **One tap from the home screen to a live session.** An app icon that opens directly to the dashboard, with no browser chrome, no VPN toggle, and no tab to lose.
2. **No system VPN.** The app carries its own userspace Tailscale node, so it does not compete with any other VPN profile and works even when Tailscale's own app is off.
3. **Durable sign-in.** The session lives in the web view's cookies; the *page* renews it silently (R20), and the app asks for a new token only when renewal genuinely fails. (Originally "the token lives in the Keychain" — dropped by R5: a token is single-use within 300 s, and the Keychain outlives the cookies it would describe.)
4. **Gateway discovery.** The app finds KiroCrew gateways on the tailnet instead of requiring a hand-typed hostname.
5. **Testable without the owner's tailnet.** Contributors and CI must be able to run meaningful tests with no Tailscale account at all.

### 1.3 Non-goals (for v1)

- **App Store or TestFlight distribution.** Personal sideloading only. This also dodges the privacy-manifest blocker in [libtailscale PR #57](https://github.com/tailscale/libtailscale/pull/57).
- **Push notifications.** They need KiroCrew [PR #7821](https://github.com/kirodotdev/KiroCrew/pull/7821) (Web Push) or a native APNs sender. Section 9 keeps the door open.
- **A general browser.** No tabs, no address bar, no arbitrary navigation. Exactly one destination, chosen from discovered gateways.
- **Exit nodes and subnet routes.** Broken upstream in tsnet (see §7.4). Explicitly out of scope; remove the UI.
- **macOS.** The Mac already has the desktop app. Delete the Mac target.
- **Multi-user.** One person, one tailnet.

### 1.4 What "done" looks like

Olof taps the Latchkey icon on his iPhone 14 Pro with the system Tailscale VPN
**off**. Within a couple of seconds he is looking at a live KiroCrew chat on
`byskebox`, streaming over a WebSocket, with no sign-in prompt. He backgrounds
the app for an hour, comes back, and it reconnects on its own.

---

## 2. Background: what already exists

### 2.1 aperture-plus is 80% of this app

[tailscale/aperture-plus](https://github.com/tailscale/aperture-plus) is an
experimental WebKit browser for iOS and macOS with an embedded userspace
Tailscale node, written almost entirely by Avery Pennarun (197 of 200 commits).
It already solves the hard parts:

- Embeds `TailscaleKit` (the Swift binding in [tailscale/libtailscale](https://github.com/tailscale/libtailscale)) as a vendored submodule and builds it into an `xcframework`.
- Brings up a tsnet node, drives interactive login through `ASWebAuthenticationSession`, and persists node state.
- Obtains tsnet's loopback SOCKS5 proxy and points WebKit at it via `WKWebsiteDataStore.proxyConfigurations`.
- Implements a **split tunnel**: only tailnet destinations go through the proxy, because routing public traffic through it made every non-tailnet URL fail with `NSURLErrorBadURL (-1000)` on some hardware.
- Recovers from iOS reclaiming the loopback listener after suspension.

What it is not: single-purpose. It has tabs, an address bar, bookmarks, a macOS
app, and a virtualization feature. Our job is to remove those, pin one
destination, and add KiroCrew-specific auth and discovery.

### 2.2 Why fork rather than build fresh

A from-scratch build on `tunnelless` (MIT, ~250 lines) was considered and
rejected. aperture-plus carries roughly 3,000 lines of hard-won iOS-specific
knowledge — the `-1000` proxy semantics, the split-tunnel `matchDomains`
computation, the `node.up()` actor-starvation workaround, failure-driven loopback
recovery — that would otherwise have to be rediscovered by hitting the same bugs.
The cost of the fork is carrying code we delete once, plus tracking upstream.

### 2.3 What we verified about KiroCrew

The dashboard (0.6.0, installed at
`~/.kiro/crew-venv/lib/python3.12/site-packages/kiro_crew/`) is an SPA
that authenticates by signed token and streams over a WebSocket. Key facts that
shape the design, each verified in source:

- **Auth is a signed token in a query parameter**, exchanged for cookies. `dashboard/urls.py:364` builds `{base_url}?token={token}`.
- **Identity alone is never enough.** With `trust_identity` on, `dashboard/token_auth.py:2144-2152` only resolves the tailnet peer *when a credential is already present*. Tailnet identity narrows access; it never grants it. **The app must always hold a token.**
- **A refresh chain exists**: `POST /api/auth/refresh`, cookie-scoped to `/api/auth`, rotating on use, valid up to 30 days. This is what makes durable sign-in possible.
- **`GET /manifest.json` is unauthenticated** and returns `{"name":"Kiro Crew",...}` — our discovery probe. `GET /api/health` is deliberately uninformative through `tailscale serve`.
- **No user-agent sniffing** anywhere in the server, so a custom WKWebView UA is safe.
- **`frame-ancestors 'self'`** — the dashboard cannot be iframed from another origin. Load it as the top-level document, which is what we do anyway.

### 2.4 A live finding worth keeping in mind

During planning, simulator Safari (iOS 27) loaded `https://byskebox.example.ts.net`
over the tailnet and the dashboard **rendered correctly**. That is a live
counter-test of [KiroCrew #9399](https://github.com/kirodotdev/KiroCrew/issues/9399)
("dashboard renders blank in all WebKit browsers over Tailscale"), which is open
and disputed. It does not disprove the bug — the report is iOS 26.6.1 against a
Windows-packaged 0.6.0 — but it means we are not walking into a known wall.
**M1 must re-check this on the real device**, because a WKWebView uses the same
engine as Safari: if it breaks there, it breaks here, and the fix belongs in
KiroCrew, not in this app.

---

## 3. Architecture

### 3.1 Components

```
┌──────────────────────── Latchkey (single iOS process) ────────────────────────┐
│                                                                                │
│  SwiftUI shell                                                                 │
│   ├── ConnectionGate      — pre-connect screen, login button, status           │
│   ├── DashboardView       — one WKWebView, no chrome                           │
│   ├── GatewayPicker       — discovered KiroCrew gateways (new)                 │
│   └── Settings            — diagnostics, logs, gateway, sign-out               │
│                                                                                │
│  SessionManager (new)     — session state from page events; token entry (R20)  │
│  GatewayDiscovery (new)   — enumerate tailnet peers, probe /manifest.json      │
│                                                                                │
│  TSNetManager             — tsnet node, IPN bus, loopback SOCKS5, recovery     │
│  TailnetProxyPolicy       — split tunnel: which hosts go through the proxy     │
│                                                                                │
│  TailscaleKit.xcframework — libtailscale (Go tsnet compiled c-archive)         │
└────────────────────────────────────────────────────────────────────────────────┘
          │ SOCKS5 on 127.0.0.1 (credentialed)          │ WireGuard / DERP
          ▼                                              ▼
   WKWebView network stack                        tailnet → byskebox:443
                                                  (tailscale serve → :5476)
```

### 3.2 Traffic routing

Unchanged from upstream, and **do not simplify it** — `AGENTS.md` in the upstream
repo explicitly warns against collapsing the split tunnel back to an unscoped
proxy config, and `TSNet/TailnetProxyPolicy.swift:11-82` documents the measured
semantics.

- tsnet exposes a loopback SOCKS5 listener; username is literally `tsnet`, password is the per-launch `proxyCredential` (`tailscale.h:202-223`, `tailscale_loopback`).
- The app builds `ProxyConfiguration(socksv5Proxy:)`, calls `applyCredential(username:password:)`, and sets `matchDomains` to tailnet CIDRs plus MagicDNS names (`TSNet/TSNetManager.swift:501-549`).
- `allowFailover` stays **false** (the Network.framework default, `proxy_config.h:220-224`). This is what guarantees a dead proxy fails the load instead of leaking direct. **Add a unit test asserting it is false** — flipping it would be a silent privacy regression.
- TLS is end-to-end to the real `*.ts.net` Let's Encrypt certificate. The proxy sees only a CONNECT.

### 3.3 Authentication design

This is the main thing we add. The flow:

```
first run ──► no token in Keychain
              │
              ├─► user pastes a token URL (from `kirocrew token`) OR
              │   scans the QR from the dashboard's Phone access card
              ▼
        load https://<gateway>/?token=<token> in the WKWebView
              │  (server sets mc_token_<port> + mc_refresh_<port> cookies)
              ▼
        persist: the gateway ORIGIN only (never a URL that could carry
        ?token=, R2); cookies live in the WKWebsiteDataStore.
        The token is stripped from the address at document start (R2).
              │
              ▼
        steady state: the PAGE refreshes (R20) — proactively ~1 h
                      before session_exp, and on any 403 + X-Auth-Required.
                      The app never calls /api/auth/refresh.
              │
              ├─ page refresh 200 ──► keep going (no event, no app action)
              └─ mc-auth-required ──► native token sheet (R21)
```

**Do not build a refresh loop. The page already has one.** This was the single
most useful discovery of the planning phase. The dashboard's own JS client
(`client-oM83i081.js`) implements the whole thing:

- Any API response of **`403` with header `X-Auth-Required: true`** triggers `POST /api/auth/refresh`. Note it is 403, not 401 — the server's `_deny()` always emits that pair (`dashboard/token_auth.py:3097-3111`).
- The refresh call is **single-flight**: the in-flight promise is memoised, so concurrent 403s cause exactly one refresh. This matters because reusing a rotated refresh token outside its grace window revokes the entire chain.
- On `200` it clears the banner; on **`401` it latches a terminal flag** and never retries, drawing the red paste banner instead. Other statuses are treated as transient.

So the app's job is **not** to drive refresh. It is to (a) let the page do its
work, (b) notice the terminal state, and (c) supply a fresh token without making
the user find a computer. Building a second refresh loop natively would race the
page's and risk revoking the chain.

**Hook the events, don't scrape the DOM.** The banner is drawn as imperative DOM
outside React (element id `mc-session-expired`) so it survives a broken app tree,
and it dispatches `mc-auth-required` / `mc-auth-cleared` on `window`. Inject a
content script that forwards both to native via `WKScriptMessageHandler`. That is
the app's authoritative session signal — far better than polling `/api/auth/me`
or reading the DOM.

**~~Nudge on foreground.~~ Dropped (R20).** The server has no WebSocket expiry
watchdog, so an expired session can sit behind a healthy-looking socket — but
the page already covers it: it refreshes proactively ~1 h before `session_exp`,
defers while hidden and fires on `visibilitychange`, retries at 60 s / 4 min /
16 min / 1 h, and a 30 s approvals poll goes through its 403 interceptor. A
native nudge could not have worked anyway: the interceptor wraps only the page's
own API calls, not `window.fetch`, and a native `URLSession` has neither the web
view's cookies nor its proxy. **Only if M6 measurements show a real gap:** run
page-world JS that fetches `/api/auth/me` and calls `location.reload()` on 401
or 403 + `X-Auth-Required`, letting the page's own refresh run. **Never call
`/api/auth/refresh` from the app** — behind `tailscale serve` every client
shares one 60/min rate-limit bucket.

**Token supply, when it does come to that.** The banner accepts either a full URL
or a bare token, extracts `?token=`, and hard-navigates to
`{origin}?token={token}`. The app should present a native sheet at that moment
and perform the same navigation — with R23's safer parsing: a regex over the
paste (CLI output can hold three URLs), always the **selected gateway's**
origin, a pasted host accepted only if it is a known gateway. A token cannot be cached for later reuse: the
link window is 300 s (`LINK_WINDOW_SECS`), so there is no such thing as a stored
spare key. **The 30-day refresh chain is the only durable credential** — which is
exactly why §3.3's "don't race the page's refresh" rule matters.

**A payoff worth configuring.** `dashboard.qr_session_persist_across_restart`
gives 30-day sessions that survive gateway restarts, but it is gated on
`trust_identity` plus a non-empty `allowed_logins`. Olof's iPhone can't satisfy
that today: it is ACL-tagged, so `tailscale whois` reports it as `tagged-devices`
(`dashboard/tailnet.py:864`). **The embedded node is a different node**, created
by an interactive login as `owner@example.com`, so it reports the real
login and passes the allowlist. Enabling this on the gateway is a one-line config
change and removes the "signed out after every gateway restart" annoyance
entirely. Do it in M7 and measure the difference.

**Narrowed (R24):** that annoyance applies to **QR-minted sessions only** — CLI
links already survive restarts (§1.1). So M7.5 is optional, for QR users only,
and has more preconditions than the paragraph above lists (see M7.5).

### 3.4 Discovery design

1. Take the peers from `tsnetModel.localStatus`, which the app already polls through `LocalAPIClient.backendStatus()` — the same data `TailnetProxyPolicy.make(from:)` uses. **(R18:** this step originally said to prefer `TailscaleNode.statusJSON()`. That API and `tailscale_status_json` exist only in libtailscale `main`, which lacks `restartLoopback`; the vendored revision has neither, and the header text quoted here was from `main`.)
2. **(R26)** Filter to candidates: `Online`, not `Expired`, not a `ShareeNode`, `OS` in {linux, macOS, windows}, owned by the same user. The saved gateway is always probed, and first. (`OS`/`UserID` needed a post-import decode in the vendored TailscaleKit.)
3. Probe each over **HTTPS only**, through an ephemeral `URLSession` built from `tsnetModel.proxyConfiguration`: 12 at a time, 1.5 s per request, 5 s for the whole sweep, results streamed to the picker as they arrive.
4. A gateway is a match when `GET /manifest.json` is JSON named `"Kiro Crew"` **and** an unauthenticated `GET /api/auth/me` answers 403 with `X-Auth-Required: true`.
5. If every probe fails with -1000/-1004, report "proxy unhealthy" (not "no gateways") and refresh the node's status.
6. Re-probe on first run, on manual refresh, and from the "gateway unreachable" banner. Persist the chosen gateway.

~~Fallback: also probe `http://<host>:5476`.~~ **Dropped (R26):** chonk's
dashboard listens on 127.0.0.1 only, a plain-http origin fails KiroCrew's
`/api/ws` origin check, and HSTS (`includeSubDomains`) upgrades it after any
https visit anyway. chonk is out of v1 (D4). Manual entry stays, https only.

### 3.5 Lifecycle

Upstream HEAD already replaced lifecycle-driven repair with **failure-driven
recovery**: `TSNetManager.isLocalLoopbackConnectionFailure` (`:355-364`) →
`recoverLoopbackAfterFailure` (`:366-415`), which calls `node.restartLoopback()`,
rebuilds the LocalAPI client and IPN bus, restarts the relay and republishes the
proxy config. `willEnterBackground()` (`:662-664`) is a deliberate no-op.

Keep that design. Our addition is at the **session** layer, not the network layer:
on foreground, re-check `/api/auth/me` and let the page reconnect its WebSocket.
The dashboard's SPA already reconnects (the frontend opens `/api/ws` with a
heartbeat every 30 s), so the app should not fight it; it should only reload the
page if the session itself died.

---

## 4. Repository and project setup

### 4.1 Layout

```
~/src/latchkey/
├── docs/
│   ├── PLAN.md              ← this document
│   └── DECISIONS.md         ← append-only log of decisions made during implementation
├── testing/
│   └── harness/             ← already populated, see §6.3
│       ├── dashboard.py     — fake KiroCrew (HTTPS + WebSocket + SSE)
│       ├── socks5stub.py    — stub SOCKS5 with journal / blackhole modes
│       ├── ca.cnf, leaf.cnf — OpenSSL configs for the test CA
├── app/                     ← the fork of aperture-plus lands here (M0)
└── README.md
```

Keeping the fork in a subdirectory (`app/`) keeps the harness, docs and any
future server-side helpers out of the fork's history. **Revised:** `app/` is its
own git repository, gitignored by the parent — they are two repositories, and a
milestone is committed in each. Neither has a remote; commits are local.

### 4.2 Fork strategy

**Revised (R16, D2).** The original sequence here — clone, rename `origin` to
`upstream`, `git submodule update --init --recursive` — does not work: both
submodules are declared `url = .` and their pinned commits live only as
unreferenced objects inside the aperture-plus repository, so renaming `origin`
broke resolution (M0 worked around it). It was replaced by:

- **libtailscale is vendored as plain source** in `app/ThirdParty/libtailscale/`,
  with the patched tailscale tree at `tailscale-patched/` inside it. The first
  commit is a pristine, import-only copy of `f55900d2` and `b5adfd85`, verified
  blob-for-blob; every Latchkey change to it is a later, separate commit.
  Provenance and diff recipes: `app/ThirdParty/VENDORED.md`.
- **Upstream is tracked by cherry-pick only**, from `TSNet/` and the vendored
  tree — never a merge. After the pbxproj rewrites, the rename and the vendoring
  a merge would be a wall of modify/delete conflicts. The last upstream revision
  reviewed is recorded in `docs/DECISIONS.md`. New code goes in `App/`.
- `git subtrac`, the absolute-URL `.gitmodules` workaround and
  `scripts/bootstrap.sh` are gone; they only existed to serve the submodules.
- Work is committed straight to `main` (no topic branches, no PRs).

**License**: BSD-3-Clause. `LICENSE` is intact and `app/NOTICE` names the origin.

### 4.3 Identity changes

| What | Where | From | To |
|---|---|---|---|
| Development team | `app/Aperture.xcodeproj/project.pbxproj` (10 sites: 446, 488, 525, 542, 562, 600, 666, 731, 759, 777) | `W5364U7YZB` | your personal team |
| Bundle id (app) | same file, 581 / 619 — M0 found **four** sites: the Mac target shared the id | `io.tailscale.Aperture` | `net.lixom.latchkey` |
| Bundle id (UI tests) | same file, 763 / 781 | `io.tailscale.Aperture.UITests` | `net.lixom.latchkey.UITests` |
| Export team | `app/ExportOptions.plist` | `W5364U7YZB` | your personal team |
| Display name | `app/Aperture/Info.plist` | Aperture | Latchkey |

With a free personal team, the reliable install path is Xcode's Run button, not
`make ipa`. Profiles last 7 days; rebuild to renew.

### 4.4 Build prerequisites (already satisfied on `chonk`)

- Xcode 27.0 (27A266a), licensed, `xcode-select` pointed at it. **Note:** upstream requires Xcode 26.x and the iOS 26 SDK; we have 27. See §7.1.
- iOS 27.0 simulator runtime installed, six device types available.
- Go 1.27.1 (upstream asks for 1.26.5; `go.mod` declares `go 1.25.0`).
- Disk: ~85 GB free.

---

## 5. Milestones

### M0 — Bootstrap: fork builds and runs (3–5 h)

**Goal:** an unmodified fork building and launching in the simulator, with the
host-only tests green. This milestone changes no behaviour; it de-risks the
toolchain.

| # | Task | Detail |
|---|---|---|
| 0.1 | Clone and branch | §4.2. Verify `ThirdParty/libtailscale` and its nested `tailscale-patched` submodule are checked out. |
| 0.2 | Build the framework | `cd app && make framework`. Slow the first time (Go builds a fat xcframework). If Go 1.27 rejects the build, install 1.26.5 via `GOTOOLCHAIN=go1.26.5` before reaching for anything heavier. |
| 0.3 | Build the app | `make app` (simulator). Fix Xcode-27 fallout here, not later. |
| 0.4 | Host-only tests | `make test-policy` — runs `scripts/test-proxy-policy.sh` and `scripts/test-hostname-qualifier.sh` via `swiftc`, ~2 s, no simulator or framework needed. |
| 0.5 | Launch in simulator | `xcrun simctl boot "iPhone 17"`, install, launch. It will sit at the connection gate with no tailnet — that is correct. |
| 0.6 | Identity changes | §4.3. Rebuild. |
| 0.7 | Record the baseline | `docs/DECISIONS.md`: upstream SHA, Xcode/Go versions, which upstream tests already fail (see §7.5 — five iOS UI tests are known-flaky upstream). |

**AC:**
- `make framework && make app && make test-policy` all succeed from a clean clone.
- The app launches in the iOS 27 simulator and shows the connection gate without crashing.
- `docs/DECISIONS.md` records the baseline, including any upstream test failures inherited.

---

### M1 — Strip to single purpose (6–10 h)

**Goal:** one window, one WKWebView, one destination. No tabs, no address bar, no
Mac target, no VM code.

Deletions first, then the pin. Keep each in its own commit.

| # | Task | Files |
|---|---|---|
| 1.1 | Remove the Mac app | Delete `MacApp/`, `MacUITests/`, the `ApertureMac` / `ApertureMacUITests` targets (`project.pbxproj:219-267`), `xcshareddata/xcschemes/ApertureMac.xcscheme`, and the Makefile targets `mac-framework`, `mac-app`, `mac-app-signed`, `test-mac`, `build-mac-uitests`, `test-mac-ui`, `tf-mac*`. Nothing in the iOS target references `MacApp/`. |
| 1.2 | Remove virtualization | Delete `Packages/ApertureVM/`, `Tools/aperture-vm-cli/`, `scripts/build-aperture-vm-cli.sh`, the `stage-thunderboot-*` Makefile targets, `README.thunderboot.md`, `TODO.thunderboot.md`, `TODO.vmnet.md`, `MacApp/Thunderboot/`. |
| 1.3 | Remove the VM seam from iOS | Delete `App/Workspace/WorkspaceVMModel.swift`, `App/Workspace/WorkspaceVMProtocol.swift`, `App/Settings/WorkspaceVMSettingsSection.swift`; then fix the referents at `SettingsView.swift:87-90`, `SettingsViewModel.swift:96/103/106`, `WorkspaceManager.swift:43/282`, `WorkspaceStore.swift:213-218`. |
| 1.4 | Remove tabs | `App/Browser/TabbedBrowserView.swift`: drop the `TabOverview` sheet (`:82-87`) and the macOS `TabBar` (`:241-242`). Then delete `TabBar.swift`, `TabOverview.swift`. Collapse `TabManager` to a single tab (`maximumTabCount`, `TabManager.swift:20`) — do not delete `TabManager`; it owns tab persistence the workspace expects. |
| 1.5 | Remove the address bar | `TabbedBrowserView.swift`: remove `browserToolbar` from the VStacks at `:244` and `:264`; the definition is `:356`. Delete `CompactBrowserToolbar.swift`. **Keep** `BrowserNavigator.swift`'s statics `trimmedURLInput` / `normalizedURLString` (still called from `SettingsViewModel.swift:297,300`) or inline them. |
| 1.6 | Remove bookmarks | Delete `App/Bookmarks/Bookmark.swift`, `BookmarkEditor.swift`, `BookmarkList.swift`, `App/Browser/BookmarksSheet.swift`. **Keep** `App/Bookmarks/HomePage.swift` — it holds the start URL. |
| 1.7 | Pin the start URL | `HomePage.swift:25` (`defaultURL`), `WorkspaceStore.swift:81-92` (`makeDefault()`), `TabManager.openChatTab()` (`TabManager.swift:73-79`). Temporarily hardcode `https://byskebox.example.ts.net`; M5 replaces this with the discovered gateway. |
| 1.8 | Remove exit-node UI | `SettingsView.swift` exit-node section and `SettingsViewModel.runExitNodeDiagnostic` (`:203`) / `fetchEgressIP` (`:225`). Exit nodes are broken upstream (§7.4); shipping the toggle would be shipping a known-broken feature. Also drops the upstream-failing `testExitNodeChangesEgressIP`. |
| 1.9 | Keep and re-point diagnostics | Keep `SettingsView.swift` routing section (`:182-232`), `App/Settings/LogViewer.swift`, `TSNet/Logging.swift`, `TSNet/SocksLogProxy.swift`, `App/Tailnet Status/StatusView*.swift` (this is the login UI — not optional). |
| 1.10 | Fix the UI test suite | `UITests/ApertureUITests.swift` is 2,275 lines / 29 tests, many about tabs and bookmarks. Delete the tests for deleted features; keep and re-point the ones about connection, login, home page and keyboard layout. |
| 1.11 | Rename | Target, scheme, display name, `LogRing` subsystem string. Rename `Aperture.xcodeproj` last — it touches the most paths. |

**AC:**
- App launches to the connection gate, then to a single full-screen WKWebView. No tab UI, no address bar anywhere.
- `make test-policy` still green; the trimmed UI suite compiles and runs.
- Building the Mac scheme is impossible because it no longer exists; the iOS build has no references to `ApertureVM`.
- **Device check:** install on the iPhone, sign in with the system Tailscale VPN *off*, and confirm the KiroCrew dashboard renders (the #9399 re-test from §2.4). If it renders blank, stop and fix that in KiroCrew first — it blocks everything downstream.
  **Revised (R8):** device bring-up comes *before* this check, as owner actions O1 → O2 → O3 → install and tailnet login → O3b (node out of purgatory) → O5 (first token, pasted into the dashboard's own red banner). The step-by-step is `docs/DEVICE-CHECK.md`. Test with Local Network permission both allowed and denied, and record the phone's iOS version. "Fix it in KiroCrew first" is not actionable (Olof does not control releases); the #9399 fallbacks are in R35.

---

### M2 — Offline test harness (5–8 h; re-estimated 10–16 h by R36) — **done**

**Status:** done 2026-09-20. `scripts/test-offline.sh` passes 9/9 in ~95 s with no Tailscale account. The table below is the original plan. Revisions R9–R13 and R15 replaced 2.4, 2.6 and 2.8, noted inline. `docs/DECISIONS.md` "M2 done" has the detail.

**Goal:** prove the WebKit-through-SOCKS5 path with **zero Tailscale involvement**,
so every later change has a fast, deterministic regression net. This milestone is
scheduled early on purpose: it is the safety rail for M4 and M6.

See §6 for the full strategy; this is the build-out.

| # | Task | Detail |
|---|---|---|
| 2.1 | Move the harness in | `testing/harness/` already holds `dashboard.py`, `socks5stub.py`, `ca.cnf`, `leaf.cnf`, verified working during planning. Add a `Makefile` with `harness-up` / `harness-down`. |
| 2.2 | Generate test certs | Script `testing/harness/gen-certs.sh` per §6.3. The CA **must** carry `keyUsage=critical,keyCertSign,cRLSign` or iOS rejects it with "CA cert does not include key usage extension". The leaf needs `subjectAltName` (iOS ignores CN) and `extendedKeyUsage=serverAuth`. |
| 2.3 | Trust the CA in the simulator | `xcrun simctl keychain booted add-root-cert testing/harness/ca.der`. Wire this into the test bootstrap so a fresh simulator works unattended. |
| 2.4 | Test-only proxy override | ~~Endpoint-only override, gated on DEBUG.~~ **Replaced (R11, R15):** an endpoint-only override never loads (`loadInitial` needs `.Running` and a peer status), so `-TestStatusFixture <IpnState.Status JSON>` + `-TestProxyEndpoint` + `-TestProxyCredential` start no node and drive the production `proxyConfig` → factory → policy path. Gated on `LATCHKEY_TEST_HOOKS` (Testing configuration), because DEBUG is what Xcode's Run installs on the phone. |
| 2.5 | Happy-path UI test | Launch with the override, load `https://dash.tail-scale.ts.net/` (mapped by the stub to `127.0.0.1:8443`), assert the page renders, the WebSocket echoes, and the SSE stream advances. |
| 2.6 | **Negative test** | ~~Blackhole `dash.tail-scale.ts.net`.~~ **Replaced (R10, R12):** that name is NXDOMAIN, so a leak failed exactly like a proxied load and the test proved nothing. The origin is now `dash.localtest.me` (public, resolves to loopback): a positive control proves a direct load succeeds, then blackhole, stub-gone and stub-gone-with-`-NoSocksLog` must each fail with **zero** requests reaching the dashboard. `allowFailover == false` is asserted on the app's own object by `scripts/test-proxy-config.sh`. |
| 2.7 | Journal assertion | Assert `testing/harness/proxy.ndjson` contains a `connect` event for the dashboard host — proof the traffic actually traversed the proxy rather than reaching it some other way. |
| 2.8 | JS bridge for web assertions | ~~Hidden-view `accessibilityValue` bridge.~~ **Replaced (R13):** hidden views drop out of the accessibility tree and an `evaluateJavaScript` poll fights XCUITest idle detection. The page POSTs its state to `dashboard.py`'s `/__report`; tests read `/__state` (and the stub's `/journal`) over plain HTTP on 127.0.0.1. |
| 2.9 | Script the whole thing | `scripts/test-offline.sh`: certs → harness up → `xcodebuild test -only-testing:...` → harness down, with logs and a screenshot on failure. **Done**, plus R10's preflight and R1's validated token check. **R9:** `xcodebuild test` from the agent shell is proven, so no Terminal fallback is needed. |

**AC:**
- `scripts/test-offline.sh` passes on a machine with **no Tailscale account and no tailnet** — after one `--build`; the < 3 min budget excludes the build (`test-without-building`, R37).
- The blackhole test fails the page load (not the test), proving no direct fallback.
- Total runtime under 3 minutes.

---

### M3 — Fake control plane for tsnet tests (4–6 h; re-estimated 12–20 h by R36)

**Status:** done 2026-09-20. `scripts/test-tailnet.sh` passes 3/3 in ~70 s with no Tailscale account; the harness self-test takes ~10 s. `docs/DECISIONS.md` "R17" and "M3 done" have the detail.

**Goal:** exercise the real tsnet node — login, netmap, loopback, proxy — against a
throwaway control server, still with no real tailnet.

**Revised (R17).** The original tasks linked libtailscale's `tstestcontrol`
c-archive into the iOS test target. That cannot work: `controlhttpserver` is
`//go:build !ios`, so the archive does not build for the simulator; the
`TailscaleKitXCTests` target is macOS-only; and the shim's `RunControl` assigns
a shadowed local `control`, so `stop_control` never stops anything
(`tstestcontrol/tstestcontrol.go:77`; its `fakeTB` calls `log.Fatal` at
`:237-241`). The simulator shares the host's loopback, so the control plane
runs as a **host process** instead.

| # | Task | Detail |
|---|---|---|
| 3.1 | `testing/tsnet-harness/` | A host Go binary built against the app's vendored tailscale (R16): `testcontrol.Server` with `MagicDNSDomain: "tail-scale.ts.net"` and `DNSConfig{Proxied: true}`, DERP/STUN on `127.0.0.1`, and two tsnet peers — `dash` forwards tailnet :443 to `dashboard.py` (TLS by the M2 test-CA leaf, which already names `dash.tail-scale.ts.net`; not R17's wildcard, which would also cover M2's `wrong.tail-scale.ts.net` mismatch fixture) and journals each connection's tailnet source; `plain` serves nothing. Fixed control URL `http://127.0.0.1:8490`; test API on `:8491` (`/state`, `/reset?auth=&machine=`, `/approve?hostname=`). Serves the `/auth/<id>` login page testcontrol lacks. Sets `SetNoLogsNoSupport` like the app (D1). |
| 3.2 | `-TestControlURL` | Launch argument behind `LATCHKEY_TEST_HOOKS` that overrides `WorkspaceDefinition.controlURL` for the launch only (never persisted). Loopback http(s) only; anything else is a crash, never a fall-back to the real control plane. Host-tested (`scripts/test-control-plane.sh`), with and without the hooks compiled in. |
| 3.3 | Join and load | The node reaches `Running`, receives the netmap and MagicDNS config, and the dashboard loads by name through the node's own loopback SOCKS5 — asserted by the `dash` peer journaling a connection from the **app node's** tailnet address. Peers come from `tsnetModel.localStatus` (R18); the load itself proves the proxy policy covered the MagicDNS name, since the name is NXDOMAIN off the tailnet. |
| 3.4 | Login (`RequireAuth`) | The node stops at `NeedsLogin`; the gate's Login opens the real `ASWebAuthenticationSession` on the harness's login page, which completes the login (`CompleteAuth`). Nothing loads before it. |
| 3.5 | Device approval (`RequireMachineAuth`) | The app handles `NeedsMachineAuth` with its own gate text (no Login button; approval happens in the admin console), and continues by itself after `/approve`. Nothing loads before it. Mid-session handling is R31: **done** — a Login banner on an expired key, an approval banner on a revoked device, both L2-tested. |
| 3.6 | Address overlap | Verify once that the harness's `100.64.x` addresses do not collide with the host's real tailnet routes. |
| 3.7 | Script | `scripts/test-tailnet.sh [--build]`: preflight, the harness's host-side self-test (`make -C testing/tsnet-harness check`, ~10 s, no simulator), harness up, `TailnetHarnessTests`, teardown. |

**AC:**
- A test joins the app's real tsnet node to a fake control plane and loads the dashboard through the node's proxy — with no Tailscale account.
- Login and device approval are each exercised, and nothing loads before them.
- Both the self-test and the UI suite run from the command line; the UI suite within 5 minutes.

**Note:** HTTPS certs are the one thing testcontrol cannot give us. Tailscale's
own tests mint them through `s.lb.ForTest().ConfigureCerts`, which panics outside
`go test` (`ipn/ipnlocal/fortest.go:26-32`). So the `dash` peer forwards to
`dashboard.py`, which serves the M2 test CA's leaf. That is fine — TLS is
covered by M2.

---

### M4 — KiroCrew session management (8–12 h; re-estimated 14–20 h by R36)

**Status:** done 2026-09-20 against the fake gateway serving the real 0.6.0 bundle: `scripts/test-session.sh` passes 9/9 in ~4 min. The O7 contract run against a real gateway is Olof's (R19). `docs/DECISIONS.md` "R19" and "M4 done" have the detail.

**Goal:** the app holds a durable session, lets the page renew it silently, and asks
for a new token only when renewal truly fails.

**Revised before starting (R19–R25, R38):** tested against KiroCrew's **real**
frontend bundle, never the fake dashboard's own page (testing a page we wrote
would be circular — the refresh logic and `mc-auth-*` events exist only in the
real bundles); no foreground nudge; corrected event semantics; CSS-only banner
hiding; safer token entry; a restart story that matches the real `boot` claim;
acceptance criteria that cannot pass vacuously. The rows below are the revised
tasks.

| # | Task | Detail |
|---|---|---|
| 4.1 | Fake KiroCrew backend (R19) | A fake backend serving the **real** `kiro_crew/static/dist` from the installed venv, with the KiroCrew version and bundle hash **pinned — fail on mismatch**. It emulates real auth: `?token=` redemption; cookies `mc_token_5476` / `mc_refresh_5476` (the listen port, since a serve Host header carries none); a stale session → **403 + `X-Auth-Required: true`**; `GET /api/auth/me`; `POST /api/auth/refresh` with rotation and a grace window; `401 refresh_chain_revoked` clearing the refresh cookie; `--expire-in N`. It tracks refresh-token **lineage** and fails on any superseded token used outside the grace window — sequential reuse, not only overlap (R25). Plus whatever minimal API surface the SPA needs to render and run its scheduler. A **bundle smoke test** fails if `mc-auth-required` / `mc-auth-cleared` or `#mc-session-expired` disappear from the bundle. |
| 4.1b | Contract test, owner-run (R19, §C O7) | `testing/harness/contract_test.py`: replays redeem → expire → 403 + header → rotate → reuse the superseded refresh token (→ 401) against a **real** gateway on byskebox's KiroCrew version, and diffs statuses, headers and cookie attributes against the fake. Token from a file or env var, never an argument; its own fresh session, never the phone's; far below the 60/min refresh limit. The agent cannot run it (it cannot mint tokens, D10). Never use KiroCrew's own test harness (`--test-mode`, `spawn_feature_gateway`, in-process `generate_token`). |
| 4.2 | JS event bridge | Inject a content script that forwards the page's `mc-auth-required` and `mc-auth-cleared` window events to native through a `WKScriptMessageHandler`. This is the session signal; no DOM scraping, no polling. **R3:** register it `forMainFrameOnly: true`, add it through `PageScripts.install`, and act on a message only when `frameInfo.securityOrigin` matches the gateway origin. **R21:** inject at document start so it is re-injected on every navigation — including the `location.assign('/')` the page does on a revoked chain, after which `mc-auth-required` fires. |
| 4.3 | `SessionManager` | New type. Owns the gateway origin and session state (`unauthenticated` / `active` / `needsToken`). **It does not refresh** — the page does (§3.3, R20) — and it persists nothing (R5). **R21 semantics:** `mc-auth-required` → `needsToken`; the stale-owner banner → `needsToken`. `mc-auth-cleared` does **not** mean healthy (it fires when the banner is dismissed, and a silent refresh fires nothing): return to `active` only after a `?token=` navigation completes or a page-world `GET /api/auth/me` returns 200 (R38: assert sign-in by API, never by rendering — the shell returns 200 signed out too). |
| 4.4 | Token entry UI (R23) | A native sheet. **Paste:** extract the first `token=([^&\s]+)` with a regex — CLI output holds up to three URLs, so `new URL(paste)` fails on a multi-line paste; otherwise treat the input as a bare token. Use `PasteButton` / `UIPasteControl`, never a silent clipboard read; after a successful redemption clear the clipboard only if it still holds that exact string (Universal Clipboard syncs it everywhere). **Target:** always the **selected gateway's** origin; accept a pasted host only if it is a known gateway (anti-QR-phishing), and show the target host before navigating. Tokens are signed per gateway. **QR** (D3): `AVCaptureSession` + `NSCameraUsageDescription`; the Phone-access payload `https://<gateway>/?token=…` goes through the same parser and host check. |
| 4.5 | Redemption | Load `https://<gateway>/?token=<token>` once; the server mints cookies. The link is valid **300 s** and is re-redeemable inside that window, so one retry is safe. |
| 4.6 | ~~Keychain~~ | **Dropped (R5).** No redemption marker: the Keychain survives uninstall but cookies do not, so the two desync. Derive session state from the page and `/api/auth/me`. The gateway origin is already persisted in `workspaces.json` (R2). If a Keychain item is ever added, it uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Node keys and WebKit data are excluded from backup at every launch (`BackupExclusion`, R5). |
| 4.7 | ~~Foreground nudge~~ | **Dropped (R20).** It cannot work — the page's 403→refresh interceptor runs only inside its own API wrappers, and a native `URLSession` has neither the cookies nor the proxy — and it is unnecessary (§3.3). |
| 4.8 | Suppress the web banner (R22) | Inject `#mc-session-expired{display:none!important}` at document start — CSS only, which also stops its input autofocusing and popping the keyboard. **Never remove the element and never click its ✕**: a startup gate reads it, and ✕ clears latches. Add a bridge **ready-handshake**; if it does not arrive within N seconds, leave the banner visible as the fallback. |
| 4.9 | Tests | Against the fake backend serving the real bundle: cold redemption; the page self-refreshing across expiries with no native involvement; terminal `401` → native sheet; re-entering a token recovers; **gateway restart, two cases (R24):** a CLI-shaped session survives a boot-id change with no sheet, a boot-claimed (QR) session shows the sheet; network loss → no spurious sheet, recovers on return; **no superseded refresh token used outside the grace window, throughout** (R25). **R38 patterns:** redeem once and reuse the data store's cookies; preset `localStorage` `mc-onboarded=1` to skip the first-run overlay; one cookie store per gateway port; assert sign-in by page-world `/api/auth/me`, never by rendering. Upstream's frontend auth tests (`useRefreshScheduler.ts`, `refreshOnce.ts`, `clientAuthRecovery.test.ts`, `staleOwnerSession.test.ts`) are the spec for the fake, **at the tag matching the installed 0.6.0, not `main`** — where they disagree with the installed bundle, the bundle wins. A WebKit-only failure may be KiroCrew's bug (#9399-style): upstream has no WebKit coverage. |

**AC (R25 — none may pass vacuously):**
- Across several expiries, with **periodic SPA API traffic driven by the test**, the token sheet never shows **and** the fake counts at least a stated minimum of successful rotations. (With the real bundle, `--expire-in 60` refreshes about every 5 s — the scheduler aims for `exp − 1 h`, floored at 5 s — so pick an expiry that yields a countable number.)
- Forcing `refresh_chain_revoked` shows the native token sheet, and re-entering a token recovers without reinstalling the app.
- The fake's lineage check never fires: no superseded refresh token is used outside the grace window, sequentially or concurrently.
- The bundle smoke test passes against the pinned version.

---

### M5 — Gateway discovery (5–8 h)

**Status:** done 2026-09-21 on the L2 harness: `scripts/test-discovery.sh` passes 3/3; first gateway < 0.5 s, sweep ~1.5 s. The real-tailnet check waits for M7. `docs/DECISIONS.md` "M5" has the detail.

**Goal:** find KiroCrew gateways on the tailnet instead of hardcoding a hostname.

| # | Task | Detail |
|---|---|---|
| 5.1 | `GatewayDiscovery` | Peers from `tsnetModel.localStatus` (R18), filtered by R26: online, not expired, not shared in, a server OS, same owner; the saved gateway first. The filter and fingerprint are pure code (`GatewayCandidates`), host-tested. |
| 5.2 | Probe (R26) | HTTPS only, through an ephemeral `URLSession` on the node's proxy configuration; 12 concurrent, 1.5 s per request, 5 s per sweep; streamed. Fingerprint: `manifest.json` named "Kiro Crew" **and** `/api/auth/me` → 403 + `X-Auth-Required`. All probes failing with -1000/-1004 → "proxy unhealthy" + `refreshStatusNow()`. ~~`http://<host>:5476`~~ dropped. |
| 5.3 | Picker UI | Shown instead of the dashboard until a gateway is chosen; results stream in; Refresh; manual entry (a bare name is qualified with the MagicDNS suffix; always https). A single gateway found on the first run is chosen without asking (the "already has a session" condition cannot be known before loading it, and would not change what to load). |
| 5.4 | Wire into the start URL | `HomePage.defaultURL` is empty — no gateway — instead of the M1 hardcoded byskebox. Choosing one sets the home page and reopens the dashboard tab on it. `HomePageAvailability` stays. |
| 5.5 | Re-probe policy | First run, manual refresh, and the "gateway unreachable" banner's Find. Never on every launch. |
| 5.6 | Tests | L2 (`scripts/test-discovery.sh`): the tsnet harness with peers `gw` (the fake KiroCrew gateway), `dash` (a web page, not KiroCrew), `plain` (nothing listening) and `slow` (accepts, never answers). Discovery must find exactly `gw` within the deadline, choose it and load it over the tailnet; manual entry when nothing is found; the choice persists across relaunch. |

**AC (rewritten by R26, measured by app-logged timestamps):**
- On the harness tailnet, discovery finds exactly the one gateway; the first gateway appears within 5 s and the sweep completes within 10 s even with a peer that never answers.
- Manual entry works when discovery finds nothing.
- The selected gateway persists across app restarts.
- **To verify in M7 (R26):** under the purgatory policy (D5) a promoted `kiro-clients` node's netmap should hold only byskebox, chonk and air; a node still in purgatory sees no gateway at all.

---

### M6 — Lifecycle hardening (6–10 h)

**Goal:** survive suspension, resume, and network churn — the failure mode most
likely to make the app feel unreliable in daily use.

| # | Task | Detail |
|---|---|---|
| 6.1 | Inherit, don't rewrite | Upstream's failure-driven recovery (`TSNetManager.swift:355-415`) is the right design and replaced an earlier lifecycle-driven one that had real bugs. Do not reintroduce foreground rebuild logic. |
| 6.2 | ~~Use `statusJSON()` for liveness~~ **Liveness stays on the loopback status poll (R18)** | As written this was inverted: the loopback listener serves both SOCKS5 and LocalAPI, so the loopback poll failing is exactly the signal that the proxy is dead — which is what upstream's `recoverLoopbackAfterFailure` keys on. `statusJSON()` does not exist in the vendored revision anyway. Nothing to build; keep the upstream design (6.1). |
| 6.3 | ~~Session re-check on foreground~~ | **Dropped (R20):** no `SessionManager.refreshIfNeeded()` — the page refreshes itself on `visibilitychange`. Only if M6 measurements show a gap, use the page-world `/api/auth/me` + `location.reload()` fallback in §3.3. |
| 6.4 | WebSocket reconnect | **Write no app-side reconnect logic.** (One exception now exists, R7: if the *web content process* dies — routine under memory pressure — the app reloads the page, at most 2× per 60 s, deferred to foreground if it died in the background. The page's own reconnect cannot help when its JavaScript is gone.) The page already reconnects with exponential backoff (1 s, doubling, capped at 10 s; reset to 1 s on open) and on reconnect does a full refetch plus re-subscribe, because the protocol has no sequence numbers or cursor-based replay — anything missed while disconnected is recovered by HTTP, not by the socket. The foreground nudge (M4.7) was dropped by R20; the app has no job here. Measure reconnect time after resume; intervene only if it is bad. |
| 6.5 | Simulated suspend test | `XCUIDevice.shared.press(.home)` then `app.activate()`, then assert a page load still works. **`xcrun simctl` has no `suspend` subcommand** (verified) — there is no CLI path. **Corrected (R14):** there is a CLI path — upstream's `app/scripts/test-lock-resume.sh` freezes the app with SIGSTOP. Use it. |
| 6.6 | Real-device suspend test | The simulator keeps processes far more alive than a real device; genuine listener reclamation and jetsam kills are **device-only**. Write a manual test script: background for 1 min / 10 min / 1 h / overnight, foreground, and record time-to-interactive each time. A debugger prevents suspension entirely, so run it untethered and read logs afterwards. |
| 6.7 | Network churn | Kill the stub proxy or run it `--blackhole` mid-session. `simctl status_bar` is **cosmetic only** and cannot simulate network loss (verified). Assert the app shows a real error and recovers when the proxy returns. **Revised (R14):** a dead stub never triggers `recoverLoopbackAfterFailure`, which is driven by LocalAPI poll failures — test recovery at L2 with `-UITestDefunctLoopback` / `-UITestShutdownTCPConnections`. The stub's control port (`/mode?blackhole=1`, `/close`, `/open`) serves the page-level error/recovery half. |
| 6.8 | Known upstream flake | Five upstream iOS UI tests flake at ~66–68 s against a 60 s page-load timeout on a cold node, because the initial navigation waits on netmap peer data while `watch-ipn-bus` times out. The code involved is `BrowserViewModel.loadInitial` (`:277-312`) and `TailnetProxyPolicy.hasPeerData`. Decide deliberately: raise the timeout, or gate the first load on peer data. Record the decision. |

**AC:**
- After a 10-minute background on a real device, foregrounding reaches an interactive dashboard in under 5 seconds with no manual intervention.
- Mid-session proxy loss shows a clear error and self-recovers.
- The overnight test is documented with real measured numbers in `docs/DECISIONS.md`.

---

### M7 — Real tailnet bring-up (3–5 h)

**Goal:** the app working on Olof's actual phone and tailnet, daily-driver ready.

| # | Task | Detail |
|---|---|---|
| 7.1 | Device registration | Plug the iPhone into `chonk`, Xcode → Devices and Simulators, enable Developer Mode on the phone (Settings → Privacy & Security). |
| 7.2 | Install | Xcode Run with the free personal team. Trust the profile under General → VPN & Device Management. |
| 7.3 | Node login | Interactive login through `ASWebAuthenticationSession` (`TSNet/AuthManager.swift:16-44`). The new node appears in the tailnet under `owner@example.com`, **not** tagged. Confirm in the Tailscale admin console. **R6:** it is already named `latchkey-iphone` by `WorkspaceDefinition.makeDefault()` — renaming it after the first dashboard sign-in would sign the app out, since KiroCrew pins sessions to `login|node name`. **R8:** this login now happens during the M1 device check, not here. |
| 7.4 | System VPN off | Turn the Tailscale app's VPN off and confirm the dashboard still loads. This is the headline feature — verify it explicitly. |
| 7.5 | Durable QR sessions — **optional, QR users only (R24)** | CLI-link sessions already survive restarts, so this matters only if QR sign-in is used. `dashboard.qr_session_persist_across_restart` needs **all of:** `trust_identity` on with a non-empty `allowed_logins` (including `owner@example.com`), `qr_session_until_restart` still true, **and** the QR generated from an unbounded desktop session. Keep `pin_scope: node`, and name the node first (R6). Depends on §C O4; needs Olof's consent (§C O6) and a rollback note. |
| 7.6 | Discovery on the real tailnet | Confirm discovery finds `byskebox` (443 via serve) and nothing else, within R26's budget. ~~`chonk`~~: out of v1 (D4, R26) — its dashboard listens on loopback only. Gateway switching itself was built in M5 (Settings → Gateway, Find gateways…, the unreachable banner's Find; L2-tested), which R32 confirmed. |
| 7.7 | Weekly re-sign | Document the 7-day rebuild ritual in `README.md`. If it grates, the $99 program makes profiles last a year. |

**AC:**
- App reaches a live session with the system VPN off, on cellular as well as Wi-Fi.
- Survives a gateway restart without a token re-entry — for CLI-link sessions always; for QR sessions only if 7.5 is enabled.
- byskebox is discovered on the real tailnet within R26's budget.

---

### M8 — Polish (3–6 h)

| # | Task |
|---|---|
| 8.1 | App icon and launch screen. **Done:** an original icon (`app/scripts/render-app-icon.swift`); the launch screen is the generated system background. |
| 8.2 | Diagnostics screen: node state, selected gateway, session expiry, proxy endpoint, last error — everything needed to debug a failure without a Mac. **Done early (R29):** Settings → Status, which also shows the node key and provisioning-profile expiry (R31, R33). |
| 8.3 | Surface tsnet's own logs. Upstream writes Go/tsnet detail to `Logs/tsnet.log`, **not** to `LogRing`/`os_log`, so Settings → Logs currently hides magicsock/DERP/loopback failures. Pipe them in. **Local only (R1/D1):** nothing is uploaded to Tailscale's log service — upload is disabled inside the vendored libtailscale — and every line is redacted (`URL.redactedForLog`, `LogRedaction.scrub`). Revision R29 moves this before M6's device tests. **Done (R29):** upstream actually discarded these lines (the drain goes to the no-op transport). The vendored library now keeps a local, capped `tsnet.log` (plus `stderr.log` for a Go panic), shown in Settings → Node log. |
| 8.4 | `README.md`: build, install, re-sign, test, troubleshoot. **Done.** |
| 8.5 | Clean up upstream oddity: `Aperture/Info.plist:11-28` has a malformed nested `NSAllowsArbitraryLoadsInWebContentUsageDescription` dict. **Done by R28.** |
| 8.6 | Decide whether to keep `NSAllowsArbitraryLoads`. We only ever load one HTTPS origin with a real cert; tightening ATS is easy hardening. **Done by R28:** ATS on, no exceptions. |

---

## 6. Test strategy

### 6.1 The constraint

The app's whole job is to reach a private tailnet, so the obvious test needs
Olof's Tailscale account, his gateways and his phone. That does not scale to CI,
it cannot run on a contributor's machine, and it makes every test depend on a
network that might be down for unrelated reasons. So the strategy is to push as
much coverage as possible *down* to layers that need no tailnet at all.

### 6.2 Five layers

| Layer | What it covers | Needs | Speed |
|---|---|---|---|
| **L0** Host unit tests | Pure logic: split-tunnel policy, hostname qualification, URL parsing, session state machine, `allowFailover == false` | `swiftc`, nothing else | ~2 s |
| **L1** Offline harness (M2) | WKWebView ↔ SOCKS5 ↔ HTTPS ↔ WebSocket ↔ SSE; the anti-leak negative test | Simulator + two Python processes | <3 min |
| **L2** Fake control plane (M3) | Real tsnet node: login, device approval, netmap, loopback, proxy, MagicDNS names | Simulator + the host-side `testing/tsnet-harness` (R17) | <5 min |
| **L3** Headscale (optional) | Persistent identity, ACLs/tags, a second device | Docker | minutes |
| **L4** Real tailnet + device | Suspension, jetsam, cellular, real certs, real dashboard | Olof's phone | manual |

**The rule: a bug found at L4 gets a regression test at the lowest layer that can
express it.** L4 is for discovering problems, never for guarding against them.

### 6.3 The offline harness (already built and verified)

Living in `testing/harness/`, verified working during planning:

- **`socks5stub.py`** (96 lines, stdlib only) — SOCKS5 with RFC1929 user/pass auth and CONNECT. Three test affordances: `--journal FILE` writes one JSON line per event so a test can *prove* traffic traversed the proxy; `--map dash.tail-scale.ts.net:443=127.0.0.1:8443` stands in for MagicDNS; `--blackhole` authenticates then refuses every CONNECT, which is the negative fixture.
- **`dashboard.py`** (91 lines, stdlib only) — HTTPS server with `GET /` (a page that opens a WebSocket and an EventSource, writing state into stable element ids), `GET /healthz`, `GET /events` (SSE ticks), `GET /ws` (RFC6455 echo). M4 extends it with KiroCrew's auth semantics.
- **`ca.cnf` / `leaf.cnf`** — OpenSSL configs that produce a CA iOS will actually accept.

Verified behaviours from the planning run: HTTPS GET through the proxy succeeds
and is journaled; SSE streams; a WebSocket completes `101 Switching Protocols`
and echoes through TLS through SOCKS5; a wrong proxy password is rejected;
`--blackhole` fails the connection **with no direct fallback**; and killing the
proxy fails the connection outright.

### 6.4 Things worth knowing before writing tests

- **The CA must carry `keyUsage=critical,keyCertSign,cRLSign`.** Without it iOS fails with "CA cert does not include key usage extension". The leaf needs `subjectAltName` (CN is ignored) and `extendedKeyUsage=serverAuth`.
- **Trust it with** `xcrun simctl keychain booted add-root-cert <path>` (verified syntax; PEM or DER).
- **`xcresulttool get object` is deprecated** in Xcode 27 and now requires `--legacy`; every old recipe from the internet needs that flag. Use `xcrun xcresulttool get test-results summary|tests|test-details --path X`. Note the deprecation text points at `get test-report`, **which does not exist**. `xcresulttool export attachments --only-failures` pulls out failure screenshots.
- **`-resultBundlePath` errors out if the path already exists.** `rm -rf` it first in any script.
- **Useful `xcodebuild test` flags** (all verified present in Xcode 27): `-only-testing:`, `-parallel-testing-enabled NO`, `-test-timeouts-enabled YES`, `-default-test-execution-time-allowance 120`, `-maximum-test-execution-time-allowance 300`, `-retry-tests-on-failure`, `-collect-test-diagnostics on-failure`, `-destination-timeout 60`. New in 27: `-only-testing @file.txt` response files, handy for sharding.
- **`timeout` is not a stock macOS command.** It resolves to Homebrew coreutils' `gtimeout` here. Don't assume it exists in CI.
- **`xcrun simctl bootstatus <device> -b`** is the correct boot barrier (boots if needed, blocks until ready). It is hidden from the top-level help. Never `sleep`.
- **XCUITest now lives in `XCUIAutomation.framework`**, split out of XCTest in Xcode 16.3. `XCTAttachment`, `XCTContext` and `XCTestCase` stayed in XCTest. Old doc URLs redirect.
- **Attachment lifetime defaults to `deleteOnSuccess`** — set `.keepAlways` on failure screenshots or they vanish.
- **`camera` is not a valid `simctl privacy` service** in Xcode 27; `simctl device_appearance` does not exist (use `simctl ui <device> appearance`).
- **The CoreSimulator XPC service outlives runs** and is how the simulator wedges. Recovery: `simctl shutdown all` then `killall -9 com.apple.CoreSimulator.CoreSimulatorService Simulator SimulatorTrampoline`.
- **`simctl status_bar` is cosmetic.** It changes the rendered status bar, not the network stack. To simulate network loss, kill or blackhole the stub proxy.
- **There is no `simctl suspend`.** Background/foreground only from inside XCUITest.
- **The simulator does not reproduce real suspension.** Listener reclamation, jetsam and true suspended state are device-only. Section M6.6 exists because of this.
- **Web content assertions**: the accessibility tree is flaky for dynamic content. Observe server-side instead (R13): the page reports to the harness, and the tests read the harness's control ports.

### 6.5 CI

There is no CI today and none is required for v1, but keep every layer
script-invocable so it can be added later:

```bash
make -C app test-policy    # L0, a few seconds, no simulator
scripts/test-offline.sh    # L1, <3 min, no tailnet
scripts/test-tailnet.sh    # L2, <5 min, no tailnet
scripts/test-session.sh    # M4: the real KiroCrew bundle against the fake gateway
```

Wrap simulator runs in a hard `timeout`; on failure, capture a screenshot and
`xcrun simctl spawn booted log collect`, then `xcrun simctl shutdown all` and
`killall -9 com.apple.CoreSimulator.CoreSimulatorService`.

---

## 7. Risks

### 7.1 Xcode 27 vs the required 26 — *resolved in M0*
**Resolved:** framework and app build on Xcode 27 / Go 1.27.1 with no side-by-side install (DECISIONS, M0 baseline). Original text kept for context:
Upstream mandates iOS/macOS 26.0 SDKs and Xcode 26.x; `chonk` has Xcode 27 with
the iOS 27 SDK. A newer SDK with an unchanged deployment target normally builds
fine, and `SWIFT_VERSION = 6.0` with strict concurrency is unchanged in 27.
**Mitigation:** M0 surfaces this within the first hour. If it breaks, install
Xcode 26.x side by side with `xcodes` and set `DEVELOPER_DIR`. Note that
`DEVELOPER_DIR` does not appear anywhere in upstream's Makefile — you would add it.

### 7.2 libtailscale instability — *medium, ongoing*
**Revised (R16):** the pin is now vendored source rather than a submodule SHA; changes arrive only by deliberate cherry-pick.
No releases or tags ever, issues disabled, and a Tailscale maintainer describing
iOS support as "a work-in-progress and it can be tricky to get (and keep)
everything working reliably". **Mitigation:** we consume it through upstream's
vendored, patched submodule rather than tracking libtailscale `main`. Pin the
submodule SHA and move deliberately.

### 7.3 WebSockets through `proxyConfigurations` — *low, verify in M2*
WebKit's source routes `createWebSocketTask` onto the same proxied session, and
the planning run proved a WebSocket completing through the stub SOCKS5 proxy at
the curl level. What is **not** yet verified is a WKWebView WebSocket surviving a
`matchDomains` republication. M2.5 tests the first; M6.4 tests the second.
**Resolved differently (R27):** the published rules no longer change when peers do (`StableProxyPolicy`: the tailnet ranges plus the MagicDNS suffix), so there is no republication under a live WebSocket to survive.

### 7.4 Exit nodes are broken upstream — *accepted, not mitigated*
`README.tsnet-exit-nodes-dont-work.md` documents the cause: `Dialer.UserDial`
takes a plain `net.Dialer` branch for Tailscale routes, which under tsnet (no TUN)
is a direct dial bypassing WireGuard. Affects subnet routers too. **We remove the
feature (M1.8) rather than ship it broken.**

### 7.5 Inherited flaky tests — *low*
Upstream's own `TODO.failing-tests.md` records iOS 23/29 and macOS 2/3 passing.
Five iOS failures are the cold-node 60 s timeout (M6.8); one is the exit-node bug
(removed by M1.8); one is macOS-only (removed by M1.1). Deleting the Mac target
and exit nodes clears most of it. **Record the inherited baseline in M0.7** so we
never confuse an upstream flake for our own regression.

### 7.6 KiroCrew #9399 — *low but blocking if it bites*
If the dashboard renders blank in WKWebView on the real device, this project
stalls until KiroCrew is fixed. The planning run rendered it fine in the iOS 27
simulator, and the issue reporter has published a two-layer fix. **M1's device
check is the gate**; do not build further until it passes.

### 7.7 Free-signing friction — *low, known*
Seven-day profile expiry, three apps per device. If weekly rebuilds grate, $99
fixes it. No architectural impact.

- **The app warns 48 h before the profile expires** (R33), on the dashboard
  and in Settings → Status. It reads `embedded.mobileprovision`. Otherwise
  the app simply stops launching.
- **Moving to a paid team changes the Team ID** (R33). A different Team ID
  is a different app to iOS: the old one must be deleted and the new one
  installed. That takes the app's data with it: the node key (a new
  Tailscale node appears; remove the old one in the admin console, and move
  the new one out of purgatory, O3b) and the dashboard session (mint a new
  token). Plan the switch for a moment when both are convenient.

---

## 8. Open questions

Each is answerable in minutes during the milestone that needs it; none changes
the architecture.

1. ~~What exactly does `kirocrew token` print?~~ **Resolved (R37):** up to three URLs — localhost, `dashboard.url` and the tailnet name — so the token sheet extracts the first `token=` with a regex (R23, M4.4).
2. **What argv does `kirocrew tailnet up` pass to `tailscale serve`?** Affects whether a gateway sits on 443 or behind a path prefix. *Needed by M5.2.* Read `dashboard/tailnet_serve.py`.
3. ~~What is `<port>` in the cookie name behind `tailscale serve`?~~ **Resolved (R37):** the Host header's port, else the listen port — `mc_token_5476` / `mc_refresh_5476` behind serve. The fake gateway emulates exactly that (`--cookie-port`).
4. ~~Does suppressing the page's own banner have side effects?~~ **Resolved by R22:** CSS only — the element stays (a startup gate reads it; ✕ clears latches), the events still fire, so the header pill still updates.

**Resolved during planning** (recorded so nobody re-investigates):

- ~~Does the gateway close an expired WebSocket?~~ **No.** There is no session-expiry watchdog on `/api/ws`. The only coded close is `POLICY_VIOLATION "app disabled"` at connect time (`dashboard/ws.py:597`); scope revocation narrows a live socket rather than closing it. Expiry is discovered only on the next HTTP request. Hence M4.7.
- ~~Is Web Push wired up in 0.6.0?~~ **No.** Zero hits for VAPID, `PushManager`, `PushSubscription` or a subscribe endpoint across the entire package and the JS bundles; `sw.js` has no `push` or `notificationclick` listener. `POST /api/notifications/push` is an app-token **bus producer**, unrelated to Web Push. In-page `new Notification(...)` only works with the tab open. Notifications therefore require [PR #7821](https://github.com/kirodotdev/KiroCrew/pull/7821) or a native APNs path — see §9.
- ~~Should the app drive `/api/auth/refresh`?~~ **No.** The page already does, single-flight, on 403 + `X-Auth-Required`. Duplicating it risks revoking the chain. See §3.3.

---

## 9. Possible follow-ups (explicitly out of v1 scope)

- **Push notifications.** The reason the phone still feels passive, and now confirmed as genuinely absent: 0.6.0 has no Web Push at all, and its in-page `Notification` call only fires with the tab open. Two routes — land KiroCrew [PR #7821](https://github.com/kirodotdev/KiroCrew/pull/7821), or have the app hold a background connection and raise local notifications itself. The second is the one a native app can do and a PWA cannot, but iOS will not keep a socket alive indefinitely, so it needs a real design rather than optimism.
- **Claude app Remote Control.** A different route to the original goal: [claude-agent-acp PR #735](https://github.com/agentclientprotocol/claude-agent-acp/pull/735) adds `/remote-control` over ACP, which would surface KiroCrew sessions in the Claude iPhone app. Open since 2026-06-01 with merge conflicts. Complementary, not competing. **If it merges, re-evaluate what is left of M5–M8 before building it (R34)**; notifications stay out of v1 either way, with no deep-link interim.
- **Share sheet / Shortcuts.** "Send this URL to Kiro" as a native share target.
- **Multiple gateways side by side.** Upstream's workspace model already supports several identities; we collapse it to one. It could come back.
- **Upstreaming.** The split-tunnel and lifecycle fixes stay compatible; if we fix something real in the shared layer, send it to aperture-plus.

---

## 10. Appendix A — Upstream file map

Paths relative to `app/` after the M0 clone.

**Keep and modify**
```
App/ApertureApp.swift               @main, scenePhase fan-out (:44, :53, :67, :69)
App/Browser/TabbedBrowserView.swift root window; strip toolbar (:244, :264, :356)
App/Browser/BrowserViewModel.swift  owns the WKWebView (:115-155), proxy attach (:88-95, :272-275)
App/Browser/BrowserView.swift       web view host + error page
App/Browser/RawWebView.swift        UIViewRepresentable wrapper
App/Browser/ConnectionGateView.swift pre-connect screen
App/Browser/HomePageAvailability.swift is the home host in this tailnet?
App/Browser/TailnetHostnameQualifier.swift short name → FQDN (host-testable)
App/Bookmarks/HomePage.swift        start URL lives at :25
App/Settings/SettingsView.swift     keep routing diagnostics (:182-232)
App/Settings/LogViewer.swift        on-device log viewer
App/Tailnet Status/StatusView*.swift login state machine — not optional
App/Workspace/*.swift               workspace/identity/storage
TSNet/TSNetManager.swift            node, loopback, proxy, recovery (738 lines)
TSNet/TailnetProxyPolicy.swift      split tunnel; read :11-82 first
TSNet/SocksLogProxy.swift           logging relay (diagnostics)
TSNet/AuthManager.swift             ASWebAuthenticationSession login
TSNet/Logging.swift                 LogRing
```

**Delete (M1)**
```
MacApp/ MacUITests/ Packages/ApertureVM/ Tools/aperture-vm-cli/
App/Browser/TabBar.swift TabOverview.swift CompactBrowserToolbar.swift BookmarksSheet.swift
App/Bookmarks/Bookmark.swift BookmarkEditor.swift BookmarkList.swift
App/Workspace/WorkspaceVMModel.swift WorkspaceVMProtocol.swift
App/Settings/WorkspaceVMSettingsSection.swift
App/TimingHarness.swift             (optional; a useful latency harness if you want it)
```

**Gotcha:** a new file added under `TSNet/` must be listed in the target's
`membershipExceptions` in `project.pbxproj` or it silently is not compiled.
Files under `App/` and `UITests/` use synchronized folder groups and need no
pbxproj edit.

## 11. Appendix B — KiroCrew endpoint reference

All verified in `kiro_crew` 0.6.0 source. Paths are relative to the gateway origin.

| Endpoint | Auth | Purpose |
|---|---|---|
| `?token=<token>` on **any** request | the token itself | Redeems a link: the response the route would give anyway (`/` → the shell, 200, **no redirect**) carries the session and refresh cookies. Link window 300 s, re-redeemable inside it; each redemption starts a **new** refresh chain. A restart forgets unredeemed links. A bad token with a valid access cookie is ignored silently; without one, shell paths get the shell and `/api/*` a 403 (`token_auth.py:2603-3061`) |
| `GET /api/auth/me` | cookie | `{"user_id","session_exp","refresh_exp"}`. **Stale or missing access cookie: `403 {"error": …, "code":"forbidden"}` + `X-Auth-Required: true`** — not 401; the handler's `401 unauthenticated` is unreachable behind the middleware (R37) |
| `POST /api/auth/refresh` | refresh cookie | `200 {"refreshed_at","session_exp","refresh_exp"}` + rotated cookies (access re-minted at a flat 20 h). `401 no_refresh_cookie`; `401 invalid_refresh` (also a `boot` mismatch; **no** cookie clear); `401 refresh_chain_revoked` (**clears** the refresh cookie). A superseded token is forgiven only as the chain head, from the same remote, within 60 s (same tokens re-served); any other reuse revokes the chain. `429 {"error":"rate_limited"}` + `Retry-After: 60`: 60/min keyed on `request.remote`, so **behind `tailscale serve` every client shares one bucket**. A foreign Origin gets the CSRF middleware's **text/plain 403** first — the handler's `403 bad_origin` is effectively unreachable (`auth_refresh.py:398-678`) |
| `POST /api/auth/logout` | cookie | Ends the session (nonce denylist) |
| `POST /api/tailnet/mobile/qr` | cookie | `{"url","image","ttl_secs","link_window_secs","host"}`. The 1 h default (max 12 h) is the **access-token** TTL; with `qr_session_until_restart` (default true) the session carries a `boot` claim and **lasts until the gateway restarts** — the only mint path that sets `boot` (R24, R37) |
| `POST /api/auth/mobile-link` | cookie | `{"url","expires_in"}` |
| `GET /manifest.json` | **none** | Discovery probe: `{"name":"Kiro Crew",…}` |
| `GET /api/health` | **none** | `{"ok":true}` only, through `tailscale serve` — deliberately no version |
| `GET /api/ws` | cookie or `?token=` | The main channel. Auth resolves **once at upgrade** and is never re-checked; the server never closes the socket on session expiry. Heartbeat 30 s. Client reconnects with 1 s→10 s backoff and recovers missed state by HTTP refetch — there is no replay cursor |
| `POST /api/notifications/push` | **app token only** | A notification-bus producer, **not** Web Push. 0.6.0 has no VAPID, no `PushManager`, no subscribe endpoint |

**Cookies:** `mc_token_<port>` (HttpOnly, SameSite=Lax, path `/`, Max-Age ≤ 20 h) and `mc_refresh_<port>` (HttpOnly, SameSite=Lax, path `/api/auth`, ~30 d, **sliding**: each rotation issues a fresh 30 days). `Secure` when the request is HTTPS, or `X-Forwarded-Proto: https` from a loopback peer. `<port>` is the Host header's port, falling back to the **listen** port when the Host carries none — so behind `tailscale serve` the names are **`mc_token_5476` / `mc_refresh_5476`** (`token_auth.py:1353-1369`; resolves open question 3).

**Session killers:** revocation generation bump; a boot-id change at gateway restart — **for boot-bound (QR) sessions only**; CLI links (`kirocrew token` → `/api/token/local`) carry no `boot` claim and survive restarts (R24); `session_exp` (recoverable by refresh); explicit logout. A revoked refresh chain does not revoke the live access session.

**Every middleware denial** is 403 + `X-Auth-Required: true` (JSON on `/api/*`; the shell on GET of other paths). **Not** carrying the header: the Host-allowlist and CSRF 403s (text/plain), the refresh/logout 401s, and handler-level permission 403s.

**CSP:** `frame-ancestors 'self'`; `connect-src 'self'` plus loopback; no CORS on `/api`; no user-agent sniffing. The page fetches fonts and CDN scripts from the public internet — with a split tunnel those go direct, which is correct, but a tailnet-only device would render in fallback fonts.

## 12. Appendix C — Command cheat sheet

```bash
# Build
cd ~/src/latchkey/app
make framework                      # TailscaleKit.xcframework (needs Go; slow first time)
make app                            # simulator build
make test-policy                    # host-only unit tests, ~2 s

# Simulator
xcrun simctl boot "iPhone 17"
xcrun simctl keychain booted add-root-cert ../testing/harness/ca.der
xcrun simctl io booted screenshot /tmp/shot.png
xcrun simctl spawn booted log stream --level debug --predicate 'subsystem CONTAINS "latchkey"'

# Tests
xcodebuild test -scheme Latchkey \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' \
  -resultBundlePath /tmp/out.xcresult -only-testing:LatchkeyUITests/ProxyTests \
  -parallel-testing-enabled NO -test-timeouts-enabled YES
xcrun xcresulttool get test-results summary --path /tmp/out.xcresult --format json

# Harness
make -C testing/harness harness-up      # dashboard.py + socks5stub.py (journal: testing/harness/.run/proxy.ndjson)
make -C testing/harness gateway-up      # fake_gateway.py: the real KiroCrew bundle (M4)
make -C testing/tsnet-harness up        # the L2 fake control plane (M3)
```

**Total estimated effort: 43–70 focused hours across M0–M8. Re-estimated by R36: M2 10–16 h, M3 12–20 h, M4 14–20 h, total ≈ 75–110 h.** Actuals per milestone are recorded in `docs/DECISIONS.md`. M0–M2 (14–23 h) is
the point at which the riskiest unknowns are resolved and there is a working
test net; if the project is going to fail, it fails there, cheaply.
