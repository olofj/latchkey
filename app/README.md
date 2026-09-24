# Latchkey (app)

A single-purpose iPhone app that reaches a self-hosted
[KiroCrew](https://github.com/kirodotdev/KiroCrew) dashboard over Tailscale
without a system VPN. It brings up a userspace Tailscale node inside its own
process, points a `WKWebView` at that node's loopback SOCKS5 proxy, and loads
the one dashboard. One window, one destination: no tabs, no address bar, no
bookmarks, no macOS app. It is a fork of
[tailscale/aperture-plus](https://github.com/tailscale/aperture-plus) — see
[`NOTICE`](NOTICE) for attribution, [`../docs/PLAN.md`](../docs/PLAN.md) for
what is being built and why, and [`../docs/DECISIONS.md`](../docs/DECISIONS.md)
for every divergence from upstream. [`AGENTS.md`](AGENTS.md) has the working
notes that are easy to get wrong.

Bundle id `net.lixom.latchkey`; one target and one scheme, `Latchkey`.

## First-time setup

Verified on Xcode 27.0 (iOS 27 SDK; deployment target iOS 26.0) and Go 1.27.1.

```bash
make framework     # TailscaleKit.xcframework from the vendored libtailscale — needs Go; slow the first time
make app           # simulator build
make test-policy   # host-only unit tests, ~2 s, no simulator
make help          # everything else
```

The xcframework is **not in git**. It is built from
`ThirdParty/libtailscale/` (plain vendored source, not a submodule — see
[`ThirdParty/VENDORED.md`](ThirdParty/VENDORED.md)) into
`ThirdParty/libtailscale/swift/build/Build/Products/Release-iphonefat/TailscaleKit.xcframework`,
and stamped with a hash of the sources it was built from. `make framework`
skips the build when the stamp matches and fails when it does not; every Go
change needs it.

If a build inside an agent shell or CI fails with
`sandbox_apply: Operation not permitted`, the shell forbids nested sandboxes.
`make` detects this and passes `-disable-sandbox` to the Swift driver; force
it with `NESTED_SANDBOX=1` or off with `NESTED_SANDBOX=0`. The symptom
without the fix is a flood of `cannot find '$binding' in scope` errors.

### Signing

Signing is a **free personal team**, deliberately (PLAN §7.7): the vendored
xcframework has no privacy manifest, so there is no TestFlight or App Store
path, and a paid team would buy only a longer profile. The owner actions
before the first device install are O1–O3 in
[`../docs/PLAN-REVISIONS.md`](../docs/PLAN-REVISIONS.md) §C: the Apple ID
in Xcode (O1), Developer Mode on the phone (O2), and the tailnet policy that
puts a new node in purgatory until it is moved into `kiro-clients` (O3, then
O3b after the first login). Do them in that order.

The app target carries the Team ID, which Xcode wrote into the project on the
first device Run (2026-09-23) and would write again; keeping it saves
re-picking the team on every Run. `make device` passes the ID from
`app/.dev-team` (gitignored) regardless, so another team needs no project edit.
Either way the profile is managed automatically. A free team allows three sideloaded apps per device.

## Installing on the iPhone

1. Plug the phone into the Mac and trust it; Developer Mode must be on
   (Settings → Privacy & Security → Developer Mode). The switch appears only
   after the phone has been connected to a Mac with Xcode.
2. `make device`: checks the phone first (paired, reachable, Developer Mode
   on, and prints its iOS version), then builds Release, signs it with the
   team in `.dev-team`, installs and launches it. The first build creates the
   signing certificate and profile and registers the phone. *Or* choose the
   phone in Xcode and press Run, which installs the Debug configuration.
   Neither carries test hooks.
3. The first time, trust the profile on the phone under General → VPN &
   Device Management.

`make ipa` (archive + export a dev-signed `.ipa` under `build/ipa/`) is for
a paid team only: it needs `teamID` in `ExportOptions.plist` and a profile
that lasts. With a free team, `make device` or Run from Xcode is the install
path.

## The weekly re-sign

A free team's provisioning profile expires **7 days** after the build. The
app warns **48 hours** ahead — a banner above the dashboard and the
"Profile expires" row under Settings → Status — and after that it simply
stops launching. The ritual: plug the phone in, `make device` (or Run in
Xcode), done.
Nothing else changes: the app's data (the node identity, the chosen gateway,
the dashboard session) survives a rebuild over the installed app.

Two things break that:

- **Deleting the app** deletes its node key and session. The next install is
  a new node: it lands back in purgatory (O3b again), needs a new dashboard
  token, and — since the tailnet has tailnet lock on — has to be signed again
  from a signing node (`tailscale lock sign nodekey:…`), or no peer will talk
  to it. The admin console shows such a node as "Locked Out".
- **Moving to a paid team** changes the Team ID, and a different Team ID is
  a different app to iOS: delete and reinstall, with the same consequences
  (PLAN §7.7). Pick a convenient moment.

## First run

1. **Connect the node.** The connection gate shows the Tailscale status
   and a Login button. Login opens Tailscale's sign-in in a browser sheet;
   sign in with your own account, so the node is yours and untagged. The
   node is named `latchkey-iphone` (Settings → Name). Do not rename it once
   the dashboard is signed in: KiroCrew ties the session to your login and
   the node name, and a rename signs it out.
2. **Approval, and access control if your tailnet has any.** If the tailnet
   requires device approval, the gate says so and connects by itself once you
   approve the machine in the admin console. On a **flat tailnet with no ACLs
   that is all** — the node can reach its peers immediately. If your tailnet
   restricts access (this project's own does: new devices land in an address
   pool with no grants), the node will be connected and still able to reach
   nothing until a grant admits it. That is expected, not a bug, and it is the
   single most confusing state to be in; see `../docs/SETUP.md`.
3. **Find the gateway.** With no gateway saved, the app sweeps the tailnet
   for KiroCrew gateways: online peers of yours, probed over HTTPS through
   the node's own proxy, a match being `/manifest.json` named "Kiro Crew"
   plus `/api/auth/me` demanding auth. One match is chosen automatically;
   otherwise the "Choose a gateway" picker lists what it found, with
   "Search again" and "Enter manually". The choice is kept. Change it later
   under Settings → Gateway, or with "Find gateways…" there. A gateway looks
   like `https://gateway.example.ts.net/`.
4. **Sign in to the dashboard.** The dashboard loads and asks for a token;
   the app puts up its own sheet. On a computer run `kirocrew token` and
   paste what it prints (a link or the bare token; the app applies it to the
   selected gateway only), or tap "Scan QR code" and scan the Phone access
   card on the dashboard. A link is valid for 5 minutes. After that the page
   keeps its own 30-day session refreshed; CLI-link sessions survive a
   gateway restart, QR sessions do not unless the gateway is configured for
   it (PLAN M7.5). Never paste a token anywhere but the app.
5. **Turn the Tailscale app's VPN off** and confirm the dashboard still
   loads. That is the point.

## How traffic is routed (split tunnel)

Only **tailnet** destinations go through the embedded node's SOCKS5 proxy:

| destination | route |
| --- | --- |
| Tailnet IPs (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`) | via the tsnet proxy |
| MagicDNS names — `https://gateway.example.ts.net/` | via the tsnet proxy |
| Everything else (fonts, CDN scripts the dashboard loads) | **direct**, like any other app |

This is least-privilege, and it is also required for correctness: routing
public traffic through a proxy that resolves names proxy-side made **every**
non-tailnet URL fail with an "invalid URL" error (`NSURLErrorDomain -1000`) on
some hardware. TLS is unaffected — certificates are validated end-to-end, and
the proxy only ever sees a CONNECT.

`allowFailover` stays false, so a dead proxy **fails the load** rather than
silently falling back to a direct connection. That is the anti-leak guarantee;
do not change it.

See **Settings → Routing** in the app for the live rules and a per-host test,
`TSNet/TailnetProxyPolicy.swift` for the implementation (read its header
comment before touching it), and `scripts/proxy-semantics/README.md` for how
the behaviour was measured.

## Tests

The strategy is PLAN §6: push coverage down to layers that need no tailnet.
Run the suites by tier from the parent repository:

```bash
../scripts/test-all.sh            # quick, about 4–5 min: while iterating
../scripts/test-all.sh --full     # about 17 min: before a milestone or review commit
../scripts/test-all.sh --build    # build for testing once, in the first simulator suite
```

Quick runs the host tests, the vendored Go tests, L1 and L2, and adds the
session, discovery and lifecycle suites only when code they exercise changed
since the last full pass. Full runs everything and records the commits it passed, which
is what quick compares against. Every simulator suite fails unless every test
in its file passed: a stale build that runs nothing is not a pass.

| Suite | Command | What it covers |
|---|---|---|
| L0 host | `make test-policy` | Split tunnel, hostname qualification, log redaction, proxy config, token parsing, gateway candidates, diagnostics — pure logic, ~2 s, no simulator |
| Go | (in `../scripts/test-all.sh`) | The vendored library's local log and the logtail patch |
| L1 offline | `../scripts/test-offline.sh` | The real app and WKWebView against a stub SOCKS5 proxy and a fake dashboard, including the anti-leak tests; <3 min |
| L2 tailnet | `../scripts/test-tailnet.sh` | The app's real tsnet node against a host-side fake control plane: login, approval, key expiry, MagicDNS, diagnostics; <5 min |
| M4 session | `../scripts/test-session.sh` | The dashboard session against KiroCrew's real, pinned frontend served by the fake gateway; ~6 min |
| M5 discovery | `../scripts/test-discovery.sh` | Gateway discovery on the L2 harness with a real-looking gateway, a non-gateway, a dead peer and one that never answers, plus the discovery timing budget (R39's numbers: a sweep takes 4–15 s, the first gateway shows within 5 s); ~1.5 min |
| M6 lifecycle | `../scripts/test-lifecycle.sh` | Recovery on the L2 harness: the app's sockets damaged through its own chaos hooks, then its process frozen with SIGSTOP from the host while backgrounded; ~4 min |
| inherited | `../scripts/test-inherited.sh` | The three upstream XCUITests that need no tailnet; full tier only |
| L4 real tailnet | `make test-ios-ui` | The rest of the inherited XCUITest suite: needs a tailnet and an auth key at `~/.aperture-ios-authkey` |

Each simulator script takes `--build`; without it the last test build is
reused. On failure they leave a screenshot, the harness logs and the xcresult
under `build/<suite>-logs/` — `offline-logs`, `tailnet-logs`, `session-logs`,
`discovery-logs`, `lifecycle-logs`, `inherited-logs` — one directory per run
(the tailnet-dependent `make test-ios-ui` writes `build/uitest-logs/` via
`scripts/run-uitests.sh`). Two more, run by hand:
`make test-lock-resume` freezes the app process and asserts a prompt resume;
`../scripts/check-no-log-upload.sh` watches the app's sockets for Tailscale's
log service, which the vendored library must never contact. After a KiroCrew
upgrade, `../testing/harness/contract_test.py` against a real gateway checks
that the fake backend has not drifted (O7).

`README.ui-automation.md` documents the simulator tooling and log capture in
depth. It predates the fork, so its references to tabs, bookmarks and the
macOS target no longer apply.

## Troubleshooting

Everything needed to debug a failure on a phone that is not attached to a Mac
is under Settings → Diagnostics. Each screen has Copy.

- **Status** — the node (state, name, tailnet, addresses, peers, key
  expiry), the gateway and the last discovery, the dashboard session and
  when it and its access token expire, the proxy endpoint and rules, the
  last page error, and the app's version, configuration and profile expiry,
  with any warnings. Nothing secret is on it.
- **Node log (tsnet)** — tsnet's own lines: control, magicsock, DERP and
  loopback, which the app's log never sees. Kept locally and redacted, never
  uploaded. A switch shows the process's raw stderr — a Go panic from the
  last run — which is not kept under Xcode or XCTest.
- **Logs** — the app's own log ring, including a `socks[n]` line for every
  proxy connection attempt and its outcome; the filter defaults to `socks`.
- **Routing** — the live split-tunnel rules and a field to test any host.

From a Mac, with the simulator:

```bash
xcrun simctl spawn booted log stream --level debug \
  --predicate 'subsystem == "net.lixom.latchkey"'
```

Common failures:

| Symptom | Cause and fix |
|---|---|
| `no such module 'TailscaleKit'`, or a missing-framework error | The xcframework is not built: `make framework`. |
| `STALE: TailscaleKit.xcframework was not built from the current libtailscale sources` | A Go change since the last build, or an interrupted one: `make -B framework`. `make check-framework` asks without building. |
| `sandbox_apply: Operation not permitted` | Nested sandbox; see First-time setup. |
| The app does not launch on the phone; last week it did | The 7-day profile expired. Plug in, `make device` (or Run from Xcode). For the 48 hours before, the dashboard and Status said "This build of Latchkey stops launching in …". |
| "Login Required" banner over the dashboard | The node key expired (or an admin expired it). Login signs in again in place; the dashboard stays up. The key warns 14 days ahead; disable key expiry for the device in the admin console to avoid it. |
| "Waiting for approval" banner | The device was revoked or the tailnet requires approval. Approve it under Machines in the admin console; the banner goes by itself. |
| "No KiroCrew gateway with this name is in your tailnet" | The saved gateway is not among the node's peers, or discovery is stale. **Find** re-sweeps and opens the picker; **Change** opens Settings → Gateway. A new node that is connected but reaches nothing is still in purgatory: O3b. |
| The picker says the tailnet connection isn't passing traffic yet | The node is not Running yet, or every probe failed at the proxy. Check Status, then Search again. |
| Public resources on the page fail with "invalid URL" (-1000) while the dashboard loads | The split tunnel is proxying everything; Settings → Routing shows it. Someone changed `TailnetProxyPolicy` or launched with `-ProxyEverything`. |
| "Your dashboard session has ended" | The page's refresh chain ended (a gateway restart on a QR session, or 30 days). Mint a new token and use the sheet. |
| Logout under Settings | Deletes the session, including the tailnet identity and website data. The next launch is a new node: purgatory, then a new token. Not a fix for anything above. |

## Adding source files

`App/` and `UITests/` are Xcode **synchronized folder groups** — a new
`.swift` file there is compiled automatically. `TSNet/` is **not**: it has a
`membershipExceptions` list in `project.pbxproj`, and a new file dropped there
is silently not compiled until you add its name to that list. The app icon is rendered by
`../design/latchkey-icon.swift` (`swift design/latchkey-icon.swift` from the
repository root); rerun it rather than editing the PNGs.
