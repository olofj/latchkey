# F4 — Never a bare screen: connecting, scanning and empty states

| | |
|---|---|
| **Status** | **spec — design pass 2026-09-23: every root-view state enumerated from the code, the blank screen's code path identified; amended the same day with a second, faster path to the same screen (D10: a 5xx committed as the document) and the response rule that closes it (§4.13); ready to build** |
| **Requested** | 2026-09-23, by Olof: "I entered byskebox manually, screen went blank. Not a great UI experience if it's stuck loading something." On discovery: "Is it giving up too quickly?" and "Did a couple more 'Search again' and nothing showed up." Later the same day: "The UI has some blank screens where you don't know what's going on, such as when there's no gateway available and all you have is the gear in the top right. That should be improved." and "Make sure the UI indicates the scan is going on." |
| **Revision** | one rule: a main-frame HTTP **5xx is refused** and shown as a failure instead of committing as the document (§4.13); every 2xx/3xx/4xx commits exactly as today, including KiroCrew's own `403` + `X-Auth-Required`. The retry policy (20 s, 1 s cadence), the `about:blank` fallback (R3), the discovery timeouts (R39) and the SOCKS dial timeout are all unchanged; this makes them visible. One label is corrected (a SOCKS failure is not a "URL format error"), which is a fix, not a policy change, and landed as its own commit ahead of this feature (`8b0933d`, §4.3). |
| **Supersedes** | F2 (the connecting state). F2's four tests are carried over as tests 1, 3 and 12 below; its identifier `page-loading` is **not** used — `page-connecting` is. |
| **Touches** | `App/Browser` (`BrowserView`, `BrowserViewModel`, `DashboardRootView`, `NavigationPolicy.swift` gains a `ResponsePolicy`, new `PageState.swift`, `PageFailureText.swift`), `App/Discovery` (`GatewayDiscovery`, `GatewayPickerView`), `App/Tailnet Status/StatusView`, `TSNet/TSNetModel` + `TSNet/SocksLogProxy` (one published field, existing files), `testing/harness/socks5stub.py` (a stall mode), `testing/harness/fake_gateway.py` and `testing/harness/dashboard.py` (a 502 front and a 403 document mode, §6), the L1 offline, L2 discovery and session suites, two host tests |

**The rule this feature asserts:** there is never a screen that tells the owner
nothing. Every state — starting, connecting, holding, scanning, empty, failed,
gateway answered but not with a page, no gateway, gateway missing, node not
ready — says **what is happening, how long it has been happening, and what to
do next.**

## 1. Why: the device pain, and what actually produced it

### 1.1 The blank screen, traced

Olof typed `byskebox` and the screen went blank. The path, from the code:

1. **Manual entry.** `GatewayPickerView.useManual` (`App/Discovery/GatewayPickerView.swift:159-170`)
   qualifies the name, checks the proxy policy carries it, and calls
   `onSelect(origin)` → `Workspace.selectGateway` (`App/Workspace/Workspace.swift:159-165`):
   `setHomePage(origin)`, `session.reset()`, `tabManager.reopenHomeTab()`.
   Settings → Gateway reaches the same function through
   `SettingsViewModel.commitGateway` (`App/Settings/SettingsViewModel.swift:127-138`),
   so it does not matter which field he used: both end here.
2. **The picker is replaced by the web view.** `reopenHomeTab`
   (`App/Browser/TabManager.swift:138-143`) makes a fresh `BrowserTab`;
   `homePage.hasGateway` flips true, so `DashboardContent`
   (`App/Browser/DashboardRootView.swift:190-196`) swaps the full-screen
   picker for `NavigationStack { gatewayContent }`, whose body is
   `BrowserView` (`:352`). `BrowserView` (`App/Browser/BrowserView.swift:17-42`)
   has two branches: `navError != nil` → `NavErrorPage`; otherwise
   `RawWebView`. `navError` is nil, so a `WKWebView` is installed.
3. **The load starts.** `RawWebView.makeUIView` → `BrowserViewModel.makeWebView`
   (`App/Browser/BrowserViewModel.swift:148-188`) → `loadInitial` (`:269-304`).
   `HomePageAvailabilityChecker.check` found byskebox among the peers (it
   was: the node log shows a dial *to* it, and MagicDNS only resolves peers
   in the netmap), so the decision was `.load(url)`, then
   `load(url:isAutomaticStartupLoad: true)` (`:337-359`) armed
   `startupLoad = (target, now + 20 s)` (`:349`) and `loadResolved`
   (`:361-373`) called `webView.load(URLRequest(url:, timeoutInterval: 120))`.
4. **What was on screen.** A `WKWebView` with nothing committed paints its
   backing colour — white in light mode, black in dark
   (`App/Browser/RawWebView.swift:35-41`) — and over it the gear at 0.45
   opacity (`DashboardRootView.swift:317-331`). No text, no indicator.
   `isLoading` was true on the model (`BrowserViewModel.swift:37`, KVO at
   `:233`) and nothing reads it.
5. **Where the 30 seconds went.** WebKit's CONNECT reached the app's relay
   (`TSNet/SocksLogProxy.swift`) and then tsnet's SOCKS5 server, whose
   `handleTCP` (`ThirdParty/libtailscale/tailscale-patched/net/socks5/socks5.go:218-234`)
   dials with `dialTimeout = 30 * time.Second` (`socks5.go:99`). The phone's
   packet filter had no outbound grant (DECISIONS, "O4 answered": grant 1 of
   D5 was the only rule), so every SYN was dropped and the dial ended at the
   deadline — the node-log line F2 quoted:
   ```
   socks5: dial tcp byskebox…:443 failed: context deadline exceeded
   ```
   `replyCodeForDialError` (`socks5.go:687-697`) maps a deadline to
   `generalFailure` (0x01), and the relay logged it as
   `socks[N] FAILED byskebox…:443 — tailnet proxy could not connect: general failure (reply 1, ~30000ms)`
   (`SocksLogProxy.swift:629`).
6. **The failure reaches the app.** WebKit maps every SOCKS failure reply to
   `NSURLErrorBadURL` (-1000) — the code says so itself (`BrowserViewModel.swift:405-406`).
   `didFailProvisionalNavigation` (`:773-785`) asks
   `retryStartupLoadIfAppropriate` (`:378-400`), whose guard
   `ContinuousClock.now < startupLoad.deadline` is **false**: the deadline
   was 20 s after the load and the failure arrived at 30 s. So no retry;
   `navigationError` (`:516-535`) set `navError`, and `NavErrorPage`
   (`BrowserView.swift:55-111`) replaced the web view.
7. **What the error page said.** "Unable to Load Page", then in orange
   **"URL format error"**, the escaped URL, and "bad URL [NSURLErrorDomain
   -1000]". `categorize` (`:553-558`) maps -1000 to `.urlFormat` even though
   the same file knows -1000 is every SOCKS failure. The page has **no
   button**: `reload()` is bound only to ⌘R on a hardware keyboard
   (`DashboardRootView.swift:291`), and there is no "choose another gateway"
   anywhere but Settings.

**So the blank screen was state D4 below — a main-frame load in flight with
nothing committed — for the full 30 s SOCKS dial timeout, followed by an
error page that blamed the URL and offered nothing.** The earlier draft of
this spec blamed the silent startup-retry loop (D5). That loop did **not**
run on the device: it is armed for 20 s and the first failure came at 30 s.
It is a real second hole, on a transport that fails *fast* — the L1
blackhole test shows it, which is why `assertErrorPage` waits 40 s for a
failure the stub refuses in milliseconds (`UITests/OfflineHarnessTests.swift:327`;
20 s of 1-s retries, then the error page). Both holes — and the third, in
§1.2 — are closed here; the spec no longer guesses which one a given screen
came from because every state now logs its name and its elapsed time.

Two things only Olof can confirm are in §8: which field he typed into, and
whether he waited for the error page.

### 1.2 The same blank screen, the fast way: a live port that answers 502

The design pass traced one path to the blank screen and stopped. There is a
second, and it is faster. None of the 24 rows of §2 covered it, and the
tests as first written would have passed against it.

1. **The response delegate never looks at the status.** `decidePolicyFor
   navigationResponse` (`BrowserViewModel.swift:744-754`) logs the response
   under the `-UITestLogResponses` hook and then calls
   `decisionHandler(.allow)` unconditionally (`:753`). Whatever the gateway
   answers — 200, 403, 502 — commits as the document.
2. **The gateway's front door answers 502 when Kiro Crew is not there.** The
   gateway is published with `tailscale serve --bg --https=443
   http://127.0.0.1:<port>` (kirocrew 0.6.0, `dashboard/tailnet_serve.py:526`).
   serve's reverse proxy is a bare `httputil.ReverseProxy` with a `Rewrite`
   and a `Transport` and **no `ErrorHandler`**
   (`ThirdParty/libtailscale/tailscale-patched/ipn/ipnlocal/serve.go:959-994`),
   so when its dial to the loopback port fails — Kiro Crew restarting,
   stopped, or crashed — Go's default handler writes `502 Bad Gateway`
   **with no body**. While serve itself is being reconfigured the same
   handler answers `503 proxy is closed` (`:955-957`). Port 443 is live
   throughout: it is tailscaled's, not Kiro Crew's.
3. **So nothing fails.** The SOCKS CONNECT succeeds and the relay logs it as
   such, TLS completes against serve's certificate, the GET is answered.
   **No `NSURLError` is produced.** `SocksRelayRecovery`'s transport codes —
   -1000, -1004, -1005 (`App/Network/SocksRelayPolicy.swift:95-102`) — never
   fire, so the relay renders no verdict (`:180-193` is never asked).
   `didCommit` runs (`:707-718`), then `didFinish` (`:756-760`) →
   `session.navigationFinished()` → `verify` → a page-world fetch of
   `/api/auth/me`, which meets the same 502 and answers nil twice →
   `onUnansweredCheck` (`SessionManager.swift:176-184, 277-288`) → a relay
   self-probe that finds the listener answering and leaves it. Every
   instrument reports health.
4. **What is on screen.** An empty document from the right origin: white in
   light mode, black in dark, the gear at 0.45 opacity. `isLoading` is
   false, so even this feature's connecting block as first designed goes
   away at `didCommit` and shows exactly this. No error overlay, no button,
   no text, no timer — and **unbounded**: nothing polls the main frame, so
   the screen stays until the owner finds ⌘R or Settings. It takes about a
   second to reach (TCP, TLS, one GET on a relayed path), not 30.

**Why no suite ever saw it.** Every "gateway down" the harnesses can produce
is a *transport* failure:

- `fake_gateway.py`'s `__restart?down=S` (`:393-410`) accepts, completes the
  TLS handshake (`HandshakeInThread.setup`, `tls_accept.py:29-36`) and then
  `Page.handle` closes the connection without a byte (`:456-460`). CFNetwork
  reports that as an `NSURLError` (a lost connection), which *is* in
  `transportFailureCodes` and *does* reach `didFailProvisionalNavigation`.
  The session suite's restart tests (`SessionTests.swift:245, 448`) exercise
  exactly this shape.
- The L1 `down` peer is a closed port (`testing/harness/Makefile:91`,
  `127.0.0.1:9`): the stub's `create_connection` fails and it replies SOCKS
  0x05, which is -1000. `dashboard.py` has no down mode at all
  (`dashboard.py:18-29`).

Measured both ways on 2026-09-23: the fake closes the connection;
`tailscale serve` answers `502 Bad Gateway`. A build that commits every 5xx
passes every existing test and every test in the first draft of §6, because
none of them can make a gateway answer 502 on a live connection. §6 rule 6
(`assertSomethingIsSaid`) would have failed the moment a test looked at this
state — `connected-browser` counts only with the fake dashboard's report, and
a 502 page reports nothing — but no test could produce the state to look at.

### 1.3 The scan he could not read

At the time of the device run a probe had 1.5 s and a sweep 5 s. Under the
missing grant every probe hit its timeout, so a sweep ended after ~1.5 s
(DECISIONS, the O3b rehearsal: "1.5–1.6 s, every probe hits its timeout").
The "Looking for Kiro Crew gateways…" row (`GatewayPickerView.swift:48-55`)
flashed for that long and was replaced by "No Kiro Crew gateway answered
among N computer(s)". "Is it giving up too quickly?" — yes; R39 raised the
budgets to 4 s and 12 s (`GatewayDiscovery.swift:65-68`) and that landed
separately.

What R39 did not fix, and this does:

- the row is **static** for up to 12 s: no count of what has been checked,
  no elapsed time, nothing that moves;
- it is shown only while `gateways.isEmpty` (`:48`), so **Search again with
  rows already listed shows nothing at all** — the button merely goes grey;
- before the node's status arrives the picker shows a **disabled Search
  again and nothing else** (`ready == false`, `:42, :84, :134-138`);
- the finished text says how many were checked but not what happened to
  them. On the device the answer was "none answered at all", which is the
  signature of a policy that drops the node's traffic — and "no number of
  Search agains changes that" (DECISIONS, "O4 answered"). The text did not
  say so, so he searched again, twice.

### 1.4 Also found while enumerating

- The unreachable-gateway fallback (`about:blank` + banner) leaves 95 % of
  the screen blank under a one-line banner (D3).
- After `Running`, while the first status or the peer list is still on its
  way, `loadInitial` holds (`:287-289`, `:298-300`) and the web view is blank
  with no text (D2). On a relaunch this is a few seconds; if the netmap never
  arrives it is forever.
- The earlier draft's case C ("cancel the picker sheet over emptiness")
  **does not exist**: with no gateway the picker *is* the screen
  (`DashboardRootView.swift:197-203`), not a sheet, so Cancel lands back on
  it. Dropped.

## 2. Every state the root view can be in

`LatchkeyApp` → `DashboardRootView` → `WorkspaceRoot` → the gate until the
tailnet first reaches `Running`, then `DashboardContent` for the rest of the
session (`DashboardRootView.swift:129-147`). Within `DashboardContent`: the
picker until a gateway is chosen (`:190-203`), else the page. Verdict:
**bare** = nothing readable on screen; **misleading** = readable but wrong;
**thin** = readable but missing "how long" or "what next"; **fine**.

| # | State | Where | Drawn today | Text today | Affordance today | Leaves when | Verdict |
|---|---|---|---|---|---|---|---|
| G0 | No `WorkspaceManager` yet | `LatchkeyApp.swift:57, 66` | `ProgressView()` | none | none | immediately (constructed in `init`) | bare, unreachable |
| G1 | No active workspace | `DashboardRootView.swift:50-54` | `ProgressView()` | none | none | "never happens" (the manager seeds one) | bare, unreachable |
| G2 | Node starting: state `nil`/`NoState`/`Starting` | `StatusViewModel.swift:183-187`, `StatusView.swift:36-44` | brand header, status icon + text | "Connecting…" / "Starting…" | gear | the node reaches any other state; **unbounded** | thin — no elapsed, no escalation, no where-to-look |
| G3 | `NeedsLogin` | `StatusView.swift:66-80` | text + Login button | "Login Required" | Login | login | fine |
| G4 | Logged in, connecting | `StatusView.swift:58-65`; watchdog `StatusViewModel.swift:137-144` | spinner + text | "Finishing the tailnet connection…" | gear | `Running`, or back to G3 after 60 s | fine (bounded); gains an elapsed count |
| G5 | `NeedsMachineAuth` | `StatusView.swift:48-57` | text | "…waiting for a tailnet admin to approve it…" | none needed | approval | fine |
| G6 | `Stopped` | `StatusViewModel.swift:180` | icon + text | "Stopped" | gear | the node restarts (foreground) | thin — no what-next |
| G7 | The node could not be created (F8) | `StatusViewModel.startFailure`, `NodeStartFailureView.swift` | brand header, warning icon, title, cause, countdown | "Latchkey can't start its Tailscale node." + cause + "Nothing has been deleted." | Try now, Logs; *Start a new node* behind a confirmation | a start succeeds | fine (was a `fatalError`) |
| D1 | No gateway chosen | `DashboardRootView.swift:197-203` | full-screen `GatewayPickerView` | see P1–P8 | see P1–P8 | a gateway is chosen | fine as a container |
| D2 | Gateway chosen, load **holding** for status / peers | `BrowserViewModel.swift:287-289, 298-300` | blank `WKWebView` + gear | none (a log line only) | gear | the next status poll with peers (`TSNetManager.swift:408`, 5 s cadence); **unbounded** if peers never arrive | **bare** |
| D3 | Gateway **not in the tailnet**: `about:blank` fallback + banner | `HomePageAvailability.swift:34, 95`; `DashboardRootView.swift:348-351, 449-480` | banner over a blank body | "No KiroCrew gateway with this name is in your tailnet." | Find, Change | the peer appears (`:395-402`) or another gateway is chosen | thin — one line over a blank page |
| D4 | **Connecting**: main-frame load in flight, nothing committed | `BrowserViewModel.swift:361-373` → `didCommit :707` | blank `WKWebView` + gear | none | gear | `didCommit`, or a failure: 30 s (dropped SYNs, `socks5.go:99`), 120 s (accepted, never answers, `:372`), or WebKit's own TLS timeout | **bare — Olof's screen** |
| D5 | Connecting through **silent startup retries** | `BrowserViewModel.swift:378-400` | as D4 | none (a log line per retry, `:393`) | gear | commit, or the 20 s deadline (`:349`) → D6 | **bare** |
| D6 | **Failed**: `NavErrorPage` | `BrowserView.swift:55-111`; `BrowserViewModel.swift:516-535` | icon, title, category, escaped URL, message | "Unable to Load Page" / "URL format error" (for **every** SOCKS failure, `:553-558` — corrected in `8b0933d`, which already gives `.retrieval` §3.2's title "Couldn't reach <host>"; §4.3) / "bad URL [NSURLErrorDomain -1000]" | **none** (⌘R only, `DashboardRootView.swift:291`) | ⌘R, a gateway switch, a relay restart (`:262-266`), R7 | **misleading, and a dead end on a phone** |
| D7 | Failed: unknown / ambiguous short name | `BrowserViewModel.swift:494-514` | as D6 | "No device named “x” exists in this tailnet…" / "More than one…" | none | as D6 | thin — good text, no button |
| D8 | **Painted** page; the page's own states, the token sheet, node banners, expiry warnings, return-to-dashboard | `DashboardRootView.swift:225-239, 338-367, 423-443`; `TokenEntrySheet` | web content | the page's | the page's | — | fine; **must never be covered by D4** |
| D9 | Content process died | `BrowserViewModel.swift:883-905` | reload in place; after the budget, D6 with its own message (`:888`) | "The dashboard page stopped repeatedly…" | none | reload / ⌘R | fine text, needs D6's buttons |
| D10 | **Gateway answered 5xx**: the main-frame response is a 5xx and its body commits as the document | `BrowserViewModel.swift:744-754` (`.allow` for every status, `:753`); produced by `tailscale serve` with Kiro Crew down (`serve.go:959-994`, no `ErrorHandler`) | the 5xx body — for serve's 502, **nothing** (Go writes the status and no body); for its 503, one line of plain text | none | none (⌘R only) | a reload or a gateway switch; nothing polls the main frame — **unbounded** | **bare — the second path to Olof's screen, reached in ~1 s rather than 30 (§1.2)** |
| D11 | **KiroCrew's own 403 page** committed: `403` + `X-Auth-Required: true`, the "Sign in required — <reason>" document | `BrowserViewModel.swift:753`; served by `_deny` (kirocrew 0.6.0 `dashboard/token_auth.py:3097-3115`, body `:695-742`) when the peer's login is outside the gateway's allow-list (`:2169, :2203`), a sign-in link is bound to another device (`:2688-2690`), or a data path (`:599-610`) is opened as a document (`:2621, :2681`) | the gateway's page: a heading naming the reason, a paste field, Connect | the gateway's own | the page's field (navigates to `/?token=`, `:733-737`); no native sheet — the page fires no `mc-auth-required`, and `verify` does nothing with a 403 unless a sign-in is in flight (`SessionManager.swift:176-184, 289-306`) | a link pasted there; during a redemption, `failRedemption` → the sheet says the link didn't work (`:304-306, 324`) | fine — readable, the right words, the right origin; **must stay committed** (§4.13), and gets a log line |
| P1 | Picker, node **not ready** (`localStatus` or `proxyConfiguration` nil), phase `.idle` | `GatewayPickerView.swift:42, 84, 134-138` | "Gateways" header, a **disabled** Search again, the manual section | none about the wait | manual entry | `ready` flips (first status poll); **unbounded** | **bare** about what it waits for |
| P2 | Probing, no rows yet | `GatewayPickerView.swift:48-55` | spinner + one line | "Looking for Kiro Crew gateways on your tailnet…" | manual entry | `.finished` / `.proxyUnhealthy`, ≤ 12 s | thin — nothing moves for 12 s |
| P3 | Probing, rows already listed (a re-scan) | `GatewayPickerView.swift:48` (`gateways.isEmpty`) | rows; Search again greyed | none about the scan | rows, manual entry | `.finished` | **bare** about the scan |
| P4 | Finished, none found, candidates > 0 | `GatewayPickerView.swift:65-71` | one line | "No Kiro Crew gateway answered among N computer(s) on your tailnet. Enter one below." | Search again, manual entry | a new sweep | thin — no answered/unanswered split, no duration, no likely cause |
| P5 | Finished, some found | `GatewayPickerView.swift:56-64, 149-154` | rows; auto-chosen on first run if exactly one | the hosts | tap a row | choice | fine |
| P6 | Every probe failed **and** the loopback did not answer | `GatewayPickerView.swift:72-76`; `GatewayDiscovery.swift:195-204` | orange line | "The tailnet connection isn't passing traffic yet. Search again in a moment." | Search again | a new sweep | fine; gains what was tried |
| P7 | Finished, **zero candidates** | `GatewayPickerView.swift:66-67, 144-148` | one line | "No computers on your tailnet could be a gateway. Enter one below." | manual entry; auto re-sweep when peers change | peers arrive | fine; says it re-searches by itself |
| P8 | Manual entry refused | `GatewayPickerView.swift:101-106, 163-166` | red line | "x isn't on your tailnet. Enter a tailnet name…" | edit | edit | fine |

Sheets over any of these (Settings, the picker sheet from Find / Settings,
the token sheet) hide the state underneath; on dismissal the state
underneath is one of the rows above, and each of those now says something.

## 3. What the owner sees

All wording is final unless §8 changes it. `<host>` is the gateway's first
DNS label as the owner knows it (`byskebox`), with `:<port>` appended when
the port is not 443 (F1). `<fqdn>` is the full name, shown only in details.
Elapsed times are whole seconds and tick once a second.

### 3.1 Connecting (D4, D5)

- **0–300 ms:** the web view's own background. Nothing else.
- **300 ms:** a centred block replaces the web view's area (opaque, system
  background, correct in dark mode):
  - an indeterminate indicator;
  - **"Connecting to byskebox…"**;
  - smaller, secondary: **"over your tailnet · 4 s"** — the number ticks.
- **8 s:** a third block appears beneath, and stays:
  - **"Still trying. A gateway on the tailnet normally answers within a few
    seconds. If this device is new, it may not be allowed to reach byskebox
    yet — whoever manages the tailnet needs this device's address, shown in
    Settings → Status."**
  - one button: **Choose another gateway**. Tapping it stops the load
    (`stopLoading()`), moves the page to the failed state below with cause
    *stopped* (so cancelling the picker lands on an error page with *Try
    again*, never on a blank web view), and opens the picker sheet.
- Through the silent retries (D5) the block does not change and the clock
  does not reset: it counts from the **first** attempt. Each retry logs as it
  does today, plus the state line (§4.9).
- It disappears the instant `didCommit` runs. It never appears over a
  committed page: a same-document navigation, a subresource, the page's own
  WebSocket reconnect, the session layer's fetches — none of them touch it.

### 3.2 Failed (D6, D7, D9, D10)

The error page is rebuilt. Same identifier `nav-error-overlay`, new body:

- title (`nav-error-title`): **"Couldn't reach byskebox"** for a retrieval
  failure; **"Couldn't reach Kiro Crew on byskebox"** when byskebox answered
  but with a 5xx (D10); **"Latchkey can't open this address"** for a URL
  format error; **"The page stopped"** for a content-process failure;
  **"Stopped"** when the owner stopped it.
- cause (`nav-error-cause`): one sentence from the table in §4.4, naming
  the host, the port, the elapsed time and the most likely reason.
- what to do (`nav-error-next`): one sentence from the same table.
- two buttons, full opacity: **Try again** (`nav-error-retry`, calls
  `reload()`) and **Choose another gateway** (`nav-error-choose-gateway`).
- a **Details** disclosure (`nav-error-details`, collapsed): the escaped URL
  exactly as today (`debugEscaped`, it has caught invisible characters
  before), the error domain and code, the relay's reply name and its
  timing when there is one — or, for D10, the HTTP status, the response's
  `Content-Type` and its body length (0 for serve's 502) — and "Settings →
  Status → Page keeps this; Logs has the full record." D1 holds: nothing
  leaves the device; this is where the diagnosis is *read*.

### 3.3 Holding (D2)

Same block as 3.1 with the text **"Waiting for the tailnet's peer list before
opening byskebox…"** and the ticking **"· 3 s"**. At **15 s** a hint:
**"Still waiting for the node's peer list. Settings → Status shows the
node's state and how many peers it sees; Settings → Node log shows what it
is doing."** No button: there is nothing to retry, and the picker would find
nothing without peers either.

### 3.4 Gateway missing (D3)

The banner stays (with its Find and Change). The blank body under it becomes
the same centred block: **"byskebox isn't in your tailnet right now."** and
**"Latchkey checks again as the tailnet updates. *Find* lists the gateways
it can see; *Change* lets you correct the name."** No buttons in the body —
the banner's are the single presentation path (M5 review).

### 3.5 The picker (P1–P7)

Rows in the Gateways section, in this order, above the gateway rows:

- **P1 waiting for the node:** indicator + **"Waiting for the tailnet
  node… 2 s"**. At 15 s, a second line: **"Still waiting. Settings → Status
  shows the node's state."** *Search again* keeps its label and stays
  disabled; the row above it is the explanation.
- **P2/P3 scanning, whenever `phase == .probing`, rows listed or not:** a
  determinate bar plus **"Checking 7 computers on your tailnet · 3 of 7
  done · 5 s"**. The count is finished probes (answered or failed) over
  `candidateCount`; the seconds tick. Rows stream in beneath it as today.
  *Search again* reads **Searching…** and is disabled while this row is up.
- **P4 none found:** **"Checked 7 computers in 12 s. 2 answered but aren't
  Kiro Crew gateways; 5 didn't answer at all."** Then one of:
  - unanswered > 0: **"A computer that doesn't answer at all is usually one
    this device isn't allowed to reach yet. If your gateway is among them,
    whoever manages the tailnet needs this device's address: Settings →
    Status. Searching again won't change that by itself."**
  - unanswered = 0: **"Every computer answered, so the tailnet is fine; none
    of them is a Kiro Crew gateway. Enter yours below if it isn't listed as
    a peer."**
- **P6 proxy unhealthy:** **"Nothing answered in 12 s, and the tailnet node
  itself isn't passing traffic yet (its own proxy didn't answer either).
  Search again in a moment; if it keeps happening, Settings → Node log."**
- **P7 zero candidates:** **"No computer on your tailnet could be a gateway
  (0 candidates among 3 peers). Latchkey searches again by itself when
  peers appear. Enter one below if you know its name."**

### 3.6 The gate (G2, G6)

- G2 at **15 s** in `Connecting…` or `Starting…`: a line under the status:
  **"Still starting after 15 s. Settings → Node log shows what the node is
  doing."** (ticks).
- G6: **"Stopped. Latchkey starts the node again when it returns to the
  foreground; if it doesn't, Settings → Node log."**
- G1: `Text("Starting Latchkey…")` beside the spinner. Unreachable, and one
  line.

### 3.7 Everything is named in the log

Every transition writes one line (§4.9), so a suite and a device run can
both tell which state was on screen and for how long — the same instrument
`scripts/test-discovery.sh` already reads for sweeps.

## 4. Design

### 4.1 Timing, and why these numbers

| Threshold | Value | Constant | Why |
|---|---|---|---|
| Connecting state becomes visible | **300 ms** after `loadResolved` with no commit | `PageStateView.showDelay` | Below it, a state that appears and is replaced reads as flicker. A loopback commit on the harness is well under it, so a healthy load never shows it; a real relayed path (190 ms RTT direct, more via DERP; TCP + TLS + GET ≈ 4 round trips) is over it, and the owner *is* waiting then. It replaces a blank rectangle, not content, so the cost of a brief appearance is low; the cost of a 30 s blank is what this feature is for. |
| "Still trying" hint | **8 s** | `BrowserViewModel.connectingHintDelay` | Twice R39's per-probe budget (4 s), which was sized from the device's own relayed intercontinental path with "room to spare". A load is the same shape as a probe (TCP, TLS, one GET); one that has not committed by 2× that budget is not slow, it is stuck. F2 said 6–8 s; 8 s errs toward not nagging. |
| Holding hint | **15 s** | `BrowserViewModel.holdingHintDelay` | Three status polls (`TSNetManager.startStatusPolling`, 5 s). On a relaunch the peer list arrives within one or two. |
| Gate hint | **15 s** | `StatusView.startingHintDelay` | Same reasoning; a node normally reaches a state well inside one poll. |
| Picker waiting-for-node hint | **15 s** | `GatewayPickerView.waitingHintDelay` | Same. |
| Give up | **not a new timer** | — | The transport already bounds it: 30 s SOCKS dial (`socks5.go:99`), 20 s startup retries (`BrowserViewModel.swift:349`), 120 s request timeout (`:372`), 12 s sweep (`GatewayDiscovery.swift:68`). Adding a shorter app timer would abandon loads that would have succeeded on a slow path — exactly R39's lesson. Instead the clock is on screen, so nothing looks frozen, and the failure names the elapsed time. |
| Scan progress | from the first ms of `.probing`, updated per outcome and per second | — | The picker is a list; the row is content, not a spinner over content. |

### 4.2 `App/Browser/PageState.swift` (new)

```swift
enum PageState: Equatable {
    case idle
    /// D2: `loadInitial` is waiting for status / peers.
    case holding(host: String, since: ContinuousClock.Instant)
    /// D4/D5: a main-frame load is in flight and nothing has committed.
    /// `since` is the first attempt's stamp; `attempt` counts startup retries.
    case connecting(host: String, port: Int, since: ContinuousClock.Instant, attempt: Int)
    case committed
    /// D6/D7/D9.
    case failed(PageFailure)
}

struct PageFailure: Equatable {
    enum Cause: Equatable {
        case noAnswer            // SOCKS general failure after a long dial: dropped SYNs
        case refused             // SOCKS connection refused
        case unreachable         // SOCKS host / network unreachable
        case proxyNotReady       // SOCKS general failure within 2 s of the attempt
        case proxyDown           // the relay / loopback listener refused (R30's territory)
        case timedOutAfterConnect // -1001: connected, never answered
        case certificate         // -1200…-1206
        case unknownHost(String)  // D7
        case ambiguousHost(String, [String])
        case redirectedAway(String)  // WebKitErrorDomain 102, nothing committed, no refused-response record
        case gatewayError(status: Int)  // D10: a main-frame 5xx, refused in decidePolicyFor navigationResponse (§4.13)
        case pageCrashed(times: Int, window: Int)  // D9 after the budget
        case stopped             // the owner chose another gateway mid-load
        case badAddress          // URL(string:) failed (reportURLParseFailure)
        case other(domain: String, code: Int)
    }
    let host: String        // first label, as shown
    let fqdn: String
    let port: Int
    let cause: Cause
    let elapsed: Duration   // since the first attempt
    let domain: String
    let code: Int
    let proxyReply: ProxyReply?   // from TSNetModel.lastProxyFailure when it matches host:port
}
```

`App/Browser/PageFailureText.swift` (new): pure `static func lines(for:
PageFailure) -> (title: String, cause: String, next: String)` and `static func
cause(domain:code:proxyReply:elapsed:) -> Cause`. Host-tested (§6, test 5–6)
through a new `app/scripts/test-page-failure-text.sh` on the pattern of
`test-navigation-policy.sh`, run by `make test-policy`.

### 4.3 `App/Browser/BrowserViewModel.swift`

- `@Published private(set) var pageState: PageState = .idle`.
- `loadInitial`: on `.wait` (either hold), set `.holding(host:since:)` once
  (keep the first `since`).
- `loadResolved`: if `pageState` is not `.connecting`, set
  `.connecting(host:port:since: .now, attempt: 1)`; if it is (a startup
  retry), bump `attempt` and keep `since`. Same-document and page-initiated
  navigations never reach `loadResolved`; they are unaffected.
- `didStartProvisionalNavigation`: **no state change.** Page-initiated
  main-frame navigations over a committed page (a link, the session layer's
  sign-in load) must not show the block; those are `.committed` already, and
  the test in §6 (12) pins it.
- `didCommit`: `.committed`. `unloadWebView`: `.idle`.
- `navigationError`, `reportUnknownTailnetHost`, `reportAmbiguousTailnetHost`,
  `reportURLParseFailure`, `handlePolicyInterruption`,
  `recoverFromContentProcessTermination` (the give-up branch): `.failed(…)`
  with `elapsed = .now - since` (zero when there was no connecting state),
  `proxyReply` looked up as in §4.5.
- `categorize` (`:553-558`): `-1000` is `.retrieval` unless it came from
  `reportURLParseFailure`, which sets `.urlFormat` itself. The comment at
  `:405-406` already states why. This landed as its own fix ahead of the
  rest of F4 (`8b0933d`), and it took §3.2's titles with it:
  `NavErrorKind.caption(host:)` reads **"Couldn't reach <host>"** for
  `.retrieval` and **"Latchkey can't open this address"** for
  `.urlFormat`, with the host from `BrowserViewModel.displayHost(of:)`. So a
  SOCKS failure already reads "Couldn't reach byskebox" and never "URL
  format error"; the rebuilt page (§3.2) keeps those exact words as
  `nav-error-title` and adds the cause, the next step and the buttons. Test 5
  pins the function either way.
- `decidePolicyFor navigationResponse` (`:744-754`): the `RESP-LOG` hook
  stays; then
  `ResponsePolicy.decide(isMainFrame: navigationResponse.isForMainFrame, statusCode: (response as? HTTPURLResponse)?.statusCode, authRequired: http?.value(forHTTPHeaderField: "X-Auth-Required")?.lowercased() == "true")`
  (§4.13). `.commit` → `decisionHandler(.allow)` as today, plus the status
  in the `committed` log line (§4.9). `.refuse` → record
  `refusedResponse = (url: Self.withoutSignInToken(url), status: status)`,
  log `page-state: refused status=<n> after <t> ms`, then
  `decisionHandler(.cancel)`. WebKit reports the cancel to
  `didFailProvisionalNavigation` as `WebKitErrorDomain` 102 — the same code
  as a cancelled *action* — which is why the record exists.
- `handlePolicyInterruption` (`:849-865`) **checks `refusedResponse`
  first.** Without that, a 502 would be labelled "redirected to …" when
  nothing has committed (`:861-863`) or swallowed with "keeping the current
  page" over a committed one (`:852-856`) — the stale page staying up with
  no word while the owner's reload was refused. With a record:
  `startupLoad = nil`, cancel `startupRetryTask`,
  `.failed(cause: .gatewayError(status: n))` with the usual `elapsed`,
  `session?.signInLoadFailed()` when the original URL carried a token
  (today `:781` runs *after* the interruption check, so a refused sign-in
  load would otherwise wait out the 30 s redemption timer), clear the
  record, return true. A new `didStartProvisionalNavigation` clears a stale
  record.
- **No silent startup retry for a refused response.** `isTransientStartupError`
  (`:402-414`) exists because the node can publish `Running` a moment before
  its first dial works; a 5xx is the gateway's answer over a working
  transport, not the transport settling, and 20 s of silent retries against
  it would be a fresh bare screen. The failed state's *Try again* is the
  retry, and its cause line says a restart is normally over in seconds.
- `stopForGatewayChange()`: `stopLoading()`, cancel `startupRetryTask`, clear
  `startupLoad`, `.failed(cause: .stopped)`.
- Constants with their reasoning in a comment: `connectingHintDelay =
  .seconds(8)`, `holdingHintDelay = .seconds(15)`. The retry policy at `:349`
  and `:387` is **not** touched; a comment there records that a 30 s dial
  outlasts the 20 s window, so the loop only ever fires on fast failures.

### 4.4 Failure wording (`PageFailureText`)

`<h>` = host, `<p>` = port, `<t>` = elapsed seconds, `<f>` = fqdn.

| Cause | Decided by | Title | Cause line | Next line |
|---|---|---|---|---|
| `.noAnswer` | -1000, reply *general failure* (or no reply recorded), elapsed ≥ 2 s | Couldn't reach `<h>` | `<h>` didn't answer on port `<p>` in `<t>` s. The tailnet dropped the connection, which usually means this device isn't allowed to reach `<h>` yet, or `<h>` is off. | Whoever manages the tailnet needs this device's address (Settings → Status). If `<h>` is on, try again in a moment. |
| `.proxyNotReady` | -1000, reply *general failure*, elapsed < 2 s | Couldn't reach `<h>` | The tailnet node couldn't open a connection to `<h>`:`<p>` (it answered "general failure" after `<t>` s). The node may still be settling. | Try again. If it keeps happening, Settings → Node log. |
| `.refused` | reply *connection refused* | Couldn't reach `<h>` | `<h>` is reachable but refused the connection on port `<p>`: nothing is listening there. | Is Kiro Crew's dashboard served on port `<p>`? Choose another gateway, or correct the port in Settings. |
| `.unreachable` | reply *host unreachable* / *network unreachable* | Couldn't reach `<h>` | The tailnet has no route to `<h>` right now. | Try again in a moment; if it persists, Settings → Status shows the node's state. |
| `.proxyDown` | -1000 and the relay accepted nothing since the navigation, or R30 restarted it | Couldn't reach `<h>` | The connection never reached the tailnet node: its proxy on this phone didn't answer. | Try again; Latchkey has restarted the proxy. If it persists, Settings → Status → Proxy. |
| `.timedOutAfterConnect` | -1001 | Couldn't reach `<h>` | `<h>` accepted the connection on port `<p>` but sent nothing in `<t>` s. | Try again. If `<h>` keeps accepting and never answering, its gateway is up but stuck. |
| `.certificate` | -1200…-1206 | Couldn't reach `<h>` | `<h>` answered on port `<p>`, but its certificate isn't valid for `<f>`. | Latchkey only opens a gateway with a valid certificate (R28). Check the gateway's `tailscale serve` certificate. |
| `.unknownHost(x)` | today's text | Couldn't reach `<h>` | No device named “x” exists in this tailnet. | Check the name, or choose another gateway. |
| `.ambiguousHost` | today's text | Couldn't reach `<h>` | More than one tailnet device matches “x”: a, b. | Enter the full name. |
| `.redirectedAway(u)` | WebKitErrorDomain 102 with no refused-response record (§4.3) | Couldn't open `<h>` here | `<h>` redirected to `u`, which isn't the gateway this app is set to, so it wasn't opened here. | Check the gateway address in Settings. |
| `.gatewayError(502/503/504)` | a main-frame 5xx refused in `decidePolicyFor navigationResponse` (§4.13), one of the reverse-proxy statuses | Couldn't reach Kiro Crew on `<h>` | `<h>` answered on port `<p>`, but Kiro Crew behind it didn't: `tailscale serve` returned `<status>` after `<t>` s, which is what it says when nothing is listening behind it. Kiro Crew is probably restarting or stopped on `<h>`. | Try again in a few seconds — a restart is normally over by then. If it keeps happening, Kiro Crew isn't running on `<h>`: start it there, or choose another gateway. |
| `.gatewayError(other 5xx)` | any other main-frame 5xx | Kiro Crew on `<h>` hit an error | `<h>` answered `<status>` for the dashboard page after `<t>` s: Kiro Crew is running but couldn't serve it. | Try again. If it persists, Kiro Crew's own log on `<h>` says why. |
| `.pageCrashed(n, w)` | R7 budget spent | The page stopped | The dashboard page stopped `n` times in `w` s, so automatic reloading has paused. This is the page itself, not the tailnet. | Try again. |
| `.stopped` | owner action | Stopped | You stopped the connection to `<h>` after `<t>` s. | Try again, or choose another gateway. |
| `.badAddress` | `URL(string:)` nil | Latchkey can't open this address | The address has a character it can't use; the details show it escaped. | Correct the gateway in Settings. |
| `.other` | anything else | Couldn't load `<h>` | `<h>` could not be loaded (`domain` `code`). | Try again. |

The words "bad URL" and "URL format error" never appear for a transport
failure.

### 4.5 `TSNet/TSNetModel.swift` and `TSNet/SocksLogProxy.swift` (existing files; no pbxproj edit)

- `TSNetModel`: `@Published var lastProxyFailure: ProxyReply?` where
  `struct ProxyReply: Sendable, Equatable { let target: String; let reply: String; let elapsed: Duration; let at: Date }`.
- `SocksLogProxy`, at the line that logs `FAILED … could not connect`
  (`:629`): also publish it on the model (main actor hop; the relay already
  holds a reference to the manager's model through its owner). Only failures
  are published; the value stays in memory and is shown in Status → Page.
- `BrowserViewModel` reads it when building a `PageFailure`: it matches when
  `target == "<fqdn>:<port>"` and `at >= navigationStartedAt`. Otherwise
  `proxyReply` is nil and the cause falls back on code and elapsed alone.

This is the only change to `TSNet/`. It adds one field to a model that is
already the app's own (`TSNetModel` is not upstream's shape any more), and
one line to the relay next to its existing log call.

### 4.6 `App/Browser/BrowserView.swift`

```swift
ZStack {
    RawWebView(model: model).id(ObjectIdentifier(model)).ignoresSafeArea(.container, edges: .top)
    PageStateView(state: model.pageState, gatewayMissing: gatewayMissing,
                  onRetry: model.reload, onChooseGateway: onChooseGateway)
}
```

- `RawWebView` stays in the hierarchy in every state, so the in-flight load
  and the committed page are never torn down by a state change (today the
  `if navError` branch removes the web view; keeping it is simpler and
  avoids a re-`makeUIView` on retry).
- `PageStateView` is `EmptyView` for `.idle` and `.committed` (unless
  `gatewayMissing`), renders `NavErrorPage` for `.failed`, and is otherwise
  an **opaque** full-size block on `Color.platformSystemBackground`. Its buttons are at opacity 1 with an
  opaque background behind them — the M8 finding (a control at opacity < 1
  over a `WKWebView` gets no taps) is the reason the block is opaque, and
  tests 4 and 10 tap the buttons to prove it.
- The 300 ms delay: `.task(id: since) { try? await Task.sleep(for: showDelay); pastShowDelay = true }`,
  with `pastShowDelay` reset whenever `since` changes. The elapsed label
  uses `TimelineView(.periodic(from: since, by: 1))`.
- `NavErrorPage` keeps its name and identifier and gains the body in §3.2;
  `debugEscaped` moves under Details.
- Accessibility: the container is `.accessibilityElement(children: .contain)`;
  the ticking number is a separate element whose **label** is static
  ("elapsed") and whose **value** ticks, so VoiceOver reads it on focus and
  does not announce every second. The indicator is never the only signal.

### 4.7 `App/Browser/DashboardRootView.swift`

- `DashboardContent` owns the one picker presentation already
  (`showingGatewayPicker`, `:182, :242-257`). It passes
  `onChooseGateway: { tab.viewModel.stopForGatewayChange(); showingGatewayPicker = true }`
  and `gatewayMissing: homePageAvailability == .unavailable` into `BrowserView`.
  Find, Change, the connecting hint and the error page all go through this
  one path; two presentations never overlap (M5 review).
- G1: `ProgressView()` becomes `Label("Starting Latchkey…", systemImage: …)`
  with a spinner.
- `#if LATCHKEY_TEST_HOOKS`: a hidden overlay `page-connecting-shown-count`
  (opacity 0.01, like `session-auth-required-count` at `:259-266`) showing
  how many times the connecting block became visible for this tab. A flash
  between two looks is caught by the number.

### 4.8 Discovery: `App/Discovery/GatewayDiscovery.swift`, `GatewayPickerView.swift`

- `GatewayDiscovery` publishes, besides `phase`, `gateways`, `candidateCount`:
  `probed` (outcomes received), `answered`, `unanswered` (= failures),
  `startedAt: ContinuousClock.Instant?`, and `lastSweep: SweepSummary?`
  (`candidates, answered, unanswered, gateways, elapsed`) set at the end.
  Updated inside the existing outcome loop (`:160-187`); the generation
  guard already prevents a superseded sweep from writing.
- **The existing log lines are byte-for-byte unchanged**: `Discovery:
  probing N of M peer(s)` and `Discovery: N gateway(s); first after …`
  are parsed by `scripts/test-discovery.sh` (its regexes at lines ~150–165).
  Progress goes to a **new** line, `Discovery: progress k/n at t ms`, at
  most once a second.
- `GatewayPickerView`: the rows of §3.5 replace `:48-55` and `:65-76`. The
  scanning row is conditioned on `phase == .probing` **only**. *Search
  again*'s label is `Searching…` while probing. The `gateway-sweep-done`
  hidden text is kept (tests read it) and gains `answered/unanswered`:
  `sweep-done:<gateways>:<answered>:<unanswered>`. Existing tests read only
  the first field and keep working; the format is documented in the view.
- Status → Gateway → "Last discovery" (`DiagnosticsView.swift:164-171`)
  reads `lastSweep`: "1 of 4 candidates; 2 answered, 2 didn't, 4.1 s".

**As built (2026-09-24), four corrections.** F7 landed between this section
being written and being implemented, and it changed the same two files:

1. **The published names are `probedCount`, `answeredCount`, `unansweredCount`**,
   not `probed`/`answered`/`unanswered`: `probedCount` already shipped in F7 and
   its host tests, and renaming a shipped, tested value to match a spec written
   earlier is churn for its own sake. `SweepSummary` also carries `probed` and
   `truncated`, which this section did not ask for — without them the
   "Last discovery" row would report a sweep that ran out of time as if it had
   finished.
2. **The counts are kept per host, not as counters**, so
   `answeredCount + unansweredCount == probedCount` holds by construction. A
   continuation re-probes the saved gateway and may re-probe a peer that timed
   out inside the dispatched window, and plain counters would have had the picker
   say it checked 25 of 24 computers.
3. **P4's wording is merged with F7 §4.2's, not chosen over it.** This section's
   answered/unanswered split is the part that tells the owner whether the tailnet
   or the gateway is at fault; F7's rule is that no sentence may name a number
   that was not probed. So the split always shows, the count is `probedCount`,
   and the candidate total appears beside it only when the two differ — with
   "— the search ran out of time" and "Keep searching to try the rest" added in
   that case. The button therefore has *three* labels, not two: `Searching…`
   while probing, `Keep searching` when truncated, `Search again` otherwise.
4. **"Existing tests read only the first field and keep working" was wrong.**
   `DiscoveryTests.testManualEntryWhenNoGatewayIsFound` asserted
   `XCTAssertEqual(label, "sweep-done:0")` — whole-string equality. Appending the
   two fields broke it, and it was updated to parse by field. A marker that tests
   compare by equality is not extensible; the format is now documented in the
   view *and* parsed by field on the test side.

### 4.9 One line per state

Through `logger.log`, redacted as today (`redactedForLog`):

```
page-state: holding host=<r> 
page-state: connecting host=<r> port=443 attempt=1
page-state: connecting host=<r> port=443 attempt=7        (each retry)
page-state: hint after 8004 ms
page-state: committed status=200 after 812 ms
page-state: committed status=403 auth-required after 640 ms      (D11)
page-state: refused status=502 after 910 ms                      (D10)
page-state: failed cause=gatewayError status=502 after 912 ms
page-state: failed cause=noAnswer code=-1000 after 30012 ms reply="general failure"
page-state: stopped after 9200 ms
picker-state: waiting-node
picker-state: scanning 0/4
picker-state: none answered=2 unanswered=2 in 4012 ms
picker-state: found 1 in 447 ms
gate-state: starting-hint after 15003 ms
```

### 4.10 Gate: `App/Tailnet Status/StatusView.swift`

A `StalledHint(since:delay:text:)` view (shared with the picker and the page
block) under the status row for `Connecting…` / `Starting…`; `Stopped` gets
the sentence in §3.6. `since` is when the gate appeared or the state last
changed, whichever is later.

### 4.11 Diagnostics: `App/Diagnostics/DiagnosticsView.swift`

Status → Page gains "State" (`pageState`, with its elapsed) and keeps "Last
error", now the cause line; "Last proxy reply" from `lastProxyFailure`.
Read-only, on device, nothing leaves (D1).

### 4.12 Identifiers (the contract between the views and the tests)

| Identifier | Element | Label / value read by tests |
|---|---|---|
| `page-connecting` | the block (D4/D5) | — |
| `page-connecting-host` | text | "Connecting to <host>…" |
| `page-connecting-elapsed` | text | value "<n> s" |
| `page-connecting-hint` | text (from 8 s) | the hint |
| `page-connecting-choose-gateway` | button (from 8 s) | — |
| `page-holding`, `page-holding-hint` | block (D2), its 15 s hint | "Waiting for the tailnet's peer list before opening <host>…" |
| `page-gateway-missing` | block body (D3) | — |
| `nav-error-overlay` | the error page (kept) | — |
| `nav-error-title`, `nav-error-cause`, `nav-error-next` | texts | §4.4 |
| `nav-error-retry`, `nav-error-choose-gateway` | buttons | — |
| `nav-error-details` | disclosure | escaped URL, domain, code, reply |
| `page-connecting-shown-count` | hidden text (test builds) | integer |
| `gateway-waiting-node`, `gateway-waiting-node-hint` | row (P1), its hint | "Waiting for the tailnet node… <n> s" |
| `gateway-scanning` | row (P2/P3) | "Checking <n> computers on your tailnet · <k> of <n> done · <t> s" |
| `gateway-none` (kept), `gateway-none-hint` | P4 line, its second line | §3.5 |
| `gateway-proxy-unhealthy`, `gateway-refresh`, `gateway-sweep-done` (kept) | | `sweep-done:<g>:<a>:<u>` |
| `gate-starting-hint` | gate hint (G2) | — |

**Invariants this must not break** (see `../../app/AGENTS.md`):
- the split tunnel decides what goes through the proxy; only tailnet hosts
  do — nothing here touches `TailnetProxyPolicy` or the proxy configuration;
- `allowFailover` stays false — a dead proxy still fails the load; the
  failure is now *described*, not avoided;
- ATS stays on with no exceptions; HTTPS only;
- D1: no app or node logs leave the device — every diagnostic above is shown
  in-app (the block, the error page's Details, Settings → Status/Logs);
- a vendored-tree change is its own commit (R16) — there is none; the SOCKS
  dial timeout is read, not changed;
- the node's own banners (login, approval, expiry) keep priority: they are in
  the layout above `BrowserView` and are unaffected by the page block.

### 4.13 Which main-frame responses commit (`ResponsePolicy`, in `App/Browser/NavigationPolicy.swift`)

`NavigationPolicy` decides *requests*; this decides *responses*, by status
alone, in the main frame alone, and it lives in the same pure-Foundation
file so `scripts/test-navigation-policy.sh` compiles and tests it on the host
(test 18).

```swift
enum ResponseDecision: Equatable, Sendable { case commit, refuse }

enum ResponsePolicy {
    /// - statusCode: nil for anything that is not an HTTP response.
    /// - authRequired: `X-Auth-Required: true` — KiroCrew's own signature.
    nonisolated static func decide(isMainFrame: Bool, statusCode: Int?,
                                   authRequired: Bool) -> ResponseDecision
}
```

| Response | Decision | Why |
|---|---|---|
| Not the main frame | commit | Frames are the page's own (`/sandbox-doc/`); `NavigationPolicy` leaves them alone for the same reason (`NavigationPolicy.swift:17-18`). A widget's 502 is the widget's business. |
| Not HTTP (`about:blank`, a `WKURLSchemeHandler` scheme, a blob) | commit | Nothing to inspect. |
| 1xx, 2xx | commit | The document. |
| 3xx | commit | WebKit follows redirects before the response reaches this delegate — each hop is a fresh `decidePolicyFor navigationAction`, where `NavigationPolicy` already sends an off-origin hop to the system and the app shows `.redirectedAway` (`:849-865`). A 3xx that *does* arrive here is one WebKit could not follow and is the gateway's own document. KiroCrew's one document redirect is its canonical-host 302 (`dashboard/server.py:2697-2709`, `urls.py:325`), which is exactly the `.redirectedAway` case. |
| **304** | commit | **Never a failure**: it is the document the web view already has. CFNetwork normally answers a revalidation with the cached 200, so this delegate rarely sees a 304 at all; the rule is written so that if it does, nothing is refused. |
| **`401`/`403` with `X-Auth-Required: true`** | **commit** | KiroCrew speaking — the very signature discovery uses to recognise a gateway (`GatewayCandidates.swift:106-108`, `GatewayDiscovery.swift:14-17`). Its body is KiroCrew's own sign-in page (D11). What follows is today's behaviour, unchanged: `didFinish` → `navigationFinished` → `verify` → `/api/auth/me` (`SessionManager.swift:176-184, 277-307`). **Refusing it would break sign-in.** A redemption load (`loadSessionURL`, `BrowserViewModel.swift:915-922`) that the gateway refuses — a link bound to another device (`token_auth.py:2688-2690`), a login outside the allow-list (`:2169`) — is answered with this 403, and `verify(afterRedemption: true)` is what turns it into "That sign-in link didn't work. Links last 5 minutes and work only on the gateway that made them" (`SessionManager.swift:304-306, 324`). Cancelled, `didFinish` never runs, `signInLoadFailed` says "Couldn't reach the gateway to sign in" (`:190`), and the owner is told the tailnet is broken when the gateway said no. Test 16 pins this. |
| Any other 4xx | commit | The gateway answered about the request with a body of its own, same-origin: a 404 for a path the dashboard linked to is the dashboard's page, and this feature never covers a page the gateway meant to show. For `/` KiroCrew never answers 4xx without the header — the shell is served to any unauthenticated document GET (`token_auth.py:661-690, 2617, 2669`) — so a bare 4xx in the main frame is a link inside the dashboard, not the startup load. |
| **5xx** | **refuse** → `.failed(.gatewayError(status:))` | None is a page the owner can use, and 502's body is nothing at all. 502/503/504 are `tailscale serve` speaking for a Kiro Crew that is not there (`serve.go:959-994` with Go's default error handler: 502, no body; `:955-957`: 503 while serve reconfigures); 500 is Kiro Crew itself failing on the document. The wording in §4.4 tells the two apart. |
| 5xx **with** `X-Auth-Required: true` | commit | Does not occur (`_deny` is always 403), but the rule is "KiroCrew's own voice is always shown", stated once. |
| `canShowMIMEType == false` | unchanged (allow, as today) | Not this feature's. |

What the rule never does: read the body, read any header but
`X-Auth-Required`, refuse anything under 500, or touch a sub-frame. Refusal
is by status alone, so a gateway that is up and answering — however
unhappily — always gets to show its page; only a gateway that is *not there*
is replaced by ours.

## 5. State and migration

Nothing is persisted. `pageState`, the discovery counters and
`lastProxyFailure` are in memory, per tab / per workspace, and reset on
launch. A value written by the previous version does not exist.

## 6. End-to-end tests

**Suites:** host `make test-policy`; L1 `scripts/test-offline.sh`
(`OfflineHarnessTests`); L2 `scripts/test-tailnet.sh`; session
`scripts/test-session.sh` (`SessionTests`, real 0.6.0 bundle); discovery
`scripts/test-discovery.sh` (`DiscoveryTests`, L2 harness with `gw`, `dash`,
`plain`, `slow`, purgatory); lifecycle `scripts/test-lifecycle.sh`.

**Harness change (L1):** `testing/harness/socks5stub.py` gains
`POST /mode?stall=<seconds>`: authenticate, journal the CONNECT as today,
then **hold the socket silent for N seconds and reply 0x01 general failure**
— tsnet's exact behaviour on dropped SYNs (`socks5.go:219-232`), at a
duration the test chooses. `stall=0` clears it. The stub's `--map` and the
relay in front stay as they are, so `lastProxyFailure` is populated in L1
exactly as on the device.

**Harness change (session and L1): a 502 on a live connection.** Today no
fake can produce what `tailscale serve` produces with Kiro Crew down (§1.2):
`fake_gateway.py`'s `__restart?down=S` closes after the TLS handshake
(`:456-460`), which is an `NSURLError`; `dashboard.py` has no down mode; the
L1 `down` peer is a closed port (`testing/harness/Makefile:91`). So:

- `fake_gateway.py` gains `POST /__mode?front=502[&for=S]`: after the
  handshake (`HandshakeInThread.setup` must still run — TLS completing is
  the point), every request is answered as Go's `httputil.ReverseProxy`
  default error handler answers when its dial fails: `HTTP/1.1 502 Bad
  Gateway`, `Content-Length: 0`, no `Content-Type`, no body, the connection
  kept as HTTP/1.1 keeps it. Counted in `/__state` as `front_502`. `front=0`
  (or `for=S` elapsing) restores the gateway with its boot id, chains and
  sessions untouched — serve outlives a Kiro Crew restart and a CLI session
  is boot-unbound, so the page comes straight back on *Try again*. `down=S`
  stays: a host going away is also real, and the restart tests keep it.
- `fake_gateway.py` gains `POST /__mode?document=403[&reason=…]`: every
  document GET (a path `_is_spa_shell_request` would give the shell) is
  answered as `_deny` answers — `403`, `X-Auth-Required: true`,
  `text/html`, the "Sign in required — <reason>" page with its paste field
  (`token_auth.py:695-742`). API paths answer as before. Counted as
  `document_403`.
- `dashboard.py` (L1) gains `POST /__mode?status=502`: the same 502 shape
  for every request until `status=0`; counted per host in `/__state`.
- Each fake's self-test (`--check-bundle`, `ws_drop_probe`) gains one check:
  with the mode on, a TLS client receives exactly `502` with an empty body
  on a connection that completed the handshake.

**Why a test that waits for a spinner to appear is racy, and what these do
instead.** `waitForExistence` polls the accessibility tree; a state present
for 300 ms–2 s is missed or caught by luck, and in the other direction a
wait on a transient passes even when the state is stuck. So:

1. **Make the state last.** Stall the transport (`stall=<n>`, purgatory, the
   `slow` peer) so the state's minimum duration is known, and put the
   checkpoints inside it.
2. **Assert at absolute checkpoints**, timed from a stamp taken at the
   triggering tap, not with `waitForExistence`. At each checkpoint read
   `page-connecting-elapsed` (or the scanning row) and assert it is on
   screen **and monotonic** since the last checkpoint.
3. **"Gone" is asserted after server-side proof** the page is up (the fake
   dashboard's report, `waitForReport`), never after a sleep.
4. **"Never shown" and "shown once" read the hidden counter**
   `page-connecting-shown-count`, which catches a flash between two looks.
5. **Timing is read from the app's log** by the script, inside its log
   window, as `test-discovery.sh` does for sweeps: `page-state: … after N ms`.
6. Every checkpoint in every test below also calls
   `assertSomethingIsSaid(app)`: at least one of `page-connecting`,
   `page-holding`, `page-gateway-missing`, `nav-error-overlay`,
   `gateway-picker`, `gateway-waiting-node`, `gateway-scanning`,
   `gateway-none`, `connected-browser` **with** the fake dashboard's report,
   `logged-in-connecting`, `needs-machine-auth`, `login-button` exists.
   That is the "no state leaves only the gear" rule, enforced at every
   moment a test looks rather than in one test that looks once.

| # | Test | Suite | Asserts | Shown to fail by |
|---|---|---|---|---|
| 1 | `testStalledLoadShowsTheConnectingStateForItsWholeDuration` | L1 (`stall=22`: longer than the 20 s retry window, so — as on the device — one dial, no retry) | At 1 s, 4 s, 7 s, 11 s, 20 s after launch: `page-connecting` exists, `page-connecting-host` names `dash`, `page-connecting-elapsed` is monotonic; at 4 s the hint is **absent**, at 9 s and after **present** with `page-connecting-choose-gateway`. By 26 s `nav-error-overlay` with `nav-error-cause` containing "didn't answer on port 443 in 22 s" and `nav-error-retry`. Stub journal: **exactly one** CONNECT — the failure came after the 20 s window, so the silent retry loop did not run, which is the device's path (§1.1 step 6). Log: `page-state: failed cause=noAnswer … after 22xxx ms reply="general failure"`, and no `retrying` line. | Against today's build: nothing at any checkpoint. Then: freeze the elapsed label (monotonic fails); set the hint delay to 2 s (absent-at-4 s fails); restore the old `categorize` (the cause reads "URL format"). |
| 2 | `testSilentStartupRetriesAreVisibleAndCounted` | L1 (`blackhole=1`, refuses at once) | At 2 s, 10 s, 19 s: `page-connecting` exists, elapsed monotonic from the **first** attempt, `page-connecting-shown-count` == **1**. The log window has ≥ 5 `Startup page transport not ready; retrying` lines and ≥ 5 `page-state: connecting … attempt=N` lines. By 25 s `nav-error-overlay` with cause containing "refused the connection on port 443" (the relay's reply) and `nav-error-retry`. | Resetting `pageState` to `.idle` on each failure (count > 1, elapsed restarts); leaving it undefined across retries (absent at 10 s). |
| 3 | `testAFastLoadDoesNotLeaveTheConnectingStateOnScreen` | L1 (happy path) | After `waitForReport` shows the page up: `page-connecting` absent, `nav-error-overlay` absent, `page-connecting-shown-count` ≤ 1. | Leaving `pageState` at `.connecting` on `didCommit`. |
| 4 | `testTheErrorPageOffersRetryAndAnotherGateway` | L1 (`blackhole=1`, then `=0`) | On `nav-error-overlay`: set `blackhole=0`, tap `nav-error-retry` → the stub journal shows a **second** CONNECT after the tap and the dashboard's report arrives (server-side). Relaunch with `blackhole=1`: on the error page tap `nav-error-choose-gateway` → `gateway-picker` exists. | Removing either button; making the block non-opaque (the tap dies, M8). |
| 5 | `testMinusOneThousandIsNotAURLFormatError` | host | `PageFailureText.cause(domain: NSURLErrorDomain, code: -1000, proxyReply: nil, elapsed: 30 s)` is `.noAnswer`; with reply "connection refused" it is `.refused`; with elapsed 0.1 s and "general failure" it is `.proxyNotReady`; `.badAddress` only from the parse path. | Reverting `categorize`. |
| 6 | `testFailureTextNamesHostPortAndCause` | host | Table-driven over §4.4: each output contains the host, the port, and its row's key phrase; none contains "bad URL" or "URL format" except `.badAddress`. | Changing any row's phrase. |
| 7 | `testHoldingStateWhileThePeerListIsMissing` | L1 (fixture with an empty `Peer` map → `.checking`) | At 2 s and 5 s `page-holding` names the host; at 16 s `page-holding-hint` exists; `nav-error-overlay` never appears; the log has `page-state: holding`. (The "leaves" edge is pinned in 11.) | Against today's build: blank at every checkpoint. |
| 8 | `testAScanShowsProgressForItsWholeDuration` | discovery | First-run picker, `gw` present, `slow` peer (4 s timeout, so the sweep lasts ~4 s). At 1 s: `gateway-scanning` exists with "of 4 done" and k ≥ 1; at 3 s: k ≥ 3, seconds monotonic; `gateway-refresh` label "Searching…" and disabled. After `gateway-sweep-done`: row absent, label `sweep-done:1:2:2`. The sweep-signature log lines are unchanged (the script's check still passes). | Against today's build: `gateway-searching` has no count and vanishes when `gw` answers (< 1 s), so the 3 s checkpoint fails. |
| 9 | `testSearchAgainShowsProgressWithRowsListed` | discovery | Via the unreachable-banner Find sheet (`autoSelectSingle: false`, as `testFindFromTheUnreachableBannerSwitchesGateway`): once `gateway-gw.tail-scale.ts.net` is listed, tap `gateway-refresh`; within 500 ms `gateway-scanning` exists **while the row is still listed**; it is gone after `gateway-sweep-done`. | Restoring the `gateways.isEmpty` condition (`GatewayPickerView.swift:48`). |
| 10 | `testDeviceCheckRehearsalPurgatoryThenAddressMove` (**extended**) | discovery | In purgatory: the first-run sweep ends with `gateway-none` reading "Checked 4 computers in 4 s. 0 answered…; 4 didn't answer at all." and `gateway-none-hint` naming Settings → Status. Then **enter `gw` manually — Olof's exact case**: at 1 s, 8 s, 20 s, 29 s `page-connecting` exists, elapsed monotonic, hint present from 8 s; by 35 s `nav-error-overlay` with cause "didn't answer on port 443 in 30 s" and the address hint; the harness journal shows **no** accept at `gw` from the app node; log `page-state: failed cause=noAnswer … after ≥ 29000 ms`. Tap `nav-error-choose-gateway` → the picker sheet; **then** `/move`; Search again lists `gw`; choose it; the token sheet opens with no navigation error (the existing tail of the test). The script's rule that the all-failed purgatory sweep happens **exactly once** still holds: the manual entry is a page load, not a sweep. | Against today's build: blank for 30 s then "URL format error" with no button — every checkpoint fails. |
| 11 | `testTheChosenGatewayPersistsAcrossRelaunch` (**one assertion added**) | discovery | Once `token-sheet` is up after the relaunch, `page-holding` and `page-connecting` are absent and the log has `page-state: committed`. | Leaving `.holding` set when `loadInitial` finally loads. |
| 12 | `testAPaintedDashboardNeverShowsTheConnectingState` | session | With the real bundle live: read `page-connecting-shown-count` after the first paint (c₀ ≤ 1); through the page's own WebSocket reconnect (`/__drop_ws`), its refetches and a sign-in navigation, the count stays c₀ and `page-connecting` is absent. | Driving `pageState` from `isLoading` KVO or from `didStartProvisionalNavigation`. |
| 13 | `testASlowGatewayShowsConnectingUntilItsTimeout` | discovery | Manual entry of `slow` (accepts on 443, never answers): `page-connecting` at 1 s, 10 s, 20 s with elapsed monotonic; the test terminates the app at 25 s (WebKit's own timeout for this shape is not yet measured; §8). | Against today's build: blank. |
| 14 | Lifecycle | lifecycle | No new test; the suite must stay green. A frozen process resumes with a larger elapsed number, and the R30 relay restart's reload (`applyProxy` → `reload`) moves `.failed` → `.connecting` again, incrementing the counter legitimately. | — |
| 15 | `testAGatewayAnswering502ShowsTheFailureNotABlankPage` | session (`front=502`) | Sign in with a CLI link (boot-unbound, as `testACLISessionSurvivesAGatewayRestart`). `POST /__mode?front=502`. Relaunch — the app's own startup load, as a phone returning to a restarting gateway. At **3 s**: `nav-error-overlay` exists; `nav-error-title` is "Couldn't reach Kiro Crew on gw"; `nav-error-cause` contains "502"; `nav-error-retry` exists; `page-connecting-shown-count` ≤ 1. `/__state` `front_502` ≥ 1. Log: `page-state: refused status=502 after N ms` with N < 3000, `RESP-LOG response: 502` (`-UITestLogResponses`), and **no** `Navigation interrupted by policy` line; the page contains no "redirected". Hold to **13 s**: the overlay is still up and `front_502` has **not grown** — no silent retry. `POST /__mode?front=0`, tap `nav-error-retry` → within 15 s `nav-error-overlay` is gone and `auth_me_ok` has grown (the session survived; server-side proof). | Against today's build: nothing at 3 s or 13 s — the 502 committed and the screen is blank (`assertSomethingIsSaid` fails). Then: drop the `refusedResponse` check in `handlePolicyInterruption` (the title reads "Couldn't open gw here" and the cause "redirected", `:863`); make `ResponsePolicy` commit 5xx (blank again); route a refusal through `retryStartupLoadIfAppropriate` (`front_502` grows by ≥ 5 in 10 s). |
| 16 | `testAGatewayThatSays403CommitsAndSignInSaysWhy` | session (`document=403`) | Launch; `token-sheet` is up (the shell's own `mc-auth-required`, as today). `POST /__mode?document=403&reason=link+bound+to+another+device`. Paste a CLI link: the redemption navigates to `/?token=…` and the fake answers `403` + `X-Auth-Required` with its sign-in page. Within **5 s**: `token-sheet-message` reads "That sign-in link didn't work…" (`SessionManager.swift:324`) — **not** "Couldn't reach the gateway to sign in" (`:190`); `nav-error-overlay` never appears; `app.webViews.staticTexts` contains "Sign in required"; log `page-state: committed status=403 auth-required` and `RESP-LOG response: 403`; `/__state` `document_403` ≥ 1. `POST /__mode?document=0`, paste a fresh link → the dashboard paints (`auth_me_ok` grows). | Make `ResponsePolicy` refuse 403 (or every 4xx): the message becomes "Couldn't reach the gateway to sign in" and `nav-error-overlay` appears. Today's build commits everything, so this test passes on it: it is the guard that keeps the new rule from widening, shown able to fail by the rule's inversion. |
| 17 | `testA502InL1IsRefusedAndTryAgainRecovers` | L1 (`status=502`) | `POST <dashboard control>/__mode?status=502`; launch against `dash`. By **3 s** `nav-error-overlay`, `nav-error-cause` containing "502" and an elapsed time under 3 s, `nav-error-retry`. The stub journal has a CONNECT for `dash…:443` and **no** `upstream_fail`; the dashboard's `requests[dash]` ≥ 1 — the request *reached* the gateway, which is what separates this from every existing "down" test (`assertZeroRequests` is deliberately not asserted). `POST …?status=0`, tap `nav-error-retry` → `waitForReport` shows "FAKE DASHBOARD" (server-side proof), `nav-error-overlay` gone. | Against today's build: `assertErrorPage`'s 40 s wait (`OfflineHarnessTests.swift:324-328`) expires with a blank screen. Then: commit 5xx (same). |
| 18 | `testResponsePolicyDecidesByStatusAloneInTheMainFrame` | host (`test-navigation-policy.sh`) | Table-driven over §4.13: sub-frame 502 → commit; nil status → commit; 200, 204, 301, 302, 304, 401, 403 (header either way), 404 → commit; 500, 502, 503, 504 → refuse; 502 with `X-Auth-Required: true` → commit. | Change any row; in particular refusing 304 or 403 fails at once. |

### 6.1 As built (2026-09-24) — corrections from running tests 1–4

- **"Exactly one CONNECT" is wrong**, and so is predicting the elapsed number.
  WebKit issues **more than one dial within a single navigation**: measured, a
  22 s stall produced 2 CONNECTs and the navigation failed at ~31 s, not 22 s.
  Test 1 therefore asserts what the rule is actually about — the app's own
  silent-retry loop did not run past its 20 s window, which would have produced
  upwards of twenty CONNECTs at one a second — and reads the duration out of the
  sentence rather than predicting it.
- **Reset harness modes in `setUp`, not only in a teardown block.** The stall
  test hung on its first run; XCTest killed it and restarted the runner, its
  `addTeardownBlock` never ran, and `stall=22` leaked into every later test in
  the file — two of which then failed for a reason that had nothing to do with
  them. `setUp` now clears `stall`, `blackhole` and the dashboard's `front`, so a
  test that dies cannot poison its successors. (This is the same shape as the
  earlier `__mode` finding: a control call whose effect outlives the test that
  made it.)
- **An accessibility modifier on a container can absorb its children.** With
  `.accessibilityIdentifier` alone on the `Waiting` stack, `page-connecting` was
  findable and `page-connecting-host` was **not**. It needs
  `.accessibilityElement(children: .contain)` beside it. A §4.12 identifier that
  exists in the source and not in the tree is not a contract.
- **`makeWebView` runs inside SwiftUI's view update**, so publishing the page
  state from the load it starts produced "Publishing changes from within view
  updates is not allowed, this will cause undefined behavior" — once per launch,
  in every test, and absent from every run before this feature. The load still
  starts synchronously; only the announcement is deferred a tick, and only if
  nothing else has moved the state meanwhile.
- Checkpoint tests set `continueAfterFailure = true`: the point of five
  checkpoints over 20 s is to see the whole picture, and stopping at the first
  bad one hides the rest — including whether the failure recovers.

Gate states G2/G6 have no harness that can hold the node in `Starting` or
`Stopped` today; the `StalledHint` threshold logic is pure and covered by a
host check, and the gate text is confirmed on the device (§8). Said plainly
rather than pretended.

## 7. Acceptance criteria

Each with its instrument.

1. **No bare screen.** In every test above, `assertSomethingIsSaid` holds at
   every checkpoint — *XCUITest*. On the device, a screenshot at 1 s, 8 s
   and 30 s after a manual entry to a gateway the node cannot reach shows the
   block, the hint and the error page respectively — *`make look` / a photo*.
2. **The connecting block appears within 300 ms + one render of a load that
   has not committed, survives the silent retries with its clock running from
   the first attempt, and is gone on commit** — tests 1, 2, 3; the log's
   `page-state:` lines with elapsed ms, checked by the script.
3. **The failure names host, port, elapsed time and the most likely cause,
   and offers Try again and Choose another gateway** — tests 1, 2, 4, 5, 6,
   10; the relay's reply name appears in `nav-error-details` — *accessibility
   tree + app log*.
4. **A SOCKS failure is never labelled a URL format error** — tests 1, 5, 6.
5. **A sweep is visibly in progress for its whole duration, including a
   re-scan with rows listed, with a count that moves and seconds that tick;
   its end names answered and unanswered and, when nothing answered, the
   likely cause** — tests 8, 9, 10; `sweep-done:<g>:<a>:<u>`;
   `picker-state:` log lines; the script's existing sweep-signature check
   still passes unchanged.
6. **The picker never shows a disabled Search again with no explanation** —
   `gateway-waiting-node` exists whenever `ready == false` (test 8's first
   look, before the node's status; and the log's `picker-state:
   waiting-node`).
7. **The owner can always reach the picker without Settings**: from the
   connecting hint, the error page, the banner — tests 4, 10.
8. **Nothing is covered that was painted** — test 12, counter unchanged
   through a reconnect.
9. **Suites green:** host, L1, L2, discovery, session, lifecycle; the
   discovery script's timing rules unchanged and passing.
10. **D1:** `scripts/check-no-log-upload.sh` unchanged and green; nothing new
    writes off-device.
11. **A main-frame 5xx never commits as the document**; within 3 s the
    failure names the host, the status and the elapsed time and offers Try
    again — tests 15, 17, 18; `page-state: refused status=<n>`; the fakes'
    `front_502` counters — *accessibility tree + app log + `/__state`*.
12. **A main-frame `403` + `X-Auth-Required` always commits, and a refused
    sign-in says the link was refused, not that the gateway was
    unreachable** — tests 16, 18; `page-state: committed status=403
    auth-required`.

## 8. Open questions and owner actions

Only Olof can answer these; nothing in §4 waits on them.

1. **Which field did you type `byskebox` into** — the picker's *Enter
   manually*, or Settings → Gateway? Both reach `selectGateway`; the answer
   only confirms the trace in §1.1.
2. **Did you wait ~30 s** and see "Unable to Load Page / URL format error",
   or leave before it? If you saw it, the label's wrongness is confirmed on
   the device as well as in the code.
3. **The hint's tone.** "whoever manages the tailnet needs this device's
   address" is written for the one tailnet you manage yourself; say if it
   should be blunter ("you haven't granted this device access yet").
4. **Choose another gateway at 8 s** — offered during the wait, or only
   after the failure? Specified: during (from 8 s). Say if that invites
   abandoning loads that would have succeeded.
5. **Tailnet lock.** DECISIONS' open question stands: should Status say
   "locked out" from the node's own tailnet-lock field? It is one more way
   for "nothing answers at all" to happen; the P4 hint would then name it.
   Not in this feature unless you say so.
6. **Device confirmation** of G2/G6 wording, which no harness can drive.
7. **Was the blank ever quick?** The device log pins the 30 s path for the
   run you reported (the dial deadline). D10 produces the same blank in
   about a second — a Kiro Crew restart on byskebox at the moment of a load.
   If you have seen the blank appear *fast*, that was D10. Once this lands
   the tell in Settings → Logs is `page-state: refused status=502`; today the
   tell is that the log shows a successful connect and then nothing at all.

## 9. Log

- 2026-09-23: specified, superseding F2. The bugfix Olof asked for in the
  same message — the probe timeout — landed separately as R39 (4 s per
  probe, 12 s per sweep; app `8a5220b51`), because it needed no UI work.
- 2026-09-23, design pass: every state enumerated from the code (§2). The
  first draft's diagnosis was wrong: the blank screen was the plain
  connecting state for the full 30 s SOCKS dial (`socks5.go:99`), not the
  20 s silent-retry loop, which cannot fire on a dial that long. Case C (a
  dismissed picker sheet over emptiness) does not exist and was dropped. New
  findings: the error page labels every SOCKS failure "URL format error" and
  has no buttons at all on a phone; the picker shows a disabled button and
  nothing else before the node's status; a re-scan shows nothing. Timing
  thresholds fixed (§4.1), failure wording fixed (§4.4), tests rewritten
  around checkpoints and counters rather than waits for transients (§6).
- 2026-09-23, amendment (same day): **a second path to the same blank
  screen**, missed by the design pass. `decidePolicyFor navigationResponse`
  (`BrowserViewModel.swift:744-754`) commits every status, and `tailscale
  serve`'s reverse proxy has no error handler (`serve.go:959-994`), so a
  Kiro Crew restart answers 502 on a live port 443: TCP and TLS succeed, no
  `NSURLError`, the relay renders no verdict, an empty body commits. Reached
  in about a second, not 30, and unbounded. No suite could see it: the
  fakes' "down" closes the connection after TLS (`fake_gateway.py:456-460`),
  which *is* an `NSURLError`, and L1's `down` peer is a closed port —
  measured both ways today. Added: D10 and D11 (§2), the response rule
  (§4.13, `ResponsePolicy` in `NavigationPolicy.swift`), `.gatewayError` and
  its wording (§4.2, §4.4), the `handlePolicyInterruption` ordering and the
  no-silent-retry rule (§4.3), tests 15–18 and the harness change (§6),
  criteria 11–12 (§7), question 7 (§8). The `categorize` label fix (-1000 is
  `.retrieval` unless from the parse path) landed as `8b0933d` while this
  amendment was being written, and already uses §3.2's titles ("Couldn't
  reach <host>" / "Latchkey can't open this address") through
  `NavErrorKind.caption(host:)`; §4.3 states the same rule. An earlier
  draft of this entry called the interim label "Connection error"; that was
  the label before `8b0933d`, not after.
