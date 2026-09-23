# F1 — A gateway carries a port; 8443 is the standard one

| | |
|---|---|
| **Status** | spec |
| **Requested** | 2026-09-23, by Olof: "maybe I want to move the serve off of 443 though, since it's the poplar local SSL port and might at some point overlap" … "Let's choose a standard port number and use it and have the app look for it too. We're setting the precedent here, no legacy we need to consider." |
| **Revision** | R40 in `../PLAN-REVISIONS.md` |
| **Touches** | `App/Discovery`, `App/Browser/HomePage.swift`, Settings, `testing/tsnet-harness`, the discovery and session suites |

## 1. Why

`tailscale serve --https=443` takes port 443 **host-wide** on macOS, not only
on the tailnet address. Measured on chonk while it was serving the dashboard:

```
IPNExtens  73794  olof  31u  IPv4  TCP *:443 (LISTEN)
IPNExtens  73794  olof  32u  IPv6  TCP *:443 (LISTEN)
```

So a gateway machine cannot also run anything local on 443. Serving on
another port is supported for tailnet-only serve (only Funnel is restricted to
443/8443/10000), but the app hardcodes 443 in three places and silently throws
away a port the owner types:

- `App/Discovery/GatewayDiscovery.swift:41` — `var url: String { "https://\(host)" }`
- `App/Discovery/GatewayDiscovery.swift:211-212` — probes `https://\(host)/manifest.json` and `/api/auth/me`
- `App/Discovery/GatewayCandidates.swift:120-127` — `manualOrigin` parses `host:port` and returns `"https://\(host)"`

**8443 is the project's standard alternate**: the conventional alt-HTTPS port,
permitted by Funnel if that is ever wanted, and not 5476, which would collide
with the dashboard's own loopback listener.

## 2. What the owner sees

Working:
- A gateway serving 8443 appears in *Choose a gateway* by itself, shown as
  `box:8443`. One serving 443 appears as `box`, unchanged.
- Typing `chonk:8443` in the manual field reaches it. Typing `chonk` still
  means 443.
- The chosen gateway, port included, survives quitting the app and the
  7-day rebuild.
- Settings → Gateway and Settings → Status show the port when it is not 443.

Failing:
- A gateway reachable on neither port is "No Kiro Crew gateway answered among
  N computer(s)", as today.
- A typed port that is not a number, or is outside 1–65535, is refused in
  place with "Enter a host, or host:port" — it is not silently dropped, which
  is today's behaviour and the reason this spec exists.
- A gateway moved to 8443 while the grant still names 443 is dropped by the
  tailnet: unchanged symptom (timeouts, no answer), and the runbook already
  says to check the grant's port.

## 3. Non-goals

- **No port scanning.** Two ports, 443 and 8443, and whatever the owner typed
  or saved. A gateway on 9999 is reachable by typing it, not by discovery.
- **No plain HTTP**, at any port. ATS stays on with no exceptions (R28).
- **No per-gateway settings UI.** The port rides on the gateway's URL.

## 4. Design

**`App/Discovery/GatewayDiscovery.swift`**
- `Gateway` gains `let port: Int`. `id` becomes `"\(host):\(port)"` so the same
  host on two ports is two rows. `url` renders `https://host` for 443 and
  `https://host:port` otherwise — one place, used by every caller.
- `static let standardPorts = [443, 8443]`, commented with why 8443 (R40).
- The sweep builds one probe task per (candidate, port) pair, still capped by
  `concurrency`. The saved gateway's own (host, port) is probed first, as
  R26 requires of the saved gateway today.
- A probe's two requests carry the port. The existing R26 log line gains the
  port so `scripts/test-discovery.sh` can assert what was probed.
- Cost: probes double. Concurrency stays 12 and R39's budgets (4 s per
  request, 12 s per sweep) hold; the suite's sweep bound stays 4–15 s.

**`App/Discovery/GatewayCandidates.swift`**
- `manualOrigin(_:suffix:)` keeps an explicit port: parse with
  `URLComponents`, validate `1...65535`, qualify the host as today (short name
  → FQDN via the tailnet suffix), and return `https://host[:port]`. A port of
  0, a non-numeric port, or trailing junk returns nil, which the picker already
  renders as its inline error.
- Peer names stay untrusted input: the existing rules (no single-label rule, no
  `localhost`) are unchanged, and a port cannot affect them.

**`App/Browser/HomePage.swift` and the pickers**
- `HomePage.url` is already a full URL string, so a port persists with no
  schema change. The two `savedHost:` call sites in
  `App/Browser/DashboardRootView.swift:200,249` and
  `App/Settings/SettingsView.swift:165` pass host **and** port (derived from
  the saved URL, port defaulting to 443) so the picker can mark and
  probe-first the saved gateway.
- `GatewayPickerView` shows `gateway.host` for 443 and `host:port` otherwise;
  the row's accessibility identifier becomes `gateway-<host>:<port>` so a test
  can name a ported row unambiguously.

**Sessions.** `SessionManager` keys the dashboard session by gateway host
today. With a port it keys by **origin** (`host:port`), because two ports on
one host are two dashboards with their own cookies. Cookie names come from the
dashboard's own port (5476) and do not change (R37).

**Untouched on purpose:** `TSNet/TailnetProxyPolicy.swift` matches on host
names, and `matchDomains` carries no ports, so the split tunnel needs no
change — worth stating because "add the port everywhere" would break it.
`allowFailover` stays false. Nothing here writes logs, so D1 is unaffected.

**Harness (`testing/tsnet-harness/main.go`)**
- A peer spec gains its serve port. Add `gw-alt`, forwarding tailnet **:8443**
  to the fake KiroCrew gateway, alongside `gw` on 443. The existing peers are
  unchanged, so every other suite sees what it sees today.
- `make check` gains a step: a host-side client reaches the fake gateway
  through `gw-alt`'s 8443 forward.

## 5. State and migration

The only persisted value is `HomePage.url` in the workspace definition.

- A URL written by the current version has no port and means 443. Nothing to
  migrate: `URL.port == nil` → 443.
- A URL with `:8443` written by this version is read by an older build as…
  nothing: the older build's `manualOrigin` would have dropped the port, but it
  never parses the saved URL through that path, and `URL(string:)` keeps the
  port. So a downgrade still loads the ported gateway. No migration code, and
  the spec records the check rather than assuming it.

## 6. End-to-end tests

The discovery suite (`scripts/test-discovery.sh`, `UITests/DiscoveryTests.swift`)
already runs the real app against the L2 harness with a fake KiroCrew gateway
peer; that is where most of this belongs.

| Test | Suite | Asserts | Shown to fail by |
|---|---|---|---|
| A gateway serving only 8443 is found and loads | discovery (L2) | `gw-alt` is listed as `…:8443`, is chosen, and the dashboard loads over the tailnet (the gateway's own request journal shows the load) | running it against today's build: the probe goes to 443, nothing answers |
| A 443 gateway is still found, and both appear together | discovery (L2) | both rows present, both reachable, sweep inside 4–15 s with the doubled probe count | breaking `standardPorts` to `[8443]` |
| Manual `host:8443` reaches the dashboard | discovery (L2) | typing the ported host loads it; the app's log shows the ported origin | today's build: `manualOrigin` drops the port, the load goes to 443 and fails |
| A bad port is refused in place | discovery (L2) | `host:0` and `host:abc` show the picker's inline error and start no load | returning a nil-tolerant origin instead of nil |
| A ported gateway survives a relaunch | discovery (L2) | after choosing `…:8443`, terminating and relaunching, the app loads it with no picker | writing only the host into `HomePage.url` |
| A token sign-in works through a ported origin | session (M4) | the Sign in sheet accepts a token minted for the ported origin and the real KiroCrew bundle reaches a live session | keying the session by host only, so the 443 session is reused for 8443 |
| Nothing is ever fetched over plain HTTP | L1 offline | the anti-leak counts stay zero, and no `http://` request reaches the fake dashboard | adding an ATS exception (must fail) |
| The harness really serves 8443 | `make check` | a host-side client reaches the fake gateway through the 8443 forward | pointing the forward at a closed port |

## 7. Acceptance criteria

- A gateway serving **only** 8443 is discovered and shown within R39's budget:
  first gateway ≤ 5 s of the picker, sweep ≤ 15 s. Instrument: the app's own
  R26 sweep log line, which now names the port, enforced by
  `scripts/test-discovery.sh`.
- Both ports are found in one sweep when both exist.
- `host:8443` typed by hand loads the dashboard; `host` alone still means 443.
- The chosen gateway with its port survives a relaunch.
- L1's anti-leak counts stay at zero: no plain-HTTP attempt, at any port.
- On the device: after moving a machine's serve to 8443 **and** the grant's
  port list to 8443, the app finds it without being told.

## 8. Open questions and owner actions

- **Owner:** after this ships, move serve to 8443 where wanted
  (`tailscale serve --bg --https=8443 http://127.0.0.1:5476`, then
  `tailscale serve --https=443 off`) and change the grant's `"ip"` to
  `["8443"]` — or `["443", "8443"]` while machines are mixed.
- Should a third port ever be probed? Not until something needs it; each port
  doubles the sweep's requests.
- If two gateways on one host (443 and 8443) ever both answer, the picker
  shows two rows and the owner picks. Accepted; it is a real distinction.

## 9. Log

- 2026-09-23: specified. R39's budget rise landed first (app `8a5220b51`), so
  the doubled probe count has room.
