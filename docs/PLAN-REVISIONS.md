# Latchkey — plan revisions (2026-09-20)

**For the session implementing `~/src/latchkey/docs/PLAN.md`.**

These revisions come out of an adversarial review of the plan. Full findings, with evidence
(file:line, executed tests), are in `~/.kiro/crew/workspace/latchkey-plan-review-2026-09-20.md`
(outside this repo); the IDs in brackets (B1, H3, M7…) point there.

## How to apply

1. **Do not stop current work to apply these.** Apply each revision before the milestone it is filed under.
2. **Check before changing.** Some revisions touch M0/M1 code you may already have written. For every
   revision marked **CHECK-FIRST**, verify the current state; if it is already satisfied, record that and move on.
3. **Record every adopted revision in `docs/DECISIONS.md`** (one line each is fine for small ones), and update
   the affected PLAN.md sections as you reach them. Where a revision contradicts PLAN.md, the revision wins.
4. Items in **§C are owner actions** — things only Olof can do. Where a revision depends on one, it says so.
   Stop and ask rather than working around a missing owner action.

---

## A. Owner decisions (context — do not re-litigate)

| # | Decision |
|---|---|
| D1 | **Log upload off.** No app or tsnet logs go to Tailscale's hosted logtail. On-device logs stay, with URLs redacted. |
| D2 | **Vendor libtailscale as plain source**, via one clean, import-only commit first. All modifications are later, separate commits. |
| D3 | **First token: both paths.** Paste from the Mac (primary; CLI links survive gateway restarts) and QR scan (convenience). |
| D4 | **chonk is out of v1.** v1 targets byskebox only. **Superseded 2026-09-23** (`DECISIONS.md`, "D4 superseded"): chonk already had `tailscale serve` on 443 in front of its loopback-only dashboard, so it is a usable HTTPS gateway, as is box; the grant covers all three. Where R26 and R28 below cite D4, the mechanism they built stands on its other grounds (https-only discovery, the dashboard's own origin check). |
| D5 | **User-owned node, "admin purgatory" tailnet policy.** The node logs in as `owner@example.com` (so KiroCrew sees his login). The tailnet policy gives full access only to chonk and air by name; every new admin-owned device lands in a purgatory address pool with no grants, and gets access only when an admin moves its address into a category range — for Latchkey, `kiro-clients` → `byskebox:443`. Applied by an agent in Olof's infra workspace. See §C O3/O3b. |
| D6 | **No notifications in v1.** The deep-link interim is dropped. |
| D7 | **Tests must run with the Mac's own Tailscale up.** chonk is always on the tailnet. Leak coverage for tailnet *IP* destinations is accepted as weaker. |
| D8 | **Keep node key expiry** (180-day default); the app warns before it lapses. |
| D9 | **byskebox identity-trust state is unknown** — an owner check step is added (§C O4). |
| D10 | **Authenticated tests use a fake backend serving KiroCrew's real 0.6.0 frontend.** No Dev Fleet app, no KiroCrew pods, no building KiroCrew from source. A real gateway is exercised only by an owner-run contract check (§C O7). |

---

## B. Revisions by milestone

### Now — alongside M1

**R1 — Turn off log upload; redact URLs everywhere** [H1, D1] — CHECK-FIRST
- Remove the app-log mirror into logtail (`TailscaleLogging.log(message)`, the fourth sink in `TSNet/Logging.swift`'s `Logger.log`).
- Disable tsnet/libtailscale's own backend log upload as well. Find the cleanest switch (not calling the logtail setup, or an env knob such as `TS_NO_LOGS_NO_SUPPORT` if the vendored code honours it). Changes inside libtailscale go in a post-import commit (R16).
- Keep `print`, `os_log` and `LogRing` on-device.
- Add `URL.redactedForLog` (scheme + host + path, never query) and use it at every log site that prints a URL, including `BrowserViewModel` `:296, :300, :399, :476, :517, :530` and the `RESP-LOG` lines `:688, :699`, plus `SocksLogProxy` CONNECT lines.
- **AC:** a 5-minute simulator session makes no connection to `log.tailscale.io`; `grep -r 'token=' ` over the app container's logs finds nothing.

**R2 — Never persist or replay the token URL** [H1] — CHECK-FIRST
- Do not save the tab URL (`tabs.json` via `TabManager`/`WorkspaceStore.saveTabs`). Cold start always opens the gateway origin.
- After a `?token=` redemption completes, strip the query from the page URL (page-world `history.replaceState`) so it is not in history or restorable.

**R3 — Lock navigation to the gateway origin** [H2] — CHECK-FIRST
- Main-frame navigations: allow only the selected gateway origin (scheme + host + port). Everything else opens outside the app (`SFSafariViewController` or `UIApplication.open`).
- Handle `createWebViewWith` the same way (it currently opens anything).
- Leave sub-frame navigations alone — the dashboard uses same-origin `/sandbox-doc/` iframes for widgets. Verify nothing it needs is cross-origin.
- Register the production JS bridge (M4.2) with `forMainFrameOnly: true` and act on a message only when `frameInfo.securityOrigin` matches the gateway. Before changing upstream's existing focus script (`forMainFrameOnly: false`), find out why it is false.

**R4 — Kill the exit-node trap** [review M7] — CHECK-FIRST (M1.8 may have covered it)
- `proxyEverythingRequested()` must return false in production even if `prefs.ExitNodeID` is saved; otherwise the dashboard's public CDN assets and fonts get routed through the proxy and fail with `-1000`.
- Keep `-ProxyEverything` only as a test hook (R15).

**R5 — Exclude secrets from backup; device-only Keychain** [review M1]
- At launch, set `isExcludedFromBackup` on the workspace state directory under Application Support (node keys) and on the WebKit data directory (`Library/WebKit`, the refresh cookie).
- Any Keychain item uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- Drop the Keychain "redemption marker" from M4.6 — Keychain survives uninstall but cookies don't, so it desyncs. Derive session state from the page and `/api/auth/me`.

**R6 — Name the node deliberately, before first redemption** [review M2, H7]
- Set a real hostname in `WorkspaceStore.makeDefault()` instead of `aperture-NNNNNN` (suggest `latchkey-iphone`; confirm with Olof).
- KiroCrew pins identity-bound sessions to `login|node name`, so renaming the node after signing in signs the app out. Name first.
- Keep `ephemeral` off.

**R7 — Recover from web content process termination** [H10]
- Upstream turns `webViewWebContentProcessDidTerminate` (`BrowserViewModel.swift:738`) into a `cannotLoadFromNetwork` error page and never reloads — a routine memory kill looks like a tailnet outage.
- If active: `reload()`, at most 2 per 60 s. If backgrounded: set a flag, reload on `scenePhase == .active`. Count it separately in diagnostics.

**R8 — Move device bring-up before the M1 device check** [B3]
- The M1 AC device check needs §C O1, O2, O3, O3b and O5 done first, in that order: the node must be moved out of purgatory (O3b) before the first token is redeemed. Do not attempt it before they are. If the app sits at "connected" but the dashboard never loads, check O3b first.
- Enter the first token through the **dashboard's own red paste banner** — it accepts a full URL or a bare token — so the check does not wait for M4.
- Add `NSLocalNetworkUsageDescription` to `Info.plist`. In the device check, test with Local Network permission both allowed and denied (upstream ties `-1000` behaviour to it). [review M9]
- Record the phone's iOS version in DECISIONS (#9399 was reported on 26.6.1).

### Before M2

**R9 — Prove `xcodebuild test` works from your shell, first** [H12]
- One trivial UI test via `xcodebuild test` from the agent shell, reusing the `NESTED_SANDBOX` detection. It needs the test runner launch, CoreSimulator and testmanagerd.
- If it fails, stop and report — do not build M2 on it. The fallback is "tests are run from a normal Terminal", recorded in DECISIONS.

**R10 — Rebuild the anti-leak test so it can actually detect a leak, with Tailscale up** [H3, D7]
- `dash.tail-scale.ts.net` is NXDOMAIN, so a leaked direct connection fails the same as a proxied one — the current negative test proves nothing.
- Serve the negative-test origin on a **publicly resolvable loopback name**. `dash.localtest.me` resolves to loopback on chonk; note it returns `::1` as well as `127.0.0.1`, so bind the test server on both families. Add it to the leaf cert's SAN.
- Sequence: (1) **positive control** — prove a direct load of that origin succeeds without the proxy; (2) `--blackhole` run — assert the load fails, the stub journal shows the `connect`, and `dashboard.py` received **zero** requests. Add variants with the stub killed and with `-NoSocksLog` (with the relay on, WebKit always talks to an in-app listener, which masks the proxy-unreachable path).
- **Never use a real tailnet's `*.ts.net` names or real tailnet `100.x` addresses in any test** — on a Mac running Tailscale they route through the host's own VPN and a leak would *succeed*. Only the fixture tailnets (`tail-scale.ts.net`, `example.ts.net`) may appear.
- Preflight in every simulator test script: **warn** (not fail) when host Tailscale is up, and fail if the test config names any tailnet that is not a fixture tailnet (`scripts/check-fixture-tailnets.sh`). Record in DECISIONS that tailnet-IP leak coverage is limited on this host.

**R11 — Test override must exercise the production path** [H4]
- An endpoint-only override never loads: `loadInitial()` waits for `.Running` and for `localStatus`, and `TailnetProxyPolicy.make(from: nil)` yields IP ranges only.
- Add `-TestStatusFixture <file.json>` (an `IpnState.Status` with `MagicDNSSuffix` and a peer `DNSName`) and synthesize `.Running`, so the real `proxyConfig()`, policy, `HomePageAvailability` and `hasPeerData` run.
- Add a split-tunnel assertion: a non-tailnet resource loads direct and never appears in the stub journal.

**R12 — Make the proxy config unit-testable** [H3]
- Move the `ProxyConfiguration` construction out of `TSNetManager` into a pure factory, so the L0 test asserts `allowFailover == false` and the `matchDomains` content on the **app's own** object, not Apple's default.

**R13 — One observation channel for tests: server-side, not accessibility** [review M10]
- Replace the M2.8 hidden-view `accessibilityValue` bridge: the harness page reports its state to `dashboard.py` (`POST /__report`), and the test reads `GET http://127.0.0.1:<port>/__state`. IP literals are exempt from ATS.
- For M4, assert on the native token sheet, which is a real accessibility element.

**R14 — Put recovery tests at the right layer** [review M11]
- Stub-killed (M6.7) never triggers `recoverLoopbackAfterFailure`; that is driven by LocalAPI poll failures. Test recovery at L2 with upstream's `-UITestDefunctLoopback` and `-UITestShutdownTCPConnections`.
- M6.5 is wrong that there is no CLI path to suspend: upstream's `scripts/test-lock-resume.sh` uses SIGSTOP. Use it.

**R15 — Gate test hooks on a dedicated compile flag, not `DEBUG`** [review L]
- The daily driver is installed with Xcode Run, i.e. usually a Debug build. Gate every test hook — new ones and upstream's `-AuthKey`/`APERTURE_AUTHKEY`, `-ProxyEverything`, `-UITestLogResponses`, `-UITestReset*` — on a `LATCHKEY_TEST_HOOKS` flag set only in the test configuration.
- Consider building the daily driver in the Release configuration.

### Before M3

**R16 — Vendor libtailscale as plain source** [H11, D2]
- **Commit 1 (import-only):** replace the `ThirdParty/libtailscale` submodule and its nested `tailscale-patched` submodule with plain source, byte-for-byte at `f55900d2efb7ccc327a9ac07779b92767c1e48ab` and `b5adfd852c01a53025cbacc0727789984ffbf427`. Remove the gitlinks and `.gitmodules` entries. Add `ThirdParty/VENDORED.md` recording source repo URLs, both SHAs, and how to diff against upstream. **Nothing else in this commit** — no build fixes, no Makefile edits.
- **Commit 2+:** anything needed to build again (e.g. `scripts/bootstrap.sh` submodule logic), then any real modifications, each its own commit.
- The absolute-URL `.gitmodules` workaround and `git subtrac` become moot; remove references to them.
- Upstream tracking is **cherry-pick only**, from `TSNet/` and the vendored tree. Record the last upstream SHA reviewed in DECISIONS. Put new code in `App/`, not `TSNet/`.

**R17 — Replace M3's in-process control plane with a host-side harness** [B2, D7]
- M3.1/M3.3/M3.6 cannot work: `controlhttpserver` is `//go:build !ios`, so `libtstestcontrol.a` won't build for the simulator; libtailscale's XCTest target is macOS-only; the shim's shadowed variable means `stop_control` never stops.
- Build `testing/tsnet-harness/`: a host Go binary running `testcontrol.Server` (`MagicDNSDomain: "tail-scale.ts.net"`, `DNSConfig: {Proxied: true}`), DERP/STUN bound to `127.0.0.1`, and N tsnet peers — one reverse-proxying to `dashboard.py` over HTTPS with a test-CA leaf for `*.tail-scale.ts.net`. It prints its control URL. The simulator shares host loopback.
- **A working ~80-line proof of concept** (testcontrol + a tsnet node serving HTTP + a tsnet "app" node; a page fetched by MagicDNS name through the app node's loopback SOCKS5) is at `~/.kiro/crew/workspace/latchkey-review-artifacts/hostctl-poc/main.go`. Start from it.
- Add a `-TestControlURL` launch argument (behind `LATCHKEY_TEST_HOOKS`) that overrides `WorkspaceDefinition.controlURL` — none exists today; it is persisted and defaults to `kDefaultControlURL`.
- Cover login with `RequireAuth` plus `CompleteAuth`, and device approval with `RequireMachineAuth` (the app must handle `NeedsMachineAuth`, which `App/` currently never does).
- The harness's `100.64.x` addresses live in userspace netstacks, so they do not collide with the host's real tailnet routes. Verify that once, then record it.

**R18 — `statusJSON()` does not exist in the vendored revision** [B1]
- Remove every reliance on `TailscaleNode.statusJSON()`. It and `tailscale_status_json` exist only in libtailscale `main`, which lacks `restartLoopback`.
- **Peers** come from `tsnetModel.localStatus`, already polled via `LocalAPIClient.backendStatus()` — the same data `TailnetProxyPolicy.make(from:)` uses.
- **Liveness** stays on the loopback status poll. M6.2 as written is inverted: the loopback listener serves both SOCKS5 and LocalAPI, so the loopback poll failing is exactly the signal that the proxy is dead.
- Porting `TsnetStatusJSON` (~30 lines from main) is optional and, if done, is a post-import commit.
- Re-check every libtailscale line reference in PLAN.md against the vendored tree; §3.2, §3.4 and M3 cite `main`.

### Before M4

**R19 — Test against KiroCrew's real frontend** [H5]
- The refresh logic and `mc-auth-*` events exist only in KiroCrew's real bundles; testing against `dashboard.py`'s own page is circular.
- Serve the real `kiro_crew/static/dist` (from `~/.kiro/crew-venv/lib/python3.12/site-packages/kiro_crew/static/dist`) from the fake backend. Pin the KiroCrew version and bundle hash; fail on mismatch.
- The fake backend must match real behaviour: stale session → **403 with `X-Auth-Required: true`** (not 401), refresh rotation, `401 refresh_chain_revoked` clearing the refresh cookie, cookie names `mc_token_5476` / `mc_refresh_5476` (listen port, since a serve Host header carries none).
- Add a smoke test that fails if the `mc-auth-required`/`mc-auth-cleared` events or `#mc-session-expired` disappear from the bundle.
- **Contract test against a real gateway is owner-run** (§C O7, D10): the agent shell is policy-blocked from minting KiroCrew tokens, and KiroCrew pods are out of scope, so no real-gateway test can be automated. Write `testing/harness/contract_test.py` so Olof can run it with a token he mints. It replays redeem → expire → 403+header → rotate → reuse the superseded refresh token (→ 401) and diffs statuses, headers and cookie attributes against the fake. Constraints: it takes the token from a file or env var, never an argument that lands in shell history; it runs against a gateway on the **same KiroCrew version as byskebox**; it uses its own fresh session (never the phone's) — the reuse step revokes that one chain on purpose; and it stays far below the refresh endpoint's shared 60/min rate limit.
- Do not reach for KiroCrew's own test harness (`gateway --test-mode`, `spawn_feature_gateway`, in-process `generate_token`) or its pods: they run product code that mints credentials, which the local policy blocks and D10 rules out.

**R20 — Drop the foreground nudge** [H6]
- M4.7 cannot work: the page's 403→refresh interceptor runs only inside its own API wrappers, not `window.fetch`; a native `URLSession` has neither the WKWebView's cookies nor the proxy.
- It is also unnecessary: the page refreshes proactively ~1 h before `session_exp`, defers while hidden and fires on `visibilitychange`, retries at 60 s / 4 min / 16 min / 1 h, and a 30 s approvals poll goes through the interceptor.
- Delete M4.7 and M6.3's `SessionManager.refreshIfNeeded()`. Fix the leftover "refresh loop" text in the §3.1 diagram and the §3.3 flow.
- Only if M6 measurements show a real gap: run page-world JS that fetches `/api/auth/me` and calls `location.reload()` on 401 or 403+`X-Auth-Required`, letting the page's own refresh run. Never call `/api/auth/refresh` from the app — behind `tailscale serve` every client shares one 60/min rate-limit bucket.

**R21 — Correct the auth event semantics** [review M3]
- Go to `needsToken` on `mc-auth-required`.
- `mc-auth-cleared` does **not** mean healthy — it fires when the banner is dismissed, and a silent refresh fires nothing. Return to `active` only after a `?token=` navigation completes or a page-world `/api/auth/me` returns 200.
- Treat the stale-owner banner as `needsToken`. On a revoked chain the page's proactive path does `location.assign('/')`, and `mc-auth-required` fires after that reload — make sure the bridge is present on it.
- Inject the bridge at document start, main frame only, so it is re-injected on every navigation.

**R22 — Hide the page's banner with CSS only** [review M4]
- Inject `#mc-session-expired{display:none!important}` at document start (also blocks its input from autofocusing and popping the keyboard). Never remove the element and never click its ✕ — a startup gate reads it and ✕ clears latches.
- Add a bridge ready-handshake; if it does not arrive within N seconds, leave the banner visible as the fallback.

**R23 — Token entry: paste and QR, safely** [review M5, D3]
- CLI output contains up to three URLs (localhost, `dashboard.url`, tailnet), so `new URL(paste)` fails on a multi-line paste. Extract the first `token=([^&\s]+)` with a regex.
- Always navigate to the **selected gateway's** origin. Accept a pasted host only if it is a known gateway (anti-QR-phishing); otherwise treat the input as a bare token for the current gateway, and show the target host before navigating. Tokens are signed per gateway.
- Use `PasteButton`/`UIPasteControl`, not a silent clipboard read. After a successful redemption, clear the clipboard only if it still holds that exact string (Universal Clipboard syncs it to every device).
- QR scan (D3): `AVCaptureSession` + `NSCameraUsageDescription`. The Phone-access QR payload is `https://<gateway>/?token=…`; run it through the same parser and host check.

**R24 — Fix the restart story** [H7, D3]
- CLI links (`kirocrew token` → `GET /api/token/local`) carry no `boot` claim, so their sessions and 30-day refresh chains **already survive gateway restarts**. Only QR-minted sessions are boot-bound by default.
- Rewrite §1.1/§3.3: the real remaining friction is getting the first token onto the phone, not restarts.
- M4.9 gets two cases: a CLI-shaped session survives a boot-id change with no sheet; a boot-claimed (QR) session shows the sheet.
- M7.5 becomes **optional, QR users only**, and must list its real preconditions: `trust_identity` on with non-empty `allowed_logins`, `qr_session_until_restart` still true, *and* the QR generated from an unbounded desktop session. It depends on §C O4, needs Olof's consent and a rollback note, and must keep `pin_scope: node`. Name the node first (R6).

**R25 — Make M4's acceptance criteria non-vacuous** [review M10]
- "10 minutes without the sheet" passes if the page makes no API calls. Drive periodic SPA API traffic and assert a minimum number of successful rotations.
- Against the real bundle, `--expire-in 60` makes the scheduler refresh about every 5 s (it aims for `exp − 1 h`, floored at 5 s). Choose an expiry that yields a countable number of rotations.
- The real hazard is sequential reuse of a superseded refresh token, not only overlap. Have the fake track refresh-token lineage and fail on any superseded token outside the grace window.

**R38 — Copy KiroCrew's own test patterns** [research follow-up, D10]
KiroCrew's end-to-end suite (`website/playwright/auth.setup.ts` in kirodotdev/KiroCrew) solves the same problems. Adopt its patterns; none needs product code:
- **Redeem once, reuse cookies.** Load `/?token=…` a single time, then reuse the `WKWebsiteDataStore`'s `mc_token_<port>` / `mc_refresh_<port>` cookies across tests.
- **Skip the first-run overlay** by presetting `localStorage` `mc-onboarded=1` before the dashboard loads.
- **One cookie store per gateway port** — cookie names include the port, and upstream records races when runs share a store.
- **Assert sign-in by API, never by rendering.** The dashboard shell returns 200 even when signed out. Check that page-world `GET /api/auth/me` (or `/api/sessions`) returns 200 when signed in and 403 when not.
- **Use upstream's frontend auth tests as the spec for the fake backend** — `src/hooks/useRefreshScheduler.ts`, `src/api/refreshOnce.ts`, `src/test/clientAuthRecovery.test.ts`, `src/test/staleOwnerSession.test.ts` — **read at the tag matching the installed 0.6.0, not `main`**. They already differ: upstream `main` describes refreshing on a 401 from `/api/auth/me`, while the 0.6.0 bundle refreshes on 403 + `X-Auth-Required`. When they disagree, the installed bundle wins.
- **No recorded fixtures exist upstream** (no HAR files, no `/api/auth` or `/api/ws` mocks). If replay fixtures help, record them from an O7 contract-test run and scrub every credential before committing.
- Upstream has **no WebKit coverage** at all (Chromium only, "mobile" = Chromium with an iPhone user agent). Latchkey's WKWebView tests are the only WebKit coverage of the dashboard — treat a WebKit-only failure as possibly KiroCrew's bug (#9399-style), not automatically the app's.
- Optional: the installed `ios-simulator-preview` skill (`~/.kiro/crew/skills/ios-simulator-preview/SKILL.md`) mirrors the live Simulator into the dashboard's Browser panel, so Olof can watch test runs.

### Before M5

**R26 — Discovery: https only, byskebox-first** [H8, H9, D4, D5]
- Delete the `http://<host>:5476` probe. chonk's dashboard listens on `127.0.0.1` only, a plain-http origin fails the required `/api/ws` origin check, and HSTS (`includeSubDomains`) upgrades it after any https visit. chonk is out of v1 (D4); remove it from M7.6 and all ACs. *(D4 has since been superseded — chonk is served on 443 and is a gateway like any other; the http probe stays dropped on the first two grounds.)*
- Probe the saved gateway first. Filter candidates to `Online`, not `Expired`, not `ShareeNode`, `OS` in {linux, macOS, windows}, owned by the same user. `OS`/`UserID` are not decoded by the vendored TailscaleKit (`LocalAPI/Types.swift`) — add them in a post-import commit.
- 12–16 concurrent probes, 1.5 s each, 5 s overall deadline; stream results into the picker as they arrive. *(Built as 12 concurrent; the budgets were raised to 4 s and 12 s by R39, which is the live rule.)*
- Send probes through an ephemeral `URLSession` built from `tsnetModel.proxyConfiguration`, rebuilt when the config is republished. If every probe fails with `-1000`/`-1004`, report "proxy unhealthy" and call `refreshStatusNow()` — not "no gateways found".
- Fingerprint: `GET /manifest.json` with `"name": "Kiro Crew"` (use the FQDN without the trailing dot), confirmed by `GET /api/auth/me` returning 403 with `X-Auth-Required: true`.
- **Expectation to verify in M7:** under the purgatory policy (D5) a promoted `kiro-clients` node's netmap should contain only peers it may talk to or that may talk to it — roughly byskebox, chonk and air — so real-world discovery is small. A node still in purgatory sees no gateway at all. Keep the filters and deadline anyway.
- Rewrite the M5 AC against the real tailnet with a defined instrument (app-logged timestamps): first gateway shown ≤ 5 s, sweep done ≤ 10 s *(≤ 15 s since R39)*.

**R27 — Stop republishing the proxy config on every peer change** [review M6]
- `matchDomains` includes every peer's DNS name and short hostname, so any device joining, leaving or renaming republishes; WebKit may rebuild sessions on some config changes.
- Either pin the rules to `[100.64.0.0/10, fd7a:115c:a1e0::/48, <MagicDNS suffix>]` (still a scoped split tunnel, so it does not violate upstream's AGENTS.md warning; the app only uses FQDN origins), or add a test that republishes mid-WebSocket. §7.3 claims M6.4 already tests this; it does not.

**R28 — ATS can now be tightened** [review L, D4]
- With chonk gone and discovery https-only, M8.6 is viable: `NSAllowsArbitraryLoads = false`. *(D4 is superseded and chonk is back — served on 443, so it changes nothing here. The rule rests on discovery and manual entry being https-only (R26) and on every gateway being an HTTPS origin behind `tailscale serve`; a dashboard's bare loopback listener is never a target.)* Keep test-only exceptions in the test configuration if the harness needs them (loopback IP literals are exempt anyway). Fix the malformed nested dict in `Info.plist` in the same edit.

### M6 – M8

**R29 — Observability before device testing** [review M13]
- Build the diagnostics screen (M8.2) and on-device tsnet log capture (M8.3, local only per D1) **before** M6's device tests — M6.6 "read logs afterwards" needs them.

**R30 — SocksLogProxy housekeeping** [review M8]
- Not a security hole (tsnet enforces its 128-bit SOCKS password; the relay passes it through). But it is in the data path by default and `restartListener()` has no callers. Cap concurrent sessions, and either disable it in the daily-driver build or restart it on tailnet `-1000/-1004/-1005`.

**R31 — Key expiry, device approval and re-login** [review M2, D8]
- Decode and show `SelfNode.KeyExpiry` in diagnostics; warn in-app 14 days before expiry.
- Handle `NeedsLogin` mid-session with a clear re-login path, and `NeedsMachineAuth` with its own gate screen. Test both at L2 (R17).

**R32 — Define sign-out and reset** [review M13]
- **Sign out:** page-world `POST /api/auth/logout`, then clear the WebKit data store.
- **Reset app:** sign out, plus log the node out via upstream's `SettingsViewModel.logout()` so it is removed from the tailnet (otherwise every reinstall leaves an orphaned node with a valid key).
- Build gateway switching as a real task — M7.6 has the AC, but no task builds it.

**R33 — Free-signing hygiene** [review L]
- Warn 48 h before the provisioning profile (`embedded.mobileprovision`) expires — the app otherwise simply stops launching.
- Document in 7.7: moving to a paid team changes the Team ID → delete and reinstall → new node, new token.

**R34 — Notifications stay out** [D6]
- Drop the deep-link interim. Keep the §9 note to re-evaluate M5–M8 if claude-agent-acp PR #735 merges.

### Plan-wide

**R35 — Add a stop gate after M2** [review M12]
- Stop and reassess if any holds: the dashboard renders blank on the device; the embedded node cannot reach byskebox; UI tests cannot run from the agent shell (and the Terminal fallback is unacceptable to Olof); cold start to an interactive dashboard > 15 s.
- #9399 fallbacks, since Olof does not control KiroCrew releases: the reporter's published fix patched into the gateway venv, or a client-side WKUserScript.

**R36 — Re-estimate** [H13]
- M2 10–16 h, M3 12–20 h, M4 14–20 h; total ≈ 75–110 h. Record actual hours per milestone in DECISIONS.

**R37 — Text and Appendix B corrections** [review L]
- Appendix B: a stale `/api/auth/me` returns **403 + `X-Auth-Required`**, not 401. The QR "1 h TTL" is the access-token TTL; the default QR session lasts until a gateway restart. The refresh rate limit keys on `request.remote`, so behind `tailscale serve` every client shares one 60/min bucket. Refresh returns 403 `bad_origin` for a foreign Origin. Cookie names are `mc_token_5476`/`mc_refresh_5476` behind serve (resolves open question 3). Remove the `POST /api/notifications/push` Web-Push caveat only if you also keep the "not Web Push" note.
- Open question 1 is resolved: `kirocrew token` prints up to three URLs (see R23). Open question 4 is resolved by R22.
- Stale text: the header's "no code written yet"; §4.1 "versioned alongside"; §4.2's command sequence (replaced by R16); §4.3's two bundle-ID sites (M0 found four); §7.1 still "medium, early" though M0 resolved it; §6.5's nonexistent `scripts/test-policy.sh`; the journal path differs between M2.7 and Appendix C; M2's "clean checkout, < 3 min" (exclude the build via `test-without-building`); test leaf validity must be ≤ 825 days; `tstestcontrol.go:53` is a logging TODO — `log.Fatal` is at `:237-241`.

**R39 — Discovery's budgets were set for a lab, not a tailnet** [device run 2026-09-23]
- R26's 1.5 s per probe and 5 s per sweep were chosen before anyone had run this on a real tailnet. The first device run had UDP blocked on the phone's network, so every path relayed through DERP over TCP, against a gateway a continent away (190 ms RTT measured direct, more relayed). A probe pays TCP, then TLS, then the request, and may pay the peer's WireGuard handshake inside the same budget.
- **Now 4 s per request, 12 s per sweep** (`GatewayDiscovery.requestTimeout`, `.deadline`). Concurrency stays 12, so a dead peer still costs one probe's wait, not the sum.
- The M5/M7.6 AC changes with it: first gateway shown ≤ 5 s stands; **sweep done ≤ 15 s**, and a sweep must take ≥ 4 s when a stalling peer is present (`scripts/test-discovery.sh` enforces both from the app's own log).

**R40 — A gateway carries a port; ~~8443 is the standard one~~ 443 stays the default** [owner, 2026-09-23]
- **Status (2026-09-23): agreed in mechanism, deferred in number.** Olof, the same day: "I'm fine with staying on 443 for now." The port-carrying mechanism below (`GatewayEndpoint`, port-aware origins, manual `host:port`, the saved port probed first) is still the design and is buildable; making **8443 the standard, probed by default, does not happen yet** — 8443 needs `KIROCREW_CORS_ORIGINS` on every gateway or it fails silently, whereas 443 works with a bare `tailscale serve`. Reasoning: `features/F1-gateway-port.md` §0 and §4a; the user-facing default: `SETUP.md`. Nothing of R40 is in the code yet: `Gateway.url` is still `https://<host>` (`app/App/Discovery/GatewayDiscovery.swift:41`). The bullets below are the entry as written, kept as the record.
- `tailscale serve --https=443` takes port 443 **host-wide** on macOS (measured on chonk: `IPNExtension` listening on `*:443`, v4 and v6), so it collides with anything local that wants 443. Serving on another port is supported for tailnet-only serve; only Funnel is restricted to 443/8443/10000.
- **8443 is the project's standard alternate**: the conventional alt-HTTPS port, allowed by Funnel if that is ever wanted, and not 5476 (which would collide with the dashboard's own loopback listener).
- The app hardcodes 443 today — `Gateway.url`, both probe URLs, and `GatewayCandidates.manualOrigin`, which parses a typed port and then discards it. A gateway must carry a port: discovery probes 443 **and** 8443 concurrently, manual entry accepts `host:8443`, and the saved gateway keeps it.
- Operationally: the grant's port list is the **serve** port, not the dashboard's, so moving a gateway to 8443 means `"ip": ["8443"]` or the node is dropped exactly as it was on the first device run.

**R41 — "Exactly one destination" covers every request, with four named exceptions** [owner, 2026-09-23; built 2026-09-25, `features/F6-single-origin-web-view.md`]
- **The tightening.** R3 made the gateway's origin (scheme, host, port) the only thing the *main frame* may show. From F6 it is also the only origin the web view may **fetch from**: every subresource — image, script, style, font, `fetch`/XHR, `EventSource`, WebSocket, worker, `sendBeacon`/ping, cross-origin iframe, and a preconnect (seen blocked on the simulator through the proxy; unobserved on a device, where a non-tailnet host goes direct) — is blocked by a WebKit content rule list compiled for the gateway's exact origin (`App/Browser/ContentRules.swift`). The same host on another port is another origin and is blocked. A list that cannot be built loads **nothing** (F4's error page), never everything.
- **The four exceptions, which are the other half of this promise.** Unless the owner turns *Settings → Privacy → Allow widget CDNs* off (default **on**), the web view also fetches from exactly `https://esm.sh/`, `https://cdn.jsdelivr.net/`, `https://cdnjs.cloudflare.com/` and `https://cdn.tailwindcss.com/` — default port, https only, no subdomains, compiled into the binary (`ContentRules.allowedCDNHosts`), not editable at runtime. They are what the gateway's own CSP names for widget runtimes; without them MCP-app widgets are blank. **Each of the four sees the phone's IP address and that it is loading a KiroCrew dashboard**, and an allowed load goes direct, outside the tailnet, where no instrument in the app can see it (Settings → Diagnostics → Page shows what the page itself reports). With the toggle off, the promise is the gateway's origin alone.
- **Not exceptions, and why they are not a hole:** top-level navigations and `window.open` stay R3's (`NavigationPolicy` sends every other origin to Safari; the list exempts them so it cannot pre-empt that); `blob:`, `about:srcdoc` and `data:` carry no network destination. Google's font hosts are **not** allowed, although the same CSP names them.
- **Still outside any rule list** (F6 §4.2): `dns-prefetch` (a DNS query, not used by the bundle), WebRTC and WebTransport (not HTTP loads; not used by the bundle), and the OS's own traffic. Service workers cannot exist in this view without `WKAppBoundDomains`; adding that key reopens F6 §4.2.

**R42 — What leaves the app is decided, and another app opens only from a tap** [issue #2, 2026-09-25; built 2026-09-25, `features/F17-hand-off-needs-a-tap.md`]
- **What changed.** R3 said a main-frame navigation off the gateway "leaves the app", and every such URL went to `UIApplication.shared.open` with no prompt, whatever its scheme and whoever started it. R41 tightened the same invariant (content the dashboard renders does not reach past its origin) for fetches; R42 tightens it for hand-off to other apps. `NavigationPolicy.decide` is unchanged — it still says only *here or not here*; a new `HandOffPolicy` decides what happens to *not here*.
- **The rule.** Another web origin, `mailto:` and `tel:` open without asking when tapped, as before, and **ask** when no tap started them. Every other scheme **asks** when tapped and is **refused** when not. `javascript:`, `data:`, `file:` and a foreign `blob:` stay refused. One prompt at a time; after an untapped ask is cancelled, untapped requests are refused until the next tap.
- **"Tapped"** is a trusted `click` in a gateway-origin frame, reported from the app's own content world, at most 1 s before the hand-off and consumed by it. Not `navigationType`: a script's `a.click()` reports `.linkActivated` too. A script that navigates from inside the owner's own click still counts as tapped (every browser's limit), which is why tapped does not make an unknown scheme silent.

---

## C. Owner actions (Olof)

| # | When | Action |
|---|---|---|
| O1 | Before the M1 device check | Add your Apple ID in Xcode → Settings → Accounts (free personal team) and tell the session the Team ID it shows. |
| O2 | Before the M1 device check | On the iPhone: Settings → Privacy & Security → Developer Mode on; connect it to chonk and trust the Mac. Tell the session the iOS version. |
| O3 | Before the M1 device check | **Apply the "admin purgatory" tailnet policy** (D5, via the infra workspace brief): grant 1 becomes device-scoped (`src: ["chonk", "air"]`); new admin-owned devices get an address from a purgatory pool (`100.81.0.0/24`) and **no grants at all**; access comes from category ranges outside the pool, starting with `kiro-clients` = `100.82.1.0/24` → `byskebox:443` only. SSH rules stay on `autogroup:admin` (Tailscale SSH also needs a network grant to port 22). No effect on air or chonk. Owner applied: _(date)_. |
| O3b | After the node first logs in, **before the first token redemption** | Move the Latchkey node out of purgatory into the next free `kiro-clients` address (`100.82.1.x`), via the admin console or API. Until this is done the app cannot reach byskebox — a "connected but can't load the dashboard" state at this point is expected, not a bug. Confirm the node is owned by you and untagged, and record its address. Reinstalling the app creates a new node that lands back in purgatory and must be moved again. |
| O4 ☑ 2026-09-23 (box; byskebox still unasked) | Before M4 / before any M7.5 decision | Check byskebox's dashboard identity settings (e.g. `ssh byskebox 'bash -lc "kirocrew config get dashboard.tailscale"'`) and report `trust_identity`, `allowed_logins`, `pin_scope`. If on, `allowed_logins` must include `owner@example.com`. |
| O5 | For the M1 device check | Mint a first token on byskebox (`kirocrew token`, or the dashboard's Phone access QR) and paste it into the dashboard's banner in the app within 5 minutes. |
| O6 | Only if QR restart friction shows up | Decide on M7.5 (`qr_session_persist_across_restart`) — see R24 for preconditions and risk. |
| O7 | Once R19 lands; again after every KiroCrew upgrade | Run `testing/harness/contract_test.py` against a real gateway on byskebox's KiroCrew version, using a fresh token you mint for it (the agent is policy-blocked from minting tokens). chonk's local gateway (`127.0.0.1:5476`) is the easiest target if its version matches. Keep the token in a file or env var, not chat. A failure means the fake backend has drifted from real KiroCrew — tell the session. |
