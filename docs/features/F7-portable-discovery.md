# F7 — Discovery works on someone else's tailnet, and never overstates what it checked

| | |
|---|---|
| **Status** | spec — not implemented. Split out of the portability review because these are **behaviour** changes, where the same review's hygiene fixes went straight in |
| **Requested** | 2026-09-23, by Olof: "what if someone else wants to run this? The most specific piece to my setup is the purgatory and IP namespace. Someone who runs a flat tailnet without access controls wouldn't need it. Look through both code and documentation (and UI) to see how that environment would work vs my specific one, and suggest any changes" — then: "looks like all those details above should be fixed" |
| **Revision** | one when built: it changes which peers are probed (R26's filter set) and what the picker claims |
| **Touches** | `App/Discovery/GatewayCandidates.swift`, `App/Discovery/GatewayDiscovery.swift`, `App/Discovery/GatewayPickerView.swift`; `scripts/test-gateway-candidates.swift`; the discovery suite |

## 1. Why

The portability review found the app is **already agnostic** about tailnet
policy: across `App/` and `TSNet/` there is no grant, ACL, address range or
approval concept, and the only hardcoded network constant is Tailscale's own
CGNAT range (`TailnetProxyPolicy.swift:93`). Purgatory appears in the docs, the
runbook and the test harness — never in the product. So a flat-tailnet user
needs no code change to connect at all.

What the review did find is that discovery is tuned, silently, for **a small and
heavily restricted tailnet** — which is exactly the shape of the author's. Three
findings, in the order they would bite a newcomer.

### 1.1 A legitimate gateway can be filtered out with no trace

`GatewayCandidates.exclusion` (`GatewayCandidates.swift:62-72`) drops a peer for:

| Rule | Line | Who it excludes wrongly |
|---|---|---|
| untagged **and a different owner** | `:68-70` | a gateway belonging to a colleague or family member on a shared tailnet |
| **`sharee`** | `:66` | a gateway reached through Tailscale's node sharing |
| **OS not `linux`/`macos`/`windows`** | `:56`, `:67` | a gateway on a NAS (Synology reports `synology`) or a BSD |

None of these can misfire for the author: his gateways are his own or tagged,
and they run Linux and macOS. For someone else the result is a picker that says
nothing answered while the gateway sits there, reachable, one manual entry away.
The exclusion reason is computed — `exclusion` returns a *string* — and then
thrown away.

To be fair to the existing code, the filters are cheap-probe optimisations and
the comment at `:58-60` already shows care: an **unknown** OS or owner does not
exclude. The gap is that a *known-and-different* one excludes silently.

### 1.2 A large tailnet is probed incompletely, and nothing says so

`concurrency = 12`, `requestTimeout = 4 s`, `deadline = 12 s`
(`GatewayDiscovery.swift:66-69`). The comment is explicit that the budget is
"two rounds of `concurrency` probes", i.e. **about 24 peers**. Past that the
`pending` iterator is simply abandoned when the deadline fires
(`:160-186`) — the remaining candidates are never probed and never counted.

The author's candidate list is tiny, so this has never mattered. On a 60-peer
tailnet it means discovery quietly stops a third of the way through.

### 1.3 The picker then claims it checked everything

`GatewayPickerView.swift:66-68`:

> "No Kiro Crew gateway answered among \(discovery.candidateCount) computer(s)
> on your tailnet."

`candidateCount` is the number of candidates *selected* (`:131`), not the number
**probed**. So on that 60-peer tailnet the app asserts it checked 60 computers
when it checked 24. This is the only place in the review where the environment
difference produces a **false statement to the user** rather than merely a
slower or emptier result, which is why it is the highest-priority item here.

## 2. What the owner sees

**Working, on any tailnet.** The picker lists the gateways that answered, as
now. When none answered it says what it actually did:

> No Kiro Crew gateway answered. Checked 24 of 61 computers in 12 s — the sweep
> ran out of time. *Search again* continues from where it stopped.

and when it did finish:

> No Kiro Crew gateway answered among all 7 computers on your tailnet.

**When a peer was skipped**, the picker offers it rather than hiding it. Below
the list, collapsed:

> 3 computers were not checked · *Show*

which expands to the host names with the reason next to each ("another owner",
"OS synology", "shared from another tailnet"), each **tappable to probe anyway**.
That turns the §1.1 failure from a mystery into one tap, without loosening the
default filters into a slow sweep of every phone on the tailnet.

**Failing:** unchanged. A dead proxy, a node that is connected but reaching
nothing (the restricted-tailnet case, `../SETUP.md` §6), and a sweep with no
candidates at all keep the states they have — those are F4's territory, and this
spec must not duplicate them.

## 3. Non-goals

- **Not a change to what counts as a gateway.** The fingerprint (manifest named
  "Kiro Crew" plus `/api/auth/me` answering 403 with `X-Auth-Required`) is
  untouched.
- **Not probing everything.** The OS and owner filters stay *on by default*;
  they exist because a personal tailnet is mostly phones. This spec makes them
  visible and overridable, not absent.
- **No ACL awareness.** The app must stay ignorant of grants and ranges. The
  right response to "connected but reaches nothing" is documentation
  (`../SETUP.md`), not inference.
- **No new persisted state** beyond what §5 says.

## 4. Design

### 4.1 Report probed-vs-selected honestly

`GatewayDiscovery` gains two published values beside `candidateCount`:

```swift
@Published private(set) var probedCount = 0      // probes that returned a verdict
@Published private(set) var sweepTruncated = false // deadline fired with work left
```

`probedCount` increments wherever `answered` and `failures` already do
(`:170-180`). `sweepTruncated` is set in the `.deadline` case (`:164-168`) **only
if `pending` still has an element** — a deadline that fires with an empty queue
is not truncation, and conflating the two would cry wolf on every slow sweep.
Both reset in `start()` next to `candidateCount = 0` (`:119`).

The existing summary log line gains `probed=N/M truncated=yes|no`, so a device
log answers this without a debugger.

### 4.2 Say what was checked

`GatewayPickerView`'s empty state (`:66-68`) becomes three cases, and no case
may claim a number it did not probe:

| Condition | Text |
|---|---|
| `candidateCount == 0` | unchanged (no candidates at all) |
| `!sweepTruncated` | "No Kiro Crew gateway answered among all \(probedCount) computer(s) on your tailnet. Enter one below." |
| `sweepTruncated` | "No Kiro Crew gateway answered. Checked \(probedCount) of \(candidateCount) computer(s) in \(elapsed) — the sweep ran out of time. Search again to continue." |

### 4.3 Continue rather than restart

A truncated sweep that restarts from the top can never reach the tail of a large
tailnet, however many times it is tapped. So `start()` takes a
`continueFrom: Int = 0` cursor: the index into the ordered candidate list at
which the previous sweep stopped, published as `nextCandidateIndex`. *Search
again* passes it when `sweepTruncated`, and 0 otherwise.

The saved gateway is always probed first regardless of the cursor
(`GatewayCandidates.select` already puts it first), because the most likely
reason for searching again is that it came back.

### 4.4 Make the skipped visible, and probeable

`GatewayCandidates.select` currently discards the excluded. It gains a sibling
that keeps them with their reason — the string `exclusion` already returns:

```swift
struct Skipped: Equatable, Sendable { let host: String; let reason: String }
static func selectWithSkipped(_ peers: [GatewayPeer], selfUserID: Int64?,
                              savedHost: String?) -> (probe: [GatewayPeer], skipped: [Skipped])
```

`select` stays, implemented in terms of it, so existing host tests keep passing
unchanged. Offline and expired peers are **not** reported as skipped: they
cannot answer, so listing them would be noise. The reported set is exactly the
three §1.1 rules plus "no MagicDNS name".

Tapping one probes that host with the same `probe(_:session:)` and, if it
answers, appends it to `gateways` like any other. It is not persisted as an
exception: if it is really the gateway, choosing it saves it, and the saved
gateway is always probed first thereafter.

### 4.5 Deliberately unchanged

The budgets (`requestTimeout = 4`, `deadline = 12`, `concurrency = 12`) stay as
R39 set them from a real relayed intercontinental path. Raising the deadline to
cover a large tailnet would make every *small*-tailnet sweep slower in the
common case; the cursor of §4.3 covers the tail instead, and the honesty of
§4.2 means the user is told rather than misled. If measurement later shows the
concurrency could rise safely on a big tailnet, that is its own change with its
own evidence.

## 5. State and migration

None persisted. `probedCount`, `sweepTruncated` and `nextCandidateIndex` are
in-memory publishers, reset per sweep. No workspace-definition change, so
nothing to migrate in either direction.

## 6. End-to-end tests

The discovery suite (`scripts/test-discovery.sh`) drives the app's real tsnet
node against `testing/tsnet-harness`, which can present an arbitrary peer set —
that is what makes the large-tailnet and skipped-peer cases testable at all.

| Test | Suite | Asserts | Shown to fail by |
|---|---|---|---|
| `testATruncatedSweepSaysSoAndCountsOnlyWhatItProbed` | discovery (M5) | harness presents **40** candidate peers, none a gateway: the empty state contains "Checked" with a probed count **< 40**, names 40 as the total, and says the sweep ran out of time; the app log carries `probed=N/40 truncated=yes` with the same N | against today's build: the text claims all 40 were checked. Also by presenting 5 peers instead: the truncated wording must **not** appear, which pins the "deadline with empty queue is not truncation" rule |
| `testSearchAgainContinuesFromWhereItStopped` | discovery (M5) | 40 peers with the **only** gateway placed last in the ordered candidate list: it is not found by the first sweep; after one *Search again* it appears | dropping the cursor (`continueFrom: 0` always): the gateway is never found however many times the test taps |
| `testAFinishedSweepSaysItCheckedThemAll` | discovery (M5) | 6 peers, no gateway: the text says "among all 6", and `probedCount == candidateCount` | reporting `candidateCount` in both branches — the wording diverges only when the counts do |
| `testAPeerSkippedForItsOSIsOfferedAndCanBeProbed` | discovery (M5) | the harness presents the gateway with OS `synology`: the sweep finds nothing, "1 computer was not checked" is shown, expanding names the host with reason `OS synology`, and tapping it finds the gateway and connects | against today's build: the peer is silently absent and there is nothing to tap. Also by asserting an offline peer is **not** listed as skipped |
| `testAGatewayOwnedByAnotherUserIsOffered` | discovery (M5) | same shape, with the gateway untagged and a different `UserID`: reason reads `another owner` | removing the owner rule from the reported set |
| `test-gateway-candidates.swift` (extended) | host (`make test-policy`) | `selectWithSkipped` returns each §1.1 reason for the right peer; offline/expired peers appear in neither list; `select` returns exactly what it does today for every existing case | changing a reason string; letting an offline peer into `skipped`; any divergence between `select` and `selectWithSkipped.probe` |

## 7. Acceptance criteria

- The empty state never names a number larger than what was probed — the
  discovery suite asserts the counts against a 40-peer harness.
- A gateway at the tail of a 40-peer tailnet is reachable through repeated
  *Search again*, without raising any timeout.
- A peer excluded by the owner, sharee or OS rule is listed with its reason and
  can be probed in one tap; an offline peer is not listed.
- `select`'s behaviour is unchanged for every input the host tests already
  cover.
- The app still contains no ACL, grant or address-range concept — grep for
  `grant`, `purgatory`, `100.8` in `App/` and `TSNet/` returns nothing but
  Tailscale's CGNAT constant.

## 8. Open questions and owner actions

- **Olof:** should the skipped list be collapsed (as specified) or shown
  expanded when it is short, say three or fewer? Collapsed is specified because
  on his tailnet the list is usually empty and an always-open section would be
  clutter for the common case.
- Worth deciding once there is a second user: whether `sharee` should be
  probed by default rather than merely offered. It is the one exclusion with a
  real argument for being on by default — a shared-in node is usually someone
  else's infrastructure — and the one most likely to hide a legitimately shared
  gateway.

## 9. Log

- 2026-09-23: split out of the portability review. The review's hygiene items
  (generic hostname placeholders, the fixture-tailnet allow-list replacing a
  guard that named one real tailnet, an overridable bundle id, the
  `latchkey-*` node name, a setup guide for a flat tailnet) went in directly;
  these three are behaviour changes and wait for a spec. The headline of that
  review belongs here too: **the app was already tailnet-policy agnostic**, so
  portability is a matter of not lying about what discovery did, and not hiding
  peers it declined to probe.
