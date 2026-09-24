# F8 — A node that cannot start is a screen, not a crash

| | |
|---|---|
| **Status** | spec — not implemented. Deferred deliberately from the 2026-09-23 adversarial review, which recorded it under "Left open": *"Needs a design, not a quick guard."* |
| **Requested** | Not by Olof directly. Found by the full-codebase adversarial review of 2026-09-23 and left open in `../DECISIONS.md` because the obvious fix — catch the error and carry on — produces a running app with no node, which is a worse lie than the crash |
| **Revision** | one: `TSNetManager` **never traps** on a node it could not create. Every timeout, budget, poll cadence and the split tunnel are unchanged |
| **Extends** | [F4](F4-never-a-bare-screen.md). F4 enumerates every state the root view can be in (§2, G0–G6 / D1–D11 / P1–P8) and this state is **absent from that table** — because today it is not a state, it is a `fatalError`. F8 adds one row, **G7**, and reuses F4's failure screen, wording rules and identifiers rather than inventing a second failure surface |
| **Touches** | `TSNet/TSNetManager.swift` (the `catch`), `TSNet/TSNetModel.swift` (one published value), `App/Workspace/WorkspaceManager.swift` (**the second trap, §1.4**), `App/Tailnet Status/StatusViewModel.swift` + `StatusView.swift` (the G7 text and its affordances), `App/Workspace/WorkspaceStore.swift` (a *move-aside*, not a delete), the L1 offline suite, one host test |

## 1. Why

### 1.1 The app kills itself, and the only exit costs the node's identity

`TSNetManager.startTailscale` (`TSNet/TSNetManager.swift:176-191`):

```swift
} catch {
    await MainActor.run { startInFlight = false }
    fatalError("Error setting up Tailscale: \(error)")
}
```

Every failure to bring up the embedded node is a process kill. On a phone that
is a launch-time crash: tap the icon, it dies, tap it again, it dies. The owner
has no log to read, because Settings → Diagnostics is inside the app that just
died, and **no way out except deleting the app** — which deletes
`<Application Support>/Latchkey/`, i.e. every workspace's tsnet state directory,
i.e. the node's identity. `WorkspaceStore.swift:90-158` and `AGENTS.md` both
spell out what that costs: the device is logged out, tailnet-lock re-signing and
new grants are needed, and nothing says so — the app just quietly starts over.

So the cheapest recovery from a transient failure is a permanent loss. That is
the whole of the problem.

### 1.2 The recovery machinery already exists, and the trap pre-empts it

Two things in the same file show the author already intended this to be
survivable:

- `startInFlight = false` is set **immediately before** the `fatalError` —
  bookkeeping for a retry that can never happen, because the next statement
  ends the process.
- `willEnterForeground` (`:901`) already calls `startTailscaleIfNeeded()` when
  `node == nil`, and `startTailscaleIfNeeded` (`:115-132`) already guards against
  overlapping starts. **A driver for "try again later" is in place and wired to a
  real event.** The node just has to survive long enough to be retried.

This is why the fix is not "add a guard": the guard is there. The missing piece
is a state for "there is no node", and a screen that says so.

### 1.3 What can actually throw

`setupNode` (`:462-466`) constructs `TailscaleNode`, whose `init`
(`ThirdParty/libtailscale/swift/TailscaleKit/TailscaleNode.swift:60-83`) throws
`TailscaleError.badInterfaceHandle` or
`TailscaleError.fromPosixErrCode(res, tailscale.getErrorMessage())` — a POSIX
errno **and** tsnet's own message. `tailscaleUp` then makes LocalAPI calls that
throw the same way. Plausible causes, all of which a correct app survives:

| Cause | Shape | Transient? |
|---|---|---|
| State directory unreadable or unwritable (wrong permissions, a restored backup, a half-written container) | `EACCES`/`EPERM` from `tailscale_set_dir` | no — needs the owner |
| Disk full | `ENOSPC` | yes, once space is freed |
| The loopback listener's port still held by a dying previous instance | `EADDRINUSE` | yes, seconds |
| tsnet's own start failing for its own reasons | errno + message | usually |
| A corrupt `tailscaled.state` inside an otherwise fine directory | tsnet message, no useful errno | no — needs a decision |

Note the split: **most are transient, and the one that is not is the one where
deleting the app is most tempting and most expensive.** A design that only
retries, or only offers a reset, gets half the cases wrong.

### 1.4 There is a second trap, and it fires first

Fixing `startTailscale` alone would leave the crash loop fully intact for the
headline case. `WorkspaceManager.init` (`App/Workspace/WorkspaceManager.swift:55-59`):

```swift
do {
    try TailscaleLogging.setup(directory: WorkspaceStore.logsDir.path)
} catch {
    fatalError("Could not initialize process logging: \(error)")
}
```

This runs during app construction, **before** any node is created, and its
directory is inside the same `<Application Support>/Latchkey/` tree. So an
unwritable container — `EACCES`, the one non-transient cause and the one where
delete-and-reinstall is most tempting — trips *this* trap first, and F8's screen
is never reached. Two traps, one underlying fault, and the sibling would have
been left behind: the same shape as the review's systemic finding (a protection
written once and not carried to the sibling path).

It cannot simply be caught and ignored, and this is the constraint that shapes
§4.6. The comment above it is load-bearing: the setup "MUST run before any
`TailscaleNode` is created so all nodes share one logtail and Go runtime stderr
is captured by its persistent filch from the beginning." That filch is where
tsnet's Go stderr is redacted before it is written (R29, and the login-link
redaction of the same day). With setup failed and a node created anyway, tsnet's
stderr has nowhere it is *known* to go — and login links are exactly what it
carries. **So a logging-setup failure must prevent node creation**, not merely be
reported. That converts it from a second bug into a second cause feeding the same
screen, which is a simpler product than two failure paths.

> Worth confirming on device before building: where a Go-runtime write to an
> unredirected stderr actually lands on iOS. If it reaches the unified log, this
> is also a D1/R5 matter and the "must prevent node creation" rule is doing
> double duty. The rule is right either way — it is stated here as a design
> constraint, not as a measured fact.

### 1.5 Not reproducible today, and that is part of the finding

Nothing in any suite exercises this path, because there is no way to make the
node fail on demand — which is why a `fatalError` survived in the launch path of
a shipping app. F8 is not done until the failure can be *caused* in a test
(§6.1).

## 2. What the owner sees

One new row for F4 §2's table, in F4's own format:

| # | State | Where | Drawn | Text | Affordance | Leaves when | Verdict |
|---|---|---|---|---|---|---|---|
| G7 | **The node could not be created**: `startTailscale` threw | `StatusView` via `TSNetModel.startFailure` | brand header, warning icon, title, one-line cause, retry countdown | "Latchkey can't start its Tailscale node." + the cause (§3) | **Try now**, **Diagnostics → Logs**, and — behind a confirmation — **Start a new node** | a retry succeeds, or the owner starts a new node | fine (today: the app is gone) |

The wording, in full:

> **Latchkey can't start its Tailscale node.**
>
> `<cause>`
>
> Nothing has been deleted. Your node's identity is still on this device.
> Trying again in `<n>` s.
>
> [ Try now ]  [ Logs ]
>
> *Start a new node* — only if the above keeps failing. Your current node's
> files are kept, renamed aside, and you would sign in to the tailnet again.

`<cause>` is one sentence chosen from the errno, plus the raw
`errno`/message in the Logs — never only the raw message on screen, and never
only the friendly sentence in the log:

| Condition | Sentence |
|---|---|
| `EACCES`, `EPERM` | "Its files can't be opened. This usually means the app's storage permissions changed." |
| `ENOSPC` | "This device is out of storage. Free some space and it will start." |
| `EADDRINUSE` | "A previous run is still shutting down." (retry is almost certainly enough) |
| anything else | "Tailscale reported: `<tsnet's message>` (`<errno name>`)." |

Three rules the screen must obey, each because the alternative is what an app
normally does here:

1. **"Nothing has been deleted" is on the screen, not implied.** An owner
   staring at a failure reaches for delete-and-reinstall, and on this app that
   is the one irreversible act available to them.
2. **The retry is visible and counted.** F4's G2 verdict is "thin — no elapsed,
   no escalation": a silent retry is indistinguishable from a hang.
3. **"Start a new node" is not a button you can hit by accident**, and it does
   not say "Reset". It is the last line, it takes a confirmation naming what will
   happen, and it *moves* rather than deletes (§4.4).

## 3. Non-goals

- **No automatic recovery that touches the state directory.** No delete, no
  move, no "repair" without the owner saying so. `WorkspaceStore`'s existing
  `.preserve` decision (`WorkspaceStore.swift:490-497`: "Touch nothing on disk;
  run a recovery workspace; say so loudly") is the precedent and F8 follows it.
- **No change to the node lifecycle**, the start sequence, or the deliberate
  absence of `node.up()` (`:196-209`). F8 changes what happens *after* a
  failure, nothing about how a start is attempted.
- **No new container, bundle id or storage location.**
- **Not a general error-reporting feature.** One state, one screen.
- **No unbounded retry loop.** A retry every 5 s forever is a battery bug
  wearing a recovery costume.

## 4. Design

### 4.1 `TSNetManager`: return, do not trap

```swift
} catch {
    await MainActor.run {
        startInFlight = false
        model.startFailure = TSNetModel.StartFailure(error)
        logger.log("NODE START FAILED: \(error). Nothing on disk has been changed. \
                    Retry \(attempt) of \(Self.startAttempts); next in \(delay)s.")
    }
}
```

`fatalError` goes. Nothing else in the `do` block changes.

### 4.2 `TSNetModel`: one published value

```swift
/// The node could not be created. Nil once one is (F8).
@Published var startFailure: StartFailure?

struct StartFailure: Equatable, Sendable {
    let errnoValue: Int32?      // nil when the error carried none
    let message: String         // tsnet's own words, for the log and Logs
    let attempt: Int
    let nextRetryIn: Duration?  // nil when the attempts are exhausted
}
```

Cleared in exactly one place: when a node is successfully created. A failure
that is cleared anywhere else is a screen that lies.

### 4.3 Bounded retry with backoff, plus the events that already exist

`startTailscaleIfNeeded` gains an attempt counter and a delay:
**five attempts at 1, 2, 4, 8, 16 s**, then it stops retrying by itself and the
screen drops the countdown, keeping **Try now**. The numbers are the same shape
the page's own reconnect uses (`testing/harness/page_check.js` asserts KiroCrew's
1 s doubling to 10 s), so there is one backoff idiom in the product.

`willEnterForeground`'s existing `if node == nil { startTailscaleIfNeeded() }`
resets the counter: the owner having backgrounded and returned is new
information, and `EADDRINUSE` and `ENOSPC` are both likely to have resolved.

### 4.4 "Start a new node" moves; it never deletes

In `WorkspaceStore`, beside `stateDir(_:)`:

```swift
/// Renames the workspace's `state/` aside so a fresh node can be created,
/// and returns where it went. NEVER deletes: this directory IS the node's
/// identity, and an owner who taps this is already having a bad day.
static func setStateDirAside(_ id: UUID) throws -> URL
```

The old directory becomes `state-aside-<ISO8601>/`, beside `state/`. Consequences,
stated because the confirmation dialog must state them: the device appears as a
**new node** on the tailnet, needs approval and grants again, tailnet lock needs
re-signing, and the old node lingers in the admin console until removed. The
aside directory is *not* excluded from the backup exclusion that
`BackupExclusion.apply` sets on the root (`WorkspaceManager.swift:63`) — it is
inside the same root, so it stays excluded, which is correct: it holds node keys.

No automatic cleanup of aside directories. They are small, they are the only
copy of an identity, and a sweeper that deletes them is the crash loop's damage
arriving late.

### 4.5 Where the screen lives

`StatusViewModel` gains `startFailure` as the highest-priority state — ahead of
`nil`/`NoState`/`Starting` (`StatusViewModel.swift:183-187`), because those are
what the model reports *while* there is no node, and G2's "Connecting…" over a
node that will never exist is F4's "misleading" verdict exactly. `StatusView`
renders it with F4 §4.4's `PageFailureText` conventions and F4 §4.12's
identifier discipline; new identifiers:

| Identifier | On |
|---|---|
| `node-start-failed` | the container |
| `node-start-failed-cause` | the one-line cause |
| `node-start-retry-now` | Try now |
| `node-start-new-node` | Start a new node |
| `node-start-new-node-confirm` | the confirmation's destructive button |

### 4.6 The logging trap becomes the same screen

`WorkspaceManager.init`'s `fatalError` (§1.4) goes the same way, but it cannot
just carry on: a failed logging setup must **stop a node from being created at
all**, because the filch that redacts tsnet's Go stderr is what failed.

```swift
/// Set when process logging could not be initialised. While this is set,
/// NO node is created: the filch that redacts tsnet's Go stderr (R29) is
/// exactly what failed, and a node started without it writes login links
/// somewhere unaudited. Reported as F8's G7 with its own cause sentence.
private(set) var loggingUnavailable: Error?
```

`startTailscaleIfNeeded` returns early while it is set, publishing a
`StartFailure` whose sentence is "Latchkey can't open its own log files, so it
won't start a node until that is fixed." — deliberately naming the *refusal* as
deliberate, because a retry countdown over a permanent condition is the same lie
G2 tells today. **Try now** re-attempts the logging setup first; if that succeeds
the node start follows in the same tap.

This is one screen with two causes, not two screens: the owner's situation
("the app can't reach its own storage") and their action (fix permissions, or
start a new node) are identical.

### 4.7 D1 holds

The cause sentence, the errno and tsnet's message are shown **on the device** and
written to the app's own log. Nothing is sent anywhere: D1 (no app or tsnet logs
leave the device) is unchanged, and this screen adds no network call at all.

## 5. State and migration

Nothing new is persisted. `startFailure` is in-memory only — a failure that
survived a relaunch would be a stale claim about a node that might start fine
this time.

The only on-disk change F8 can make is `state/` → `state-aside-<timestamp>/`, and
only when the owner confirms it. A build **before** F8 that meets such a
directory ignores it: it reads `state/`, which is absent, and creates a new node
— the same outcome F8 produced deliberately. No migration is needed in either
direction.

## 6. End-to-end tests

### 6.1 First, make the failure causable

Test builds only (R15), in the `LATCHKEY_TEST_HOOKS` block that already carries the
chaos hooks (`-UITestDefunctLoopback`, `-UITestShutdownTCPConnections`,
`-UITestDefunctRelayListener`, `:171-174`):

- `-UITestNodeStartFails <errno>` — `setupNode` throws
  `TailscaleError.fromPosixErrCode(errno, "test hook")` before touching tsnet.
- `-UITestNodeStartFailsTimes <n>` — fails the first *n* attempts and then
  succeeds, which is the only way to test that the retry works rather than that
  it is merely attempted.

A hook, not a real broken directory, for the first four tests: making the
container unwritable from XCUITest is possible but it is also how you leave a
simulator in a state that fails the *next* suite. One test does use the real
thing (test 5).

### 6.2 The tests

| Test | Suite | Asserts | Shown to fail by |
|---|---|---|---|
| `testANodeThatCannotStartShowsAScreenInsteadOfDying` | L1 offline | with `-UITestNodeStartFails EACCES`: the app is still running after 10 s, `node-start-failed` exists, the cause names storage permissions, and "Nothing has been deleted" is on screen | against today's build: the app is gone (XCUITest reports it not running). Also by asserting the app's process is alive — the assertion that would have caught the original defect |
| `testTheNodeStartRetryIsVisibleAndSucceeds` | L1 offline | with `-UITestNodeStartFailsTimes 2`: the screen appears, shows a countdown, and the dashboard is reached without any tap | removing the backoff retry (attempts = 1): the screen stays forever. Also by making the hook fail *always* and asserting the countdown **stops** after five attempts while Try now remains |
| `testTryNowRestartsTheNodeImmediately` | L1 offline | with `-UITestNodeStartFailsTimes 99` then flipping the hook off via the control port, tapping `node-start-retry-now` reaches the dashboard without waiting out the backoff | ignoring the tap: the test waits out the full backoff and times out |
| `testStartingANewNodeMovesTheOldStateAsideAndKeepsIt` | L1 offline | after confirming `node-start-new-node`: a `state-aside-*` directory exists in the container **with the old node's files in it**, `state/` is fresh, and the old directory is untouched byte-for-byte (compare a file planted before) | making it a delete: the aside directory is absent. Also by tapping `node-start-new-node` and **dismissing** the confirmation — nothing on disk may move |
| `testAnUnwritableStateDirectoryIsSurvived` | L1 offline | the real thing: `chmod 000` the workspace's `state/` from the host before launch; the app shows G7, names permissions, and does not crash. Restores the mode in `addTeardownBlock` | against today's build: a crash. This is the only test that proves the *hook* models the real failure |
| `testLoggingSetupFailureStopsTheNodeRatherThanStartingItBlind` | L1 offline | with a hook failing `TailscaleLogging.setup`: G7 appears with the log-files sentence, **no countdown**, and the app log records that no node was started. Then assert the harness saw **zero** SOCKS connections — no node means no traffic | against a version that merely reports the failure and continues: a node exists and the proxy sees connections. This is the test that keeps the fix from trading a crash for an unaudited login link |
| `test-node-start-failure.swift` | host (`make test-policy`) | the errno → sentence mapping, the backoff schedule (1, 2, 4, 8, 16 then no more), that `StartFailure` is cleared only by success, and that a logging failure yields **no** `nextRetryIn` | changing a sentence; extending the schedule; clearing the failure on any other event; giving the logging case a countdown |

Every test that taps *Start a new node* must assert the aside directory's
contents, not merely its existence. An empty `state-aside-*` beside a fresh
`state/` is data loss that passes a weaker test.

## 7. Acceptance criteria

- Grep: **no `fatalError` remains on any launch path reachable in a release
  build** — `TSNetManager.swift:189` *and* `WorkspaceManager.swift:58`, which is
  the whole of the set. (`App/Testing/*` and `TokenEntrySheet.swift:186`'s
  `required init?(coder:)` are out of scope; the first is test-only, the second is
  unreachable-by-construction. `App/Testing`'s traps are argument validation in
  test builds, where a crash is the correct response to a malformed `-Test…` flag.)
- **No node is ever created while process logging is unavailable**, asserted by a
  test, because that is the one way this feature could trade a crash for a leak.
- With the node failing, the app is running and readable 10 s after launch, and
  the screen names a cause, a retry and Logs.
- A failure that clears on retry reaches the dashboard with no tap.
- After *Start a new node*, the previous `state/` still exists, with its files,
  under `state-aside-<timestamp>/`.
- The app never writes to or deletes any state directory without the owner
  confirming a dialog that names the consequence.
- `../DECISIONS.md`'s "Left open" entry for `startTailscale` is removed, and the
  rule is recorded: **the launch path does not trap.**

## 8. Open questions and owner actions

- **Olof:** should *Start a new node* exist at all in the first build, or should
  the screen stop at Try now plus Logs and leave the aside move to a later
  version once we know which failures actually happen? The argument for shipping
  it: the whole point is that the owner's current escape hatch destroys the
  identity, and without an in-app alternative they will still reach for delete.
  The argument against: it is the only irreversible-ish action in the app, and it
  is being designed against failures we have never seen.
- **Olof:** should a node-start failure also be surfaced when it happens *after*
  a successful start — e.g. a later `willEnterForeground` retry failing — or is
  that adequately covered by the existing `Stopped` (G6) and relay-recovery
  paths? The spec above deliberately covers only "there is no node yet".
- Worth measuring once there is a second user: which errno actually shows up.
  The sentence table is written from what `tsnet_start` *can* return, not from
  one observed failure, and it says so.

## 9. Log

- 2026-09-23: specced, and the spec found a second defect. The review recorded
  one trap; writing the design turned up `WorkspaceManager.init`'s, which fires
  **earlier** on the same unwritable-container fault, so fixing only the one that
  was reported would have left the crash loop intact for the exact case used to
  motivate the fix (§1.4). That in turn produced the one real constraint here: a
  logging failure must *prevent* a node from starting, or the fix trades a crash
  for tsnet stderr written somewhere unredacted.
- 2026-09-23: specced. Found by that day's adversarial review and deferred with
  "needs a design, not a quick guard" — correctly, because the cheap version
  (catch and continue) yields a running app with no node and no explanation,
  which is worse than the crash it replaces. Writing it turned up the detail that
  makes the design straightforward: **the retry driver already exists**
  (`willEnterForeground`, `node == nil`) and `startInFlight = false` is already
  set one line above the trap, so the original author was a statement away from
  this and stopped. The genuinely new work is a state, a screen, and a recovery
  that moves instead of deleting.
