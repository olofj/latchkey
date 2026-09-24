# Latchkey

A single-purpose iPhone app for reaching a self-hosted [KiroCrew](https://github.com/kirodotdev/KiroCrew)
dashboard over Tailscale, with the Tailscale node embedded in the app binary — no
system VPN required.

Built as a fork of [tailscale/aperture-plus](https://github.com/tailscale/aperture-plus)
(BSD-3-Clause), Avery Pennarun's experimental WebKit browser with an embedded
userspace Tailscale node.

**Status: built and running on a real device.** The plan's milestones are done
bar a few owner-and-device items; work now arrives as feature requests, each
specified in [`docs/features/`](docs/features/) before it is built.

## Is this for you?

It is, if you run KiroCrew on your own machine and want it on your phone
without turning on a system-wide VPN. You need a Tailscale tailnet, a computer
running KiroCrew, an iPhone, and a Mac with Xcode — a **free** Apple ID is
enough.

**→ [`docs/SETUP.md`](docs/SETUP.md) is the setup guide.** It covers a flat
tailnet (the short path: no access control to configure) and says separately
what changes if your tailnet uses ACLs, device approval or tailnet lock.

Nothing in the app assumes a particular tailnet policy. The author's own tailnet
is locked down and its bring-up runbook
([`docs/DEVICE-CHECK.md`](docs/DEVICE-CHECK.md)) names his hosts and his
grants — that is one environment, not a requirement.

## Where things are

| Path | What |
|---|---|
| `docs/SETUP.md` | **Setting this up yourself.** Start here if you want to run it. |
| `docs/features/` | One spec per feature or bug, written before the code. Start here if you want to change it. |
| `docs/PLAN.md` | The original implementation plan — architecture, 9 milestones, test strategy. Historical, and specific to the author's environment in places. |
| `docs/DECISIONS.md` | Append-only log of decisions, with the evidence for each. |
| `docs/DEVICE-CHECK.md` | The author's device bring-up runbook (environment-specific). |
| `testing/harness/` | Offline test harness: a stub SOCKS5 proxy and a fake dashboard, so the WebKit proxy path can be tested with no Tailscale account. |
| `app/` | The app itself, a fork of aperture-plus. |

## Quick start

```bash
cd app
make framework     # builds TailscaleKit.xcframework (needs Go; slow the first time)
make app           # simulator build
make test-policy   # host-only unit tests, ~2s
```

## The offline harness

Runs without Tailscale, a tailnet, or an account:

```bash
python3 testing/harness/dashboard.py --port 8443 --cert server.pem --key server.key
python3 testing/harness/socks5stub.py --port 1080 --user tsnet --password s3cret \
    --journal /tmp/proxy.ndjson --map dash.tail-scale.ts.net:443=127.0.0.1:8443
```

`socks5stub.py --blackhole` authenticates and then refuses every CONNECT, which is
how the "a dead proxy must fail the load rather than leak a direct connection"
test is written.
