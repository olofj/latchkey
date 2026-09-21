# Latchkey (app)

A single-purpose iPhone app for reaching a self-hosted
[KiroCrew](https://github.com/kirodotdev/KiroCrew) dashboard over Tailscale,
with the Tailscale node embedded in the app binary. No system VPN.

This directory is a fork of
[tailscale/aperture-plus](https://github.com/tailscale/aperture-plus) — see
[`NOTICE`](NOTICE) for attribution and [`../docs/PLAN.md`](../docs/PLAN.md) for
what is being built and why. Every divergence from upstream is recorded in
[`../docs/DECISIONS.md`](../docs/DECISIONS.md).

## What it is

One window, one destination. The app brings up a userspace Tailscale node
inside its own process, points a `WKWebView` at that node's loopback SOCKS5
proxy, and loads the dashboard. There are no tabs, no address bar, no
bookmarks, and no macOS app — all removed in milestone M1.

## How traffic is routed (split tunnel)

Only **tailnet** destinations go through the embedded node's SOCKS5 proxy:

| destination | route |
| --- | --- |
| Tailnet IPs (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`) | via the tsnet proxy |
| MagicDNS names — `https://byskebox.your-tailnet.ts.net/` | via the tsnet proxy |
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

## Build

```bash
make framework     # TailscaleKit.xcframework — needs Go; slow the first time
make app           # simulator build
make test-policy   # host-only unit tests, ~2s, no simulator needed
make help          # everything else
```

Requires Xcode and Go. Built and verified on Xcode 27.0 / iOS 27 SDK and Go
1.27.1, both newer than upstream asks for.

The xcframework is **not in git** and must exist at
`ThirdParty/libtailscale/swift/build/Build/Products/Release-iphonefat/TailscaleKit.xcframework`
before the project will build. A missing-framework error means you skipped
`make framework`.

### Vendored libtailscale

`ThirdParty/libtailscale/` (with `tailscale-patched/` inside it) is plain
source committed into this repository, not a submodule — see
[`ThirdParty/VENDORED.md`](ThirdParty/VENDORED.md) for provenance, the pinned
upstream revisions, and how to diff against upstream. Every Latchkey change
to it is a separate commit after the pristine import.

### If the build fails with `sandbox_apply: Operation not permitted`

You are building inside a sandbox that forbids nested sandboxes (an AI coding
agent's shell, some CI runners). `make` detects this and passes
`-disable-sandbox` to the Swift driver; force it either way with
`make app NESTED_SANDBOX=1` or `NESTED_SANDBOX=0`. Without it, Swift macro
expansion fails and the build drowns in misleading
`cannot find '$binding' in scope` errors that point at the wrong layer
entirely. See `../docs/DECISIONS.md`.

## Install on a device

Signing is deliberately personal-sideload only; there is no TestFlight path
(the vendored TailscaleKit xcframework fails App Store validation for a missing
privacy manifest — [libtailscale#57](https://github.com/tailscale/libtailscale/pull/57)).

1. Open `Latchkey.xcodeproj` in Xcode.
2. Select the `Latchkey` target → Signing & Capabilities → pick your team.
   `DEVELOPMENT_TEAM` is intentionally blank in the project so Xcode prompts.
3. Enable Developer Mode on the phone (Settings → Privacy & Security), then
   press Run.
4. Trust the profile under General → VPN & Device Management.

With a **free** Apple ID the provisioning profile expires after 7 days and the
app stops launching until you rebuild; its data survives. The $99 program makes
profiles last a year and is the only thing that changes. `make ipa` exists for
a paid team — set `teamID` in `ExportOptions.plist` first.

## Tests

| Layer | Command | Needs |
|---|---|---|
| L0 host unit tests | `make test-policy` | nothing (~2s) |
| L1 offline harness | `../scripts/test-offline.sh` | simulator + Python (M2) |
| L2 fake control plane | `../scripts/test-tsnet.sh` | simulator (M3) |
| L4 real tailnet | `make test-ios-ui` | a tailnet **and** an auth key |

`make test-ios-ui` runs the inherited XCUITest suite. Most of it needs a real
tailnet plus an auth key staged at `~/.aperture-ios-authkey`, which is exactly
the dependency milestones M2 and M3 exist to remove — see `../docs/PLAN.md` §6.
Three tests are connection-independent and pass with no tailnet at all:
`testAppLaunchesAndShowsStatus`, `testOpenAndCloseSettings`,
`testHomePageSettingPersistsAcrossSettingsReopen`.

`README.ui-automation.md` documents the test tooling, log capture and
simulator handling. It predates the fork, so its references to tabs, bookmarks
and the macOS target no longer apply.

## Diagnostics

Everything needed to debug a failure without a Mac lives in Settings:

- **Routing** — the live split-tunnel rules, plus a field to test any host.
- **Logs** — the app's own log ring, including a `socks[n]` line for every
  proxy connection attempt and its outcome. Moved here from the deleted
  browser toolbar; it is the only diagnostic channel on a device that cannot be
  attached to a Mac.

Streaming from a Mac:

```bash
xcrun simctl spawn booted log stream --level debug \
  --predicate 'subsystem == "net.lixom.latchkey"'
```

## Adding source files

`App/` and `UITests/` are Xcode **synchronized folder groups** — a new
`.swift` file there is compiled automatically. `TSNet/` is **not**: it has a
`membershipExceptions` list in `project.pbxproj`, and a new file dropped there
is silently not compiled until you add its name to that list.
