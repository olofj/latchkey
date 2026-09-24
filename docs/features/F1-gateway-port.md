# F1 — A gateway carries a port; 443 stays the default

| | |
|---|---|
| **Status** | **deferred 2026-09-23 — "I'm fine with staying on 443 for now" (Olof).** The port-awareness work below stands and is buildable; making **8443** the standard does not happen yet |
| **Requested** | 2026-09-23, by Olof: "maybe I want to move the serve off of 443 though, since it's the poplar local SSL port and might at some point overlap" … "Let's choose a standard port number and use it and have the app look for it too. We're setting the precedent here, no legacy we need to consider." |
| **Revision** | R40 in `../PLAN-REVISIONS.md` (R39 sets the budgets this spec's arithmetic uses) |
| **Touches** | `App/Discovery` (all three files), `App/Session/SessionManager.swift`, `App/Session/TokenEntrySheet.swift`, `App/Browser/DashboardRootView.swift`, `App/Browser/PageScriptSources.swift`, `App/Browser/BrowserViewModel.swift` (one signature), `App/Settings/SettingsView.swift` (one call site), `App/Diagnostics/DiagnosticsView.swift` (one row); `testing/tsnet-harness`, `testing/harness` (fake gateway, stub proxy map, leaf SANs); `scripts/test-discovery.sh`; the discovery, session and host suites |

## 0. Where this stands (2026-09-23)

Olof's answer to §4a's finding: **stay on 443 for now.** So this spec splits in
two, and only the first half is live work:

- **Live: a gateway carries a port, and the app handles one.** `GatewayEndpoint`,
  the migration, the manual-entry table, port-aware origins and the origin check
  of §4b are all still worth building. They cost nothing on 443 and they are
  what makes any other port *possible* rather than silently broken.
- **Deferred: 8443 as the standard, probed by default.** Not now. The reason is
  §4a and it turned out to be a portability argument as much as a correctness
  one: 443 works with a plain `tailscale serve --https=443` and no further
  configuration, whereas 8443 needs `KIROCREW_CORS_ORIGINS` set on every
  gateway and a restart — and when that is missed the failure is the silent
  "loads fine, does nothing" one. Making the *standard* port the one that needs
  extra server setup would hand that failure to every new user on their first
  attempt. So 443 is the documented default (`../SETUP.md`), and a non-default
  port is an explicit, documented opt-in.

R40 in `../PLAN-REVISIONS.md` should be read with this in mind: the port
*mechanism* is agreed, the port *number* is not changing yet.

## 1. Why

`tailscale serve --https=443` takes port 443 **host-wide** on macOS, not only
on the tailnet address. Measured on chonk while it was serving the dashboard:

```
IPNExtens  73794  olof  31u  IPv4  TCP *:443 (LISTEN)
IPNExtens  73794  olof  32u  IPv6  TCP *:443 (LISTEN)
```

So a gateway machine cannot also run anything local on 443. Serving on
another port is supported for tailnet-only serve (only Funnel is restricted to
443/8443/10000), but the app hardcodes 443 in the discovery layer and silently
throws away a port the owner types:

- `app/App/Discovery/GatewayDiscovery.swift:38-42` — `Gateway` is a host;
  `url` is `"https://\(host)"`.
- `app/App/Discovery/GatewayDiscovery.swift:221-224` — the probe builds
  `https://<host>/manifest.json` and `https://<host>/api/auth/me`.
- `app/App/Discovery/GatewayCandidates.swift:115-128` — `manualOrigin`
  parses `host:port` through `URLComponents` and returns `"https://\(host)"`:
  the port is read and discarded.
- `app/App/Browser/DashboardRootView.swift:249` and
  `app/App/Settings/SettingsView.swift:165` — the saved gateway is handed to
  the picker as `URL(string:)?.host()`, so a saved port is never probed first
  (R26) and never marked.

Everything *below* discovery is already port-clean, which is why the change
is contained:

- `app/App/Browser/GatewayAddress.swift:41-46` keeps a non-default port in
  the origin it persists (`https://h.example:8443` is a host-test case,
  `app/scripts/test-gateway-address.swift:47`).
- `app/App/Browser/BrowserViewModel.swift:361-367` sets `allowedOrigin` from
  that origin, so R3's navigation lock already treats `host:8443` as a
  different origin from `host` (`app/scripts/test-navigation-policy.swift:39`).
- `app/App/Session/SessionManager.swift:348-357` compares the bridge frame's
  `WKSecurityOrigin` **with its port** against the session origin.
- L1 runs the entire app against a ported gateway today:
  `app/UITests/OfflineHarnessTests.swift:51` sets
  `https://dash.localtest.me:8443` as the gateway, through `-UITestHomePage`
  → `GatewayAddress.persistable` (`app/App/Workspace/WorkspaceManager.swift:121-128`).

**8443 is the project's standard alternate**: the conventional alt-HTTPS port,
permitted by Funnel if that is ever wanted, and not 5476, which would collide
with the dashboard's own loopback listener.

**The larger half of the problem is on the gateway**, not in the app: KiroCrew
0.6.0's origin allowlist is port-blind, so a dashboard served on 8443 loads
and then does nothing (§4a). The app cannot fix that; it must refuse to hide
it.

## 2. What the owner sees

Working:
- *Choose a gateway* lists a gateway serving 8443 as `box.<tailnet>.ts.net:8443`
  and one serving 443 as `box.<tailnet>.ts.net`, as today. A machine serving
  both is two rows.
- The manual field takes `box`, `box:8443`, `box.<tailnet>.ts.net:8443` and
  `https://box:8443/anything`. `box` alone still means 443.
- The Sign in sheet names the gateway with its port when it is not 443:
  "Sign in to box.<tailnet>.ts.net:8443".
- Settings → Gateway shows `https://box.<tailnet>.ts.net:8443`; Settings →
  Status → Gateway shows the same, and a new row **Origin accepted: yes**.
- The chosen gateway, port included, survives quitting the app and the
  7-day rebuild; a relaunch loads it without a picker and without a sweep.
- On a gateway moved to 8443 whose operator has allowed the ported origin
  (§4a), sign-in, live updates and posting all work, and Status → Dashboard
  session shows the cookies as expiring normally.

Failing:
- A gateway reachable on neither port: "No Kiro Crew gateway answered among
  N computer(s) on your tailnet", as today. N counts computers, not probes.
- A typed port that is not a number, is 0, is above 65535, or is a bare
  trailing colon: *Use this gateway* is disabled, and Return shows the inline
  error "Enter a host, or host:port (1–65535)." under the field. No load is
  started. (Today the port is dropped without a word; that is the reason this
  spec exists.)
- A gateway moved to 8443 while the grant still names 443 is dropped by the
  tailnet: unchanged symptom (the sweep finds nothing, every probe times out),
  and the runbook says to check the grant's port.
- **A gateway on 8443 whose operator has not allowed the ported origin**: the
  page loads, and within a few seconds a banner appears above it —
  "This gateway refuses the origin https://box.<tailnet>.ts.net:8443. It will
  load but not work: no live updates, and sign-in will not last. On the
  gateway, set KIROCREW_CORS_ORIGINS=https://box.<tailnet>.ts.net:8443 and
  restart it, or serve on 443." The Sign in sheet, if it is up, carries the
  same first sentence. Status → Dashboard session shows **Origin accepted:
  no**. Nothing is silent.
- Settings → Gateway with a bad port keeps the current gateway (M5 review:
  an unusable entry never replaces a working one); the picker is where a bad
  port is refused with a reason.

## 3. Non-goals

- **No port scanning.** 443, 8443, and the saved gateway's own port. A
  gateway on 9999 is reachable by typing it, not by discovery.
- **No plain HTTP**, at any port. ATS stays on with no exceptions (R28); the
  scheme of every gateway origin is https whatever was typed (R26).
- **No per-gateway settings UI.** The port rides on the gateway's URL.
- **No change to KiroCrew, and no attempt to work around its allowlist** from
  the app (no proxying, no header rewriting). The app detects and says; the
  operator allows. A report upstream is an owner action (§8).
- **No cookie handling by port.** Cookies are host-scoped (RFC 6265) and
  KiroCrew names them by the request's port; WebKit sends both ports' cookies
  and the server reads only its own. Nothing to do (§4.6).
- **Not `kirocrew tailnet up` on 8443.** KiroCrew's own publisher pins 443
  (`tailnet_serve.py:73`); moving serve is a `tailscale serve` operation the
  owner does by hand, and KiroCrew's `tailnet status` will call the result
  "not published" (§8).

## 4. Design

### 4.1 A gateway is a host and a port: `GatewayEndpoint`

New type in `app/App/Discovery/GatewayCandidates.swift` (Foundation only, so
`scripts/test-gateway-candidates.sh` compiles it on the host). It replaces
`GatewayDiscovery.Gateway` (`GatewayDiscovery.swift:38-42`), which becomes
`typealias Gateway = GatewayEndpoint` inside `GatewayDiscovery` so the
picker's `discovery.gateways` reads unchanged.

```swift
struct GatewayEndpoint: Hashable, Sendable, Identifiable {
    /// tailscale serve's default; a URL with no port means this.
    static let standardPort = 443
    /// The project's standard alternate (R40): 443 is taken host-wide by
    /// serve on macOS and collides with local SSL; 8443 is the conventional
    /// alt-HTTPS port and one Funnel would allow; 5476 is the dashboard's own
    /// loopback listener.
    static let alternatePort = 8443
    /// What discovery probes, in this order, on every candidate.
    static let standardPorts = [standardPort, alternatePort]

    let host: String   // lowercased FQDN, no trailing dot, never empty
    let port: Int      // 1...65535

    init?(host: String, port: Int)   // nil unless host non-empty and port in 1...65535
    /// From `https://host[:port]`; goes through `GatewayAddress.origin(of:)`
    /// first, so `https://h:443` and `https://h` are the same endpoint. An
    /// http URL, a bare name or junk is nil.
    init?(origin: String)

    var id: String { "\(host):\(port)" }
    /// `https://host` for 443, `https://host:port` otherwise — the ONE place
    /// a gateway is rendered as a URL; every caller uses it.
    var origin: String
    /// `host` for 443, `host:port` otherwise: rows, the sign-in sheet, logs.
    var displayName: String
    var isStandardPort: Bool { port == Self.standardPort }
}
```

Host checks to add to `app/scripts/test-gateway-candidates.swift`:
`init?(origin:)` on `https://h.ts.net` → (h, 443); `https://h.ts.net:8443` →
(h, 8443); `https://H.TS.NET.:443/x?y` → (h.ts.net, 443); `http://h` → nil;
`h` → nil; `origin` and `displayName` round-trip for 443 and 8443; port 0 and
65536 → nil.

### 4.2 Discovery: two ports per candidate (`GatewayDiscovery.swift`)

**The probe list.** Pure, host-tested, in `GatewayCandidates`:

```swift
static func probeOrder(_ candidates: [GatewayPeer], saved: GatewayEndpoint?) -> [GatewayEndpoint]
```

1. If `saved` is non-nil and its host is among `candidates`, the saved
   endpoint itself is probe #1 (R26: the saved gateway is always probed, and
   first — now on its own port).
2. Then every candidate in `select` order (`GatewayCandidates.swift:76-89`:
   the saved host first, the rest alphabetically), and for each, the ports
   `standardPorts` in order, skipping the pair already emitted as #1.

So with saved `box:8443` and candidates `[box, air, nas]` the order is
`box:8443, box:443, air:443, air:8443, nas:443, nas:8443`. With saved
`box:9999`: `box:9999, box:443, box:8443, …` — a non-standard saved port is
probed, and its host's standard ports too, since the owner may have moved it.
A pair is never short-circuited: a machine can run something else on 443 and
KiroCrew on 8443 — that is the whole point.

`start(savedHost:)` (`:91`) becomes `start(saved: GatewayEndpoint?, shownAt:)`;
`select(_:selfUserID:savedHost:)` keeps its host-only signature (it orders
peers, and a peer has no port) and is called with `saved?.host`.

**The probe** (`:221-241`) takes a `GatewayEndpoint` and builds
`"\(endpoint.origin)/manifest.json"` and `"\(endpoint.origin)/api/auth/me"`.
The fingerprint is unchanged: two GETs, both must hold (R26). `Outcome`
carries the endpoint: `.gateway(GatewayEndpoint)`, `.notGateway(GatewayEndpoint)`,
`.failed(GatewayEndpoint, code:)`. `gateways` dedupes on the endpoint, so
`box:443` and `box:8443` are two rows and `box:443` twice is one.

**Concurrency and the deadline — the arithmetic.** R39's numbers hold:
`requestTimeout = 4` s (`:65`), `timeoutIntervalForResource = 8` s (`:213`),
`deadline = 12` s (`:68`), `concurrency = 12` (`:69`). Probes are now `2N` for
`N` candidates (plus one when the saved port is non-standard), filled into the
task group exactly as today (`:156-159`, `:182-185`): 12 in flight, the next
starts as one finishes.

- Rounds = ⌈2N / 12⌉. Worst case (every probe times out) the sweep takes
  `min(12, 4 × rounds)` s: N ≤ 6 → 4 s; 7–12 → 8 s; 13–18 → 12 s, the whole
  budget; N ≥ 19 → the deadline fires with probes never started, and the log
  says how many (`:166`). Before this change the same cliffs were at 12, 24
  and 36 candidates.
- A probe to a port nothing listens on is **refused at once**, not timed out:
  tsnet resets a flow with no listener (`getTCPHandlerForFlow` returns no
  handler, `app/ThirdParty/libtailscale/tailscale-patched/tsnet/tsnet.go:1296-1309`),
  and the SOCKS reply surfaces as `-1000` (`.failed`). So on a healthy tailnet
  the second port costs one round trip, not 4 s; only a peer that accepts and
  never answers (the harness's `slow`, or a jailed node dropping SYNs) pays
  the timeout, and it did already.
- The picker's "first gateway ≤ 5 s" (R39) is unaffected for the saved
  gateway and the first five candidates alphabetically: their probes are all
  in the first round of 12.
- Concurrency stays 12 rather than doubling to 24: on the phone every probe
  is a TCP, TLS and possibly WireGuard handshake over DERP (R39), and Olof's
  tailnet has three candidates. Recorded as the trade-off; raise it only if a
  real sweep is measured against the 12-s deadline.

**Log lines** (the suite's instrument; `scripts/test-discovery.sh:154-181`
parses them):

- `Discovery: probing N of M peer(s) on 2 port(s): P probe(s); first <host>:<port>`
  replaces `Discovery: probing N of M peer(s)` (`:134`). `P` is the probe
  list's length; `first` is its first entry.
- `Discovery: gateway at <host>:<port>` — one line per hit, new.
- `Discovery: K gateway(s); first after X ms, sweep Y ms; A answered, F failed; shown to first Z ms`
  (`:199`) keeps its shape; `A` and `F` now count probes, so `A + F ≤ P`.
- The picker's "answered among N computer(s)" keeps counting peers
  (`candidateCount`), not probes.

### 4.3 Manual entry (`GatewayCandidates.manualOrigin`, `:115-128`)

Split into `manualEndpoint(_:suffix:) -> GatewayEndpoint?` (the parser) and
`manualOrigin(_:suffix:) -> String?` = `manualEndpoint(...)?.origin`, so
`SettingsViewModel.commitGateway` (`app/App/Settings/SettingsViewModel.swift:130`)
and the picker's button state (`GatewayPickerView.swift:99`) gain the port
without changing.

Rules, in order: trim; drop anything through `://`; cut at the first `/`; the
rest is `host[:port]`. Then:

| Typed | Result |
|---|---|
| `box` | `https://box.<suffix>` (443; qualified as today) |
| `box:8443`, `BOX.<suffix>.:8443` | `https://box.<suffix>:8443` |
| `box:443`, `https://box:443/` | `https://box.<suffix>` (443 is never rendered) |
| `http://box:8443/x?y` | `https://box.<suffix>:8443` (scheme always https, path and query dropped) |
| `box:0`, `box:65536`, `box:abc`, `box:` | nil |
| `a b`, empty | nil (as today) |
| `[fd7a::1]:8443` | parsed like any host; the tailnet check in `useManual` decides |

Validation is `1...65535` on the parsed port; a bare trailing colon is refused
explicitly (`URLComponents` reads it as "no port", which would silently mean
443). Peer names stay untrusted input: the single-label and `localhost` rules
in `TailnetProxyPolicy` are untouched, and a port cannot reach them.

Host checks to add to `test-gateway-candidates.swift`: every row of the table.

### 4.4 The picker (`GatewayPickerView.swift`)

- Row label: `gateway.displayName` (`:60`); identifier
  `"gateway-\(gateway.displayName)"` (`:63`) — so a 443 row keeps today's
  `gateway-<host>` and every existing test, and an 8443 row is
  `gateway-<host>:8443`, unambiguous.
- `onSelect(gateway.origin)` (`:58`, `:153`) — the callback's contract stays
  "the gateway's origin, as a string".
- `savedHost: String?` (`:26`) becomes `saved: GatewayEndpoint?`, passed to
  `discovery.start(saved:shownAt:)` at `:80`, `:131`, `:136`, `:146`.
- `useManual` (`:159-170`): when `manualEndpoint` is nil, set
  `manualError = "Enter a host, or host:port (1–65535)."` instead of returning
  silently. The tailnet check (`:163-166`) keeps using `URL(string:)?.host()`:
  the policy is host-based (§4.7).
- Placeholder text (`:91`) gains the form: "byskebox, byskebox:8443, or
  byskebox.example.ts.net".

### 4.5 Call sites of the saved gateway

All three pass `GatewayEndpoint(origin: <the saved URL string>)`:

- `app/App/Browser/DashboardRootView.swift:200` — first run: `saved: nil`.
- `app/App/Browser/DashboardRootView.swift:249` — Find from the unreachable
  banner: `saved: GatewayEndpoint(origin: homePage.url)`.
- `app/App/Settings/SettingsView.swift:165` — Find gateways…:
  `saved: GatewayEndpoint(origin: viewModel.homePage)`.

An `http://` or bare legacy value gives nil, which only means "nothing to
probe first" — the load path for such a value is unchanged (ATS refuses it,
the unreachable banner shows), not a new case.

### 4.6 The session layer: what is already right, and the two lines that change

Already port-aware, cited so nobody "fixes" it:

- `BrowserViewModel.loadResolved` (`:361-367`) sets `allowedOrigin` from
  `GatewayAddress.origin(of:)`, which keeps `:8443`; `loadSessionURL` (`:916`)
  refuses a sign-in navigation whose origin differs, port included;
  `haveSameWebOrigin` (`:588-603`) compares effective ports.
- `SessionManager.matches` (`:348-357`) compares the bridge frame's
  `securityOrigin.port` (0 → scheme default) with the session origin's.
- `TokenInput.signInURL(origin:token:)` (`app/App/Session/TokenInput.swift:77-80`)
  builds `<origin.absoluteString>/?token=…`, so the redemption goes to the
  ported origin.
- `Workspace.selectGateway` logs `Gateway chosen: <origin>`
  (`app/App/Workspace/Workspace.swift:160`) and `LogRedaction.redact` keeps
  the port (`app/App/Logging/LogRedaction.swift:87`): the app log names the
  ported origin on every load.

Changes:

- `SessionManager.gatewayHost` (`:116`) **stays host-only** and keeps feeding
  `foreignLinkHost` (`:266-273`): the CLI's sign-in link names the gateway
  without a port even when serve is on 8443, because KiroCrew derives it from
  `tailnet_host` and pins serve to 443 (`urls.py:457-458`,
  `tailnet_serve.py:73`). A host-only comparison is what keeps such a link
  from being flagged as foreign; the app uses the link's token at the
  selected origin regardless (R23).
- New `SessionManager.gatewayDisplayName: String?` =
  `GatewayEndpoint(origin:)?.displayName` of the session origin. The sheet's
  target (`app/App/Session/TokenEntrySheet.swift:48`, identifier
  `token-sheet-target`) and the foreign-link sentence (`:82`) show it. Existing
  tests assert `hasSuffix(gatewayHost)`, which stays true for 443.
- Cookies: KiroCrew names them by the port in the `Host` header, falling back
  to its listen port only when the header has none (`token_auth.py:1353-1369`);
  behind serve on 8443 the browser sends `Host: box…:8443`, so the cookies are
  `mc_token_8443` / `mc_refresh_8443`, not `mc_token_5476`. (The earlier draft
  of this spec said the names would not change; it was wrong.) WebKit scopes
  cookies by host, so a `:443` session's `mc_token_5476` is sent to `:8443`
  too and ignored there. `SessionCookies.summaries(of:host:)`
  (`app/App/Diagnostics/SessionCookies.swift:40-51`) therefore **stays
  host-keyed** and groups by the name's port, as R37 finding 8 built it;
  Status shows one line per port when more than one exists. Sign-out (R32)
  wipes the whole data store, both ports.

### 4.7 Host-only comparisons that must stay host-only

Each was checked; none should learn about ports, for the reason given:

| Site | Why host-only is right |
|---|---|
| `app/TSNet/TailnetProxyPolicy.swift:243-256` `matchingRule(for:)` | `matchDomains` carries names and CIDRs; the split tunnel routes by destination host, and the same host on any port takes the same path. "Add the port everywhere" would break routing. |
| `GatewayPickerView.useManual` `:163-166` | Asks the policy above whether the host is carried; the port is irrelevant to that. |
| `GatewayDiscovery.sweep` `:127-130` | Same: never probe a host the proxy would not carry, whatever the port. |
| `GatewayCandidates.select(savedHost:)` `:76-89` | Orders peers; a peer is a host. The saved port is applied by `probeOrder`. |
| `app/App/Browser/HomePageAvailability.swift:40-81` | "Is this host a peer of the tailnet?" — decided from `DNSName`, which has no port. |
| `SessionCookies.summaries(of:host:)` | Cookies are host-scoped (§4.6). |
| `app/App/Diagnostics/DiagnosticsView.swift:81` | Feeds the above. |
| `SessionManager.gatewayHost` / `foreignLinkHost` | §4.6. |
| `app/TSNet/TSNetManager.swift:340` | Classifies a loopback failure by host; unrelated to gateways. |
| `app/App/Network/StableProxyPolicy.swift:49`, `app/App/Testing/TestNetworkFixture.swift:72` | Suffix checks on peer names. |
| `app/App/Browser/BrowserTab.swift:52-57, 99` `displayHost` | Cosmetic, and there is no chrome that shows it. Left alone. |
| F6's `unless-domain: [<gateway host>]` | WebKit's `if-domain`/`unless-domain` match hosts by design; the rule list's job is "no other host", and "no other port" is `NavigationPolicy`'s, which already compares full origins. A switch from `box:443` to `box:8443` needs no new list. |

### 4a. The gateway's origin allowlist is port-blind: what happens, and the resolution

Verified against the installed 0.6.0 source (read, never run), file:line:

- **The allowlist never contains a ported tailnet origin.**
  `build_allowed_origins` adds `https://<tailnet_host>` and nothing else for
  the tailnet (`kiro_crew/dashboard/urls.py:454-458`), with the docstring
  "no port, because tailscale serve fronts the dashboard on 443" (`:432-434`).
  The background "origin recovery" adds the same portless form
  (`dashboard/tailnet.py:756`). `tailnet_serve.py:66-73` pins
  `SERVE_HTTPS_PORT = 443`, and `publish` passes `--https=443` (`:587`).
- **The check is an exact string match on `scheme://host[:port]`.**
  `check_origin` (`dashboard/origin.py:257-271`) reduces the `Origin` (or,
  for the CSRF middleware, the `Referer`) to its first three `/`-separated
  parts and tests set membership. A browser at `https://box…:8443` sends
  `Origin: https://box…:8443`, which is not in the set. The loopback
  same-origin fallback (`:272-287`) applies to loopback hosts only.
- **Every mutating request and the WebSocket go through it.** The CSRF
  middleware (`dashboard/server.py:653-707`) guards every method but
  GET/HEAD/OPTIONS unless `is_csrf_exempt` — whose only entry is the Teams
  webhook (`dashboard/token_auth.py:560-571`). `/api/ws` calls
  `check_origin(require=True)` before upgrading (`dashboard/ws.py:513-521`).
- **GETs pass.** The `Host` barrier compares hostnames with the port stripped
  (`urls.py:486-507`, `origin.py:340-345`), so the shell, the assets,
  `/manifest.json` and `/api/auth/me` all answer. **Discovery's two-GET
  fingerprint cannot tell**; a token redemption (`GET /?token=`) succeeds and
  `/api/auth/me` answers 200, so the app would even report the session
  active. Then the WebSocket is refused, the ~1 h refresh POST is refused,
  sign-out is refused, F3's share is refused. "Looks fine, does nothing" —
  the exact failure this project exists to eliminate.
- **The override is an environment variable read once at startup.**
  `KIROCREW_CORS_ORIGINS` is split on commas and added as-is
  (`urls.py:468-470`), evaluated where `build_allowed_origins` is called
  (`server.py:3787`, `:3879`, `:4546`) — i.e. at gateway start; a change needs
  a restart. The other route, `dashboard.url` in config, refuses to start
  without token-auth middleware, which means Slack (`server.py:3874-3892`):
  not the path.

**Resolution, in three parts. All three are required.**

**(A) Owner side, per gateway moved to 8443** — the only thing that makes it
work: start the gateway with `KIROCREW_CORS_ORIGINS=https://<fqdn>:8443` in
its environment (the launchd plist or systemd unit that runs it), restart it,
and confirm in its log the line `tailnet access enabled: trusting origin
https://<fqdn>` still appears (the portless one is added too; both are
needed, since the 443 origin may stay in use). Then the grant's port list
(R40) and the serve command (§8).

**(B) App side — the origin check.** The app must not hide (A) being missing.
One mechanism, in the session layer, credential-less and side-effect-free:

- `PageScriptSources.sessionFetch` (`app/App/Browser/PageScriptSources.swift:124-133`)
  gains an argument `credentials` (`'same-origin'` or `'omit'`), passed to
  `fetch`. `SessionHost.sessionFetchStatus(_:method:timeout:)`
  (`SessionManager.swift:51`) gains `credentials: SessionCredentials = .sameOrigin`
  and `BrowserViewModel.sessionFetchStatus` (`:923-937`) forwards it in the
  `arguments` dictionary. `M4`'s check and R32's logout keep `same-origin`;
  the contract in the file's comment ("`omit` would make the logout a no-op")
  stays true and is why the default does not change.
- `SessionManager` gains `enum OriginCheck { unknown, accepted, refused }`
  and `@Published private(set) var originCheck = .unknown`, reset by
  `reset(notice:)` (`:121-130`). In `navigationFinished()` (`:176-184`), once
  per gateway document, it runs
  `checkOrigin()`: `POST /api/auth/refresh` with `credentials: .omit`,
  timeout 10 s, and classifies the status with a pure, host-tested
  `GatewayCandidates.originCheck(status: Int?) -> OriginCheck`:
  **401 or 429 → accepted** (the request got past the CSRF barrier: no cookie
  → `no_refresh_cookie`; or the shared 60/min bucket, R37);
  **403 → refused** (the middleware's text/plain `CSRF check failed`);
  nil or anything else → unchanged. Why this request: the browser always
  sends `Origin` on a POST; with no cookie the handler rotates nothing, so
  the R25 lineage hazard is not touched; the only cost is one tick of a
  rate-limit bucket per document load. Log:
  `Session: origin check at <origin>: accepted|refused (HTTP n)`.
- `DashboardContent.gatewayContent` (`DashboardRootView.swift:333-376`) shows
  a banner after the unreachable banner (`:348-351`), same style, identifier
  `gateway-origin-refused-banner`, when `session.originCheck == .refused`.
  Text: §2. When the sheet is up, `session.message` is set to the banner's
  first sentence if it is nil (identifier `token-sheet-message` exists).
- Status → Dashboard session gains a row **Origin accepted**:
  `yes` / `no` / `not checked` (`DiagnosticsView.swift:115-120`), row
  identifier `diag-origin-accepted` in the existing `diag-` convention
  (`diag-session-expires`, `diag-access-expires`).
- The check runs on every gateway, 443 included; on 443 it always says
  `accepted`, which is the negative control the session suite asserts.

**Rejected alternative, recorded:** a third, POST-shaped request in
discovery's probe. It would send an unauthenticated POST to every candidate
on every *Search again*, tick the refresh bucket that every client behind
serve shares (R37), and still not cover a manually typed or relaunched
gateway, which discovery never probes (M5.5). The page-side check covers all
three cases with one request per load.

**(C) The fake gateway must enforce the same rule**, so an 8443 gateway
without (A) fails in the suite and not on the phone. It already does by
construction: `Page.allowed_origins` is built from `--host` as
`https://<host>` (`testing/harness/fake_gateway.py:828-829`), the CSRF step
is an exact set test (`:578-585`), `/api/ws` the same (`:662-666`), and
`host_name()` strips the port as the real barrier does (`:470-475`); cookies
already follow the Host port (`:477-480`). What it lacks is the override and
the evidence. Add:

- `--allow-origin <origin>` (repeatable; startup) and
  `POST /__config?allow_origin=<url-encoded origin>` (runtime; cleared by
  `__reset`), both adding to `Page.allowed_origins`. Models
  `KIROCREW_CORS_ORIGINS`.
- Counters `csrf_denials` (`:585`) and `ws_origin_denials` (`:666`), and a
  `cookie_ports` list in `snapshot()` (`:415-421`) recording every port a
  `Set-Cookie` was named for (`auth_cookies`, `:493-506`).
- `gateway_check.py` steps (host-side, `make gateway-check`): a POST with
  `Origin: https://gw.tail-scale.ts.net:8443` and `Host:
  gw.tail-scale.ts.net:8443` is the text/plain CSRF 403 and counts one
  `csrf_denials`; after `__config?allow_origin=…` it is 401
  `no_refresh_cookie`; a redemption with that `Host` sets `mc_token_8443` and
  `mc_refresh_8443` and `cookie_ports` lists `8443`; a `/api/ws` upgrade with
  the ported `Origin` is 403 before and 101 after.

Until an 8443 gateway is verified end to end on the device — the page loads,
Status says "Origin accepted: yes", the WebSocket connects, a sign-out is
confirmed by the gateway — 443 stays the default everywhere and 8443 is
opt-in.

### 4.8 Harness

**`testing/tsnet-harness`** (`main.go`):
- `peerSpec` (`:435-438`) gains `port int`; `startPeer` (`:454-488`) listens
  on `fmt.Sprintf(":%d", port)` instead of the literal `":443"` (`:476`).
  Existing peers keep 443.
- New flag `-gateway-alt 127.0.0.1:8445` (`:212` area) and `Mode.WithAlt`,
  set by `POST /reset?alt=1` (`:868-873`). `peerSpecs` (`:441-450`) adds
  `{"gw-alt", gatewayAltAddr, 8443}` only when both hold. **Off by default**,
  so every existing discovery test keeps its single-gateway shape; F1's tests
  opt in. `?gw=0` leaves both gateway peers out.
- `selftest.go`: when `-gateway-alt` is set, a step "gw-alt forwards tailnet
  :8443 to <addr>, and is journaled" (curl through the probe node's SOCKS to
  `https://gw-alt.<suffix>:8443/` with `-k`, then `journalHas(h, "gw-alt", …)`),
  and "a reset without `alt=1` has no gw-alt". `Makefile` `check` passes
  `-gateway-alt 127.0.0.1:$(DASH_PORT)` as it passes `-gateway`.
- Note for the reader: `DASH_PORT ?= 8443` (`testing/harness/Makefile:27`,
  `tsnet-harness/Makefile:18`) is the fake *dashboard's* loopback port on the
  Mac. It is not a tailnet port and has nothing to do with this feature; the
  coincidence is worth one sentence so nobody "fixes" it.

**`testing/harness`**:
- `leaf.cnf`: add `DNS:gw-alt.tail-scale.ts.net` to `subjectAltName`
  (explicitly, never a wildcard — the M3 lesson in the file). `gen-certs.sh`
  regenerates when `leaf.cnf` is newer than the leaf (`gen-certs.sh:33-36`);
  the CA is unchanged, so the simulator's trust is unchanged.
- `Makefile`: `GW_ALT_PORT ?= 8445`, `GW_ALT_CONTROL_PORT ?= 8482`, targets
  `gateway-alt-up` / `gateway-alt-down` mirroring `gateway-up`, starting a
  second `fake_gateway.py` with `--host gw-alt.tail-scale.ts.net
  --allow-origin https://gw-alt.tail-scale.ts.net:8443` (the owner did (A)).
  `harness-reap` learns the two ports.
- `harness-up`'s stub proxy gains
  `--map gw.tail-scale.ts.net:8443=127.0.0.1:$(GW_PORT)`: the stub keys on
  `host:port` (`socks5stub.py:93`), so `gw:8443` reaches the **same** fake
  gateway as `gw:443`, whose allowed origin is only `https://gw…` — the
  "moved to 8443 without the override" case, for the session suite, with no
  second instance.

**`scripts/test-discovery.sh`**: `HARNESS_ARGS` gains
`-gateway-alt 127.0.0.1:8445`; `make gateway-alt-up` after `gateway-up`, and
the teardown, and `:8482/__state` in the failure dump. The sweep parser
(`:154-181`): the `probing` regex becomes
`probing (\d+) of (\d+) peer\(s\) on 2 port\(s\): (\d+) probe\(s\); first (\S+)`;
signatures are `(peers, probes, gateways, answered, failed)`:

| Peer set | Signature |
|---|---|
| default (gw, dash, plain, slow) | `(4, 8, 1, 2, 6)` — gw:443 gateway; dash:443 answered; gw:8443, dash:8443, plain×2, slow:8443 refused; slow:443 timed out |
| `gw=0` | `(3, 6, 0, 1, 5)` |
| purgatory | `(4, 8, 0, 0, 8)` — still exactly one such sweep |
| `alt=1` (+ gw-alt) | `(5, 10, 2, 3, 7)` |

The 4–15 s bound stays: `slow:443` still holds for 4 s. New check: every
sweep's `first` is `dash.tail-scale.ts.net:443` (nothing saved that is a
peer) or `gw-alt.tail-scale.ts.net:8443` (D6's launch); anything else fails.

**Invariants this must not break** (see `../../app/AGENTS.md`):
- the split tunnel decides what goes through the proxy; only tailnet hosts
  do — and it matches hosts, not ports (§4.7);
- `allowFailover` stays false;
- ATS stays on with no exceptions; HTTPS only, at any port;
- D1: nothing here writes new logs to disk or uploads anything; the new
  `os_log` lines carry origins, never tokens;
- a vendored-tree change is its own commit (R16) — none is needed here;
  `tsnet.go` is cited, not changed.

## 5. State and migration

**What is persisted.** One string: `WorkspaceDefinition.homePageURL`
(`app/App/Workspace/WorkspaceStore.swift:58`), in `workspaces.json`. It is
written by the `HomePage.$url` observer through `GatewayAddress.stripParameters`
(`app/App/Workspace/Workspace.swift:110-120`) and read back through
`GatewayAddress.persistable` (`Workspace.swift:101`), which reduces a URL to
`scheme://host[:port]` and drops only a default port (`GatewayAddress.swift:41-46`).
**There is no separate port field, and this spec adds none**: the port lives
in the URL, so the "host plus a port field" case does not arise. The UI-test
seed `-UITestHomePage` goes through the same `persistable`
(`WorkspaceManager.swift:121-128`), so a test can seed `https://gw…:8443`.

**Reading a value, by origin of the value:**

| Stored `homePageURL` | Written by | Read as |
|---|---|---|
| `""` | any version | no gateway; the first-run picker (unchanged) |
| `https://box.<t>.ts.net` | the current version | endpoint `(box…, 443)`; loads `https://box…`; probed first on 443, then 8443 |
| `https://box.<t>.ts.net:443` | cannot occur (`persistable` strips it) | — |
| `https://box.<t>.ts.net:8443` | this version | endpoint `(box…, 8443)`; loads the ported origin; probed first on 8443 |
| `http://box` | a pre-M5 build (R2 era) | `GatewayEndpoint(origin:)` nil → nothing probed first; the load path is today's (ATS refuses it; unreachable banner). Not a new case. |

No migration code. `URL.port == nil` means 443, in one place
(`GatewayEndpoint.init?(origin:)`).

**What the owner sees on upgrade:** nothing. The gateway loads as before; the
Settings field shows the same string; the first sweep he starts probes both
ports. A saved 443 gateway whose machine has since moved serve to 8443 is
found by the next *Search again* (its 8443 probe is in the first round), and
choosing the `:8443` row rewrites the stored URL.

**Downgrade** (recorded, not handled): an older build reads
`https://box…:8443` and loads it — `URL(string:)` keeps the port and R3's
origin keeps it — but its picker probes only 443 for the saved host, and its
Settings field commits through the old `manualOrigin`, so pressing Return
there silently rewrites the gateway to `https://box…` (443). A downgrade
followed by a Settings edit loses the port.

## 6. End-to-end tests

The discovery suite (`scripts/test-discovery.sh`,
`app/UITests/DiscoveryTests.swift`) runs the real app against the L2 harness
with a fake KiroCrew peer; the session suite (`scripts/test-session.sh`,
`app/UITests/SessionTests.swift`) runs it against the real 0.6.0 bundle behind
the stub proxy. `alt=1` and the ported map are opt-in per test, so every
existing test keeps its shape. New constants: `gatewayAltControl =
"http://127.0.0.1:8482"`, `gatewayAltHost = "gw-alt.tail-scale.ts.net"`,
`portedGateway = "https://gw.tail-scale.ts.net:8443"`; `resetHarness(alt:)`;
`resetFakes` resets the alt instance too.

| Test | Suite | Asserts | Shown to fail by |
|---|---|---|---|
| D1 `testAGatewayServingOnly8443IsFoundAndLoads` — `reset?alt=1`, first run | discovery (L2) | the picker lists `gateway-gw.tail-scale.ts.net` **and** `gateway-gw-alt.tail-scale.ts.net:8443` and does not auto-choose (two found); tapping the alt row: `token-sheet-target` label ends `gw-alt.tail-scale.ts.net:8443`; the alt instance's `__state.requests` begins `GET /manifest.json`, `GET /api/auth/me` (the probe) and later holds `GET /` (the load); the harness journal has an entry with `peer == "gw-alt"` from the app's node; the gw instance's requests hold the probe but no `GET /` | running it against today's build: only 443 is probed, the alt row never appears and the 15-s wait for it fails. Breaking it on purpose after the change: `standardPorts = [443]` — same failure |
| D2 sweep signature with both ports | discovery (L2), enforced by `test-discovery.sh` from the app log | D1's sweep logs `(5, 10, 2, 3, 7)` inside 4–15 s, and every other sweep in the run matches the table in §4.8; at least one sweep found a gateway; exactly one purgatory sweep | `standardPorts = [8443]`: the signature becomes `(5, 10, 1, 1, 9)`, not in the set. Or reverting the `probing` log line: the regex matches nothing and the script fails with "no sweep that found a gateway was logged" |
| D3 `testManualEntryWithAPortReachesThePortedGateway` — `reset?alt=1&gw=0` (only gw-alt exists, on 8443, so the sweep finds nothing and the picker stays) | discovery (L2) | typing `gw-alt:8443` and *Use this gateway* loads it: the alt instance's `__state.requests` gains `GET /`; `token-sheet-target` ends `:8443` | today's `manualOrigin`: the port is dropped, the load goes to `gw-alt:443`, tsnet resets it, `nav-error-overlay` appears and the alt instance never sees `GET /` |
| D4 `testABadPortIsRefusedInPlace` — same reset as D3 | discovery (L2) | for each of `gw-alt:0`, `gw-alt:abc`, `gw-alt:70000`, `gw-alt:`: `gateway-manual-use` is disabled, Return shows `gateway-manual-error` with "Enter a host, or host:port (1–65535).", the picker stays, and neither fake instance nor the dashboard records any request (all three `__state` request lists empty) | making `manualEndpoint` fall back to 443 for an unparseable port: the load goes to `gw-alt:443` (a request appears in the journal as a refused connect) and the error never shows |
| D5 `testAPortedGatewayPersistsAcrossRelaunch` — D1's choice, then terminate and relaunch with only `-TestControlURL` | discovery (L2) | the token sheet appears with target `…gw-alt…:8443`; the alt instance's first request after `resetFakes` is `GET /` (loaded directly, not probed — no sweep on relaunch, M5.5); the dashboard's paths hold no `/manifest.json` | rendering `GatewayEndpoint.origin` without the port: the relaunch loads `gw-alt:443`, which is reset by tsnet; the alt instance sees nothing and the sheet never appears |
| D6 `testTheSavedPortedGatewayIsProbedFirst` — launch with `-UITestHomePage https://gw-alt.tail-scale.ts.net:8443`, `reset?alt=1`, then Settings → *Find gateways…* | discovery (L2) + `test-discovery.sh` | both rows listed; the sweep's log line reads `first gw-alt.tail-scale.ts.net:8443` (the script's `first` check) | removing rule 1 of `probeOrder`: the line reads `first dash.tail-scale.ts.net:443`, which the script rejects for a sweep that also found two gateways (only D6 does) |
| S1 `testASignInThroughAPortedOriginWorksWhenTheGatewayAllowsIt` — `__config?allow_origin=https://gw.tail-scale.ts.net:8443`, launch with `portedGateway` | session (M4) | the sheet's target ends `:8443`; pasting a fresh `__mint` link signs in as `testPastingCLIOutputSignsIn` proves it (`redemptions == 1`, `app_auth_checks ≥ 1`, `session-signin-button` absent); `ws_opens ≥ 1` (the real bundle opened its WebSocket through the ported origin); `cookie_ports == ["8443"]`; `gateway-origin-refused-banner` absent; Status rows `diag-session-expires` shows the 30-day expiry and the new `diag-origin-accepted` reads `yes` | omitting the `__config` step: `ws_opens` stays 0 and the banner assertion fires (that is S2). Classifying 401 as refused: the banner appears on a working gateway |
| S2 `testAGatewayThatRefusesThePortedOriginSaysSo` — no `allow_origin`, launch with `portedGateway` | session (M4) | the page loads (shell 200); `gateway-origin-refused-banner` exists within 15 s and its label contains `https://gw.tail-scale.ts.net:8443` and `KIROCREW_CORS_ORIGINS`; `token-sheet-message` carries the first sentence; `csrf_denials ≥ 1`; Status → Origin accepted `no`; the app log has `origin check … refused (HTTP 403)` | adding `--allow-origin https://gw.tail-scale.ts.net:8443` to `gateway-up`: no 403, no banner, the assertion fails. Reverting the page-side check: `csrf_denials` stays 0 |
| S3 the 443 gateway is unchanged — one assertion added to `testSignedOutShowsTheNativeSheetAndHidesThePageBanner` | session (M4) | `gateway-origin-refused-banner` does not exist after the load; Status → Origin accepted `yes` | classifying 401 as refused (the negative control for S1's classifier) |
| H1 gw-alt forwards :8443 | `make -C testing/tsnet-harness check` | the self-test's new step reaches the forward through the probe node and finds the `gw-alt` journal entry; a reset without `alt=1` lists no `gw-alt` | pointing `-gateway-alt` at a closed port: curl fails, the step fails |
| H2 the fake enforces the port-blind allowlist | `make -C testing/harness gateway-check` | the four steps in §4a(C) | comparing hosts instead of origins in the fake's CSRF step: the first step's 403 never comes |
| L0 (bonus) `GatewayEndpoint`, `manualEndpoint` table, `probeOrder`, `originCheck` | `make test-policy` (`test-gateway-candidates.sh`) | every row of §4.1, §4.3, the three `probeOrder` orders in §4.2, and 401/429/403/nil classification | each `expect` is a single boolean; flip any rule and its line fails |

The L1 offline suite is not changed and must stay green (§7): it is the
existing proof that a ported origin flows through the browser layer and
that nothing leaks.

## 7. Acceptance criteria

- A gateway serving **only** 8443 is discovered and listed within R39's
  budget: first gateway ≤ 5 s of the picker appearing, sweep ≤ 15 s and ≥ 4 s.
  Instrument: the app's sweep log lines, parsed and enforced by
  `scripts/test-discovery.sh` (D2).
- Both ports of one sweep are probed on every candidate: the signature
  `(5, 10, 2, 3, 7)` in D1's sweep. Instrument: the same script.
- `host:8443` typed by hand loads the ported dashboard; `host` alone loads
  443; a bad port starts no load. Instruments: the fake instances' `__state`
  request lists (D3, D4).
- The chosen gateway with its port survives a relaunch and is loaded without
  a sweep. Instrument: the alt instance's first request is `GET /` (D5).
- A gateway that refuses the ported origin is named as such within 15 s of
  loading, in the layout, on the sheet, and in Status; one that accepts it
  shows nothing. Instruments: the fake's `csrf_denials`, `ws_opens`,
  `cookie_ports` counters and the app log's `origin check` line (S1–S3).
- `scripts/test-offline.sh` and `scripts/test-tailnet.sh` pass unchanged:
  no plain-HTTP attempt at any port (the L1 anti-leak counts stay zero).
- `make test-policy` passes with the new host checks.
- **On the device**, after (A), the serve move and the grant change: the app
  finds the machine as `<fqdn>:8443` without being told, Status → Origin
  accepted says `yes`, live updates arrive, and *Sign out of the dashboard*
  reports the gateway confirmed it (R32's "ended at the gateway" path, which
  is a POST and so proves the origin). Instrument: Settings → Diagnostics.

## 8. Open questions and owner actions

**Owner actions, per gateway to move (in this order):**
1. Check 8443 is free on the machine: `lsof -nP -iTCP:8443 -sTCP:LISTEN`
   (serve will take it host-wide too, exactly as it takes 443).
2. Put `KIROCREW_CORS_ORIGINS=https://<fqdn>:8443` in the gateway's
   environment and restart it (§4a A). Confirm the trusted-origin line in its
   log.
3. `tailscale serve --bg --https=8443 http://127.0.0.1:5476`, then
   `tailscale serve --https=443 off`.
4. Change the grant's `"ip"` to `["8443"]` — or `["443", "8443"]` while
   machines are mixed (R40).
5. Expect KiroCrew's `tailnet status` to report nothing published: its
   publisher and checker are pinned to 443 (`tailnet_serve.py:73`, `:472-517`).
   Do not run its `tailnet up` again; that re-publishes 443 host-wide.
6. Run `testing/harness/contract_test.py` (O7) once against a real 8443
   gateway, with a short-TTL link from a file or env var, to confirm the
   cookie names and the CSRF 403's shape match the fake's.

**Open:**
- Report upstream? KiroCrew pins serve to 443 and derives a portless origin;
  a `dashboard.tailscale.serve_port` setting that also feeds
  `build_allowed_origins` is the clean fix. Same shape as the fonts report
  (#13161). Olof's call whether to file it.
- Should a third port ever be probed? Not until something needs it; each port
  is another `N` probes and moves the deadline cliff from 18 candidates to 12.
- F4's open question ("show which port is being tried") is answered by
  `GatewayEndpoint.displayName`: the connecting state shows `box:8443`.

## 9. Log

- 2026-09-23: specified. R39's budget rise landed first (app `8a5220b51`), so
  the doubled probe count has room.
- 2026-09-23, design pass: read every host/port/origin site in `app/` and the
  installed 0.6.0 server. Findings that changed the spec: the session and
  browser layers were already origin-keyed with the port (the draft said the
  session was keyed by host and that cookie names would stay `_5476`; both
  wrong — §4.6); the origin check moved from "decide during implementation"
  to a page-world credential-less POST (§4a B) with the discovery-side
  variant rejected on the record; tsnet resets unlistened ports, so a second
  port costs a round trip, not a timeout (§4.2); the harness's `gw-alt` peer
  is opt-in per reset so the existing discovery tests keep their shape; the
  443 row's accessibility identifier is unchanged for the same reason;
  `DASH_PORT = 8443` on the Mac is an unrelated coincidence, noted so nobody
  fixes it.
