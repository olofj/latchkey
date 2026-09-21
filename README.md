# Latchkey

A single-purpose iPhone app for reaching a self-hosted [KiroCrew](https://github.com/kirodotdev/KiroCrew)
dashboard over Tailscale, with the Tailscale node embedded in the app binary — no
system VPN required.

Built as a fork of [tailscale/aperture-plus](https://github.com/tailscale/aperture-plus)
(BSD-3-Clause), Avery Pennarun's experimental WebKit browser with an embedded
userspace Tailscale node.

**Status: planned, not yet implemented.**

## Where things are

| Path | What |
|---|---|
| `docs/PLAN.md` | The implementation plan — architecture, 9 milestones, test strategy. Start here. |
| `docs/DECISIONS.md` | Append-only log of decisions made during implementation. |
| `testing/harness/` | Offline test harness: a stub SOCKS5 proxy and a fake dashboard, so the WebKit proxy path can be tested with no Tailscale account. |
| `app/` | The fork of aperture-plus (created in milestone M0). |

## Quick start (once M0 is done)

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
