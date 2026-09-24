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
approval concept, and the only hardcoded network constants are Tailscale's own
address ranges — the IPv4 CGNAT range and the IPv6 ULA range
(`TailnetProxyPolicy.swift:93-95`). Purgatory appears in the docs, the
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
Both reset at the top of `sweep()`, beside `gateways = []` (`:116`) — `start()`
only cancels the previous run, bumps the generation and spawns the sweep
(`:91-97`); `candidateCount` is likewise set inside `sweep()` (`:119`, `:131`).

The existing summary log line gains `probed=N/M truncated=yes|no`, so a device
log answers this without a debugger.

**Wrong, and it broke the discovery suite for one commit.** That summary line and
`Discovery: probing N of M peer(s)` are *instruments*:
`scripts/test-discovery.sh` parses both (`:151`, `:155-156`), and the summary's
regex is anchored with `$`. Appending the counters inside it, and rewording the
probing line, made both regexes miss — at which point the parser records no sweep
at all and the suite fails with "no sweep that found a gateway was logged; this
measured nothing". Both lines are now restored byte-for-byte and the counters are
on their own line, `Discovery: probed=N/M truncated=yes|no skipped=K [next=i]`,
which the suite's pre-filter grep does not even select. F4 §4.8 states the rule
this should have followed: **the existing lines do not change; new numbers get a
new line.** Verified by running the suite's two regexes against both the restored
and the broken strings.

**As built, three corrections to the above** (2026-09-23) — each because the
specified version would have let the picker state something untrue:

1. **Truncation is derived after the task group, not set in the `.deadline`
   case, and its test is "a candidate has no verdict" rather than "`pending`
   still has an element".** A probe that was *dispatched* and was still in
   flight when the deadline cancelled it has no verdict either, and the
   specified version counted it as done. That both overstated the count and,
   worse, made the resume cursor skip it for good. So: `sweepTruncated` and
   `nextCandidateIndex` come from `plan.first { !probedHosts.contains($0.peer.host) }`,
   and the cursor is the **first** candidate without a verdict, not where
   dispatch stopped. Re-probing a few that did answer is the cheap side of
   that trade. This buys the invariant §4.2's wording depends on: not
   truncated means every candidate was probed.
2. **`probedCount` counts distinct hosts, and accumulates across a chain of
   continuations.** A counter would have been wrong twice: a continuation
   always re-probes the saved gateway (it is candidate 0), and §4.3's resume
   may re-probe a peer that timed out inside the dispatched window — so the
   owner would read "checked 25 of 24". It is `probedHosts.count`, reset only
   when `continueFrom == 0`. `probeAnyway` (§4.4) deliberately does **not**
   count: that peer is not one of the candidates `candidateCount` counts, and
   counting it would report more computers checked than there were to check.
3. **`candidateCount` stays the whole ordered candidate list on a
   continuation**, not the resumed slice. It is the denominator the picker
   divides by, so shrinking it would turn "checked 16 of 17" into a
   finished-looking search of a 40-machine tailnet. `gateways` is likewise
   kept across a continuation: the tap means "find *more*", and clearing the
   list would make what was already found vanish.

### 4.2 Say what was checked

`GatewayPickerView`'s empty state (`:66-68`) becomes three cases, and no case
may claim a number it did not probe:

| Condition | Text |
|---|---|
| `candidateCount == 0` | unchanged (no candidates at all) |
| `!sweepTruncated` | "No Kiro Crew gateway answered among all \(probedCount) computer(s) on your tailnet. Enter one below." |
| `sweepTruncated` | "No Kiro Crew gateway answered. Checked \(probedCount) of \(candidateCount) computer(s) in \(elapsed) — the sweep ran out of time. Search again to continue." |

As built, the truncated line drops `\(elapsed)` — the number the owner can act
on is how many machines are left, and an elapsed time in a sentence about an
incomplete search reads as an excuse — and says "keep searching to try the rest",
matching the button, which relabels itself *Keep searching* when the sweep was
truncated. The button's two jobs were otherwise indistinguishable: *Search
again* meaning "start over" and meaning "continue" are different promises.

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

As built, the reported set is the three §1.1 rules **only**. "No MagicDNS name"
is unreachable: the loop drops a peer with an empty host before `exclusion` is
asked, and a peer with no name is nothing the owner could tap anyway.

Tapping one probes that host with the same `probe(_:session:)` and, if it
answers, appends it to `gateways` like any other. It is not persisted as an
exception: if it is really the gateway, choosing it saves it, and the saved
gateway is always probed first thereafter.

`probeAnyway` applies the same split-tunnel gate the sweep does — a host no
proxy rule carries is refused rather than probed, because that probe would go
direct, off the tailnet. A skipped peer comes from the netmap, so in practice
this only ever drops a malformed name; it is there so the tap cannot become the
one path to the network that skips the check. A peer that is probed and does not
answer stays listed, with "— tried, no answer" appended to its reason, so the
owner can see the filter was not what hid a gateway.

### 4.4a What the suite needed before any of §6 could be written

None of §6's cases were reachable with the harness as it stood, and the gap was
not small: a large tailnet, a peer reporting a NAS's OS, and a peer owned by
someone else are all *control-plane* facts, and the harness only had real tsnet
peers. Standing up forty of those is not a test, it is a second product.

So `testing/tsnet-harness` gained three endpoints on its existing test API:

| Endpoint | Does |
|---|---|
| `POST /peers?n=N&name=PREFIX&os=OS` | adds N **synthetic** peers — present in the netmap, candidates by every one of R26's filters, and with nothing behind them, so a probe stalls to the app's own 4 s timeout. That stall is what makes a truncated sweep reproducible. |
| `POST /peer-os?hostname=H&os=OS` | makes a real, answering peer report another OS (`synology`) |
| `POST /peer-owner?hostname=H&user=ID` | gives it a different, non-zero owner |

Four things about it that are not obvious, all of them learned by getting them
wrong first:

1. **A synthetic node needs `Name` set to the full MagicDNS FQDN with a trailing
   dot.** The app reads `PeerStatus.DNSName`, and a peer with no name is dropped
   *before* any filter — so the peers would exist and be invisible. `testcontrol`'s
   own `AddFakeNode` sets neither `Hostinfo` nor `Name`, which is why it could
   not be used.
2. **The owner must be non-zero.** `exclusion` treats `UserID == 0` as "unknown",
   which does *not* exclude — so `user=0` would have produced a test that passed
   while proving nothing. The harness refuses it with that reason.
3. **The OS override has to be applied to the incoming map request, not pushed.**
   `serveMap` stores `req.Hostinfo` into the node *after* the `HoldMapRequest`
   hook returns, so a push from the hook is overwritten by the very request that
   triggered it. Rewriting `req.Hostinfo.OS` in place is what sticks. Without
   stickiness the override silently reverts when the peer next re-sends its
   Hostinfo, and the test goes green for the wrong reason.
4. **Synthetic peers are reported as harness peers** in `GET /state`, because the
   suite identifies the app's node as the one node that is *not* one.

`name` is load-bearing in one test: the candidate list is alphabetical after the
saved gateway, so the forty peers are named `a-*` to sort *before* `gw` and put
the gateway out of a first sweep's reach. The harness's default prefix sorts
after it, which would have made `testSearchAgainContinuesFromWhereItStopped`
pass without the cursor ever being exercised.

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

### 6.1 As built — three rows of the table above were wrong

Written before the fixture existed, and corrected by running it (2026-09-24):

- **40 peers is not enough to truncate; it is the boundary.** A 12 s deadline at
  concurrency 12 with a 4 s probe timeout reaches roughly 36 candidates, and the
  first run measured `probed=43/43 truncated=no` in one test beside
  `probed=40/44 truncated=yes` in another — the same mechanism, opposite verdicts,
  one candidate apart. The truncation test now presents **90**. A test whose
  subject is a coin flip is worse than no test.
- **"After one *Search again* the gateway appears" is not assertable with this
  fixture**, and the reason is worth keeping: forty peers reported *online with no
  data plane* congest tsnet enough that a probe to the genuinely reachable gateway
  also exceeds its 4 s budget (`socks[41] CONNECT gw…:443` reached the proxy and
  never completed; the relay's session cap was never hit). So the test asserts
  what §4.3 actually promises and what the owner actually reads: the truncated
  "Checked 40 of 44" becomes "Checked 44 computers" after one tap, and the button
  returns to *Search again*. That is a stronger test of the cursor than a page
  load, because it cannot pass while the cursor is broken. The congestion itself
  is §8's open question.
- **"An offline peer is not listed as skipped" is not end-to-end testable.** The
  harness runs `AllOnline: true` and its `MapResponse` marks every peer online;
  there is no per-node switch without a vendored `testcontrol` change, which R16
  would make its own commit and which is not worth it. That rule is covered by
  the host table in `test-gateway-candidates.swift`, which does assert it.
- The finished-sweep text reads "Checked 6 computers in 4 s…", not "among all 6":
  §4.2's wording was merged with F4 §3.5's answered/unanswered split (see F4 §4.8,
  "as built"), since F4 specified the same row first and without knowing about
  truncation.

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
  `grant`, `purgatory`, `100.8` in `App/` and `TSNet/` returns nothing in
  code. (Today it returns only the doc comments in
  `App/Workspace/WorkspaceStore.swift:90-158` that explain why the tsnet state
  directory must not move in the author's environment; those are prose about
  a policy, not an implementation of one, and may stay.)

## 8. Open questions and owner actions

- **Olof:** should the skipped list be collapsed (as specified) or shown
  expanded when it is short, say three or fewer? Collapsed is specified because
  on his tailnet the list is usually empty and an always-open section would be
  clutter for the common case.
- **Open, with evidence, and worth answering before anyone runs this on a big
  restricted tailnet:** many peers that are *online but unreachable* delay probes
  to the reachable ones past the 4 s budget. Measured while building §6's tests
  (2026-09-24): with 40 such peers, a sweep truncated at 40 of 44 as designed,
  and the continuation's probes to `gw` and `dash` — both genuinely reachable —
  reached the proxy (`socks[41] CONNECT gw…:443`) and never completed inside the
  4 s timeout. It is not the relay's session cap: `SocksRelayCapacity` logged no
  refusal or eviction in the whole run.

  Mostly this is a property of the fixture, and that is the reassuring part: a
  real tailnet reports an unreachable peer as **offline**, and `exclusion` drops
  offline peers before they are probed, so they never compete for tsnet at all.
  The exception is the environment this feature was written for — a restricted
  tailnet where peers are *visible and drop traffic*, which is exactly device
  purgatory on the author's own. At four peers that is harmless (the purgatory
  test sweeps in 4 s). Whether it stays harmless at forty is unknown, and the
  honest answer is that the instrument to find out already exists: run a sweep on
  a large restricted tailnet and read `probed=`/`truncated=`.
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
