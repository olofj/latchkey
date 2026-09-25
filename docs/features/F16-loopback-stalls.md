# F16 — A stalled loopback costs seconds, not a minute

| | |
|---|---|
| **Status** | **stage 1 built** 2026-09-25 (`5864df9`, `c5d5198`, `4c5a65d`; §9). Stages 2-4 designed, not built. Four stages, **stage 1 first** (§4.0). Specced from [issue #3](https://github.com/olofj/latchkey/issues/3). Of its four faults, two are confirmed as stated, one is a real code defect whose trigger this pass could not show happens on its own, and **one is contradicted by a recorded measurement** (§1.5). That one gets measured before anything is fixed |
| **Requested** | 2026-09-25, by Olof, as issue #3: *"The network layer has several ways to stall for seconds to a minute when the loopback path misbehaves."* Owner-visible evidence from 2026-09-24: the gateway picker sat at "Searching…"; reported as *"scan didn't work, nothing found"*, together with an empty screen showing only the cogwheel |
| **Revision** | none. No documented behaviour changes. Timeouts get shorter on paths where the owner is waiting, and a stalled loopback is now recovered |
| **Touches** | `TSNet/TSNetManager.swift` (status bound, recovery trigger, bus-watcher install, async relay start), `TSNet/SocksLogProxy.swift` (async `start`, one test hook), `App/Discovery/GatewayDiscovery.swift` (no change beyond the bounded closure it is handed), the vendored tree (**one** debug hook, its own commit, R16), the L2 lifecycle and discovery suites, L1, host tests |

Line numbers below are from `main` at `20aa1b6`. The issue's own line numbers
predate F8's implementation and are off by about 100 in `TSNetManager.swift`.
`ddc9f2b` touched the listener setup in `SocksLogProxy.startListener` (it
dropped `allowLocalEndpointReuse`) and does not affect anything here.

## 1. Why: each claim, checked against the code

### 1.1 Summary

| # | Issue's claim | Verdict | Stage |
|---|---|---|---|
| 2 | `backendStatus()` waits up to 60 s on UI paths; -1001 starts no recovery | **confirmed**. Timing bound checked in code; the stall itself has not been reproduced (no harness can produce it, §6.1) | **1** |
| 4 | A cancelled bus restart installs its watcher anyway, and the live bus goes unobserved | **defect confirmed, trigger not shown**. The install is unconditional. The interleaving the issue describes needs the stale restart to finish *after* recovery. The node actor's ordering makes that unlikely, but nothing prevents it | 2 |
| 1 | `SocksLogProxy.start()` blocks the main actor for up to 4 s | **confirmed** as a main-thread block. How often a listener is slow to reach `.ready` is **unmeasured** | 3 |
| 3 | A refused upstream leaves WebKit hanging for 60 s (-1001) | **contradicted in the simulator**: measured over 25 runs as a -1009 inside a 40 s bound. Device unmeasured | 4 (measure first) |

### 1.2 Fault 2: status waits have no bound below 60 s (confirmed)

- **The 60 s.** `LocalAPIClient.backendStatus()`
  (`ThirdParty/libtailscale/swift/TailscaleKit/LocalAPI/LocalAPIClient.swift:229-239`)
  calls `doSimpleAPIRequest` with its default `timeoutInterval: TimeInterval = 60`
  (`:337`, applied at `:357`), and exposes no parameter to change it.
- **UI callers that await it with no bound.**
  - Discovery. `Workspace.discovery` hands `GatewayDiscovery` the closure
    `await manager.refreshStatusNow()` (`App/Workspace/Workspace.swift:71-73`).
    The sweep awaits it at `GatewayDiscovery.swift:415` when nothing answered
    (`answered == 0, !failures.isEmpty`). **`phase` is still `.probing` for the
    whole wait**, so the button reads "Searching…"
    (`GatewayPickerView.swift:71`) and the progress row goes on counting
    seconds past "N of N done" (`:160-173`). `phase` changes only at `:438-442`.
  - `pageLoadFailed` (`TSNetManager.swift:716-753`) awaits `refreshStatusNow()`
    at `:726`, before its relay verdict. On a silent loopback, relay recovery
    is postponed by up to 60 s. Nothing freezes; the retry is just late.
  - The status poll (`:525-574`) awaits `client.backendStatus()` at `:533`
    serially, so a silent loopback turns one 5 s iteration into 60 s. Neither
    `model.localStatus` nor the `model.state` fallback (`:550-553`) moves in
    that time.
- **-1001 starts no recovery.** `isLocalLoopbackConnectionFailure`
  (`:452-461`) accepts only `NSURLErrorCannotConnectToHost` (-1004) and
  `NSURLErrorNetworkConnectionLost` (-1005). When the poll catches the timeout
  (`:562-568`) it logs `Status poll failed` and does nothing else, once a
  minute, indefinitely.
- **Only a loopback that accepts and never answers causes this.** A refused
  loopback fails with -1004 at once, and recovery already runs for that case
  (the lifecycle suite's `testDefunctLoopbackListenerIsReplacedAndNewConnectionsGetThrough`).
  Only the silent case waits out the 60 s.

**The tempting fix is wrong.** Adding -1001 to `isLocalLoopbackConnectionFailure`
looks like a one-line fix, and it would **restart the loopback every idle minute**.
The same function classifies the bus watcher's errors (`scheduleBusRestart`, `:417`),
and the watch-ipn-bus long-poll dies with a 60 s -1001 on every idle minute by design
(`:384-387`: "URLSession's default 60s request timeout kills it every minute of
idleness"). §4.1 keeps the new timeout a separate signal for that reason.

**Is this the owner's report?** Partly, and the log would settle it:

- **"Searching…" that does not end**: fault 2 is the likely cause. No other path
  keeps `phase == .probing` after every probe has returned. With a silent
  loopback the probes, which go through the same tsnet listener, all fail at
  their 4 s bound (`:146`). Then the 60 s status wait starts, and the picker
  reads "Searching…" for about 64-72 s in total.
- **"nothing found"**: this is also what F11 §1 attributed the same report to:
  a new node with no grant that reaches the dashboard. A sweep on a *healthy*
  loopback with no grant ends in about 4-12 s with "didn't answer at all". Both
  explanations fit the words, and they are not exclusive.
- **"an empty screen with just the cogwheel"**: fault 2 does **not** explain
  this. The picker is never empty; it always has the searching row and the
  manual-entry section. This part is more likely a page load that never
  committed. Nothing in this pass pins it to one of the four faults.
- **What would decide it:** the 2026-09-24 app log. A `Discovery: probing …`
  line followed about 60 s later by `Immediate status refresh failed: … -1001`
  means fault 2. A `Discovery: 0 gateway(s); … N failed` line within about
  12 s of it means F11's cause. See §8.

### 1.3 Fault 4: a stale bus restart can install its watcher (defect confirmed, trigger not shown)

**What the code does.** `startEventBus` (`:376-412`) always ends with
`busErrorWatcher?.cancel(); busErrorWatcher = busObserver` (`:407-410`). It does
not check `Task.isCancelled` and knows nothing about recovery generations.

- The ordinary restart (`scheduleBusRestart`, `:426-449`) checks cancellation
  only **after** `startEventBus` has returned (`:433-436`). By then it has
  already replaced the watcher. It cancels its processor, but the watcher it
  installed stays.
- `recoverLoopbackAfterFailure` (`:464-515`) cancels `busRestartTask` (`:469`)
  and installs its own watcher for `newConsumer` inside `startEventBus`
  (`:482-483`).

**The race.** Suppose a stale restart's `startEventBus` finishes after
recovery's. The stale restart then cancels the watcher recovery installed for
`newConsumer` and installs one for the **old** consumer. The new bus's processor
keeps delivering until its first death, which is the idle -1001 after about
60 s. `newConsumer.error` is then set with no subscriber, and the bus is never
restarted.

- **What stops when the bus is dead.** `browseToURL` comes only from the bus
  (`TSNetModel.swift:14`), and so does `loginFinishedGeneration` (`:19`). Tapping
  Login (`StatusViewModel.swift:243`) would then never open the sign-in sheet.
- **What keeps working.** Backend state and peers are still mirrored by the 5 s
  status poll (`TSNetManager.swift:550-560`). The gate therefore stays correct,
  which makes this fault quieter than the issue suggests.

**Why the trigger is not shown.** The stale restart is cancelled synchronously
on the main actor (`:469`), so at that moment it is suspended at one of the
awaits inside `startEventBus`:

- The first is `node.loopback()`, reached through
  `watchIPNBus → basicAuthURLRequest → tailscaleSession → proxyVia`
  (`URLSession+Tailscale.swift:18`) on the `TailscaleNode` actor. That call was
  enqueued **before** recovery's `node.restartLoopback()`.
- Recovery has to finish `restartLoopback()`, hop back to the main actor, and go
  through the same chain of awaits before it installs.

So the stale restart normally installs **first**, and recovery's later install
correctly replaces it. Actor scheduling is not FIFO by contract, so the bad
order is possible, but this pass found no path that makes it likely.

**A second instance of the same defect, which the issue does not list.**
`shutdown()` (`:984-1004`) cancels `loopbackRecoveryTask`, bumps
`loopbackRecoveryGeneration`, and sets `busErrorWatcher = nil`. A recovery that
is inside `startEventBus` at that moment installs its watcher **after**
shutdown cleared it. The generation check at `:484-488` comes too late to stop
that. A deleted workspace's manager is then left with a live watcher on a
closed node.

### 1.4 Fault 1: `SocksLogProxy.start()` blocks the main thread (confirmed; frequency unmeasured)

**The block.** `start()` (`SocksLogProxy.swift:147-158`) dispatches
`startListener` onto the relay's queue and then calls
`DispatchSemaphore.wait(timeout: .now() + startTimeout + 1)` (`:156`), with
`startTimeout` = 3 s (`:141`). The callers are all on the main actor, through
the synchronous `proxyConfig(upstreamHost:upstreamPort:credential:)`
(`TSNetManager.swift:614-670`; `start()` at `:637`):

- `tailscaleUp`'s `MainActor.run` (`:339-342`);
- loopback recovery (`:501`), inside a `Task` created on the main actor;
- the L1 fixture path `startFromTestFixture` (`:263`).

The completion runs on the relay's queue, not the main one, so this does not
deadlock. It only blocks.

**How long.** `startListener`'s own `asyncAfter` settles at 3 s (`:228-234`),
so the practical worst case is about 3 s of frozen UI. The semaphore's 4 s is
only its outer bound.

**What is not established.** The issue says this happens exactly when the
listener sits in `.waiting` during a recovery. That is plausible, since the
code logs `sockslog: listener waiting:` at `:222`. But no log in `docs/` records
that line or `listener not ready after`, so how often it happens is unknown.

**Precedent.** The restart path already has the fix
(`restartListener() async`, `:266-271`, used at `:839`). R30's review made
that change for this reason: "nothing waits on the main actor for the new port"
(`:256-257`). `start()` was not carried over. This is the sibling-path pattern
F8 §1.4 also found.

### 1.5 Fault 3: a refused upstream does not hang WebKit for 60 s in the simulator (contradicted)

**What the issue gets right.**

- The upstream `NWConnection` really has no `stateUpdateHandler`
  (`SocksLogProxy.swift:412-422`; `client.stateUpdateHandler = nil` at `:413`,
  and none is set on `upstream`).
- -1001 really is excluded from `transportFailureCodes`
  (`App/Network/SocksRelayPolicy.swift:134-141`), deliberately: "a slow gateway
  is not a dead listener".

**What it gets wrong.** The consequence it draws has been measured, and it does
not happen:

- `OfflineHarnessTests.testProxyGoneFailsWithoutDirectFallback` (`:142-150`)
  closes the stub proxy, which refuses at TCP level, with the relay in front,
  exactly as in production. It asserts the error page within **40 s**
  (`assertErrorPage`, `:1667`) and a connection-failure code.
- The comment at `:1675-1679` records the result over **25 runs**: -1009, with
  "the relay accepted, tsnet's port refused it, the relay closed on WebKit".
- `../DECISIONS.md` "Left open, deliberately" records the same -1009 as by
  design: "the status poll repairs it".

A 60 s hang ending in -1001 would fail that test on every run.

**Not measured.**

- How long the -1009 takes. The test only bounds it at 40 s.
- What closes the relay's session, given that no state handler is set. It is
  presumably the upstream `receive` or `send` completing with an error.
- The device, where iOS *defuncts* a listener rather than closing it. A
  defuncted socket may drop the SYN instead of refusing it. That would be a
  different shape from the one the issue names, and possibly a real stall.

Stage 4 therefore measures before it fixes.

## 2. What the owner sees

**Working:**

- **Picker on a silent loopback.** It leaves "Searching…" within about 3 s of
  the last probe returning. With the 4 s probe bound, that is at most about
  15 s after the sweep starts, never 72 s. It shows the existing P6 row
  (`gateway-proxy-unhealthy`: "…its own proxy didn't answer either. Search
  again in a moment…").
- **Recovery.** Within about 16 s of the loopback going silent (two bounded
  status polls, §4.1), the app replaces it just as it does a refused one, and
  *Search again* then works.
- **Page load failure on a silent loopback.** The relay verdict arrives in
  about 3 s instead of 60.
- **Relay listener slow to start** (stage 3). The UI stays responsive while it
  starts: a tap during those seconds is answered at once.
- **After a loopback recovery that raced a bus restart** (stage 2). Login still
  opens the sign-in sheet.

**Failing:**

- A loopback that stays silent after recovery: the picker still ends in P6
  within the bound, and the log records each attempt. This is not silent.
- Recovery itself failing: the existing `LocalAPI loopback replacement failed …;
  retrying through bus backoff` path (`:506-513`), unchanged.

## 3. Non-goals

- **No change to the bus's own 60 s idle death**, or to how the bus is
  restarted after one. That is the designed keep-alive substitute (`:384-397`).
- **No -1001 in `isLocalLoopbackConnectionFailure` or in
  `transportFailureCodes`** (§1.2, §1.5).
- **No bound on every LocalAPI call in this spec.** Stage 1 bounds the two
  status paths the issue names, plus the poll. `startLoginInteractive`
  (`StatusViewModel.swift:243`), `currentProfile` (`Workspace.swift:347`),
  `editPrefs` (`TSNetManager.swift:1068`) and the logout have the same 60 s
  exposure. They are listed in §8, not silently included.
- **No change to discovery's per-probe or sweep budgets** (4 s, 12 s,
  `GatewayDiscovery.swift:146-149`), or to the two log lines
  `scripts/test-discovery.sh` parses (`:313-320`, `:418`), which stay
  byte-for-byte.
- **No fix for fault 3 unless stage 4 measures a stall.**

## 4. Design

### 4.0 Order

1. **Fault 2 (stage 1).** It is the one with owner-visible evidence, and it
   makes the picker look broken for a minute.
2. **Fault 4 (stage 2).** A small change. Its consequence, a Login that does
   nothing, is severe even though its trigger is unproven.
3. **Fault 1 (stage 3).** Confirmed, bounded at about 3 s, frequency unknown.
   It is the larger change, because `proxyConfig` becomes async.
4. **Fault 3 (stage 4).** Measure. Fix only on evidence.

Each stage is a separate commit with its own tests. None depends on another.

### 4.1 Stage 1: bounded status on every path that waits for it

In `TSNetManager`:

```swift
/// A status request that was abandoned at its bound (F16). Distinct from
/// any NSURLError on purpose: the bus's idle -1001 is routine, this is not.
struct LoopbackStatusTimeout: Error {}

/// How long a status request may take on a path something is waiting on.
/// Loopback answers in milliseconds; the bound covers a busy node actor.
nonisolated static let statusBound: Duration = .seconds(3)

/// `backendStatus()` raced against `statusBound`. TailscaleKit's request
/// carries a 60 s timeout (LocalAPIClient.swift:337) that no caller here
/// may inherit. The loser is cancelled; URLSession's async API cancels the
/// underlying task with it.
nonisolated static func boundedStatus(_ client: LocalAPIClient,
                                      within bound: Duration = statusBound)
    async throws -> IpnState.Status
```

Implement it with `withThrowingTaskGroup`: one child calls
`client.backendStatus()`, the other sleeps `bound` and throws
`LoopbackStatusTimeout()`. Take the first result and `cancelAll()`.

**Alternative, not chosen:** add a `timeoutInterval` parameter to the vendored
`backendStatus()`. That puts a vendored commit on the stage's critical path for
no gain. Stage 1 already needs one vendored commit (§6.1), but only in test
builds.

Callers:

- **`refreshStatusNow()`** (`:1050-1061`) uses `boundedStatus`, so discovery
  (`GatewayDiscovery.swift:415`) and `pageLoadFailed` (`:726`) are bounded
  without being edited.
- **The status poll** (`:533`) uses `boundedStatus`, so the loop keeps a cadence
  of 5 s plus at most 3 s.
- **Recovery on the new signal.** Add
  `@MainActor private var consecutiveStatusTimeouts = 0`.
  - Every `LoopbackStatusTimeout`, from either caller, increments it.
  - Every successful status resets it.
  - At **2** it calls `recoverLoopbackAfterFailure(LoopbackStatusTimeout())`
    and resets.

  Two strikes rather than one: a single slow answer, such as a node actor busy
  in `restartLoopback` or a GC pause, must not replace a working listener.
  `RestartLoopback` changes the SOCKS credential and replaces the relay
  (`:498-501`), which is not free. The same reasoning is behind
  `sessionCheckUnanswered`'s "twice in a row" (`:755-762`).
- **Log each timeout** as `Status request abandoned after 3 s (n of 2 before
  loopback recovery)`. Stage 1's tests assert that exact line.

`isLocalLoopbackConnectionFailure` is **unchanged**. Add a comment above it
naming the bus's idle -1001 as the reason -1001 is not in the set. That keeps
§1.2's tempting fix from being made later by someone who has not read this
spec.

### 4.2 Stage 2: whoever decided to install the watcher checks, then installs

`startEventBus` stops installing. It returns what it built:

```swift
/// Starts a bus watch and its error observer. Installs NOTHING (F16): the
/// caller installs both, after its own staleness check, or cancels both.
func startEventBus(localAPI: LocalAPIClient, consumer: TSNetConsumer) async throws
    -> (processor: MessageProcessor, errorWatcher: AnyCancellable)

/// Installs a started bus. Only called after the caller's own check.
private func installBus(_ processor: MessageProcessor, _ watcher: AnyCancellable)
```

Each caller checks before installing, and on a failed check cancels **both**
the processor and the watcher:

| Caller | Check before `installBus` |
|---|---|
| `tailscaleUp` (`:313`) | none beyond today's; it is the first install |
| `scheduleBusRestart`'s task (`:431-437`) | `!Task.isCancelled` |
| `recoverLoopbackAfterFailure` (`:482-491`) | `!Task.isCancelled && generation == loopbackRecoveryGeneration`. This also closes the `shutdown()` instance from §1.3, because shutdown bumps the generation |

Test builds only (R15): `installBus` records
`ObjectIdentifier` of the consumer the watcher observes. If that is not
`self.consumer`, it logs `BUS WATCHER MISMATCH: observing <a>, current <b>`.
§6.3 asserts that the line never appears. That is the instrument for a fault
whose natural trigger was not shown.

### 4.3 Stage 3: the relay starts without blocking

- In `SocksLogProxy`, `start()` becomes `func start() async -> UInt16?`. It is a
  `withCheckedContinuation` around `startListener`, the same shape as
  `restartListener() async` (`:267-271`). The semaphore and `Box` (`:352-356`)
  go.
- `proxyConfig(upstreamHost:upstreamPort:credential:)` and
  `proxyConfig(_ loopback:)` become `async`. `refreshProxyPolicyIfNeeded` does
  not start a relay and stays synchronous.
- Two hazards come with the new suspension point.
  1. **Re-entrancy.** Two callers can both see `socksLogProxy == nil` across the
     `await` and start two relays. Add
     `@MainActor private var relayStart: Task<SocksLogProxy?, Never>?`: a second
     caller awaits the one in flight instead of starting another.
  2. **Staleness.** A loopback recovery or `shutdown()` can replace or clear the
     relay while a start is pending. After the `await`, keep the result only if
     nothing replaced it. Use the same identity check as `restartSocksRelay`
     (`:841-842`); otherwise `stop()` the new relay. Recovery also rechecks its
     generation after the `await`, before publishing (`:501`).
- Callers:
  - `tailscaleUp` publishes with
    `model.proxyConfiguration = await proxyConfig(loopback)`, still on the main
    actor, suspended rather than blocked.
  - `startFromTestFixture` (`:263`) wraps its publish in a `Task`.
- A third hazard: **the first load must not run before the proxy exists.**
  Today the synchronous publish closes a window that an async one opens.
  - `BrowserViewModel.loadInitial` checks only `tsnetModel.state == .Running`
    (`BrowserViewModel.swift:470`), not the proxy.
  - `startFromTestFixture` sets `model.state` (`TSNetManager.swift:262`)
    **before** it publishes the proxy (`:263`).
  - With an `await` between the two, `$state`'s sink (`BrowserViewModel.swift:288-291`)
    can call `loadInitial` while `dataStore.proxyConfigurations` is still
    empty. The first load would then go direct, off the tailnet. In L1, where
    `localtest.me` resolves to loopback, a direct load can *succeed*, which is
    exactly the leak the R10 tests exist to catch.

  So `loadInitial` gains `tsnetModel.proxyConfiguration != nil` in its guard.
  `applyProxy` already calls `loadInitial` when the proxy arrives
  (`:449-455`). The picker already waits for both (`GatewayPickerView.swift:127`).

### 4.4 Stage 4: measure fault 3, then decide

- **Measure.** Add to `testProxyGoneFailsWithoutDirectFallback` and its
  `-NoSocksLog` twin: record launch → `nav-error-overlay` in seconds, and read
  the relay's `socks[n] relay finished (<reason>)` from the journal-adjacent app
  log. Report both. Nothing new is asserted yet; this stage produces a number.
- **Fix only if** the measured time exceeds about 10 s in the simulator, or a
  device log shows a `socks[n] relay accepted` with no `finished` for about
  60 s. The fix would be:
  - Give `upstream` a `stateUpdateHandler`. On `.waiting` or `.failed` before
    `.ready`, log `socks[n] upstream refused: <error>`, cancel both connections,
    and `finishRelay(id:reason: "upstream refused")`. That gives WebKit an
    immediate connection failure.
  - Leave `transportFailureCodes` as it is.
- **Otherwise**, record the time next to the -1009 entry in `../DECISIONS.md`
  and close fault 3 as not reproducible in the simulator, open for device
  evidence.

### 4.5 Invariants

- **Unchanged:** the split tunnel, `allowFailover == false`, ATS, and D1. No
  new log line carries a URL or credential. The timeout lines name only
  durations and counts.
- **The vendored hook** (§6.1) is its own commit (R16), needs `make framework`,
  and compiles only under the same debug export as `DebugDefunctLoopback`.

## 5. State and migration

Nothing is persisted. `consecutiveStatusTimeouts` and `relayStart` are in
memory only.

## 6. End-to-end tests

### 6.1 Instruments: what the harnesses must be able to do

| Fault | Can today's harness produce it? | What is needed |
|---|---|---|
| 2 | **No.** L1 has no LocalAPI: the fixture path has no `localAPIClient`, so `refreshStatusNow` returns `false` at once (`:1051`). L2's chaos hooks only *close* the loopback (`tsnet.go:495-502`) or shut sockets down; both fail fast with -1004 or -1005. The tsnet harness's `-slow-peer` (`testing/tsnet-harness/main.go:248`) is a silent *peer*, not a silent loopback | A vendored hook, `(*Server).DebugStallLoopback()`, exported as `tailscale_debug_stall_loopback` and `TailscaleNode.debugStallLoopback()`. It marks the **current** loopback listener so that its handler accepts every connection and then holds it without reading or answering. `RestartLoopback` replaces the listener, and the mark goes with it: that is what lets a test prove recovery. App hook `-UITestStallLoopback`, fired through the existing chaos plumbing (`-UITestTCPChaosDelay`, `runTCPChaosTestIfNeeded`, `:950ff`) |
| 4 | **No.** The interleaving is a scheduling accident (§1.3) | Two test-build hooks that force it. `-UITestBusErrorAfter <s>` sets the current consumer's `error` to a synthetic `URLError(.timedOut)` once, which starts an *ordinary* restart. `-UITestBusInstallDelay <s>` sleeps between `startEventBus` returning and `installBus` in the ordinary restart only. Combined with `-UITestDefunctLoopback` inside the delay, the stale install lands after recovery's, every run. **This proves the guard, not how often the race happens naturally**, and the test's comment must say so |
| 1 | **Partly.** L1 exercises `start()` on the main actor at launch (`startFromTestFixture`), but nothing makes the listener slow or measures the main thread | `-UITestRelayReadyDelay <s>` in `SocksLogProxy.startListener`: hold the `.ready` handling for *s* seconds (2, under `startTimeout`, so the start still succeeds). Plus a test-build main-thread monitor: a background timer every 50 ms posts to the main queue and records the largest gap, published as the accessibility element `main-thread-max-stall-ms` (the same pattern as `tcp-chaos-test-status`) |
| 3 | **Yes, for the refused shape**: the stub's `POST /close`, and L2's `-UITestDefunctLoopback`. **No, for a dropped SYN**, which cannot be arranged on the simulator's loopback | Nothing new for the measurement. The dropped-SYN shape stays device-only, and this spec says so rather than inventing a test for it |

### 6.2 Stage 1

| Test | Suite | Asserts | Shown to fail by |
|---|---|---|---|
| `testAStalledLoopbackEndsTheSearchWithinSeconds` | discovery (M5, L2) | With `-UITestStallLoopback` fired before the picker opens: `gateway-proxy-unhealthy` appears, and `gateway-refresh` no longer reads "Searching…", within **16 s** of `gateway-searching` first appearing. The app log has `Status request abandoned after 3 s` | Today's build: the label is still "Searching…" at 16 s, and stays so until about 64-72 s |
| `testAStalledLoopbackIsReplacedAndTheSearchThenFindsTheGateway` | discovery | Same launch. Within **25 s** the log has `LocalAPI loopback recovered`. Tapping `gateway-refresh` then lists `gateway-<gw>` | Removing the two-strike trigger: no recovery line, and the second sweep also ends in P6. Also by making the hook survive `RestartLoopback`: the test must then fail, which shows it is recovery that fixed it |
| `testAStalledLoopbackUnderALivePageIsRecovered` | lifecycle (M6, L2) | `runTCPChaos(hook: "-UITestStallLoopback", expectsLoopbackRecovery: true)`: `tcp-chaos-test-status` reaches `recovered`, and the dash peer journals the page's reconnect | Today's build: the status stays `damaged`, and the poll logs one -1001 a minute |
| `test-loopback-stalls.swift` | host (`make test-policy`) | `boundedStatus` returns `LoopbackStatusTimeout` within bound + 100 ms against a never-completing call, and cancels it. Two timeouts trigger recovery, one does not, and a success resets the count. **A bus -1001 is not a loopback failure** | Adding -1001 to `isLocalLoopbackConnectionFailure` fails the last assertion. That is the guard against §1.2's tempting fix |

`scripts/test-discovery.sh`'s sweep parser only accepts sweep signatures it
knows (`:146-150`). The stalled sweep is new: every probe fails and none
answers, the same shape as `purgatory_sig`. Add it explicitly, with a comment
naming this test, and do not widen the check.

### 6.3 Stage 2

| Test | Suite | Asserts | Shown to fail by |
|---|---|---|---|
| `testABusRestartOverlappingRecoveryLeavesTheBusObserved` | lifecycle | `-UITestBusErrorAfter 2 -UITestBusInstallDelay 6 -UITestDefunctLoopback` with chaos delay 3. Recovery completes. **No `BUS WATCHER MISMATCH`** is in the log. Then the harness expires the node's key (`POST /expire`), and tapping Login opens the sign-in sheet: `browseToURL` arrived over the bus | Today's build with the same hooks: the mismatch line appears, and after the new bus's first death the Login tap opens nothing. (That needs one idle death, about 60 s; `-UITestBusErrorAfter` can fire a second time to shorten it) |
| `testShutdownDuringRecoveryInstallsNoWatcher` | host, or L1 if it proves impractical there | With recovery held inside `startEventBus`, `shutdown()` runs, and after release `busErrorWatcher == nil` | Today's code: a watcher is installed after shutdown |

### 6.4 Stage 3

| Test | Suite | Asserts | Shown to fail by |
|---|---|---|---|
| `testASlowRelayListenerDoesNotFreezeTheApp` | L1 | `-UITestRelayReadyDelay 2`: after the dashboard loads, `main-thread-max-stall-ms` < 250, and the stub journal shows the first load came **through the relay** (the async start still published the relay's port, not tsnet's) | Today's build: about 2000 ms. Also by making the hook's delay exceed `startTimeout`: the journal then shows a direct-to-stub load and the log shows `using tsnet proxy directly`, which proves the test can tell the two apart |
| the existing R10 anti-leak tests (`testBlackholedProxyFailsWithoutDirectFallback`, `testProxyGone…`), run with `-UITestRelayReadyDelay 2` added | L1 | Unchanged: zero requests reach the dashboard directly, even when the proxy is published seconds after `Running` | Leaving `loadInitial`'s guard as it is today: the first load goes direct during the delay, and `assertZeroRequests` fails |
| `testARecoveryDuringASlowRelayStartPublishesOnlyTheNewRelay` | lifecycle | `-UITestRelayReadyDelay 2 -UITestDefunctLoopback`: after recovery, exactly one `relay listening` line per recovery generation, and the page reconnects | Removing the post-await identity check: two relays start, and the log shows the stale one published |

### 6.5 Stage 4

There is no new test, only the timing added to the two existing proxy-gone
tests (§4.4). **If the fix is made**, a test comes with it: stage 4's
`testProxyGoneFailsWithoutDirectFallback` asserts the error page within 5 s.
Before the fix, that assertion is shown to fail by running it against the
unfixed build.

## 7. Acceptance criteria

- **Discovery on a silent loopback.** The picker leaves "Searching…" at most
  16 s after the sweep starts. Instrument: `testAStalledLoopbackEndsTheSearchWithinSeconds`.
- **Recovery.** A silent loopback is replaced within 25 s with nothing tapped.
  Instrument: the `LocalAPI loopback recovered` log line in two suites.
- **No UI path waits on `backendStatus()` longer than `statusBound`.** Grep: no
  bare `backendStatus()` outside `boundedStatus`.
- **-1001 is not a loopback failure.** Instrument: the host test.
- **Every installed bus watcher observes the current consumer.** Instrument:
  the test-build mismatch line, absent in the lifecycle suite.
- **No main-thread gap over 250 ms from a relay start.** Instrument:
  `main-thread-max-stall-ms`. Grep: no `DispatchSemaphore` in
  `SocksLogProxy.swift`.
- **Fault 3 has a number.** The proxy-gone time-to-error is recorded in
  `../DECISIONS.md`, with the fix made or declined on that number.
- `scripts/test-discovery.sh`'s sweep-signature check still passes, with the
  stalled signature added explicitly.

## 8. Open questions and owner actions

- **Olof: the 2026-09-24 log.** If Settings → Diagnostics → Logs from that
  session still exists (or the container can be pulled with
  `xcrun devicectl device copy from --domain-type appDataContainer`), look for
  `Immediate status refresh failed` with -1001 about 60 s after
  `Discovery: probing`. That decides whether fault 2 caused the report or only
  could have (§1.2). It would also show whether the "empty screen with the
  cogwheel" matches any of these faults. Nothing here explains it yet.
- **The other LocalAPI calls on UI paths** (§3): Login (`startLoginInteractive`),
  `currentProfile`, `editPrefs`, logout. Each can wait 60 s on a silent
  loopback. Login is the one the owner would feel. Should stage 1 bound it as
  well? Recommended yes, with the same helper, but only for Login: a bounded
  logout that gives up early would leave the owner believing they had signed
  out.
- **`statusBound` = 3 s** is chosen, not measured. Stage 1 should log any
  status request slower than 500 ms, so a week of device use shows whether 3 s
  is tight.
- **Device-only**: whether a defuncted relay or tsnet listener drops SYNs
  rather than refusing them (§1.5), and whether a `NWListener` really sits in
  `.waiting` after suspension (§1.4). Both would show up in a device log as
  `sockslog: listener waiting:` or `listener not ready after`.

## 9. Log

- 2026-09-25: specced from issue #3. Each claim was checked against `main` at
  `20aa1b6` before being repeated.
  - **Faults 1 and 2**: confirmed as stated.
  - **Fault 4**: the defect is real, but the interleaving it describes runs
    against the node actor's usual ordering, so the test forces it rather than
    waiting for it. Writing it up turned up a second instance on the
    `shutdown()` path.
  - **Fault 3**: contradicted by the L1 measurement recorded at
    `OfflineHarnessTests.swift:1675-1679` and in `../DECISIONS.md` (-1009 over
    25 runs, inside 40 s). It is staged as a measurement.
  - **The one-line fix the issue implies for fault 2** (count -1001 as a
    loopback failure) would restart the loopback every idle minute, because the
    bus's long-poll dies with -1001 by design. §4.1 uses a separate signal for
    that reason.
  - **Stage 3 opens a window for a leak** that the synchronous start closes
    today. `loadInitial` does not wait for the proxy, and the fixture path
    publishes `Running` before it. §4.3 adds the guard, and the R10 anti-leak
    tests are re-run under a slow relay start to prove it.
- 2026-09-25: **stage 1 built** in `5864df9` (vendored hook), `c5d5198`
  (bound and recovery) and `4c5a65d` (L2 tests and script instruments).
  **Stages 2, 3 and 4 are not built.** Faults 4, 1 and 3 are as §1 describes
  them. The build departs from the text above in these ways:
  - **`bounded` is not a task group.** A task group awaits its losing child,
    and a call queued on a busy node actor does not see cancellation until
    the actor reaches it, so the bound would not hold in the case it exists
    for. The losing request is cancelled and not awaited. A host check
    stands in for the difference: a call that ignores cancellation must
    still be abandoned at the bound.
  - **`LoopbackStatusTimeout`, `statusBound` and the classifier live in
    `App/Network/LoopbackHealth.swift`, not `TSNetManager`**, so the host
    test compiles them without TailscaleKit.
    `isLocalLoopbackConnectionFailure` moved there with its body unchanged,
    and the -1001 comment is above it.
  - **The vendored hook drains a stalled connection rather than holding it
    unread**, so a request the client abandons does not keep a descriptor
    open. The client sees no difference: no byte ever comes back.
  - **The discovery tests stall before the first status is published**
    (`-UITestTCPChaosDelay 0`). That status starts the sweep, so the chaos
    plumbing's usual "after the first Running poll" would race it.
  - **The second discovery test ends on `token-sheet`, not on
    `gateway-<gw>`.** A first-run sweep that finds one gateway chooses it by
    itself, so the row is gone before a test can see it. Recovery is read
    from `tcp-chaos-test-status`, which the picker now shows in test builds.
    The exact log lines are checked by the two scripts, from the unified log.
  - **§8's slow-answer log is in:** an answer over 500 ms logs `Status
    request answered after N ms`. Login stays unbounded (§8, the owner's
    question).
  - **§7's grep** finds one bare `backendStatus()` outside `boundedStatus`:
    `App/TimingHarness.swift:335`. That is the test-build timing harness,
    not a UI path.
  - Two Go tests for the hook (`TestLatchkeyStalled…`), run by
    `scripts/test-all.sh`.
- Shown able to fail. Each mutation was built and run, and the source was
  restored afterwards:
  - **Today's behaviour** (status unbounded, everything else kept): both
    discovery tests fail with no P6 within 30 s. The lifecycle test fails
    with "never read recovered within 45 s; last: damaged". The other 15 tests
    in the two suites pass.
  - **No two-strike trigger:** the second discovery test fails with no
    recovery (status "damaged"). The first test passes, as it should: the
    bound alone ends the search.
  - **The stall survives `RestartLoopback`** (a vendored mutation, with the
    framework rebuilt): recovery runs, but the next search finds nothing and
    the gateway is never loaded.
  - **Host:** adding -1001 to the classifier fails "a bus -1001 is not a
    loopback failure". Awaiting the losing request fails the
    ignores-cancellation check (2.1 s against a 0.3 s bound).
  - **Go:** a listener that ignores the mark fails "a stalled listener
    answered".
- Measured: searching → P6 **6.2 s** (budget 16 s) in both discovery runs.
  Searching → loopback recovered **6.5 s and 6.8 s** (budget 25 s). Under a
  live page, damage → recovered **13.3 s and 13.6 s**. `make test-policy`
  passed, with the new host test at 21/21. Discovery passed 12/12, with its
  parser counting both stalled sweeps and one recovery. Lifecycle passed
  6/6. The quick tier (`scripts/test-all.sh --build`) is recorded in
  `../DECISIONS.md`.
